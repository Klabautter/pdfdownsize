import Foundation

// MARK: - Masterplan §5.5/§5.6/§5.7 – Kandidaten-Domänenmodell
//
// Der Sprung von „eine Aktion pro Bild“ zu „Kandidatenraum + Wahl“: Jede
// Bildressource bekommt ein CandidateSet (KEEP immer an Position 0), der
// Planner wählt daraus lokal und übersetzt die Wahl in die bestehende
// ImageCompressionAction (§5.8 Phase A). CandidateKind deckt §5.2 vollständig
// ab – indexedFlate (Palette, V2-3b), CCITT/JBIG2-Input (V2-Folgewelle) und
// mrc (V2-7) sind als Cases definiert, werden in 3a aber NICHT erzeugt.

/// Stabile, deterministische Kennung eines Kandidaten innerhalb eines Plans.
struct CandidateID: Hashable, Codable, Sendable {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// §13.8 – Beschreiber eines MRC-Kandidaten (Maske + Hintergrund + Foto-
/// Regionen einer Scan-Seite).
///
/// Die §13.8-Felder (Maske/Auflösung/Qualität) beschreiben die Politik,
/// die Ausführungsfelder (V2-7) machen den Plan selbstbeschreibend: Der
/// Executor kann das Bundle über den Deskriptor deterministisch neu
/// erzeugen (Segmentierung + Kodierung mit denselben Konstanten), ohne
/// dass Payloads zwingend im Speicher liegen müssen.
struct MRCCandidateDescriptor: Hashable, Codable, Sendable {
    let pageIndex: Int
    let maskDPI: Double
    let backgroundDPI: Double
    let backgroundQuality: Double
    let photoDPI: Double
    let photoQuality: Double

    // MARK: Ausführung (V2-7)

    /// Kodierung der Vordergrund-Maske (lossless, §13.6): JBIG2 bevorzugt,
    /// CCITT G4 als verifizierter Fallback. Kein Lossy-JBIG2 (§13.11).
    var maskCodec: MRCMaskCodec = .jbig2
    /// Dominantes Vollbild-Raster (Objektidentität) – Adressierung der
    /// Seitenrekonstruktion.
    var imageObjectNumber: Int = 0
    var imageObjectGeneration: Int = 0
    /// Name des Rasters im Seiten-/Resources-Namespace (ohne führenden Slash).
    var resourceName: String = ""
    /// Maskenmaße = Original-Rastermaße (Maske bleibt auf Scan-Auflösung).
    var maskWidth: Int = 0
    var maskHeight: Int = 0
    /// Hintergrund-Layer-Maße (Pixel).
    var backgroundWidth: Int = 0
    var backgroundHeight: Int = 0
    /// Hintergrund-Kanäle: 1 = grau, 3 = RGB.
    var backgroundComponents: Int = 3

    /// Photo-Regionen als flache Rect-Liste (x, y, width, height je Region,
    /// BILDPIXELRAUM mit oben-links-Ursprung – dieselbe Konvention wie die
    /// Sub-Rects der Bridge). Je Region folgen in `photoWidths`/
    /// `photoHeights`/`photoComponents` die Layer-Maße.
    var photoRects: [Double] = []
    var photoWidths: [Int] = []
    var photoHeights: [Int] = []
    var photoComponents: [Int] = []

    var photoRegionCount: Int { photoRects.count / 4 }
}

/// Kodierung der Vordergrund-Maske (§13.6) – beide verlustfrei.
enum MRCMaskCodec: String, Codable, Sendable {
    /// Lossless JBIG2 (Refinement im Shim hart aus), Symbolpfad mit Globals.
    case jbig2
    /// CCITT G4 – verifizierter Fallback, wenn das JBIG2-Render-Gate die
    /// Bitidentität nicht bestätigt.
    case ccittG4
}

/// Art eines Kandidaten – exakt die Aufzählung aus Masterplan §5.2.
enum CandidateKind: Hashable, Codable, Sendable {
    /// Bild bleibt unangetastet (immer Candidate 0, §9.1).
    case keep

