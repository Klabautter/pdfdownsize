import Foundation

/// Masterplan Schritt 5/7 – DER `CompressionPlan` ist die einzige Quelle der
/// Wahrheit für die Compression.
///
/// Estimator und Executor lesen denselben Plan; keiner von beiden trifft eigene
/// Bildentscheidungen. Damit ist die Schätzung per Konstruktion konsistent zum
/// Ergebnis (Masterplan Finding 11).

// MARK: - Zielgröße

struct PixelSize: Hashable, Codable, Sendable {
    let width: Int
    let height: Int

    var pixelCount: Int { width * height }
}

// MARK: - Warum ein Bild unangetastet bleibt

enum KeepReason: Hashable, Codable, Sendable {
    /// Auflösung und Kantenlänge liegen im Rahmen.
    case withinBudget
    /// Zu klein, als dass eine Transformation etwas brächte.
    case tooSmall
    /// Zu viele Pixel, um sie sicher zu dekodieren.
    case pixelBudgetExceeded(pixels: Int)
    /// Graustufen angefordert, aber das Bild ist bereits grau.
    case alreadyGrayscale
    /// S/W-Scan (1-bit oder exakt zweiwertig) – Bilevel-Politik `.keep`.
    case bilevelKept
    /// Der Plan würde das Bild vergrößern – niemals zulässig.
    case neverUpscale
    /// Capability-Politik verbietet die Transformation.
    case capability(ImageTransformCapability)
    /// Die Pixel waren nicht dekodierbar, obwohl die Capability es erlaubte.
    case decodeFailed
    /// Keine Qualitätsstufe erreichte die SSIM-Schwelle.
    case qualityRejected(bestSSIM: Double)
    /// Phase 6C – kein CMYK-Kandidat hielt ΔE-Gate oder Größen-Race gegen
    /// den 6b-Repack; das Feld gehört dem verlustfreien Repack.
    case cmykGateFailed
    /// Das Ergebnis wäre nicht kleiner als das Original.
    case noSizeBenefit
    /// Phase 2b – ein kleinerer Bilevel-Kandidat war nicht bitidentisch und
    /// wurde deshalb verworfen.
    case bilevelGateFailed
    /// V2-3b (§9.6) – ein Exact-Palette-Kandidat hat das Bitgenau-Gate
    /// nicht bestanden (Palette + Indizes rekonstruierten die Pixel nicht);
    /// das Bild bleibt unangetastet.
    case paletteGateFailed
    /// V2-4 (§10.3) – kein verlustbehafteter Kandidat hielt den unverhandel-
    /// baren Katastrophen-Floor (auch hinter Custom/fixed geltend,
    /// Produktsicherheit): massiver Struktur-/Text-/Kantenabsturz. Die
    /// Nutzerwahl wird nicht durch Ästhetik überstimmt – nur Katastrophen
    /// werden nicht ausgeliefert.
    case catastrophicFloorFailed

    var explanation: String {
        switch self {
        case .withinBudget: return "innerhalb der Zielauflösung"
        case .tooSmall: return "zu klein"
        case .pixelBudgetExceeded(let pixels):
            return "über dem Pixelbudget (\(pixels) Pixel)"
        case .alreadyGrayscale: return "bereits Graustufen"
        case .bilevelKept: return "S/W-Scan unangetastet (Einstellung)"
        case .neverUpscale: return "keine Vergrößerung"
        case .capability(let capability): return capability.reason
        case .decodeFailed: return "Pixel nicht dekodierbar"
        case .qualityRejected(let ssim):
            return String(format: "Qualität nicht erreichbar (bestes SSIM %.4f)", ssim)
        case .cmykGateFailed:
            return "CMYK-Kandidat fiel durch ΔE-Gate oder Größen-Race (6b bleibt)"
        case .noSizeBenefit: return "kein Größenvorteil"
        case .bilevelGateFailed: return "Bilevel-Kandidat nicht bitidentisch"
        case .paletteGateFailed: return "Palette-Kandidat nicht bitgenau"
        case .catastrophicFloorFailed:
            return "Katastrophen-Floor verletzt (§10.3 Produktsicherheit)"
        }
    }
}

// MARK: - Aktion je Bildobjekt

/// Jede Aktion trägt die Ausgangsgröße mit sich. Dadurch ist der Plan
/// vollständig selbstbeschreibend: Der Estimator braucht keine Rückfrage ans
/// Dokument und keine Verteilungsannahme – er summiert nur noch.
enum ImageCompressionAction: Hashable, Codable, Sendable {
    case keep(objectID: PDFObjectID,
              reason: KeepReason,
              originalEncodedBytes: Int)

