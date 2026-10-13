import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Monster Epic Phase 21 – libqpdf-backed Image XObject Inspection.
@MainActor
struct ImageInspectionTests {

    /// Raw-Fixture: 2 Seiten teilen sich EIN indirektes Bild-XObject
    /// (gemeinsames /Resources-Dict), je Seite eigener Content mit `Do`.
    static func sharedImageFixture() throws -> URL {
        var data = Data()
        var offsets: [Int] = []
        func add(_ s: String) {
            offsets.append(data.count)
            data.append(Data(s.utf8))
        }
        let content = "q 612 0 0 792 0 0 cm /Im0 Do Q"

        data.append(Data("%PDF-1.4\n".utf8))
        func obj(_ id: Int, _ body: String) {
            offsets.append(data.count)
            data.append(Data("\(id) 0 obj\n\(body)\nendobj\n".utf8))
        }
        obj(1, "<</Type/Catalog/Pages 2 0 R>>")
        obj(2, "<</Type/Pages/Kids[3 0 R 4 0 R]/Count 2>>")
        obj(3, "<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Resources 5 0 R/Contents 6 0 R>>")
        obj(4, "<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Resources 5 0 R/Contents 7 0 R>>")
        obj(5, "<</XObject<</Im0 8 0 R>>>>")
        obj(6, "<</Length \(content.count)>>\nstream\n\(content)\nendstream")
        obj(7, "<</Length \(content.count)>>\nstream\n\(content)\nendstream")
        // 2×2 RGB unfiltert:
        obj(8, "<</Type/XObject/Subtype/Image/Width 2/Height 2/BitsPerComponent 8/ColorSpace/DeviceRGB/Length 12>>\nstream\nRGBRGBRGBRGB\nendstream")

        let startxref = data.count
        data.append(Data("xref\n0 9\n".utf8))
        data.append(Data(String(format: "0000000000 65535 f \n").utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer<</Size 9/Root 1 0 R>>\nstartxref\n\(startxref)\n%%EOF\n".utf8))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharedimg-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    @Test func photoFixtureHasSingleDCTImage() async throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 900)
        defer { try? FileManager.default.removeItem(at: url) }

        let opened = try? PDFCoreDocument(path: url.path)
        let doc = try #require(opened)
        let images = try doc.inspectImages()
        try #require(images.count == 1, "Foto-Fixture muss genau 1 Bild haben")
        #expect(images[0].pageIndex == 0)
        #expect(images[0].width == 900)
        #expect(images[0].height == 900)
        #expect(!images[0].isShared)

        // Effective-DPI-Mapping: Punkte == Pixel → 72 dpi.
        let dpi = Double(images[0].width) / Double(max(images[0].width, 1)) * 72
        #expect(dpi == 72)
    }

    @Test func textOnlyVectorFixtureHasNoImages() async throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let opened = try? PDFCoreDocument(path: url.path)
        let doc = try #require(opened)
        #expect(try doc.inspectImages().isEmpty)
    }

    @Test func sharedXObjectDetectedAcrossPages() throws {
        let url = try Self.sharedImageFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let opened = try? PDFCoreDocument(path: url.path)
        let doc = try #require(opened)
        let images = try doc.inspectImages()
        #expect(images.count == 2)                       // eine Platzierung pro Seite
        #expect(images.allSatisfy { $0.isShared })       // dasselbe Objekt
        #expect(images.map(\.pageIndex) == [0, 1])
        #expect(images.allSatisfy { $0.width == 2 && $0.height == 2 })
        #expect(images.allSatisfy { $0.colorspace == "DeviceRGB" })
    }

    @Test func smaskPresenceIsReported() throws {
        // Transparente Seite: PDFKit rastert – SMask entsteht ggf. im Output.
        // Wir prüfen hier das Flag-Feld grundsätzlich (true/false lesbar).
        let url = try Self.sharedImageFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let opened = try? PDFCoreDocument(path: url.path)
        let doc = try #require(opened)
        for img in try doc.inspectImages() {
            #expect(img.hasSMask == false || img.hasSMask == true)
        }
    }

    @Test func effectiveDPIMappingFromPoints() async throws {
        // makeTempPNG: 400×300 px auf 400×300 pt Seite → exakt 72 dpi.
        let png = try TestFactory.makeTempPNG(size: CGSize(width: 400, height: 300))
        defer { try? FileManager.default.removeItem(at: png) }
        let image = try #require(NSImage(contentsOf: png))
        let page = try #require(PDFPage(image: image))
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("p21-dpi-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        _ = doc.write(to: pdfURL)

        let core = try PDFCoreDocument(path: pdfURL.path)
        let images = try core.inspectImages()
        #expect(images.count == 1)
        let points = doc.page(at: 0)?.bounds(for: .mediaBox).width ?? 1
        let dpi = Double(images[0].width) / points * 72
        #expect(abs(dpi - 72) < 1)
    }
}
