import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// V2-Maps-Perf – Dekodier-Cache der Kandidatenphase (Folgeauftrag aus der
/// V2-11-Zertifizierung: Maps/CAD 2,8× langsamer als V1, Ursache mehrfache
/// Dekodierungen derselben großen Raster in der Kandidatenphase).
///
/// Festgenagelt:
///   1. DEKODIER-ZÄHLER (Test-Seam: zählende Pixelquelle) – die Auflösungs-
///      leiter (§9.4) dekoliert EINMAL je (Ressource, Ebene) statt je Stufe:
///      DCT (keine Eingangsreduktion) 4 Stufen → 1 Dekodierung; JPX mit
///      cp_reduce → 1 Dekodierung je Reduktionsstufe.
///   2. PLAN-DETERMINISMUS alt (je Stufe dekodiert, Mini-Budget-Cache mit
///      sofortiger Verdrängung reproduziert das alte Rufmuster) vs. neu
///      (Cache-Hits) – Aktionen, normalisierte CandidateSets und Decisions
///      unverändert. Hartes Gate: gleiche Datei → gleicher Plan.
///   3. RASTER-GLEICHHEIT: Cached Raster ≡ frische Dekodierung (Pixelvergleich)
///      – die Wurzel der Byteidentität.
///   4. CACHE-POLITIK: Budget/Verdrängung ergebnisneutral, Blatt-Freigabe
///      hält benötigte Ebenen, RAII über cancel().
@Suite(.serialized) struct MapsDecodeCacheTests {

    // MARK: - Hilfen

    /// Zählende Pixelquelle – der Dekodier-Zähler des Tests. Thread-sicher,
    /// weil die Candidate-Erzeugung unter dem Pixel-Budget-Scheduler parallel
    /// laufen kann.
    private final class CountingPixelSource: ImagePixelSource {
        let image: CGImage
        private let lock = NSLock()
        private(set) var decodeCalls = 0
        private(set) var requestedTargets: [PixelSize] = []

        init(image: CGImage) { self.image = image }

        func decodedImage(for resource: PDFImageResource) -> CGImage? {
            lock.lock(); decodeCalls += 1; lock.unlock()
            return image
        }

        func decodedImage(for resource: PDFImageResource,
                          target: PixelSize) -> CGImage? {
            lock.lock()
            decodeCalls += 1
            requestedTargets.append(target)
            lock.unlock()
            return image
        }
    }

    /// JPX-Quelle mit der EBENEN-Semantik von `LibQPDFPixelSource` (cp_reduce:
    /// je Reduktionsstufe eine eigene Dekodierungsvariante, Schlüssel via
    /// `reduceLevel`). Der Stub liefert für JEDE Ebene das volle Raster –
    /// der Test nagelt die Cache-Ebenenschlüssel und die Dekodier-Zählung
    /// fest (je Ebene EIN Dekodierlauf), nicht die Pixelherleitung der
    /// Reduktion (die gehört zur Quelle selbst und bleibt dort getestet).
    private final class JPXReduceCountingSource: ImagePixelSource {
        let fullImage: CGImage
        private let lock = NSLock()
        private(set) var decodeCalls = 0
        private(set) var decodedLevels: [Int] = []

        init(fullImage: CGImage) { self.fullImage = fullImage }

        func decodedImage(for resource: PDFImageResource) -> CGImage? {
            lock.lock(); decodeCalls += 1; lock.unlock()
            return fullImage
        }

        func decodedImage(for resource: PDFImageResource,
                          target: PixelSize) -> CGImage? {
            let level = LibQPDFPixelSource.reduceLevel(resource: resource,
                                                       target: target)
            lock.lock()
            decodeCalls += 1
            decodedLevels.append(level)
            lock.unlock()
            return fullImage
        }

        func decodeLevel(for resource: PDFImageResource, target: PixelSize) -> Int {
            LibQPDFPixelSource.reduceLevel(resource: resource, target: target)
        }
    }

