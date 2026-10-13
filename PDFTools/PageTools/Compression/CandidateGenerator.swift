import Foundation
import CoreGraphics

// MARK: - Masterplan §9 – Candidate Generator
//
// Erzeugt pro Bildressource EIN CandidateSet:
//
//   • KEEP ist immer Candidate 0 (§9.1) – bytes = Original, Verzerrung 0,
//     Laufzeit 0.
//   • JPEG-Kandidaten (photo, aggressive Graphics, JPX-Input) entstehen über
//     die BESTEHENDE Encode-Kette (ImageResampler/JPEGEncoder/QualityGates)
//     mit Bracketed Quality Search (§9.3) je Auflösungsstufe (§9.4).
//   • Flate-Kandidat (graphics/screenshot/lineArt/chart) = der bestehende
//     lossless-Resize+Predictor-Pfad als Kandidat (§9.5); scheitert die
//     verlustfreie Familie komplett am Never-Grow, tritt der §9.5-Fallback
//     an: JPEG nur bei klarem Größenhebel (≤ 50 %) und hinter den
//     Graphics-Gates – gescanntes Kartenmaterial bleibt sonst in voller
//     Größe stehen.
//   • Exact-Palette-Kandidat (§9.6, V2-3b): nur in der Screenshot-/LineArt-/
//     Chart-Sicht (die Legacy-Grafiksicht mappt auf screenshot); Palette und
//     Indizes werden bitgenau gegen die Zielpixel verifiziert, bevor der
//     Kandidat in den Race geht. Er konkurriert dort mit KEEP und Flate –
//     der kleinste gewinnt (Planner-Wahl).
//   • Bilevel (§9.7), CMYK (§9.8) und JPX-Input (§9.9) rufen die bestehenden
//     Race-/Pfadfunktionen auf und drücken ihr Ergebnis in Setform.
//
// Budget (§9.2): max 10 ernsthafte Kandidaten je Bild (KEEP eingerechnet).
// Verteilung: erst die Auflösungsstufen (native → feiner → Ziel → gröber),
// je Stufe ein Bracketed-Search-Fenster (max 5 Evaluierungen); nur PASS-
// Stufen werden Kandidaten. Gleichstände: KEEP gewinnt.
//
// Phase-A-Übersetzung (§5.8): Jeder Kandidat trägt die bestehende
// ImageCompressionAction, in die er übersetzt wird. Der Planner wählt den
// kleinsten Kandidaten und hängt DIESE Aktion in den Plan – der Executor
// läuft unverändert weiter.

// MARK: - §9.3 Bracketed Quality Search

/// Eine gemessene Qualitätsstufe (Encode + Dekodieren + Gate).
struct JPEGSearchRung {
    let quality: Double
    let data: Data
    let measurement: QualityGateMeasurement?
    /// Perzeptueller Score (nil ohne Messung); Quelle des
    /// Katastrophen-AND-Gates (§10.3-Familie).
    let perceptualScore: Double?
    /// Gate-Ergebnis; `true` ohne Gate (feste Qualität, Kleinbild-Ausnahme).
    let passed: Bool
    let runtimeMs: Double

    /// Expliziter Initialisierer: Der Score kommt als optionales Suffix –
    /// bestehende Aufrufe (Tests) kompilieren unverändert.
    init(quality: Double, data: Data,
         measurement: QualityGateMeasurement?,
         perceptualScore: Double? = nil,
         passed: Bool, runtimeMs: Double) {
        self.quality = quality
        self.data = data
        self.measurement = measurement
        self.perceptualScore = perceptualScore
        self.passed = passed
        self.runtimeMs = runtimeMs
    }
}

/// Bracketed Quality Search (§9.3): qHigh → Gate? → qLow → halbieren,
/// Stopp bei Δq ≤ 0.02 oder max. Evaluierungen. Quality-Metriken sind nicht
/// garantiert monoton – deshalb erfolgt die FINALE Wahl immer über die
/// tatsächlich gemessenen Stufen (`winner(in:)`), nie über die Bisektion.
enum BracketedJPEGSearch {

    static let maxEvaluations = 5
    static let minimumInterval = 0.02

    enum Policy {
        /// Feste Qualität ohne Gate (Custom) bzw. Kleinbild-Ausnahme.
        case ungated(quality: Double)
        /// Bracketed Search mit Preset-Multi-Gate.
        case bracketed(qLow: Double, qHigh: Double,
                       gate: QualityGatePolicy,
                       imageClass: QualityGateClass,
                       minimumSSIM: Double)
    }

    /// Fährt die Suche mit einem INJIZIERTEN Evaluierer – Testseam für
    /// deterministische (auch nicht-monotone) Metrikverläufe.
    static func run(policy: Policy,
                    evaluate: (Double) -> JPEGSearchRung?) -> [JPEGSearchRung] {
        var measured: [JPEGSearchRung] = []
        var evaluations = 0

        func evaluateCounted(_ q: Double) -> JPEGSearchRung? {
            guard evaluations < maxEvaluations else { return nil }
            guard let rung = evaluate(q) else { return nil }  // Encode-Fehler
            evaluations += 1
            measured.append(rung)
            return rung
        }

        switch policy {
        case .ungated(let quality):
            _ = evaluateCounted(quality)
            return measured

        case .bracketed(let low, let high, _, _, _):
            let qLow = min(low, high)
            let qHigh = max(low, high)

            // 1./2. qHigh kodieren – hält es das Gate nicht, entsteht für
            // diese Auflösung kein verlustbehafteter Kandidat (§9.3).
            guard let highRung = evaluateCounted(qHigh), highRung.passed else {
                return measured
            }
            guard qHigh > qLow else { return measured }

            // 3./4. qLow – hält es, ist es der Frontier-Kandidat (2 Eval.).
            if evaluateCounted(qLow)?.passed == true { return measured }

            // 5.–7. Intervall halbieren; Stopp bei Δq ≤ 0.02 oder Budget.
            var lower = qLow        // gescheitert (oder nicht evaluiert)
            var upper = qHigh       // bestanden
            while evaluations < maxEvaluations, (upper - lower) > minimumInterval {
                let mid = (lower + upper) / 2
                guard let midRung = evaluateCounted(mid) else { break }
                if midRung.passed { upper = mid } else { lower = mid }
            }
            return measured
        }
    }

    /// Fährt die Suche gegen eine echte Referenz – über die bestehende
    /// Encode-Kette (ImageResampler.encodeJPEG → decodeJPEG → QualityGates).
    /// V2-Maps-Perf: Der qualitätsunabhängige Pixelbuffer der Referenz wird
    /// EINMAL je Stufe vorbereitet und je Quality-Rung wiederverwendet
    /// (`JPEGEncoder.preparePixels`) – Byteidentität bleibt gewahrt, denn
    /// dieselben Pixel gehen in denselben Shim.
    static func run(reference: CGImage, grayscale: Bool, backend: JPEGBackend,
                    policy: Policy,
                    sourceSample: QualityGates.Sample? = nil,
                    anchorCheck: AnchorCheck? = nil) -> [JPEGSearchRung] {
        let evaluator = makeEvaluator(reference: reference, sourceSample: sourceSample)
        let prepared = JPEGEncoder.preparePixels(reference)
        return run(policy: policy) { quality in
            let start = ContinuousClock.now
            guard let (data, decoded, comparison) = encodeAndCompare(
                reference, quality: quality, backend: backend,
                prepared: prepared, evaluator: evaluator) else { return nil }
            let measurement = comparison.flatMap { evaluator.measure(candidate: $0) }
            // Perzeptueller Score aus derselben Messung + Kanten-Einführung
            // (eine zusätzliche Kandidaten-Stichprobe je Rung).
            let edgeIntro = comparison.flatMap { evaluator.edgeIntroduction(candidate: $0) }
            let perceptual = measurement.map {
                PerceptualScore.score(measurement: $0,
                                      edgeIntroduction: edgeIntro)
            }
            var passed: Bool
            switch policy {
            case .ungated:
                passed = true
            case .bracketed(_, _, let gate, _, _):
                if let measurement {
                    if case .pass = QualityGates.qualityVerdict(policy: gate,
                                                                measurement: measurement) {
                        passed = true
                    } else {
                        passed = false
                    }
                } else {
                    passed = false
                }
            }
            if passed, let anchorCheck {
                passed = anchorCheck.admits(decoded)
            }
            return JPEGSearchRung(quality: quality, data: data,
                                  measurement: measurement,
                                  perceptualScore: perceptual,
                                  passed: passed,
                                  runtimeMs: stageMs(since: start))
        }
    }

    /// Smart-Anker (Vertrag 2026-09-29): Jede Stufe muss bei normaler
    /// Ansicht mindestens so nah am Original liegen wie JPEG q75 auf dem
    /// Zielraster.
    ///
    /// Gemessen auf einem FEINEN Raster (Zielgröße bis `sampleEdge`): Das
    /// Gate-Raster (≤ 320 px) mittelt genau das weg, was man bei normaler
    /// Ansicht sieht – 127 DPI mit der niedrigsten Stufe maß dort wie der
    /// Anker (Nutzerbefund 2026-10-05). Der Vergleich ist relativ (Kandidat
    /// gegen Anker auf demselben Raster) und braucht keine eigene Kalibrierung.
    struct AnchorCheck {
        static let sampleEdge = 1024

        let reference: QualityGates.StructuralReference
        let anchor: QualityGates.StructuralScores

        /// `image` ist das Bild auf Zielgröße, `sample` die feine
        /// Originalstichprobe; `nil`, wenn der Anker nicht messbar ist.
        init?(image: CGImage, backend: JPEGBackend, sample: QualityGates.Sample) {
            let reference = QualityGates.StructuralReference(sample)
            guard let data = ImageResampler.encodeJPEG(image,
                                                       quality: QualityGatePolicy.smartAnchorQuality,
                                                       backend: backend),
                  let decoded = ImageResampler.decodeJPEG(data),
                  let anchor = Self.measure(decoded, reference: reference) else { return nil }
            self.reference = reference
            self.anchor = anchor
        }

        func admits(_ decoded: CGImage) -> Bool {
            guard let m = Self.measure(decoded, reference: reference) else { return false }
            let tolerance = QualityGatePolicy.anchorTolerance
            return m.globalSSIM >= anchor.globalSSIM - tolerance
                && m.p05TileSSIM >= anchor.p05TileSSIM - tolerance
                && m.edgeWeightedScore >= anchor.edgeWeightedScore - tolerance
        }