    case jpeg(target: PixelSize,
              quality: Double,
              backend: JPEGBackend,
              grayscale: Bool)

    /// Verlustfrei kodierter Stream (Resize + PNG-Prädiktor + Flate).
    case flate(target: PixelSize, grayscale: Bool, predictor: Bool)

    /// Exact-Palette (V2-3b) – in 3a definiert, nicht erzeugt.
    case indexedFlate(target: PixelSize, paletteEntries: Int, bitsPerComponent: Int)

    /// CCITT G4 aus dem Bilevel-Race (§9.7); CCITT-INPUT-Decode folgt separat.
    case ccittG4

    /// Lossless JBIG2 aus dem Bilevel-Race (§9.7).
    case jbig2Lossless

    /// Kontrollierter YCCK-Re-Encode (§9.8, Phase 6C).
    case cmykJPEG(target: PixelSize, quality: Double)

    /// Verlustfreier JPEG-Repack des Originalstroms (Executor-seitig, 6b).
    case jpegRepack(progressive: Bool)

    // Font-/Ressourcen-Kandidaten (V2-8) – definiert, in 3a nicht erzeugt.
    case fontKeep
    case fontSubset
    case resourceDedup

    /// MRC-Seitenbündel (V2-7) – definiert, in 3a nicht erzeugt.
    case mrc(MRCCandidateDescriptor)
}

// MARK: - §10.2 DistortionVector (V2-4)

/// Masterplan §10.2 – Verzerrungsvektor eines Kandidaten über die Dimensionen
/// des Multi-Gates.
///
/// BEWUSSTE SEMANTIK-WAHL (dokumentiert): Der Vektor speichert je Dimension
/// die QUALITÄT in [0…1] – 1.0 heißt verlustfrei, niedriger heißt schlechter –
/// NICHT die Verzerrung. Der Optimizer (§10.5/§10.6) vergleicht damit Qualität
/// direkt und monoton: höher ist immer besser, eine „Loss“-Umrechnung
/// (1 − SSIM) würde die Vergleichsrichtung nur drehen, ohne Information zu
/// gewinnen. Die Feldnamen folgen dem Masterplan; „…Loss“ ist als
/// „Verlust-Dimension“ zu lesen, der Wert die verbliebene Qualität:
///
///   global     ← globalSSIM (globale Strukturelle Ähnlichkeit)
///   localWorst ← p05TileSSIM (5-%-Perzentil der Kachel-SSIMs)
///   edgeLoss   ← edgeWeightedScore (kantengewichtete Bewertung)
///   textLoss   ← textRegionScore (nil = keine Text-Kacheln erkannt)
///   colorLoss  ← ΔE76 in Qualität überführt: max(0, 1 − ΔE/8). Referenz 8
///                ist die weiteste ΔE-Grenze der Preset-Matrix (small/photo);
///                nil bei Graustufen (keine ΔE-Messung).
///
/// Ohne Messung (KEEP, verlustfreie Kandidaten ohne Gate) sind alle Felder
/// nil – die Skalarisierung behandelt das als Qualität 1.0.
struct DistortionVector: Hashable, Codable, Sendable {
    let global: Double?
    let localWorst: Double?
    let edgeLoss: Double?
    let textLoss: Double?
    let colorLoss: Double?
}

/// §5.5 – gemessene Kennzahlen eines Kandidaten. Distortion-Felder sind nil,
/// wenn nichts gemessen wurde (KEEP, Verlustfreies ohne Gate).
struct CandidateMetrics: Hashable, Codable, Sendable {
    let encodedBytes: Int

    let globalSSIM: Double?
    let p05TileSSIM: Double?
    let edgeScore: Double?
    let textScore: Double?
    let deltaE76: Double?
    let psnr: Double?

    let expectedRuntimeMs: Double
    let expectedPeakWorkingBytes: Int64

