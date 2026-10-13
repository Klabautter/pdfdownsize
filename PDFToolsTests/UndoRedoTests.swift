import Foundation
import Testing
@testable import PDFTools

/// Undo/Redo inkl. Import-Baseline-Sync (Review P1 „Variante A", §55).
@MainActor
struct UndoRedoTests {

    @Test func moveUndoRedoRoundtrip() {
        let (vm, ids, undo) = TestFactory.makeVM(docPageCounts: [4])
        let before = vm.project.pages.map(\.id)

        vm.movePages([ids[0][3]], to: 0)
        #expect(vm.project.pages.map(\.id) != before)
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Seite verschieben")

        undo.undo()
        #expect(vm.project.pages.map(\.id) == before)

        undo.redo()
        #expect(vm.project.pages.first?.id == ids[0][3])
    }

    @Test func deleteUndoRestoresPagesAndDocuments() {
        let (vm, ids, undo) = TestFactory.makeVM(docPageCounts: [2, 2])
        vm.tapSelect(p(vm, ids[0][0]))
        vm.cmdToggle(p(vm, ids[0][1]))
        vm.deleteSelectedPages()
        #expect(vm.project.documents.count == 1)

        undo.undo()
        #expect(vm.project.pages.count == 4)
        #expect(vm.project.documents.count == 2)
    }

    // Import-Undo entfernt Dokumente auch aus der Baseline – sonst belebt
    // „Änderungen zurücksetzen" den entfernten Import wieder (P1, Variante A).
    @Test func importUndoAlsoRevertsBaseline() async throws {
        let (vm, undo) = try await EditTests.makeImportedVM(pageCountPerFile: 2)   // A
        let urlB = try TestFactory.makeTempPDF(name: "import-B-\(UUID().uuidString)",
                                               pageCount: 1)

        vm.selectAll()
        vm.rotateSelectedPages(by: 90)          // echte Bearbeitung nach Import A
        vm.importDocuments([urlB])              // B
        try await TestFactory.waitFor { vm.project.pages.count == 3 }
        #expect(vm.hasChanges)

        undo.undo()                             // ⌘Z = Import B zurück
        #expect(vm.project.pages.count == 2)
        #expect(vm.project.documents.count == 1)
        #expect(TestFactory.rotations(vm) == [90, 90])   // Rotation bliebt erhalten

        // Kern-Assertion: Baseline ist mit zurückgesetzt → Reset darf B nicht
        // wiederbeleben und die Rotation nicht verschwinden lassen.
        #expect(vm.hasChanges)                  // nur noch die Rotation zählt
        vm.resetChanges()
        #expect(vm.project.pages.count == 2)
        #expect(TestFactory.rotations(vm) == [0, 0])
    }

    @Test func importUndoRedoRoundtripFromEmptyProject() async throws {
        let (vm, undo) = try await EditTests.makeImportedVM(pageCountPerFile: 2)

        undo.undo()
        #expect(vm.project.pages.isEmpty)
        #expect(vm.project.documents.isEmpty)
        #expect(!vm.hasChanges)                 // Baseline ebenfalls leer

        undo.redo()
        #expect(vm.project.pages.count == 2)
        #expect(!vm.hasChanges)
    }

    @Test func multipleMovesCollapseIntoDistinctUndoSteps() {
        let (vm, ids, undo) = TestFactory.makeVM(docPageCounts: [5])
        vm.movePages([ids[0][4]], to: 0)
        vm.movePages([ids[0][4]], to: 2)
        #expect(undo.undoActionName == "Seite verschieben")

        undo.undo()
        #expect(vm.project.pages.first?.id == ids[0][4])   // zweiter Move zurück
        undo.undo()
        #expect(vm.project.pages.last?.id == ids[0][4])    // erster Move zurück
    }

    // No-op-Edits dürfen kein Undo erzeugen (§44).
    @Test func noOpEditsDoNotEnterUndoHistory() {
        let (vm, _, undo) = TestFactory.makeVM(docPageCounts: [3])
        vm.rotateSelectedPages(by: 360)         // Normalisierung → keine Änderung
        #expect(!undo.canUndo)
    }
}
