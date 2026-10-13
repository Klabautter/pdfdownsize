import Testing
import Foundation
@testable import PDFTools

/// Phase V2-2 (§8.4) – PageScanAnalyzer: Seitenklassen aus Platzierungen und
/// Content-Operatoren, inklusive OCR-Overlay-Heuristik (Render-Mode 3).
@Suite struct PageScanClassifierTests {

    private func analyze(_ url: URL) throws -> PageAnalysis {
        let document = try PDFCoreDocument(path: url.path)
        return try PageScanAnalyzer.analyze(document: document).first
            ?? PageAnalysis(pageIndex: 0, pageArea: 0, imageCoverageRatio: 0,
                            largestImageCoverageRatio: 0, nativeTextOperatorCount: 0,
                            textCharacterEstimate: 0, imageCount: 0,
                            vectorOperatorEstimate: 0, likelyOCRTextLayer: false,
                            scanDPI: nil, classification: .unknown, confidence: 0)
    }

    @Test(.hangGuard) func vollbildRasterIstRasterScan() throws {
        let url = try PDFFixtures.scanPagePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = try analyze(url)
        #expect(analysis.classification == .rasterScan)
        #expect(analysis.largestImageCoverageRatio >= 0.99)
        #expect(analysis.imageCount == 1)
        #expect(analysis.nativeTextOperatorCount == 0)
        #expect(analysis.confidence >= 0.75)
        #expect(analysis.likelyOCRTextLayer == false)
    }

