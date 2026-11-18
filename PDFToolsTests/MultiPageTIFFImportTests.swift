import Testing
import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import PDFTools

/// Masterplan E5: Mehrseitige TIFFs.
///
/// Befund: `ImageImporter` las nur Bild 0 – aus einem dreiseitigen Fax-TIFF
/// wurde eine Seite, zwei Seiten fehlten ohne Hinweis.
///
/// Fehlermöglichkeiten: (1) Seiten fehlen; (2) Reihenfolge oder Maße
/// vertauscht; (3) ein animiertes GIF wird zu vielen Seiten.
@MainActor
@Suite(.serialized) struct MultiPageTIFFImportTests {

    static let sizes = [(600, 800), (800, 600), (500, 500)]

    static func frame(_ width: Int, _ height: Int, gray: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func write(_ type: UTType, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e5-\(UUID().uuidString).\(ext)")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, sizes.count, nil))
        for (k, size) in sizes.enumerated() {
            CGImageDestinationAddImage(dest, frame(size.0, size.1, gray: 0.2 + 0.3 * CGFloat(k)), nil)
        }
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func dreiseitigesTIFFWirdDreiSeiten() throws {
        let tiff = try Self.write(.tiff, ext: "tiff")
        defer { try? FileManager.default.removeItem(at: tiff) }
        let imported = try ImageImporter.pdf(from: tiff)
        defer { try? FileManager.default.removeItem(at: imported.url) }
        #expect(imported.pageCount == 3)
        let doc = try #require(PDFDocument(url: imported.url))
        #expect(doc.pageCount == 3)
        for (k, size) in Self.sizes.enumerated() {
            let box = doc.page(at: k)?.bounds(for: .mediaBox) ?? .zero
            #expect(abs(box.width - CGFloat(size.0)) < 1 && abs(box.height - CGFloat(size.1)) < 1,
                    "Seite \(k + 1): \(box.size)")
        }
    }

    @Test func animiertesGIFBleibtEineSeite() throws {
        let gif = try Self.write(.gif, ext: "gif")
        defer { try? FileManager.default.removeItem(at: gif) }
        let imported = try ImageImporter.pdf(from: gif)
        defer { try? FileManager.default.removeItem(at: imported.url) }
        #expect(imported.pageCount == 1)
    }

    @Test func organisierenUebernimmtAlleSeiten() async throws {
        let tiff = try Self.write(.tiff, ext: "tiff")
        defer { try? FileManager.default.removeItem(at: tiff) }
        let vm = MergeViewModel()
        vm.attachUndoManager(UndoManager())
        vm.importDocuments([tiff])
        for _ in 0..<500 where vm.project.pages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(vm.project.pages.count == 3)
        #expect(vm.project.documents.first?.pageCount == 3)
    }
}
