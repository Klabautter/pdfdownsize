import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan E1: Ein-Quellen-Operationen behalten das Dokument.
///
/// Befund: Organisieren baute IMMER ein neues Dokument und kopierte nur
/// Seiten, Formularfelder und Ziele – Tags, Anhänge, XMP, Ebenen und
/// Verschlüsselung gingen verloren, auch wenn nur eine Seite gelöscht oder
/// gedreht wurde.
///
/// Fehlermöglichkeiten: (1) Katalogeinträge fehlen in der Ausgabe;
/// (2) die Verschlüsselung fällt weg; (3) Reihenfolge/Drehung stimmen nicht;
/// (4) ein Lesezeichen auf die gelöschte Seite bleibt als toter Verweis.
@Suite(.serialized) struct SingleSourceAssemblyE2ETests {

    static func qpdf(_ args: [String]) throws -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("qpdf-out-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        let handle = try FileHandle(forWritingTo: out)
        let process = Process()
        process.executableURL = Compressor.bundledQPDFURL()
        process.arguments = args
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try handle.close()
        return String(decoding: try Data(contentsOf: out), as: UTF8.self)
    }

    /// Drei Seiten; Katalog mit Struktur, XMP, Anhang, Ebene, zwei Lesezeichen
    /// (auf Seite 1 und 2); danach mit Besitzerpasswort (AES-256) verschlüsselt.
    static func richDocument() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        var pageIDs: [Int] = []
        for n in 1...3 {
            let content = b.addStream(dictionary: "", content: "BT /F1 24 Tf 72 700 Td (Seite \(n)) Tj ET")
            pageIDs.append(b.addPage(parent: pages, resources: "<</Font<</F1 \(font) 0 R>>>>", contents: content))
        }
        b.fill(pages, "<</Type/Pages/Kids[\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))]/Count 3>>")
        let xmp = b.addStream(dictionary: "/Type/Metadata/Subtype/XML",
                              content: "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"/></x:xmpmeta>")
        let file = b.addStream(dictionary: "/Type/EmbeddedFile", content: "Anhang")
        let spec = b.addObject("<</Type/Filespec/F(anhang.txt)/UF(anhang.txt)/EF<</F \(file) 0 R>>>>")
        let ocg = b.addObject("<</Type/OCG/Name(Ebene)>>")
        let outlines = b.reserveNumber()
        let o1 = b.reserveNumber()
        let o2 = b.reserveNumber()
        b.fill(o1, "<</Title(Kapitel 1)/Parent \(outlines) 0 R/Next \(o2) 0 R/Dest[\(pageIDs[0]) 0 R/Fit]>>")
        b.fill(o2, "<</Title(Kapitel 2)/Parent \(outlines) 0 R/Prev \(o1) 0 R/Dest[\(pageIDs[1]) 0 R/Fit]>>")
        b.fill(outlines, "<</Type/Outlines/First \(o1) 0 R/Last \(o2) 0 R/Count 2>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R/Metadata \(xmp) 0 R"
            + "/StructTreeRoot<</Type/StructTreeRoot>>/MarkInfo<</Marked true>>"
            + "/Names<</EmbeddedFiles<</Names[(anhang.txt) \(spec) 0 R]>>>>"
            + "/OCProperties<</OCGs[\(ocg) 0 R]/D<<>>>>/Outlines \(outlines) 0 R>>")
        let plain = try b.write(rootObject: root, prefix: "e1-rich")
        defer { try? FileManager.default.removeItem(at: plain) }
        let locked = PDFFixtures.fixtureURL(prefix: "e1-rich-enc")
        _ = try qpdf(["--encrypt", "--user-password=", "--owner-password=besitzer", "--bits=256",
                      "--", plain.path, locked.path])
        try #require(FileManager.default.fileExists(atPath: locked.path))
        return locked
    }

    @Test func seiteLoeschenUndDrehenBehaeltDasDokument() async throws {
        let input = try Self.richDocument()
        defer { try? FileManager.default.removeItem(at: input) }
        let source = SourceDocument(url: input, pageCount: 3)
        var first = PageItem(source: source, pageIndex: 0)
        first.rotation = 90
        let pages = [first, PageItem(source: source, pageIndex: 2)]
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("e1-out-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(pages: pages, to: out) { _ in }

        let encryption = try Self.qpdf(["--show-encryption", out.path])
        #expect(encryption.contains("R = 6"), "Verschlüsselung fehlt: \(encryption)")
        let qdf = FileManager.default.temporaryDirectory.appendingPathComponent("e1-qdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: qdf) }
        _ = try Self.qpdf(["--qdf", "--object-streams=disable", out.path, qdf.path])
        let text = String(decoding: try Data(contentsOf: qdf), as: UTF8.self)
        for key in ["/StructTreeRoot", "/EmbeddedFiles", "/Metadata", "/OCProperties", "/MarkInfo"] {
            #expect(text.contains(key), "\(key) fehlt nach der Operation")
        }

        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 2)
        #expect(doc.page(at: 0)?.string?.contains("Seite 1") == true)
        #expect(doc.page(at: 1)?.string?.contains("Seite 3") == true)
        #expect(doc.page(at: 0)?.rotation == 90)
        // Lesezeichen „Kapitel 2“ zeigte auf die gelöschte Seite 2.
        let titles = (0..<(doc.outlineRoot?.numberOfChildren ?? 0)).compactMap { doc.outlineRoot?.child(at: $0)?.label }
        #expect(titles.contains("Kapitel 1"))
        let deadTarget = (0..<(doc.outlineRoot?.numberOfChildren ?? 0)).compactMap { doc.outlineRoot?.child(at: $0) }
            .contains { $0.label == "Kapitel 2" && $0.destination?.page != nil
                && doc.index(for: $0.destination!.page!) == NSNotFound }
        #expect(!deadTarget, "Lesezeichen auf gelöschte Seite zeigt ins Leere")
    }
}
