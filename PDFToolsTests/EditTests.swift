import Foundation
import Testing
@testable import PDFTools

/// Rotate / Delete / Reset (Review §31–§32, §44).
@MainActor
struct EditTests {

    @Test func rotateNormalizesAfterFullCircle() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [3])
        vm.tapSelect(p(vm, ids[0][1]))
        for _ in 0..<4 { vm.rotateSelectedPages(by: 90) }
        #expect(TestFactory.rotations(vm) == [0, 0, 0])
    }

    @Test func rotateNegativeStaysNormalized() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [2])
        vm.tapSelect(p(vm, ids[0][0]))
        vm.rotateSelectedPages(by: 270)
        vm.rotateSelectedPages(by: -90)
        #expect(TestFactory.rotations(vm) == [180, 0])
    }

    @Test func rotateAppliesOnlyToSelection() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [3])
        vm.tapSelect(p(vm, ids[0][1]))
        vm.rotateSelectedPages(by: 90)
        #expect(TestFactory.rotations(vm) == [0, 90, 0])
    }

    @Test func rotateWithoutSelectionIsNoOp() {
        let (vm, _, undo) = TestFactory.makeVM(docPageCounts: [2])
        vm.rotateSelectedPages(by: 90)
        #expect(TestFactory.rotations(vm) == [0, 0])
        #expect(!undo.canUndo)
    }

    @Test func deleteRemovesPagesSelectionAndEmptyDocuments() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [2, 3])
        vm.tapSelect(p(vm, ids[0][0]))
        vm.cmdToggle(p(vm, ids[0][1]))          // gesamtes Dokument 0
        vm.deleteSelectedPages()
        #expect(vm.project.pages.count == 3)
        #expect(vm.project.documents.count == 1)
        #expect(vm.selectedPageIDs.isEmpty)
        #expect(vm.project.documents[0].fileName == "pdftools-src-1.pdf")
    }

    @Test func deletePartialKeepsDocument() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [3])
        vm.tapSelect(p(vm, ids[0][1]))
        vm.deleteSelectedPages()
        #expect(vm.project.pages.count == 2)
        #expect(vm.project.documents.count == 1)
    }

    // „Alle entfernen" (2026-10-13): Arbeitsbereich leer, ohne offene
    // Änderungen, Auswahl weg – und per Widerrufen vollständig zurück.
    @Test func removeAllEmptiesWorkspaceAndIsUndoable() async throws {
        let (vm, undo) = try await Self.makeImportedVM(pageCountPerFile: 3)
        vm.selectAll()
        vm.rotateSelectedPages(by: 90)

        vm.removeAllDocuments()
        #expect(vm.project.documents.isEmpty)
        #expect(vm.project.pages.isEmpty)
        #expect(vm.selectedPageIDs.isEmpty)
        #expect(!vm.hasChanges, "leerer Arbeitsbereich meldet offene Änderungen")

        undo.undo()
        #expect(vm.project.totalPages == 3)
        #expect(vm.project.pages.allSatisfy { $0.rotation == 90 })
    }

    // Reset stellt den Import-Zustand wieder her und ist selbst rückgängig machbar (§31).
    @Test func resetRestoresBaselineAndIsUndoable() async throws {
        let (vm, undo) = try await Self.makeImportedVM(pageCountPerFile: 3)

        vm.selectAll()
        vm.rotateSelectedPages(by: 90)
        vm.tapSelect(page(in: vm, at: 0))
        vm.deleteSelectedPages()
        #expect(vm.hasChanges)

        vm.resetChanges()
        #expect(vm.project.totalPages == 3)
        #expect(!vm.hasChanges)

        undo.undo()                       // Reset rückgängig → bearbeiteter Zustand
        #expect(vm.project.totalPages == 2)
        undo.redo()                       // erneut Reset
        #expect(vm.project.totalPages == 3)
    }

    // MARK: - Helper

    /// VM mit echtem Import über `importDocuments` – nur so wird die Baseline gesetzt.
    static func makeImportedVM(fileCount: Int = 1,
                               pageCountPerFile: Int = 3) async throws -> (MergeViewModel, UndoManager) {
        let vm = MergeViewModel()
        let undo = UndoManager()
        vm.attachUndoManager(undo)

        var urls: [URL] = []
        for i in 0..<fileCount {
            urls.append(try TestFactory.makeTempPDF(name: "import-\(i)-\(UUID().uuidString)",
                                                    pageCount: pageCountPerFile))
        }
        vm.importDocuments(urls)
        try await TestFactory.waitFor {
            vm.project.pages.count == fileCount * pageCountPerFile
                && !vm.hasChanges          // Baseline synchron
        }
        return (vm, undo)
    }
}
