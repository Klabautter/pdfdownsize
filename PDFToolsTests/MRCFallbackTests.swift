import Testing
import Foundation
@testable import PDFTools

/// Phase V2-7 – Fallbacks: Was die Segmentierung verweigert oder was die
/// Seiten-QA nicht hält, bleibt beim Original-Raster. Born-digital-Seiten
/// werden NIE MRC-fähig gesehen (§13.1/§13.4).
@Suite(.timeLimit(.minutes(10))) struct MRCFallbackTests {

    private static func hasMRCAction(_ plan: CompressionPlan) -> Bool {
        plan.actions.contains { action in
            if case .mrc = action { return true }
            return false
        }
    }

    @Test func bornDigitaleSeiteBekommtKeinMRC() throws {
        let input = try PDFFixtures.vectorTextPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let output = MRCPageRewriteTests.tempURL("born-digital")
        defer { try? FileManager.default.removeItem(at: output) }

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: output,
            options: MRCPageRewriteTests.mrcOptions())
        #expect(!Self.hasMRCAction(outcome.plan),
                "Born-digital-Seite ist außerhalb des MRC-Scope (§13.1)")
        #expect(outcome.execution.mrcPages == 0)
    }

    @Test func unsegmentierbarerScanFaelltAufOriginalRasterZurueck() throws {
        // Das V2-2-Scan-Fixture (Foto-artiges Rauschraster, rasterScan) hat
        // keinen Text auf hellem Papier – die Segmentierung verweigert.
        let input = try PDFFixtures.scanPagePDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let output = MRCPageRewriteTests.tempURL("unsegmentable")
        defer { try? FileManager.default.removeItem(at: output) }

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: output,
            options: MRCPageRewriteTests.mrcOptions())
        #expect(!Self.hasMRCAction(outcome.plan),
                "Nicht segmentierbarer Scan darf kein MRC-Bündel erhalten")
        #expect(outcome.execution.mrcPages == 0)
    }

    @Test func qualitaetsfailFaelltAufOriginalRasterZurueck() throws {
        // Mittelgraue Tinte (140): die Segmentierung erkennt den Text
        // (Sauvola), aber die schwarze Masken-Tinte macht aus Nicht-Tinten-
        // Pixeln Tinte → das inkDelta-Gate (§13.10) weist ALLE Stufen
        // zurück → das Original-Raster bleibt.
        let input = try PDFFixtures.mrcScanPagePDF(textLuma: 140,
                                                   withPhoto: false)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = MRCPageRewriteTests.tempURL("quality-fail")
        defer { try? FileManager.default.removeItem(at: output) }

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: output,
            options: MRCPageRewriteTests.mrcOptions())
        #expect(!Self.hasMRCAction(outcome.plan),
                "QA-Fail darf keinen MRC-Kandidaten liefern")
        #expect(outcome.execution.mrcPages == 0)
        // Der ursprüngliche Raster-Draw ist noch da.
        let core = try PDFCoreDocument(path: output.path)
        let content = String(decoding: try core.pageContentBytes(pageIndex: 0),
                             as: UTF8.self)
        #expect(content.contains("/Im0 Do"),
                "Original-Raster-Draw muss beim Fallback bleiben")
    }

    @Test func mrcOhneFeatureFlagIstTot() throws {
        // §25 – ohne den mrc-Schalter entsteht kein MRC-Kandidat, auch
        // nicht im Candidate-Engine-Pfad (Produktion byteidentisch).
        let input = try PDFFixtures.mrcScanPagePDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let output = MRCPageRewriteTests.tempURL("flag-off")
        defer { try? FileManager.default.removeItem(at: output) }

        var options = CompressionOptions.smart
        options.featureFlags.candidateEngine = true
        options.featureFlags.mrc = false
        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: output, options: options)
        #expect(!Self.hasMRCAction(outcome.plan))
        #expect(outcome.execution.mrcPages == 0)
    }

    @Test func standardmodiAktivierenMRCNurMitEndlichemBudget() {
        let options = CompressionOptions.make(
            mode: .smart, customConfig: nil,
            stripMetadata: false, linearize: false)
        #expect(options.featureFlags.mrc)
        #expect(options.mrcProvisionBudget.maximumPages == 8)
        #expect(options.mrcProvisionBudget.maximumElapsedSeconds == 60)

        let custom = CompressionOptions.make(
            mode: .custom, customConfig: nil,
            stripMetadata: false, linearize: false)
        #expect(!custom.featureFlags.mrc,
                "Custom-Parameter duerfen MRC nicht implizit aktivieren")
    }

    @Test func provisionBudgetBegrenztSeitenPixelUndZeit() {
        let budget = MRCProvisionBudget(
            maximumPages: 2, maximumPixels: 1_000,
            maximumElapsedSeconds: 5)
        #expect(budget.permitsNextPage(
            attemptedPages: 0, attemptedPixels: 0,
            elapsedSeconds: 0, nextPagePixels: 600))
        #expect(!budget.permitsNextPage(
            attemptedPages: 1, attemptedPixels: 600,
            elapsedSeconds: 1, nextPagePixels: 500))
        #expect(!budget.permitsNextPage(
            attemptedPages: 2, attemptedPixels: 600,
            elapsedSeconds: 1, nextPagePixels: 100))
        #expect(!budget.permitsNextPage(
            attemptedPages: 1, attemptedPixels: 600,
            elapsedSeconds: 5, nextPagePixels: 100))
    }
}