    let compatibilityRisk: Double
    let semanticRisk: Double

    /// Perzeptueller Score des Kandidaten (nil ohne Messung: KEEP,
    /// verlustfrei ohne Gate, CMYK mit eigenem ΔE-Gate). Quelle des
    /// Katastrophen-AND-Gates in `RateDistortionOptimizer.eligibility`.
    /// Am Ende der Property-Liste, damit alle bestehenden
    /// Initialisierungen positionsstabil bleiben.
    let perceptualScore: Double?

    /// Expliziter Initialisierer (statt Memberwise-Synthese): Die
    /// Production baut Metriken positionsstabil, der Score kommt als
    /// optionales Suffix – bestehende Aufrufe kompilieren unverändert.
    init(encodedBytes: Int,
         globalSSIM: Double?,
         p05TileSSIM: Double?,
         edgeScore: Double?,
         textScore: Double?,
         deltaE76: Double?,
         psnr: Double?,
         expectedRuntimeMs: Double,
         expectedPeakWorkingBytes: Int64,
         compatibilityRisk: Double,
         semanticRisk: Double,
         perceptualScore: Double? = nil) {
        self.encodedBytes = encodedBytes
        self.globalSSIM = globalSSIM
        self.p05TileSSIM = p05TileSSIM
        self.edgeScore = edgeScore
        self.textScore = textScore
        self.deltaE76 = deltaE76
        self.psnr = psnr
        self.expectedRuntimeMs = expectedRuntimeMs
        self.expectedPeakWorkingBytes = expectedPeakWorkingBytes
        self.compatibilityRisk = compatibilityRisk
        self.semanticRisk = semanticRisk
        self.perceptualScore = perceptualScore
    }

    /// Q = min über die gemessenen strukturellen Metriken – dieselbe Formel
    /// wie `QualityGateMeasurement.qualityScore`. Ohne Messung (lossless/
    /// KEEP) gilt 1.0. Grundlage des klassenneutralen Pareto-Prunings und
    /// der Gate-Rekonstruktion (V2-4).
    var qualityScore: Double {
        let values = [globalSSIM, p05TileSSIM, edgeScore, textScore].compactMap { $0 }
        return values.min() ?? 1.0
    }

    /// §10.2 – Der Distortion-Vektor des Kandidaten (abgeleitet aus den
    /// Rohmetriken; siehe Dokumentation `DistortionVector`).
    var distortion: DistortionVector {
        DistortionVector(
            global: globalSSIM,
            localWorst: p05TileSSIM,
            edgeLoss: edgeScore,
            textLoss: textScore,
            colorLoss: deltaE76.map { max(0, 1 - $0 / 8.0) })
    }

    /// §10.1/§10.3/§10.6 – Die Messung in Gate-Form rekonstruiert, damit
    /// der Optimizer dieselbe Verdict-Mechanik nutzt wie Generator und
    /// Legacy-Leiter. Kachel-Einzelwerte sind im Kandidaten nicht mitgeführt;
    /// das Verdict braucht sie nicht. `nil`, wenn keine strukturelle Messung
    /// vorliegt (KEEP, verlustfreie Kandidaten, CMYK-YCCK mit eigenem ΔE-Gate).
    var gateMeasurement: QualityGateMeasurement? {
        guard let globalSSIM, let p05TileSSIM, let edgeScore else { return nil }
        return QualityGateMeasurement(
            globalSSIM: globalSSIM,
            p05TileSSIM: p05TileSSIM,
            edgeWeightedScore: edgeScore,
            textRegionScore: textScore,
            meanDeltaE76: deltaE76,
            psnr: psnr ?? 0,
            tileSSIMs: [],
            tileGrid: QualityGates.tileGrid,
            isColor: deltaE76 != nil)
    }
}

/// §5.5 – EIN Kandidat einer Ressource.
struct CompressionCandidate: Hashable, Codable, Sendable {
    let id: CandidateID
    let objectID: PDFObjectID?
    let kind: CandidateKind
    let metrics: CandidateMetrics
    let isLossless: Bool
    let pages: [Int]
    let reason: String
}

// MARK: - §5.6 CandidateSet

/// Kandidatenraum EINER Bildressource. MUSS KEEP enthalten (§5.6); der
/// Generator garantiert das, indem KEEP@0 immer zuerst steht.
struct CandidateSet: Hashable, Codable, Sendable {
    /// „123 0“ – Objektidentität als String (§5.6).
    let resourceID: String
    let candidates: [CompressionCandidate]