    /// Foto-artiges Raster: großskalige Farbflecken plus Körnung
    /// (deterministisch). Die großskalige Struktur überlebt das
    /// Feature-Sampling (128²), damit das Bild AUCH auf reduzierten Rastern
    /// (JPX cp_reduce liefert dem Klassifizierer das verkleinerte
    /// Zielraster) als photo durchgeht und die JPEG-Leiter läuft.
    static func photoImage(width: Int, height: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let buf = ctx.data else { return nil }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd(_ modulus: UInt64) -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (seed >> 33) % modulus
        }
        func noise() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % 121) - 60
        }
        // 1) Großskalige Farbflecken (Photosynthese der Merkmale: lokale
        //    Varianz und Farbvielfalt bleiben beim Heruntersampeln erhalten).
        ctx.setBlendMode(.normal)
        for _ in 0..<40 {
            let cx = CGFloat(rnd(UInt64(width))), cy = CGFloat(rnd(UInt64(height)))
            let r = CGFloat(width + height) / 12 + CGFloat(rnd(64))
            ctx.setFillColor(CGColor(
                red: CGFloat(rnd(256)) / 255, green: CGFloat(rnd(256)) / 255,
                blue: CGFloat(rnd(256)) / 255, alpha: 0.9))
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r,
                                       height: 2 * r))
        }
        // 2) Körnung (±60) über die Flecken – Fotokörnung statt Flachfläche.
        let px = buf.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for i in 0..<(width * height) {
            let o = i * 4
            for c in 0..<3 {
                px[o + c] = UInt8(max(0, min(255, Int(px[o + c]) + noise())))
            }
        }
        return ctx.makeImage()
    }

    /// DCT-Ressource mit steuerbarer Platzierung (bestimmt Effective DPI,
    /// Zielgröße und Leiter).
    private static func resource(image: CGImage, objectNumber: Int,
                                 placedWidthPoints: Double,
                                 filters: [PDFImageFilter]) -> PDFImageResource {
        let heightFactor = Double(image.height) / Double(image.width)
        return PDFImageResource(
            objectID: PDFObjectID(objectNumber: objectNumber, generation: 0),
            width: image.width, height: image.height, bitsPerComponent: 8,
            colorSpace: .deviceRGB, filters: filters, unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            decodeArray: [], encodedByteCount: 2_000_000,
            placements: [PDFImagePlacement(pageIndex: 0, resourceName: "/Im0",
                                           placedWidthPoints: placedWidthPoints,
                                           placedHeightPoints:
                                               placedWidthPoints * Double(image.height)
                                               / Double(image.width))])
    }