        private static func measure(_ decoded: CGImage,
                                    reference: QualityGates.StructuralReference)
            -> QualityGates.StructuralScores? {
            let size = PixelSize(width: reference.sample.width, height: reference.sample.height)
            let onRaster = decoded.width == size.width && decoded.height == size.height
                ? decoded
                : ImageResampler.resize(decoded, to: size, components: 3)
            return onRaster
                .flatMap { QualityGates.sample($0, maxEdge: max(size.width, size.height)) }
                .flatMap { QualityGates.structuralScores(reference: reference, candidate: $0) }
        }
    }

    /// Ohne Originalstichprobe: Referenz mit demselben Resampler wie der
    /// Kandidat aufs Raster bringen (P0.3), nicht per CoreGraphics-Zeichnen.
    private static func makeEvaluator(reference: CGImage,
                                      sourceSample: QualityGates.Sample?) -> QualityGates.Evaluator {
        (sourceSample ?? CandidateGenerator.referenceSample(original: reference, target: nil))
            .map { QualityGates.Evaluator(reference: $0) }
            ?? QualityGates.Evaluator(reference: reference)
    }

    /// Kodiert, dekodiert und bringt das Ergebnis auf das Raster der
    /// Originalstichprobe – jede Auflösung wird auf demselben Raster verglichen.
    private static func encodeAndCompare(_ reference: CGImage, quality: Double,
                                         backend: JPEGBackend,
                                         prepared: JPEGEncoder.PreparedPixels?,
                                         evaluator: QualityGates.Evaluator)
        -> (data: Data, decoded: CGImage, comparison: CGImage?)? {
        guard let data = ImageResampler.encodeJPEG(reference, quality: quality,
                                                   backend: backend, prepared: prepared),
              let decoded = ImageResampler.decodeJPEG(data) else { return nil }
        let comparison = ImageResampler.resize(decoded,
            to: PixelSize(width: evaluator.reference.width,
                          height: evaluator.reference.height), components: 3)
        return (data, decoded, comparison)
    }

    /// Finale Wahl (§9.3 Schritt 8/9): kleinste gemessene PASS-Datei;
    /// Gleichstand geht an die bessere Messung, dann an die höhere Qualität.
    static func winner(in rungs: [JPEGSearchRung]) -> JPEGSearchRung? {
        rungs
            .filter(\.passed)
            .min { a, b in
                if a.data.count != b.data.count { return a.data.count < b.data.count }
                let sa = a.measurement?.globalSSIM ?? 1.0
                let sb = b.measurement?.globalSSIM ?? 1.0
                if sa != sb { return sa > sb }
                return a.quality > b.quality
            }
    }
}

// MARK: - Generator

enum CandidateGenerator {

    /// Ergebnis der Kandidatenerzeugung für EINE Ressource.
    struct Generated {
        let set: CandidateSet
        /// Phase-A-Übersetzung: je Candidate die bestehende Aktion.
        let actionsByCandidate: [CandidateID: ImageCompressionAction]
        /// Payload-Ablage je Candidate (über den CandidateStore).
        let payloadByCandidate: [CandidateID: CandidatePayload]
        /// JBIG2-Globals (klein, nur beim Race-Gewinner vorhanden).
        let globalsByCandidate: [CandidateID: Data]
        /// Klassifikation für Trace und ResourceDecision (nil = strukturelles
        /// KEEP vor jeder Dekodierung).
        let classification: ResourceClassification?
    }

    /// §9.2 – Budget ernsthafter Kandidaten je Bild (KEEP eingerechnet).
    static let maximumCandidatesPerImage = 10

    /// Obergrenze der Zielpixel für quantisierte Paletten (128 × 128, das
    /// Doppelte der größten gemessenen Gewinnerkante).
    static let maximumQuantizedPalettePixels = 128 * 128

    static func generate(resource: PDFImageResource,
                         options: ImageCompressionOptions,
                         classifierPolicy: ClassifierPolicy,
                         pixels: ImagePixelSource,
                         store: CandidateStore,
                         mrc: [PreparedMRCCandidate] = [],
                         pageContext: [Int: PageAnalysis] = [:],
                         stageTimer: StageTimer? = nil,
                         allowsQuantizedPalette: Bool = false) -> Generated {
        var session = Session(resource: resource, options: options,
                              pixels: pixels, store: store,
                              pageContext: pageContext,
                              stageTimer: stageTimer,
                              allowsQuantizedPalette: allowsQuantizedPalette)
        session.run(classifierPolicy: classifierPolicy)
        // V2-7 (§13) – QA-geprüfte MRC-Seitenbündel der Seite: Sie
        // konkurrieren im Set des DOMINANTEN RASTERBILDES mit dessen
        // normalen Kandidaten; die Seiten-QA (§13.10) ist ihr Gate.
        session.applyMRC(mrc)
        return session.finalize()
    }

    /// Sammelt die Kandidaten EINER Ressource. Bewusst eigener Typ: Das
    /// große Entscheidungsfluss-Diagramm wird so in kleine Methoden
    /// zerlegt (Typchecker-freundlich).
    private struct Session {
        let resource: PDFImageResource
        let options: ImageCompressionOptions
        let pixels: ImagePixelSource
        let store: CandidateStore
        /// §8.4 – Seitenanalysen (pageIndex → PageAnalysis) für die V2-
        /// Klassifikation. Ohne Eintrag bleiben die Seitenregeln aus
        /// (Konservativität wie vor der Verknüpfung).
        let pageContext: [Int: PageAnalysis]
        /// §7.3 – die Feature-Extraktion zahlt auf `feature_analysis_ms`
        /// ein (V2-11: die Phasenuhr des entfernten Legacy-`decide` ist
        /// durch diesen Messpunkt ersetzt).
        let stageTimer: StageTimer?
        let objectID: PDFObjectID
        let originalBytes: Int
        let pages: [Int]

        private(set) var transforms: [(candidate: CompressionCandidate,
                                       action: ImageCompressionAction,
                                       payload: Data?)] = []
        private(set) var globals: [CandidateID: Data] = [:]
        private(set) var keepReason = KeepReason.withinBudget
        private(set) var classification: ResourceClassification?

        /// Quantisierte Palette NUR für Small/Target-Size (§4: keine
        /// Farbreduktion in Smart/Qualität/Custom). Der Planner setzt das
        /// Flag aus Preset + Ziel (V2-6); ohne Flag bleibt der Pfad tot und
        /// das Verhalten byteidentisch.
        let allowsQuantizedPalette: Bool

        /// Budget der Kandidatensuche (§9.2, KEEP eingerechnet).
        var hasSearchBudget: Bool {
            transforms.count + 1 < CandidateGenerator.maximumCandidatesPerImage
        }

        /// Mindestens ein Kandidat, der die perzeptuelle Katastrophen-Grenze
        /// hält (verlustfrei gilt als sicher) – dieselbe Grenze wie im
        /// Optimierer (`PerceptualScore.catastrophicLimit`).
        var hasSafeCandidate: Bool {
            transforms.contains {
                $0.candidate.isLossless
                    || ($0.candidate.metrics.perceptualScore ?? 0)
                        <= PerceptualScore.catastrophicLimit
            }
        }

        init(resource: PDFImageResource, options: ImageCompressionOptions,
             pixels: ImagePixelSource, store: CandidateStore,
             pageContext: [Int: PageAnalysis], stageTimer: StageTimer?,
             allowsQuantizedPalette: Bool = false) {
            self.resource = resource
            self.options = options
            self.pixels = pixels
            self.store = store
            self.pageContext = pageContext
            self.stageTimer = stageTimer
            self.allowsQuantizedPalette = allowsQuantizedPalette
            self.objectID = resource.objectID
            self.originalBytes = resource.encodedByteCount
            self.pages = Array(Set(resource.placements.map(\.pageIndex))).sorted()
        }

        // MARK: Pixelquelle

        /// V2-Maps-Perf – dekoliert EINMAL je (Ressource, Ebene) über den
        /// PixelDecodeCache des Stores. Der Bracketed Search encodiert nur
        /// um – er braucht die Pixel nicht neu; dieselbe Ebene liefert
        /// dasselbe Raster, das zwei getrennte Dekodierungen geliefert
        /// hätten (byteidentische Referenzen, Determinismus unberührt).
        func decodedRaster(for target: PixelSize) -> CGImage? {
            let level = pixels.decodeLevel(for: resource, target: target)
            return store.pixelCache.image(for: objectID, level: level) {
                pixels.decodedImage(for: resource, target: target)
            }
        }

        // MARK: Ablage

        /// Nimmt einen Kandidaten auf, sofern Budget und Never-Grow es
        /// erlauben. `bytes` überschreibt die Byteschätzung (6b-Barriere).
        @discardableResult
        mutating func add(kind: CandidateKind, isLossless: Bool, data: Data?,
                          measurement: QualityGateMeasurement?, runtimeMs: Double,
                          workingBytes: Int64, reason: String,
                          action: ImageCompressionAction,
                          bytes: Int? = nil) -> Bool {
            let size = bytes ?? data?.count ?? action.expectedEncodedBytes
                ?? max(0, originalBytes)
            guard originalBytes < 0 || size < originalBytes else { return false }
            guard hasSearchBudget else { return false }
            let candidate = CompressionCandidate(
                id: CandidateGenerator.actionCandidateID(kind: kind,
                                                         objectID: objectID),
                objectID: objectID,
                kind: kind,
                metrics: CandidateMetrics(
                    encodedBytes: size,
                    globalSSIM: measurement?.globalSSIM,
                    p05TileSSIM: measurement?.p05TileSSIM,
                    edgeScore: measurement?.edgeWeightedScore,
                    textScore: measurement?.textRegionScore,
                    deltaE76: measurement?.meanDeltaE76,
                    psnr: measurement?.psnr,
                    expectedRuntimeMs: runtimeMs,
                    expectedPeakWorkingBytes: workingBytes,
                    compatibilityRisk: CandidateGenerator.compatibilityRisk(kind),
                    semanticRisk: CandidateGenerator.semanticRisk(
                        kind, measurement: measurement)),
                isLossless: isLossless,
                pages: pages,
                reason: reason)
            transforms.append((candidate, action, data))
            return true
        }

