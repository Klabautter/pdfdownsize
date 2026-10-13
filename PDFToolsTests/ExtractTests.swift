import Testing
import PDFKit
@testable import PDFTools

/// Extract Pages (Review §65, Feature 1): Selektion → eigene PDF,
/// Reihenfolge/Rotationen erhalten, Projekt bleibt unangetastet.
@MainActor
struct ExtractTests {

    @Test func extractWritesOnlySelectedPagesInOrder() async throws {
        let (vm, undo) = try await EditTests.makeImportedVM(fileCount: 2, pageCountPerFile: 3)
        // Seiten: A0 A1 A2 B0 B1 B2 → Auswahl A1 + B0, nur A1 um 90° gedreht
        vm.tapSelect(page(in: vm, at: 1))
        vm.rotateSelectedPages(by: 90)          // trifft nur A1
        vm.cmdToggle(page(in: vm, at: 3))       // B0 ungedreht dazunehmen

        let undoNameBefore = undo.undoActionName
        vm.extractSelectedPages()
        try await TestFactory.waitFor { vm.outcome != nil && !vm.isProcessing }
        try await TestFactory.waitFor { vm.errorMessage == nil }

        let outcome = try #require(vm.outcome)
        #expect(outcome.pageCount == 2)
        #expect(outcome.kind == .extracted)
        // #5/#6: kein Größenvergleich beim Extract, eigener Default-Dateiname.
        #expect(!outcome.kind.showsSizeComparison)
        #expect(outcome.kind.defaultFileName == "Extrahierte Seiten.pdf")
        #expect(FileManager.default.fileExists(atPath: outcome.url.path))

        let result = try #require(PDFDocument(url: outcome.url))
        #expect(result.pageCount == 2)
        #expect(result.page(at: 0)?.rotation == 90)     // A1 zuerst, mit Rotation
        #expect(result.page(at: 1)?.rotation == 0)      // B0 danach, ohne Rotation

        // Projekt unangetastet, Selection erhalten, kein neuer Undo-Eintrag.
        #expect(vm.project.pages.count == 6)
        #expect(vm.selectedPageIDs.count == 2)
        #expect(undo.undoActionName == undoNameBefore)

        try? FileManager.default.removeItem(at: outcome.url)
    }

    @Test func extractWithEmptySelectionDoesNothing() async throws {
        let (vm, undo) = try await EditTests.makeImportedVM(pageCountPerFile: 2)

        vm.extractSelectedPages()
        try await Task.sleep(for: .milliseconds(50))    // ggf. laufende Arbeit abwarten
        #expect(vm.outcome == nil)
        #expect(!vm.isProcessing)
        #expect(!undo.canUndo || undo.undoActionName == "Dokumente hinzufügen")
    }

    @Test func extractReplacesPreviousUnsavedOutcome() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 2)

        vm.selectAll()
        vm.extractSelectedPages()
        try await TestFactory.waitFor { vm.outcome != nil && !vm.isProcessing }
        let first = try #require(vm.outcome)

        vm.tapSelect(page(in: vm, at: 0))
        vm.extractSelectedPages()
        try await TestFactory.waitFor { vm.outcome?.url != first.url && !vm.isProcessing }
        let second = try #require(vm.outcome)

        #expect(second.pageCount == 1)
        // Alte ungespeicherte Ausgabe wurde aufgeräumt (kein Temp-Leak).
        #expect(!FileManager.default.fileExists(atPath: first.url.path))

        try? FileManager.default.removeItem(at: second.url)
    }

    @Test func extractSinglePageWorks() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 2)
        vm.tapSelect(page(in: vm, at: 1))

        vm.extractSelectedPages()
        try await TestFactory.waitFor { vm.outcome != nil && !vm.isProcessing }

        let outcome = try #require(vm.outcome)
        #expect(outcome.pageCount == 1)
        try? FileManager.default.removeItem(at: outcome.url)
    }
}