/// Adaptive Politik mit .smart-Zusage (0.90) – damit die §9.4-Leiter
    /// native/1.25×/Ziel/0.85× bildet. pixelBudgetScheduler bewusst AUS:
    /// Die Zähltests prüfen die Ruffolge deterministisch (die Parallelität
    /// nutzt denselben Generator und denselben thread-sicheren Cache).
    static func ladderOptions() -> CompressionOptions {
        var options = CompressionOptions(image: ImageCompressionOptions(
            targetDPI: 72, tolerance: 1.0, maxPixelEdge: 4000,
            hardPixelCap: false, forceGrayscale: false, aggressiveGraphics: false,
            qualityPolicy: .adaptive(ladder: [0.6, 0.8],
                                     minimumSSIM: ImageCompressionOptions.smart.ssimThreshold)))
        options.featureFlags.pixelBudgetScheduler = false
        return options
    }

    /// Deterministischer Fingerabdruck eines Kandidaten (ohne
    /// Laufzeitmessung – die ist wall-clock-abhängig).
    struct MetricFingerprint: Equatable {
        let bytes: Int
        let ssim: Double?
        let p05: Double?
        let edge: Double?
        let text: Double?
        let deltaE: Double?
        let psnr: Double?

        init(_ m: CandidateMetrics) {
            bytes = m.encodedBytes
            ssim = m.globalSSIM
            p05 = m.p05TileSSIM
            edge = m.edgeScore
            text = m.textScore
            deltaE = m.deltaE76
            psnr = m.psnr
        }
    }

    /// Normalisiert eine Candidate-Liste auf deterministische Felder:
    /// IDs, Arten (Equatable, NICHT JSON – dessen Key-Reihenfolge ist nicht
    /// stabil) und Metrik-Fingerabdrücke.
    static func normalized(_ set: CandidateSet)
        -> (ids: [String], kinds: [CandidateKind],
            metrics: [MetricFingerprint]) {
        (set.candidates.map { $0.id.rawValue },
         set.candidates.map(\.kind),
         set.candidates.map { MetricFingerprint($0.metrics) })
    }

    // MARK: - 1) Dekodier-Zähler

    /// DCT-Foto, Leiter [native, 1.25×, Ziel, 0.85×] (4 Stufen): Vor dem Fix
    /// dekodierte JEDE Nicht-Ziel-Stufe die volle Quelle neu (4 Dekodierungen:
    /// Zielraster + 3 Leiterstufen); nach dem Fix bleibt es bei EINER
    /// Dekodierung – alle Stufen resampeln aus demselben gecachten Original.
    @Test(.hangGuard) func dctLeiterDekodiertNurEinmal() throws {
        let image = try #require(Self.photoImage(width: 2400, height: 1800))
        // 2400 px auf 600 pt → 288 DPI; Ziel-DPI 72 → Faktor 0.25 → 600×450.
        // Native Kante 2400 ≥ 1.5×600 → die 4-Stufen-Leiter bildet sich.
        let res = Self.resource(image: image, objectNumber: 7,
                                placedWidthPoints: 600, filters: [.dct])
        let source = CountingPixelSource(image: image)
        let planned = try CompressionPlanner.plan(
            resources: [res], options: Self.ladderOptions(),
            documentID: "maps-decode-dct", documentBytes: 2_000_000,
            pixels: source)

        #expect(source.decodeCalls == 1,
                "DCT-Leiter soll EINMAL dekodieren, tat es \(source.decodeCalls)×")
        // Nur der Einstieg (Schritt 4, Zielraster) fragt die Quelle – die
        // Leiterstufen kommen aus dem Cache bzw. dem Zielraster-Handle.
        #expect(source.requestedTargets == [PixelSize(width: 600, height: 450)])
        // Der Plan ist trotzdem ein vollständiger JPEG-Kandidatenplan.
        #expect(planned.plan.traceVersion == 2)
        #expect(!planned.plan.candidateSets.isEmpty)
    }

    /// JPX-Eingang: cp_reduce dekoliert je Reduktionsstufe direkt auf 1/2^N.
    /// Die Leiter [native, 1.25×, Ziel, 0.85×] bildet die Ebenen
    /// [0, 1, 2, 2] – dekoliert wird je EBENE einmal, gleiche Ebenen teilen
    /// sich dasselbe Raster (byteidentisch, siehe Test 3). Seit der Sonde
    /// (2026-10-19) kommt VOR der Leiter die nächstkleinere Ebene 3 dazu
    /// (200×150, ein Vierundsechzigstel der Pixel): Die Sonde kodiert sie
    /// einmal, um die Leiter bei schon kompakten Quellen zu sparen; hier
    /// ist die Sonde kleiner als das Original, und die Leiter läuft wie
    /// zuvor – 4 Dekodierungen, jede Ebene genau einmal.
    @Test(.hangGuard) func jpxLeiterDekodiertJeReduktionsstufeEinmal() throws {
        let image = try #require(Self.photoImage(width: 1600, height: 1200))
        // 1600 px auf 400 pt → 288 DPI; Ziel-DPI 72 → Faktor 0.25 → 400×300.
        let res = Self.resource(image: image, objectNumber: 7,
                                placedWidthPoints: 400, filters: [.jpx])
        let source = JPXReduceCountingSource(fullImage: image)
        let planned = try CompressionPlanner.plan(
            resources: [res], options: Self.ladderOptions(),
            documentID: "maps-decode-jpx", documentBytes: 2_000_000,
            pixels: source)
        #expect(source.decodeCalls == 4,
                "JPX-Leiter soll je Ebene einmal dekodieren (Sonde + 3 Ebenen), tat es \(source.decodeCalls)×")
        // Reihenfolge: Einstieg = Zielraster (Ebene 2), Sonde auf der
        // nächstkleineren Ebene (3), dann native (0), 1.25× (1); Zielrung
        // übernimmt das Einstiegsraster, 0.85× (2) trifft den Cache der
        // Ebene 2.
        #expect(source.decodedLevels == [2, 3, 0, 1],
                "Ebenenfolge unerwartet: \(source.decodedLevels)")
        #expect(planned.plan.traceVersion == 2)
    }

    // MARK: - 2) Plan-Determinismus alt vs. neu

    /// HARTES GATE: Der Plan mit Cache (1 Dekodierung) ist byteidentisch zum
    /// Plan des ALTEN Rufmusters (je Stufe dekodiert). Das alte Muster wird
    /// über ein Mini-Budget reproduziert: 1 Byte verdrängt jeden Eintrag
    /// sofort, also dekoliert jede Stufe neu – exakt das V2-11-Verhalten.
    /// Verglichen werden Aktionen, normalisierte CandidateSets (ohne
    /// Laufzeitmessungen) und die Decisions.
    @Test(.hangGuard) func planMitCacheIstByteidentischZumAltMuster() throws {
        let image = try #require(Self.photoImage(width: 2400, height: 1800))
        let res = Self.resource(image: image, objectNumber: 11,
                                placedWidthPoints: 600, filters: [.dct])
        let options = Self.ladderOptions()

        let cached = try CompressionPlanner.plan(
            resources: [res], options: options,
            documentID: "maps-det", documentBytes: 2_000_000,
            pixels: CountingPixelSource(image: image),
            store: CandidateStore())

        // Alt-Muster: Budget 1 Byte → jeder Cache-Eintrag wird sofort
        // verdrängt → je Stufe eine frische Dekodierung.
        let uncached = try CompressionPlanner.plan(
            resources: [res], options: options,
            documentID: "maps-det", documentBytes: 2_000_000,
            pixels: CountingPixelSource(image: image),
            store: CandidateStore(pixelCache: PixelDecodeCache(
                config: PixelDecodeCache.Config(budgetBytes: 1))))

        #expect(cached.plan.actions == uncached.plan.actions,
                "Aktionen weichen zwischen Cache und Alt-Muster ab")
        #expect(cached.plan.decisions == uncached.plan.decisions,
                "Decisions weichen zwischen Cache und Alt-Muster ab")
        let cachedSets = cached.plan.candidateSets.map(Self.normalized)
        let uncachedSets = uncached.plan.candidateSets.map(Self.normalized)
        #expect(cachedSets.map(\.ids) == uncachedSets.map(\.ids),
                "Kandidaten-IDs weichen ab")
        #expect(cachedSets.map(\.kinds) == uncachedSets.map(\.kinds),
                "Kandidaten-Arten weichen ab")
        #expect(cachedSets.map(\.metrics) == uncachedSets.map(\.metrics),
                "Kandidaten-Metriken weichen ab")
    }

    /// Lauf-zu-Lauf: zwei frische Läufe mit Cache liefern denselben Plan
    /// (gleiche Datei → gleicher Plan → gleiche Bytes). Geometrie mit
    /// klarem Abstand zu den Gate-Floors (2400×1800, SSIM-Marge ≈ 0.09) –
    /// ein Fixture knapp an der Gate-Grenze würde metrische Gleichstände
    /// der Vorberechnung (Pareto/Ladder-Ties) sichtbar machen, ohne etwas
    /// über den Cache auszusagen.
    @Test(.hangGuard) func planIstLaufzuLaufDeterministisch() throws {
        let image = try #require(Self.photoImage(width: 2400, height: 1800))
        let res = Self.resource(image: image, objectNumber: 9,
                                placedWidthPoints: 600, filters: [.dct])

        let first = try CompressionPlanner.plan(
            resources: [res], options: Self.ladderOptions(),
            documentID: "maps-det-run", documentBytes: 2_000_000,
            pixels: CountingPixelSource(image: image))
        let second = try CompressionPlanner.plan(
            resources: [res], options: Self.ladderOptions(),
            documentID: "maps-det-run", documentBytes: 2_000_000,
            pixels: CountingPixelSource(image: image))

        #expect(first.plan.actions == second.plan.actions)
        #expect(first.plan.decisions == second.plan.decisions)
        let firstSets = first.plan.candidateSets.map(Self.normalized)
        let secondSets = second.plan.candidateSets.map(Self.normalized)
        #expect(firstSets.map(\.ids) == secondSets.map(\.ids))
        #expect(firstSets.map(\.kinds) == secondSets.map(\.kinds))
        #expect(firstSets.map(\.metrics) == secondSets.map(\.metrics))
    }

    /// Cachtes Raster ≡ frische Dekodierung – die Wurzel der Byteidentität.
    /// Die Quelle erzeugt je Ruf ein NEUES CGImage aus denselben Pixeln
    /// (wie eine echte Dekodierung); der Vergleich gecacht-gegen-frisch darf
    /// keinen Pixelunterschied zeigen. Der Pixelvergleich läuft über
    /// Re-Encodierung (derselbe Encoder ist deterministisch: gleiche Pixel
    /// → gleiche Bytes).
    @Test func cachtesRasterIstPixelidentischZurFrischenDekodierung() throws {
        let image = try #require(Self.photoImage(width: 300, height: 200))
        let objectID = PDFObjectID(objectNumber: 11, generation: 0)

        // Erzeugt je Ruf ein NEUES Raster aus denselben Pixeln.
        func decodeFresh() -> CGImage? {
            ImageResampler.resize(image, to: PixelSize(width: 300, height: 200),
                                  components: 3)
        }

        let cache = PixelDecodeCache()
        let cached = try #require(cache.image(for: objectID, level: 0) { decodeFresh() })
        let fresh = try #require(cache.image(for: objectID, level: 0) { decodeFresh() })
        #expect(cached === fresh, "Zweiter Ruf lieferte kein Cachtes Raster")

        // Nach der Verdrängung (Budget 1) wird neu dekoliert – neues Objekt,
        // dieselben Pixel.
        let tight = PixelDecodeCache(config: PixelDecodeCache.Config(budgetBytes: 1))
        let firstTight = try #require(tight.image(for: objectID, level: 0) { decodeFresh() })
        let secondTight = try #require(tight.image(for: objectID, level: 0) { decodeFresh() })
        #expect(firstTight !== secondTight,
                "Verdrängung hätte neu dekodieren müssen (neues Objekt)")
        let encodedFirst = try #require(
            ImageResampler.encodeJPEG(firstTight, quality: 1.0))
        let encodedSecond = try #require(
            ImageResampler.encodeJPEG(secondTight, quality: 1.0))
        let encodedCached = try #require(
            ImageResampler.encodeJPEG(cached, quality: 1.0))
        #expect(encodedFirst == encodedSecond,
                "Neu dekodiertes Raster weicht vom Cachten ab")
        #expect(encodedCached == encodedSecond,
                "Cachtes Raster weicht von der frischen Dekodierung ab")
    }

    /// Vorbereiteter Pixelbuffer (V2-Maps-Perf): `JPEGEncoder.encode(prepared:)`
    /// liefert bitidentische Bytes zum Pfad ohne Vorbereitung – dieselben
    /// Pixel in denselben Shim. Grundlage der Bracketed-Search-Beschleunigung
    /// (rawBitmap ist qualitätsunabhängig).
    @Test func preparedPixelsEncodiertByteidentisch() throws {
        let image = try #require(Self.photoImage(width: 257, height: 131))
        let prepared = try #require(JPEGEncoder.preparePixels(image))
        for quality in [0.6, 0.8, 0.97] {
            let direct = try #require(JPEGEncoder.encode(
                image, quality: quality, backend: .mozjpeg))
            let withPrepared = try #require(JPEGEncoder.encode(
                image, quality: quality, backend: .mozjpeg, prepared: prepared))
            #expect(direct == withPrepared,
                    "Prepared-Pixelbuffer ergab andere Bytes (q=\(quality))")
        }
        #expect(prepared.components == 3)
        #expect(prepared.pixels.count == 257 * 131 * 3)
    }

    // MARK: - 3) Cache-Politik

    @Test func cacheZaehltHitsMissesUndGibtFrei() throws {
        let objectID = PDFObjectID(objectNumber: 21, generation: 0)
        let image = try #require(Self.photoImage(width: 64, height: 48))
        let cache = PixelDecodeCache()

        var decodeRuns = 0
        _ = cache.image(for: objectID, level: 0) { decodeRuns += 1; return image }
        _ = cache.image(for: objectID, level: 0) { decodeRuns += 1; return image } // Hit
        _ = cache.image(for: objectID, level: 3) { decodeRuns += 1; return image } // Miss (andere Ebene)
        #expect(decodeRuns == 2)
        #expect(cache.hits == 1)
        #expect(cache.misses == 2)

        cache.releaseLevels(of: objectID, keeping: [3])
        #expect(cache.currentCachedBytes == Self.rasterBytes(image))
        cache.release(resource: objectID)
        #expect(cache.currentCachedBytes == 0)
        // Nach der Freigabe wird wieder dekoliert – ergebnisneutral.
        _ = cache.image(for: objectID, level: 0) { decodeRuns += 1; return image }
        #expect(decodeRuns == 3)
    }

    /// Verdrängung bleibt ergebnisneutral: Über Budget wird least-recently-
    /// used geworfen, die gelieferten Raster bleiben gültig, ein verdrängter
    /// Eintrag wird bei Bedarf deterministisch neu dekodiert.
    @Test func budgetVerdraengtErgebnisneutral() throws {
        let image = try #require(Self.photoImage(width: 64, height: 48))
        let bytes = Self.rasterBytes(image)
        let cache = PixelDecodeCache(config: PixelDecodeCache.Config(
            budgetBytes: bytes * 2))
        let a = PDFObjectID(objectNumber: 1, generation: 0)
        let b = PDFObjectID(objectNumber: 2, generation: 0)
        let c = PDFObjectID(objectNumber: 3, generation: 0)

        var runs = 0
        _ = cache.image(for: a, level: 0) { runs += 1; return image }
        _ = cache.image(for: b, level: 0) { runs += 1; return image }
        _ = cache.image(for: c, level: 0) { runs += 1; return image }
        #expect(cache.evictions >= 1, "Drittes Raster musste verdrängen")
        #expect(cache.currentCachedBytes <= bytes * 2)
        #expect(runs == 3)

        // Das verdrängte Raster wird bei erneutem Ruf neu dekodiert – und
        // liefert dasselbe Ergebnis (Dekodierung ist deterministisch).
        _ = cache.image(for: a, level: 0) { runs += 1; return image }
        #expect(runs == 4)
    }

    /// RAII wie der CandidateStore: cancel() räumt auch den Pixel-Cache.
    @Test func storeCancelLeertPixelCache() throws {
        let image = try #require(Self.photoImage(width: 64, height: 48))
        let store = CandidateStore()
        let objectID = PDFObjectID(objectNumber: 13, generation: 0)
        var runs = 0
        _ = store.pixelCache.image(for: objectID, level: 0) {
            runs += 1; return image
        }
        #expect(store.pixelCache.currentCachedBytes > 0)
        store.cancel()
        #expect(store.pixelCache.currentCachedBytes == 0)
        _ = store.pixelCache.image(for: objectID, level: 0) {
            runs += 1; return image
        }
        #expect(runs == 2)
    }

    /// Env-Überschreibung des Budgets (Muster PDFTOOLS_PIXEL_BUDGET).
    @Test func budgetAusUmgebungLesbar() {
        let config = PixelDecodeCache.Config.resolved(env:
            ["PDFTOOLS_DECODE_CACHE_BUDGET": "33554432"])
        #expect(config.budgetBytes == 32 * 1_048_576)
        #expect(PixelDecodeCache.Config.resolved(env: [:]).budgetBytes
                == 192 * 1024 * 1024)
    }

    // MARK: - 4) Ressourcen-Grenze

    /// Zwei Ressourcen teilen sich den Store-Cache, ohne sich zu vermischen:
    /// je Ressource genau eine Dekodierung, keine Kreuz-Hits (Schlüssel ist
    /// die Ressource).
    @Test(.hangGuard) func ressourcenTeilenCacheOhneKreuztreffer() throws {
        let image = try #require(Self.photoImage(width: 1200, height: 900))
        let a = Self.resource(image: image, objectNumber: 21,
                              placedWidthPoints: 300, filters: [.dct])
        let b = Self.resource(image: image, objectNumber: 22,
                              placedWidthPoints: 300, filters: [.dct])
        let source = CountingPixelSource(image: image)
        let options = Self.ladderOptions()

        let planned = try CompressionPlanner.plan(
            resources: [a, b], options: options,
            documentID: "maps-two", documentBytes: 4_000_000,
            pixels: source)

        // Je Ressource EIN Dekodierlauf (Einstiegsraster); die Leiterstufen
        // kommen aus dem Cache der EIGENEN Ressource.
        #expect(source.decodeCalls == 2,
                "Zwei Ressourcen → zwei Dekodierungen, tat es \(source.decodeCalls)×")
        #expect(planned.plan.actions.count == 2)
    }

    private static func rasterBytes(_ image: CGImage) -> Int64 {
        PixelDecodeCache.rasterBytes(of: image)
    }
}
extension MapsDecodeCacheTests {
    static func countingSourceSeam(image: CGImage) -> ImagePixelSource {
        CountingPixelSource(image: image)
    }
}
