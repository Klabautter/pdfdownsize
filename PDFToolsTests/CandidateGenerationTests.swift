import Testing
import Foundation
@testable import PDFTools

/// Phase V2-3a (§9, §5.8) – Candidate-Erzeugung je Bildklasse.
///
/// Festgenagelt:
///   • KEEP ist IMMER Candidate 0 (§9.1): bytes = Original, Verzerrung 0,
///     Laufzeit 0 – in jedem Set, auch wenn das Bild strukturell KEEP ist.
///   • Je Klasse die richtige Kandidatenart (§9.5/§9.7/§9.8/§9.9), direkt
///     aus den bestehenden Pfaden.
///   • Budget: max 10 ernsthafte Kandidaten je Bild (§9.2).
///   • V2-11 – Candidate Engine Default AN (§25: „V2 Flags default ON“);
///     der frühere Legacy-Plan (traceVersion 1) existiert nicht mehr.
@Suite struct CandidateGenerationTests {

    // MARK: Helfer

    static func candidateOptions(_ base: CompressionOptions = .smart)
        -> CompressionOptions {
        var options = base
        options.featureFlags.candidateEngine = true
        return options
    }

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("candgen-\(label)-\(UUID().uuidString).pdf")
    }

    // MARK: Flag-Semantik (§25, V2-11)

    @Test func coreFlagsSindStandardmaessigAn() {
        #expect(CompressionOptions().featureFlags.candidateEngine)
        #expect(CompressionOptions.smart.featureFlags.candidateEngine)
        #expect(CompressionFeatureFlags().candidateEngine)
        // Advanced-Flag bleibt AUS (§26/§27): MRC wird separat zertifiziert.
        #expect(!CompressionFeatureFlags().mrc)
    }

    @Test func photoTrialIsOptInAndOldOptionsDecode() throws {
        #expect(ImageCompressionOptions.smart.experimentalSmartPhotoCandidates != true)
        let encoded = try JSONEncoder().encode(ImageCompressionOptions.smart)
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "experimentalSmartPhotoCandidates")
        let decoded = try JSONDecoder().decode(ImageCompressionOptions.self,
            from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded == .smart)
        var trial = decoded
        trial.experimentalSmartPhotoCandidates = true
        #expect(try JSONDecoder().decode(ImageCompressionOptions.self,
            from: JSONEncoder().encode(trial)) == trial)
    }

    @Test func photoTrialRespectsPlacementAndPreset() {
        func resource(_ points: [Double], width: Int = 2000) -> PDFImageResource {
            PDFImageResource(objectID: PDFObjectID(objectNumber: 1, generation: 0),
                width: width, height: width, bitsPerComponent: 8, colorSpace: .deviceGray,
                filters: [.flate], unknownFilters: [], hasSoftMask: false,
                hasExplicitMask: false, isImageMask: false, encodedByteCount: 100000,
                placements: points.enumerated().map { index, size in
                    PDFImagePlacement(pageIndex: index, resourceName: "Im1",
                        placedWidthPoints: size, placedHeightPoints: size)
                })
        }
        let target = PixelSize(width: 300, height: 300)
        var options = ImageCompressionOptions.smart
        #expect(CandidateGenerator.smartPhotoIntermediate(resource: resource([72]),
            target: target, options: options) == nil)
        options.experimentalSmartPhotoCandidates = true
        #expect(CandidateGenerator.smartPhotoIntermediate(resource: resource([72]),
            target: target, options: options) == PixelSize(width: 600, height: 600))
        #expect(CandidateGenerator.smartPhotoIntermediate(resource: resource([72, 144]),
            target: target, options: options) == PixelSize(width: 1200, height: 1200))
        #expect(CandidateGenerator.smartPhotoIntermediate(resource: resource([]),
            target: target, options: options) == nil)
        #expect(CandidateGenerator.smartPhotoIntermediate(resource: resource([], width: 10000),
            target: target, options: options) == nil)
        #expect(CandidateGenerator.smartPhotoIntermediate(resource: resource([72], width: 500),
            target: target, options: options) == nil)
        options = .quality
        options.experimentalSmartPhotoCandidates = true
        #expect(CandidateGenerator.smartPhotoIntermediate(resource: resource([72]),
            target: target, options: options) == nil)
    }

    @Test(.hangGuard) func standardOptionenFahrenDieCandidateEngine() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: .smart)
        // V2-11: Der Default-Plan IST der Candidate-Plan (traceVersion 2).
        #expect(!planned.plan.candidateSets.isEmpty)
        #expect(planned.plan.decisions.count == planned.plan.actions.count)
        #expect(planned.plan.traceVersion == 2)
    }

    @Test(.hangGuard) func candidatePfadSetztTraceVersion2() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.candidateOptions())
        #expect(!planned.plan.candidateSets.isEmpty)
        #expect(planned.plan.decisions.count == planned.plan.actions.count)
        #expect(planned.plan.traceVersion == 2)
        #expect(planned.plan.goal == .balanced)
    }

    // MARK: KEEP@0-Invarianten (§9.1)

    @Test(.hangGuard) func keepIstImmerErsterKandidatMitNullkosten() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        let out = Self.tempURL("keep0")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: Self.candidateOptions())
        let set = try #require(outcome.plan.candidateSets.first)
        let keep = try #require(set.keepCandidate)
        let resource = outcome.resources.first!
        #expect(set.candidates.first?.id == keep.id)
        // KEEP kostet, was im fertigen Dokument daraus wird (2026-10-01):
        // die Größe nach dem verlustfreien Repack, nie mehr als das Original.
        let pixels = LibQPDFPixelSource(document: try PDFCoreDocument(path: url.path))
        #expect(keep.metrics.encodedBytes
                == CompressionPlanner.repackBarrier(resource: resource, pixels: pixels))
        #expect(keep.metrics.encodedBytes <= resource.encodedByteCount)
        #expect(keep.metrics.globalSSIM == nil)
        #expect(keep.metrics.p05TileSSIM == nil)
        #expect(keep.metrics.expectedRuntimeMs == 0)
        #expect(keep.metrics.expectedPeakWorkingBytes == 0)
        #expect(keep.isLossless)
        #expect(keep.metrics.qualityScore == 1.0)
        // KEEP-Kandidat gehört zur Ressource.
        #expect(set.candidates.allSatisfy { $0.objectID == resource.objectID })
    }

    // MARK: Photo (§9.2–9.4)

    @Test(.hangGuard) func fotoBekommtJpegKandidatenMitMetriken() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        let out = Self.tempURL("foto")
        defer { try? FileManager.default.removeItem(at: out) }
        let options = Self.candidateOptions()
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: options)
        let set = try #require(outcome.plan.candidateSets.first)
        // KEEP + mindestens ein verlustbehafteter JPEG-Kandidat.
        let jpegCandidates = set.candidates.filter {
            if case .jpeg = $0.kind { return true }
            return false
        }
        #expect(!jpegCandidates.isEmpty, "Kein JPEG-Kandidat erzeugt")
        for candidate in jpegCandidates {
            #expect(!candidate.isLossless)
            #expect(candidate.metrics.encodedBytes > 0)
            #expect(candidate.metrics.globalSSIM != nil,
                    "JPEG-Kandidat ohne SSIM-Messung")
            // Never-Grow: nur Kandidaten unterhalb der Originalbytes.
            #expect(candidate.metrics.encodedBytes
                    < outcome.resources.first!.encodedByteCount)
            if case .jpeg(_, let quality, _, _) = candidate.kind {
                #expect(quality >= (options.image.qualityLadder.min() ?? 0)
                        && quality <= (options.image.qualityLadder.max() ?? 1),
                        "Qualität \(quality) außerhalb des Smart-Fensters")
            }
        }
        #expect(set.candidates.count <= CandidateGenerator.maximumCandidatesPerImage)
    }

    /// Oversized Foto: die §9.4-Leiter greift (native/1.25×/Ziel/0.85×) und
    /// mehrere Zielauflösungen tauchen in den Kandidaten auf.
    @Test(.hangGuard) func aufloesungsleiterSetztSichDurch() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.candidateOptions())
        let set = try #require(planned.plan.candidateSets.first)
        var widths = Set<Int>()
        for candidate in set.candidates {
            if case .jpeg(let target, _, _, _) = candidate.kind {
                widths.insert(target.width)
            }
        }
        // Zielauflösung (DPI-Regel) UND mindestens eine Zusatzstufe.
        #expect(widths.count >= 2,
                "Auflösungsleiter lief nur eine Stufe: \(widths.sorted())")
    }

    /// §9.4 Small-Preset: die Leiter ist 144/110/96 DPI – bewusst OHNE
    /// Native-Stufe, nicht unter die Floor außerhalb der Politik.
    @Test(.hangGuard) func smallPresetLäuftUeberDpiStufen() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(
            inputURL: url,
            options: Self.candidateOptions(CompressionOptions(image: .small)))
        let set = try #require(planned.plan.candidateSets.first)
        #expect(planned.plan.goal == .smallest)
        var widths = Set<Int>()
        for candidate in set.candidates {
            if case .jpeg(let target, _, _, _) = candidate.kind {
                widths.insert(target.width)
            }
        }
        #expect(!widths.isEmpty, "Small erzeugt keine JPEG-Kandidaten")
        // Keine Native-Stufe: alle Kandidaten sind deutlich unter 2400 px.
        #expect(widths.allSatisfy { $0 < 2400 },
                "Small darf die Native-Stufe nicht führen: \(widths.sorted())")
    }

    // MARK: Graphics (§9.5)

    @Test(.hangGuard) func grafikBekommtFlateKandidatenKeinJpeg() throws {
        // 1600 px auf 400 pt ≙ 288 DPI – über Smart-Ziel × Toleranz
        // (220 × 1,15 = 253). Die früheren 1400 px (252 DPI) lagen nach der
        // Umstellung auf 220 DPI (2026-10-09) innerhalb der Toleranz und
        // wurden regelkonform nicht verkleinert.
        let url = try PDFFixtures.screenshotLikePDF(pixels: 1600)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.candidateOptions())
        let set = try #require(planned.plan.candidateSets.first)
        let kinds = set.candidates.map(\.kind)
        #expect(kinds.contains { if case .flate = $0 { return true }; return false })
        #expect(!kinds.contains { if case .jpeg = $0 { return true }; return false },
                "Grafik ohne aggressiveGraphics darf keinen JPEG-Kandidaten haben")
        for candidate in set.candidates {
            if case .flate(let target, let grayscale, let predictor) = candidate.kind {
                #expect(predictor, "Flate-Kandidat ohne Prädiktor")
                #expect(!grayscale)
                #expect(!candidate.isLossless)
                #expect(candidate.metrics.gateMeasurement != nil)
                #expect(target.width < 1600, "Zielauflösung greift nicht")
            }
        }
    }

    /// Befund A5 (Review 2026-10-09), „Grafikflächen als JPEG" im Custom-Reiter.
    /// Vorher aufgeschriebene Fehlermöglichkeiten:
    ///  1. `raised(to:cap:)` SENKT eine vom Nutzer gewählte Qualität über dem
    ///     Deckel (0,92 → 0,82) – „angehoben" darf nie heißen „abgesenkt".
    ///  2. Zwischen Ziel × 1,15 und Ziel × 1,5 liefert die Einstellung AN gar
    ///     keinen Kandidaten (KEEP), AUS dagegen den verlustfreien Resize –
    ///     Einschalten lässt die Datei größer.
    ///  3. Die Anhebung für Grafiken unterhalb des Deckels bleibt bestehen
    ///     (0,72 → 0,82), sonst wäre die Grafikpolitik abgeschafft.
    @Test(.hangGuard) func grafikJpegSenktNieDieGewaehlteQualitaet() throws {
        // 1600 px auf 400 pt ≙ 288 DPI, bei Ziel 150 klar oversized (> 225).
        let url = try PDFFixtures.screenshotLikePDF(pixels: 1600)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(
            inputURL: url,
            options: Self.candidateOptions(CompressionPresetFactory.custom(
                dpi: 150, quality: 0.92, aggressiveGraphics: true)))
        let set = try #require(planned.plan.candidateSets.first)
        let qualities = set.candidates.compactMap { c -> Double? in
            if case .jpeg(_, let q, _, _) = c.kind { return q }
            return nil
        }
        #expect(!qualities.isEmpty, "Grafik-JPEG-Kandidat fehlt")
        #expect(qualities.allSatisfy { $0 >= 0.92 },
                "Gewählte Qualität 0,92 wurde abgesenkt: \(qualities)")

        // 3: unterhalb des Deckels wird weiter angehoben.
        let lifted = JPEGQualityPolicy.fixed(quality: 0.72).raised(to: 0.82, cap: 0.82)
        #expect(lifted == .fixed(quality: 0.82))
    }

    @Test(.hangGuard) func grafikJpegAnLiefertImToleranzfensterNichtWenigerAlsAus() throws {
        // 1080 px auf 400 pt ≙ 194 DPI: über Ziel × 1,15 (172,5), unter Ziel × 1,5 (225).
        let url = try PDFFixtures.screenshotLikePDF(pixels: 1080)
        defer { try? FileManager.default.removeItem(at: url) }
        func kinds(aggressive: Bool) throws -> [CandidateKind] {
            let planned = try CompressionPipeline.plan(
                inputURL: url,
                options: Self.candidateOptions(CompressionPresetFactory.custom(
                    dpi: 150, quality: 0.85, aggressiveGraphics: aggressive)))
            return planned.plan.candidateSets.first?.candidates.map(\.kind) ?? []
        }
        let off = try kinds(aggressive: false)
        let on = try kinds(aggressive: true)
        #expect(off.contains { if case .flate = $0 { return true }; return false },
                "AUS: verlustfreier Resize fehlt")
        #expect(on.contains { if case .flate = $0 { return true }; return false },
                "AN: im Toleranzfenster muss der verlustfreie Resize wie bei AUS vorliegen: \(on)")
    }

    /// Laufzeit (Sichtabnahme 2026-10-12): Die Smart-Leiter kodierte ein
    /// 12-MP-Foto dreimal in voller Auflösung, obwohl die Zielstufe längst
    /// einen kleineren Kandidaten hatte. Fehlermöglichkeiten:
    ///  1. Native/1,25×-Stufen werden weiter kodiert, obwohl die Zielstufe
    ///     bestanden hat (keine Beschleunigung).
    ///  2. Die Zielstufe fehlt im Set (Sprung kaputt).
    ///  3. Scheitert die kleine Stufe, muss die größere weiter geprüft werden
    ///     (Kontrolle über Klein auf einer Grafik mit Katastrophen-Floor ist
    ///     in MeasurementFilterRegressionE2ETests abgedeckt; hier: kein
    ///     Skip ohne bestandene kleinere Stufe).
    @Test(.hangGuard) func smartLeiterKodiertKeineDominiertenGrossenStufen() throws {
        let url = try PDFFixtures.photoAtWidth(4000)   // 612 pt → ≈ 470 DPI
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.candidateOptions(.smart))
        let set = try #require(planned.plan.candidateSets.first)
        let widths = Set(set.candidates.compactMap { c -> Int? in
            if case .jpeg(let t, _, _, _) = c.kind { return t.width }
            return nil
        })
        #expect(!widths.isEmpty)
        // Ziel 220 DPI auf 8,5 Zoll = 1870 px; 1,25× = 2338; 0,85× = 1590.
        let target = Int((8.5 * ImageCompressionOptions.smart.targetDPI).rounded(.up))
        #expect(widths.contains { abs($0 - target) <= 2 || abs($0 - Int(Double(target) * 0.85)) <= 2 },
                "Zielstufe fehlt: \(widths.sorted())")
        #expect(!widths.contains(4000), "Native Stufe wurde trotz bestandener Zielstufe kodiert: \(widths.sorted())")
    }

    // MARK: Custom-Reiter (Review 2026-10-09, Befunde B1/B3/B7)

    /// DeviceRGB-Foto, verlustfrei (Flate) gespeichert, INNERHALB des
    /// DPI-Budgets. Vorher blieb der Qualitätsregler bei fester Qualität
    /// für solche Bilder wirkungslos (`withinBudget`, Befund B1).
    static func flatePhotoWithinBudget() throws -> URL {
        let w = 600, h = 450
        var raw = Data(count: w * h * 3)
        raw.withUnsafeMutableBytes { ptr in
            let p = ptr.bindMemory(to: UInt8.self)
            var seed: UInt32 = 12345
            for y in 0..<h { for x in 0..<w {
                seed = seed &* 1664525 &+ 1013904223
                let noise = Int(seed >> 28)
                let i = (y * w + x) * 3
                p[i] = UInt8(min(255, (x * 255 / w) + noise))
                p[i + 1] = UInt8(min(255, (y * 255 / h) + noise))
                p[i + 2] = UInt8(min(255, ((x + y) * 255 / (w + h)) + noise))
            } }
        }
        let flate = try #require(ImageProcessor.flate(raw))
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(w)/Height \(h)"
                + "/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/FlateDecode",
            data: flate)
        // 600 px auf 400 pt ≙ 108 DPI – unter jedem Custom-Ziel ≥ 110.
        let content = b.addStream(dictionary: "", content: "q 400 0 0 300 100 300 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</XObject<</Im0 \(image) 0 R>>>>/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "flate-photo-budget")
    }

    /// Fehlermöglichkeiten: (1) kein JPEG-Kandidat → Regler wirkungslos;
    /// (2) Kandidat nicht auf Originalgröße (hochgerechnet oder verkleinert
    /// trotz Budget); (3) Kandidat trägt nicht die gewählte Qualität.
    @Test(.hangGuard) func festeQualitaetKodiertFlateFotoImBudgetNeu() throws {
        let url = try Self.flatePhotoWithinBudget()
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(
            inputURL: url,
            options: Self.candidateOptions(CompressionPresetFactory.custom(dpi: 150, quality: 0.6)))
        let set = try #require(planned.plan.candidateSets.first)
        let jpegs = set.candidates.compactMap { c -> (PixelSize, Double)? in
            if case .jpeg(let t, let q, _, _) = c.kind { return (t, q) }
            return nil
        }
        #expect(!jpegs.isEmpty, "Kein JPEG-Kandidat – Qualitätsregler wirkungslos: \(set.candidates.map(\.kind))")
        #expect(jpegs.allSatisfy { $0.0 == PixelSize(width: 600, height: 450) },
                "Kandidat nicht auf Originalgröße: \(jpegs.map(\.0))")
        #expect(jpegs.allSatisfy { $0.1 == 0.6 }, "Qualität: \(jpegs.map(\.1))")
    }

    /// Befund B3: Graustufen übersprang ICC-basierte Nicht-JPEG-Bilder.
    /// Fehlermöglichkeiten: (1) Flate-Kandidat bleibt dreikanalig; (2) kein
    /// Kandidat; (3) Grau greift auch, wenn NICHT angefordert.
    @Test(.hangGuard) func graustufenWirktAufIccFlateBilder() throws {
        let url = try PDFFixtures.iccProfilePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        func grayFlags(grayscale: Bool) throws -> [Bool] {
            let planned = try CompressionPipeline.plan(
                inputURL: url,
                options: Self.candidateOptions(CompressionPresetFactory.custom(
                    dpi: 150, quality: 0.85, grayscale: grayscale)))
            let set = try #require(planned.plan.candidateSets.first)
            return set.candidates.compactMap { c -> Bool? in
                if case .flate(_, let g, _) = c.kind { return g }
                return nil
            }
        }
        let on = try grayFlags(grayscale: true)
        #expect(!on.isEmpty, "Kein Flate-Kandidat für das ICC-Bild")
        #expect(on.allSatisfy { $0 }, "Graustufen angefordert, Kandidat bleibt farbig")
        let off = try grayFlags(grayscale: false)
        #expect(off.allSatisfy { !$0 }, "Graustufen nicht angefordert, Kandidat ist grau")
    }

    /// Befund B7: „S/W-Scans verlustfrei" AUS (`.keep`) übersprang die
    /// Bilevel-Erkennung; exakt zweiwertige 8-bit-Scans liefen in den
    /// Foto-/Grafikpfad. `.keep` heißt: unangetastet – 1-bit UND 8-bit.
    /// Fehlermöglichkeiten: (1) 8-bit-Zweiwert-Scan bekommt JPEG/Flate-
    /// Kandidaten; (2) 1-bit-Scan wird trotz `.keep` in den Race geschickt;
    /// (3) `.auto` verliert den Race (Regression der Standardpolitik).
    @Test(.hangGuard, arguments: [true, false])
    func bilevelKeepLaesstScansUnangetastet(eightBit: Bool) throws {
        let url = eightBit
            ? try PDFFixtures.nearBilevelGrayPDF(pixels: 800, rows: 600)
            : try PDFFixtures.bilevelScanPDF(pixels: 900, rows: 1200, placedPoints: 144)
        defer { try? FileManager.default.removeItem(at: url) }
        var keep = CompressionPresetFactory.custom(dpi: 150, quality: 0.85)
        keep.image.bilevelPolicy = .keep
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.candidateOptions(keep))
        let transformed = planned.plan.transformedActions
        #expect(transformed.isEmpty, "`.keep` hat verändert: \(transformed)")
        let reasons = planned.plan.actions.compactMap { a -> KeepReason? in
            if case .keep(_, let r, _) = a { return r }
            return nil
        }
        #expect(reasons.contains(.bilevelKept), "Grund: \(reasons)")

        var auto = keep
        auto.image.bilevelPolicy = .auto
        let raced = try CompressionPipeline.plan(inputURL: url,
                                                 options: Self.candidateOptions(auto))
        #expect(raced.plan.candidateSets.first.map { !$0.candidates.isEmpty } == true,
                "`.auto` erzeugt keine Bilevel-Kandidaten mehr")
    }

    // MARK: Bilevel (§9.7)

    @Test(.hangGuard) func bilevelRaceWirdZuKandidatenset() throws {
        let url = try PDFFixtures.bilevelScanPDF(pixels: 900, rows: 1200,
                                                 placedPoints: 144)
        defer { try? FileManager.default.removeItem(at: url) }
        let out = Self.tempURL("bilevel")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: Self.candidateOptions())
        let set = try #require(outcome.plan.candidateSets.first)
        // Der Race-Sieger erscheint als Codec-Kandidat und ist kleiner als
        // das Original; KEEP bleibt trotzdem im Set (§5.6).
        let codecCandidates = set.candidates.filter {
            switch $0.kind {
            case .ccittG4, .jbig2Lossless: return true
            default: return false
            }
        }
        #expect(codecCandidates.count == 1, "Race-Sieger fehlt im Set")
        #expect(codecCandidates.first?.metrics.encodedBytes
                ?? Int.max < outcome.resources.first!.encodedByteCount)
        #expect(codecCandidates.first?.isLossless == true)
        #expect(set.keepCandidate != nil)
    }

    // MARK: CMYK (§9.8)

    @Test(.hangGuard) func cmykVerlustfreiImSmartPfad() throws {
        let url = try PDFFixtures.cmykPhotoPDF(pixelWidth: 2000)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.candidateOptions())
        let set = try #require(planned.plan.candidateSets.first)
        let kinds = set.candidates.map(\.kind)
        #expect(kinds.contains { if case .flate = $0 { return true }; return false })
        #expect(!kinds.contains { if case .cmykJPEG = $0 { return true }; return false },
                "Smart bleibt verlustfrei – kein YCCK-Kandidat")
    }

    @Test(.hangGuard) func cmykVerlustbehaftetImQualityPfad() throws {
        let jpeg = try CMYKLossyTests.smoothCmykJpeg(2000, quality: 0.95)
        let url = try CMYKLossyTests.cmykJpegPDF(jpeg: jpeg, pixels: 2000,
                                                 placedPoints: 150)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(
            inputURL: url,
            options: Self.candidateOptions(CompressionOptions(image: .quality)))
        let set = try #require(planned.plan.candidateSets.first)
        let kinds = set.candidates.map(\.kind)
        // YCCK-Kandidat UND die 6b-Repack-Barriere als verlustfreier Kandidat.
        #expect(kinds.contains { if case .cmykJPEG = $0 { return true }; return false })
        #expect(kinds.contains { if case .jpegRepack = $0 { return true }; return false })
        let cmyk = try #require(set.candidates.first {
            if case .cmykJPEG = $0.kind { return true }
            return false
        })
        let repack = try #require(set.candidates.first {
            if case .jpegRepack = $0.kind { return true }
            return false
        })
        #expect(cmyk.metrics.encodedBytes < repack.metrics.encodedBytes,
                "YCCK-Kandidat hat die 6b-Barriere nicht unterboten")
        #expect(!cmyk.isLossless)
        #expect(repack.isLossless)
    }

    // MARK: JPX-Input (§9.9)

    @Test(.hangGuard) func jpxInputBekommtKandidatenAusBestehendenPfaden() throws {
        let url = try PDFFixtures.jpxImagePDF(kind: .photoRGBLossy, placedWidth: 60)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.candidateOptions())
        let set = try #require(planned.plan.candidateSets.first)
        // KEEP + Kandidaten aus dem regulären photo-Pfad (JPEG).
        #expect(set.candidates.contains { if case .jpeg = $0.kind { return true }; return false },
                "JPX-Foto erzeugt keinen JPEG-Kandidaten")
        // Kein JPX-Output: Alle Kandidaten sind keep/jpeg/flate.
        for candidate in set.candidates {
            switch candidate.kind {
            case .keep, .jpeg, .flate:
                continue
            default:
                Issue.record("Unerwarteter Kandidat für JPX-Input: \(candidate.kind)")
            }
        }
    }

    // MARK: Budget und Struktur-Keeps

    @Test(.hangGuard) func smartErhaeltJPEGInnerhalbDesAufloesungsbudgets() throws {
        // 72-DPI-DCT-Bild: kein verlustbehafteter Generationswechsel ohne Resize.
        let url = try PDFFixtures.photoHeavyPDF(pixels: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.candidateOptions())
        let set = try #require(planned.plan.candidateSets.first)
        #expect(set.keepCandidate != nil)
        #expect(set.candidates.count == 1)
        #expect(set.candidates.first?.kind.isKeep == true)
        #expect(planned.plan.actions.first?.transformsImage == false)
    }

    @Test(.hangGuard) func festeQualitaetImBudgetBleibtKeep() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = Self.candidateOptions()
        options.image.qualityPolicy = .fixed(quality: 0.75)
        let planned = try CompressionPipeline.plan(inputURL: url, options: options)
        let set = try #require(planned.plan.candidateSets.first)
        #expect(set.candidates.count == 1)
        #expect(set.candidates.first?.kind.isKeep == true)
        #expect(planned.plan.actions.first?.transformsImage == false)
    }

    @Test(.hangGuard) func zuKleineBilderBleibenKeep() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 60)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.candidateOptions())
        let set = try #require(planned.plan.candidateSets.first)
        #expect(set.candidates.count == 1)
        #expect(set.candidates.first?.kind.isKeep == true)
        #expect(planned.plan.decisions.first?.reason.contains("zu klein") == true)
    }

    /// Jedes Set jeder Fixturklasse enthält KEEP und bleibt im Budget.
    @Test(.hangGuard) func jedesSetHatKeepUndBleibtImBudget() throws {
        let urls = [
            try PDFFixtures.photoAtWidth(2400),
            try PDFFixtures.screenshotLikePDF(pixels: 1400),
            try PDFFixtures.cmykPhotoPDF(pixelWidth: 2000),
            try PDFFixtures.jpxImagePDF(kind: .photoRGBLossy, placedWidth: 60),
        ]
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        for url in urls {
            let planned = try CompressionPipeline.plan(inputURL: url,
                                                       options: Self.candidateOptions())
            for set in planned.plan.candidateSets {
                #expect(set.keepCandidate != nil,
                        "\(set.resourceID) ohne KEEP")
                #expect(set.candidates.first?.kind.isKeep == true,
                        "\(set.resourceID): KEEP nicht an Position 0")
                #expect(set.candidates.count
                        <= CandidateGenerator.maximumCandidatesPerImage)
            }
        }
    }

    // MARK: ResourceDecision (§5.7)

    @Test(.hangGuard) func entscheidungTrägtRückstufungsleiter() throws {
        let jpeg = try CMYKLossyTests.smoothCmykJpeg(2000, quality: 0.95)
        let url = try CMYKLossyTests.cmykJpegPDF(jpeg: jpeg, pixels: 2000,
                                                 placedPoints: 150)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(
            inputURL: url,
            options: Self.candidateOptions(CompressionOptions(image: .quality)))
        let decision = try #require(planned.plan.decisions.first)
        let set = try #require(planned.plan.candidateSets.first)
        // Die Leiter endet mit KEEP und beginnt mit dem aggressivsten
        // (verlustbehafteten) Kandidaten.
        #expect(decision.candidateIDsBySafety.count == set.candidates.count)
        #expect(decision.candidateIDsBySafety.last == set.keepCandidate?.id)
        #expect(decision.selectedCandidateID == set.candidates
            .min(by: { $0.metrics.encodedBytes < $1.metrics.encodedBytes })?.id)
        #expect(decision.classification != .unknown)
    }
}
