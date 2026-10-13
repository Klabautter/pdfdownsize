import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Kompressions-Backend nach Masterplan Schritt 11.
///
/// Diese Suite prüfte früher die Auswahl zwischen zwei Engines und deren
/// Parität. Seit der Legacy-Pfad entfernt ist, gibt es nichts mehr
/// auszuwählen – geblieben ist die Frage, ob der verbliebene Pfad gültige
/// Ergebnisse liefert.
///
/// Entfernt wurde dabei auch ein hartcodierter Ablagepfad
/// (`/tmp/opencode/p24_…pdf`), über den der Test Zwischenergebnisse
/// wegschrieb – ein Entwicklerpfad im Testcode (Masterplan 2.5).
@MainActor
struct EngineSelectionTests {

    /// Der Produktionspfad liefert eine gültige, nicht grössere Ausgabe.
    @Test func productionPathProducesValidOutput() async throws {
        let input = try PDFFixtures.photoHeavyPDF(pixels: 1500)
        defer { try? FileManager.default.removeItem(at: input) }
        let inBytes = Compressor.fileSize(of: input)
        let expectedPages = try #require(PDFDocument(url: input)?.pageCount)

        let result = try Compressor().compress(inputURL: input, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.outputBytes > 0)
        #expect(result.outputBytes <= inBytes + 1024, """
            Ausgabe gewachsen: \(inBytes) → \(result.outputBytes) Bytes
            """)

        let core = try #require(try? PDFCoreDocument(path: result.outputURL.path))
        #expect(core.pageCount == expectedPages)
        #expect(throws: Never.self) { try core.check() }
    }

}
