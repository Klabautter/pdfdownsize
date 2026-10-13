import Testing
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import PDFTools

/// Epic Phase 11 – Converter Hardening.
@MainActor
struct ConverterHardeningTests {

    // MARK: EXIF-Orientierung

    /// JPEG mit EXIF-Orientierung 6 (90° CW): gespeichert 1200×900 quer,
    /// angezeigt/benötigt hochkant 900×1200. Der Import muss das auflösen.
    @Test func exifOrientationIsBakedIntoPage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exif6-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: 1200, pixelsHigh: 900,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemGreen.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: rep.size)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        #expect(dest != nil)
        guard let dest else { return }
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyPixelWidth: 1200,
            kCGImagePropertyPixelHeight: 900,
        ]
        CGImageDestinationAddImage(dest, rep.cgImage!, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        // pixelInfo meldet gespeicherte Maße + Orientation 6.
        let info = ImageImporter.pixelInfo(of: url)
        #expect(info?.width == 1200)
        #expect(info?.height == 900)
        #expect(info?.orientation == 6)

        // Die erzeugte PDF-Seite ist aufgerichtet: 900 breit × 1200 hoch.
        let pdfURL = try ImageImporter.singlePagePDF(from: url)
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let doc = try #require(PDFDocument(url: pdfURL))
        let bounds = doc.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
        #expect(abs(bounds.width - 900) < 1)
        #expect(abs(bounds.height - 1200) < 1)
    }

    // MARK: Transparenz über PDF → Bilder

    @Test func transparentPageExportsPngWithAlphaAndJpegOpaque() async throws {
        let input = try PDFFixtures.transparentPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let source = SourceDocument(url: input, pageCount: 1)
        var item = PageItem(source: source, pageIndex: 0)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-alpha-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // PNG behält Alpha-Kanal.
        item.rotation = 0
        let pngs = try await PageImageExporter.export(
            pages: [item],
            options: .init(format: .png, dpi: 72),
            to: folder) { _ in }
        #expect(pngs.count == 1)
        let pngSource = CGImageSourceCreateWithURL(pngs[0] as CFURL, nil)
        let pngProps = pngSource.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        } as? [String: Any]
        let hasAlpha = pngProps?["HasAlpha"] as? Bool ?? true
        #expect(hasAlpha)

        // JPEG wird mit weißem Grund gezeichnet und bleibt decodierbar.
        let jpegs = try await PageImageExporter.export(
            pages: [item],
            options: .init(format: .jpeg, dpi: 72, jpegQuality: 0.8),
            to: folder.appendingPathComponent("jpeg")) { _ in }
        #expect(jpegs.count == 1)
        let image = try #require(NSImage(contentsOf: jpegs[0]))
        #expect(image.size.width == 400)
    }

    // MARK: Cancellation räumt auf

    @Test func cancelledPdfToImagesExportLeavesNoFiles() async throws {
        let input = try PDFFixtures.textPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let source = SourceDocument(url: input, pageCount: 1)
        let items = (0..<4).map { _ in PageItem(source: source, pageIndex: 0) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let task = Task {
            try await PageImageExporter.export(pages: items,
                                               options: .init(format: .png, dpi: 150),
                                               to: folder) { _ in }
        }
        task.cancel()
        do {
            let urls = try await task.value
            #expect(urls.isEmpty)
        } catch is CancellationError { /* erwartet */ }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true)
    }
}
