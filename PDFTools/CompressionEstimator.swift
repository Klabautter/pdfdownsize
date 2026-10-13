import Foundation

struct CompressionEstimate {
    let pageCount: Int
    let imageCount: Int
    let oversizedCount: Int
    let maxEffectiveDPI: Double?
    let lowBytes: Int64
    let pointBytes: Int64
    let highBytes: Int64
    let originalBytes: Int64
    let potential: Potential
    /// Phase V2-10 (§16.2) – Anzahl der im Accurate-Modus gemessenen
    /// (sample-encodierten) Streams; 0 im Fast-Modus. Telemetrie.
    var sampledStreamCount: Int = 0

    enum Potential {
        case high
        case medium
        case low
    }

    var savingsRatio: Double {
        guard originalBytes > 0 else { return 0 }
        return max(0, 1 - Double(pointBytes) / Double(originalBytes))
    }

    static func classifyPotential(savings: Double) -> Potential {
        if savings > 0.25 { return .high }
        if savings > 0.08 { return .medium }
        return .low
    }
}

/// Masterplan Schritt 7 / Finding 11 – der Estimator LIEST den Plan.
///
/// Vorher gab es zwei Entscheidungsmaschinen: Der Estimator rechnete mit
/// `targetDPI * tolerance`, der Compressor mit `targetDPI * 1.5`. Schätzung und
/// Ergebnis mussten auseinanderlaufen.
///
/// Jetzt entscheidet ausschließlich der `CompressionPlanner`. Der Estimator
/// modelliert nur noch, was er darf: Stream- und Container-Overhead. Er trifft
/// KEINE Bildentscheidungen mehr.
///
/// Wie der Punktwert entsteht (Band-Schätzung, keine Punktpräzision):
/// geplante Bildbytes (transformierte mit Plangröße, behaltene unverändert)
/// minus dem, was `--recompress-flate` an behaltenen Flate-Streams nachpackt
/// (`keptFlateRetention`), minus dem erwarteten Gewinn des verlustfreien
/// JPEG-Repacks an behaltenen DCT-Streams (`keptDCTRepackSaving`), plus dem
/// Strukturanteil nach `structureRetention`, minus der GEMESSENEN Dedup-
/// Ersparnis (Vorschau des verlustfreien Dedup am Wegwerf-Handle). Um diesen
/// Punkt liegt das asymmetrische Unsicherheitsband [0.55, 1.25] – asymmetrisch,
/// weil der Struktur-Pass gemessen eher MEHR herausholt als das Modell
/// annimmt, fast nie weniger.
enum CompressionEstimator {

    /// Anteil eines BEHALTENEN Flate-Bildstreams, der nach dem Struktur-Pass
    /// übrig bleibt. `--recompress-flate --compression-level=9` packt solche
    /// Streams nach, auch wenn der Planner das Bild nicht angefasst hat –
    /// genau das fehlte im ersten Modell und erklärte den Ausreißer bei
    /// `scan-like.pdf` (geschätzt 104 KB, tatsächlich 24 KB).
    static let keptFlateRetention = 0.85

    /// Phase 1b-Rückführung – erwartete relative Ersparnis des verlustfreien
    /// JPEG-Repacks auf behaltenen DCT-Streams. Die Messung der Roadmap Phase 1
    /// liegt bei 3–15 % der JPEG-Bytes; bereits progressive/optimierte Streams
    /// überspringt der Repack selbst. Hier bewusst der untere Rand als
    /// Punktwert – die Streuung, und der Unterschied zwischen progressivem
    /// und reinem optimize-only im Kompatibilitätsmodus, schluckt das Band.
    static let keptDCTRepackSaving = 0.05

    /// Unsicherheitsband um den Punktwert.
    ///
    /// Asymmetrisch, weil die Messung eine klare Richtung zeigt: Der
    /// Struktur-Pass holt eher mehr heraus als das Modell erwartet, fast nie
    /// weniger. Alle 63 Messungen des ersten Laufs lagen auf derselben Seite.
    static let lowerBandFactor = 0.55
    static let upperBandFactor = 1.25

    // MARK: Phase V2-10 (§16.2) – Accurate-Band
    //
    // Nach dem Sample-Encode der größten behaltenen Streams sind deren Bytes
    // GEMESSEN statt modelliert; die verbleibende Unsicherheit liegt in den
    // unsampled Kleinströmen und im Strukturanteil. Das Band fällt deshalb
    // enger aus („hohe Sicherheit“), bleibt aber asymmetrisch in derselben
    // Richtung wie das Fast-Band.
    static let accurateLowerBandFactor = 0.80
    static let accurateUpperBandFactor = 1.12

    /// Schätzmodus (§16). `.fast` liest Plan + Kurven (bestehendes Verhalten);
    /// `.accurate` misst zusätzlich die größten behaltenen Streams per
    /// Sample-Encode und zieht das Band zusammen. Der Modus ändert NIE den
    /// Plan – er ist reine Messung über denselben Kandidatenraum.
    enum EstimateMode: Sendable {
        case fast
        case accurate
    }

    /// Budget des Sample-Encodes in Sekunden (§16.2: „keine volle Datei“).
    static let accurateSampleBudgetSeconds: Double = 2.0

