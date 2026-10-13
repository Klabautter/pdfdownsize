import Testing
import Foundation
@testable import PDFTools

/// Phase V2-2 (§8.3) – Regelwerk des ContentClassifiers: Reihenfolge,
/// unknown als echtes Ergebnis, mapTechnical-Fallback und die Migration-
/// Ableitung in die bestehende photo/graphics-Welt.
@Suite struct ContentClassifierTests {

    /// Feature-Bauer mit sinnvollen neutralen Werten – die Tests überschreiben
    /// gezielt die regelrelevanten Felder. Kanten-Ratios verteilen bewusst
    /// UNTER der mapTechnical-Schwelle (diagonal 0.3 < 0.35), damit die
    /// Untertrennung der Familie nicht versehentlich zündet.
    private func features(
        uniqueColorRatio: Double = 0.5,
        chromaMean: Double = 40,
        grayscaleScore: Double = 0.1,
        entropy: Double = 5.0,
        edgeDensity: Double = 0.05,
        hRatio: Double = 0.35,
        vRatio: Double = 0.35,
        diagRatio: Double = 0.3,
        flatAreaRatio: Double = 0.2,
        textureRatio: Double = 0.6,
        textLikeTileRatio: Double = 0.0
    ) -> ContentFeatures {
        ContentFeatures(
            sampleWidth: 128, sampleHeight: 128,
            uniqueColorRatio: uniqueColorRatio,
            exactColorCountHint: nil,
            chromaMean: chromaMean,
            grayscaleScore: grayscaleScore,
            entropy: entropy,
            localVarianceMean: 500, localVarianceP90: 2000,
            edgeDensity: edgeDensity,
            horizontalEdgeRatio: hRatio,
            verticalEdgeRatio: vRatio,
            diagonalEdgeRatio: diagRatio,
            connectedComponentDensity: nil, smallComponentRatio: nil,
            flatAreaRatio: flatAreaRatio,
            textureRatio: textureRatio,
            textLikeTileRatio: textLikeTileRatio,
            confidence: 0)
    }

    private let context = ContentClassifier.ClassificationContext()

    @Test func reihenfolgeBilevelSchlaegtAlles() {
        // Selbst ein vollständiges Foto-Profil wird von der harten
        // Zweiwertigkeit überstimmt.
        let verdict = ContentClassifier.classify(
            features: features(), context: .init(isExactBilevel: true))
        #expect(verdict.contentClass == .scanBilevel)
        #expect(verdict.rule == "exact_bilevel")
    }

