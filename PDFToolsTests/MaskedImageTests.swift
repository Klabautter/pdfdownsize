import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Bilder mit Maske dürfen komprimiert werden – ihre Transparenz nicht
/// verlieren.
///
/// Sie waren pauschal ausgeschlossen, mit der Begründung, Bild und Maske
/// müssten gemeinsam umgerechnet werden. Die Norm verlangt das nicht: Nach
/// PDF 32000-1 §8.9.6.4 muss eine weiche Maske nicht dieselben Masse haben
/// wie ihr Basisbild, sie wird darauf skaliert.
///
/// Die Annahme kostete 143,5 MB im Korpus – 40 % aller Bilddaten und damit
/// der grösste einzelne Posten.
@Suite struct MaskedImageTests {

    /// Vorbedingung: Die Fixture trägt wirklich eine Maske, und die Maske
    /// hat andere Masse als das Bild.
    @Test(.hangGuard) func fixtureCarriesASoftMask() throws {
        let url = try PDFFixtures.softMaskedPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let res = try doc.imageResources()
        let base = try #require(res.first { $0.hasSoftMask },
                                "Kein Bild mit weicher Maske: \(res.count) Bilder")
        #expect(base.width == 2400)
        // Die Maske selbst erscheint NICHT in dieser Liste: Sie hängt am
        // Wörterbuch des Bildes, nicht an den Seitenressourcen. Gemeldet
        // wird sie über `hasSoftMask` am Basisbild – und genau das ist die
        // Beziehung, die eine Neukodierung überleben muss.
        #expect(res.count == 1,
                "Unerwartet \(res.count) Bildressourcen")
    }

    /// Ein maskiertes Bild ist transformierbar.
    @Test(.hangGuard) func maskedImageIsTransformable() throws {
        let url = try PDFFixtures.softMaskedPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let res = try doc.imageResources()
        let base = try #require(res.first { $0.hasSoftMask })
        #expect(base.transformCapability.isSafe, """
            Maskiertes Bild gilt weiterhin als untransformierbar: \
            \(base.transformCapability.reason)
            """)
    }

    /// Und die Kompression fasst es an, ohne die Transparenz zu verlieren.
    @Test(.hangGuard) func compressionKeepsTheMaskRelation() throws {
        let url = try PDFFixtures.softMaskedPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let inBytes = Compressor.fileSize(of: url)

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.outputBytes < inBytes, """
            Nicht kleiner geworden: \(inBytes) → \(result.outputBytes)
            """)

        let out = try PDFCoreDocument(path: result.outputURL.path)
        let res = try out.imageResources()
        let base = try #require(res.first { $0.width > 200 && $0.hasSoftMask }, """
            Nach der Kompression trägt kein Bild mehr eine weiche Maske – \
            die Transparenz ist verloren. Bilder: \
            \(res.map { "\($0.width)×\($0.height) smask=\($0.hasSoftMask)" })
            """)
        #expect(base.width < 2400, "Das Bild wurde nicht verkleinert")
    }

    /// Eine weiche Maske mit /Matte geht die Verkleinerung mit.
    ///
    /// Die Farben des Basisbildes sind gegen die Matte-Farbe vorgemischt;
    /// PDF 32000-1 §11.6.5.3 verlangt dann dieselben Masse für Bild und
    /// Maske. Bis 1.0.3 wurde nur das Bild verkleinert – Poppler meldete
    /// „Softmask with matte entry … must have same geometry" (CSWP.04162018,
    /// S. 19, Klein).
    @Test(.hangGuard) func matteSoftMaskFollowsTheResize() throws {
        let url = try PDFFixtures.softMaskedPhotoPDF(matte: true,
                                                     name: "matte-masked")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Compressor().compress(inputURL: url, mode: .small)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let pairs = try Self.imageAndMaskGeometry(of: result.outputURL)
        let pair = try #require(pairs.first { $0.matte }, """
            Kein Bild mit /Matte-Maske mehr im Ergebnis – Transparenz \
            verloren? \(pairs)
            """)
        #expect(pair.image.width < 2400, "Das Bild wurde nicht verkleinert")
        #expect(pair.image == pair.mask, """
            Maske mit /Matte hat \(pair.mask), das Bild \(pair.image) – \
            §11.6.5.3 verlangt gleiche Masse.
            """)
    }

    struct Geometry: Equatable, CustomStringConvertible {
        let width: Int, height: Int
        var description: String { "\(width)×\(height)" }
    }

    /// Masse aller Seitenbilder mit weicher Maske, direkt aus den Wörter-
    /// büchern gelesen – `imageResources()` meldet die Maske nur als Flag.
    static func imageAndMaskGeometry(of url: URL) throws
        -> [(image: Geometry, mask: Geometry, matte: Bool)] {
        let doc = try #require(CGPDFDocument(url as CFURL))
        var found: [(image: Geometry, mask: Geometry, matte: Bool)] = []
        for index in 1...max(doc.numberOfPages, 1) {
            guard let page = doc.page(at: index)?.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(page, "Resources", &resources),
                  let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
                  let xobjects else { continue }
            var streams: [CGPDFStreamRef] = []
            withUnsafeMutablePointer(to: &streams) { ctx in
                CGPDFDictionaryApplyFunction(xobjects, { _, object, info in
                    var stream: CGPDFStreamRef?
                    if CGPDFObjectGetValue(object, .stream, &stream), let stream {
                        info!.assumingMemoryBound(to: [CGPDFStreamRef].self)
                            .pointee.append(stream)
                    }
                }, ctx)
            }
            for stream in streams {
                guard let dict = CGPDFStreamGetDictionary(stream) else { continue }
                var smask: CGPDFStreamRef?
                guard CGPDFDictionaryGetStream(dict, "SMask", &smask), let smask,
                      let maskDict = CGPDFStreamGetDictionary(smask) else { continue }
                var matte: CGPDFArrayRef?
                found.append((image: geometry(dict), mask: geometry(maskDict),
                              matte: CGPDFDictionaryGetArray(maskDict, "Matte", &matte)))
            }
        }
        return found
    }

    private static func geometry(_ dict: CGPDFDictionaryRef) -> Geometry {
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(dict, "Width", &w)
        CGPDFDictionaryGetInteger(dict, "Height", &h)
        return Geometry(width: w, height: h)
    }

    // MARK: Weiche Masken ohne /Matte gehen mit
    //
    // Fehlerbilder, gegen die diese Tests stehen: Maske bleibt gross und
    // dominiert das Ergebnis; geteilte Maske unter den Bedarf des grössten
    // Bildes oder unter ein unverkleinertes Bild gerechnet; geteilte Maske je
    // Bild kopiert; harte Kante verschwimmt auf dem Bildraster; /Decode geht
    // verloren; Zweitlauf rechnet die Maske weiter herunter; nicht 8 Bit wird
    // als 8 Bit gelesen.

    /// Eine weiche Maske folgt dem verkleinerten Bild, die Seite sieht gleich aus.
    @Test(.hangGuard) func softMaskFollowsTheResize() throws {
        let url = try Self.maskedPDF(name: "soft-follow", mask: .gradient(2400, 1800),
                                     placements: [512])
        defer { try? FileManager.default.removeItem(at: url) }
        let inBytes = Compressor.fileSize(of: url)

        let result = try Compressor().compress(inputURL: url, mode: .small)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let pair = try #require(try Self.imageAndMaskGeometry(of: result.outputURL).first)
        #expect(pair.image.width < 2400, "Das Bild wurde nicht verkleinert")
        #expect(pair.mask == pair.image, "Maske \(pair.mask), Bild \(pair.image)")
        #expect(result.outputBytes < inBytes / 2, "\(inBytes) → \(result.outputBytes)")
        try Self.expectRenderMatch(url, result.outputURL)
    }

    /// Klein <= Smart <= Qualität, und die Stufen unterscheiden sich sichtbar.
    @Test(.hangGuard) func softMaskSeparatesThePresets() throws {
        let url = try Self.maskedPDF(name: "soft-presets", mask: .gradient(2400, 1800),
                                     placements: [300])
        defer { try? FileManager.default.removeItem(at: url) }
        var sizes: [Int] = []
        for mode in [CompressionMode.small, .smart, .quality] {
            let result = try Compressor().compress(inputURL: url, mode: mode)
            defer { try? FileManager.default.removeItem(at: result.outputURL) }
            sizes.append(Int(result.outputBytes))
            try Self.expectRenderMatch(url, result.outputURL)
        }
        #expect(sizes[0] < sizes[1] && sizes[1] < sizes[2], "\(sizes)")
    }

    /// Eine geteilte Maske bleibt ein Objekt und reicht für das grösste Bild.
    @Test(.hangGuard) func sharedMaskServesTheLargestPlacement() throws {
        let url = try Self.maskedPDF(name: "soft-shared", mask: .gradient(2400, 1800),
                                     placements: [512, 40])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Compressor().compress(inputURL: url, mode: .small)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let pairs = try Self.imageAndMaskGeometry(of: result.outputURL)
        try #require(pairs.count == 2, "\(pairs)")
        let largest = try #require(pairs.map(\.image.width).max())
        #expect(largest < 2400, "\(pairs)")
        #expect(pairs[0].image.width != pairs[1].image.width, "\(pairs)")
        for pair in pairs {
            #expect(pair.mask.width == largest, "\(pairs)")
        }
        try Self.expectRenderMatch(url, result.outputURL)
    }

    /// Benutzt ein unverkleinertes Bild die Maske mit, bleibt sie, wie sie ist.
    @Test(.hangGuard) func sharedMaskStaysForAnUnchangedImage() throws {
        // Das zweite Bild liegt unter jeder Zielauflösung: 400 px auf 400 pt.
        let url = try Self.maskedPDF(name: "soft-shared-kept", mask: .gradient(2400, 1800),
                                     placements: [512, 400],
                                     imageWidths: [2400, 400])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Compressor().compress(inputURL: url, mode: .small)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let pairs = try Self.imageAndMaskGeometry(of: result.outputURL)
        try #require(pairs.count == 2, "\(pairs)")
        #expect(pairs.contains { $0.image.width == 400 }, "\(pairs)")
        #expect(pairs.contains { $0.image.width < 2400 && $0.image.width != 400 }, "\(pairs)")
        for pair in pairs {
            #expect(pair.mask.width == 2400, "\(pairs)")
        }
    }

    /// Eine harte Kante behält Reserve über dem Bildraster und bleibt scharf.
    @Test(.hangGuard) func hardMaskKeepsItsEdge() throws {
        let url = try Self.maskedPDF(name: "soft-hard", mask: .hardShapes(2400, 1800),
                                     placements: [300])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Compressor().compress(inputURL: url, mode: .small)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let pair = try #require(try Self.imageAndMaskGeometry(of: result.outputURL).first)
        #expect(pair.image.width < 1200, "\(pair)")
        #expect(pair.mask.width == pair.image.width * 2, "\(pair)")
        try Self.expectRenderMatch(url, result.outputURL)
    }

    /// /Decode gehört zur Bedeutung der Maske: Invertiert bleibt invertiert.
    @Test(.hangGuard) func maskDecodeSurvivesTheResize() throws {
        let url = try Self.maskedPDF(name: "soft-decode", mask: .gradient(2400, 1800),
                                     placements: [512], maskExtra: "/Decode[1 0]")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Compressor().compress(inputURL: url, mode: .small)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let pair = try #require(try Self.imageAndMaskGeometry(of: result.outputURL).first)
        #expect(pair.mask.width < 2400, "\(pair)")
        try Self.expectRenderMatch(url, result.outputURL)
    }

    /// Der Zweitlauf rechnet die Maske nicht weiter herunter.
    @Test(.hangGuard) func secondRunLeavesTheMaskAlone() throws {
        let url = try Self.maskedPDF(name: "soft-second", mask: .hardShapes(2400, 1800),
                                     placements: [512])
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try Compressor().compress(inputURL: url, mode: .small)
        defer { try? FileManager.default.removeItem(at: first.outputURL) }
        let second = try Compressor().compress(inputURL: first.outputURL, mode: .small)
        defer { try? FileManager.default.removeItem(at: second.outputURL) }

        let before = try #require(try Self.imageAndMaskGeometry(of: first.outputURL).first)
        let after = try #require(try Self.imageAndMaskGeometry(of: second.outputURL).first)
        #expect(before.mask == after.mask, "\(before) → \(after)")
        #expect(second.outputBytes <= first.outputBytes)
    }

    /// Eine 1-Bit-Maske liest die Umrechnung nicht – sie bleibt, das Bild schrumpft.
    @Test(.hangGuard) func bilevelSoftMaskStaysUntouched() throws {
        let url = try Self.maskedPDF(name: "soft-1bit", mask: .bilevel(2400, 1800),
                                     placements: [512])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Compressor().compress(inputURL: url, mode: .small)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let pair = try #require(try Self.imageAndMaskGeometry(of: result.outputURL).first)
        #expect(pair.image.width < 2400, "\(pair)")
        #expect(pair.mask.width == 2400, "\(pair)")
        try Self.expectRenderMatch(url, result.outputURL)
    }

    enum MaskContent {
        case gradient(Int, Int), hardShapes(Int, Int), bilevel(Int, Int)
    }

    /// Bilder auf farbigem Grund (sonst wäre die Transparenz unsichtbar), alle
    /// mit DERSELBEN Maske. `placements` sind die Breiten in pt.
    private static func maskedPDF(name: String, mask: MaskContent, placements: [Double],
                                  imageWidths: [Int]? = nil,
                                  maskExtra: String = "") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let maskRef: Int
        switch mask {
        case .gradient(let w, let h):
            var bytes = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { bytes[y * w + x] = UInt8(255 * x / (w - 1)) } }
            maskRef = b.addStream(dictionary: maskDict(w, h, bits: 8) + maskExtra, data: Data(bytes))
        case .hardShapes(let w, let h):
            var bytes = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w {
                let dx = Double(x - w / 2), dy = Double(y - h / 2)
                let disc = dx * dx + dy * dy < Double(h * h) / 5
                bytes[y * w + x] = disc && (y / 40) % 3 != 2 ? 255 : 0
            } }
            maskRef = b.addStream(dictionary: maskDict(w, h, bits: 8) + maskExtra, data: Data(bytes))
        case .bilevel(let w, let h):
            let row = (w + 7) / 8
            var bytes = [UInt8](repeating: 0, count: row * h)
            for y in 0..<h where (y / 40) % 3 != 2 {
                for x in (row / 4)..<(row * 3 / 4) { bytes[y * row + x] = 0xFF }
            }
            maskRef = b.addStream(dictionary: maskDict(w, h, bits: 1) + maskExtra, data: Data(bytes))
        }

        var xobjects = ""
        var content = "0.1 0.2 0.8 rg 0 0 612 792 re f\n"
        var top = 780.0
        for (index, placed) in placements.enumerated() {
            let w = imageWidths?[index] ?? 2400
            let h = w * 3 / 4
            // Ein angehängtes Byte hält die Bilder auseinander, sonst legt der
            // Duplikat-Abgleich sie zusammen.
            let jpeg = try stripedJPEG(width: w, height: h)
                + Data([UInt8(index)])
            let image = b.addStream(
                dictionary: "/Type/XObject/Subtype/Image/Width \(w)/Height \(h)"
                    + "/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode"
                    + "/SMask \(maskRef) 0 R",
                data: jpeg)
            xobjects += "/Im\(index) \(image) 0 R"
            let height = placed * 3 / 4
            top -= height + 4
            content += "q \(placed) 0 0 \(height) 40 \(top) cm /Im\(index) Do Q\n"
        }
        let stream = b.addStream(dictionary: "", content: content)
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</XObject<<\(xobjects)>>>>/Contents \(stream) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = PDFFixtures.fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    private static func maskDict(_ w: Int, _ h: Int, bits: Int) -> String {
        "/Type/XObject/Subtype/Image/Width \(w)/Height \(h)"
            + "/ColorSpace/DeviceGray/BitsPerComponent \(bits)"
    }

    private static func stripedJPEG(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in stride(from: 0, to: width, by: 6) {
            let t = CGFloat(x) / CGFloat(width)
            ctx.setFillColor(red: t, green: 1 - t, blue: 0.5 + 0.5 * sin(t * 40), alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 6, height: height))
        }
        let image = try #require(ctx.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
    }

    /// Dieselbe Prüfung wie die Abnahme: gerenderte Seite gegen die Quelle.
    private static func expectRenderMatch(_ source: URL, _ output: URL,
                                          sourceLocation: SourceLocation = #_sourceLocation) throws {
        let pages = try RenderDifferential.compare(sourceURL: source, outputURL: output)
        for page in pages {
            #expect(page.ssim >= 0.97, "SSIM \(page.ssim)", sourceLocation: sourceLocation)
            #expect(page.meanAbsDiff <= 4, "MAD \(page.meanAbsDiff)", sourceLocation: sourceLocation)
        }
    }

    /// Farbschlüssel-Maskierung bleibt ausgeschlossen.
    ///
    /// `/Mask` als Array benennt Farbwerte im Original. Eine verlustbehaftete
    /// Neukodierung verschiebt genau diese Werte – die Maskierung träfe
    /// danach andere Bildpunkte. Ohne diese Gegenprobe wäre die Lockerung
    /// zu weit gegangen.
    @Test(.hangGuard) func colorKeyMaskingStaysExcluded() throws {
        let url = try PDFFixtures.colorKeyMaskedPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let res = try doc.imageResources()
        let base = try #require(res.first, "Kein Bild in der Fixture")
        #expect(base.hasColorKeyMask, "Farbschlüssel-Maske nicht erkannt")
        #expect(!base.transformCapability.isSafe, """
            Farbschlüssel-Maskierung gilt als transformierbar – eine \
            verlustbehaftete Neukodierung würde die Maskierung verschieben.
            """)
    }
}