    /// Kleinste Streamgröße, ab der sich ein Sample lohnt – darunter dominiert
    /// der Container-Overhead, dieselbe Schwelle wie `minimumTransformableEdge`
    /// im Planner (96 px-Logik, hier in Bytes).
    static let accurateMinimumSampleBytes = 4096

    /// §16.2 – wie viele der größten behaltenen Streams gemessen werden.
    static let accurateSampleLimit = 3

    /// Schätzt anhand eines fertigen Plans. Das ist der Pfad, der Parität
    /// garantiert: gleicher Plan, gleiche Aktionen, gleiche Bytes.
    ///
    /// Reine Summierung – der Plan trägt für jedes Bild sowohl die Ausgangs-
    /// als auch die erwartete Größe, also ist keine Verteilungsannahme nötig.
    /// Der `structureRetention`-Default ist mit dem Fixed-Bytes-Modell des
    /// Zielgrößen-Optimators gekoppelt (V2-6, §12.3/§16 – §4 Prinzip 3).
    static func estimate(plan: CompressionPlan, pageCount: Int,
                         maxEffectiveDPI: Double? = nil,
                         structureRetention: Double
                             = TargetSizeOptimizer.structureFactor,
                         recompressibleKeptBytes: Int = 0,
                         repackableDCTBytes: Int = 0,
                         dedupEstimatedBytes: Int = 0) -> CompressionEstimate {
        let original = Int64(plan.originalDocumentBytes)
        let originalImageBytes = Int64(plan.originalImageBytes)

        // Transformierte Bilder bringen ihre geplante Größe mit; behaltene
        // ihre bisherige – abzüglich dessen, was der Struktur-Pass an
        // verlustfrei kodierten Streams noch nachpackt, und abzüglich des
        // erwarteten Repack-Gewinns an behaltenen DCT-Streams.
        var plannedImageBytes = plan.actions.reduce(Int64(0)) {
            $0 + Int64($1.resultingEncodedBytes)
        }
        plannedImageBytes -= Int64(Double(recompressibleKeptBytes)
                                   * (1 - keptFlateRetention))
        plannedImageBytes -= Int64(Double(repackableDCTBytes) * keptDCTRepackSaving)
        plannedImageBytes = max(plannedImageBytes, 0)

        // Alles, was kein Bildstream ist: Seitenbäume, Content-Streams,
        // Schriften, Navigation. Wie stark der Struktur-Pass das verdichtet,
        // hängt davon ab, was schon komprimiert ist (siehe StructureProfile).
        let structural = max(original - originalImageBytes, 0)
        // Die Dedup-Vorschau liefert gemessene Duplikatbytes (Schätzung des
        // C-Kerns). Sie betreffen Bild-, Content- und sonstige Streams
        // gleichermaßen und werden daher vom Gesamtpunkt abgezogen – nie
        // unter null.
        let point = max(plannedImageBytes
                            + Int64(Double(structural) * structureRetention)
                            - Int64(dedupEstimatedBytes),
                        0)

        let savings = original > 0 ? max(0, 1 - Double(point) / Double(original)) : 0

        return CompressionEstimate(
            pageCount: pageCount,
            imageCount: plan.actions.count,
            oversizedCount: plan.transformedActions.count,
            maxEffectiveDPI: maxEffectiveDPI,
            lowBytes: Int64(Double(point) * lowerBandFactor),
            pointBytes: point,
            highBytes: Int64(Double(point) * upperBandFactor),
            originalBytes: original,
            potential: CompressionEstimate.classifyPotential(savings: savings))
    }

    // MARK: - Schnellschätzung (Vorschau vor dem Lauf)
    //
    // Die planbasierte Schätzung unten fährt die komplette Kandidatensuche
    // (Dekodieren, Kodieren, Qualitätsmessung) und brauchte damit 45–80 %
    // der eigentlichen Kompressionszeit – für eine Vorschau zu teuer. Die
    // Schnellschätzung liest nur das Inventar (Codec, Bytes, Pixel,
    // Platzierung) und rechnet mit der Größenpolitik des Planners
    // (`plannedSize`, dieselbe Funktion) plus Byte-Kurven. Sie trifft keine
    // Bildentscheidung; entschieden wird weiter ausschließlich im Lauf.
    //
    // Kalibrierung 2026-09-29 (nach P0.1) auf dem Core-235-Lauf mit Smart,
    // 235/235 erfolgreich (benchmark/p01-photo-dpi/core235 + NASA-Nachlauf):
    // mittlerer |log|-Fehler 0,26 (Holdout 0,25), 87 % innerhalb Faktor 1,5,
    // 89 % der Ergebnisse im Band [0,6 · Punkt, 1,5 · Punkt].
    //
    // Nachkalibrierung 2026-10-13 (Sichtabnahme 2026-10-12, M3) auf dem
    // Core-235-Abschlusslauf vom 10.10. (compression-smoke/
    // 20261010-030021-core235-final, alle drei Stufen; eine Stichprobe von
    // 45 Läufen ergab am 13.10. dieselben Größen). Vorher lagen im Band:
    // Klein 109/235 (46 %), Smart 187/234 (80 %), Qualität 198/235 (84 %) –
    // das Modell kannte die Qualitätsstufe nicht, Graustufen-Scans waren
    // bei Smart 2× zu klein geschätzt, und große, stark komprimierte Fotos
    // (12 MP, < 0,25 Bit je Abtastwert) galten als Kartenkacheln.
    // Nachher: Klein 193/235 (82 %), Smart 213/234 (91 %), Qualität 214/235
    // (91 %); angepasst auf der Hälfte der Dateien, auf der anderen Hälfte
    // gleich gut (85 % / 91 % / 91 %). Mittlerer |log|-Fehler 0,33 / 0,24 /
    // 0,24. Nicht gelöst: Dokumente aus detailarmen Großfotos bei Qualität
    // (medium.pdf: geschätzt 5,6 MB, tatsächlich 1,3 MB).

