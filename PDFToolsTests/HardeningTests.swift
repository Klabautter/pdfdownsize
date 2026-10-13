import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Epic Phase 3 – zentrale Validierung mit Workflow-Policies.
@MainActor
struct PDFValidatorTests {

    @Test func validOutputPassesCompressionPolicy() async throws {
        let input = try PDFFixtures.textPDF()
        defer { try? FileManager.default.removeItem(at: input) }

        let result = try Compressor().compress(inputURL: input, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let report = PDFValidator.validate(outputURL: result.outputURL,
                                           referenceURL: input,
                                           policy: .compression)
        #expect(report.isValid, "Failures: \(report.failures)")
    }

    @Test func corruptedOutputFailsOpenable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).pdf")
        try Data("%PDF-1.7 broken".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = PDFValidator.validate(outputURL: url, policy: .assembly)
        #expect(!report.isValid)
    }

    @Test func wrongPageCountFails() throws {
        let url = try PDFFixtures.textPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        var policy = PDFValidator.Policy.assembly
        policy.expectedPageCount = 5
        let report = PDFValidator.validate(outputURL: url, policy: policy)
        #expect(report.failures.contains { $0.contains("Seitenzahl") })
    }

    @Test func pdfKitClampsImplausibleRotationOnLoad() throws {
        // Plattformverhalten dokumentieren: /Rotate 45 wird von PDFKit beim
        // Laden auf ein 90°-Vielfaches geklemmt – der Validator-Rotationscheck
        // ist damit reiner Defensiv-Layer für nicht-PDFKit-Pfade.
        var data = Data()
        var offsets: [Int] = []
        func append(_ s: String) {
            offsets.append(data.count)
            data.append(Data(s.utf8))
        }
        data.append(Data("%PDF-1.4\n".utf8))
        append("1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n")
        append("2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n")
        // /Resources ist Pflichteintrag – fehlt er, meldet qpdf eine Warnung
        // und die (seit Befund 13 geschärfte) Assembly-Politik lässt die
        // Strukturprüfung scheitern. Der Test soll die Rotationsklemmung
        // prüfen, nicht an einem zweiten Defekt hängenbleiben (Befund 4).
        append("3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]"
            + "/Resources<<>>/Rotate 45>>endobj\n")

        let startxref = data.count
        data.append(Data("xref\n0 4\n".utf8))
        data.append(Data(String(format: "0000000000 65535 f \n").utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer<</Size 4/Root 1 0 R>>\nstartxref\n\(startxref)\n%%EOF\n".utf8))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rot45-\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try #require(PDFDocument(url: url))
        #expect([0, 90, 180, 270].contains(loaded.page(at: 0)?.rotation ?? -1))

        let report = PDFValidator.validate(outputURL: url, policy: .assembly)
        #expect(report.isValid)
    }

    @Test func textLossIsDetected() throws {
        // Referenz mit ECHTEM Vektor-Text vs. Output nur-Bild → Textverlust muss auffallen.
        let reference = try PDFFixtures.vectorTextPDF(lines: 20)

        let imageOnly = PDFDocument()
        imageOnly.insert(PDFFixtures.solidColorPage(.systemTeal), at: 0)
        let output = try PDFFixtures.write(imageOnly, name: "image-only")
        defer {
            try? FileManager.default.removeItem(at: reference)
            try? FileManager.default.removeItem(at: output)
        }

        #expect(!(referenceText(reference).isEmpty))   // Fixture-Selbsttest
        let report = PDFValidator.validate(outputURL: output,
                                           referenceURL: reference,
                                           policy: .compression)
        #expect(report.failures.contains { $0.contains("Textverlust") })
    }

    private func referenceText(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined()
    }

    @Test func annotationLossIsHardFailureForCompression() throws {
        let annotated = try PDFFixtures.annotatedPDF()

        // Output = gleiche Seite OHNE Annotationen (simulierter Verlust).
        let sourceDoc = try #require(PDFDocument(url: annotated))
        let page = sourceDoc.page(at: 0)!
        for annotation in page.annotations {
            page.removeAnnotation(annotation)
        }
        let stripped = try PDFFixtures.write(sourceDoc, name: "stripped")
        defer {
            try? FileManager.default.removeItem(at: annotated)
            try? FileManager.default.removeItem(at: stripped)
        }

        let report = PDFValidator.validate(outputURL: stripped,
                                           referenceURL: annotated,
                                           policy: .compression)
        #expect(report.failures.contains { $0.contains("Annotationen") })
    }

    @Test func signatureMarkerProducesWarningNotFailure() throws {
        let signed = try PDFFixtures.fakeSignaturePDF()
        defer { try? FileManager.default.removeItem(at: signed) }

        let report = PDFValidator.validate(outputURL: signed, policy: .assembly)
        #expect(report.isValid)
        #expect(report.signatureDetected)
        #expect(report.warnings.contains { $0.contains("Signatur") })
    }
}

/// Epic Phase 4 + 6 – Assembly-Kompatibilität auf Fixture-Basis.
@MainActor
@Suite(.serialized)
struct AssemblyCompatibilityTests {

    private func item(_ doc: SourceDocument, _ page: Int, rotation: Int = 0) -> PageItem {
        var i = PageItem(source: doc, pageIndex: page)
        i.rotation = rotation
        return i
    }

    @Test func mixedSizesAndRotationsSurviveAssembly() async throws {
        let mixedURL = try PDFFixtures.mixedSizesPDF()
        let rotatedURL = try PDFFixtures.rotatedPDF()
        defer {
            try? FileManager.default.removeItem(at: mixedURL)
            try? FileManager.default.removeItem(at: rotatedURL)
        }

        let mixedDoc = try #require(PDFDocument(url: mixedURL))
        let rotatedDoc = try #require(PDFDocument(url: rotatedURL))
        let mixedSource = SourceDocument(url: mixedURL, pageCount: mixedDoc.pageCount)
        let rotatedSource = SourceDocument(url: rotatedURL, pageCount: rotatedDoc.pageCount)

        let pages = [
            item(mixedSource, 0),                       // A4 portrait
            item(rotatedSource, 1),                     // 90° rotiert
            item(mixedSource, 1),                       // Letter landscape
            item(rotatedSource, 2, rotation: 90),       // 180° + Nutzer-90° → 270°
        ]

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-compat-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        try await PageAssemblyService.assemble(pages: pages, to: out) { _ in }

        let report = PDFValidator.validate(outputURL: out, policy: .assembly)
        #expect(report.isValid, "Failures: \(report.failures)")

        let result = try #require(PDFDocument(url: out))
        #expect(result.pageCount == 4)
        let b0 = result.page(at: 0)!.bounds(for: .mediaBox)
        #expect(abs(b0.width - 595) < 1 && abs(b0.height - 842) < 1)
        let b2 = result.page(at: 2)!.bounds(for: .mediaBox)
        #expect(abs(b2.width - 792) < 1 && abs(b2.height - 612) < 1)
        #expect(result.page(at: 1)?.rotation == 90)
        #expect(result.page(at: 3)?.rotation == 270)
    }

    @Test func annotationsAndLinksSurvivePageCopy() async throws {
        let url = try PDFFixtures.annotatedPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try #require(PDFDocument(url: url))
        let source = SourceDocument(url: url, pageCount: 1)
        let pages = [item(source, 0)]

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-anno-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(pages: pages, to: out) { _ in }

        let result = try #require(PDFDocument(url: out))
        let annos = result.page(at: 0)?.annotations ?? []
        #expect(annos.count == 2)                                   // Highlight + Link
        #expect(annos.filter { $0.type == "Link" }.count == 1)
    }

    @Test func repeatedSameSourceAssemblesCorrectly() async throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))
        let source = SourceDocument(url: url, pageCount: doc.pageCount)

