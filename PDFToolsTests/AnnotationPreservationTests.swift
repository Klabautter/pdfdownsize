import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Monster Epic Phase 10 – Annotations & External Links Preservation
/// über Reorder / Merge / Extract / Split – für BEIDE Engines.
@MainActor
struct AnnotationPreservationTests {

    // MARK: Helpers

    private func outputsFor(_ plan: PageAssemblyPlan,
                            tag: String) async throws -> (legacy: URL, qpdf: URL) {
        let legacyOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("p10-legacy-\(tag)-\(UUID().uuidString).pdf")
        let qpdfOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("p10-qpdf-\(tag)-\(UUID().uuidString).pdf")
        try await PageAssemblyService.assemble(plan: plan, to: legacyOut, progress: { _ in })
        try await PageAssemblyService.assemble(plan: plan, to: qpdfOut,
                                          progress: { _ in })
        return (legacyOut, qpdfOut)
    }

    /// Typen + URIs einer Ausgabe laut PDFKit (unabhängiger Verifizierer).
    private func annotationFacts(_ url: URL) throws -> (total: Int,
                                                        types: [String]) {
        let doc = try #require(PDFDocument(url: url))
        var types: [String] = []
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)?.annotations ?? [] {
                types.append(a.type ?? "Unknown")
            }
        }
        return (types.count, types)
    }

    private func assertCheckGreen(_ url: URL) throws {
        guard let qpdfPath = Compressor.findQPDF() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qpdfPath)
        p.arguments = ["--check", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect([0, 3].contains(p.terminationStatus),
                "qpdf --check failed: \(url.lastPathComponent)")
    }

    // MARK: A) Reorder einzelnes Dokument

    @Test func reorderKeepsAnnotationsAndExternalLink() async throws {
        let outlineURL = try PDFFixtures.outlinedWithInternalLinkPDF()
        let extURL = try PDFFixtures.annotatedPDF()
        defer {
            try? FileManager.default.removeItem(at: outlineURL)
            try? FileManager.default.removeItem(at: extURL)
        }
        let outlineDoc = try #require(PDFDocument(url: outlineURL))
        let srcOutline = SourceDocument(url: outlineURL, pageCount: outlineDoc.pageCount)
        let srcExt = SourceDocument(url: extURL, pageCount: 1)

        // Reorder: [extern annotiert, Kapitel 2, Kapitel 1]
        let plan = PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: srcExt.url, sourcePageIndex: 0, rotation: 0),
            PageAssemblyItem(sourceURL: srcOutline.url, sourcePageIndex: 1, rotation: 0),
            PageAssemblyItem(sourceURL: srcOutline.url, sourcePageIndex: 0, rotation: 0),
        ])

        let outs = try await outputsFor(plan, tag: "reorder")
        defer {
            try? FileManager.default.removeItem(at: outs.legacy)
            try? FileManager.default.removeItem(at: outs.qpdf)
        }

        for url in [outs.legacy, outs.qpdf] {
            let facts = try annotationFacts(url)
            #expect(facts.total == 3, "\(url.lastPathComponent): \(facts.types)")
            #expect(facts.types.filter { $0 == "Link" }.count == 2)   // intern + extern
            #expect(facts.types.contains("Highlight"))

            let snap = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)
            #expect(snap.annotationTotals.links == 2)
            #expect(snap.navigation.externalLinkURLs.contains("https://example.com"))
            try assertCheckGreen(url)
        }
    }

    // MARK: B) Multi-Document-Merge

    @Test func multiDocMergeKeepsAnnotationsFormsLinks() async throws {
        let annotatedURL = try PDFFixtures.annotatedPDF()
        let formURL = try PDFFixtures.formWidgetsPDF()
        let textURL = try PDFFixtures.vectorTextPDF(lines: 3)
        defer {
            try? FileManager.default.removeItem(at: annotatedURL)
            try? FileManager.default.removeItem(at: formURL)
            try? FileManager.default.removeItem(at: textURL)
        }
        let annPages = try #require(PDFDocument(url: annotatedURL)).pageCount
        let formPages = try #require(PDFDocument(url: formURL)).pageCount
        let textPages = try #require(PDFDocument(url: textURL)).pageCount

        let plan = PageAssemblyPlan(pages:
            (0..<textPages).map { PageAssemblyItem(sourceURL: textURL, sourcePageIndex: $0) }
            + (0..<annPages).map { PageAssemblyItem(sourceURL: annotatedURL, sourcePageIndex: $0) }
            + (0..<formPages).map { PageAssemblyItem(sourceURL: formURL, sourcePageIndex: $0) })

        let outs = try await outputsFor(plan, tag: "merge")
        defer {
            try? FileManager.default.removeItem(at: outs.legacy)
            try? FileManager.default.removeItem(at: outs.qpdf)
        }

        for url in [outs.legacy, outs.qpdf] {
            let facts = try annotationFacts(url)
            #expect(facts.total == 4)                       // 2 Annos + 2 Widgets
            #expect(facts.types.filter { $0 == "Widget" }.count == 2)
            #expect(facts.types.filter { $0 == "Link" }.count == 1)
            #expect(facts.types.contains("Highlight"))

            let snap = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)
            #expect(snap.form.fields.count == 2)
            #expect(snap.navigation.externalLinkURLs.contains("https://example.com"))
            try assertCheckGreen(url)
        }
    }

    // MARK: C) Extract (Teilauswahl)

    @Test func extractPreservesAnnotationsOfSelectedPages() async throws {
        let annotatedURL = try PDFFixtures.annotatedPDF()
        let formURL = try PDFFixtures.formWidgetsPDF()
        let textURL = try PDFFixtures.vectorTextPDF(lines: 3)
        defer {
            try? FileManager.default.removeItem(at: annotatedURL)
            try? FileManager.default.removeItem(at: formURL)
            try? FileManager.default.removeItem(at: textURL)
        }

        // Extraktion = Sub-Plan: nur annotierte + Textseite.
        let extractPlan = PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: annotatedURL, sourcePageIndex: 0),
            PageAssemblyItem(sourceURL: textURL, sourcePageIndex: 0),
        ])

        let outs = try await outputsFor(extractPlan, tag: "extract")
        defer {
            try? FileManager.default.removeItem(at: outs.legacy)
            try? FileManager.default.removeItem(at: outs.qpdf)
        }

        for url in [outs.legacy, outs.qpdf] {
            try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath:
                "/tmp/opencode/p10_extract_\(url.lastPathComponent)"))
            let facts = try annotationFacts(url)
            #expect(facts.total == 2)
            #expect(facts.types.filter { $0 == "Link" }.count == 1)
            #expect(facts.types.contains("Highlight"))

            let snap = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)
            #expect(snap.pageCount == 2)
            #expect(snap.navigation.externalLinkURLs.contains("https://example.com"))
            #expect(snap.form.fields.count == 0)   // nicht gewählte Formularseite fehlt
            try assertCheckGreen(url)
        }
    }

    // MARK: D) Split (zwei Teil-Pläne)

    @Test func splitPartsKeepTheirRespectiveAnnotations() async throws {
        let annotatedURL = try PDFFixtures.annotatedPDF()
        let formURL = try PDFFixtures.formWidgetsPDF()
        defer {
            try? FileManager.default.removeItem(at: annotatedURL)
            try? FileManager.default.removeItem(at: formURL)
        }

        let parts: [(plan: PageAssemblyPlan, links: Int, widgets: Int, total: Int)] = [
            (PageAssemblyPlan(pages: [
                PageAssemblyItem(sourceURL: annotatedURL, sourcePageIndex: 0),
            ]), 1, 0, 2),
            (PageAssemblyPlan(pages: [
                PageAssemblyItem(sourceURL: formURL, sourcePageIndex: 0),
            ]), 0, 1, 1),
        ]

        for (index, part) in parts.enumerated() {
            let outs = try await outputsFor(part.plan, tag: "split-\(index)")
            defer {
                try? FileManager.default.removeItem(at: outs.legacy)
                try? FileManager.default.removeItem(at: outs.qpdf)
            }
            for url in [outs.legacy, outs.qpdf] {
                let facts = try annotationFacts(url)
                #expect(facts.total == part.total)
                #expect(facts.types.filter { $0 == "Link" }.count == part.links)
                #expect(facts.types.filter { $0 == "Widget" }.count == part.widgets)

                try assertCheckGreen(url)
            }
        }
    }
}
