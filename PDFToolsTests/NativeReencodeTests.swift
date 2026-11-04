import AppKit
import ImageIO
import Testing
import Foundation
import UniformTypeIdentifiers
@testable import PDFTools

/// Bilder im DPI-Budget: Klein und Smart dürfen dort noch etwas tun, wenn es
/// sich lohnt (Entscheidung 2026-11-03), Qualität bleibt verlustfrei.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Gut kodierte JPEGs werden mitgenommen und verlieren ohne Gegenwert.
///  2. Qualität fasst im Budget doch etwas verlustbehaftet an.
///  3. Jeder weitere Lauf kodiert erneut (Generationsverlust).
///  4. Die Klein-Leiter rechnet Bilder im Budget unter die Originalgröße.
///  5. Harte Grafik in Grau wird zu JPEG.
///  6. Hochauflösendes Bilevel verliert Haarlinien oder wird in Qualität
///     verändert; der Executor schreibt falsche Maße in das Dokument.
@Suite(.serialized) struct NativeReencodeTests {

    // MARK: Fixtures

    /// Körniges Motiv mit Feinstruktur – bei hoher Qualität viele Bits je Pixel.
    private static func grain(_ w: Int, _ h: Int, components: Int, amplitude: Int = 42) -> Data {
        var out = Data(capacity: w * h * components)
        var seed: UInt64 = 2026
        for y in 0..<h { for x in 0..<w {
            let u = Double(x) / 37, v = Double(y) / 29
            let base = 128 + 60 * sin(u) * cos(v) + 25 * sin(u * 3.1 + v * 2.3)
            for _ in 0..<components {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Int((seed >> 40) % UInt64(2 * amplitude + 1)) - amplitude
                out.append(UInt8(max(0, min(255, Int(base) + noise))))
            }
        } }
        return out
    }