    enum QuickModel {
        /// Bezugspunkt der Qualitätsterme: die unterste Stufe von Smart. Die
        /// Terme rechnen mit `Stufe / Bezug` (Klein 0,83 · Smart 1 · Qualität
        /// 1,42) – die unterste Stufe nennt der Planner (`qualityFloor`).
        static let referenceFloor = 0.60
        /// Bilevel (1 bpc): G4/JBIG2-Race.
        static let bilevelRetention = 0.03
        /// JPEG ohne Verkleinerung: verlustfreier Repack/Strukturgewinn;
        /// bei niedriger Stufe wird ein Teil doch neu kodiert.
        static let dctKeptRetention = 0.85
        static let dctKeptFloorExponent = -0.25
        /// JPEG-Quellen mit Verkleinerung, getrennt nach Bits je Abtastwert:
        /// hohe Bitrate = Foto (wird neu als JPEG kodiert und schrumpft mit
        /// der Pixelzahl), niedrige = stark komprimierte Grafik/Kartenkachel
        /// (verlustfrei verkleinert, schrumpft kaum).
        static let dctPhotoBitsPerSample = 0.25
        /// Ab dieser Pixelzahl ist ein JPEG ein Foto, auch bei niedriger
        /// Bitrate: Kartenkacheln sind klein, ein 12-MP-Handyfoto mit
        /// 0,2 Bit je Abtastwert ist keine Kachel.
        static let dctPhotoMinimumPixels = 2_000_000
        static let dctPhotoFactor = 0.3
        static let dctPhotoExponent = 0.5
        static let dctPhotoFloorExponent = 3.5
        static let dctGraphicsRetention = 0.5
        static let dctGraphicsFloorExponent = 5.0
        /// Verlustfrei kodierte Quellen: Bits je Pixel und Kanal trennen
        /// fotoartige (→ JPEG) von grafischen (→ Flate) Inhalten.
        static let photoBitsPerSample = 3.0
        static let photoFactor = 0.6
        static let photoExponent = 0.5
        static let graphicsExponent = 0.8
        /// Verlustfrei kodierte Grafik ohne Verkleinerung: Neupacken.
        static let graphicsKeptRetention = 0.7
        static let otherRetention = 0.9
        /// Scan-Seiten: ein 8-Bit-Raster füllt die Seite (≥ 100 DPI) UND die
        /// Seite zeichnet keinen eigenen sichtbaren Text (höchstens OCR mit
        /// Render-Modus 3). Die Kompression zerlegt sie per MRC; ohne Regel
        /// galten sie als unverkleinertes JPEG – Graustufen-Scans wurden
        /// ~3,8× zu groß geschätzt. Die reine Bildregel traf auch
        /// Vollseitenfotos (Fotoklasse im Band 96 % → 24 %), daher das
        /// Textsignal (`VisibleTextScanner`, 2026-10-01) und nur Graustufen.
        static let scanMinimumShortSidePoints = 500.0
        static let scanMinimumLongSidePoints = 700.0
        static let scanMinimumDPI = 100.0
        /// Anteil nach MRC je unterster Qualitätsstufe (Stützstellen der
        /// drei Stufen, dazwischen linear).
        static let scanGrayRetention: [(floor: Double, retention: Double)] =
            [(0.50, 0.08), (0.60, 0.28), (0.85, 0.50)]
        static let neutralChromaSamples = 3
        static let lowerBand = 0.6
        static let upperBand = 1.5
    }