    /// Verkleinern ohne Neukodierung der Tonwerte (Grafiken/Screenshots):
    /// das Ergebnis bleibt ein verlustfrei kodierter Stream. `predictor`
    /// steuert die /DecodeParms der Bridge (true = Predictor 15, false = roh):
    /// Race aus beiden, der kleinere gewinnt – beide dekodieren bitidentisch.
    case losslessResize(objectID: PDFObjectID,
                        target: PixelSize,
                        grayscale: Bool,
                        originalEncodedBytes: Int,
                        expectedEncodedBytes: Int,
                        predictor: Bool = true)

    case jpeg(objectID: PDFObjectID,
              target: PixelSize,
              selectedQuality: Double,
              grayscale: Bool,
              expectedSSIM: Double?,
              originalEncodedBytes: Int,
              expectedEncodedBytes: Int)

    /// Phase 6C – kontrollierter CMYK-JPEG-Re-Encode (YCCK, transform 2).
    /// Steht nur im Plan, wenn der Kandidat das ΔE-Gate bestanden UND den
    /// 6b-Repack des Originals unterboten hat; die ICC-/DeviceCMYK-Erklärung
    /// bleibt an der Ersetzung (pdfcore_replace_image_object_cmyk).
    case cmykJpegReencode(objectID: PDFObjectID,
                          target: PixelSize,
                          selectedQuality: Double,
                          originalEncodedBytes: Int,
                          expectedEncodedBytes: Int)

    /// Phase 2b – Bilevel-Race-Ergebnisse. Beide behalten die Originalmaße
    /// (Bilevel wird nie resampelt) und stehen nur im Plan, wenn sie das
    /// Bitidentitäts-Gate bestanden und kleiner als das Original sind.
    case ccittG4(objectID: PDFObjectID,
                 originalEncodedBytes: Int,
                 expectedEncodedBytes: Int)

    case jbig2(objectID: PDFObjectID,
               originalEncodedBytes: Int,
               expectedEncodedBytes: Int)

    /// V2-3b (§9.6) – Exact Palette: verlustfreie Neukodierung als
    /// /Indexed-Farbraum mit Flate + PNG-Prädiktor. Steht nur im Plan, wenn
    /// der exakte Farbscan ≤ 256 Farben ergab UND die Rekonstruktion
    /// (Palette + Indizes) die Pixel BITGENAU reproduziert hat. Die Palette
    /// (paletteComponents Byte je Eintrag) liegt im Plan – er bleibt damit
    /// selbstbeschreibend; die Indizes sind Plan- oder Executor-Bytearbeit.
    /// `quantized`/`dithered`: Median-Cut-Farbreduktion (lossy, nur Small/
    /// Target) statt exakter Palette – deterministische Executor-Rekodierung
    /// braucht beide Flags (Finding 11).
    case indexed(objectID: PDFObjectID,
                 target: PixelSize,
                 bitsPerComponent: Int,
                 paletteComponents: Int,
                 palette: Data,
                 originalEncodedBytes: Int,
                 expectedEncodedBytes: Int,
                 quantized: Bool,
                 dithered: Bool)

    /// V2-7 (§13) – MRC-Seitenbündel: Der Full-Page-Raster-Draw einer
    /// Scan-Seite wird durch Background + Photo-Regionen + FG-Maske ersetzt
    /// (§13.7, Rekonstruktion über die Bridge, NICHT über ein Seitenraster).
    /// Die Aktion hängt am DOMINANTEN Rasterbild; `expectedEncodedBytes` ist
    /// die Summe aller Layer (Bundle, §13.8). Das Original-Raster verwaist
    /// bei der Ausführung und wird vom Writer verworfen.
    case mrc(objectID: PDFObjectID,
             descriptor: MRCCandidateDescriptor,
             originalEncodedBytes: Int,
             expectedEncodedBytes: Int)

    var objectID: PDFObjectID {
        switch self {
        case .keep(let id, _, _): return id
        case .losslessResize(let id, _, _, _, _, _): return id
        case .jpeg(let id, _, _, _, _, _, _): return id
        case .cmykJpegReencode(let id, _, _, _, _): return id
        case .ccittG4(let id, _, _): return id
        case .jbig2(let id, _, _): return id
        case .indexed(let id, _, _, _, _, _, _, _, _): return id
        case .mrc(let id, _, _, _): return id
        }
    }

    var transformsImage: Bool {
        if case .keep = self { return false }
        return true
    }

