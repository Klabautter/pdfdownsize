import Testing
import PDFKit
@testable import PDFTools

/// Monster Epic Phase 8 – Gate: neutrales Assembly-Modell.
@MainActor
struct PageAssemblyPlanTests {

    @Test func pageItemMapsToNeutralPlanItem() {
        let doc = SourceDocument(url: URL(fileURLWithPath: "/tmp/a.pdf"), pageCount: 3)
        var item = PageItem(source: doc, pageIndex: 2)
        item.rotation = 450                     // wird normalisiert → 90

        let planItem = item.assemblyItem
        #expect(planItem.sourceURL == item.sourceURL)
        #expect(planItem.sourcePageIndex == 2)
        #expect(planItem.rotation == 90)        // Normalisierung im Initializer
    }

    @Test func planIsBackendAgnostic() {
        // Kein PDFKit-/AppKit-Typ darf im Modell landen – strukturell sichergestellt
        // durch Codable-Roundtrip (nur Value-Typen).
        let plan = PageAssemblyPlan(pages: [
            .init(sourceURL: URL(fileURLWithPath: "/tmp/x.pdf"),
                  sourcePageIndex: 0, rotation: 270),
            .init(sourceURL: URL(fileURLWithPath: "/tmp/y.pdf"),
                  sourcePageIndex: 4, rotation: 45),
        ])

        let data = try? JSONEncoder().encode(plan)
        let decoded = data.flatMap { try? JSONDecoder().decode(PageAssemblyPlan.self, from: $0) }
        #expect(decoded == plan)
        #expect(decoded?.pages[1].rotation == 45)
    }

    @Test func assembleViaPlanMatchesLegacyItemsPath() async throws {
        // Beide Einstiege müssen byte-funktional dasselbe Ergebnis liefern.
        let urlA = try PDFFixtures.vectorTextPDF(lines: 4)
        let urlB = try PDFFixtures.rotatedPDF()
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let docB = try #require(PDFDocument(url: urlB))
        let sourceA = SourceDocument(url: urlA, pageCount: 1)
        let sourceB = SourceDocument(url: urlB, pageCount: docB.pageCount)

        var items: [PageItem] = []
        items.append(PageItem(source: sourceA, pageIndex: 0))
        items.append(PageItem(source: sourceB, pageIndex: 1))
        items[1].rotation = 180

        // Legacy-Pfad (Items):
        let legacyOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-legacy-\(UUID().uuidString).pdf")
        // Plan-Pfad:
        let planOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-neutral-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: legacyOut)
            try? FileManager.default.removeItem(at: planOut)
        }

        try await PageAssemblyService.assemble(pages: items, to: legacyOut) { _ in }
        try await PageAssemblyService.assemble(plan: items.assemblyPlan, to: planOut) { _ in }

        let a = try #require(PDFDocument(url: legacyOut))
        let b = try #require(PDFDocument(url: planOut))
        #expect(a.pageCount == b.pageCount)
        for i in 0..<a.pageCount {
            #expect(a.page(at: i)?.rotation == b.page(at: i)?.rotation)
            #expect(abs(a.page(at: i)!.bounds(for: .mediaBox).width
                        - b.page(at: i)!.bounds(for: .mediaBox).width) < 0.5)
        }
    }

    @Test func organizerStillWorksEndToEndWithPlan() async throws {
        // Organizer-Workflow über die öffentliche API bleibt intakt (Gate 8).
        let vm = MergeViewModel()
        vm.attachUndoManager(UndoManager())
        let url = try TestFactory.makeTempPDF(pageCount: 3)

        vm.importDocuments([url])
        try await TestFactory.waitFor { vm.project.pages.count == 3 && !vm.hasChanges }

        vm.movePages([vm.project.pages[2].id], to: 0)
        vm.mergeAndPrepare()
        try await TestFactory.waitFor { vm.outcome != nil && !vm.isProcessing }

        let outcome = try #require(vm.outcome)
        #expect(outcome.pageCount == 3)
        try? FileManager.default.removeItem(at: outcome.url)
    }
}