    @Test func flatLowColorFamilie() {
        var f = features(uniqueColorRatio: 0.004, edgeDensity: 0.08,
                         flatAreaRatio: 0.9, textureRatio: 0.05)
        #expect(ContentClassifier.classify(features: f, context: context).contentClass
                == .screenshot)
        // Graustufen-Variante → lineArt.
        f = features(uniqueColorRatio: 0.004, chromaMean: 0.2, grayscaleScore: 1.0,
                     edgeDensity: 0.08, flatAreaRatio: 0.9, textureRatio: 0.05)
        #expect(ContentClassifier.classify(features: f, context: context).contentClass
                == .lineArt)
        // Diagramm: große Zeichenfläche plus Beschriftungs-Kacheln.
        f = features(uniqueColorRatio: 0.05, edgeDensity: 0.08, flatAreaRatio: 0.8,
                     textureRatio: 0.05, textLikeTileRatio: 0.2)
        #expect(ContentClassifier.classify(features: f, context: context).contentClass
                == .chart)
    }

    @Test func mapTechnicalNurBeiKlarenDiagonalen() {
        let clear = features(uniqueColorRatio: 0.03, edgeDensity: 0.2,
                             hRatio: 0.25, vRatio: 0.25, diagRatio: 0.5,
                             flatAreaRatio: 0.6, textureRatio: 0.05)
        #expect(ContentClassifier.classify(features: clear, context: context).contentClass
                == .mapTechnical)
        // Knapp über der Schwelle: Fallback lineArt (§5.2 – unsicher = Fallback).
        let borderline = features(uniqueColorRatio: 0.03, edgeDensity: 0.2,
                                  hRatio: 0.3, vRatio: 0.3, diagRatio: 0.38,
                                  flatAreaRatio: 0.6, textureRatio: 0.05)
        #expect(ContentClassifier.classify(features: borderline, context: context).contentClass
                == .lineArt)
    }

    // MARK: §8.6-Reparatur – gescanntes Kartenmaterial (Korpusmessung §8.5)

    /// Gemessene Signatur der 522 USGS-Kartenkacheln (1989er Karte):
    /// Scan-Rauschen auf Liniengewebe – edge 0.48–0.82, entropy 4.3–5.6,
    /// keine flache/texturierte Kachel, diag 0.35–0.42, „textartig“ durch
    /// Schwarz-Weiß-Wechsel des Gewebes (0.84–1.0).
    @Test func gescannteKartenKachelnLaufenAufMapTechnical() {
        let tile = features(uniqueColorRatio: 0.087, chromaMean: 15.0,
                            grayscaleScore: 0.0, entropy: 5.23,
                            edgeDensity: 0.64, hRatio: 0.31, vRatio: 0.31,
                            diagRatio: 0.38, flatAreaRatio: 0.0,
                            textureRatio: 0.0, textLikeTileRatio: 1.0)
        let verdict = ContentClassifier.classify(features: tile, context: context)
        #expect(verdict.contentClass == .mapTechnical)
        #expect(verdict.rule == "scanned_map_tile")
        // §8.6 – „technische Karten erhalten edge-sensitive Policy“:
        // mapTechnical läuft auf der Foto-Route mit map-Gewichten
        // (edge 0.50 + localWorst 0.50, RateDistortionOptimizer §10.2).
        #expect(verdict.contentClass.derivedImageClass == .photo)
    }

    /// Diagnose-Gegenprobe (NASA-Korpus): Graustufen-Textscans teilen
    /// „hohe Entropie + viele Text-Kacheln“, scheitern aber an der
    /// Diagonal-/Flach-Signatur – sie dürfen NICHT als Karten enden.
    @Test func textScansWerdenNichtZuKarten() {
        let textScan = features(uniqueColorRatio: 0.006, chromaMean: 0.0,
                                grayscaleScore: 1.0, entropy: 4.48,
                                edgeDensity: 0.35, hRatio: 0.40, vRatio: 0.40,
                                diagRatio: 0.20, flatAreaRatio: 0.04,
                                textureRatio: 0.03, textLikeTileRatio: 0.43)
        var scanContext = ContentClassifier.ClassificationContext()
        scanContext.pageLooksScanned = true
        scanContext.sourceIsLossy = true
        let verdict = ContentClassifier.classify(features: textScan,
                                                 context: scanContext)
        #expect(verdict.contentClass == .scanContinuous,
                "Vollseiten-Textscan bleibt Scan – nicht Karte, nicht lineArt")
    }

    /// §8.3/§8.4 – Scan-Regel mit Priorität: Ein ≥ 90-%-Einzelraster wird
    /// VOR der Flachfamilie gelesen, sonst enden Scans auf der Graphics-
    /// Route (V2-2-Fund). Der Graustufen-Arm braucht eine verlustbehaftete
    /// Quelle – verlustfreie Vollseiten-Raster sind Screenshot-/Linienwerk
    /// (§8.6: „Screenshot wird nicht automatisch als Photo JPEG behandelt“).
    @Test func graustufenScanBrauchtVerlustbehafteteQuelle() {
        // Gemessener Fall (07_Scans_Grayscale): heller Graustufen-Scan,
        // entropy 1.8, texture 0.24 – kein Textur-/Entropie-Arm greift.
        let grayScan = features(uniqueColorRatio: 0.0014, chromaMean: 0.0,
                                grayscaleScore: 1.0, entropy: 1.785,
                                edgeDensity: 0.129, hRatio: 0.47, vRatio: 0.47,
                                diagRatio: 0.06, flatAreaRatio: 0.43,
                                textureRatio: 0.24, textLikeTileRatio: 0.0)
        var lossyScanContext = ContentClassifier.ClassificationContext()
        lossyScanContext.pageLooksScanned = true
        lossyScanContext.sourceIsLossy = true
        #expect(ContentClassifier.classify(features: grayScan,
                                           context: lossyScanContext).contentClass
                == .scanContinuous)

        // Dieselben Pixel als verlustfreie Quelle (Flate): kein Scan.
        var losslessContext = lossyScanContext
        losslessContext.sourceIsLossy = false
        #expect(ContentClassifier.classify(features: grayScan,
                                           context: losslessContext).contentClass
                == .lineArt)

        // Unbekannte Quelle: konservativ – kein Scan-Arm.
        var unknownSourceContext = lossyScanContext
        unknownSourceContext.sourceIsLossy = nil
        #expect(ContentClassifier.classify(features: grayScan,
                                           context: unknownSourceContext).contentClass
                == .lineArt)
    }

    /// Gemessener Fall (03_Screenshots_UI): farbiger Vollseiten-Screenshot
    /// als Flate-Raster bleibt in der Flachfamilie – der Graustufen-Arm der
    /// Scan-Regel greift nicht (gray 0.54 < 0.90) und die Route bleibt
    /// verlustfrei (§8.6).
    @Test func vollseitenScreenshotBleibtScreenshot() {
        let screenshot = features(uniqueColorRatio: 0.0059, chromaMean: 8.0,
                                  grayscaleScore: 0.54, entropy: 1.84,
                                  edgeDensity: 0.065, hRatio: 0.38, vRatio: 0.38,
                                  diagRatio: 0.16, flatAreaRatio: 0.63,
                                  textureRatio: 0.11, textLikeTileRatio: 0.0)
        var context = ContentClassifier.ClassificationContext()
        context.pageLooksScanned = true
        context.sourceIsLossy = false
        context.scanDPI = 96
        #expect(ContentClassifier.classify(features: screenshot,
                                           context: context).contentClass
                == .screenshot)
    }

    @Test func scanRegelBrauchtSeitenkontext() {
        // Ohne pageLooksScanned fällt Foto-artiges Material in die Foto-Regel –
        // die Scan-Regel überspringt sich selbst.
        let f = features()
        #expect(ContentClassifier.classify(features: f, context: context).contentClass
                == .photo)
        // Mit Kontext: dieselben Features werden scanContinuous.
        var scanContext = ContentClassifier.ClassificationContext()
        scanContext.pageLooksScanned = true
        scanContext.scanDPI = 300
        #expect(ContentClassifier.classify(features: f, context: scanContext).contentClass
                == .scanContinuous)
    }

    @Test func unknownIstEchtesErgebnis() {
        // Zwischen allen Regeln: mäßige Fläche, mäßige Textur, keine Kanten.
        let f = features(uniqueColorRatio: 0.5, entropy: 3.0, edgeDensity: 0.005,
                         flatAreaRatio: 0.05, textureRatio: 0.1)
        let verdict = ContentClassifier.classify(features: f, context: context)
        #expect(verdict.contentClass == .unknown)
        #expect(verdict.rule == "no_rule")
        #expect(verdict.contentClass.derivedImageClass == nil,
                "unknown darf NICHT als photo durchgehen")
    }

    @Test func migrationAbleitungInImageClass() {
        // photo/scan*/map → photo-Seite; screenshot/lineArt/chart → graphics.
        let photoSide: [ContentClass] = [.photo, .scanContinuous, .scanBilevel,
                                         .mapTechnical, .mixedRaster]
        for c in photoSide {
            #expect(c.derivedImageClass == .photo, "\(c) muss auf die photo-Seite mappen")
        }
        let graphicsSide: [ContentClass] = [.screenshot, .lineArt, .chart]
        for c in graphicsSide {
            #expect(c.derivedImageClass == .graphics, "\(c) muss auf die graphics-Seite mappen")
        }
        #expect(ContentClass.unknown.derivedImageClass == nil)
    }

    @Test func mixedRasterFingerBeiMischsignalen() {
        // Flache UND texturierte Anteile mit Farbe – UI mit Foto-Inhalt.
        // Entropie UNTER der Foto-Schwelle, damit die Foto-Regel nicht
        // zuerst zuschlägt. Niedrige Confidence, konservativ.
        let f = features(uniqueColorRatio: 0.3, entropy: 3.0,
                         flatAreaRatio: 0.35, textureRatio: 0.45)
        let verdict = ContentClassifier.classify(features: f, context: context)
        #expect(verdict.contentClass == .mixedRaster)
        #expect(verdict.confidence <= 0.6)
    }
}
