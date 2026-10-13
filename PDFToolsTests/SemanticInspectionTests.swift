import Testing
import PDFKit
@testable import PDFTools

/// Monster Epic Phase 7 – Gate: libqpdf-Inspection vs. Expected/PDFKit.
@MainActor
struct SemanticInspectionTests {

    private func makeFixture(_ name: String) throws -> URL {
        switch name {
        case "vector-text": return try PDFFixtures.vectorTextPDF(lines: 6)
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
        "vector-text", "mixed-sizes", "rotated",
        "annotated", "transparent", "outline-links", "form",
    ])
    func libqpdfSnapshotAgreesWithPDFKit(name: String) throws {
        let url = try makeFixture(name)
        defer { try? FileManager.default.removeItem(at: url) }

        let pdfkitSnap = try PDFSemanticSnapshot.capture(url)
        let qpdfSnap = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)

        let diffs = PDFSemanticSnapshot.backendDifferences(qpdfSnap, pdfkitSnap)
        #expect(diffs.isEmpty, "\(name): \(diffs.joined(separator: "; "))")
    }

    @Test func externalLinkURLIsExtracted() throws {
        let url = try PDFFixtures.annotatedPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let snap = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)
        #expect(snap.navigation.externalLinkURLs.contains("https://example.com"))
    }

    @Test func outlineLabelsAreInTreeOrder() throws {
        let url = try PDFFixtures.outlinedWithInternalLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let snap = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)
        #expect(snap.outlineLabels == ["Kapitel 1", "Kapitel 2"])
    }

    @Test func pageLabelAndAttachmentFlagsOnPlainFixtures() throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let snap = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)
        #expect(!snap.document.hasPageLabels)      // Fixture ohne Labels
        #expect(snap.attachments.count == 0)
        #expect(snap.navigation.namedDestinations.count == 0)
    }
}