        /// Measure against native pixels, including the loss from resizing/color conversion.
        private func sourceMeasurement(target: PixelSize, components: Int) -> QualityGateMeasurement? {
            let native = PixelSize(width: resource.width, height: resource.height)
            guard let decodedOriginal = decodedRaster(for: native),
                  let input = decodedRaster(for: target),
                  let transformed = ImageResampler.resize(input, to: target, components: components),
                  let original = options.forceGrayscale
                    ? ImageResampler.resize(decodedOriginal, to: native, components: 1)
                    : decodedOriginal,
                  let reference = CandidateGenerator.referenceSample(original: original,
                                                                    target: target),
                  let comparison = ImageResampler.resize(transformed,
                      to: PixelSize(width: reference.width, height: reference.height),
                      components: 3) else { return nil }
            return QualityGates.Evaluator(reference: reference).measure(candidate: comparison)
        }

        /// Flate encoding is lossless; the preceding pixel transformation is not.
        mutating func record(action: ImageCompressionAction, payload: Data?,
                             kind: CandidateKind, workingBytes: Int64) {
            switch action {
            case .losslessResize(_, let target, let grayscale, _, _, let predictor):
                keepReason = .noSizeBenefit
                // Predictor-Entscheidung kommt aus dem Race im Planner –
                // die übergebene Kind-Vorlage wird damit überschrieben.
                let racedKind: CandidateKind
                if case .flate = kind {
                    racedKind = .flate(target: target, grayscale: grayscale,
                                       predictor: predictor)
                } else {
                    racedKind = kind
                }
                let components = grayscale ? 1 : (resource.colorSpace.componentCount ?? 3)
                guard let measurement = sourceMeasurement(target: target, components: components)
                else { return }
                add(kind: racedKind, isLossless: false, data: payload, measurement: measurement,
                    runtimeMs: 0, workingBytes: workingBytes,
                    reason: "Flate nach Pixeltransformation, gegen Original gemessen"
                        + (predictor ? " mit Predictor" : " roh"),
                    action: action)
            case .keep(_, let reason, _):
                keepReason = reason
            default:
                keepReason = .noSizeBenefit
            }
        }

        /// Bilevel-Race-Ergebnis in Setform (§9.7).
        mutating func applyBilevelRace(action: ImageCompressionAction,
                                       payload: Data?,
                                       raceGlobals: Data?,
                                       workingBytes: Int64) {
            switch action {
            case .ccittG4:
                keepReason = .noSizeBenefit
                add(kind: .ccittG4, isLossless: true, data: payload,
                    measurement: nil, runtimeMs: 0, workingBytes: workingBytes,
                    reason: "kleinster bitidenter Bilevel-Kandidat (Race §9.7)",
                    action: action)
            case .jbig2:
                keepReason = .noSizeBenefit
                add(kind: .jbig2Lossless, isLossless: true, data: payload,
                    measurement: nil, runtimeMs: 0, workingBytes: workingBytes,
                    reason: "kleinster bitidenter Bilevel-Kandidat (Race §9.7)",
                    action: action)
                if let raceGlobals, let last = transforms.last {
                    globals[last.candidate.id] = raceGlobals
                }
            case .keep(_, let reason, _):
                keepReason = reason
            default:
                keepReason = .noSizeBenefit
            }
        }

        /// Strukturelles KEEP vor jeder Dekodierung abschließen.
        mutating func finishStructural(_ reason: KeepReason) {
            keepReason = reason
        }

        /// V2-7 (§13) – QA-geprüfte MRC-Kandidaten aufnehmen (Never-Grow und
        /// Budget wie in `add`; die Metriken kommen aus der Seiten-QA).
        mutating func applyMRC(_ prepared: [PreparedMRCCandidate]) {
            for entry in prepared {
                guard case .mrc(let descriptor) = entry.candidate.kind else {
                    continue
                }
                guard originalBytes < 0
                        || entry.candidate.metrics.encodedBytes < originalBytes
                else { continue }
                // Volles Budget (P0.3): Das Bündel verdrängt den GRÖSSTEN
                // verlustbehafteten Nicht-MRC-Kandidaten, sofern es kleiner
                // ist – der kann neben kleineren bestandenen Kandidaten nie
                // gewinnen (§10.6 wählt den kleinsten). Früher fiel die
                // kleinere MRC-Stufe ohne Ablehnungsgrund aus dem Set
                // (Schwarzweiß-Scans 7,6 → 15,5 KB); eine pauschale
                // Reservierung verdrängte dagegen die gewinnende kleinste
                // JPEG-Stufe (Graustufen-Scan 48,8 → 64,4 KB).
                if !hasSearchBudget {
                    let evictable = transforms.indices.filter { index in
                        let candidate = transforms[index].candidate
                        if case .mrc = candidate.kind { return false }
                        return !candidate.isLossless
                    }
                    guard let largest = evictable.max(by: {
                        transforms[$0].candidate.metrics.encodedBytes
                            < transforms[$1].candidate.metrics.encodedBytes
                    }), transforms[largest].candidate.metrics.encodedBytes
                            > entry.candidate.metrics.encodedBytes else { continue }
                    transforms.remove(at: largest)
                }
                let action = ImageCompressionAction.mrc(
                    objectID: objectID, descriptor: descriptor,
                    originalEncodedBytes: originalBytes,
                    expectedEncodedBytes: entry.candidate.metrics.encodedBytes)
                transforms.append((entry.candidate, action, entry.bundle))
                keepReason = .noSizeBenefit
            }
        }

        // MARK: Entscheidungsfluss (vormals gespiegelt aus dem entfernten
        // Legacy-`decide`; seit V2-11 DER Entscheidungsfluss)

        mutating func run(classifierPolicy: ClassifierPolicy) {
            // 0. Bilevel-Vorprüfung (Dictionary-Ebene, vor jeder Dekodierung)
            //    – Bilevel wird nie resampelt.
            // Die Erkennung läuft in JEDER Politik: `.keep` heißt „Bilevel
            // bleibt unangetastet" – auch exakt zweiwertiges 8-bit. Vorher
            // übersprang `.keep` die Erkennung, und solche Scans liefen in
            // den Foto-/Grafikpfad (Befund B7, Review 2026-10-09).
            let bilevelKind = CompressionPlanner.planBilevelKind(resource: resource)
            if bilevelKind == .trueBilevel {
                if options.bilevelPolicy != .auto {
                    finishStructural(.bilevelKept)
                    return
                }
                classification = ResourceClassification(contentClass: .scanBilevel,
                                                        confidence: 0.95,
                                                        features: nil)
                guard let buffer = pixels.bilevelBuffer(for: resource) else {
                    keepReason = .decodeFailed
                    return
                }
                let (action, payload, raceGlobals) =
                    CompressionPlanner.bilevelRace(buffer: buffer,
                                                   resource: resource,
                                                   pixels: pixels)
                applyBilevelRace(action: action, payload: payload,
                                 raceGlobals: raceGlobals,
                                 workingBytes: Int64(buffer.data.count))
                return
            }

            // 1. Capability – „darf man das Bild überhaupt anfassen?“
            let capability = resource.transformCapability
            guard capability.isSafe else {
                finishStructural(.capability(capability))
                return
            }

            // 2. Größenpolitik.
            guard resource.maxEdge
                    >= CompressionPlanner.minimumTransformableEdge else {
                finishStructural(.tooSmall)
                return
            }
            guard resource.pixelCount
                    <= CompressionPlanner.maximumDecodablePixels else {
                finishStructural(.pixelBudgetExceeded(pixels: resource.pixelCount))
                return
            }

            // 3. Zielgröße aus Effective DPI + Kantenlimit (Never Upscale).
            let resize = CompressionPlanner.plannedSize(for: resource,
                                                        options: options)
            let needsColorChange = options.forceGrayscale
            // Existing DCT streams get a lossless repack below the DPI limit.
            // A native-size lossy encode would silently replace their pixels.
            // Verlustfrei gespeicherte Fotos (Flate) im DPI-Budget dürfen
            // dagegen in JEDER Politik auf Originalgröße kodiert werden –
            // auch bei fester Custom-Qualität: Der Nutzer hat die Qualität
            // gewählt, vorher blieb der Regler für solche Bilder wirkungslos
            // (Befund B1, Review 2026-10-09).
            let allowsNativeReencode = true
            guard resize != nil || needsColorChange
                    || (allowsNativeReencode
                        && resource.terminalFilter != .dct
                        && resource.colorSpace.allowsLossyReplacement) else {
                finishStructural(.withinBudget)
                return
            }
            let plannedTarget = resize
                ?? PixelSize(width: resource.width, height: resource.height)
            guard plannedTarget.width <= resource.width,
                  plannedTarget.height <= resource.height else {
                finishStructural(.neverUpscale)
                return
            }

            // 4. Pixel besorgen (Zielraster – derselbe Aufruf wie die Legacy-
            //    Planung, damit JPX-cp_reduce deterministisch übereinstimmt).
            //    Über den Raster-Cache: die Dekodierung dient allen Stufen
            //    der Leiter (V2-Maps-Perf).
            guard let targetImage = decodedRaster(for: plannedTarget) else {
                finishStructural(.decodeFailed)
                return
            }

            // 4.5 „Nahezu bilevel“ – exakte Zweiwertigkeit nach dem Dekodieren.
            if bilevelKind == .nearBilevel,
               let scan = BilevelDetection.exactBilevel(
                   targetImage, rgb: BilevelDetection.isRGB(resource)) {
                classification = ResourceClassification(contentClass: .scanBilevel,
                                                        confidence: 0.95,
                                                        features: nil)
                if options.bilevelPolicy != .auto {
                    finishStructural(.bilevelKept)
                    return
                }
                let (action, payload, raceGlobals) =
                    CompressionPlanner.bilevelRace(buffer: scan.buffer,
                                                   resource: resource,
                                                   pixels: pixels)
                applyBilevelRace(action: action, payload: payload,
                                 raceGlobals: raceGlobals,
                                 workingBytes: Int64(scan.buffer.data.count))
                return
            }

            runContentPaths(classifierPolicy: classifierPolicy,
                            target: plannedTarget,
                            targetImage: targetImage,
                            resize: resize)
        }

