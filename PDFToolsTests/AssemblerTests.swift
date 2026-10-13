import Foundation
import Testing
import PDFKit
@testable import PDFTools

/// Assembler-Korrektheit (Seitenzahl, Reihenfolge, Rotation, Progress)
/// und Merge-End-to-End inkl. Validierung (Review §59).
@MainActor
struct AssemblerTests {

    private func item(_ doc: SourceDocument, _ pageIndex: Int,
                      rotation: Int = 0) -> PageItem {
        var item = PageItem(source: doc, pageIndex: pageIndex)
        item.rotation = RotationNormalizer.normalized(rotation)
        return item
    }

    @Test func assemblesAllPagesInOrderWithRotation() async throws {
        let urlA = try TestFactory.makeTempPDF(name: "asm-a-\(UUID().uuidString)", pageCount: 2)
        let urlB = try TestFactory.makeTempPDF(name: "asm-b-\(UUID().uuidString)", pageCount: 2)
        let a = SourceDocument(url: urlA, pageCount: 2)
        let b = SourceDocument(url: urlB, pageCount: 2)

        let pages: [PageItem] = [
            item(a, 0, rotation: 90),
            item(b, 0),
            item(a, 1, rotation: 180),
            item(b, 1, rotation: 270),
        ]

        var progressValues: [Double] = []
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-out-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        try await PageAssemblyService.assemble(pages: pages, to: out) { progressValues.append($0) }

        #expect(progressValues.count == 4)
        #expect((progressValues.last ?? 0) == 1.0)

        let result = try #require(PDFDocument(url: out))
        #expect(result.pageCount == 4)
        #expect(result.page(at: 0)?.rotation == 90)
        #expect(result.page(at: 1)?.rotation == 0)
        #expect(result.page(at: 2)?.rotation == 180)
        #expect(result.page(at: 3)?.rotation == 270)
    }

    @Test func missingSourceThrowsAndLeavesNoOutput() async throws {
        let ghost = URL(fileURLWithPath: "/tmp/pdftools-does-not-exist-\(UUID().uuidString).pdf")
        let doc = SourceDocument(url: ghost, pageCount: 1)
        let pages = [item(doc, 0)]
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("asm-fail-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        do {
            _ = try await PageAssemblyService.assemble(pages: pages, to: out) { _ in }
            Issue.record("assemble hätte fehlschlagen müssen")
        } catch let error as MergeError {
            guard case .missingSource(let name) = error else {
                Issue.record("Falscher Fehler: \(error)")
                return
            }
            #expect(name == ghost.lastPathComponent)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    // End-to-End: importieren → PDF erstellen → Outcome mit korrekter Seitenzahl.
    @Test func mergeAndPrepareProducesValidOutcome() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 3)

        vm.mergeAndPrepare()
        try await TestFactory.waitFor { vm.outcome != nil && !vm.isProcessing }
        try await TestFactory.waitFor { vm.errorMessage == nil }

        let outcome = try #require(vm.outcome)
        #expect(outcome.pageCount == 3)
        #expect(outcome.outputBytes > 0)
        #expect(FileManager.default.fileExists(atPath: outcome.url.path))
        #expect(vm.savedURL == nil)          // Result-State „noch nicht gespeichert“ (§35)

        try? FileManager.default.removeItem(at: outcome.url)
    }
}
