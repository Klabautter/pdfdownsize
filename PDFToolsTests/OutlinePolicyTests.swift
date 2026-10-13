import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Monster Epic Phase 12 – Bookmarks / Outlines.
/// Policy (engine-agnostisch): genau eine Quelle vollständig → Top-Level-Outline
/// mit remappten Zielen neu aufgesetzt; mehrere Quellen oder Teil-Extract → Drop.
@MainActor
struct OutlinePolicyTests {

    private func outlineLabelsAndTargetIndices(_ url: URL) throws -> [(String, Int?)] {
        let doc = try #require(PDFDocument(url: url))
        guard let root = doc.outlineRoot else { return [] }
        var result: [(String, Int?)] = []
        func walk(_ node: PDFOutline) {
            for i in 0..<node.numberOfChildren {
                if let child = node.child(at: i) {
                    var idx: Int?
                    if let dest = child.destination, let target = dest.page {
                        idx = doc.index(for: target)
                    }
                    result.append((child.label ?? "?", idx))
                    walk(child)
                }
            }
        }
        walk(root)
        return result
    }

    @Test func fullSingleSourceReorderPreservesOutlinesWithRemappedTargets() async throws {
        let url = try PDFFixtures.outlinedWithInternalLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        // Vollständige Quelle, REVERSED: Kapitel 2 → Index 0, Kapitel 1 → Index 1.
        let plan = PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: url, sourcePageIndex: 1),
            PageAssemblyItem(sourceURL: url, sourcePageIndex: 0),
        ])

        do {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("p12-full-libqpdf-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: out) }
            try await PageAssemblyService.assemble(plan: plan, to: out,
                                              progress: { _ in })

            let labelsAndTargets = try outlineLabelsAndTargetIndices(out)
            #expect(labelsAndTargets.count == 2, "libqpdf")
            #expect(labelsAndTargets[0].0 == "Kapitel 1")
            #expect(labelsAndTargets[0].1 == 1)   // Kapitel 1 → Output-Index 1
            #expect(labelsAndTargets[1].0 == "Kapitel 2")
            #expect(labelsAndTargets[1].1 == 0)   // Kapitel 2 → Output-Index 0
        }
    }

    @Test func multiSourceMergeHasNoOutlines() async throws {
        let aURL = try PDFFixtures.outlinedWithInternalLinkPDF()
        let bURL = try PDFFixtures.vectorTextPDF(lines: 3)
        defer {
            try? FileManager.default.removeItem(at: aURL)
            try? FileManager.default.removeItem(at: bURL)
        }

        let plan = PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: aURL, sourcePageIndex: 0),
            PageAssemblyItem(sourceURL: aURL, sourcePageIndex: 1),
            PageAssemblyItem(sourceURL: bURL, sourcePageIndex: 0),
        ])

        do {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("p12-multi-libqpdf-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: out) }
            try await PageAssemblyService.assemble(plan: plan, to: out,
                                              progress: { _ in })
            #expect(try outlineLabelsAndTargetIndices(out).isEmpty,
                    "libqpdf: Policy verlangt Drop bei Multi-Source")
        }
    }

    @Test func partialExtractDropsOutlinesByPolicy() async throws {
        let url = try PDFFixtures.outlinedWithInternalLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        // Nur eine von zwei Seiten → nicht vollständig → Drop.
        let plan = PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: url, sourcePageIndex: 0),
        ])
        do {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("p12-partial-libqpdf-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: out) }
            try await PageAssemblyService.assemble(plan: plan, to: out,
                                              progress: { _ in })
            #expect(try outlineLabelsAndTargetIndices(out).count == 1,
                    "libqpdf: Entry-level-Policy – Kapitel 1 bleibt")
            #expect(try outlineLabelsAndTargetIndices(out).first?.0 == "Kapitel 1")
        }
    }
}
