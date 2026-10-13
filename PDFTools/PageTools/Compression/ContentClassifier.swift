import Foundation

// MARK: - Masterplan §8.3 – Deterministische Regeln

/// Wendet die deterministischen Regeln des Masterplans §8.3 auf die
/// `ContentFeatures` an. Kein ML; jede Regel ist ein nachlesbarer Zweig.
///
/// Reihenfolge (§8.3, mit §8.4-Seitenkontext):
///
///     0. exact_bilevel                        → scanBilevel
///     1. Seitenkontext (≥ 90-%-Einzelraster)
///        + texture/entropy/grayscale( lossy )  → scanContinuous
///     2. edge + flat + lowcolors              → screenshot / lineArt / chart
///                                               / mapTechnical
///     3. entropy + texture + verteilte Kanten → photo
///     4. Mischsignale                          → mixedRaster
///     sonst                                    → unknown
///
/// `unknown` ist ein echtes Ergebnis und wird konservativ behandelt –
/// NICHT als photo (Prinzip 11). mapTechnical ist bewusst eng gefasst;
/// bei unsicherer Heuristik fällt es auf lineArt zurück (§5.2).
enum ContentClassifier {

    /// Seitenkontext, soweit er bereits bekannt ist. Der Planner kennt beim
    /// Bildvergleich meist noch keine Seitenanalyse – dann bleiben die Felder
    /// nil und die Seitenregeln überspringen sich selbst. `PageScanAnalyzer`
    /// liefert den Kontext für seitenbezogene Klassifikation (§8.4; seit der
    /// V2-11-Nachbereitung verdrahtet die Pipeline ihn in den Bildpfad).
    struct ClassificationContext: Sendable {
        /// Exakt zweiwertige Pixel (BilevelDetection) – harte Pixeleigenschaft.
        var isExactBilevel: Bool = false
        /// Größtes Bild bedeckt die Seite ≥ 0.90 (Scan-Kandidat, §8.4).
        var pageLooksScanned: Bool? = nil
        /// Deckungsgrad des größten Bilds (falls bekannt).
        var largestImageCoverageRatio: Double? = nil
        /// Effective DPI der größten Platzierung, falls bekannt.
        var scanDPI: Double? = nil
        /// Terminale Quellkodierung ist verlustbehaftet (DCTDecode/
        /// JPXDecode). Ein verlustfrei kodierter Vollseiten-Raster ist
        /// typischerweise Screenshot-/Linienmaterial, kein Scan – der
        /// Graustufen-Arm der Scan-Regel fragt dieses Signal ab, um
        /// Screenshots nicht auf die Foto-Route zu drücken (§8.6).
        /// nil = unbekannt; dann greift der Arm nicht.
        var sourceIsLossy: Bool? = nil
    }

    struct Verdict: Equatable, Sendable {
        let contentClass: ContentClass
        let confidence: Double
        /// Die ausgelöste Regel – für Trace und Benchmark nachlesbar.
        let rule: String
    }

    // MARK: Schwellwerte (eine Stelle, nach Regel gruppiert)

    private enum Thresholds {
        // Regel 1 – screenshot/lineArt-Familie
        static let flatArea = 0.45
        static let lowUniqueColors = 0.10
        static let minimumEdgeDensity = 0.03
        static let maximumTexture = 0.45
        static let lineArtGrayscale = 0.90
        static let textLikeTile = 0.08
        static let bimodalEntropy = 2.5
        static let chartFlatArea = 0.60
        static let mapDiagonal = 0.35
        static let mapMapDiagonalClear = 0.45
        static let mapTextLike = 0.08
        static let mapUniqueColors = 0.30
        // Scanned-map-Tile (verrauschtes Kartenmaterial, Korpusmessung §8.5:
        // 522 USGS-Kacheln, diag 0.35–0.42 / NASA-Textscans diag ≤ 0.28)
        static let mapScanDiagonal = 0.30
        static let mapScanEntropy = 4.0
        static let mapScanFlat = 0.10
        static let mapScanTexture = 0.10
        static let mapScanTextLike = 0.50
        static let mapScanEdge = 0.30
        // Regel 1 – Scan (Seitenkontext)
        static let scanTexture = 0.30
        static let scanEntropy = 4.0
        // Regel 4 – Foto
        static let photoEntropy = 4.0
        static let photoTexture = 0.30
        // Regel 6 – Mixed
        static let mixedFlat = 0.15
        static let mixedTexture = 0.25
        static let mixedUniqueColors = 0.08
    }

