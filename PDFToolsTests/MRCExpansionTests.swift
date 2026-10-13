import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// MRC-Ausbau (§13.1-Scope + parallele Provision): Seiten mit dominantem
/// Vollbild-Raster PLUS kleinen Sekundärrastern erhalten MRC-Kandidaten für
/// den dominanten Draw; zu große Sekundär-Raster schließen die Seite aus.
/// Die parallele Provision bleibt deterministisch (zwei Läufe, gleiche Wahl).
@Suite(.timeLimit(.minutes(10))) struct MRCExpansionTests {

    private static func hasMRCAction(_ plan: CompressionPlan) -> Bool {
        plan.actions.contains {
            if case .mrc = $0 { return true }
            return false
        }
    }

    @Test func dominanteSeiteMitKleinemSekundaerRasterBekommtMRC() throws {
        let input = try PDFFixtures.mrcScanPageWithSecondaryPDF(secondaryPoints: 60)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = MRCPageRewriteTests.tempURL("secondary-small")
        defer { try? FileManager.default.removeItem(at: output) }

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: output,
            options: MRCPageRewriteTests.mrcOptions())
        #expect(Self.hasMRCAction(outcome.plan),
                "Dominantes Raster mit kleinem Sekundärbild muss MRC erhalten")
        #expect(outcome.execution.mrcPages == 1)

        // Der Sekundär-Draw bleibt unangetastet im Content.
        let core = try PDFCoreDocument(path: output.path)
        let content = String(decoding: try core.pageContentBytes(pageIndex: 0),
                             as: UTF8.self)
        #expect(content.contains("/Im1 Do"),
                "Sekundär-Draw darf die Rekonstruktion nicht verlieren")
        try PDFCoreDocument(path: output.path).check()
        // Stabilität über das ECHTE Seiten-QA-Gate (§13.10): CAR ist bewusst
        // kein Maß (schwarze Masken-Tinte zählt jeden Textpixel als geändert,
        // ohne ihn strukturell zu beschädigen) – SSIM/p05/inkDelta tragen.
        let quality = try #require(MRCPageQA.measure(
            sourceURL: input, outputURL: output, pageIndex: 0))
        #expect(quality.meetsScanLimits, Comment(rawValue:
                "MRC-Ausgabe muss das Seiten-QA-Gate halten: "
                + "SSIM \(quality.globalSSIM), p05 \(quality.p05TileSSIM), "
                + "inkDelta \(quality.inkDelta)"))
    }

    @Test func zuGrossesSekundaerRasterSchliesstMRCaus() throws {
        // 220 pt ≈ 10 % Deckung > maximumSecondaryCoverage (5 %).
        let input = try PDFFixtures.mrcScanPageWithSecondaryPDF(secondaryPoints: 220)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = MRCPageRewriteTests.tempURL("secondary-large")
        defer { try? FileManager.default.removeItem(at: output) }

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: output,
            options: MRCPageRewriteTests.mrcOptions())
        #expect(!Self.hasMRCAction(outcome.plan),
                "Zu großes Sekundär-Raster fällt aus dem MRC-Scope")
        #expect(outcome.execution.mrcPages == 0)
    }

    @Test func paralleleProvisionBleibtDeterministisch() throws {
        let input = try PDFFixtures.mrcScanPagePDF(withOCR: true)
        defer { try? FileManager.default.removeItem(at: input) }
        let options = MRCPageRewriteTests.mrcOptions()

        func selectedIDs() throws -> [String] {
            let out = MRCPageRewriteTests.tempURL("determ")
            defer { try? FileManager.default.removeItem(at: out) }
            let outcome = try CompressionPipeline.run(
                inputURL: input, outputURL: out, options: options)
            return outcome.plan.decisions.map {
                "\($0.resourceID)=\($0.selectedCandidateID.rawValue)"
            }.sorted()
        }
        #expect(try selectedIDs() == selectedIDs(),
                "Parallele Provision muss dieselbe Wahl treffen")
    }
}
