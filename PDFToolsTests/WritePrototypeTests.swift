import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Monster Epic Phase 22 – Compression Write Prototype.
/// Ein Bild-XObject wird über libqpdf durch neue JPEG-Daten ersetzt.
@MainActor
struct WritePrototypeTests {

    private func makeCombined() throws -> (plan: PageAssemblyPlan,
                                           cleanup: [URL]) {
        let textURL = try PDFFixtures.vectorTextPDF(lines: 6)
        let photoURL = try PDFFixtures.photoHeavyPDF(pixels: 700)
        let textDoc = try #require(PDFDocument(url: textURL))
        let photoDoc = try #require(PDFDocument(url: photoURL))
        let srcText = SourceDocument(url: textURL, pageCount: textDoc.pageCount)
        let srcPhoto = SourceDocument(url: photoURL, pageCount: photoDoc.pageCount)

        let plan = PageAssemblyPlan(pages: [
            PageItem(source: srcText, pageIndex: 0).assemblyItem,
            PageItem(source: srcPhoto, pageIndex: 0).assemblyItem,
        ])
        return (plan, [textURL, photoURL])
    }

    private func page1(of url: URL) -> PDFPage? {
        PDFDocument(url: url)?.page(at: 1)
    }

    private func renderJPEG(page: PDFPage, pixels: Int, quality: CGFloat) throws -> Data {
        let bounds = page.bounds(for: .mediaBox)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        page.thumbnail(of: bounds.size, for: .mediaBox)
            .draw(in: NSRect(origin: .zero, size: bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(
            using: .jpeg, properties: [.compressionFactor: quality]))
    }

    @Test func replacedImageKeepsDocumentSemanticsAndShrinks() async throws {
        let (plan, cleanup) = try makeCombined()
        defer { for u in cleanup { try? FileManager.default.removeItem(at: u) } }

        // Output mit LEGACY-Engine bauen; danach ersetzt der Prototype das Bild.
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("p22-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })

        let beforeSize = Compressor.fileSize(of: out)

        // Bild über seine OBJEKTIDENTITÄT bestimmen – nicht über den
        // Resource-Namen (Masterplan Finding 13).
        let coreBeforeReplace = try #require(try? PDFCoreDocument(path: out.path))
        let imgsBefore = try coreBeforeReplace.inspectImages()
        let photoEntry = imgsBefore.first(where: { $0.pageIndex == 1 })
        let imageObjectID = try #require(photoEntry?.objectID,
                                         "kein Bild auf der Foto-Seite gefunden")

        // Neues, kleineres JPEG erzeugen (Render der Foto-Seite @350 px).
        guard let photoPage = page1(of: out) else {
            Issue.record("Foto-Seite fehlt im Output")
            return
        }
        let newJpeg = try renderJPEG(page: photoPage, pixels: 350, quality: 0.5)

        // REPLACE über die Bridge.
        let core = try PDFCoreDocument(path: out.path)
        try core.replaceImage(objectID: imageObjectID, jpegData: newJpeg,
                              newWidth: -1, newHeight: -1, grayscale: false)
        try core.save(to: out)

        // --- Gate-22-Kriterien ---
        let reopened = try #require(PDFDocument(url: out))          // 1) öffnet
        #expect(reopened.pageCount == 2)                            // Seitenzahl

        guard let qpdfPath = Compressor.findQPDF() else { return }  // 2) --check
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qpdfPath)
        p.arguments = ["--check", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect([0, 3].contains(p.terminationStatus))

        let textNow = (0..<reopened.pageCount)                      // 3) Text
            .compactMap { reopened.page(at: $0)?.string }.joined()
        #expect(textNow.contains("Zeile"))

        let coreAfter = try #require(try? PDFCoreDocument(path: out.path))
        let imgsAfter = try coreAfter.inspectImages()               // 4) Bild korrekt
        #expect(imgsAfter.count == 1)
        #expect(imgsAfter[0].filters == ["DCTDecode"])
        #expect(imgsAfter[0].width == imgsBefore.first?.width)
        #expect(imgsAfter[0].height == imgsBefore.first?.height)

        try? FileManager.default.copyItem(at: out, to: URL(fileURLWithPath:
            "/tmp/opencode/p22_debug.pdf"))

        let renderPage = reopened.page(at: 1)!                      // 5) Render
        let render = renderPage.thumbnail(of: CGSize(width: 200, height: 200),
                                          for: .mediaBox)
        let cg = render.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #expect(cg != nil && cg!.width > 50)

        let afterSize = Compressor.fileSize(of: out)                // 6) geschrumpft
        #expect(afterSize < beforeSize,
                "before=\(beforeSize) after=\(afterSize)")
    }
}