        /// §8.4/§8.3 – Verknüpfung von Seitenanalyse und Bildklassifikation
        /// (V2-2 offen, hier geschlossen): Eine Stelle in PageScanAnalyzer
        /// (Benchmark und Diagnose spiegeln dieselbe Semantik). Ohne
        /// Seitenanalyse bleibt der Kontext leer – die Seitenregeln
        /// überspringen sich dann selbst (Konservativität unverändert).
        private func classificationContext() -> ContentClassifier.ClassificationContext {
            PageScanAnalyzer.classificationContext(
                for: resource.placements.first.flatMap { pageContext[$0.pageIndex] },
                resource: resource)
        }

        /// Ab der Klassifikation – Inhalt nach Legacy-Route verteilt.
        private mutating func runContentPaths(classifierPolicy: ClassifierPolicy,
                                              target: PixelSize,
                                              targetImage: CGImage,
                                              resize: PixelSize?) {
            // 5. Klassifikation. Die ROUTE folgt exakt der Legacy-Semantik
            //    (ImageClassifier, bei `.v2` die abgeleitete V2-Klasse); die
            //    V2-Feature-Extraktion läuft zusätzlich, weil ResourceDecision
            //    die Merkmale trägt (§5.7).
            let stats = ImageClassifier.analyze(targetImage)
            var imageClass = ImageClassifier.classify(stats)
            var verdict: ContentClassifier.Verdict?
            var features: ContentFeatures?
            if let extracted = StageTimer.run(stageTimer, .featureAnalysisMs, {
                ContentFeatureExtractor.extract(from: targetImage)
            }) {
                features = extracted
                let result = ContentClassifier.classify(
                    features: extracted,
                    context: classificationContext())
                verdict = result
                if classifierPolicy == .v2 {
                    imageClass = result.contentClass.derivedImageClass ?? imageClass
                }
            }
            classification = ResourceClassification(
                contentClass: verdict?.contentClass
                    ?? ContentClass(imageClass: imageClass),
                confidence: verdict?.confidence ?? 0.5,
                features: features)
            traceClassification(imageClass: imageClass, stats: stats, verdict: verdict)

            let grayscale = options.forceGrayscale || stats.isGrayscale

            // Graustufen angefordert, Bild schon grau, kein Resize nötig.
            // (Greift auch ohne Grau-Anforderung für graue Bilder im Budget –
            // bewusst so belassen, 2026-10-09: ein Lockern hätte Smart für
            // graue Flate-Bilder im Budget verändert.)
            if resize == nil && stats.isGrayscale {
                keepReason = .alreadyGrayscale
                return
            }

            // ICC-Profil OHNE JPEG-Quelle: verlustfrei verkleinern, Profil
            // bleibt (derselbe Pfad wie Legacy, als Kandidat). Ist Graustufen
            // angefordert, wird auch hier nach Grau gewandelt – vorher
            // überging die Einstellung ICC-Bilder still (Befund B3).
            if case .iccBased = resource.colorSpace,
               resource.terminalFilter != .dct {
                let outcome = CompressionPlanner.planLosslessResize(
                    resource: resource, image: targetImage, target: target,
                    grayscale: grayscale)
                record(action: outcome.0, payload: outcome.1,
                       kind: .flate(target: target, grayscale: grayscale,
                                    predictor: true),
                       workingBytes: CandidateGenerator.workingBytes(
                           for: target, components: 3))
                return
            }

            // CMYK bleibt CMYK (§9.8): kontrollierter YCCK-Kandidat hinter
            // der 6b-Barriere, sonst verlustfreier Resize.
            if !resource.colorSpace.allowsLossyReplacement {
                runCMYKPath(target: target, targetImage: targetImage)
                return
            }

            // Aggressive-Graphics-Politik (Custom): JPEG nur bei echtem
            // Größenüberhang. Dazwischen – über Ziel × Toleranz, aber unter
            // Ziel × 1,5 – gilt derselbe verlustfreie Weg wie ohne die
            // Einstellung; vorher blieb das Bild dort als KEEP liegen, und
            // Einschalten ließ die Datei größer (Befund A5, Review 2026-10-09).
            let clearlyOversized = resource.maxEdge > options.maxPixelEdge
                || (resource.effectiveDPI ?? 0) > options.targetDPI * 1.5

            switch imageClass {
            case .graphics where !(options.aggressiveGraphics && clearlyOversized):
                // Grafiken/Screenshots: verlustfrei (§9.5) – JPEG würde
                // Kanten zerstören.
                let losslessBefore = transforms.count
                let outcome = CompressionPlanner.planLosslessResize(
                    resource: resource, image: targetImage, target: target,
                    grayscale: grayscale)
                record(action: outcome.0, payload: outcome.1,
                       kind: .flate(target: target, grayscale: grayscale,
                                    predictor: true),
                       workingBytes: CandidateGenerator.workingBytes(
                           for: target, components: grayscale ? 1 : 3))
                // V2-3b (§9.6) – Exact Palette als zusätzlicher Kandidat;
                // der Race entscheidet, ob er gegen KEEP/Flate gewinnt.
                addIndexedCandidate(target: target, targetImage: targetImage,
                                    grayscale: grayscale)
                // §9.5 – Gated JPEG-Fallback: greift NUR, wenn kein
                // verlustfreier Kandidat (Flate/Palette) das Never-Grow
                // geschafft hat. Bei echter Vektorgrafik kommt er nicht
                // zustande – gescanntes Kartenmaterial (verlustbehaftete
                // Quelle, Rauschen) blieb sonst als KEEP in voller Größe
                // liegen (gemessener Maps-Rückgang der V2-11-Zertifizierung).
                addGatedJPEGFallback(target: target, targetImage: targetImage,
                                     grayscale: grayscale,
                                     losslessAdded: transforms.count > losslessBefore)

            case .graphics:
                // Aggressive-Graphics-Politik bei echtem Größenüberhang:
                // JPEG mit angehobener – nie abgesenkter – Qualitätspolitik.
                var aggressive = options
                aggressive.qualityPolicy = options.qualityPolicy.raised(
                    to: options.jpegQuality + 0.10, cap: 0.82)
                generateJPEGCandidates(ladder: [target],
                                       target: target,
                                       targetImage: targetImage,
                                       grayscale: grayscale,
                                       jpegOptions: aggressive,
                                       gateClass: .graphics)

            case .photo:
                let gateClass = classification.map {
                    QualityGateClass(contentClass: $0.contentClass)
                } ?? .photo
                let ladder = CandidateGenerator.resolutionLadder(
                    resource: resource, target: resize, options: options)
                generateJPEGCandidates(
                    ladder: ladder,
                    target: target,
                    targetImage: targetImage,
                    grayscale: grayscale,
                    jpegOptions: options,
                    gateClass: gateClass)
                // Klein-Sicherheitsstufen (2026-09-30): Verletzt JEDER Klein-
                // Kandidat die perzeptuelle Katastrophen-Grenze, fehlte bisher
                // eine sichere Stufe – das Original blieb in voller Größe,
                // während Smart eine sichere höhere Auflösung fand (USGS-
                // Kacheln: feine Linien halten erst über 150 DPI). Klein
                // bekommt dann die Smart-Sicherheitsstufen; nur als Rückfall,
                // damit Klein im Regelfall nicht langsamer wird. Der
                // Optimierer entscheidet wie immer.
                if QualityGatePreset(ssimThreshold: options.ssimThreshold) == .small,
                   !hasSafeCandidate {
                    let safety = CandidateGenerator.smallSafetyLadder(
                        resource: resource, options: options)
                    let rungs = safety.rungs.filter { !ladder.contains($0) }
                    if let smartTarget = safety.smartTarget, !rungs.isEmpty {
                        // Gemessen am Raster der Politik, aus der die Stufen
                        // stammen (Smart-Ziel, P0.1-Regel): Auf dem gröberen
                        // Klein-Raster zerfielen feine Linien derselben
                        // Kandidaten messbar stärker – Smart nahm eine
                        // Kachel an, Klein verwarf die byte-identische.
                        generateJPEGCandidates(
                            ladder: rungs,
                            target: smartTarget,
                            targetImage: targetImage,
                            grayscale: grayscale,
                            jpegOptions: options,
                            gateClass: gateClass,
                            rungIndexOffset: ladder.count)
                    }
                }
            }
        }

        /// CMYK-Pfad (§9.8): YCCK-Kandidat + 6b-Repack-Barriere oder
        /// verlustfreier Resize – beides aus den bestehenden Funktionen.
        private mutating func runCMYKPath(target: PixelSize,
                                          targetImage: CGImage) {
            if CMYKReencode.lossyAllowed(resource: resource, options: options) {
                let barrier = CompressionPlanner.repackBarrier(
                    resource: resource, pixels: pixels)
                // Verlustfreier 6b-Repack als Kandidat – er wird executor-
                // seitig für jedes behaltene DCT-Bild gefahren und ist der
                // Race-Gegner des YCCK-Kandidaten. (KEEP selbst wird dann mit
                // den Originalbytes bewertet – der Repack zählt nur einmal.)
                if barrier != Int.max {
                    add(kind: .jpegRepack(progressive: true), isLossless: true,
                        data: nil, measurement: nil, runtimeMs: 0, workingBytes: 0,
                        reason: "verlustfreier 6b-Repack des Originals",
                        action: .keep(objectID: objectID, reason: .noSizeBenefit,
                                      originalEncodedBytes: originalBytes),
                        bytes: barrier)
                }
                let outcome = CompressionPlanner.planCMYKReencode(
                    resource: resource, image: targetImage, target: target,
                    pixels: pixels, options: options)
                if case .cmykJpegReencode(_, let cmykTarget, let quality, _, _) =
                    outcome.0 {
                    keepReason = .noSizeBenefit
                    add(kind: .cmykJPEG(target: cmykTarget, quality: quality),
                        isLossless: false, data: outcome.1, measurement: nil,
                        runtimeMs: 0,
                        workingBytes: CandidateGenerator.workingBytes(
                            for: cmykTarget, components: 4),
                        reason: "YCCK-Kandidat hielt ΔE-Gate und Größen-Race (§9.8)",
                        action: outcome.0)
                } else if case .keep(_, let reason, _) = outcome.0 {
                    keepReason = reason
                }
                return
            }
            let outcome = CompressionPlanner.planLosslessResize(
                resource: resource, image: targetImage, target: target,
                grayscale: false)
            record(action: outcome.0, payload: outcome.1,
                   kind: .flate(target: target, grayscale: false, predictor: true),
                   workingBytes: CandidateGenerator.workingBytes(for: target,
                                                                 components: 4))
        }

