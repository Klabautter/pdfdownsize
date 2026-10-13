import Foundation
import Testing
@testable import PDFTools

/// Move-Engine-Tests: Buttons + Drag-Move inkl. Multi-Drag-Edge-Cases (Review §43–44).
@MainActor
struct MoveTests {

    @Test func moveSinglePageLeft() {
        let (vm, _, _) = TestFactory.makeVM(docPageCounts: [4])
        vm.tapSelect(page(in: vm, at: 2))
        vm.moveSelectionLeft()
        #expect(TestFactory.order(vm) == ["pdftools-src-0.pdf:0",
                                          "pdftools-src-0.pdf:2",
                                          "pdftools-src-0.pdf:1",
                                          "pdftools-src-0.pdf:3"])
    }

    @Test func moveSinglePageRight() {
        let (vm, _, _) = TestFactory.makeVM(docPageCounts: [4])
        vm.tapSelect(page(in: vm, at: 1))
        vm.moveSelectionRight()
        #expect(TestFactory.order(vm) == ["pdftools-src-0.pdf:0",
                                          "pdftools-src-0.pdf:2",
                                          "pdftools-src-0.pdf:1",
                                          "pdftools-src-0.pdf:3"])
    }

    @Test func boundaryPagesCannotMoveFurther() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [3])
        vm.tapSelect(p(vm, ids[0][0]))
        #expect(!vm.canMoveLeft())
        vm.tapSelect(p(vm, ids[0][2]))
        #expect(!vm.canMoveRight())
    }

    @Test func contiguousGroupMovesAsBlock() {
        let (vm, _, _) = TestFactory.makeVM(docPageCounts: [5])
        // A B [C D] E → nach links → A C D B E
        vm.tapSelect(page(in: vm, at: 2))
        vm.cmdToggle(page(in: vm, at: 3))
        #expect(vm.canMoveLeft())
        vm.moveSelectionLeft()
        #expect(TestFactory.order(vm) == ["pdftools-src-0.pdf:0",
                                          "pdftools-src-0.pdf:2",
                                          "pdftools-src-0.pdf:3",
                                          "pdftools-src-0.pdf:1",
                                          "pdftools-src-0.pdf:4"])
    }

    @Test func groupAtFrontCannotMoveLeft() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [5])
        vm.tapSelect(p(vm, ids[0][0]))
        vm.cmdToggle(p(vm, ids[0][1]))
        #expect(!vm.canMoveLeft())
        vm.moveSelectionLeft()
        #expect(vm.project.pages.map(\.id) == ids[0]) // unverändert
    }

    @Test func groupAtEndCannotMoveRight() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [5])
        vm.tapSelect(p(vm, ids[0][3]))
        vm.cmdToggle(p(vm, ids[0][4]))
        #expect(!vm.canMoveRight())
    }

    // Single-Drag: C an den Anfang ziehen → C A B D …
    @Test func dragSinglePageToFront() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [4])
        vm.movePages([ids[0][2]], to: 0)
        #expect(TestFactory.order(vm) == ["pdftools-src-0.pdf:2",
                                          "pdftools-src-0.pdf:0",
                                          "pdftools-src-0.pdf:1",
                                          "pdftools-src-0.pdf:3"])
    }

    // §43 – Gruppe vor sich selbst gezogen: keine Änderung, kein Undo-Eintrag.
    @Test func dropInsideOwnGroupIsNoOp() {
        let (vm, ids, undo) = TestFactory.makeVM(docPageCounts: [5])
        vm.movePages([ids[0][1], ids[0][2]], to: 2)   // Drop „zwischen B und C“
        #expect(vm.project.pages.map(\.id) == ids[0])
        #expect(!undo.canUndo)
    }

    // §43 – Gruppe direkt hinter sich gezogen: keine Änderung.
    @Test func dropDirectlyBehindOwnGroupIsNoOp() {
        let (vm, ids, undo) = TestFactory.makeVM(docPageCounts: [5])
        vm.movePages([ids[0][1], ids[0][2]], to: 3)   // Drop „nach C“
        #expect(vm.project.pages.map(\.id) == ids[0])
        #expect(!undo.canUndo)
    }

    // §43 – Drop vor dem eigenen Gruppenkopf: ebenfalls No-op.
    @Test func dropBeforeOwnGroupHeadIsNoOp() {
        let (vm, ids, undo) = TestFactory.makeVM(docPageCounts: [5])
        vm.movePages([ids[0][2], ids[0][3]], to: 2)   // Drop „vor C“
        #expect(vm.project.pages.map(\.id) == ids[0])
        #expect(!undo.canUndo)
    }

    // §43 – Non-contiguous Multi-Drag ans Ende:
    // [A] B [C] D [E] → B D A C E, relative Reihenfolge erhalten.
    @Test func nonContiguousGroupKeepsRelativeOrder() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [5])
        vm.tapSelect(p(vm, ids[0][0]))
        vm.cmdToggle(p(vm, ids[0][2]))
        vm.cmdToggle(p(vm, ids[0][4]))
        vm.movePages(vm.orderedSelection.map(\.id), to: 5)
        #expect(TestFactory.order(vm) == ["pdftools-src-0.pdf:1",
                                          "pdftools-src-0.pdf:3",
                                          "pdftools-src-0.pdf:0",
                                          "pdftools-src-0.pdf:2",
                                          "pdftools-src-0.pdf:4"])
    }

    // Multi-Drag mitten hinein: Zielindex zählt nur nichtgezogene Seiten.
    @Test func contiguousGroupInsertMiddle() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [6])
        // A [B C] D E F → Gruppe zwischen E und F (Ziel 5) → A D E B C F
        vm.movePages([ids[0][1], ids[0][2]], to: 5)
        #expect(TestFactory.order(vm) == ["pdftools-src-0.pdf:0",
                                          "pdftools-src-0.pdf:3",
                                          "pdftools-src-0.pdf:4",
                                          "pdftools-src-0.pdf:1",
                                          "pdftools-src-0.pdf:2",
                                          "pdftools-src-0.pdf:5"])
    }

    @Test func moveWithUnknownIDsDoesNothing() {
        let (vm, ids, undo) = TestFactory.makeVM(docPageCounts: [3])
        vm.movePages([UUID()], to: 0)
        #expect(vm.project.pages.map(\.id) == ids[0])
        #expect(!undo.canUndo)
    }

    // §9 – Ziehen einer selektierten Seite darf die Selection nicht reduzieren;
    // die View übergibt genau `orderedSelection` – Selection bleibt intakt.
    @Test func multiDragViaOrderedSelectionMovesWholeGroup() {
        let (vm, _, _) = TestFactory.makeVM(docPageCounts: [6])
        vm.tapSelect(page(in: vm, at: 1))
        vm.cmdToggle(page(in: vm, at: 3))
        let dragged = vm.orderedSelection.map(\.id)   // startDrag nutzt diese Gruppe
        vm.movePages(dragged, to: 0)
        #expect(vm.selectedPageIDs.count == 2)        // Selection bleibt erhalten
        #expect(TestFactory.order(vm) == ["pdftools-src-0.pdf:1",
                                          "pdftools-src-0.pdf:3",
                                          "pdftools-src-0.pdf:0",
                                          "pdftools-src-0.pdf:2",
                                          "pdftools-src-0.pdf:4",
                                          "pdftools-src-0.pdf:5"])
    }
}
