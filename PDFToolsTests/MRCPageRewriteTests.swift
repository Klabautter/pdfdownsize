import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import PDFTools

/// Phase V2-7 (Masterplan §13.7) – Seitenrekonstruktion und Erhalt der
/// nicht-raster Semantik.
///
/// Die Seite nach dem MRC-Rewrite muss außerhalb des Raster-Draws
/// identisch sein: OCR-Text-Operatoren, Annotationen, MediaBox – und der
/// zweite Lauf darf die MRC-Ausgabe nicht erneut MRC-fähig sehen.
@Suite(.timeLimit(.minutes(10))) struct MRCPageRewriteTests {

    static func mrcOptions() -> CompressionOptions {
        var options = CompressionOptions.make(mode: .smart, customConfig: nil,
                                              stripMetadata: false, linearize: false)
        // Diese Tests pruefen die MRC-Mechanik (Rekonstruktion, Seiten-QA),
        // nicht die Bedarfsregel: Die synthetische Scan-Seite ist nach der
        // JPEG-Leiter klein, MRC muss hier trotzdem laufen.
        options.mrcProvisionBudget.provisionIfCandidateExceedsBytes = 0
        return options
    }

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mrc-\(label)-\(UUID().uuidString).pdf")
    }

    /// Die Vorprüfung in der Provision muss dieselbe Grenze ziehen wie die
    /// Rekonstruktion: Sonst fiele ein lieferbarer Kandidat weg.
    @Test func ebenenGrenzeStimmtMitRekonstruktionUeberein() throws {
        // N26: Farbmasken sind eigene Ebenen und zählen mit.
        #expect(MRCPageRewriter.fitsLayerLimit(photoRegionCount: 62, colorMaskCount: 0))
        #expect(!MRCPageRewriter.fitsLayerLimit(photoRegionCount: 63, colorMaskCount: 0))
        #expect(MRCPageRewriter.fitsLayerLimit(photoRegionCount: 59, colorMaskCount: 3))
        #expect(!MRCPageRewriter.fitsLayerLimit(photoRegionCount: 60, colorMaskCount: 3))

        let input = try PDFFixtures.mrcScanPagePDF(withOCR: false, withLink: false)
        defer { try? FileManager.default.removeItem(at: input) }
        let document = try PDFCoreDocument(path: input.path)
        let resources = try document.imageResources()
        let resource = try #require(resources.first)
        let placement = try #require(resource.placements.first)
        let name = placement.resourceName.hasPrefix("/")
            ? String(placement.resourceName.dropFirst()) : placement.resourceName

        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let black = try #require(context.makeImage())
        let jpeg = try #require(ImageResampler.encodeJPEG(black, quality: 0.8))
        let maskBits = try #require(BilevelBuffer(
            width: 8, height: 8, data: Data(repeating: 0, count: 8)))
        let maskData = try #require(BilevelCodec.encodeG4(maskBits))
        func layers(photos: Int, colorMasks: Int = 0) -> [PDFCoreDocument.MRCLayer] {
            let photo = PDFCoreDocument.MRCLayer(
                kind: .jpeg(components: 1), width: 8, height: 8, data: jpeg,
                rect: CGRect(x: 0, y: 0, width: 8, height: 8))
            let background = PDFCoreDocument.MRCLayer(
                kind: .jpeg(components: 1), width: 8, height: 8, data: jpeg, rect: nil)
            let mask = PDFCoreDocument.MRCLayer(
                kind: .ccittG4Mask, width: 8, height: 8, data: maskData, rect: nil)
            var colorMask = mask
            colorMask.fill = (red: 0.8, green: 0.1, blue: 0.1)
            return [background] + Array(repeating: photo, count: photos) + [mask]
                + Array(repeating: colorMask, count: colorMasks)
        }
        func replace(photos: Int, colorMasks: Int = 0) throws {
            try document.replacePageImageDrawWithLayers(
                pageIndex: placement.pageIndex, imageObjectID: resource.objectID,
                resourceName: name, layers: layers(photos: photos, colorMasks: colorMasks))
        }
        #expect(throws: (any Error).self) { try replace(photos: 63) }
        #expect(throws: (any Error).self) { try replace(photos: 60, colorMasks: 3) }
        try replace(photos: 62)
    }

    @Test func rekonstruktionErhaeltOCRTextAnnotationUndBoxen() throws {
        let input = try PDFFixtures.mrcScanPagePDF(withOCR: true, withLink: true)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = Self.tempURL("rewrite")
        defer { try? FileManager.default.removeItem(at: output) }

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: output, options: Self.mrcOptions())

        // Der MRC-Kandidat muss im Plan sichtbar sein und ausgeführt werden.
        let mrcAction = outcome.plan.actions.first { action in
            if case .mrc = action { return true }
            return false
        }
        guard case .mrc(_, let descriptor, let original, let expected) =
                try #require(mrcAction, "Erwartete MRC-Aktion im Plan") else {
            return
        }
        #expect(original > expected, "MRC-Bundle muss kleiner als das Raster sein")
        #expect(outcome.execution.mrcPages == 1)
        #expect(outcome.execution.bytesSavedMRC > 0)
        #expect(descriptor.pageIndex == 0)
        #expect(descriptor.resourceName == "Im0")

        // Datei gewinnt insgesamt (Raster → Bundle).
        let inBytes = Int(Compressor.fileSize(of: input))
        let outBytes = Int(Compressor.fileSize(of: output))
        #expect(outBytes < inBytes,
                "MRC-Ausgabe (\(outBytes)) größer als Eingabe (\(inBytes))")

        // 1. OCR-Textoperatoren bleiben: Der Text der unsichtbaren Ebene
        //    steht unverändert im Seiten-Content (§13.2).
        let core = try PDFCoreDocument(path: output.path)
        let content = try core.pageContentBytes(pageIndex: 0)
        let contentText = String(decoding: content, as: UTF8.self)
        #expect(contentText.contains("Selektierbarer OCR-Text der MRC-Erkennung"),
                "OCR-Textoperator fehlt im rekonstruierten Content")
        #expect(contentText.contains("3 Tr"), "Unsichtbarer Render-Modus bleibt")
        // Der alte Raster-Draw ist weg.
        #expect(!contentText.contains("/Im0 Do"),
                "Original-Raster-Draw muss ersetzt sein")

        // 2. Annotationen bleiben (Anzahl + URL).
        let counts = try core.annotationCounts(page: 0)
        #expect(counts.total == 1, "Link-Annotation verloren")
        #expect(try core.linkURLs().contains("https://example.com/mrc"))

        // 3. Boxen unverändert.
        let info = try core.pageInfo(at: 0)
        #expect(info.mediaBox == [0, 0, 612, 792])
        #expect(info.rotation == 0)

        // 4. Kein MRC-Zweitlauf: Die Ausgabe ist für die Engine keine
        //    Scan-Seite mit dominierendem Vollbild mehr.
        let second = Self.tempURL("second")
        defer { try? FileManager.default.removeItem(at: second) }
        let secondOutcome = try CompressionPipeline.run(
            inputURL: output, outputURL: second, options: Self.mrcOptions())
        #expect(!secondOutcome.plan.actions.contains { action in
            if case .mrc = action { return true }
            return false
        }, "MRC-Output darf nicht erneut MRC-Kandidat werden")
    }

    /// Masterplan A2 Stufe 2: Eine blaue Linie auf einer Scan-Seite wird als
    /// eigene Maske in ihrer Farbe gezeichnet („r g b rg“), nicht schwarz.
    @Test func farbigeTinteWirdAlsFarbmaskeGezeichnet() throws {
        let image = try MRCSegmentationTests.pageWithBlueInk()
        let rgb = try #require(ImageResampler.rawBitmap(image, components: 3))
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let raster = b.addStream(dictionary: "/Type/XObject/Subtype/Image/Width \(image.width)"
            + "/Height \(image.height)/BitsPerComponent 8/ColorSpace/DeviceRGB/Filter/FlateDecode",
            data: try #require(ImageProcessor.flate(rgb)))
        let resources = b.addObject("<</XObject<</Im0 \(raster) 0 R>>>>")
        let content = b.addStream(dictionary: "", content: "q 612 0 0 816 0 0 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 816]"
            + "/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let input = try b.write(rootObject: root, prefix: "a2-stufe2")
        defer { try? FileManager.default.removeItem(at: input) }
        let output = Self.tempURL("a2-stufe2")
        defer { try? FileManager.default.removeItem(at: output) }

        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: output,
                                                  options: Self.mrcOptions())
        let mrc = outcome.plan.actions.compactMap { action -> MRCCandidateDescriptor? in
            if case .mrc(_, let descriptor, _, _) = action { return descriptor }
            return nil
        }.first
        let descriptor = try #require(mrc, "Erwartete MRC-Aktion im Plan")
        #expect(descriptor.colorMaskCount == 1)
        let text = String(decoding: try PDFCoreDocument(path: output.path).pageContentBytes(pageIndex: 0),
                          as: UTF8.self)
        #expect(text.contains(" rg"), "Farbmaske wird nicht farbig gemalt: \(text)")
        #expect(text.contains("0 g"), "Schwarze Maske fehlt")
    }

    /// Masterplan N21: Eine Scan-Seite mit eigenem ICC-Profil (sRGB, wie es
    /// Scanner und CoreGraphics schreiben). Die Rohwerte stehen im Profil
    /// (N5); die MRC-Ebenen und die Füllfarbe der Farbmaske müssen es
    /// weitertragen, sonst verschieben sich die Farben. (Mit AdobeRGB verwirft
    /// die Seitenprüfung dieselbe Seite knapp – Farbspitze 12,9 bei Grenze 12 –
    /// und es bleibt beim Bild: sicher, aber hier ohne MRC zu prüfen.)
    @Test func mrcBehaeltDasProfilDerQuelle() throws {
        let image = try MRCSegmentationTests.pageWithBlueInk()
        let rgb = try #require(ImageResampler.rawBitmap(image, components: 3))
        let icc = try #require(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?)
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let profile = b.addStream(dictionary: "/N 3", data: icc)
        let raster = b.addStream(dictionary: "/Type/XObject/Subtype/Image/Width \(image.width)"
            + "/Height \(image.height)/BitsPerComponent 8/ColorSpace[/ICCBased \(profile) 0 R]/Filter/FlateDecode",
            data: try #require(ImageProcessor.flate(rgb)))
        let resources = b.addObject("<</XObject<</Im0 \(raster) 0 R>>>>")
        let content = b.addStream(dictionary: "", content: "q 612 0 0 816 0 0 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 816]"
            + "/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let input = try b.write(rootObject: root, prefix: "n21-icc")
        defer { try? FileManager.default.removeItem(at: input) }
        let output = Self.tempURL("n21")
        defer { try? FileManager.default.removeItem(at: output) }

        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: output,
                                                  options: Self.mrcOptions())
        #expect(outcome.plan.actions.contains { if case .mrc = $0 { return true }; return false },
                "Erwartete MRC-Aktion im Plan")
        let layers = try PDFCoreDocument(path: output.path).imageResources()
        let rgbLayers = layers.filter { $0.pixelColorSpace.componentCount == 3 }
        #expect(!rgbLayers.isEmpty && rgbLayers.allSatisfy { $0.colorSpace == .iccBased(components: 3) },
                "RGB-Ebenen ohne Quellprofil: \(layers.map(\.colorSpace))")
        let text = String(decoding: try PDFCoreDocument(path: output.path).pageContentBytes(pageIndex: 0),
                          as: UTF8.self)
        #expect(text.contains(" cs ") && text.contains(" sc"), "Füllfarbe nicht im Quellprofil: \(text)")

        // Farbe der blauen Linie: die farbigsten Pixel der ganzen Seite (sRGB).
        func inkLab(_ url: URL) throws -> (Double, Double, Double) {
            let page = try #require(PDFDocument(url: url)?.page(at: 0))
            let (w, h) = (612, 816)
            let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                             bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            page.draw(with: .mediaBox, to: ctx)
            let px = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            var sum = (0.0, 0.0, 0.0), n = 0.0
            for i in 0..<(w * h) {
                let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), bl = Int(px[i * 4 + 2])
                guard bl - max(r, g) > 60 else { continue }   // deutlich blau
                sum.0 += Double(r); sum.1 += Double(g); sum.2 += Double(bl); n += 1
            }
            try #require(n > 50, "keine blaue Linie gefunden")
            return ICCProfileReplacementE2ETests.lab(sum.0 / n / 255, sum.1 / n / 255, sum.2 / n / 255)
        }
        let a = try inkLab(input)
        let o = try inkLab(output)
        let dE = ((a.0 - o.0) * (a.0 - o.0) + (a.1 - o.1) * (a.1 - o.1) + (a.2 - o.2) * (a.2 - o.2)).squareRoot()
        #expect(dE < 6, "Farbe der Linie verschoben: ΔE \(dE), Original \(a), Ausgabe \(o)")
    }
}