    /// Schnellschätzung aus dem Inventar – für die Anzeige vor dem Lauf.
    static func quickEstimate(url: URL, options: CompressionOptions,
                              isCancelled: (() -> Bool)? = nil) -> CompressionEstimate? {
        guard let document = try? PDFCoreDocument(path: url.path),
              let resources = try? document.imageResources() else { return nil }
        if let isCancelled, isCancelled() { return nil }
        let original = Compressor.fileSize(of: url)
        let imageBytes = resources.reduce(Int64(0)) { $0 + Int64(max($1.encodedByteCount, 0)) }
        // Nicht-Bild-Anteil: für textlastige, nicht zu große Dateien GEMESSEN
        // (Probelauf des Struktur-Passes), sonst das Pauschalmodell.
        let measuredStructure = StructureTrial.retention(
            url: url, original: original, imageBytes: imageBytes,
            compatibility: options.compatibilityPolicy)
        if let isCancelled, isCancelled() { return nil }
        let structural = Double(max(original - imageBytes, 0))
            * (measuredStructure ?? min(document.structureProfile.structureRetention, 1.0))

        var imagesOut = 0.0
        var oversized = 0
        var visibleTextByPage: [Int: Bool] = [:]
        func pageHasVisibleText(_ pageIndex: Int) -> Bool {
            if let known = visibleTextByPage[pageIndex] { return known }
            // Unlesbarer Inhalt: konservativ wie eine Seite mit Text.
            let visible = (try? document.pageContentBytes(pageIndex: pageIndex))
                .map(VisibleTextScanner.hasVisibleText) ?? true
            visibleTextByPage[pageIndex] = visible
            return visible
        }
        // Farbneutralität von RGB-JPEG-Scans: höchstens drei Stichproben je
        // Dokument (je ein 64-px-Vorschaubild); weitere Kandidaten erben das
        // Mehrheitsurteil – ein 300-Seiten-Scan bleibt schnell.
        var neutralVotes: [Bool] = []
        lazy var pixels = LibQPDFPixelSource(document: document)
        func contentIsNeutral(_ resource: PDFImageResource) -> Bool {
            if resource.colorSpace.componentCount == 1 { return true }
            guard resource.colorSpace.componentCount == 3,
                  resource.terminalFilter == .dct else { return false }
            if neutralVotes.count >= QuickModel.neutralChromaSamples {
                return neutralVotes.filter { $0 }.count * 2 > neutralVotes.count
            }
            let verdict = pixels.rawImageData(for: resource)
                .flatMap(NeutralChromaProbe.isNeutral(jpeg:)) ?? false
            neutralVotes.append(verdict)
            return verdict
        }
        let isFixedQualityPolicy: Bool = {
            if case .fixed = options.image.qualityPolicy { return true }
            return false
        }()
        let floor = CompressionPlanner.qualityFloor(for: options.image)
        for resource in resources {
            let bytes = Double(max(resource.encodedByteCount, 0))
            let target = CompressionPlanner.plannedSize(for: resource, options: options.image)
            let ratio = target.map {
                Double($0.width * $0.height) / Double(max(resource.pixelCount, 1))
            } ?? 1.0
            if ratio < 0.999, resource.transformCapability.isSafe { oversized += 1 }
            // Das MRC-Scan-Modell gilt nicht für feste Nutzerparameter
            // (Custom fährt kein MRC, `CompressionOptions.make`) – vorher
            // schätzte es modusblind (Befund B5, Review 2026-10-09).
            let scanRetention = !isFixedQualityPolicy
                ? quickScanRetention(resource: resource, qualityFloor: floor,
                                     pageHasVisibleText: pageHasVisibleText,
                                     contentIsNeutral: contentIsNeutral)
                : nil
            imagesOut += bytes * (scanRetention
                ?? quickRetention(resource: resource, ratio: ratio, qualityFloor: floor))
        }

        let point = Int64(max(structural + imagesOut, 1).rounded())
        let clampedPoint = min(point, original)
        // Das breite Band gehört zum Bildmodell. Ein gemessener Strukturanteil
        // bekommt sein eigenes, enges Band – sonst verspricht die Anzeige bei
        // reinen Textdokumenten Ersparnisse, die es nicht gibt.
        let lowBytes: Int64
        let highBytes: Int64
        if measuredStructure != nil {
            lowBytes = Int64(imagesOut * QuickModel.lowerBand
                             + structural * StructureTrial.measuredLowerBand)
            highBytes = Int64(imagesOut * QuickModel.upperBand
                              + structural * StructureTrial.measuredUpperBand)
        } else {
            lowBytes = Int64(Double(point) * QuickModel.lowerBand)
            highBytes = Int64(Double(point) * QuickModel.upperBand)
        }
        let savings = original > 0 ? max(0, 1 - Double(clampedPoint) / Double(original)) : 0
        return CompressionEstimate(
            pageCount: document.pageCount,
            imageCount: resources.count,
            oversizedCount: oversized,
            maxEffectiveDPI: resources.compactMap(\.effectiveDPI).max(),
            lowBytes: min(lowBytes, original),
            pointBytes: clampedPoint,
            highBytes: min(highBytes, original),
            originalBytes: original,
            potential: CompressionEstimate.classifyPotential(savings: savings))
    }

