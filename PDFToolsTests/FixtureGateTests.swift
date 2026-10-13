import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Monster Epic Phase 2 – Gate 2: Fixtures reproduzierbar, erwartungstreu, qpdf-grün.
@MainActor
struct FixtureGateTests {

    private func makeFixture(_ name: String) throws -> URL {
        switch name {
        case "vector-text": return try PDFFixtures.vectorTextPDF(lines: 15)
        case "photo": return try PDFFixtures.photoHeavyPDF(pixels: 700)
        case "mixed-sizes": return try PDFFixtures.mixedSizesPDF()
        case "rotated": return try PDFFixtures.rotatedPDF()
        case "annotated": return try PDFFixtures.annotatedPDF()
        case "transparent": return try PDFFixtures.transparentPDF()
        case "outline-links": return try PDFFixtures.outlinedWithInternalLinkPDF()
        case "form": return try PDFFixtures.formWidgetsPDF()
        case "object-streams": return try PDFFixtures.objectStreamPDF()
        default: throw CocoaError(.fileNoSuchFile)
        }
    }

    @Test(arguments: [
        "vector-text", "photo", "mixed-sizes", "rotated", "annotated",
        "transparent", "outline-links", "form", "object-streams",
    ])
    func fixtureMatchesManifestExpectations(name: String) async throws {
        let manifest = PDFFixtures.manifest().first { $0.name == name }
        let expectation = try #require(manifest, "Manifest-Eintrag fehlt für \(name)")

        let url = try makeFixture(name)
        defer { try? FileManager.default.removeItem(at: url) }

        // PDFKit öffnet
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount == expectation.expectedPageCount)

        // qpdf --check grün
        if let qpdf = Compressor.findQPDF() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: qpdf)
            p.arguments = ["--check", url.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect([0, 3].contains(p.terminationStatus),
                    "qpdf --check failed für \(name)")
        }

        // Erwartete Semantik
        var textChars = 0
        var annos = 0
        var links = 0
        var widgets = 0
        for i in 0..<doc.pageCount {
            let page = doc.page(at: i)!
            textChars += page.string?.count ?? 0
            annos += page.annotations.count
            links += page.annotations.filter { $0.type == "Link" }.count
            widgets += page.annotations.filter { $0.type == "Widget" }.count
        }
        if expectation.expectsText { #expect(textChars > 0, "\(name): erwartet Text") }
        #expect(annos >= expectation.minAnnotations)
        #expect(links >= expectation.minLinks)
        #expect(widgets >= expectation.expectsFormWidgets)

        if expectation.expectsOutline {
            let snapshot = PDFSemanticSnapshot.capture(doc)
            #expect(!snapshot.outlineLabels.isEmpty, "\(name): erwartet Outline")
        }
    }
}

/// Monster Epic Phase 3 – Gate 3: Snapshot & Diff.
@MainActor
struct SemanticSnapshotTests {

    @Test func identicalFileProducesEmptyDiff() throws {
        let url = try PDFFixtures.outlinedWithInternalLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try PDFSemanticSnapshot.capture(url)
        let after = try PDFSemanticSnapshot.capture(url)
        #expect(PDFSemanticSnapshot.compare(before, after).isEmpty)
    }

    @Test func differentDocumentsProduceClearDiagnostics() throws {
        let a = try PDFFixtures.vectorTextPDF(lines: 5)
        let b = try PDFFixtures.mixedSizesPDF()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        let snapA = try PDFSemanticSnapshot.capture(a)
        let snapB = try PDFSemanticSnapshot.capture(b)
        let diffs = PDFSemanticSnapshot.compare(snapA, snapB)
        #expect(diffs.contains { $0.contains("Seitenzahl") })
        #expect(diffs.allSatisfy { !$0.isEmpty })
    }

    @Test func outlineCaptureFindsLabels() throws {
        let url = try PDFFixtures.outlinedWithInternalLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = try PDFSemanticSnapshot.capture(url)
        #expect(snap.outlineLabels.contains("Kapitel 1"))
        #expect(snap.outlineLabels.contains("Kapitel 2"))
        #expect(snap.pages[0].linkCount == 1)
    }

    @Test func formWidgetsCaptured() throws {
        let url = try PDFFixtures.formWidgetsPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = try PDFSemanticSnapshot.capture(url)
        // PDFKit vergibt beim Schreiben eigene Feldnamen – wir prüfen Anzahl + Nichtleere.
        #expect(snap.formFieldNames.count == 2)
        #expect(snap.formFieldNames.allSatisfy { !$0.isEmpty })
    }
}

