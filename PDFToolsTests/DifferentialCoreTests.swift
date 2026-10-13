import Testing
import PDFKit
@testable import PDFTools

/// Monster Epic Phase 6 – Differential: libqpdf vs. PDFKit auf allen Fixtures.
@MainActor
struct DifferentialCoreTests {

    private func makeFixture(_ name: String) throws -> URL {
        switch name {
        case "vector-text": return try PDFFixtures.vectorTextPDF(lines: 4)
        case "photo": return try PDFFixtures.photoHeavyPDF(pixels: 600)
        case "mixed-sizes": return try PDFFixtures.mixedSizesPDF()
        case "rotated": return try PDFFixtures.rotatedPDF()
        case "annotated": return try PDFFixtures.annotatedPDF()
        case "transparent": return try PDFFixtures.transparentPDF()
        case "outline-links": return try PDFFixtures.outlinedWithInternalLinkPDF()
        case "form": return try PDFFixtures.formWidgetsPDF()
        default: throw CocoaError(.fileNoSuchFile)
        }
    }

    @Test(arguments: [
        "vector-text", "photo", "mixed-sizes", "rotated",
        "annotated", "transparent", "outline-links", "form",
    ])
    func coresAgreeOnPageCount(name: String) throws {
        let url = try makeFixture(name)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = try #require(PDFDocument(url: url)?.pageCount)
        let libqpdf = try LibQPDFCore().inspect(url)
        let pdfkit = try PDFKitCore().inspect(url)

        #expect(libqpdf.pageCount == expected, "\(name)")
        #expect(pdfkit.pageCount == expected, "\(name)")
        #expect(libqpdf.engineVersion?.isEmpty == false)
    }

    @Test func validationReportIsValidForCleanFixture() throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try LibQPDFCore().validate(url, policy: .standard)
        #expect(report.isValid)
        #expect(report.checkPassed)
    }

    @Test func validationFailsForCorruptFile() throws {
        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).pdf")
        try Data("kein pdf".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }

        #expect(throws: (any Error).self) {
            _ = try LibQPDFCore().inspect(garbage)
        }
        #expect(throws: (any Error).self) {
            _ = try LibQPDFCore().validate(garbage, policy: .standard)
        }
    }
}