    /// Erwarteter Anteil einer Scan-Seite nach MRC; nil = kein Scan-Raster.
    /// Dieselben Voraussetzungen wie die MRC-Provision, soweit sie ohne
    /// Seitenanalyse sichtbar sind; der Seiteninhalt wird nur für diese
    /// wenigen Kandidaten gelesen.
    static func quickScanRetention(resource: PDFImageResource,
                                   qualityFloor: Double,
                                   pageHasVisibleText: (Int) -> Bool,
                                   contentIsNeutral: (PDFImageResource) -> Bool) -> Double? {
        guard resource.transformCapability.isSafe, !resource.isImageMask,
              resource.bitsPerComponent == 8,
              resource.colorSpace.allowsLossyReplacement,
              resource.placements.count == 1,
              let placement = resource.placements.first,
              min(placement.placedWidthPoints, placement.placedHeightPoints)
                >= QuickModel.scanMinimumShortSidePoints,
              max(placement.placedWidthPoints, placement.placedHeightPoints)
                >= QuickModel.scanMinimumLongSidePoints,
              (resource.effectiveDPI ?? 0) >= QuickModel.scanMinimumDPI,
              !pageHasVisibleText(placement.pageIndex)
        else { return nil }
        // Nur grauer INHALT (Grau-Farbraum oder neutrales RGB-JPEG): Ein
        // farbiges Vollseitenbild ohne Text ist ohne Pixelanalyse nicht von
        // einem Foto zu unterscheiden (Wikimedia-Fotos im Core-235 wären
        // fälschlich auf 35 % geschätzt worden); Farbscans lagen ohne Regel
        // nur leicht daneben.
        return contentIsNeutral(resource) ? scanGrayRetention(qualityFloor: qualityFloor) : nil
    }

    /// Linear zwischen den Stützstellen, außerhalb der Randwert.
    static func scanGrayRetention(qualityFloor: Double) -> Double {
        let points = QuickModel.scanGrayRetention
        guard let first = points.first, let last = points.last else { return 1 }
        if qualityFloor <= first.floor { return first.retention }
        if qualityFloor >= last.floor { return last.retention }
        for (a, b) in zip(points, points.dropFirst()) where qualityFloor <= b.floor {
            let t = (qualityFloor - a.floor) / (b.floor - a.floor)
            return a.retention + t * (b.retention - a.retention)
        }
        return last.retention
    }

    /// Erwarteter Anteil der Bildbytes nach dem Lauf.
    static func quickRetention(resource: PDFImageResource, ratio: Double,
                               qualityFloor: Double) -> Double {
        guard resource.transformCapability.isSafe, !resource.isImageMask else { return 1 }
        if resource.bitsPerComponent == 1 { return QuickModel.bilevelRetention }
        let resized = ratio < 0.999
        let samples = Double(max(resource.pixelCount * max(resource.colorSpace.componentCount ?? 1, 1), 1))
        let bitsPerSample = Double(max(resource.encodedByteCount, 0)) * 8 / samples
        let level = qualityFloor / QuickModel.referenceFloor
        switch resource.terminalFilter {
        case .dct:
            let kept = min(1, QuickModel.dctKeptRetention * pow(level, QuickModel.dctKeptFloorExponent))
            guard resized else { return kept }
            if bitsPerSample >= QuickModel.dctPhotoBitsPerSample
                || resource.pixelCount >= QuickModel.dctPhotoMinimumPixels {
                return min(kept, QuickModel.dctPhotoFactor * pow(ratio, QuickModel.dctPhotoExponent)
                                * pow(level, QuickModel.dctPhotoFloorExponent))
            }
            return min(kept, QuickModel.dctGraphicsRetention * pow(level, QuickModel.dctGraphicsFloorExponent))
        case .flate, .lzw, .runLength, nil:
            if bitsPerSample >= QuickModel.photoBitsPerSample {
                return min(1, QuickModel.photoFactor * pow(ratio, QuickModel.photoExponent))
            }
            return resized ? min(1, pow(ratio, QuickModel.graphicsExponent))
                           : min(1, QuickModel.graphicsKeptRetention * level)
        default:
            return QuickModel.otherRetention
        }
    }