        /// Exact-Palette-Kandidat (§9.6, V2-3b).
        ///
        /// Klassen-Gate: nur die Screenshot-/LineArt-/Chart-Sicht. Die
        /// Legacy-Grafiksicht mappt auf `.screenshot`, damit der Kandidat
        /// auch ohne `.v2`-Klassifikator entsteht; `.unknown` heißt: der
        /// V2-Klassifikator hat nicht entschieden – dann zählt die Route
        /// (dieser Zweig wird ausschließlich für Graphics-Bilder erreicht).
        /// Foto-/Scan-Klassen bekommen keinen Palette-Pfad (keine
        /// Farbreduktion im Smart-Pfad).
        ///
        /// Die Kandidaten Bytes sind der Flate-Strom der GEPACKTEN Indizes;
        /// die Palette selbst liegt in der Action (klein, Plan bleibt
        /// selbstbeschreibend). `add` erzwingt Never-Grow gegenüber dem
        /// Original; gegen KEEP und Flate entscheidet die Planner-Wahl.
        private mutating func addIndexedCandidate(target: PixelSize,
                                                  targetImage: CGImage,
                                                  grayscale: Bool) {
            guard let contentClass = classification?.contentClass,
                  contentClass == .screenshot || contentClass == .lineArt
                      || contentClass == .chart || contentClass == .unknown
              else { return }

            let components = grayscale ? 1 : 3
            // Dieselbe Pixelherleitung wie der Flate-Konkurrent: derselbe
            // Resize-Aufruf, dieselben Zielraster – sonst wäre der Race
            // unfair und die Executor-Rekodierung nicht deterministisch.
            guard let resized = ImageResampler.resize(targetImage, to: target,
                                                      components: components)
            else { return }

            let start = ContinuousClock.now
            switch PaletteOptimizer.encodeExact(resized, components: components) {
            case .success(let encoded):
                guard let measurement = sourceMeasurement(target: target, components: components)
                else { return }
                let action = ImageCompressionAction.indexed(
                    objectID: objectID, target: target,
                    bitsPerComponent: encoded.bitsPerComponent,
                    paletteComponents: encoded.components,
                    palette: encoded.palette,
                    originalEncodedBytes: originalBytes,
                    expectedEncodedBytes: encoded.indexStream.count,
                    quantized: false,
                    dithered: false)
                _ = add(kind: .indexedFlate(target: target,
                                            paletteEntries: encoded.paletteEntries,
                                            bitsPerComponent: encoded.bitsPerComponent),
                        isLossless: false, data: encoded.indexStream,
                        measurement: measurement, runtimeMs: stageMs(since: start),
                        workingBytes: PaletteOptimizer.workingBytes(
                            pixelCount: target.pixelCount, components: components),
                        reason: "exakte Palette (\(encoded.paletteEntries) Farben, "
                            + "\(encoded.bitsPerComponent) bpc), bitgenau "
                            + "verifiziert (§9.6)",
                        action: action)
            case .verificationFailed:
                // Gate-Verweigerung sichtbar machen – der KEEP-Grund erklärt,
                // WARUM es keinen Palette-Kandidaten gibt.
                keepReason = .paletteGateFailed
            case .tooManyColors, .encodeFailed:
                break
            }

            // Quantisiert (lossy, NUR Small/Target-Size): Median-Cut plus
            // Dithering-Variante als zwei Kandidaten. Die Messung läuft im
            // Optimizer (volle Preset-Floors + Pareto + Perceptual wie JPEG);
            // Grau braucht den Pfad nie (8-bit-Grau hat ≤ 256 Stufen und
            // läuft immer exakt).
            // Nur kleine Bilder (2026-10-01): Über Screenshots, Vektor,
            // Mischinhalt und eine Karte gewann die quantisierte Palette 6 von
            // 486 Bildern (5,7 KB von 8 MB) – alle ≤ 66 × 66 px am Ziel. Auf
            // großen Kartenkacheln kostete sie ~40 % der Klein-Kandidatensuche
            // und verlor gegen JPEG; vier Karten liefen dadurch ins Zeitlimit.
            if allowsQuantizedPalette, !grayscale,
               target.pixelCount <= CandidateGenerator.maximumQuantizedPalettePixels {
                addQuantizedCandidates(target: target, resized: resized)
            }
        }

        /// Median-Cut-Kandidaten (plain + gedithert) mit voller Messung.
        /// Klassen-Gate wie exakt (Aufrufer prüft); Preset-Schranke
        /// (`allowsQuantizedPalette`) prüft der Aufrufer ebenfalls.
        private mutating func addQuantizedCandidates(target: PixelSize,
                                                     resized: CGImage) {
            for dither in [false, true] {
                if !hasSearchBudget { break }
                let start = ContinuousClock.now
                guard case .success(let encoded) =
                        PaletteOptimizer.encodeQuantized(resized,
                                                         dither: dither),
                      let measurement = encoded.quality else {
                    continue
                }
                // Never-Grow wie überall (der Optimizer prüft es erneut nach).
                guard originalBytes < 0
                        || encoded.indexStream.count < originalBytes else {
                    continue
                }
                let perceptual = encoded.edgeIntroduction.map {
                    PerceptualScore.score(measurement: measurement,
                                          edgeIntroduction: $0)
                }
                let base = "\(objectID.objectNumber)-\(objectID.generation)"
                let id = CandidateID("indexed-q-\(base)"
                    + "-e\(encoded.paletteEntries)-b\(encoded.bitsPerComponent)"
                    + (dither ? "-d" : ""))
                let kind = CandidateKind.indexedFlate(
                    target: target, paletteEntries: encoded.paletteEntries,
                    bitsPerComponent: encoded.bitsPerComponent)
                let candidate = CompressionCandidate(
                    id: id,
                    objectID: objectID,
                    kind: kind,
                    metrics: CandidateMetrics(
                        encodedBytes: encoded.indexStream.count,
                        globalSSIM: measurement.globalSSIM,
                        p05TileSSIM: measurement.p05TileSSIM,
                        edgeScore: measurement.edgeWeightedScore,
                        textScore: measurement.textRegionScore,
                        deltaE76: measurement.meanDeltaE76,
                        psnr: measurement.psnr,
                        expectedRuntimeMs: stageMs(since: start),
                        expectedPeakWorkingBytes:
                            PaletteOptimizer.workingBytes(
                                pixelCount: target.pixelCount, components: 3),
                        compatibilityRisk: CandidateGenerator.compatibilityRisk(kind),
                        semanticRisk: CandidateGenerator.semanticRisk(
                            kind, measurement: measurement),
                        perceptualScore: perceptual),
                    isLossless: false,
                    pages: pages,
                    reason: "quantisierte Palette (Median-Cut, "
                        + "\(encoded.paletteEntries) Farben, "
                        + "\(encoded.bitsPerComponent) bpc"
                        + (dither ? ", gedithert" : "")
                        + ", verlustbehaftet, nur Small/Target)")
                let action = ImageCompressionAction.indexed(
                    objectID: objectID, target: target,
                    bitsPerComponent: encoded.bitsPerComponent,
                    paletteComponents: encoded.components,
                    palette: encoded.palette,
                    originalEncodedBytes: originalBytes,
                    expectedEncodedBytes: encoded.indexStream.count,
                    quantized: true,
                    dithered: dither)
                transforms.append((candidate, action, encoded.indexStream))
            }
        }

        // MARK: JPEG-Kandidaten (§9.2–9.4)