    init(resourceID: String, candidates: [CompressionCandidate]) {
        self.resourceID = resourceID
        self.candidates = candidates
    }

    static func resourceID(for objectID: PDFObjectID) -> String {
        "\(objectID.objectNumber) \(objectID.generation)"
    }

    var keepCandidate: CompressionCandidate? {
        candidates.first { $0.kind.isKeep }
    }
}

extension CandidateKind {
    /// KEEP-Äquivalente: `.keep` (Bild bleibt) und `.fontKeep` (Font bleibt).
    /// V2-8: Damit trägt auch ein Font-Set einen Keep-Kandidaten (§9.1-
    /// Analogon) – Rückstufung und Trace behandeln ihn als unangetastet.
    var isKeep: Bool {
        switch self {
        case .keep, .fontKeep: return true
        default: return false
        }
    }
}

// MARK: - §5.7 ResourceDecision

/// Die Wahl des Planners je Ressource inkl. Rückstufungsleiter:
/// `candidateIDsBySafety` ordnet aggressiv → konservativ → lossless → KEEP.
/// V2-5 (Rollback) stuft entlang dieser Leiter zurück.
struct ResourceDecision: Equatable, Codable, Sendable {
    let resourceID: String
    var selectedCandidateID: CandidateID

    let candidateIDsBySafety: [CandidateID]

    let classification: ContentClass
    let features: ContentFeatures?

    let pages: [Int]
    let reason: String
}

extension ResourceDecision {

    /// Rückstufungsleiter: Verlustbehaftete Kandidaten aufsteigend nach
    /// Bytes (der kleinste ist der aggressivste), dann die verlustfreien,
    /// dann KEEP als letzte Stufe.
    static func safetyLadder(of candidates: [CompressionCandidate]) -> [CandidateID] {
        // Sekundärschlüssel CandidateID: Bei Byte-Gleichständen (praktisch
        // nie, aber konstruierbar) bleibt die Reihenfolge deterministisch –
        // `sorted` ist nicht stabil.
        func rank(_ candidate: CompressionCandidate) -> String {
            candidate.id.rawValue
        }
        let lossy = candidates
            .filter { !$0.isLossless }
            .sorted { a, b in
                a.metrics.encodedBytes != b.metrics.encodedBytes
                    ? a.metrics.encodedBytes < b.metrics.encodedBytes
                    : rank(a) < rank(b)
            }
        let lossless = candidates
            .filter { $0.isLossless && !$0.kind.isKeep }
            .sorted { a, b in
                a.metrics.encodedBytes != b.metrics.encodedBytes
                    ? a.metrics.encodedBytes < b.metrics.encodedBytes
                    : rank(a) < rank(b)
            }
        let keep = candidates.filter { $0.kind.isKeep }
        return (lossy + lossless + keep).map(\.id)
    }
}

// MARK: - Migration (§5.2 → bestehende photo/graphics-Welt)

extension ContentClass {

    /// Grobe Rückübersetzung der Legacy-Klassifikation in die V2-Klassen.
    /// Nur für Entscheidungsaufzeichnungen, wenn die V2-Feature-Extraktion
    /// nichts lieferte (nicht dekodierbare Randfälle). „graphics“ wird als
    /// screenshot geführt – die dominante Klasse des Legacy-Grafikpfads.
    init(imageClass: ImageClass) {
        switch imageClass {
        case .photo: self = .photo
        case .graphics: self = .screenshot
        }
    }
}