    /// Schätzt für eine Datei. Erzeugt denselben Plan, den die Kompression
    /// anschließend ausführt – ein Aufruf, eine Entscheidung.
    ///
    /// Phase V2-10 (§16.2): `mode: .accurate` misst NACH der Planung die
    /// größten behaltenen Streams per Sample-Encode (Budget
    /// `accurateSampleBudgetSeconds`, Top `accurateSampleLimit` nach Bytes)
    /// und ersetzt deren modellierte Ersparnis durch GEMESSENE Werte
    /// (Frontier-Fit) – das Band fällt enger. Der Plan selbst bleibt
    /// unangetastet; gesampelt wird nie an transformierten Bildern, deren
    /// Bytes die Planung bereits gemessen hat.
    static func estimate(url: URL, options: CompressionOptions,
                         mode: EstimateMode = .fast,
                         isCancelled: (() -> Bool)? = nil) -> CompressionEstimate? {
        guard let document = try? PDFCoreDocument(path: url.path),
              let resources = try? document.imageResources() else { return nil }
        let pixels = LibQPDFPixelSource(document: document)
        // §8.4 – derselbe Seitenkontext wie die Produktion: Der Estimator
        // führt denselben Plan aus, den die Kompression anschließend fährt.
        let pageAnalyses = (try? PageScanAnalyzer.analyze(
            document: document, resources: resources)) ?? []
        guard let planned = try? CompressionPlanner.plan(
            resources: resources,
            options: options,
            documentID: url.lastPathComponent,
            documentBytes: Int(Compressor.fileSize(of: url)),
            pixels: pixels,
            isCancelled: isCancelled,
            pageAnalyses: pageAnalyses) else { return nil }

        // Behaltene Bilder mit verlustfreiem Filter packt der Struktur-Pass nach.
        let keptIDs = Set(planned.plan.keptActions.map(\.objectID))
        let recompressible = resources
            .filter { keptIDs.contains($0.objectID) }
            .filter { resource in
                // Verlustfrei kodierte Streams (und unkomprimierte) packt
                // `--recompress-flate` nach; DCT-Streams sind bereits JPEG.
                switch resource.terminalFilter {
                case .flate, .lzw, .runLength: return true
                case nil: return true
                default: return false
                }
            }
            .reduce(0) { $0 + max($1.encodedByteCount, 0) }

        // Phase 1b-Rückführung – behaltene Baseline-DCT-Streams, die der
        // Repack-Pass im Executor anfassen würde (dieselbe Bedingung wie dort).
        let repackable = resources
            .filter { keptIDs.contains($0.objectID) }
            .filter { $0.terminalFilter == .dct && $0.unknownFilters.isEmpty
                      && $0.filters == [.dct] }
            .reduce(0) { $0 + max($1.encodedByteCount, 0) }

        // §16.2 – Sample-Encode VOR der Dedup-Vorschau: Der Dedup hängt am
        // Wegwerf-Handle Referenzen um; die Messung liest rohe Stream-Bytes
        // und soll davon unberührt bleiben.
        var samples: [KeptStreamSample] = []
        if mode == .accurate {
            samples = sampleKeptStreams(
                document: document,
                resources: resources,
                keptIDs: keptIDs,
                progressive: options.compatibilityPolicy != .maximum)
        }

        // Phase 3b-Rückführung – Dedup-Vorschau: Der verlustfreie Pass läuft
        // auf dem WEGWERF-Handle dieses Estimators (er hängt nur Referenzen
        // um, die Datei selbst bleibt unangetastet) und liefert seine
        // gemessene Ersparnis. Erst nach der Planung, damit die Planentschei-
        // dungen unberührt bleiben; bei `dedupPolicy .off` läuft er nicht.
        var dedupBytes = 0
        if planned.plan.dedupPolicy != .off {
            dedupBytes = (try? document.deduplicate())?.estimatedBytesSaved ?? 0
        }

        let estimate = estimate(plan: planned.plan,
                        pageCount: document.pageCount,
                        maxEffectiveDPI: resources.compactMap(\.effectiveDPI).max(),
                        structureRetention: document.structureProfile.structureRetention,
                        recompressibleKeptBytes: recompressible,
                        repackableDCTBytes: repackable,
                        dedupEstimatedBytes: dedupBytes)

        guard mode == .accurate else { return estimate }

        // Ohne Sample (nichts über der Schwelle, Budget leer) gibt es KEINE
        // neue Information – dann bleibt exakt die Fast-Schätzung stehen;
        // sich ein engeres Band ohne Messung einzubilden wäre Etikettenschwindel.
        guard !samples.isEmpty else { return estimate }

        // Frontier-Fit: Der Punktwert hatte für JEDE behaltene Stream-Gruppe
        // die Modellfaktoren abgezogen. Für die GEMESSENEN Samples wird der
        // Modellabzug zurückgenommen und die Messung eingesetzt; alles
        // Unsampled bleibt im Fast-Modell.
        let sampledModeledSaving = samples.reduce(Int64(0)) {
            $0 + $1.modeledSaving
        }
        let measuredSaving = samples.reduce(Int64(0)) {
            $0 + $1.measuredSaving
        }
        return refined(estimate,
                       sampledModeledSaving: sampledModeledSaving,
                       measuredSaving: measuredSaving,
                       sampleCount: samples.count)
    }

    // MARK: Phase V2-10 (§16.2) – Sample-Encode

    /// EIN Sample-Ergebnis: Was das Fast-Modell für den Stream annahm und was
    /// die Messung tatsächlich erbrachte.
    private struct KeptStreamSample {
        let modeledSaving: Int64
        let measuredSaving: Int64
    }