    /// Streamgröße vor der Operation; -1 wenn das Dokument keine angibt.
    var originalEncodedBytes: Int {
        switch self {
        case .keep(_, _, let bytes): return bytes
        case .losslessResize(_, _, _, let bytes, _, _): return bytes
        case .jpeg(_, _, _, _, _, let bytes, _): return bytes
        case .cmykJpegReencode(_, _, _, let bytes, _): return bytes
        case .ccittG4(_, let bytes, _): return bytes
        case .jbig2(_, let bytes, _): return bytes
        case .indexed(_, _, _, _, _, let bytes, _, _, _): return bytes
        case .mrc(_, _, let bytes, _): return bytes
        }
    }

    /// Erwartete Streamgröße nach Ausführung; nil, wenn das Bild bleibt.
    /// JBIG2 zählt Seitenstrom plus Globals – beide Objekte belegen Bytes.
    var expectedEncodedBytes: Int? {
        switch self {
        case .keep: return nil
        case .losslessResize(_, _, _, _, let bytes, _): return bytes
        case .jpeg(_, _, _, _, _, _, let bytes): return bytes
        case .cmykJpegReencode(_, _, _, _, let bytes): return bytes
        case .ccittG4(_, _, let bytes): return bytes
        case .jbig2(_, _, let bytes): return bytes
        case .indexed(_, _, _, _, _, _, let bytes, _, _): return bytes
        case .mrc(_, _, _, let bytes): return bytes
        }
    }

    /// Größe, die dieses Bild im Ergebnis belegen wird.
    var resultingEncodedBytes: Int {
        expectedEncodedBytes ?? max(originalEncodedBytes, 0)
    }

    var targetSize: PixelSize? {
        switch self {
        case .keep: return nil
        case .losslessResize(_, let target, _, _, _, _): return target
        case .jpeg(_, let target, _, _, _, _, _): return target
        case .cmykJpegReencode(_, let target, _, _, _): return target
        case .ccittG4, .jbig2: return nil
        case .indexed(_, let target, _, _, _, _, _, _, _): return target
        case .mrc: return nil
        }
    }

    var grayscale: Bool {
        switch self {
        case .keep: return false
        case .losslessResize(_, _, let gray, _, _, _): return gray
        case .jpeg(_, _, _, let gray, _, _, _): return gray
        case .cmykJpegReencode: return false
        case .ccittG4, .jbig2: return false
        case .indexed(_, _, _, let paletteComponents, _, _, _, _, _):
            return paletteComponents == 1
        case .mrc: return false
        }
    }

    /// Predictor-Flag des verlustfreien Resizes (true = Predictor 15).
    /// Alle anderen Aktionen melden true (bedeutungslos, nie gelesen).
    var usesPredictor: Bool {
        if case .losslessResize(_, _, _, _, _, let predictor) = self {
            return predictor
        }
        return true
    }
}

// MARK: - Plan

struct CompressionPlan: Equatable, Codable, Sendable {
    /// Stabile Kennung des geplanten Dokuments (Pfad-unabhängig).
    let documentID: String
    let actions: [ImageCompressionAction]
    let metadataPolicy: MetadataPolicy
    let linearizationPolicy: LinearizationPolicy
    /// Phase 3b – steuert den Content-Hash-Dedup im Executor.
    let dedupPolicy: DedupPolicy
    /// Phase 5a – steuert Font-Dedup + Unused-Font-GC im Executor.
    let fontPolicy: FontPolicy
    /// Phase 5b/V2-8 – Font-Subsetting-Politik. Der Plan trägt sie für den
    /// Trace; die AUSFÜHRBAREN Entscheidungen stehen in `fontSubsets`
    /// (selektiver Pfad, §14).
    var fontSubsettingPolicy: FontSubsettingPolicy = .off
    /// Phase 3c – Kompatibilitätsverhalten; der Executor liest daraus, ob
    /// der JPEG-Repack progressive Scans schreiben darf.
    let compatibilityPolicy: CompatibilityPolicy
    /// Phase 9 – JPEG-Kodierer der JPEG-Aktionen. Steht im Plan, damit der
    /// Executor beim deterministischen Neukodieren (verworfene Artefakte)
    /// exakt dieselben Kandidaten erzeugt wie die Planung.
    var jpegBackend: JPEGBackend = .mozjpeg
    /// Summe der aktuell im Dokument belegten Bild-Streambytes.
    let originalImageBytes: Int
    /// Gesamtgröße des Eingabedokuments in Bytes.
    let originalDocumentBytes: Int
    /// Phase 3-Followup – Flate-Aufwand des Struktur-/Repack-Passes. Nur
    /// `.maximum` schaltet den Zopfli-Repack großer Flate-Streams im
    /// Executor frei (nur das interne Maximum-Preset).
    var flatePolicy: FlatePolicy = .standard

    // MARK: Phase V2-3a (§5.8) – Plan-Felder der Candidate Engine
    //
    // Der Plan behält `actions` als ausführbare Wahrheit (Phase A); die
    // Candidate-Daten kommen ADDITIV dazu. Seit V2-11 sind sie immer
    // gefüllt – die Candidate Engine ist der EINZIGE Pfad (§25).

