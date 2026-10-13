import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Phase 27 – Operation Matrix: alle Operationen × alle Fixtures.
/// Jede Zelle validiert Output-Struktur + Semantik.
@MainActor
struct OperationMatrixTests {

    // MARK: Fixture-Fabrik

    enum FixtureKind: String, CaseIterable {
        case vectorText, photoHeavy, mixedSizes, rotated
        case annotated, transparent, outlineLinks, form, objectStreams, multiContent, mixedRotation

        func make() throws -> URL {
            switch self {
            case .vectorText: return try PDFFixtures.vectorTextPDF(lines: 8)
            case .photoHeavy: return try PDFFixtures.photoHeavyPDF(pixels: 800)
            case .mixedSizes: return try PDFFixtures.mixedSizesPDF()
            case .rotated: return try PDFFixtures.rotatedPDF()
            case .annotated: return try PDFFixtures.multiAnnotationPDF()
            case .transparent: return try PDFFixtures.transparentPDF()
            case .outlineLinks: return try PDFFixtures.outlinedWithInternalLinkPDF()
            case .form: return try PDFFixtures.formWidgetsPDF()
            case .objectStreams: return try PDFFixtures.objectStreamPDF()
            case .multiContent: return try PDFFixtures.multiContentTypePDF()
            case .mixedRotation: return try PDFFixtures.mixedRotationPDF()
            }
        }
    }

    private func tempOut(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("omx-\(tag)-\(UUID().uuidString).pdf")
    }

    // MARK: Compress Matrix

    @Test(arguments: FixtureKind.allCases)
    func compressPreservesStructure(kind: FixtureKind) async throws {
        let input = try kind.make()
        defer { try? FileManager.default.removeItem(at: input) }
        let expectedPages = try #require(PDFDocument(url: input)?.pageCount)

        do {
            let out = tempOut("cmp-\(kind.rawValue)-libqpdf")
            defer { try? FileManager.default.removeItem(at: out) }

            let result = try Compressor().compress(
                inputURL: input, mode: .smart)
            defer { try? FileManager.default.removeItem(at: result.outputURL) }

            // Seitenzahl erhalten
            let core = try #require(try? PDFCoreDocument(path: result.outputURL.path))
            #expect(core.pageCount == expectedPages,
                    "\(kind)/libqpdf: \(core.pageCount) ≠ \(expectedPages)")

            // Nie größer als Input
            #expect(result.outputBytes <= result.inputBytes + 1024,
                    "\(kind)/libqpdf: grew")

            // qpdf --check grün
            if let qp = Compressor.findQPDF() {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: qp)
                p.arguments = ["--check", result.outputURL.path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run(); p.waitUntilExit()
                #expect([0, 3].contains(p.terminationStatus),
                        "\(kind)/libqpdf: --check failed")
            }
        }
    }

    // MARK: Assembly Matrix (Merge/Extract/Split)

    @Test(arguments: FixtureKind.allCases)
    func assemblyRoundtrip(kind: FixtureKind) async throws {
        let url = try kind.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))
        let pageCount = doc.pageCount
        let source = SourceDocument(url: url, pageCount: pageCount)

        // Merge: alle Seiten in neuer Reihenfolge (reverse).
        let plan = PageAssemblyPlan(pages:
            (0..<pageCount).reversed().map {
                PageItem(source: source, pageIndex: $0).assemblyItem
            })

        // Split: zwei Teile (nur wenn ≥2 Seiten).
        let mid = max(1, pageCount / 2)
        var parts: [(String, PageAssemblyPlan)] = [
            ("merge", plan),
            // Extract: nur die Hälfte.
            ("extract", PageAssemblyPlan(pages: Array(plan.pages.prefix(max(1, pageCount / 2))))),
            ("splitA", PageAssemblyPlan(pages: Array(plan.pages[0..<mid]))),
        ]
        if pageCount >= 2 {
            parts.append(("splitB", PageAssemblyPlan(pages: Array(plan.pages[mid...]))))
        }

        for (label, p) in parts {
            let out = tempOut("asm-\(kind.rawValue)-\(label)")
            defer { try? FileManager.default.removeItem(at: out) }

            try await PageAssemblyService.assemble(plan: p, to: out,
                                              progress: { _ in })

            guard let result = PDFDocument(url: out) else {
                Issue.record("\(kind)/\(label): nicht lesbar")
                continue
            }
            #expect(p.pages.isEmpty || result.pageCount == p.pages.count,
                    "\(kind)/\(label): \(result.pageCount) ≠ \(p.pages.count)")

            // qpdf --check
            if let qp = Compressor.findQPDF() {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: qp)
                proc.arguments = ["--check", out.path]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try proc.run(); proc.waitUntilExit()
                #expect([0, 3].contains(proc.terminationStatus),
                        "\(kind)/\(label): --check failed")
            }
        }

        // libqpdf-Engine Parität für Merge:
        let qpdfOut = tempOut("asm-\(kind.rawValue)-qpdf")
        defer { try? FileManager.default.removeItem(at: qpdfOut) }
        try await PageAssemblyService.assemble(plan: plan, to: qpdfOut,
                                          progress: { _ in })
        let qpdfSnap = try PDFSemanticSnapshot.capture(qpdfOut, backend: .libQPDF)
        let pdfkitSnap = try PDFSemanticSnapshot.capture(qpdfOut)
        let diffs = PDFSemanticSnapshot.backendDifferences(qpdfSnap, pdfkitSnap)
        #expect(diffs.isEmpty, "\(kind): \(diffs.joined(separator: "; "))")
    }

    // MARK: Bildexport Matrix

    @Test(arguments: [FixtureKind.vectorText, .photoHeavy, .annotated])
    func imageExportProducesValidOutput(kind: FixtureKind) async throws {
        let url = try kind.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))
        let source = SourceDocument(url: url, pageCount: doc.pageCount)
        let items = (0..<doc.pageCount).map { PageItem(source: source, pageIndex: $0) }

        for format in [PageImageExporter.Format.png, .jpeg] {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("p27-img-\(kind.rawValue)-\(format)-\(UUID())",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            let urls = try await PageImageExporter.export(
                pages: items,
                options: .init(format: format, dpi: 72),
                to: folder) { _ in }

            #expect(urls.count == doc.pageCount, "\(kind)/\(format)")
            for u in urls {
                #expect(FileManager.default.fileExists(atPath: u.path),
                        "\(u.lastPathComponent) fehlt")
                #expect(Compressor.fileSize(of: u) > 0)
            }
        }
    }
}
