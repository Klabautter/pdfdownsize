import Testing
import AppKit
import PDFKit
import CryptoKit
@testable import PDFTools

/// Monster Epic Phasen 14–17: AcroForm-Konflikte, Attachments-Policy,
/// Metadata-Policy, Originaldateien unverändert.
@MainActor
struct PolicyHardeningTests {

    // MARK: Phase 14 – Formularfeld-Namen

    @Test func duplicateFormFieldNamesAreUniquified() async throws {
        let formA = try PDFFixtures.formWidgetsPDF(name: "p14-a")
        let formB = try PDFFixtures.formWidgetsPDF(name: "p14-b")
        defer {
            try? FileManager.default.removeItem(at: formA)
            try? FileManager.default.removeItem(at: formB)
        }
        // Beide Quellen erzeugen identische Auto-Namen (text0/text1) → Konfliktfall.
        let plan = PageAssemblyPlan(pages:
            PageAssemblyPlan(pages: [
                PageAssemblyItem(sourceURL: formA, sourcePageIndex: 0),
            ]).pages +
            PageAssemblyPlan(pages: [
                PageAssemblyItem(sourceURL: formB, sourcePageIndex: 0),
            ]).pages
        )

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })

        let doc = try #require(PDFDocument(url: out))
        var names: [String] = []
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)?.annotations ?? [] where a.type == "Widget" {
                names.append(a.fieldName ?? "?")
            }
        }
        #expect(names.count == 2)
        #expect(Set(names).count == names.count, "Feldnamen müssen unique sein: \(names)")
    }

    // MARK: Phase 15 – Attachments-Policy

    /// Handgebautes PDF mit EmbeddedFiles-Name-Tree (Policy-Fixture).
    private func attachmentFixture() throws -> URL {
        var data = Data()
        var offsets: [Int] = []
        func add(_ s: String) {
            offsets.append(data.count)
            data.append(Data(s.utf8))
        }
        func addObject(_ body: String) -> Int {
            add("\(offsets.count == 0 ? "" : "")") // noop, echte Offsets via add
            return offsets.count - 1 + 1
        }

        data.append(Data("%PDF-1.4\n".utf8))
        // Objekte manuell mit Offset-Tracking:
        func obj(_ id: Int, _ body: String) {
            offsets.append(data.count)
            data.append(Data("\(id) 0 obj\n\(body)\nendobj\n".utf8))
        }
        _ = offsets.count

        obj(1, "<</Type/Catalog/Pages 2 0 R/Names<</EmbeddedFiles 5 0 R>>>>")
        obj(2, "<</Type/Pages/Kids[3 0 R]/Count 1>>")
        obj(3, "<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>")
        obj(5, "<</Names[(anhang.txt) 6 0 R]>>")
        obj(6, "<</Type/EmbeddedFile/Subtype(text/plain)/Length 5>>\nstream\nhello\nendstream")

        let startxref = data.count
        data.append(Data("xref\n0 7\n".utf8))
        data.append(Data(String(format: "0000000000 65535 f \n").utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer<</Size 7/Root 1 0 R>>\nstartxref\n\(startxref)\n%%EOF\n".utf8))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    @Test func attachmentsAreDroppedByDocumentedPolicy() async throws {
        let url = try attachmentFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        // Fixture-Selbsttest: Bridge erkennt den Anhang.
        let openedBefore = try? PDFCoreDocument(path: url.path)
        let coreBefore = try #require(openedBefore)
        #expect(coreBefore.attachmentCount == 1)

        let doc = try #require(PDFDocument(url: url))
        let source = SourceDocument(url: url, pageCount: doc.pageCount)
        let plan = PageAssemblyPlan(pages: [
            PageItem(source: source, pageIndex: 0).assemblyItem,
        ])

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("p15-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })

        let openedAfter = try? PDFCoreDocument(path: out.path)
        let coreAfter = try #require(openedAfter)
        // Policy: Attachments werden beim Assembly NICHT übernommen (dokumentiert).
        #expect(coreAfter.attachmentCount == 0)
    }

    // MARK: Phase 16 – Metadata-Producer deterministisch

    @Test func producerMetadataIsStampedDeterministically() async throws {
        let urlA = try PDFFixtures.vectorTextPDF(lines: 3)
        defer { try? FileManager.default.removeItem(at: urlA) }

        var producers: [String?] = []
        for _ in 0..<2 {
            let source = SourceDocument(url: urlA, pageCount: 1)
            let plan = PageAssemblyPlan(pages: [
                PageItem(source: source, pageIndex: 0).assemblyItem,
            ])
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("p16-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: out) }
            try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })
            let doc = try #require(PDFDocument(url: out))
            let attrs = (doc.documentAttributes ?? [:]) as? [PDFDocumentAttribute: Any]
            producers.append(attrs?[.producerAttribute] as? String)
        }
        #expect(producers.allSatisfy { $0 == "PDFTools" })
        #expect(producers[0] == producers[1])
    }

    // MARK: Phase 17 – Originaldateien bleiben byte-identisch

    @Test func originalFilesRemainUntouchedAcrossOperations() async throws {
        func sha256(_ url: URL) -> String {
            let data = try! Data(contentsOf: url)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        let src = try PDFFixtures.vectorTextPDF(lines: 8)
        defer { try? FileManager.default.removeItem(at: src) }
        let before = sha256(src)

        // Assembly über die Quelle.
        let doc = try #require(PDFDocument(url: src))
        let source = SourceDocument(url: src, pageCount: doc.pageCount)
        let plan = PageAssemblyPlan(pages: [
            PageItem(source: source, pageIndex: 0).assemblyItem,
        ])
        let assembledOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("p17-a-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: assembledOut) }
        try await PageAssemblyService.assemble(plan: plan, to: assembledOut, progress: { _ in })

        // Kompression über dieselbe Quelle.
        let compressedOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("p17-c-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: compressedOut) }
        _ = try Compressor().compress(inputURL: src, mode: .smart)

        #expect(sha256(src) == before, "Original wurde verändert!")
    }
}
