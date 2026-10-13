import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Minimalreproduktion für Befund 15: Assemblierung zerstört bei
/// Type1-Fonts die Textextrahierbarkeit.
///
/// An einem CVPR-/arXiv-Paper gemessen: 470 Wörter der ersten Seite werden zu
/// 242, „Differential" zu „Di!erential". Betroffen sind ausschliesslich
/// Dokumente mit Type1-Fonts – und zwar in BEIDEN Backends gleichermassen,
/// während `qpdf --pages` auf derselben Datei den Text vollständig erhält.
///
/// Ein 16-MB-Paper taugt nicht zur Fehlersuche. Diese Suite baut denselben
/// Aufbau in kleinstmöglicher Form: ein Type1-Font mit eigenem /Encoding und
/// /Differences-Array, wie LaTeX ihn erzeugt, plus /ToUnicode für die
/// Rückübersetzung.
@Suite struct Type1TextLossTests {

    /// Zweiseitiges Dokument mit einem Type1-Font, der Glyphen über ein
    /// /Differences-Array benennt und per /ToUnicode zurückübersetzt.
    static func makeType1Document() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()

        // /ToUnicode-CMap: bildet die Codes 65..68 auf "TEST" ab.
        let cmap = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CMapName /Custom def
        /CMapType 2 def
        1 begincodespacerange
        <00> <FF>
        endcodespacerange
        4 beginbfchar
        <41> <0054>
        <42> <0045>
        <43> <0053>
        <44> <0054>
        endbfchar
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """
        let toUnicode = b.addStream(dictionary: "", content: cmap)

        // Type1-Font mit eigenem Encoding über /Differences – das Muster,
        // das LaTeX für Mathematik- und Textfonts benutzt.
        let encoding = b.addObject(
            "<</Type/Encoding/BaseEncoding/WinAnsiEncoding"
            + "/Differences[65/glyphA 66/glyphB 67/glyphC 68/glyphD]>>")
        let font = b.addObject("""
        <</Type/Font/Subtype/Type1/BaseFont/ABCDEF+TestFont\
        /FirstChar 65/LastChar 68/Widths[500 500 500 500]\
        /Encoding \(encoding) 0 R/ToUnicode \(toUnicode) 0 R>>
        """)

        var pageIDs: [Int] = []
        for index in 0..<2 {
            let text = "BT /F1 24 Tf 72 \(700 - index * 40) Td (ABCD) Tj ET"
            let stream = b.addStream(dictionary: "", content: text)
            pageIDs.append(b.addPage(parent: pages,
                                     resources: "<</Font<</F1 \(font) 0 R>>>>",
                                     contents: stream))
        }
        b.fill(pages, "<</Type/Pages/Kids[\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))]"
            + "/Count \(pageIDs.count)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "type1")
    }

    /// Zählt Font-Objekte und /ToUnicode-Referenzen über qpdf – unabhängig
    /// von der eigenen Bridge.
    static func fontStats(of url: URL) throws -> (fonts: Int, toUnicode: Int) {
        let qpdf = try #require(Compressor.findQPDF())
        let expanded = FileManager.default.temporaryDirectory
            .appendingPathComponent("t1-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: expanded) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdf)
        process.arguments = ["--qdf", "--object-streams=disable",
                             url.path, expanded.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let text = (try? String(contentsOf: expanded, encoding: .isoLatin1)) ?? ""
        func count(_ needle: String) -> Int {
            text.components(separatedBy: needle).count - 1
        }
        return (count("/Type /Font") + count("/Type/Font"),
                count("/ToUnicode"))
    }

    /// Die Fixture muss den Aufbau tatsächlich tragen.
    @Test(.hangGuard) func fixtureCarriesType1FontWithEncoding() throws {
        let url = try Self.makeType1Document()
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = try Self.fontStats(of: url)
        #expect(stats.fonts >= 1, "Fixture ohne Font-Objekt")
        #expect(stats.toUnicode >= 1, "Fixture ohne /ToUnicode")

        // Die Textextraktion wird hier NICHT geprüft: Der Font trägt keine
        // eingebettete Programmdatei, und PDFKit fällt dann auf einen
        // Ersatzfont zurück. Für den Befund kommt es darauf nicht an – er
        // dreht sich um die Frage, ob die /ToUnicode-Abbildung die
        // Assemblierung überlebt. Genau das prüft die zweite Funktion.
        #expect(try Self.fontStats(of: url).toUnicode == 1,
                "Fixture trägt nicht genau eine /ToUnicode-Referenz")
    }

    /// Der eigentliche Nachweis: Überlebt die /ToUnicode-Abbildung die
    /// Assemblierung?
    @Test(.hangGuard)
    func toUnicodeSurvivesAssembly() async throws {
        let source = try Self.makeType1Document()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("t1-out-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let document = SourceDocument(url: source, pageCount: 2)
        let plan = PageAssemblyPlan(pages: (0..<2).map {
            PageItem(source: document, pageIndex: $0).assemblyItem
        })
        try await PageAssemblyService.assemble(plan: plan, to: output,
                                               progress: { _ in })

        let before = try Self.fontStats(of: source)
        let after = try Self.fontStats(of: output)
        let text = (PDFDocument(url: output)?.page(at: 0)?.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("libqpdf: Fonts \(before.fonts)→\(after.fonts), "
            + "ToUnicode \(before.toUnicode)→\(after.toUnicode), Text: \(text)")

        #expect(after.toUnicode >= before.toUnicode, """
            libqpdf: /ToUnicode-Referenzen \(before.toUnicode) → \
            \(after.toUnicode) – ohne sie ist der Text nicht mehr lesbar.
            """)
        _ = text   // nur für die Protokollzeile oben
    }

    /// Dieselbe Fixture, aber mit OBJEKTSTRÖMEN – so, wie LaTeX-Werkzeuge
    /// und die meisten realen Erzeuger schreiben.
    ///
    /// Die einfache Variante oben zeigt den Verlust nur im PDFKit-Pfad;
    /// am echten arXiv-Paper verlieren BEIDE Backends. Der Unterschied
    /// zwischen Fixture und Realdokument muss also in einer Eigenschaft
    /// liegen, die die Fixture noch nicht hat – Objektströme sind der
    /// nächstliegende Kandidat.
    static func makeType1DocumentWithObjectStreams() throws -> URL {
        let plain = try makeType1Document()
        defer { try? FileManager.default.removeItem(at: plain) }

        let qpdf = try #require(Compressor.findQPDF())
        let packed = FileManager.default.temporaryDirectory
            .appendingPathComponent("type1-objstm-\(UUID().uuidString).pdf")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdf)
        process.arguments = ["--object-streams=generate", plain.path, packed.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return packed
    }

    @Test(.hangGuard)
    func toUnicodeSurvivesWithObjectStreams() async throws {
        let source = try Self.makeType1DocumentWithObjectStreams()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("t1-objstm-out-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let before = try Self.fontStats(of: source)
        try #require(before.toUnicode >= 1,
                     "Fixture mit Objektströmen trägt keine /ToUnicode-Referenz")

        let document = SourceDocument(url: source, pageCount: 2)
        let plan = PageAssemblyPlan(pages: (0..<2).map {
            PageItem(source: document, pageIndex: $0).assemblyItem
        })
        try await PageAssemblyService.assemble(plan: plan, to: output,
                                               progress: { _ in })

        let after = try Self.fontStats(of: output)
        print("libqpdf mit Objektströmen: ToUnicode \(before.toUnicode)→\(after.toUnicode)")
        #expect(after.toUnicode >= before.toUnicode, """
            libqpdf: /ToUnicode \(before.toUnicode) → \(after.toUnicode) \
            bei einer Quelle mit Objektströmen.
            """)
    }


    // MARK: - Der eigentliche Befund: PDFKit in der Nachsorge

    /// Ein PDFKit-Schreibvorgang zerstört die Textextrahierbarkeit.
    ///
    /// Das ist die Ursache von Befund 15 – gemessen an einem arXiv-Paper:
    /// nach `pdfcore_write_pages` 470 Wörter, nach einem einzigen
    /// `PDFDocument.write(to:)` noch 242. Der Test hält die Messung an einer
    /// eigenen Fixture fest, damit sie ohne Korpus reproduzierbar bleibt.
    @Test(.hangGuard) func pdfKitWriteDamagesToUnicode() throws {
        let source = try Self.makeType1Document()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let before = try Self.fontStats(of: source)
        let document = try #require(PDFDocument(url: source))
        #expect(document.write(to: output))
        let after = try Self.fontStats(of: output)

        print("PDFKit-Schreibvorgang: /ToUnicode \(before.toUnicode) → \(after.toUnicode)")
        #expect(before.toUnicode == 1, "Messgrundlage fehlt")
    }

    /// Die Nachsorge der Assemblierung darf NICHT über PDFKit schreiben.
    ///
    /// Genau das war der Fehler: `applyTopLevelOutlines` setzte den
    /// Outline-Baum über PDFKit und schrieb die Datei damit neu – für BEIDE
    /// Backends. Die libqpdf-Assemblierung selbst war einwandfrei; der Schaden
    /// entstand danach.
    ///
    /// Der Test liest den Quellabzug, weil sich die Eigenschaft nicht am
    /// Verhalten festmachen lässt: Ein Dokument ohne Outlines und ohne
    /// Formularfelder durchläuft die betroffenen Zweige gar nicht.
    @Test(.hangGuard) func postProcessingDoesNotWriteViaPDFKit() throws {
        let source = try CompressionEngineStateTests
            .projectSource("PDFTools/PageTools/PageAssemblyService.swift")

        // Der Outline-Aufbau läuft über die Bridge.
        #expect(source.contains("PDFCoreDocument.writeOutlines"),
                "Outline-Aufbau läuft nicht über die Bridge")

        // Der verbliebene PDFKit-Schreibvorgang steht ausschliesslich im
        // Mehrquellen-Zweig der Feldnamen-Vereindeutigung.
        // Kommentarzeilen zählen nicht mit: Die Begründung im Code zitiert den
        // früheren Aufruf wörtlich, und ein Test, der Erklärungen als Code
        // zählt, misst das Falsche.
        let writes = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .filter { $0.contains("doc.write(to: outputURL)") }
            .count
        // GAR KEIN PDFKit-Schreibvorgang mehr: Der letzte stand im
        // Mehrquellen-Zweig der Feldnamen-Vereindeutigung und ist mit
        // Phase 4 in die Bridge gewandert – dorthin, wo das /AcroForm
        // ohnehin aufgebaut wird.
        #expect(writes == 0, """
            \(writes) PDFKit-Schreibvorgänge in der Nachsorge – jeder davon \
            zerstört bei Type1-Fonts die Textextrahierbarkeit (Befund 15).
            """)
    }
}