    /// Kandidatenraum je Bildressource (§5.6); jeder Satz enthält KEEP.
    var candidateSets: [CandidateSet] = []
    /// Die lokale Wahl je Ressource inkl. Rückstufungsleiter (§5.7).
    var decisions: [ResourceDecision] = []
    /// Dokumentweites Optimierungsziel (§5.1).
    var goal: CompressionGoal = .balanced
    /// Entscheidungspfad: 2 = Candidate Engine (§9) – seit V2-11 der
    /// EINZIGE Produktionspfad. Das Feld bleibt für das Trace-Schema.
    var traceVersion: Int = 1

    // MARK: Phase V2-8 (§14) – selektive Font-Entscheidungen + Resource GC
    //
    // Additive Felder wie die Candidate-Daten oben.

    /// Gewählte Font-Subset-Entscheidungen (§14.1): Der Executor subsettet
    /// GENAU diese Objekte einzeln mit je-Font-QA (§14.4).
    var fontSubsets: [FontOptimizer.Decision] = []
    /// V2-8 (§14.6) – Resource-GC-Politik; `.auto` läuft im
    /// traceVersion-2-Plan (Candidate Engine).
    var resourceGCPolicy: ResourceGCPolicy = .off

    var transformedActions: [ImageCompressionAction] {
        actions.filter(\.transformsImage)
    }

    var keptActions: [ImageCompressionAction] {
        actions.filter { !$0.transformsImage }
    }

    func action(for objectID: PDFObjectID) -> ImageCompressionAction? {
        actions.first { $0.objectID == objectID }
    }

    /// Menschenlesbare Begründung je unangetastetem Bild – landet in Reports
    /// und macht „warum wurde nichts kleiner?" beantwortbar.
    var keepReasons: [(objectID: PDFObjectID, reason: String)] {
        keptActions.compactMap { action in
            guard case .keep(let id, let reason, _) = action else { return nil }
            return (id, reason.explanation)
        }
    }
}

// MARK: - Zwischenartefakte

/// Die beim Planen bereits erzeugten JPEG-Daten.
///
/// Sie sind bewusst NICHT Teil des `CompressionPlan`: Der Plan bleibt ein
/// serialisierbares Entscheidungsdokument, die Artefakte sind flüchtig. Der
/// Executor benutzt sie, wenn er sie hat, und kodiert sonst mit exakt den
/// Planparametern neu – das Ergebnis ist in beiden Fällen dasselbe.
struct CompressionPlanArtifacts {
    /// Obergrenze des Zwischenspeichers.
    ///
    /// Der Cache ist eine reine Beschleunigung: Was er nicht vorhält, kodiert
    /// der Executor mit exakt denselben Planparametern neu – das Ergebnis ist
    /// identisch. Ohne Grenze hielte ein 300-Seiten-Scan dagegen jedes
    /// re-kodierte Bild gleichzeitig im Speicher.
    static let budgetBytes = 64 * 1024 * 1024

    private var payloads: [PDFObjectID: Data] = [:]
    /// Phase 2b – /JBIG2Globals je Bildobjekt (gehört zum JBIG2-Kandidaten
    /// und wird vom Executor als eigenes Objekt anlegen lassen).
    private var jbig2Globals: [PDFObjectID: Data] = [:]
    private(set) var totalBytes = 0
    /// Wie viele Bilder wegen des Budgets nicht zwischengespeichert wurden –
    /// sichtbar in Reports, damit „warum ist das langsam?" beantwortbar ist.
    private(set) var droppedPayloads = 0

    init() {}

    mutating func store(_ data: Data, for objectID: PDFObjectID) {
        guard totalBytes + data.count <= Self.budgetBytes else {
            droppedPayloads += 1
            return
        }
        if let existing = payloads.updateValue(data, forKey: objectID) {
            totalBytes -= existing.count
        }
        totalBytes += data.count
    }

    /// Globals zusätzlich zum Seitenstrom; beides zählt ins Budget.
    mutating func storeGlobals(_ data: Data, for objectID: PDFObjectID) {
        guard !data.isEmpty else { return }
        guard totalBytes + data.count <= Self.budgetBytes else {
            droppedPayloads += 1
            return
        }
        if let existing = jbig2Globals.updateValue(data, forKey: objectID) {
            totalBytes -= existing.count
        }
        totalBytes += data.count
    }

    func payload(for objectID: PDFObjectID) -> Data? {
        payloads[objectID]
    }

    func globals(for objectID: PDFObjectID) -> Data? {
        jbig2Globals[objectID]
    }
}
