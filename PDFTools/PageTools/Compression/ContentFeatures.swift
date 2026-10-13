import Foundation

// MARK: - Masterplan §5.2 – ContentClass

/// Inhaltsklasse eines Bildinhalts – V2-Auflösung der bisherigen Zweiwertigkeit
/// photo/graphics (`ImageClass`). Bilevel bleibt zusätzlich als harte
/// Pixeleigenschaft verfügbar (`BilevelDetection`); hier erscheint es als
/// `scanBilevel`, wenn die Zweiwertigkeit nachgewiesen ist.
///
/// `unknown` ist ein echtes Ergebnis und wird konservativ behandelt –
/// ausdrücklich NICHT als photo (Masterplan §8.3, Prinzip 11).
enum ContentClass: String, Codable, Sendable, CaseIterable {
    case photo
    case scanContinuous
    case scanBilevel
    case screenshot
    case lineArt
    case chart
    case mixedRaster
    case mapTechnical
    case unknown
}

// MARK: - Masterplan §5.3 – ContentFeatures

/// Merkmale eines Bildinhalts, aus denen die `ContentClass` deterministisch
/// bestimmt wird. Alle Werte stammen aus downgesampelten Stichproben
/// (Multi-Resolution-Sampling, §8.2) – keine Vollbild-Computer-Vision.
struct ContentFeatures: Equatable, Codable, Sendable {

    /// Kantenlänge der feinsten verwendeten Stichprobe (128 oder 256).
    let sampleWidth: Int
    let sampleHeight: Int

    // Farbe (64×64-Stichprobe)
    /// Anteil quantisierter 4-bit-Farbschlüssel an den opaken Bildpunkten.
    let uniqueColorRatio: Double
    /// Exakte RGB-Tripel der Stichprobe, wenn klein (Palette/Index-Hinweis);
    /// nil = zu viele (>= 513) für einen sinnvollen Hinweis.
    let exactColorCountHint: Int?
    /// Mittlerer Chroma-Abstand max(RGB)−min(RGB) (0 = Graustufen).
    let chromaMean: Double
    /// Anteil der Bildpunkte mit Chroma ≤ 2 (nahezu grau).
    let grayscaleScore: Double

    // Statistik (64×64-Stichprobe, Luminanz)
    /// Shannon-Entropie des 64-Bin-Luminanzhistogramms in bit (0…6).
    let entropy: Double
    /// Mittlere Varianz der 8×8-Kachelraster (feinste Stichprobe).
    let localVarianceMean: Double
    /// 90.-Perzentil (nearest rank) der Kachel-Varianzen.
    let localVarianceP90: Double

    // Struktur (feinste Stichprobe, Sobel)
    /// Anteil der Innenpixel mit Sobel-Magnitude ≥ 32 (wie QualityGates).
    let edgeDensity: Double
    /// Anteil horizontaler Kanten an den Kantenpixeln (|gy| dominiert).
    let horizontalEdgeRatio: Double
    /// Anteil vertikaler Kanten an den Kantenpixeln (|gx| dominiert).
    let verticalEdgeRatio: Double
    /// Anteil diagonaler/sonstiger Kanten an den Kantenpixeln.
    let diagonalEdgeRatio: Double

    // Dokumentähnlichkeit (nur kleine binäre Stichprobe, 64×64)
    /// Zusammenhängende Komponenten je Tinten-Pixel (Text: hoch).
    let connectedComponentDensity: Double?
    /// Anteil der Komponenten mit Fläche ≤ 4 px (Glyphenfragment-Charakter).
    let smallComponentRatio: Double?

    // Flächencharakter (Kachelraster auf der feinsten Stichprobe)
    /// Anteil flacher Kacheln (Varianz ≤ 25, Vollton-/Leerflächen).
    let flatAreaRatio: Double
    /// Anteil Textur-Kacheln (Varianz > 25, ohne harte Kanten – Fotomaterial).
    let textureRatio: Double
    /// Anteil Text-Kacheln (Schwarz-Weiß-Wechsel + Bimodalität, Kriterien
    /// analog `QualityGates.textRegionScore`).
    let textLikeTileRatio: Double

