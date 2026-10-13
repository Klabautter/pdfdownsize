import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Final Core Hardening, Phase 4 – Formularzusammenführung ohne PDFKit.
///
/// Der Multi-Source-Zweig benannte kollidierende Feldnamen über PDFKit um und
/// schrieb die Datei dabei neu. Ein solcher Schreibvorgang zerstört die
/// /ToUnicode-Abbildungen von Type1-Fonts – gemessen an einem arXiv-Paper:
/// 470 Wörter einer Seite wurden zu 242 (Befund 15). Für den einzigen
/// verbliebenen PDFKit-Schreibvorgang im Assembler gilt dasselbe.
///
/// Zwei Anforderungen stehen dabei nebeneinander:
///  - Kollidierende Namen aus VERSCHIEDENEN Dokumenten müssen eindeutig
///    werden, sonst überschreiben sich Eingaben gegenseitig.
///  - Ein Feld mit mehreren Widgets bleibt EIN Feld (Plan 4.5). Widgets
///    umzubenennen, die zum selben Feld gehören, zerlegt es.
@Suite struct MultiSourceFormMergeTests {

    /// Dokument mit Type1-Font, /ToUnicode und einem benannten Formularfeld.
    ///
    /// Der Font ist der Punkt: Ohne ihn bliebe unbemerkt, dass ein
    /// PDFKit-Schreibvorgang die Textextraktion zerstört.
    static func formWithType1Font(fieldName: String, marker: String) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()