    @Test(.hangGuard) func ocrOverlayWirdErkannt() throws {
        let url = try PDFFixtures.ocrOverlayScanPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = try analyze(url)
        #expect(analysis.classification == .rasterScanWithOCR,
                "unsichtbarer Text über Vollbild-Raster ist OCR-Overlay")
        #expect(analysis.likelyOCRTextLayer)
        #expect(analysis.nativeTextOperatorCount > 0,
                "OCR-Text ist trotzdem native Text-Operatoren (§8.4)")
        #expect(analysis.largestImageCoverageRatio >= 0.99)
    }

    @Test(.hangGuard) func sichtbarerTextUeberRasterIstMixed() throws {
        // Sichtbarer Text über vollflächigem Raster: ohne Rendering nicht
        // sicher OCR- oder Stempel-Text → konservativ mixed.
        let url = try PDFFixtures.mixedPagePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = try analyze(url)
        #expect(analysis.classification == .mixed)
        #expect(analysis.imageCoverageRatio >= 0.30)
        #expect(analysis.nativeTextOperatorCount > 0)
        #expect(analysis.largestImageCoverageRatio < 0.90)
    }

    @Test(.hangGuard) func vektorTextIstBornDigital() throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = try analyze(url)
        #expect(analysis.classification == .bornDigital)
        #expect(analysis.nativeTextOperatorCount > 0)
        #expect(analysis.textCharacterEstimate > 32)
        #expect(analysis.imageCount == 0)
    }

    @Test(.hangGuard) func leereSeiteBleibtUnknown() throws {
        // Seiten ohne Bild, ohne Text, ohne Vektoren: konservativ unknown.
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let page = b.addPage(parent: pages)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = try b.write(rootObject: root, prefix: "empty-page")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try PDFCoreDocument(path: url.path)
        let analysis = try PageScanAnalyzer.analyze(document: document).first
        #expect(analysis?.classification == .unknown)
        #expect(analysis?.confidence == 0.30)
    }

    @Test(.hangGuard) func seitenklassenSindDeterministisch() throws {
        let url = try PDFFixtures.ocrOverlayScanPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try PDFCoreDocument(path: url.path)
        let first = try PageScanAnalyzer.analyze(document: document)
        let second = try PageScanAnalyzer.analyze(document: document)
        #expect(first.count == second.count)
        #expect(first.map(\.classification) == second.map(\.classification))
        #expect(first.map(\.imageCoverageRatio) == second.map(\.imageCoverageRatio))
        #expect(first.map(\.textCharacterEstimate) == second.map(\.textCharacterEstimate))
        #expect(first.map(\.vectorOperatorEstimate) == second.map(\.vectorOperatorEstimate))
    }

    // MARK: §8.4-Verknüpfung – Seitenkontext in die Bild-Klassifikation

    /// Aus einer PageAnalysis gebauter Klassifikationskontext – delegiert an
    /// die zentrale Stelle (`PageScanAnalyzer.classificationContext`); die
    /// Quelle ist die erste Bildressource DES Dokuments (Filter-Signal).
    /// `sourceOverride` ersetzt das Filter-Signal (für Szenarien, deren
    /// Fixture bewusst anders kodiert ist).
    private func classificationContext(_ url: URL,
                                       sourceOverride: Bool? = nil)
        -> ContentClassifier.ClassificationContext {
        let document = try! PDFCoreDocument(path: url.path)
        let resource = (try? document.imageResources())?.first
        let analysis = (try? PageScanAnalyzer.analyze(document: document))?.first
        var context = PageScanAnalyzer.classificationContext(
            for: analysis, resource: resource)
        if let sourceOverride { context.sourceIsLossy = sourceOverride }
        return context
    }

    /// Miniaturseite (32×24 pt) mit 100-%-Deckung: pageLooksScanned muss
    /// false bleiben – Deckung ist auf Miniaturseiten kein Scan-Signal
    /// (Suitenfund: JPX-Balkenmuster auf 32×24-pt-Seite fälschlich Scan).
    @Test(.hangGuard) func miniaturseiteLiefertKeinenScanKontext() throws {
        var b = RawPDFBuilder()
        let pagesObj = b.reserveNumber()
        let pixels = 128
        // Die Analysedekodiert nie – der DCT-Filter als Quelle genügt.
        let opaqueBytes = Data((0..<(pixels * pixels)).map { UInt8($0 & 0xFF) })
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/DCTDecode", data: opaqueBytes)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(dictionary: "",
                                  content: "q 32 0 0 24 0 0 cm /Im0 Do Q ")
        let page = b.addObject("<</Type/Page/Parent \(pagesObj) 0 R"
            + "/MediaBox[0 0 32 24]/Resources \(resources) 0 R"
            + "/Contents \(content) 0 R>>")
        b.fill(pagesObj, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pagesObj) 0 R>>")
        let url = try b.write(rootObject: root, prefix: "miniature-page")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try PDFCoreDocument(path: url.path)
        let analysis = try #require(
            try PageScanAnalyzer.analyze(document: document).first)
        #expect(analysis.largestImageCoverageRatio >= 0.90)
        let resource = try #require(try document.imageResources().first)
        let context = PageScanAnalyzer.classificationContext(for: analysis,
                                                             resource: resource)
        #expect(context.pageLooksScanned == false,
                "Miniaturseite ist kein Scan-Kandidat trotz 100 % Deckung")
        #expect(context.sourceIsLossy == true)
    }

    /// Gemessene USGS-Kartenkachel (Signatur siehe ContentClassifierTests).
    private func mapTileFeatures() -> ContentFeatures {
        ContentFeatures(
            sampleWidth: 128, sampleHeight: 128,
            uniqueColorRatio: 0.087, exactColorCountHint: nil, chromaMean: 15.0,
            grayscaleScore: 0.0, entropy: 5.23,
            localVarianceMean: 500, localVarianceP90: 2000,
            edgeDensity: 0.64, horizontalEdgeRatio: 0.31, verticalEdgeRatio: 0.31,
            diagonalEdgeRatio: 0.38, connectedComponentDensity: nil,
            smallComponentRatio: nil, flatAreaRatio: 0.0, textureRatio: 0.0,
            textLikeTileRatio: 1.0, confidence: 0)
    }

    @Test(.hangGuard) func kartenKachelnSeiteLiefertKeinenScanKontext() throws {
        // Gemischt belegte Seite (mehrere Platzierungen, kein ≥ 90-%-
        // Einzelraster): pageLooksScanned bleibt false – Kartenkacheln
        // dürfen nicht in die Scan-Regel laufen.
        let url = try PDFFixtures.mixedPagePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = try analyze(url)
        #expect(analysis.largestImageCoverageRatio < 0.90)
        let context = classificationContext(url)
        #expect(context.pageLooksScanned == false)
        let verdict = ContentClassifier.classify(features: mapTileFeatures(),
                                                 context: context)
        #expect(verdict.contentClass == .mapTechnical)
    }

    @Test(.hangGuard) func vollbildRasterKontextKlassifiziertScan() throws {
        // Vollbild-Rasterseite + verlustbehaftete Quelle: die Scan-Regel
        // schlägt die Flachfamilie (§8.6 – „Foto wird nicht als Line Art
        // kodiert“), obwohl die Pixel screenshot-artig flach/grau sind.
        let url = try PDFFixtures.scanPagePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = try analyze(url)
        #expect(analysis.classification == .rasterScan)
        #expect(analysis.largestImageCoverageRatio >= 0.90)
        let grayFlatRaster = ContentFeatures(
            sampleWidth: 128, sampleHeight: 128,
            uniqueColorRatio: 0.0014, exactColorCountHint: nil, chromaMean: 0.0,
            grayscaleScore: 1.0, entropy: 1.785,
            localVarianceMean: 300, localVarianceP90: 1200,
            edgeDensity: 0.129, horizontalEdgeRatio: 0.47, verticalEdgeRatio: 0.47,
            diagonalEdgeRatio: 0.06, connectedComponentDensity: nil,
            smallComponentRatio: nil, flatAreaRatio: 0.43, textureRatio: 0.24,
            textLikeTileRatio: 0.0, confidence: 0)
        let verdict = ContentClassifier.classify(
            features: grayFlatRaster,
            context: classificationContext(url, sourceOverride: true))
        #expect(verdict.contentClass == .scanContinuous)
        #expect(verdict.contentClass.derivedImageClass == .photo)
    }
}
