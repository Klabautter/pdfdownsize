import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Was der Korpuslauf an den Phasen 5 und 6 gefunden hat.
///
/// Alle drei Fehler hier waren in der Unit-Suite unsichtbar: Die Fixtures
/// kannten weder nachgepackte Anhänge noch entartete Verweisflächen noch
/// Dokumente, über die qpdf Warnungen ausgibt. Erst 285 echte Dokumente
/// haben es gezeigt. Diese Tests holen die Fälle in die Suite zurück.
@Suite struct CorpusFindingsTests {

    // MARK: - Befund 1: Warnungen sind kein Schaden

    /// Ein Dokument, über das qpdf WARNUNGEN ausgibt, muss bearbeitbar
    /// bleiben.
    ///
    /// Die vertiefte Strukturprüfung wertete jede neue Warnung als
    /// Fehlschlag. Solange sie nur den Seitenbaum ablief, fielen kaum welche
    /// an; seit sie jeden Stream liest, viele. Drei einwandfreie Dokumente
    /// des Korpus – ein IRS-Formular mit unstimmiger Hint-Tabelle, eine
    /// Publikation mit einem Stream ohne sauberes Ende – waren damit nicht
    /// einmal mehr als EINGABE zu gebrauchen. qpdf selbst nennt das
    /// „operation succeeded with warnings".
    @Test(.hangGuard, arguments: [
        "RealWorld/IRS/i1040gi.pdf",
        "RealWorld/IRS/p946.pdf",
    ])
    @MainActor
    func documentsWithQPDFWarningsStayUsable(relativePath: String) throws {
        guard let url = CorpusRunnerTests.corpusFixture(relativePath) else { return }
        let core = try #require(try? PDFCoreDocument(path: url.path),
                                "\(relativePath) öffnet nicht")
        #expect(core.pageCount > 0)
        #expect(throws: Never.self) { try core.check() }
    }

    /// Gegenprobe zum obigen: Die Prüfung darf dabei nicht stumpf geworden
    /// sein. Was objektiv unlesbar ist, meldet sie weiterhin.
    @Test(.hangGuard) func unreadableDamageIsStillCaught() throws {
        let selfEvident = ["bad-stream-length", "page-tree-cycle",
                           "image-dimension-mismatch"]
        for entry in MalformedCorpus.entries
        where selfEvident.contains(entry.name) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cf-\(entry.name)-\(UUID().uuidString).pdf")
            try entry.make().write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let core = try #require(try? PDFCoreDocument(path: url.path),
                                    "\(entry.name) öffnet unerwartet nicht")
            #expect(throws: (any Error).self) { try core.check() }
        }
    }

    // MARK: - Befund 2: Anhänge – Inhalt statt Verpackung

    /// Ein Anhang, dessen Strom beim Struktur-Pass nachgepackt wird, ist
    /// derselbe Anhang.
    ///
    /// Der Vergleich nahm zuvor die GESPEICHERTE Länge und meldete
    /// „3968 Bytes → 3773 Bytes" bei bitgleichem Inhalt – 120 Fehlschläge
    /// auf 24 einwandfreien Dokumenten.
    @Test(.hangGuard) func recompressedAttachmentIsNotAChange() throws {
        let url = try PDFFixtures.compressibleAttachmentPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try PDFSemanticSnapshot.capture(url)
        try #require(before.attachments.count == 1,
                     "Fixture trägt keinen Anhang: \(before.attachments)")
        try #require(before.attachments[0].contentHash != "-",
                     "Ohne Prüfsumme prüft dieser Test nichts")

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let after = try PDFSemanticSnapshot.capture(result.outputURL)

        #expect(after.attachments.count == 1, "Anhang verloren")
        #expect(after.attachments[0].byteCount == before.attachments[0].byteCount,
                "Die gemessene Größe ist die gespeicherte, nicht die tatsächliche")
        #expect(after.attachments[0].contentHash == before.attachments[0].contentHash)

        let blocking = PDFSemanticSnapshot.differences(before, after)
            .filter { $0.severity <= .high }
        #expect(blocking.isEmpty, """
            Kompression eines Dokuments mit Anhang meldet: \
            \(blocking.map(\.message).joined(separator: " | "))
            """)
    }

    /// Und die Gegenprobe: Ein WIRKLICH anderer Anhang wird erkannt.
    @Test(.hangGuard) func changedAttachmentContentIsDetected() throws {
        let url = try PDFFixtures.compressibleAttachmentPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)

        var after = before
        after.attachments[0].contentHash = "anderer-inhalt"

        let diffs = PDFSemanticSnapshot.differences(before, after)
        #expect(diffs.contains { $0.kind == .attachmentContent }, """
            Geänderter Anhanginhalt wird nicht bemerkt.
            """)
    }

    // MARK: - Befund 3: Mehrdeutige Verweisflächen

    /// Links mit entarteter Fläche dürfen keinen Unterschied erfinden.
    ///
    /// `SP.800-37r2.pdf` enthält Verweise mit Breite und Höhe null, sechs
    /// davon auf einer Seite. Über die Fläche zugeordnet verglich der
    /// Vergleich Link A gegen Link B und meldete Ziele, die niemand geändert
    /// hatte.
    @Test(.hangGuard) func ambiguousLinkBoundsProduceNoFalseDifference() throws {
        let url = try PDFFixtures.outlineLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        var before = try PDFSemanticSnapshot.capture(url)

        // Drei Links, gleiche Seite, gleiche entartete Fläche, drei Ziele.
        let degenerate = "0.00,792.00,0.00,792.00"
        before.navigation.links = (0..<3).map {
            .init(sourcePage: 0, destinationType: "explicit", targetPage: $0,
                  namedDestination: "", bounds: degenerate)
        }
        // Dieselben drei, nur in anderer Reihenfolge gelesen – so wie es
        // nach einem Neuschreiben vorkommt.
        var after = before
        after.navigation.links.reverse()

        let linkIssues = PDFSemanticSnapshot.differences(before, after)
            .filter { $0.kind == .internalLinks }
        #expect(linkIssues.isEmpty, """
            Mehrdeutige Verweisflächen erzeugen einen Unterschied, den es \
            nicht gibt: \(linkIssues.map(\.message).joined(separator: "; "))
            """)
    }

    /// Gegenprobe: Ein eindeutig zuzuordnender Link wird weiterhin geprüft.
    @Test(.hangGuard) func unambiguousLinkIsStillCompared() throws {
        let url = try PDFFixtures.outlineLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        var before = try PDFSemanticSnapshot.capture(url)
        before.navigation.links = [
            .init(sourcePage: 0, destinationType: "explicit", targetPage: 1,
                  namedDestination: "", bounds: "72.00,700.00,200.00,720.00"),
        ]
        var after = before
        after.navigation.links[0].targetPage = 0

        let linkIssues = PDFSemanticSnapshot.differences(before, after)
            .filter { $0.kind == .internalLinks }
        #expect(!linkIssues.isEmpty, """
            Ein eindeutiger Link mit geändertem Ziel wird nicht mehr geprüft – \
            die Ausnahme für mehrdeutige Flächen greift zu weit.
            """)
    }
}
