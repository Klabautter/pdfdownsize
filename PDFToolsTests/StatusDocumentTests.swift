import Testing
import Foundation
@testable import PDFTools

/// Statusdokumente im Repo stammen aus Maschinendaten, nicht aus Handarbeit.
///
/// Die früheren Prüfungen auf handgepflegte Testzahlen in
/// `RELEASE_READINESS.md` und `PDF_CORE_BASELINE.md` sind mit diesen Dokumenten
/// archiviert worden (Masterplan 18.11.2026, G6). Übrig bleibt der eine
/// Statusbericht, der im Repo liegt: der aus einem Korpuslauf erzeugte
/// Kompatibilitätsbericht.
@Suite struct StatusDocumentTests {

    static func projectRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()      // PDFToolsTests
            .deletingLastPathComponent()      // PDFTools (Projekt)
    }

    /// Der erzeugte Kompatibilitätsbericht bleibt die technische Quelle.
    @Test(.needsLocalFiles("PDF_CORE_COMPATIBILITY_REPORT.md"))
    func kompatibilitaetsberichtBleibtErzeugt() throws {
        let url = Self.projectRoot().appendingPathComponent("PDF_CORE_COMPATIBILITY_REPORT.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("Automatisch erzeugt"))
    }
}