    /// Misst die größten BEHALTENEN Streams: Flate-Streams inflate + zlib-
    /// Rekompression (Proxynäherung an `--recompress-flate -9`), DCT-Streams
    /// verlustfreier Repack (dieselbe Bedingung wie der Executor). Keine
    /// eigene Bildentscheidung – gemessen wird genau das, was der Struktur-/
    /// Repack-Pass mit behaltenen Streams tut; transformierte Bilder kommen
    /// nicht vor, ihre Bytes sind bereits Planungs-Messwerte. Budget:
    /// `accurateSampleBudgetSeconds`, Top `accurateSampleLimit` nach Bytes.
    private static func sampleKeptStreams(
        document: PDFCoreDocument,
        resources: [PDFImageResource],
        keptIDs: Set<PDFObjectID>,
        progressive: Bool) -> [KeptStreamSample] {
        let deadline = Date().addingTimeInterval(accurateSampleBudgetSeconds)
        var samples: [KeptStreamSample] = []

        // Größte zuerst – der Budget-Deckel trifft dann die Kleinen.
        let candidates = resources
            .filter { keptIDs.contains($0.objectID) }
            .filter { max($0.encodedByteCount, 0) >= accurateMinimumSampleBytes }
            .sorted { $0.encodedByteCount > $1.encodedByteCount }
            .prefix(accurateSampleLimit)

        for resource in candidates {
            if Date() > deadline { break }
            guard let raw = document.imageStreamData(
                objectID: resource.objectID, decoded: false) else { continue }
            let original = Int64(max(resource.encodedByteCount, 0))
            let measured: Int64
            switch resource.terminalFilter {
            case .dct where resource.unknownFilters.isEmpty
                              && resource.filters == [.dct]:
                // Derselbe Repack wie der Executor (Phase 1b). Skip (bereits
                // progressive) und Never-Grow (nicht kleiner) sind MESSUNGEN
                // mit Gewinn 0 – sie zählen als Sample, sonst übersähe der
                // Frontier-Fit Ströme, deren Modellansatz zu optimistisch war.
                measured = switch JPEGEncoder.repack(raw,
                                                     progressive: progressive) {
                case .repacked(let data):
                    max(0, original - Int64(data.count))
                case .skipped, .keepOriginal:
                    0
                }
            case .flate, nil:
                // Nur exakte zlib-Ströme lassen sich inflaten; LZW/RunLength
                // bleiben im Fast-Modell (der Struktur-Pass wandelt sie
                // ohnehin erst um). Inhalt-Obergrenze wie im Zopfli-Pfad.
                guard let content = ZopfliCodec.inflate(
                          raw, maxContentBytes: 16 * 1024 * 1024),
                      let recompressed = ImageProcessor.flateBest(content) else {
                    continue
                }
                measured = max(0, original - Int64(recompressed.count))
            default:
                continue
            }
            let modeled: Int64
            if resource.terminalFilter == .dct {
                modeled = Int64(Double(original) * keptDCTRepackSaving)
            } else {
                modeled = Int64(Double(original) * (1 - keptFlateRetention))
            }
            samples.append(KeptStreamSample(modeledSaving: modeled,
                                            measuredSaving: measured))
        }
        return samples
    }

    /// Frontier-Fit (§16.2): Für die Samples wandert der Punktwert auf die
    /// Messwerte, das Band zieht auf `accurate…BandFactor` zusammen. Nie
    /// unter null.
    private static func refined(_ fast: CompressionEstimate,
                                sampledModeledSaving: Int64,
                                measuredSaving: Int64,
                                sampleCount: Int) -> CompressionEstimate {
        let point = max(Int64(0), fast.pointBytes
                            + sampledModeledSaving - measuredSaving)
        return CompressionEstimate(
            pageCount: fast.pageCount,
            imageCount: fast.imageCount,
            oversizedCount: fast.oversizedCount,
            maxEffectiveDPI: fast.maxEffectiveDPI,
            lowBytes: Int64(Double(point) * accurateLowerBandFactor),
            pointBytes: point,
            highBytes: Int64(Double(point) * accurateUpperBandFactor),
            originalBytes: fast.originalBytes,
            potential: fast.potential,
            sampledStreamCount: sampleCount)
    }

    // MARK: Phase V2-6 (§16.3) – Target-Size-Reachability

    /// Grobe Reachability-Antwort für ein Zieldateigrößen-Ziel.
    enum TargetReachability: String, Sendable {
        /// Ziel liegt über der typischen Schätzung – erreichbar.
        case likelyReachable
        /// Ziel liegt zwischen der minimal-sicheren und der typischen
        /// Schätzung – nur der echte Lauf entscheidet.
        case uncertain
        /// Ziel liegt unter dem minimal-sicheren Ergebnis (§12.8).
        case notSafelyReachable
    }

    // MARK: Phase V2-10 (§16.3) – Zielgrößen-Assessment

    /// Die vollständige Zielgrößen-Antwort des Estimators: Reachability PLUS
    /// die Punktangaben des Modells. Genau die Punkte, die das Actual-Size-
    /// Feedback (§12.6) nach dem Lauf mit GEMESSENEN Größen verifiziert –
    /// vor dem Lauf sind sie die beste verfügbare Schätzung.
    struct TargetSizeAssessment: Sendable {
        let reachability: TargetReachability
        /// Das angefragte Ziel in Bytes.
        let targetBytes: Int64
        /// „Sicher erreichbar ca. X" – das §12.8-Minimum (Floor-Modell).
        let safelyReachableBytes: Int64
        /// Typische Größe (Kurvenmitte) – obere Grenze der Erwartung.
        let typicalBytes: Int64
    }