    /// Vertrauen der Klassifikation (0…1); die Regelwerk-Semantik steht in
    /// `ContentClassifier`.
    let confidence: Double
}

// MARK: - Masterplan §5.4 – PageContentClass / PageAnalysis

/// Seitenklasse nach Masterplan §5.4. `rasterScanWithOCR` meint eine
/// Scan-Seite mit vermutlich unsichtbarem OCR-Text-Overlay.
enum PageContentClass: String, Codable, Sendable, CaseIterable {
    case bornDigital
    case rasterScan
    case rasterScanWithOCR
    case mixed
    case unknown
}

/// Analyse EINER Seite (Masterplan §5.4). Grundlage der Scan-Erkennung und
/// später des MRC-Pfads (der nur auf sicher als Scan klassifizierten
/// Rasterseiten laufen darf – Prinzip 5).
struct PageAnalysis: Codable, Sendable {
    let pageIndex: Int
    /// Seitenfläche in pt² (MediaBox).
    let pageArea: Double
    /// Summe der platzierten Bildflächen / Seitenfläche, gekappt bei 1.
    let imageCoverageRatio: Double
    /// Deckungsgrad der größten Einzelbild-Platzierung (≥ 0.90–0.95 →
    /// Scan-Kandidat).
    let largestImageCoverageRatio: Double
    /// Textanzeige-Operatoren (Tj, TJ, ', ") insgesamt.
    let nativeTextOperatorCount: Int
    /// Grobe Zeichen-Schätzung: Bytes aller angezeigten Strings.
    let textCharacterEstimate: Int
    /// Bild-XObject-Platzierungen auf der Seite.
    let imageCount: Int
    /// Pfad-Konstruktions- und Füll-Operatoren (m, l, c, re, S, f, …).
    let vectorOperatorEstimate: Int
    /// true = vermutlich unsichtbarer OCR-Overlay-Text (Render-Mode 3/7 bzw.
    /// weiße Textfarbe über Vollbild-Raster) – Best-effort-Heuristik.
    let likelyOCRTextLayer: Bool
    /// Effective DPI der größten Platzierung, wenn ≥ 150 (scan-plausibel).
    let scanDPI: Double?
    let classification: PageContentClass
    let confidence: Double
}

// MARK: - Klassifikationsergebnis je Bildressource

/// Ergebnis der V2-Klassifikation EINER Bildressource – kommt in den Trace
/// (§7.4: `classification.class` + `confidence`) und ist die Grundlage der
/// `ResourceDecision` in V2-3.
struct ResourceClassification: Equatable, Codable, Sendable {
    let contentClass: ContentClass
    let confidence: Double
    /// Rohmerkmale für Diagnose/Benchmark; nil, wenn die Pixel nicht
    /// dekodierbar waren.
    let features: ContentFeatures?
}

// MARK: - Migration (Masterplan §8)

extension ContentClass {

    /// Ableitung in die bestehende `ImageClass`-Welt (photo/graphics). Die
    /// bestehenden Quality-Gates und Kodierpfade kennen nur diese beiden
    /// Seiten; V2 klassifiziert feiner und MAPPT darauf:
    ///
    ///   photo, scan*, mapTechnical → photo-Seite
    ///   screenshot, lineArt, chart → graphics-Seite
    ///   mixedRaster                → photo-Seite (konservativ: JPEG-Pfad,
    ///     verlustfreies Resizen von Fotomaterial wäre größer, nicht besser)
    ///   unknown                    → nil (der Legacy-Klassifikator entscheidet
    ///     unverändert weiter – Konservativität vor Neuerung)
    ///
    /// scanBilevel ist praktisch irrelevant: Echtes 1-bit läuft vor der
    /// Klassifikation über den Bilevel-Race.
    var derivedImageClass: ImageClass? {
        switch self {
        case .photo, .scanContinuous, .scanBilevel, .mapTechnical, .mixedRaster:
            return .photo
        case .screenshot, .lineArt, .chart:
            return .graphics
        case .unknown:
            return nil
        }
    }
}
