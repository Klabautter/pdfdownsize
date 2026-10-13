import Testing
import PDFKit
@testable import PDFTools

/// PageSplitter-Logik (Review §65, Feature 2) + writeChunks-Integration.
@MainActor
struct SplitTests {

    // MARK: - Chunks

    @Test func perPageYieldsSingletons() {
        let (vm, _, _) = TestFactory.makeVM(docPageCounts: [3])
        let chunks = PageSplitter.chunks(from: vm.project.pages, mode: .perPage)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count == 1 })
    }

    @Test func everyNExactAndRemainder() {
        let (vm, _, _) = TestFactory.makeVM(docPageCounts: [7])
        let chunks = PageSplitter.chunks(from: vm.project.pages, mode: .everyN(3))
        #expect(chunks.map(\.count) == [3, 3, 1])
        #expect(chunks.flatMap(\.self).map(\.id) == ids0(vm))   // Reihenfolge erhalten
    }

    @Test func everyNInvalidSizeYieldsNothing() {
        let (vm, _, _) = TestFactory.makeVM(docPageCounts: [4])
        #expect(PageSplitter.chunks(from: vm.project.pages, mode: .everyN(0)).isEmpty)
    }

    @Test func selectionSplitsBeforeSelectedPages() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [6])
        // A B C D E F, Auswahl {C, E} → [A B] [C D] [E F]
        let chunks = PageSplitter.chunks(from: vm.project.pages,
                                         mode: .atSelection,
                                         selection: [ids[0][2], ids[0][4]])
        #expect(chunks.map(\.count) == [2, 2, 2])
    }

    @Test func selectionAtFirstPageProducesNoEmptyPart() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [4])
        let chunks = PageSplitter.chunks(from: vm.project.pages,
                                         mode: .atSelection,
                                         selection: [ids[0][0]])
        #expect(chunks.map(\.count) == [4])
    }

    @Test func selectionAtLastPageProducesFinalSingleton() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [4])
        let chunks = PageSplitter.chunks(from: vm.project.pages,
                                         mode: .atSelection,
                                         selection: [ids[0][3]])
        #expect(chunks.map(\.count) == [3, 1])
    }

    @Test func adjacentSelectionsDoNotCreateEmptyParts() {
        let (vm, ids, _) = TestFactory.makeVM(docPageCounts: [5])
        // {B, C} → nur ein Split vor B → [A] [B C D E]
        let chunks = PageSplitter.chunks(from: vm.project.pages,
                                         mode: .atSelection,
                                         selection: [ids[0][1], ids[0][2]])
        #expect(chunks.map(\.count) == [1, 4])
    }

    @Test func emptySelectionKeepsSingleChunk() {
        let (vm, _, _) = TestFactory.makeVM(docPageCounts: [4])
        let chunks = PageSplitter.chunks(from: vm.project.pages,
                                         mode: .atSelection,
                                         selection: [])
        #expect(chunks.count == 1)
    }

    @Test func fileNamePadsIndexByTotal() {
        #expect(PageSplitter.fileName(base: "Bericht", index: 3, total: 12)
                == "Bericht_Teil_03.pdf")
        #expect(PageSplitter.fileName(base: "Bericht", index: 1, total: 9)
                == "Bericht_Teil_1.pdf")
    }

    private func ids0(_ vm: MergeViewModel) -> [UUID] { vm.project.pages.map(\.id) }

    // MARK: - writeChunks Integration

    @Test func writeChunksWritesValidPDFsWithCorrectCounts() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 5)
        let chunks = PageSplitter.chunks(from: vm.project.pages, mode: .everyN(2))
        #expect(chunks.count == 3)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = try await vm.writeChunks(chunks, to: folder, baseName: "Import")
        #expect(urls.count == 3)

        let counts = urls.map { PDFDocument(url: $0)?.pageCount ?? -1 }
        #expect(counts == [2, 2, 1])
        #expect(urls.map(\.lastPathComponent) ==
                ["Import_Teil_1.pdf", "Import_Teil_2.pdf", "Import_Teil_3.pdf"])
        #expect(!vm.isProcessing)                       // Flag sauber zurückgesetzt
    }

    @Test func cancelledSplitRemovesWrittenParts() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 8)
        let chunks = PageSplitter.chunks(from: vm.project.pages, mode: .perPage)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let task = Task { try await vm.writeChunks(chunks, to: folder, baseName: "X") }
        task.cancel()

        do {
            let urls = try await task.value
            #expect(urls.isEmpty)
        } catch is CancellationError {
            // erwarteter Abbruch
        } catch {
            Issue.record("Unerwarteter Fehler: \(error)")
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true)
    }
}