        /// Erzeugt die JPEG-Kandidaten über die Auflösungsleiter: je Stufe
        /// ein Bracketed-Search-Fenster (§9.3) gegen die stufeneigene
        /// Referenz; nur PASS-Stufen werden Kandidaten (Never-Grow und
        /// Budget inklusive).
        private mutating func generateJPEGCandidates(
            ladder: [PixelSize],
            target: PixelSize,
            targetImage: CGImage,
            grayscale: Bool,
            jpegOptions: ImageCompressionOptions,
            gateClass: QualityGateClass,
            rungIndexOffset: Int = 0) {

            var sawPassingRung = false
            var bestFailedSSIM: Double?
            var measuredAnything = false

            let native = PixelSize(width: resource.width, height: resource.height)
            let source = decodedRaster(for: native).flatMap { decoded in
                options.forceGrayscale
                    ? ImageResampler.resize(decoded, to: native, components: 1)
                    : decoded
            }
            let sourceSample = source.flatMap {
                CandidateGenerator.referenceSample(original: $0, target: target)
            }
            if case .adaptive = jpegOptions.qualityPolicy, sourceSample == nil {
                keepReason = .decodeFailed
                return
            }

            let anchorCheck = source.flatMap {
                smartAnchorCheck(source: $0, target: target, targetImage: targetImage,
                                 grayscale: grayscale, jpegOptions: jpegOptions)
            }

            // V2-Maps-Perf – Ebenen je Stufe (JPX: cp_reduce-Stufe, sonst 0):
            // Nach jeder Stufe werden Ebenen freigegeben, die keine künftige
            // Stufe mehr braucht (Blatt-Freigabe; Budget-Politik des Caches).
            let levels = ladder.map { pixels.decodeLevel(for: resource, target: $0) }

            // Laufzeit (Sichtabnahme 2026-10-12): Die Leiter wird von der
            // KLEINSTEN Stufe aufwärts gesucht. Der Optimierer nimmt den
            // kleinsten zulässigen Kandidaten (§10.6); hat eine Stufe einen
            // Kandidaten geliefert, kann eine Stufe mit mindestens doppelt so
            // vielen Pixeln nie kleiner werden – sie wird nicht mehr kodiert.
            // Vorher kostete ein 12-MP-Foto drei Kodierungen in voller
            // Auflösung, die nie gewannen. Kandidaten-IDs behalten ihren
            // Leiterindex, die Ausgabe bleibt byteidentisch (Smoke-Vergleich
            // per SHA-256, siehe ENGINEERING_PROGRESS).
            let order = ladder.indices.sorted {
                ladder[$0].width * ladder[$0].height < ladder[$1].width * ladder[$1].height
            }
            var pending = Set(order)
            var smallestPassingPixels: Int?
            for rungIndex in order {
                let rung = ladder[rungIndex]
                pending.remove(rungIndex)
                if !hasSearchBudget {
                    for skipped in pending.sorted() {
                        traceJPEG(target: ladder[skipped], result: nil, disposition: "budget-skipped")
                    }
                    break
                }
                let rungPixels = rung.width * rung.height
                if let best = smallestPassingPixels, rungPixels >= 2 * best {
                    traceJPEG(target: rung, result: nil, disposition: "dominated-skipped")
                    continue
                }
                let candidatesBefore = transforms.count

                // Referenz der Stufe: das bereits dekodierte Zielraster für
                // den Legacy-Zielrung, sonst das Cached-Raster der Ebene
                // (JPX reduziert direkt auf 1/2^N – derselbe Aufruf wie der
                // Executor beim deterministischen Neukodieren).
                let decoded: CGImage?
                if rung == target {
                    decoded = targetImage
                } else {
                    decoded = decodedRaster(for: rung)
                }
                guard let decodedImage = decoded,
                      let reference = ImageResampler.resize(decodedImage, to: rung,
                                                            grayscale: grayscale)
                else {
                    traceJPEG(target: rung, result: nil, disposition: "decode-failed")
                    continue
                }

                let policy = jpegPolicy(jpegOptions: jpegOptions,
                                        reference: reference,
                                        gateClass: gateClass)
                let rungs = autoreleasepool {
                    BracketedJPEGSearch.run(reference: reference,
                                            grayscale: grayscale,
                                            backend: jpegOptions.jpegBackend,
                                            policy: policy,
                                            sourceSample: sourceSample,
                                            anchorCheck: anchorCheck)
                }
                for rungResult in rungs {
                    measuredAnything = true
                    if !rungResult.passed {
                        traceJPEG(target: rung, result: rungResult, disposition: "quality-rejected")
                        if let ssim = rungResult.measurement?.globalSSIM {
                            bestFailedSSIM = max(bestFailedSSIM ?? 0, ssim)
                        }
                        continue
                    }
                    sawPassingRung = true
                    guard originalBytes < 0
                            || rungResult.data.count < originalBytes else {
                        traceJPEG(target: rung, result: rungResult, disposition: "no-size-benefit")
                        // PASS, aber kein Größenvorteil → KEEP mit
                        // noSizeBenefit (Legacy-Semantik).
                        continue
                    }
                    // Avoid another lossy generation for marginal native-size savings.
                    if case .adaptive = jpegOptions.qualityPolicy,
                       rung.width == resource.width, rung.height == resource.height,
                       !grayscale, originalBytes > 0,
                       Double(rungResult.data.count) > Double(originalBytes) * 0.90 {
                        traceJPEG(target: rung, result: rungResult, disposition: "marginal-native-saving")
                        continue
                    }
                    traceJPEG(target: rung, result: rungResult, disposition: "candidate")
                    appendJPEGCandidate(rungResult: rungResult, rung: rung,
                                        rungIndex: rungIndexOffset + rungIndex,
                                        grayscale: grayscale,
                                        jpegOptions: jpegOptions)
                }
                if transforms.count > candidatesBefore {
                    smallestPassingPixels = min(smallestPassingPixels ?? .max, rungPixels)
                }

                // Blatt-Freigabe: Ebenen noch ausstehender Stufen bleiben,
                // alles Übrige der Ressource fliegt (Zielraster selbst lebt
                // im Session-Handle `targetImage` weiter).
                store.pixelCache.releaseLevels(
                    of: objectID, keeping: Set(pending.map { levels[$0] }))
            }

            // KEEP-Grund aus dem Suchverlauf (Legacy-Semantik, soweit
            // abgeleitet): PASS vorhanden, aber kein Größenvorteil →
            // noSizeBenefit; nichts PASSendes, aber Messungen →
            // qualityRejected; sonst decodeFailed.
            if sawPassingRung {
                keepReason = .noSizeBenefit
            } else if let best = bestFailedSSIM {
                keepReason = .qualityRejected(bestSSIM: best)
            } else if measuredAnything {
                keepReason = .decodeFailed
            }
        }

