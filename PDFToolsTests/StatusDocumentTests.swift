import Testing
import Foundation
@testable import PDFTools

/// Phase 11.3 – keine handgepflegten Testzahlen in Statusdokumenten.
///
/// Der Anlass ist gemessen, nicht befürchtet: Zum Zeitpunkt dieser Prüfung
/// standen in drei Dokumenten drei verschiedene Zahlen – „Tests: 98 grün"
/// (zweimal) und „81 Tests in Debug" – während die Suite über 500 Tests
/// zählte. Keine davon war richtig, und keine fiel jemandem auf.
///
/// Der Test unterscheidet ZWEI Arten von Zahlen:
///
///  - **Verlaufseinträge** – „Phase 7: 354 Tests, 0 Fehlschläge". Die sind
///    richtig und sollen stehen bleiben; sie beschreiben einen Zeitpunkt.
///  - **Aussagen über den heutigen Stand** – die veralten und lügen.
///
/// Unterschieden wird am Ort: Der Kopfbereich eines Dokuments spricht über
/// heute, der Verlauf weiter unten über damals.
@Suite struct StatusDocumentTests {

    static func projectRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()      // PDFToolsTests
            .deletingLastPathComponent()      // PDFTools (Projekt)
    }

    static func text(_ name: String) -> String? {
        try? String(contentsOf: projectRoot().appendingPathComponent(name),
                    encoding: .utf8)
    }

    /// Zahlen, die eine Testanzahl behaupten.
    static let testCountPattern = try! NSRegularExpression(
        pattern: #"(\d{2,5})\s*(Tests?|tests?)\b|Tests?\s*:\s*(\d{2,5})"#)

    static func testCountMatches(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return testCountPattern.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// Der Kopfbereich – die ersten Zeilen, die ein Leser als „so ist es
    /// jetzt" versteht – darf keine Testanzahl behaupten.
    @Test(.needsLocalFiles("RELEASE_READINESS.md"), arguments: ["RELEASE_READINESS.md"])
    func kopfbereichNenntKeineHandgepflegteTestzahl(_ name: String) throws {
        guard let text = Self.text(name) else {
            Issue.record("\(name) fehlt"); return
        }
        // Der erzeugte Block darf Zahlen tragen – er stammt aus einem Lauf.
        let head: String
        if let begin = text.range(of: "<!-- AUTO-STATUS:BEGIN") {
            head = String(text[text.startIndex..<begin.lowerBound])
        } else {
            head = String(text.prefix(600))
        }
        let hits = Self.testCountMatches(in: head)
        #expect(hits.isEmpty, """
            \(name) behauptet im Kopfbereich eine Testanzahl: \(hits).
            Solche Zahlen veralten unbemerkt. Sie gehören in den Block, den
            Scripts/update-status-docs.sh aus einem echten Lauf erzeugt.
            """)
    }

    /// Die Momentaufnahme muss sich als solche zu erkennen geben. Ohne den
    /// Hinweis liest sich `PDF_CORE_BASELINE.md` wie der heutige Stand –
    /// und beschreibt dabei eine Architektur, die es nicht mehr gibt
    /// (`SmartCompressor`, PDFKit-Assembly).
    @Test(.needsLocalFiles("PDF_CORE_BASELINE.md")) func baselineIstAlsMomentaufnahmeGekennzeichnet() throws {
        let text = try #require(Self.text("PDF_CORE_BASELINE.md"))
        #expect(text.contains("MOMENTAUFNAHME"), """
            PDF_CORE_BASELINE.md trägt keinen Hinweis darauf, dass es einen \
            vergangenen Zustand beschreibt.
            """)
        // Der Hinweis muss VOR der Architekturtabelle stehen, sonst liest
        // ihn niemand rechtzeitig.
        if let hint = text.range(of: "MOMENTAUFNAHME"),
           let table = text.range(of: "| Operation | Engine") {
            #expect(hint.lowerBound < table.lowerBound,
                    "Der Hinweis steht hinter der Architekturtabelle")
        }
    }

    /// Der Generator muss existieren und ausführbar sein – sonst ist die
    /// Regel oben eine Behauptung ohne Werkzeug.
    @Test func generatorExistiertUndIstAusfuehrbar() {
        let script = Self.projectRoot()
            .appendingPathComponent("Scripts/update-status-docs.sh")
        #expect(FileManager.default.fileExists(atPath: script.path),
                "Scripts/update-status-docs.sh fehlt")
        #expect(FileManager.default.isExecutableFile(atPath: script.path),
                "Scripts/update-status-docs.sh ist nicht ausführbar")
    }

    /// Der erzeugte Kompatibilitätsbericht bleibt die technische Quelle.
    @Test func kompatibilitaetsberichtBleibtErzeugt() throws {
        guard let text = Self.text("PDF_CORE_COMPATIBILITY_REPORT.md") else { return }
        #expect(text.contains("Automatisch erzeugt"))
    }
}