        let cmap = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CMapName /Custom def
        /CMapType 2 def
        1 begincodespacerange
        <00> <FF>
        endcodespacerange
        2 beginbfchar
        <41> <0041>
        <42> <0042>
        endbfchar
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """
        let toUnicode = b.addStream(dictionary: "", content: cmap)
        let encoding = b.addObject(
            "<</Type/Encoding/BaseEncoding/WinAnsiEncoding"
            + "/Differences[65/glyphA 66/glyphB]>>")
        let font = b.addObject("""
        <</Type/Font/Subtype/Type1/BaseFont/ABCDEF+\(marker)\
        /FirstChar 65/LastChar 66/Widths[500 500]\
        /Encoding \(encoding) 0 R/ToUnicode \(toUnicode) 0 R>>
        """)

        let content = b.addStream(dictionary: "",
                                  content: "BT /F1 18 Tf 72 700 Td (AB) Tj ET")
        let page = b.reserveNumber()
        let widget = b.addObject("""
        <</Type/Annot/Subtype/Widget/FT/Tx/T(\(fieldName))/Rect[72 600 300 640]\
        /P \(page) 0 R/DA(/Helv 12 Tf 0 g)>>
        """)
        b.fillPage(page, parent: pages,
                   resources: "<</Font<</F1 \(font) 0 R>>>>",
                   contents: content, extra: "/Annots[\(widget) 0 R]")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let acro = b.addObject("<</Fields[\(widget) 0 R]/DA(/Helv 0 Tf 0 g)>>")
        let root = b.addObject(
            "<</Type/Catalog/Pages \(pages) 0 R/AcroForm \(acro) 0 R>>")
        return try b.write(rootObject: root, prefix: "formtype1")
    }

    /// Ein Feld mit ZWEI Widgets auf zwei Seiten – dasselbe Feld, zwei
    /// Erscheinungsstellen.
    static func fieldWithTwoWidgets(fieldName: String) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let field = b.reserveNumber()
        let p1 = b.reserveNumber()
        let p2 = b.reserveNumber()

        let w1 = b.addObject("""
        <</Type/Annot/Subtype/Widget/Rect[72 600 300 640]/P \(p1) 0 R\
        /Parent \(field) 0 R>>
        """)
        let w2 = b.addObject("""
        <</Type/Annot/Subtype/Widget/Rect[72 500 300 540]/P \(p2) 0 R\
        /Parent \(field) 0 R>>
        """)
        b.fill(field, "<</FT/Tx/T(\(fieldName))/Kids[\(w1) 0 R \(w2) 0 R]"
            + "/DA(/Helv 12 Tf 0 g)>>")
        b.fillPage(p1, parent: pages, extra: "/Annots[\(w1) 0 R]")
        b.fillPage(p2, parent: pages, extra: "/Annots[\(w2) 0 R]")
        b.fill(pages, "<</Type/Pages/Kids[\(p1) 0 R \(p2) 0 R]/Count 2>>")
        let acro = b.addObject("<</Fields[\(field) 0 R]/DA(/Helv 0 Tf 0 g)>>")
        let root = b.addObject(
            "<</Type/Catalog/Pages \(pages) 0 R/AcroForm \(acro) 0 R>>")
        return try b.write(rootObject: root, prefix: "twowidgets")
    }

    static func toUnicodeCount(of url: URL) throws -> Int {
        let qpdf = try #require(Compressor.findQPDF())
        let expanded = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: expanded) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdf)
        process.arguments = ["--qdf", "--object-streams=disable",
                             url.path, expanded.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        let text = (try? String(contentsOf: expanded, encoding: .isoLatin1)) ?? ""
        return text.components(separatedBy: "/ToUnicode").count - 1
    }

    static func widgetNames(of url: URL) -> [String] {
        guard let document = PDFDocument(url: url) else { return [] }
        var names: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                names.append(annotation.fieldName ?? "?")
            }
        }
        return names
    }

    // MARK: - Der Nachweis

    /// Beim Zusammenführen zweier Formulare darf die Textextraktion nicht
    /// leiden.
    @Test(.hangGuard) func mergingFormsPreservesToUnicode() async throws {
        let a = try Self.formWithType1Font(fieldName: "name", marker: "AAA")
        let b = try Self.formWithType1Font(fieldName: "name", marker: "BBB")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("formmerge-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
            try? FileManager.default.removeItem(at: output)
        }

        let before = try Self.toUnicodeCount(of: a) + Self.toUnicodeCount(of: b)
        try #require(before == 2, "Fixtures tragen nicht je eine /ToUnicode-CMap")

        try await PageAssemblyService.assemble(plan: PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: a, sourcePageIndex: 0),
            PageAssemblyItem(sourceURL: b, sourcePageIndex: 0),
        ]), to: output, progress: { _ in })

        let after = try Self.toUnicodeCount(of: output)
        #expect(after >= before, """
            Beim Zusammenführen gingen /ToUnicode-Abbildungen verloren: \
            \(before) → \(after). Ein PDFKit-Schreibvorgang im Formularpfad \
            zerstört sie (Befund 15).
            """)
    }

    /// Kollidierende Namen aus verschiedenen Dokumenten müssen eindeutig
    /// werden – sonst überschreiben sich Eingaben gegenseitig.
    @Test(.hangGuard) func collidingNamesBecomeUnique() async throws {
        let a = try Self.formWithType1Font(fieldName: "name", marker: "AAA")
        let b = try Self.formWithType1Font(fieldName: "name", marker: "BBB")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("collide-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
            try? FileManager.default.removeItem(at: output)
        }

        try await PageAssemblyService.assemble(plan: PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: a, sourcePageIndex: 0),
            PageAssemblyItem(sourceURL: b, sourcePageIndex: 0),
        ]), to: output, progress: { _ in })

        let names = Self.widgetNames(of: output)
        #expect(names.count == 2, "Erwartet zwei Eingabestellen, gefunden \(names)")
        #expect(Set(names).count == 2, """
            Beide Felder heissen gleich (\(names)) – Eingaben würden sich \
            gegenseitig überschreiben.
            """)
    }

    /// Ein Feld mit zwei Widgets bleibt EIN Feld (Plan 4.5).
    @Test(.hangGuard) func fieldWithTwoWidgetsStaysOneField() async throws {
        let source = try Self.fieldWithTwoWidgets(fieldName: "unterschrift")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("twow-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        try await PageAssemblyService.assemble(plan: PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: source, sourcePageIndex: 0),
            PageAssemblyItem(sourceURL: source, sourcePageIndex: 1),
        ]), to: output, progress: { _ in })

        let names = Self.widgetNames(of: output)
        #expect(names.count == 2, "Erwartet zwei Widgets, gefunden \(names)")
        #expect(Set(names).count == 1, """
            Aus einem Feld mit zwei Widgets wurden \(Set(names).count) Felder \
            (\(names)) – Widgets desselben Feldes dürfen nicht umbenannt werden.
            """)
    }

    /// Kein PDFKit-Schreibvorgang mehr im Assembler.
    @Test(.hangGuard) func assemblerDoesNotWriteViaPDFKit() throws {
        let source = try CompressionEngineStateTests
            .projectSource("PDFTools/PageTools/PageAssemblyService.swift")
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("doc.write(to: outputURL)"), """
            Der Assembler schreibt wieder über PDFKit – das zerstört bei \
            Type1-Fonts die Textextrahierbarkeit (Befund 15).
            """)
    }
}