        /// Opt-in JSONL diagnostics, including rejected and unvisited search levels.
        /// One file per resource avoids interleaved writes from concurrent images.
        private func traceJPEG(target: PixelSize, result: JPEGSearchRung?, disposition: String) {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["PDFTOOLS_JPEG_SEARCH_TRACE"]
                    ?? env["TEST_RUNNER_PDFTOOLS_JPEG_SEARCH_TRACE"], !path.isEmpty else { return }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var row: [String: Any] = [
                    "object": "\(objectID.objectNumber) \(objectID.generation)",
                    "pages": pages, "width": target.width, "height": target.height,
                    "source_width": resource.width, "source_height": resource.height,
                    "source_bytes": originalBytes, "disposition": disposition,
                    "retained_candidates": transforms.count]
                if let dpi = resource.effectiveDPI { row["source_dpi"] = dpi }
                if let result {
                    row["quality"] = result.quality
                    row["bytes"] = result.data.count
                    row["passed"] = result.passed
                    row["runtime_ms"] = result.runtimeMs
                    row["perceptual_score"] = result.perceptualScore
                    if let m = result.measurement {
                        row["ssim"] = m.globalSSIM; row["tile_p05"] = m.p05TileSSIM
                        row["edge"] = m.edgeWeightedScore; row["text"] = m.textRegionScore
                        row["delta_e"] = m.meanDeltaE76
                        if m.psnr.isFinite { row["psnr"] = m.psnr }
                    }
                }
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                data.append(10)
                let file = directory.appendingPathComponent("jpeg-\(objectID.objectNumber)-\(objectID.generation).jsonl")
                if !FileManager.default.fileExists(atPath: file.path) {
                    try data.write(to: file)
                } else {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: data)
                }
            } catch { NSLog("JPEG search trace failed: %@", String(describing: error)) }
        }

        /// Opt-in routing evidence for resources that never enter JPEG search.
        private func traceClassification(imageClass: ImageClass, stats: PixelStats,
                                         verdict: ContentClassifier.Verdict?) {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["PDFTOOLS_JPEG_SEARCH_TRACE"]
                    ?? env["TEST_RUNNER_PDFTOOLS_JPEG_SEARCH_TRACE"], !path.isEmpty else { return }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var row: [String: Any] = [
                    "object": "\(objectID.objectNumber) \(objectID.generation)",
                    "source_width": resource.width, "source_height": resource.height,
                    "source_bytes": originalBytes,
                    "route": imageClass == .photo ? "photo" : "graphics",
                    "unique_color_ratio": stats.uniqueColorRatio,
                    "dominant_color_share": stats.dominantColorShare,
                    "chroma_mean": stats.chromaMean]
                if let verdict {
                    row["content_class"] = String(describing: verdict.contentClass)
                    row["rule"] = verdict.rule
                    row["confidence"] = verdict.confidence
                }
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                data.append(10)
                let file = directory.appendingPathComponent(
                    "classification-\(objectID.objectNumber)-\(objectID.generation).jsonl")
                try data.write(to: file, options: .atomic)
            } catch { NSLog("Classification trace failed: %@", String(describing: error)) }
        }

        /// Smart-Anker: q75 auf dem Zielraster, einmal je Ressource. Jede
        /// Stufe – auch andere Auflösungen – muss bei normaler Ansicht
        /// mindestens so nah am Original liegen. Nur für Smart; Klein ist
        /// bewusst sichtbarer, Qualität hat eigene, strengere Grenzen.
        private func smartAnchorCheck(source: CGImage, target: PixelSize,
                                      targetImage: CGImage, grayscale: Bool,
                                      jpegOptions: ImageCompressionOptions)
            -> BracketedJPEGSearch.AnchorCheck? {
            guard case .adaptive = jpegOptions.qualityPolicy,
                  QualityGatePreset(ssimThreshold: jpegOptions.ssimThreshold) == .smart,
                  let fineSample = CandidateGenerator.referenceSample(
                      original: source, target: target,
                      maxEdge: min(BracketedJPEGSearch.AnchorCheck.sampleEdge,
                                   max(target.width, target.height))),
                  let reference = ImageResampler.resize(targetImage, to: target,
                                                        grayscale: grayscale)
            else { return nil }
            return BracketedJPEGSearch.AnchorCheck(image: reference,
                                                   backend: jpegOptions.jpegBackend,
                                                   sample: fineSample)
        }

        private func jpegPolicy(jpegOptions: ImageCompressionOptions,
                                reference: CGImage,
                                gateClass: QualityGateClass) -> BracketedJPEGSearch.Policy {
            switch jpegOptions.qualityPolicy {
            case .fixed(let quality):
                return .ungated(quality: quality)
            case .adaptive(let ladderQ, let minimumSSIM):
                // Masterplan §10.4 (V2-4) – die Kleinbild-Ausnahme (Kante
                // < 200 → beste Stufe ohne Gate) ist ENTFERNT: Ein kleines
                // Diagramm wird GEPRÜFT. `QualityGates.sample` vergleicht
                // kleine Bilder vollständig (Kanten ≤ 320 = vollständiger
                // Pixelvergleich auf Originalauflösung, Edge-/Text-Gate ohne
                // Downsampling-Artefakte).
                return .bracketed(
                    qLow: ladderQ.min() ?? jpegOptions.jpegQuality,
                    qHigh: ladderQ.max() ?? jpegOptions.jpegQuality,
                    gate: QualityGatePolicy.policy(matching: minimumSSIM,
                                                   imageClass: gateClass),
                    imageClass: gateClass,
                    minimumSSIM: minimumSSIM)
            }
        }

        /// §9.5 – Gated JPEG-Fallback der Screenshot-/LineArt-/Chart-Familie.
        ///
        /// Der Masterplan lässt für diese Klassen JPEG ausdrücklich zu:
        /// „JPEG nur: Small/Target Size · wenn klarer Größenhebel · hinter
        /// graphics/text/edge gates“. Beide Bedingungen werden hart geprüft:
        ///
        ///   1. KLARER GRÖSSENHEBEL – der Kandidat muss auf ≤ die Hälfte der
        ///      Originalbytes kommen (`sizeLeverageThreshold`). Grenzfälle
        ///      bleiben KEEP; das Fallback ist kein zweiter Foto-Pfad.
        ///   2. GATES – die GRAFIK-Politik (strenge Kanten-/Text-Floors,
        ///      §10.6), nicht die Foto-Leiter; Katastrophen-Floor inklusive.
        ///
        /// Nur wenn vorher GAR KEIN verlustfreier Kandidat entstanden ist
        /// (Flate scheiterte am Never-Grow, Palette an Farbe/Gate), wird
        /// überhaupt encodiert – bei echter Vektorgrafik bleibt der Zusatz-
        /// aufwand null und der Kandidatenraum unverändert. Der explizite
        /// Smart-Fotoversuch darf zusätzlich bei 600 DPI konkurrieren;
        /// dieselben Grafik-Gates und der Größenhebel gelten weiterhin.
        private mutating func addGatedJPEGFallback(target: PixelSize,
                                                   targetImage: CGImage,
                                                   grayscale: Bool,
                                                   losslessAdded: Bool) {
            let intermediate = CandidateGenerator.smartPhotoIntermediate(
                resource: resource, target: target, options: options)
            // Klein/Zielgröße (§9.5: „JPEG nur: Small/Target Size · wenn klarer
            // Größenhebel · hinter graphics/text/edge gates“): Der Fallback
            // konkurriert AUCH neben einem verlustfreien Kandidaten. Früher
            // entschied allein Never-Grow – bei der kleineren Klein-Auflösung
            // schaffte Flate es knapp, JPEG wurde nie versucht: Klein lag auf
            // Farbscans bei 203 KB, Smart bei 60 KB (Core-235, 2026-09-30).
            // Gates und Größenhebel bleiben; der Optimierer wählt.
            // Dieselbe Bedingung wie die quantisierte Palette (Planner: Preset
            // Klein oder Zielgröße) – eine Stelle entscheidet die Politik.
            let alongsideLossless = allowsQuantizedPalette
            guard intermediate != nil || alongsideLossless
                    || (!losslessAdded && transforms.isEmpty) else { return }
            let policyTarget = target
            let target = intermediate ?? target
            guard case .adaptive(let ladderQ, let minimumSSIM) = options.qualityPolicy
            else { return }
            guard let raster = intermediate != nil ? decodedRaster(for: target) : targetImage,
                  let reference = ImageResampler.resize(raster, to: target,
                                                        grayscale: grayscale),
                  let original = decodedRaster(for: PixelSize(width: resource.width,
                                                               height: resource.height)),
                  let sourceSample = CandidateGenerator.referenceSample(original: original,
                                                                        target: policyTarget)
            else { return }

            let policy = BracketedJPEGSearch.Policy.bracketed(
                qLow: ladderQ.min() ?? options.jpegQuality,
                qHigh: ladderQ.max() ?? options.jpegQuality,
                gate: QualityGatePolicy.policy(matching: minimumSSIM,
                                               imageClass: .graphics),
                imageClass: .graphics,
                minimumSSIM: minimumSSIM)
            let anchorCheck = smartAnchorCheck(source: original, target: policyTarget,
                                               targetImage: targetImage,
                                               grayscale: grayscale, jpegOptions: options)
            let rungs = autoreleasepool {
                BracketedJPEGSearch.run(reference: reference,
                                        grayscale: grayscale,
                                        backend: options.jpegBackend,
                                        policy: policy,
                                        sourceSample: sourceSample,
                                        anchorCheck: anchorCheck)
            }
            for rung in rungs {
                traceJPEG(target: target, result: rung,
                          disposition: rung.passed ? "graphics-gate-pass" : "graphics-quality-rejected")
            }
            // ALLE bestandenen Stufen mit klarem Größenhebel werden Kandidaten
            // – wie im Foto-Pfad. Früher nur die kleinste: Verletzte die im
            // Optimierer die Katastrophen-Grenze, blieb die Ressource im
            // Original, obwohl eine sichere Stufe (höhere Qualität) existierte
            // (USGS-Karte: 51 Kacheln). Die Wahl bleibt beim Optimierer.
            let admissible = rungs.filter { rung in
                rung.passed && (originalBytes < 0
                    || rung.data.count
                        <= Int(Double(originalBytes) * Self.sizeLeverageThreshold))
            }
            guard !admissible.isEmpty else {
                // Kein passender Kandidat: der KEEP-Grund (noSizeBenefit /
                // paletteGateFailed) bleibt die wahrhafte Erklärung.
                return
            }
            for rung in admissible where hasSearchBudget {
                appendJPEGCandidate(rungResult: rung, rung: target, rungIndex: 0,
                                    grayscale: grayscale, jpegOptions: options,
                                    reason: "gated JPEG-Fallback der Grafikfamilie: "
                                        + "klarer Größenhebel hinter den "
                                        + "Graphics-Gates (§9.5)")
            }
        }

        /// §9.5 – „klarer Größenhebel“: höchstens die Hälfte der
        /// Originalbytes, sonst kein verlustbehafteter Fallback.
        static let sizeLeverageThreshold = 0.5

        private mutating func appendJPEGCandidate(rungResult: JPEGSearchRung,
                                                  rung: PixelSize,
                                                  rungIndex: Int,
                                                  grayscale: Bool,
                                                  jpegOptions: ImageCompressionOptions,
                                                  reason: String? = nil) {
            // Budget zentral (§9.2): Eine Stufe liefert bis zu zwei
            // Qualitäten – die Prüfung am Stufenbeginn reicht nicht.
            guard hasSearchBudget else {
                traceJPEG(target: rung, result: rungResult, disposition: "budget-skipped")
                return
            }
            let id = CandidateID(
                "jpeg-\(objectID.objectNumber)-\(objectID.generation)"
                + "-r\(rungIndex)-q\(String(format: "%.4f", rungResult.quality))")
            let kind = CandidateKind.jpeg(target: rung,
                                          quality: rungResult.quality,
                                          backend: jpegOptions.jpegBackend,
                                          grayscale: grayscale)
            let candidate = CompressionCandidate(
                id: id,
                objectID: objectID,
                kind: kind,
                metrics: CandidateMetrics(
                    encodedBytes: rungResult.data.count,
                    globalSSIM: rungResult.measurement?.globalSSIM,
                    p05TileSSIM: rungResult.measurement?.p05TileSSIM,
                    edgeScore: rungResult.measurement?.edgeWeightedScore,
                    textScore: rungResult.measurement?.textRegionScore,
                    deltaE76: rungResult.measurement?.meanDeltaE76,
                    psnr: rungResult.measurement?.psnr,
                    expectedRuntimeMs: rungResult.runtimeMs,
                    expectedPeakWorkingBytes: CandidateGenerator.workingBytes(
                        for: rung, components: grayscale ? 1 : 3),
                    compatibilityRisk: CandidateGenerator.compatibilityRisk(kind),
                    semanticRisk: CandidateGenerator.semanticRisk(
                        kind, measurement: rungResult.measurement),
                    perceptualScore: rungResult.perceptualScore),
                isLossless: false,
                pages: pages,
                reason: reason
                    ?? "kleinste gemessene JPEG-Stufe, die das Preset-Gate hält "
                        + "(Bracketed Search §9.3)")
            let action = ImageCompressionAction.jpeg(
                objectID: objectID, target: rung,
                selectedQuality: rungResult.quality, grayscale: grayscale,
                expectedSSIM: rungResult.measurement?.globalSSIM,
                originalEncodedBytes: originalBytes,
                expectedEncodedBytes: rungResult.data.count)
            transforms.append((candidate, action, rungResult.data))
        }

        // MARK: Abschluss

        func finalize() -> Generated {
            // V2-Maps-Perf – Abschluss der Ressource: alle Raster-Cache-
            // Einträge dieser Ressource freigeben (RAII; die entnommenen
            // CGImage-Referenzen leben bei ihren Haltern weiter). Ohne
            // Leiter-Pfad landete hier nur der Zielraster-Eintrag.
            store.pixelCache.release(resource: objectID)
            let keepID = CandidateID(
                "keep-\(objectID.objectNumber)-\(objectID.generation)")
            // KEEP kostet, was im fertigen Dokument daraus wird (verlustfreie
            // Neuverpackung, `repackBarrier`). Mit den Rohbytes bewertet,
            // schlug ein schlechterer Kandidat das Original – Klein wählte
            // Flate (12,6 KB) statt des neu komprimierten Originals (7,7 KB),
            // `scan-like.pdf` wurde doppelt so groß wie in Smart
            // (2026-10-01). Nur bei Konkurrenz berechnet.
            let keepBytes: Int = {
                guard originalBytes > 0, !transforms.isEmpty,
                      // Der Repack zählt nur einmal: Steht er als eigener
                      // Kandidat im Set (CMYK-Race), bleibt KEEP beim Original.
                      !transforms.contains(where: {
                          if case .jpegRepack = $0.candidate.kind { return true }
                          return false
                      }) else { return max(0, originalBytes) }
                return CompressionPlanner.repackBarrier(resource: resource, pixels: pixels)
            }()
            let keepCandidate = CompressionCandidate(
                id: keepID,
                objectID: objectID,
                kind: .keep,
                metrics: CandidateMetrics(
                    encodedBytes: keepBytes,
                    globalSSIM: nil, p05TileSSIM: nil, edgeScore: nil,
                    textScore: nil, deltaE76: nil, psnr: nil,
                    expectedRuntimeMs: 0, expectedPeakWorkingBytes: 0,
                    compatibilityRisk: 0, semanticRisk: 0),
                isLossless: true,
                pages: pages,
                reason: keepReason.explanation)
            let set = CandidateSet(
                resourceID: CandidateSet.resourceID(for: objectID),
                candidates: [keepCandidate] + transforms.map(\.candidate))

            var actions: [CandidateID: ImageCompressionAction] = [
                keepID: .keep(objectID: objectID, reason: keepReason,
                              originalEncodedBytes: originalBytes)]
            var payloadBy: [CandidateID: CandidatePayload] = [:]
            for entry in transforms {
                actions[entry.candidate.id] = entry.action
                if let data = entry.payload {
                    payloadBy[entry.candidate.id] = store.store(
                        data, resource: objectID, candidate: entry.candidate.id,
                        kind: entry.candidate.kind)
                }
            }
            return Generated(set: set, actionsByCandidate: actions,
                             payloadByCandidate: payloadBy,
                             globalsByCandidate: globals,
                             classification: classification)
        }
    }

    // MARK: Auflösungsleiter (§9.4)

    /// Leiter je Preset. Smart: native / bei großem Abstand 8×, 4×, 2× Ziel /
    /// Ziel×1.25 / Ziel / Ziel×0.85. Die Zwischenstufen vermeiden einen
    /// Sprung von extrem hochauflösenden Bildern direkt auf Bildschirm-DPI.
    /// (Zusatzstufen nur, wenn die Quelle ausreichend oversized ist – §9.2
    /// „nicht blind alle Kombinationen erzeugen“). Qualität: native / 300 /
    /// 240 DPI. Klein: 144 / 110 / 96 DPI ohne Native-Stufe. Custom: genau
    /// das Legacy-Ziel.
    static func resolutionLadder(resource: PDFImageResource,
                                 target: PixelSize?,
                                 options: ImageCompressionOptions) -> [PixelSize] {
        let native = PixelSize(width: resource.width, height: resource.height)
        guard case .adaptive = options.qualityPolicy else {
            return [target ?? native]
        }
        let preset = QualityGatePreset(ssimThreshold: options.ssimThreshold)

        func size(atDPI dpi: Double) -> PixelSize? {
            CompressionPlanner.plannedSize(for: resource, options: options, dpi: dpi)
        }

        var rungs: [PixelSize]
        switch preset {
        case .smart, .quality:
            guard let target else { return [native] }
            rungs = [target]
            if let intermediate = smartPhotoIntermediate(resource: resource,
                                                         target: target, options: options) {
                rungs.insert(intermediate, at: 0)
            }
            // „Ausreichend oversized“: mindestens 1,5× die Zielkante.
            let targetEdge = max(target.width, target.height)
            if Double(resource.maxEdge) >= Double(targetEdge) * 1.5 {
                rungs.insert(native, at: 0)
                rungs.insert(PixelSize(
                    width: min(native.width,
                               Int((Double(target.width) * 1.25).rounded())),
                    height: min(native.height,
                                Int((Double(target.height) * 1.25).rounded()))), at: 1)
            }
            if preset == .quality {
                if let dpi240 = size(atDPI: 240) { rungs.append(dpi240) }
            } else {
                rungs.append(PixelSize(
                    width: max(1, Int((Double(target.width) * 0.85).rounded())),
                    height: max(1, Int((Double(target.height) * 0.85).rounded()))))
            }
        case .small:
            rungs = [144, 110, 96].compactMap { size(atDPI: Double($0)) }
            if rungs.isEmpty { rungs = [target ?? native] }
        case .custom:
            rungs = [target ?? native]
        }
        // Never-Upscale + Dedup in Reihenfolge.
        var seen = Set<PixelSize>()
        return rungs.filter {
            $0.width <= native.width && $0.height <= native.height
                && seen.insert($0).inserted
        }
    }

    /// Klein-Rückfallstufen = die Sicherheitsstufen der Smart-Leiter:
    /// 1,25 × Smart-Ziel und – bei ausreichend oversized Quelle (≥ 1,5 ×) –
    /// die native Auflösung. Nie hochskalieren.
    static func smallSafetyLadder(resource: PDFImageResource,
                                  options: ImageCompressionOptions)
        -> (smartTarget: PixelSize?, rungs: [PixelSize]) {
        let native = PixelSize(width: resource.width, height: resource.height)
        guard let smartTarget = CompressionPlanner.plannedSize(
            for: resource, options: options, dpi: ImageCompressionOptions.smart.targetDPI)
        else { return (nil, []) }
        var rungs: [PixelSize] = []
        if Double(resource.maxEdge) >= Double(max(smartTarget.width, smartTarget.height)) * 1.5 {
            rungs.append(native)
        }
        rungs.append(PixelSize(
            width: min(native.width, Int((Double(smartTarget.width) * 1.25).rounded())),
            height: min(native.height, Int((Double(smartTarget.height) * 1.25).rounded()))))
        var seen = Set<PixelSize>()
        return (smartTarget, rungs.filter {
            $0.width <= native.width && $0.height <= native.height
                && $0 != smartTarget && seen.insert($0).inserted
        })
    }

    /// A placement-derived rung; never upscale and never affect other presets.
    static func smartPhotoIntermediate(resource: PDFImageResource,
                                       target: PixelSize,
                                       options: ImageCompressionOptions) -> PixelSize? {
        guard options.experimentalSmartPhotoCandidates == true,
              case .adaptive = options.qualityPolicy,
              QualityGatePreset(ssimThreshold: options.ssimThreshold) == .smart,
              let placementDPI = resource.effectiveDPI, placementDPI > 0,
              let size = CompressionPlanner.plannedSize(for: resource, options: options, dpi: 600),
              size.width <= resource.width, size.height <= resource.height,
              max(size.width, size.height) > max(target.width, target.height),
              max(size.width, size.height) < resource.maxEdge else { return nil }
        return size
    }

    // MARK: Heuristiken der Metadaten

    /// Kompatibilitätsrisiko (heuristisch, verfeinert V2-4): Progressive
    /// Scans/ältere Leser für JPEG, YCCK/APP14 für CMYK, Dekodierer-
    /// Verfügbarkeit für JBIG2. Verlustfreies gilt als risikofrei.
    static func compatibilityRisk(_ kind: CandidateKind) -> Double {
        switch kind {
        case .jpeg: return 0.1
        case .cmykJPEG: return 0.2
        case .jbig2Lossless: return 0.2
        case .ccittG4: return 0.05
        default: return 0
        }
    }

    /// Semantisches Risiko (heuristisch, verfeinert V2-4): Verlustbehaftete
    /// Kandidaten tragen ein Restrisiko, das mit dem gemessenen Text-Score
    /// skaliert; unter 0.9 gilt Text als spürbar gefährdet.
    static func semanticRisk(_ kind: CandidateKind,
                             measurement: QualityGateMeasurement?) -> Double {
        switch kind {
        case .jpeg, .cmykJPEG:
            if let text = measurement?.textRegionScore, text < 0.9 { return 0.3 }
            return 0.05
        default:
            return 0
        }
    }

    static func workingBytes(for size: PixelSize, components: Int) -> Int64 {
        Int64(size.pixelCount * components)
    }

    static func actionCandidateID(kind: CandidateKind,
                                  objectID: PDFObjectID) -> CandidateID {
        let base = "\(objectID.objectNumber)-\(objectID.generation)"
        switch kind {
        case .keep: return CandidateID("keep-\(base)")
        case .flate: return CandidateID("flate-\(base)")
        case .indexedFlate(_, let entries, let bpc):
            return CandidateID("indexed-\(base)-e\(entries)-b\(bpc)")
        case .ccittG4: return CandidateID("g4-\(base)")
        case .jbig2Lossless: return CandidateID("jbig2-\(base)")
        case .jpegRepack: return CandidateID("repack-\(base)")
        case .cmykJPEG(_, let quality):
            return CandidateID("cmyk-\(base)-q\(String(format: "%.4f", quality))")
        default:
            return CandidateID("candidate-\(base)")
        }
    }
}