        let pages = (0..<3).map { _ in item(source, 0) }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-repeat-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(pages: pages, to: out) { _ in }

        #expect(PDFDocument(url: out)?.pageCount == 3)
    }

    /// Bekannte Limitierung (dokumentiert in RELEASE_READINESS.md):
    /// Dokument-Level-Strukturen wie Outlines überleben den page.copy-Assembly-Pfad nicht.
    @Test func outlinesDoNotSurvivePageCopy() throws {
        let sourceDoc = PDFDocument()
        sourceDoc.insert(PDFFixtures.textPage("Kapitel 1"), at: 0)
        let root = PDFOutline()
        let child = PDFOutline()
        child.label = "Kapitel 1"
        if let page = sourceDoc.page(at: 0) {
            child.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 0))
        }
        root.insertChild(child, at: 0)
        sourceDoc.outlineRoot = root
        #expect(sourceDoc.outlineRoot != nil)

        // Assembly-Pfad: Seite kopieren → Outline bleibt im Quelldokument zurück.
        let target = PDFDocument()
        if let page = sourceDoc.page(at: 0) {
            target.insert(page.copy() as! PDFPage, at: 0)
        }
        #expect(target.outlineRoot == nil)
    }

    /// Phase 8 (Memory/Robustness): 100-Seiten-Assembly als Rauchtest.
    @Test func hundredPageAssemblySmoke() async throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))
        let source = SourceDocument(url: url, pageCount: doc.pageCount)

        var pages: [PageItem] = []
        for i in 0..<100 {
            pages.append(item(source, i % max(1, doc.pageCount)))
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-100-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(pages: pages, to: out) { _ in }

        let report = PDFValidator.validate(outputURL: out, policy: .assembly)
        #expect(report.isValid)
        #expect(PDFDocument(url: out)?.pageCount == 100)
    }
}
