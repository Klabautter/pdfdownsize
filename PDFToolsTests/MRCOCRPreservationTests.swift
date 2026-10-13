import Testing
import Foundation
@testable import PDFTools

/// Phase V2-7 (Masterplan §13.2) – bestehende OCR-Textlayer überleben die
/// MRC-Rekonstruktion unverändert: MRC ersetzt NUR den Raster-Unterbau,
/// der Text-Layer lebt in den Text-Operatoren der Seite und wird nie neu
/// erzeugt oder ersetzt (keine OCR-Kopplung, §13.3).
@Suite(.timeLimit(.minutes(10))) struct MRCOCRPreservationTests {

    @Test func ocrTextlayerBleibtSemantischUnveraendert() throws {
        let input = try PDFFixtures.mrcScanPagePDF(withOCR: true)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = MRCPageRewriteTests.tempURL("ocr-keep")
        defer { try? FileManager.default.removeItem(at: output) }

        let before = try PDFSemanticSnapshot.capture(input)
        #expect(before.pages[0].textCharacterCount >= 16,
                "Fixture muss OCR-Text tragen")

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: output,
            options: MRCPageRewriteTests.mrcOptions())
        guard outcome.execution.mrcPages == 1 else {
            Issue.record("Fixture erzeugte keinen MRC-Lauf; OCR-Erhalt nicht pruefbar")
            return
        }

        let after = try PDFSemanticSnapshot.capture(output)
        #expect(after.pageCount == before.pageCount)
        let beforePage = try #require(before.pages.first)
        let afterPage = try #require(after.pages.first)
        #expect(afterPage.textFingerprint == beforePage.textFingerprint,
                "OCR-Textlayer verändert (§13.2-Verstoß)")
        #expect(afterPage.textCharacterCount == beforePage.textCharacterCount,
                "OCR-Zeichenzahl verändert (§13.2-Verstoß)")
    }
}