    static func classify(features: ContentFeatures,
                         context: ClassificationContext) -> Verdict {
        // 0. Exakte Zweiwertigkeit ist eine harte Pixeleigenschaft, kein
        //    Merkmal – sie schlägt jede Heuristik.
        if context.isExactBilevel {
            return Verdict(contentClass: .scanBilevel, confidence: 0.95, rule: "exact_bilevel")
        }

        // 1. Seitenkontext (§8.4) schlägt die Bildheuristik: Ein ≥ 90-%-
        //    Einzelraster ist ein Scan-Kandidat, BEVOR die Flachfamilie es
        //    als screenshot/lineArt liest – sonst enden Scans auf der
        //    Graphics-Route (V2-2-Fund, §8.6: „Foto wird nicht als Line Art
        //    kodiert“). Arme: hohe Textur, hohe Entropie ODER Graustufen-
        //    charakter (§8.3 „grayscale/high texture“) bei verlustbehafteter
        //    Quelle – der Graustufen-Arm schließt verlustfrei kodierte
        //    Vollseiten-Raster (Screenshots) bewusst aus.
        if context.pageLooksScanned == true,
           features.textureRatio >= Thresholds.scanTexture
            || features.entropy >= Thresholds.scanEntropy
            || (context.sourceIsLossy == true
                && features.grayscaleScore >= Thresholds.lineArtGrayscale) {
            var confidence = 0.70
            if features.textureRatio >= 0.50 { confidence += 0.08 }
            if features.entropy >= 5.0 { confidence += 0.06 }
            if features.grayscaleScore >= Thresholds.lineArtGrayscale { confidence += 0.04 }
            if let dpi = context.scanDPI, dpi >= 200 { confidence += 0.05 }
            return Verdict(contentClass: .scanContinuous,
                           confidence: min(0.90, confidence), rule: "scan_candidate")
        }

        // 2. Edge + flat + lowcolors → screenshot/lineArt-Familie (§8.3).
        //    Zweite Bedingung (B) fängt weitgehend flache Graustufen-Inhalte
        //    ohne nennenswerte Farbstichprobe (Text-/Linien-Grafik). Der
        //    OR-Zweig der ersten Bedingung erlaubt sehr große Volltonflächen
        //    mit nur einer Trennkante (schematische Screenshots) – Fotos
        //    scheitern an `uniqueColorRatio` weiterhin sicher.
        let rule1 = features.flatAreaRatio >= Thresholds.flatArea
            && features.uniqueColorRatio <= Thresholds.lowUniqueColors
            && features.textureRatio <= Thresholds.maximumTexture
            && (features.edgeDensity >= Thresholds.minimumEdgeDensity
                || features.flatAreaRatio >= 0.60)
        // Dichte Liniengrafik (CAD, technische Karten): Linien in fast jeder
        // Kachel → die Flach-Fläche fehlt. Erkennbar an hoher Kantendichte
        // bei Farbarmut; Graustufencharakter entlastet den mittleren
        // Kantendichte-Bereich, sehr hohe Kantendichte (≥ 0.30 – Fotos
        // erreichen das auf der Stichprobe nie) entscheidet auch bei
        // Farbe (USGS-Kartenfliesen). Korpusmessung §8.5.
        let rule1c = features.edgeDensity >= 0.15
            && features.uniqueColorRatio <= Thresholds.lowUniqueColors
            && features.textureRatio <= Thresholds.maximumTexture
            && (features.grayscaleScore >= 0.85 || features.edgeDensity >= 0.30)
        let rule1b = features.grayscaleScore >= Thresholds.lineArtGrayscale
            && features.textureRatio <= Thresholds.maximumTexture
            && (features.textLikeTileRatio >= Thresholds.textLikeTile
                || (features.edgeDensity >= Thresholds.minimumEdgeDensity
                    && features.flatAreaRatio >= 0.30
                    && features.entropy <= Thresholds.bimodalEntropy))
        if rule1 || rule1b || rule1c {
            return flatContentVerdict(features, triggered: rule1 ? "flat_lowcolor"
                                      : (rule1b ? "gray_textlike" : "dense_lines"))
        }

        // 4. Entropy + texture + verteilte Kanten → photo.
        if features.entropy >= Thresholds.photoEntropy
            && features.textureRatio >= Thresholds.photoTexture {
            var confidence = 0.70
            if features.entropy >= 5.0 { confidence += 0.08 }
            if features.textureRatio >= 0.50 { confidence += 0.08 }
            if features.uniqueColorRatio >= 0.25 && features.chromaMean >= 12 { confidence += 0.07 }
            return Verdict(contentClass: .photo, confidence: min(0.93, confidence), rule: "entropy_texture")
        }
        // 5. Weiche Tonwertverbreitung ohne Flachdominanz – Figuren/Photos,
        //     die nach dem Heruntersampeln glatt werden: breite Luminanz-
        //     Streuung (entropy ≥ 4), keine harten Kanteninvasion, etwas
        //     Farbvielfalt. Deutlich schwächeres Signal als Regel 3, daher
        //     niedrigere Basis-Confidence (Korpusmessung §8.5).
        if features.entropy >= Thresholds.photoEntropy
            && features.flatAreaRatio <= 0.40
            && features.edgeDensity <= 0.25
            && features.uniqueColorRatio >= 0.03
            && features.textureRatio >= 0.05 {
            var confidence = 0.65
            if features.entropy >= 5.0 { confidence += 0.08 }
            if features.uniqueColorRatio >= 0.15 { confidence += 0.05 }
            return Verdict(contentClass: .photo, confidence: min(0.85, confidence), rule: "soft_photo")
        }

        // 6. Mischsignale – flache UND texturierte Anteile mit Farbe: UI mit
        //    Foto-Inhalt. Bewusst niedrige Confidence, konservativ.
        if features.flatAreaRatio >= Thresholds.mixedFlat
            && features.textureRatio >= Thresholds.mixedTexture
            && features.uniqueColorRatio >= Thresholds.mixedUniqueColors {
            return Verdict(contentClass: .mixedRaster, confidence: 0.55, rule: "mixed_signals")
        }

        // 7. Sonst: unknown als echtes Ergebnis.
        return Verdict(contentClass: .unknown, confidence: 0.30, rule: "no_rule")
    }