    // Heuristik (bewusst OHNE Kandidatenlauf, §16.3): Fast Estimate über
    // Byte-Attribution + Klassen-Kurven, nicht über die Candidate-Engine.
    //
    //   fixed  = (Dokumentgröße − Bildbytes) × structureFactor  – dasselbe
    //            Fixed-Bytes-Modell wie der TargetSizeOptimizer (§12.3,
    //            §4 Prinzip 3: derselbe Kandidatenraum).
    //   Klasse (aus dem EINGANGSFILTER, ohne Dekodieren):
    //     DCT (Foto-JPEG)  → verlustbehafteter Re-Encode gewinnt typ. 65 %:
    //                        Floor 0.35, typisch 0.60 der Bildbytes.
    //     Flate/CCITT/JBIG2 (Grafik/Scan) → verlustfreier Resize:
    //                        Floor 0.55, typisch 0.80.
    //     sonst/unbekannt  → konservativ: Floor 0.80, typisch 0.95.
    //   Pixel-Faktor: übersteigt die Platzierung die SMART-REFERENZ
    //   (`ImageCompressionOptions.smartReferenceDPI`, vom Produkt-Anker
    //   abgeleitet – keine zweite Kopie und keine eigene Bildentscheidung)
    //   um F, schrumpft der Bytebedarf quadratisch (Fläche):
    //   F = (Ziel/DPI)², gekappt auf [0.02, 1]; ohne bekannte DPI 1. Bewusst
    //   MODUS-FREI – §16.3 nennt keinen Modus-Eingang, und der Schätzer
    //   trifft (Architektur-Regel) keine eigene Bildentscheidung.
    //
    //   minimum = fixed + Σ Bildbytes × Floor × F   (sicher erreichbar)
    //   typical = fixed + Σ Bildbytes × typisch × F
    //
    //   Ziel ≥ typical           → likelyReachable
    //   Ziel ≥ minimum × 1.05    → uncertain (5 % Overhead-Kissen)
    //   sonst                    → notSafelyReachable
    //
    // Heuristik-Doku: Die Kurven sind KORPUS-geankert (Foto-Dokument
    // 16,5 MB → 1,09 MB bei Smart entspricht ~6 % der Bildbytes; der Floor
    // 0.35 liegt konservativ darüber), nicht pro Dokument gemessen. Der
    // Estimator verspricht damit eine RICHTUNG, keine Bytegenauigkeit –
    // die Präzision liefert der Lauf mit Actual-Size-Feedback (§12.6).
    static func targetLikelyReachable(url: URL,
                                      goal: CompressionGoal)
        -> TargetReachability? {
        guard case .targetBytes = goal else { return nil }
        return assessTargetSize(url: url, goal: goal)?.reachability
    }

    /// §16.3 – vollständiges Assessment für ein Zieldateigrößen-Ziel:
    /// Reachability plus die Punktangaben (sicher erreichbar / typisch).
    /// Die UI zeigt daraus „Ziel: 10 MB → sicher erreichbar ca. 12,4 MB",
    /// wenn das Ziel nicht sicher erreichbar ist.
    static func assessTargetSize(url: URL,
                                 goal: CompressionGoal) -> TargetSizeAssessment? {
        guard case .targetBytes(let target) = goal, target > 0 else { return nil }
        guard let model = targetSizeModel(url: url) else { return nil }
        let reachability: TargetReachability
        if Int64(target) >= model.typicalBytes { reachability = .likelyReachable }
        else if Double(target) >= Double(model.minimumBytes) * 1.05 {
            reachability = .uncertain
        }
        else { reachability = .notSafelyReachable }
        return TargetSizeAssessment(
            reachability: reachability,
            targetBytes: target,
            safelyReachableBytes: model.minimumBytes,
            typicalBytes: model.typicalBytes)
    }

    /// Das Fixed-Bytes-Modell (§12.3) mit den Klassen-Kurven – EINE Stelle,
    /// die `targetLikelyReachable` und `assessTargetSize` teilen.
    private struct TargetSizeModel {
        let minimumBytes: Int64
        let typicalBytes: Int64
    }

    private static func targetSizeModel(url: URL) -> TargetSizeModel? {
        guard let document = try? PDFCoreDocument(path: url.path),
              let resources = try? document.imageResources() else { return nil }

        let documentBytes = Compressor.fileSize(of: url)
        let imageBytes = resources.reduce(Int64(0)) {
            $0 + Int64(max($1.encodedByteCount, 0))
        }
        let fixed = Int64((Double(max(documentBytes - imageBytes, 0))
                           * TargetSizeOptimizer.structureFactor).rounded())
        let referenceDPI = ImageCompressionOptions.smartReferenceDPI

        var minimum = fixed
        var typical = fixed
        for resource in resources {
            let original = Double(max(resource.encodedByteCount, 0))
            guard original > 0 else { continue }
            let (floorRatio, typicalRatio): (Double, Double)
            switch resource.terminalFilter {
            case .dct:
                (floorRatio, typicalRatio) = (0.35, 0.60)
            case .flate, .lzw, .runLength, .ccitt, .jbig2:
                (floorRatio, typicalRatio) = (0.55, 0.80)
            case .jpx, .ascii85, .asciiHex, .crypt, nil:
                (floorRatio, typicalRatio) = (0.80, 0.95)
            }
            // Pixel-Faktor: DPI-Überschuss wirkt quadratisch (Fläche),
            // gekappt gegen die Null.
            var pixelFactor = 1.0
            if let dpi = resource.effectiveDPI, dpi > referenceDPI {
                pixelFactor *= (referenceDPI / dpi) * (referenceDPI / dpi)
            }
            pixelFactor = max(0.02, min(pixelFactor, 1.0))
            minimum += Int64(original * floorRatio * pixelFactor)
            typical += Int64(original * typicalRatio * pixelFactor)
        }
        return TargetSizeModel(minimumBytes: minimum, typicalBytes: typical)
    }
}
