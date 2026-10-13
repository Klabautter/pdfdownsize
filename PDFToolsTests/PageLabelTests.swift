import Testing
import PDFKit
@testable import PDFTools

/// Monster Epic Phase 13 – Page Labels (einfache + mehrere Ranges,
/// Reorder / Delete / Extract) über beide Engines.
@MainActor
struct PageLabelTests {

    /// 4-Seiten-PDF: Seiten 0–1 römisch, Seiten 2–3 dezental ab 5.
    static func labeledRangesFixture() throws -> URL {
        var data = Data()
        var offsets: [Int] = []
        func add(_ s: String) {
            offsets.append(data.count)
            data.append(Data(s.utf8))
        }
        data.append(Data("%PDF-1.4\n".utf8))
        add("1 0 obj<</Type/Catalog/Pages 2 0 R/PageLabels 5 0 R>>endobj\n")
        add("2 0 obj<</Type/Pages/Kids[3 0 R 4 0 R 6 0 R 7 0 R]/Count 4>>endobj\n")
        add("3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\n")
        add("4 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\n")
        add("6 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\n")
        add("7 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\n")
        add("5 0 obj<</Nums[0<</S/r>>2<</S/D/St 5>>]>>endobj\n")

        let startxref = data.count
        data.append(Data("xref\n0 9\n".utf8))
        data.append(Data(String(format: "0000000000 65535 f \n").utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer<</Size 9/Root 1 0 R>>\nstartxref\n\(startxref)\n%%EOF\n".utf8))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("labels-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    private func itemsFor(_ url: URL) throws -> [PageItem] {
        let doc = try #require(PDFDocument(url: url))
        let source = SourceDocument(url: url, pageCount: doc.pageCount)
        return (0..<doc.pageCount).map { PageItem(source: source, pageIndex: $0) }
    }

    @Test func fixtureLabelsAreReadableViaBridge() throws {
        let url = try Self.labeledRangesFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let core = try PDFCoreDocument(path: url.path)
        #expect(try core.pageLabelEncodings() == ["0|r||", "2|D||5"])
    }

    @Test func fullCopyPreservesLabelRanges() async throws {
        let url = try Self.labeledRangesFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let items = try itemsFor(url)

        do {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("p13-full-libqpdf-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: out) }
            try await PageAssemblyService.assemble(plan: items.assemblyPlan, to: out,
                                              progress: { _ in })
            let core = try PDFCoreDocument(path: out.path)
            #expect(try core.pageLabelEncodings() ==
                    ["0|r||1", "1|r||2", "2|D||5", "3|D||6"], "libqpdf")
        }
    }

    @Test func reorderRemapsPerPageLabels() async throws {
        let url = try Self.labeledRangesFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))
        let source = SourceDocument(url: url, pageCount: doc.pageCount)
        let items = (0..<4).reversed().map { PageItem(source: source, pageIndex: $0) }

        do {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("p13-rev-libqpdf-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: out) }
            try await PageAssemblyService.assemble(plan: items.assemblyPlan, to: out,
                                              progress: { _ in })
            let core = try PDFCoreDocument(path: out.path)
            // Pro-Seite-Einträge folgen den (umgedrehten) Seiten.
            #expect(try core.pageLabelEncodings() ==
                    ["0|D||6", "1|D||5", "2|r||2", "3|r||1"],
                    "libqpdf got \((try? core.pageLabelEncodings()) ?? [])")
        }
    }

    @Test func extractKeepsSurvivingLabelsOnly() async throws {
        let url = try Self.labeledRangesFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))
        let source = SourceDocument(url: url, pageCount: doc.pageCount)
        let items = [PageItem(source: source, pageIndex: 2),
                     PageItem(source: source, pageIndex: 3)]

        do {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("p13-extract-libqpdf-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: out) }
            try await PageAssemblyService.assemble(plan: items.assemblyPlan, to: out,
                                              progress: { _ in })
            let core = try PDFCoreDocument(path: out.path)
            #expect(try core.pageLabelEncodings() ==
                    ["0|D||5", "1|D||6"], "libqpdf")
        }
    }
}