// MARK: - Messraster (P0.1)

extension CandidateGenerator {
    /// Kante des Qualitäts-Messrasters für eine Ressource mit Ziel-Pixelgröße.
    ///
    /// Gemessen wird immer gegen das ORIGINAL (Review 2026-09-26, P1), aber
    /// höchstens in der Auflösung, die die DPI-Politik als Ziel erlaubt.
    /// Vorher lag das Raster fest bei 320 px: Ein auf 150 DPI verkleinertes
    /// Foto (163 px) wurde dafür hochskaliert und fiel allein wegen der
    /// erlaubten Verkleinerung durch (Foto-Regression, 54 % statt 95 %).
    /// Stufen UNTER dem Ziel und Farbwandlungen bleiben auf diesem Raster
    /// voll messbar. Ohne Ziel (keine Platzierung/kein Resize) gilt 320 px.
    static func measurementEdge(target: PixelSize?) -> Int {
        guard let target else { return QualityMetrics.sampleEdge }
        return max(16, min(QualityMetrics.sampleEdge, max(target.width, target.height)))
    }

    /// Referenzstichprobe des Originals auf dem Messraster – IMMER mit
    /// demselben Resampler verkleinert, der auch Kandidaten auf das Raster
    /// bringt. Zwei verschiedene Filter (CoreGraphics-Zeichnen für die
    /// Referenz, Produktions-Resampler für den Kandidaten) kosteten SSIM ohne
    /// echten Verlust: unter 320 px 0,94 statt ≈ 1 (P0.1), auf dem vollen
    /// 320-px-Raster bei körnigen Scans/Fotos 0,87–0,93 selbst für ein
    /// UNVERÄNDERTES Bild (P0.3 – dadurch fielen JPEG-Kandidaten durch,
    /// größere MRC-Zerlegungen gewannen, Fotos blieben unverkleinert).
    ///
    /// Die Referenz nimmt denselben Weg wie ein Kandidat auf Zielgröße:
    /// Original → Zielgröße → Messraster. Das Raster ist auf Vielfache von 8
    /// gerundet (203 → 200 px); ging die Referenz direkt Original → 200, der
    /// Kandidat aber Original → 203 → 200, bestrafte die doppelte Umrechnung
    /// feine Linien und Beschriftungen ohne echten Verlust (USGS-Karte: 19–51
    /// Kacheln blieben im Original). So unterscheidet beide nur die Kodierung.
    static func referenceSample(original: CGImage, target: PixelSize?,
                                maxEdge: Int? = nil) -> QualityGates.Sample? {
        let edge = maxEdge ?? measurementEdge(target: target)
        var base = original
        if let target, target.width < original.width || target.height < original.height,
           let atTarget = ImageResampler.resize(original, to: target, components: 3) {
            base = atTarget
        }
        guard let size = QualityGates.sampleSize(width: base.width,
                                                 height: base.height, maxEdge: edge),
              let reduced = ImageResampler.resize(base, to: size, components: 3)
        else { return nil }
        return QualityGates.sample(reduced, maxEdge: edge)
    }
}


