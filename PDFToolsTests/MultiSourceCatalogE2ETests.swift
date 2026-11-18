import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan E2: Mehr-Quellen-Fälle ehrlich und kollisionsfrei.
///
/// Befund: Zwei Quellen mit demselben benannten Ziel („sec“) – der zweite
/// Verweis landete im ersten Dokument, weil das Zielverzeichnis nur den
/// ersten Namen behielt; Lesezeichen fielen bei mehreren Quellen ganz weg;
/// /DR kam nur aus der ersten Quelle, Felder der zweiten verloren ihre Schrift.
///
/// Fehlermöglichkeiten: (1) ein Verweis springt in die falsche Quelle;
/// (2) der Namensbaum ist unsortiert (Norm verlangt Sortierung, Leser suchen
/// binär); (3) Lesezeichen fehlen oder hängen nicht unter dem Dateinamen;
/// (4) /DR-Schriften der zweiten Quelle fehlen; (5) der Hinweis nennt Dinge,
/// die die Quellen gar nicht haben, oder verschweigt welche.
@Suite(.serialized) struct MultiSourceCatalogE2ETests {

    /// Zwei Seiten. Seite 1 trägt einen Verweis auf das benannte Ziel „sec“
    /// (Seite 2) und ein Textfeld mit eigener /DR-Schrift; Lesezeichen
    /// „Kapitel <tag>“ auf Seite 2. Beide Quellen entstehen mit demselben
    /// Aufbau – also auch mit denselben Objektnummern.
    static func source(_ tag: String, in dir: URL) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let p1 = b.reserveNumber()
        let p2 = b.reserveNumber()
        let link = b.addObject("<</Type/Annot/Subtype/Link/Rect[72 600 300 630]/Border[0 0 0]/Dest(sec)>>")
        let field = b.addObject("<</Type/Annot/Subtype/Widget/FT/Tx/T(feld)/Rect[72 500 300 530]"
            + "/DA(/F\(tag) 12 Tf 0 g)/P \(p1) 0 R>>")
        for (n, page) in [p1, p2].enumerated() {
            let content = b.addStream(dictionary: "", content: "BT /F1 24 Tf 72 700 Td (Quelle \(tag) Seite \(n + 1)) Tj ET")
            b.fillPage(page, parent: pages, resources: "<</Font<</F1 \(font) 0 R>>>>", contents: content,
                       extra: n == 0 ? "/Annots[\(link) 0 R \(field) 0 R]" : "")
        }
        b.fill(pages, "<</Type/Pages/Kids[\(p1) 0 R \(p2) 0 R]/Count 2>>")
        let outlines = b.reserveNumber()
        let item = b.addObject("<</Title(Kapitel \(tag))/Parent \(outlines) 0 R/Dest[\(p2) 0 R/Fit]>>")
        b.fill(outlines, "<</Type/Outlines/First \(item) 0 R/Last \(item) 0 R/Count 1>>")
        let drFont = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Courier/Name/F\(tag)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R/Outlines \(outlines) 0 R"
            + "/Names<</Dests<</Names[(sec)[\(p2) 0 R/Fit]]>>>>"
            + "/AcroForm<</Fields[\(field) 0 R]/DR<</Font<</F\(tag) \(drFont) 0 R>>>>/DA(/F\(tag) 0 Tf 0 g)>>>>")
        let written = try b.write(rootObject: root, prefix: "e2-\(tag)")
        let url = dir.appendingPathComponent("\(tag).pdf")
        try FileManager.default.moveItem(at: written, to: url)
        return url
    }

    static func workDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func merged(_ urls: [URL], in dir: URL) async throws -> URL {
        var pages: [PageItem] = []
        for url in urls {
            let source = SourceDocument(url: url, pageCount: 2)
            pages += [PageItem(source: source, pageIndex: 0), PageItem(source: source, pageIndex: 1)]
        }
        let out = dir.appendingPathComponent("zusammen.pdf")
        try await PageAssemblyService.assemble(pages: pages, to: out) { _ in }
        return out
    }

    @Test func gleichnamigeZieleSpringenInDieEigeneQuelle() async throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await Self.merged([try Self.source("A", in: dir), try Self.source("B", in: dir)], in: dir)
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 4)
        func linkTarget(_ pageIndex: Int) -> Int? {
            guard let page = doc.page(at: pageIndex),
                  let link = page.annotations.first(where: { $0.type == "Link" }),
                  let target = link.destination?.page ?? (link.action as? PDFActionGoTo)?.destination.page
            else { return nil }
            return doc.index(for: target)
        }
        #expect(linkTarget(0) == 1, "Verweis aus A springt nicht auf A Seite 2")
        #expect(linkTarget(2) == 3, "Verweis aus B springt nicht auf B Seite 2")
    }

    @Test func namensbaumIstSortiertUndEindeutig() async throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await Self.merged([try Self.source("B", in: dir), try Self.source("A", in: dir)], in: dir)
        let core = try PDFCoreDocument(path: out.path)
        let names = try core.namedDestinationNames()
        #expect(names.count == 2, "erwartet zwei eindeutige Ziele, bekam \(names)")
        #expect(names == names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }, "Namensbaum unsortiert: \(names)")
    }

    @Test func lesezeichenAllerQuellenUnterDemDateinamen() async throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await Self.merged([try Self.source("A", in: dir), try Self.source("B", in: dir)], in: dir)
        let doc = try #require(PDFDocument(url: out))
        let root = try #require(doc.outlineRoot)
        let top = (0..<root.numberOfChildren).compactMap { root.child(at: $0) }
        #expect(top.map(\.label) == ["A", "B"])
        for (k, group) in top.enumerated() {
            #expect(group.destination?.page.map { doc.index(for: $0) } == 2 * k, "Dateieintrag zeigt nicht auf die erste Seite")
            let child = try #require(group.child(at: 0))
            #expect(child.label == "Kapitel \(k == 0 ? "A" : "B")")
            #expect(child.destination?.page.map { doc.index(for: $0) } == 2 * k + 1)
        }
    }

    @Test func formularRessourcenAllerQuellen() async throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await Self.merged([try Self.source("A", in: dir), try Self.source("B", in: dir)], in: dir)
        let core = try PDFCoreDocument(path: out.path)
        let fonts = try core.acroFormResourceFontNames()
        #expect(fonts.contains("FA") && fonts.contains("FB"), "DR-Schriften: \(fonts)")
    }

    @Test func hinweisNenntGenauDieVerlusteDerQuellen() throws {
        let rich = try SingleSourceAssemblyE2ETests.richDocument()
        defer { try? FileManager.default.removeItem(at: rich) }
        let plain = try PDFFixtures.vectorTextPDF(lines: 2)
        defer { try? FileManager.default.removeItem(at: plain) }

        let losses = MergeLossSummary.losses(for: [rich, plain])
        #expect(Set(losses.map(\.feature)) == [.tags, .attachments, .layers, .encryption])
        #expect(losses.allSatisfy { $0.files == [rich.lastPathComponent] })
        #expect(MergeLossSummary.losses(for: [rich]).isEmpty, "Eine Quelle verliert nichts (E1)")
        #expect(MergeLossSummary.losses(for: [plain, plain]).isEmpty)
    }
}
