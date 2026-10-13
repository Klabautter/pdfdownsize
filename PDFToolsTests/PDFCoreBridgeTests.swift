import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Monster Epic Phase 5 – Gate: libqpdf über die C-Bridge aus Swift.
@MainActor
struct PDFCoreBridgeTests {

    @Test func versionIsReadable() {
        #expect(!PDFCoreDocument.version.isEmpty)
        #expect(PDFCoreDocument.version.contains("12."))
    }

    @Test func pageMatchesPDFKitOnFixtures() async throws {
        for name in ["vector-text", "mixed-sizes", "rotated", "outline-links"] {
            let url: URL
            switch name {
            case "vector-text": url = try PDFFixtures.vectorTextPDF(lines: 6)
            case "mixed-sizes": url = try PDFFixtures.mixedSizesPDF()
            case "rotated": url = try PDFFixtures.rotatedPDF()
            default: url = try PDFFixtures.outlinedWithInternalLinkPDF()
            }
            defer { try? FileManager.default.removeItem(at: url) }

            let pdfkitCount = try #require(PDFDocument(url: url)?.pageCount)
            let core = try PDFCoreDocument(path: url.path)
            #expect(core.pageCount == pdfkitCount, "\(name)")
            #expect(throws: Never.self) { try core.check() }
        }
    }

    @Test func malformedPDFReturnsErrorInsteadOfCrash() throws {
        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).pdf")
        try Data("das ist definitiv kein pdf \u{1F984}".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }

        #expect(throws: PDFCoreError.self) {
            _ = try PDFCoreDocument(path: garbage.path)
        }
    }

    @Test func missingFileReturnsOpenError() {
        #expect(throws: PDFCoreError.self) {
            _ = try PDFCoreDocument(path: "/tmp/pdftools-existiert-nicht-\(UUID().uuidString).pdf")
        }
    }

}
