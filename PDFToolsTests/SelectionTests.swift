import Foundation
import Testing
@testable import PDFTools

/// Acceptance Tests Selection (Review §8, Test A–D) + §46.
@MainActor
struct SelectionTests {

    // Test A – Single: Click 3 → nur Seite 3
    @Test func singleTapSelectsOnlyClickedPage() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [5])
        vm.tapSelect(p(vm, ids[0][2]))
        #expect(vm.selectedPageIDs == [ids[0][2]])
    }

    // Test B – Command: 2 + ⌘5 → beide ausgewählt
    @Test func commandClickAddsToSelection() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [6])
        vm.tapSelect(p(vm, ids[0][1]))
        vm.cmdToggle(p(vm, ids[0][4]))
        #expect(vm.selectedPageIDs == [ids[0][1], ids[0][4]])
    }

    // Test C – Command Toggle: 2+5 selektiert, ⌘5 → nur 2
    @Test func commandClickTogglesSelectedPageOff() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [6])
        vm.tapSelect(p(vm, ids[0][1]))
        vm.cmdToggle(p(vm, ids[0][4]))
        vm.cmdToggle(p(vm, ids[0][4]))
        #expect(vm.selectedPageIDs == [ids[0][1]])
    }

    // Test D – Shift: Click 2, ⇧Click 8 → 2…8
    @Test func shiftClickSelectsContiguousRange() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [9])
        vm.rangeSelect(to: p(vm, ids[0][7]), anchor: ids[0][1])
        #expect(vm.selectedPageIDs.count == 7)
        for i in 1...7 {
            #expect(vm.selectedPageIDs.contains(ids[0][i]))
        }
    }

    // Shift ohne Anchor fällt auf Einzelauswahl zurück.
    @Test func shiftWithoutAnchorFallsBackToSingle() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [5])
        vm.rangeSelect(to: p(vm, ids[0][3]), anchor: nil)
        #expect(vm.selectedPageIDs == [ids[0][3]])
    }

    // Reversed Range funktioniert ebenfalls (Anchor > Ziel).
    @Test func shiftRangeBackwardsWorks() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [9])
        vm.rangeSelect(to: p(vm, ids[0][1]), anchor: ids[0][7])
        #expect(vm.selectedPageIDs.count == 7)
    }

    // orderedSelection liefert Seiten in Dokument-Reihenfolge,
    // egal in welcher Reihenfolge selektiert wurde (§3, Multi-Drag-Grundlage).
    @Test func orderedSelectionPreservesDocumentOrder() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [6])
        vm.tapSelect(p(vm, ids[0][4]))
        vm.cmdToggle(p(vm, ids[0][1]))
        vm.cmdToggle(p(vm, ids[0][3]))
        #expect(vm.orderedSelection.map(\.id) == [ids[0][1], ids[0][3], ids[0][4]])
    }

    @Test func selectAllSelectsEverything() {
        let (vm, _, _) = TestFactory.makeVM(docPageCounts: [3, 4])
        vm.selectAll()
        #expect(vm.selectedPageIDs.count == 7)
    }

    @Test func selectAllOnEmptyProjectStaysEmpty() {
        let vm = MergeViewModel()
        vm.attachUndoManager(UndoManager())
        vm.selectAll()
        #expect(vm.selectedPageIDs.isEmpty)
    }

    // §29: Rechtsklick auf bereits selektierte Seite darf die Mehrfachauswahl nicht zerstören.
    @Test func contextSelectionKeepsExistingMultiSelection() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [6])
        vm.tapSelect(p(vm, ids[0][1]))
        vm.cmdToggle(p(vm, ids[0][2]))
        vm.ensureContextSelection(p(vm, ids[0][2]))
        #expect(vm.selectedPageIDs.count == 2)

        vm.ensureContextSelection(p(vm, ids[0][5]))
        #expect(vm.selectedPageIDs == [ids[0][5]])
    }
}
