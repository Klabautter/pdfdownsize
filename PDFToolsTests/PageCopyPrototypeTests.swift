import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Retains the failure contract that an invalid source page cannot create output.
@MainActor
struct PageCopyPrototypeTests {

    @Test func invalidPageIndexThrowsInsteadOfWriting() async throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let plan = PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: url, sourcePageIndex: 7, rotation: 0),
        ])
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("p9-invalid-\(UUID().uuidString).pdf")

        await #expect(throws: PDFCoreAssemblerError.invalidPageIndex) {
            try await PageAssemblyService.assemble(plan: plan, to: out,
                                              progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}