    private static func image(_ pixels: Data, _ w: Int, _ h: Int, components: Int) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        return try #require(CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * components,
            bytesPerRow: w * components,
            space: components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private static func jpeg(_ w: Int, _ h: Int, components: Int = 3, quality: Double) throws -> Data {
        let source = try image(grain(w, h, components: components), w, h, components: components)
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// Ein Bild auf einer Seite; `dpi` ergibt sich aus der Platzierungsgröße.
    private static func document(_ name: String, width: Int, height: Int, dict: String, data: Data,
                                 dpi: Double) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let (pw, ph) = (Double(width) / dpi * 72, Double(height) / dpi * 72)
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(width)/Height \(height)" + dict, data: data)
        let content = b.addStream(dictionary: "",
                                  content: String(format: "q %.3f 0 0 %.3f 0 0 cm /Im0 Do Q", pw, ph))
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 \(pw) \(ph)]"
            + "/Resources<</XObject<</Im0 \(image) 0 R>>>>/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("native-\(UUID().uuidString).pdf")
    }

    private static func options(_ image: ImageCompressionOptions) -> CompressionOptions {
        CompressionOptions(image: image)
    }

    private struct Run {
        let action: ImageCompressionAction
        let bytes: Int
        let output: URL
    }

    private static func run(_ input: URL, _ image: ImageCompressionOptions) throws -> Run {
        let out = tempURL()
        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out, options: options(image))
        let action = try #require(outcome.plan.actions.first)
        let resource = try #require(try PDFCoreDocument(path: out.path).imageResources().first)
        return Run(action: action, bytes: resource.encodedByteCount, output: out)
    }

    private static func imageStream(_ url: URL) throws -> Data {
        let core = try PDFCoreDocument(path: url.path)
        let resource = try #require(try core.imageResources().first)
        return try #require(core.imageStreamData(objectID: resource.objectID, decoded: false))
    }

    /// Kein zweiter verlustbehafteter Durchgang: Der Bildstrom bleibt gleich.
    private static func expectStableSecondRun(_ first: Run, _ image: ImageCompressionOptions,
                                              sourceLocation: SourceLocation = #_sourceLocation) throws {
        let second = try run(first.output, image)
        defer { try? FileManager.default.removeItem(at: second.output) }
        #expect(!second.action.transformsImage,
                "Zweitlauf kodiert erneut: \(second.action)", sourceLocation: sourceLocation)
        // Der verlustfreie Repack behaltener JPEGs darf den Strom ändern, nicht die Pixel.
        let before = try imageStream(first.output), after = try imageStream(second.output)
        #expect(after.count <= before.count, sourceLocation: sourceLocation)
        if before != after {
            let a = try #require(ImageResampler.decodeJPEG(before), sourceLocation: sourceLocation)
            let b = try #require(ImageResampler.decodeJPEG(after), sourceLocation: sourceLocation)
            #expect(a.dataProvider?.data as Data? == b.dataProvider?.data as Data?,
                    "Zweitlauf ändert die Pixel", sourceLocation: sourceLocation)
        }
    }

    private static func dimensions(_ url: URL) throws -> PixelSize {
        let resource = try #require(try PDFCoreDocument(path: url.path).imageResources().first)
        return PixelSize(width: resource.width, height: resource.height)
    }

    // MARK: JPEG

    /// Verschwenderisch kodiert, 100 DPI: unter jedem Ziel. Die Stufen trennen
    /// sich, Qualität bleibt beim Repack, der Zweitlauf steht.
    @Test(.hangGuard) func wastefulJPEGAtNativeSizeSeparatesKleinAndSmart() throws {
        let (w, h) = (1000, 1300)
        let data = try Self.jpeg(w, h, quality: 0.95)
        let bpp = Double(data.count) * 8 / Double(w * h)
        #expect(bpp > 2.5, "Fixture ist nicht verschwenderisch: \(bpp) bit/px")
        let input = try Self.document("jpeg-wasteful", width: w, height: h,
                                      dict: "/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode",
                                      data: data, dpi: 100)
        defer { try? FileManager.default.removeItem(at: input) }

        let klein = try Self.run(input, .small)
        let smart = try Self.run(input, .smart)
        let qualitaet = try Self.run(input, .quality)
        defer { for r in [klein, smart, qualitaet] { try? FileManager.default.removeItem(at: r.output) } }

        for (name, run) in [("Klein", klein), ("Smart", smart)] {
            guard case .jpeg(_, let target, _, _, _, _, _) = run.action else {
                Issue.record("\(name): erwartete JPEG auf Originalgröße, war \(run.action)")
                continue
            }
            #expect(target == PixelSize(width: w, height: h), "\(name) verkleinert im Budget: \(target)")
            #expect(Double(run.bytes) <= Double(data.count) * CandidateGenerator.nativeReencodeMaximumRatio)
        }
        guard case .keep = qualitaet.action else {
            Issue.record("Qualität fasst im Budget an: \(qualitaet.action)")
            return
        }
        #expect(klein.bytes <= smart.bytes && smart.bytes < qualitaet.bytes,
                "Reihenfolge: Klein \(klein.bytes), Smart \(smart.bytes), Qualität \(qualitaet.bytes)")

        try Self.expectStableSecondRun(klein, .small)
        try Self.expectStableSecondRun(smart, .smart)
    }

    /// Dasselbe Motiv bei niedriger Qualität liegt unter beiden Schwellen.
    @Test(.hangGuard) func wellEncodedJPEGStaysUntouched() throws {
        let (w, h) = (1000, 1300)
        let data = try Self.jpeg(w, h, quality: 0.30)
        let bpp = Double(data.count) * 8 / Double(w * h)
        #expect(bpp < 1.5, "Fixture ist nicht gut kodiert: \(bpp) bit/px")
        let input = try Self.document("jpeg-well", width: w, height: h,
                                      dict: "/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode",
                                      data: data, dpi: 100)
        defer { try? FileManager.default.removeItem(at: input) }
        for image in [ImageCompressionOptions.small, .smart, .quality] {
            let run = try Self.run(input, image)
            defer { try? FileManager.default.removeItem(at: run.output) }
            #expect(!run.action.transformsImage, "\(run.action)")
        }
    }

    /// Zwischen den Schwellen geht nur Klein weiter.
    @Test func thresholdsAreOrderedAndQualityHasNone() {
        let small = CandidateGenerator.wastefulJPEGBitsPerPixel(.small) ?? .infinity
        let smart = CandidateGenerator.wastefulJPEGBitsPerPixel(.smart) ?? 0
        #expect(small < smart)
        #expect(CandidateGenerator.wastefulJPEGBitsPerPixel(.quality) == nil)
        let custom = CompressionPresetFactory.custom(dpi: 200, quality: 0.85, maxPixelEdge: 6000).image
        #expect(CandidateGenerator.wastefulJPEGBitsPerPixel(custom) == nil)
    }

    // MARK: Grau im Budget

    @Test(.hangGuard) func grayFlateScanWithinBudgetGetsCandidates() throws {
        let (w, h) = (1000, 1300)
        let flate = try #require(ImageProcessor.flate(Self.grain(w, h, components: 1)))
        let input = try Self.document("gray-flate", width: w, height: h,
                                      dict: "/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/FlateDecode",
                                      data: flate, dpi: 100)
        defer { try? FileManager.default.removeItem(at: input) }
        let klein = try Self.run(input, .small)
        let smart = try Self.run(input, .smart)
        let qualitaet = try Self.run(input, .quality)
        defer { for r in [klein, smart, qualitaet] { try? FileManager.default.removeItem(at: r.output) } }

        #expect(klein.action.transformsImage && smart.action.transformsImage)
        #expect(klein.bytes <= smart.bytes && smart.bytes < qualitaet.bytes,
                "Klein \(klein.bytes), Smart \(smart.bytes), Qualität \(qualitaet.bytes)")
        guard case .keep(_, .alreadyGrayscale, _) = qualitaet.action else {
            Issue.record("Qualität: \(qualitaet.action)")
            return
        }
        #expect(try Self.dimensions(smart.output) == PixelSize(width: w, height: h))
        try Self.expectStableSecondRun(klein, .small)
        try Self.expectStableSecondRun(smart, .smart)
    }

    /// Harte Kanten in Grau: nie JPEG.
    @Test(.hangGuard) func hardEdgedGrayStaysLossless() throws {
        let (w, h) = (1000, 1300)
        var raw = Data(capacity: w * h)
        for y in 0..<h { for x in 0..<w {
            raw.append((x / 40 + y / 40) % 2 == 0 ? 20 : 235)
        } }
        // Roh gespeichert: Es gibt also etwas zu holen, nur eben verlustfrei.
        let input = try Self.document("gray-hard", width: w, height: h,
                                      dict: "/ColorSpace/DeviceGray/BitsPerComponent 8",
                                      data: raw, dpi: 100)
        defer { try? FileManager.default.removeItem(at: input) }
        for image in [ImageCompressionOptions.small, .smart] {
            let run = try Self.run(input, image)
            defer { try? FileManager.default.removeItem(at: run.output) }
            if case .jpeg = run.action { Issue.record("Harte Grafik wurde JPEG: \(run.action)") }
            let resource = try #require(try PDFCoreDocument(path: run.output.path).imageResources().first)
            #expect(resource.terminalFilter != .dct)
        }
    }

    // MARK: Bilevel

    /// Text als 1-bit-Puffer (Bit 1 = Tinte), auf Wunsch mit Haarlinien.
    private static func textBilevel(width: Int, height: Int, pointSize: CGFloat,
                                    hairlines: Bool = false) throws -> BilevelBuffer {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let line = "Sehr hochaufgelöster Scan: Quittung, Haftung, Rechnung 1234567890 — öäüß"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Times New Roman", size: pointSize) ?? NSFont.systemFont(ofSize: pointSize),
            .foregroundColor: NSColor.black]
        var y = CGFloat(height) - pointSize * 2
        while y > pointSize {
            NSAttributedString(string: line, attributes: attributes)
                .draw(at: CGPoint(x: pointSize, y: y))
            y -= pointSize * 1.6
        }
        NSGraphicsContext.restoreGraphicsState()
        if hairlines {
            // Ein Feinraster aus 1-px-Linien über die ganze Seite.
            context.setFillColor(gray: 0, alpha: 1)
            for x in stride(from: 0, to: width, by: 7) {
                context.fill(CGRect(x: x, y: 0, width: 1, height: height))
            }
        }
        let gray = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let rowBytes = BilevelBuffer.rowBytes(width: width)
        var bits = [UInt8](repeating: 0, count: rowBytes * height)
        for row in 0..<height { for x in 0..<width where gray[row * width + x] < 128 {
            bits[row * rowBytes + x / 8] |= 0x80 >> UInt8(x % 8)
        } }
        return try #require(BilevelBuffer(width: width, height: height, data: Data(bits)))
    }

    private static func bilevelDocument(_ buffer: BilevelBuffer, dpi: Double) throws -> URL {
        try document("bilevel-hires", width: buffer.width, height: buffer.height,
                     dict: "/ColorSpace/DeviceGray/BitsPerComponent 1",
                     data: Data(buffer.data.map { ~$0 }), dpi: dpi)
    }

    @Test(.hangGuard) func hiresBilevelTextIsHalvedPerPreset() throws {
        // 1200 DPI, Ausschnitt 5 × 5 Zoll; 11-pt-Schrift.
        let buffer = try Self.textBilevel(width: 6000, height: 6000, pointSize: 183)
        let input = try Self.bilevelDocument(buffer, dpi: 1200)
        defer { try? FileManager.default.removeItem(at: input) }
        let klein = try Self.run(input, .small)
        let smart = try Self.run(input, .smart)
        let qualitaet = try Self.run(input, .quality)
        defer { for r in [klein, smart, qualitaet] { try? FileManager.default.removeItem(at: r.output) } }

        #expect(try Self.dimensions(klein.output) == PixelSize(width: 1500, height: 1500))
        #expect(try Self.dimensions(smart.output) == PixelSize(width: 3000, height: 3000))
        #expect(try Self.dimensions(qualitaet.output) == PixelSize(width: 6000, height: 6000))
        #expect(klein.bytes < smart.bytes && smart.bytes < qualitaet.bytes,
                "Klein \(klein.bytes), Smart \(smart.bytes), Qualität \(qualitaet.bytes)")

        // Die geschriebene Datei rendert und bleibt nah an der Quelle.
        for run in [klein, smart] {
            let page = try #require(RenderDifferential.compare(sourceURL: input, outputURL: run.output,
                                                               dpi: 150).first)
            #expect(abs(page.inkDelta) < 0.01, "inkDelta \(page.inkDelta)")
        }
        // Zweitlauf: nichts wird weiter verkleinert.
        for (run, image) in [(klein, ImageCompressionOptions.small), (smart, .smart)] {
            let second = try Self.run(run.output, image)
            defer { try? FileManager.default.removeItem(at: second.output) }
            #expect(try Self.dimensions(second.output) == Self.dimensions(run.output))
        }
    }

    /// 600 DPI: Klein ja, Smart nein.
    @Test(.hangGuard) func bilevelAt600DPIOnlyKlein() throws {
        let buffer = try Self.textBilevel(width: 3000, height: 3000, pointSize: 92)
        let input = try Self.bilevelDocument(buffer, dpi: 600)
        defer { try? FileManager.default.removeItem(at: input) }
        let klein = try Self.run(input, .small)
        let smart = try Self.run(input, .smart)
        defer { for r in [klein, smart] { try? FileManager.default.removeItem(at: r.output) } }
        #expect(try Self.dimensions(klein.output) == PixelSize(width: 1500, height: 1500))
        #expect(try Self.dimensions(smart.output) == PixelSize(width: 3000, height: 3000))
    }

    /// Feinraster verschwindet beim Halbieren: Das Tintengate lehnt ab.
    @Test(.hangGuard) func hairlinesBlockResampling() throws {
        let buffer = try Self.textBilevel(width: 6000, height: 6000, pointSize: 183, hairlines: true)
        let input = try Self.bilevelDocument(buffer, dpi: 1200)
        defer { try? FileManager.default.removeItem(at: input) }
        for image in [ImageCompressionOptions.small, .smart] {
            let run = try Self.run(input, image)
            defer { try? FileManager.default.removeItem(at: run.output) }
            #expect(try Self.dimensions(run.output) == PixelSize(width: 6000, height: 6000))
        }
    }

    /// Kein Bild ohne bekannte Auflösung, keine Stufe außer Klein und Smart.
    @Test func factorFollowsPresetAndResolution() throws {
        func factor(dpi: Double, _ image: ImageCompressionOptions) throws -> Int? {
            let buffer = try #require(BilevelBuffer(width: 2400, height: 2400,
                                                    data: Data(count: BilevelBuffer.rowBytes(width: 2400) * 2400)))
            let url = try Self.bilevelDocument(buffer, dpi: dpi)
            defer { try? FileManager.default.removeItem(at: url) }
            let resource = try #require(try PDFCoreDocument(path: url.path).imageResources().first)
            return BilevelResampling.factor(for: resource, options: image)
        }
        #expect(try factor(dpi: 1200, .small) == 4)
        #expect(try factor(dpi: 600, .small) == 2)
        #expect(try factor(dpi: 500, .small) == nil)
        #expect(try factor(dpi: 1200, .smart) == 2)
        #expect(try factor(dpi: 2400, .smart) == 4)
        #expect(try factor(dpi: 600, .smart) == nil)
        #expect(try factor(dpi: 1200, .quality) == nil)
    }
}
