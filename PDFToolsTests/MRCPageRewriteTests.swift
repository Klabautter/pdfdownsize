import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Phase V2-7 (Masterplan §13.7) – Seitenrekonstruktion und Erhalt der
/// nicht-raster Semantik.
///
/// Die Seite nach dem MRC-Rewrite muss außerhalb des Raster-Draws
/// identisch sein: OCR-Text-Operatoren, Annotationen, MediaBox – und der
/// zweite Lauf darf die MRC-Ausgabe nicht erneut MRC-fähig sehen.
@Suite(.timeLimit(.minutes(10))) struct MRCPageRewriteTests {

    static func mrcOptions() -> CompressionOptions {
        var options = CompressionOptions.make(mode: .smart, customConfig: nil,
                                              stripMetadata: false, linearize: false)
        // Diese Tests pruefen die MRC-Mechanik (Rekonstruktion, Seiten-QA),
        // nicht die Bedarfsregel: Die synthetische Scan-Seite ist nach der
        // JPEG-Leiter klein, MRC muss hier trotzdem laufen.
        options.mrcProvisionBudget.provisionIfCandidateExceedsBytes = 0
        return options
    }

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mrc-\(label)-\(UUID().uuidString).pdf")
    }

    @Test func rekonstruktionErhaeltOCRTextAnnotationUndBoxen() throws {
        let input = try PDFFixtures.mrcScanPagePDF(withOCR: true, withLink: true)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = Self.tempURL("rewrite")
        defer { try? FileManager.default.removeItem(at: output) }

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: output, options: Self.mrcOptions())

        // Der MRC-Kandidat muss im Plan sichtbar sein und ausgeführt werden.
        let mrcAction = outcome.plan.actions.first { action in
            if case .mrc = action { return true }
            return false
        }
        guard case .mrc(_, let descriptor, let original, let expected) =
                try #require(mrcAction, "Erwartete MRC-Aktion im Plan") else {
            return
        }
        #expect(original > expected, "MRC-Bundle muss kleiner als das Raster sein")
        #expect(outcome.execution.mrcPages == 1)
        #expect(outcome.execution.bytesSavedMRC > 0)
        #expect(descriptor.pageIndex == 0)
        #expect(descriptor.resourceName == "Im0")

        // Datei gewinnt insgesamt (Raster → Bundle).
        let inBytes = Int(Compressor.fileSize(of: input))
        let outBytes = Int(Compressor.fileSize(of: output))
        #expect(outBytes < inBytes,
                "MRC-Ausgabe (\(outBytes)) größer als Eingabe (\(inBytes))")

        // 1. OCR-Textoperatoren bleiben: Der Text der unsichtbaren Ebene
        //    steht unverändert im Seiten-Content (§13.2).
        let core = try PDFCoreDocument(path: output.path)
        let content = try core.pageContentBytes(pageIndex: 0)
        let contentText = String(decoding: content, as: UTF8.self)
        #expect(contentText.contains("Selektierbarer OCR-Text der MRC-Erkennung"),
                "OCR-Textoperator fehlt im rekonstruierten Content")
        #expect(contentText.contains("3 Tr"), "Unsichtbarer Render-Modus bleibt")
        // Der alte Raster-Draw ist weg.
        #expect(!contentText.contains("/Im0 Do"),
                "Original-Raster-Draw muss ersetzt sein")

        // 2. Annotationen bleiben (Anzahl + URL).
        let counts = try core.annotationCounts(page: 0)
        #expect(counts.total == 1, "Link-Annotation verloren")
        #expect(try core.linkURLs().contains("https://example.com/mrc"))

        // 3. Boxen unverändert.
        let info = try core.pageInfo(at: 0)
        #expect(info.mediaBox == [0, 0, 612, 792])
        #expect(info.rotation == 0)

        // 4. Kein MRC-Zweitlauf: Die Ausgabe ist für die Engine keine
        //    Scan-Seite mit dominierendem Vollbild mehr.
        let second = Self.tempURL("second")
        defer { try? FileManager.default.removeItem(at: second) }
        let secondOutcome = try CompressionPipeline.run(
            inputURL: output, outputURL: second, options: Self.mrcOptions())
        #expect(!secondOutcome.plan.actions.contains { action in
            if case .mrc = action { return true }
            return false
        }, "MRC-Output darf nicht erneut MRC-Kandidat werden")
    }
}