    /// Sub-Klassifikation der flachen/Kanten-lastigen Familie. mapTechnical
    /// nur bei eindeutigen Karten-/Kachel-Signalen – sonst Fallback lineArt
    /// (§5.2). Grenze der Sub-Heuristik: Ein „heller Grund“ ist nicht als
    /// eigenes Merkmal in §5.3 enthalten; die Unterscheidung läuft deshalb
    /// über Graustufen-/Chroma-Signale, nicht über die Hintergrundhelligkeit.
    private static func flatContentVerdict(_ f: ContentFeatures, triggered: String) -> Verdict {
        var confidence = 0.70
        if f.edgeDensity >= 0.12 { confidence += 0.08 }
        if f.flatAreaRatio >= 0.60 { confidence += 0.08 }
        if f.uniqueColorRatio <= 0.05 { confidence += 0.07 }

        // Gescanntes Kartenmaterial in KACHELFORM (Korpusmessung §8.5: 522
        // USGS-Kacheln): Scan-Rauschen auf Liniengewebe – extrem hohe
        // Kantendichte ohne eine einzige flache/texturierte Kachel, mittle-
        // re Diagonalsignatur, „textartige“ Kacheln durch Schwarz-Weiß-
        // Wechsel des Gewebes statt durch Glyphen. Genau diese Kacheln
        // schloss das mapTextLike-Gate aus (gemessen textLike 0.84–1.0) –
        // sie gehören auf die edge-sensitive Karten-Politik (§8.6), nicht
        // auf die verlustfreie Graphics-Route. Abgrenzung gegen Text-Scans
        // (NASA-Korpus: diag ≤ 0.28, textLike ≤ 0.46, flat ≥ 0.04): der
        // Diagonal-Floor sitzt in der Messlücke, Text-ähnlichkeit muss
        // gleichzeitig hoch sein.
        if f.edgeDensity >= Thresholds.mapScanEdge
            && f.entropy >= Thresholds.mapScanEntropy
            && f.uniqueColorRatio <= Thresholds.lowUniqueColors
            && f.flatAreaRatio <= Thresholds.mapScanFlat
            && f.textureRatio <= Thresholds.mapScanTexture
            && f.diagonalEdgeRatio >= Thresholds.mapScanDiagonal
            && f.textLikeTileRatio >= Thresholds.mapScanTextLike {
            var mapConfidence = confidence + 0.05
            if f.edgeDensity >= 0.45 { mapConfidence += 0.05 }
            if f.entropy >= 5.0 { mapConfidence += 0.05 }
            return Verdict(contentClass: .mapTechnical,
                           confidence: min(0.90, mapConfidence),
                           rule: "scanned_map_tile")
        }

        if f.diagonalEdgeRatio >= Thresholds.mapDiagonal
            && f.textLikeTileRatio <= Thresholds.mapTextLike
            && f.uniqueColorRatio <= Thresholds.mapUniqueColors {
            // Karten/CAD: diagonale Linien deutlich dominant, kaum Text-
            // Kacheln. Erst ein DEUTLICHER Diagonalanteil (≥ 0.45) traut
            // sich das seltene Etikett; dazwischen gilt der Fallback lineArt.
            if f.diagonalEdgeRatio >= Thresholds.mapMapDiagonalClear {
                return Verdict(contentClass: .mapTechnical,
                               confidence: min(0.90, confidence + 0.05),
                               rule: "flat_diagonal_map")
            }
            return Verdict(contentClass: .lineArt,
                           confidence: min(0.88, confidence),
                           rule: "flat_diagonal_uncertain_lineArt")
        }

        if f.grayscaleScore >= Thresholds.lineArtGrayscale {
            return Verdict(contentClass: .lineArt,
                           confidence: min(0.90, confidence), rule: triggered + "_gray")
        }
        // Dichte Liniengrafik ist semantisch immer Linienwerk – egal ob
        // grau oder farbig (CAD-Export, Kartenfliesen). Die Screenshot-
        // Unterscheidung bleibt der Flach-Fläche vorbehalten.
        if triggered == "dense_lines" {
            return Verdict(contentClass: .lineArt,
                           confidence: min(0.88, confidence), rule: triggered)
        }
        // Diagramm/Chart: große weiße Zeichenfläche PLUS Beschriftungs-Kacheln.
        // Grenze (dokumentiert): Text-lastige Screenshots teilen diese Signale
        // und können als chart lesen – beide landen auf der graphics-Seite
        // der bestehenden Gates, die Entscheidung ist also unkritisch.
        if f.flatAreaRatio >= Thresholds.chartFlatArea
            && f.textLikeTileRatio >= Thresholds.textLikeTile {
            return Verdict(contentClass: .chart,
                           confidence: min(0.88, confidence), rule: "flat_chart")
        }
        return Verdict(contentClass: .screenshot,
                       confidence: min(0.93, confidence), rule: triggered)
    }
}
