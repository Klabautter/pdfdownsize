import AppKit
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import PDFTools

/// Paletten, 16 Bit, JPX ohne /ColorSpace und die Farbräume Lab, Separation,
/// DeviceN: Gehen sie durch die Stufen, ohne dass sich eine Farbe ändert?
///
/// Vorab notiert, was dabei schiefgehen kann:
/// 1. Palette falsch aufgelöst (Bytefolge, gepackte Indizes, Plätze > hival).
/// 2. /Indexed bleibt am neuen Stream stehen, die Bytes sind aber Grauwerte.
/// 3. Der Basisfarbraum geht verloren (ICC-Profil, CMYK wird RGB).
/// 4. 16 Bit in falscher Bytefolge gelesen.
/// 5. Lab/Separation/DeviceN als JPEG oder unter fremdem /ColorSpace.
/// 6. Hartkantige Palettengrafik wird zu JPEG.
/// 7. Ein wirksames /Decode geht unterwegs verloren.
/// 8. Klein ist größer als Qualität, oder ein zweiter Lauf zehrt weiter.
///
/// Geprüft wird am gerenderten Ergebnis gegen das gerenderte Original: Es
/// kommt darauf an, was der Betrachter sieht, nicht welche Bytes da stehen.
@Suite(.serialized) struct ImageSampleSourceTests {

    // 400 DPI auf 150 × 200 pt: In allen drei Stufen über dem Ziel.
    private static let width = 833
    private static let height = 1111

    private static let rgbPalette: [(UInt8, UInt8, UInt8)] = [
        (255, 255, 255), (200, 30, 30), (30, 160, 60), (30, 60, 200),
        (240, 160, 20), (0, 0, 0), (120, 120, 120), (250, 240, 40)
    ]

    /// Vier einfarbige Felder (Index 1 bis 4) in sonst hartkantigem Kleinteil.
    private static let patches: [(u: Double, v: Double)] = [
        (0.15, 0.13), (0.85, 0.13), (0.15, 0.87), (0.85, 0.87)
    ]

    /// Eine Palettenzuordnung je Bildpunkt, von oben nach unten.
    private static func scene(entries: Int) -> [UInt8] {
        let (w, h) = (width, height)
        var map = [UInt8](repeating: 0, count: w * h)
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for _ in 0..<2600 {
            let (x, y) = (next(w - 24), next(h - 24))
            let (rw, rh) = (3 + next(20), 3 + next(20))
            let index = UInt8(min(5 + next(3), entries - 1))
            for yy in y..<(y + rh) { for xx in x..<(x + rw) { map[yy * w + xx] = index } }
        }
        for (i, p) in patches.enumerated() {
            let index = UInt8(min(i + 1, entries - 1))
            let (cx, cy) = (Int(p.u * Double(w)), Int(p.v * Double(h)))
            for yy in (cy - 90)..<(cy + 90) { for xx in (cx - 90)..<(cx + 90) {
                map[yy * w + xx] = index
            } }
        }
        return map
    }

    private static func packed(_ values: [UInt8], bits: Int, samplesPerRow: Int) -> Data {
        guard bits != 8 else { return Data(values) }
        let rowBytes = (samplesPerRow * bits + 7) / 8
        var out = [UInt8](repeating: 0, count: rowBytes * values.count / samplesPerRow)
        for (i, v) in values.enumerated() {
            let (y, x) = (i / samplesPerRow, i % samplesPerRow)
            let bit = x * bits
            out[y * rowBytes + bit / 8] |= v << UInt8(8 - bits - bit % 8)
        }
        return Data(out)
    }

    private static func hex(_ table: [UInt8]) -> String {
        "<" + table.map { String(format: "%02X", $0) }.joined() + ">"
    }

    private static func flate(_ data: Data) throws -> Data {
        try #require(ImageProcessor.flate(data))
    }

    /// Ein Bild auf einer Seite; es deckt 56 % davon, damit keine Scan-Regel
    /// greift. `objects` legt Hilfsobjekte an (Profil, Funktion).
    private static func document(_ name: String, imageDict: String, data: Data,
                                 objects: (inout RawPDFBuilder) -> Void = { _ in }) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        objects(&b)
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(width)/Height \(height)" + imageDict,
            data: data)
        let content = b.addStream(dictionary: "", content: "q 150 0 0 200 0 67 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 200 267]"
            + "/Resources<</XObject<</Im0 \(image) 0 R>>>>/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = PDFFixtures.fixtureURL(prefix: "samples-\(name)")
        try b.build(rootObject: root).write(to: url)
        return url
    }

    private static func indexedPDF(_ name: String, bits: Int = 8, entries: Int = 8,
                                   palette: [UInt8]? = nil, baseSpace: String = "/DeviceRGB",
                                   extra: String = "",
                                   objects: (inout RawPDFBuilder) -> Void = { _ in }) throws -> URL {
        let table = palette ?? rgbPalette.prefix(entries).flatMap { [$0.0, $0.1, $0.2] }
        let map = packed(scene(entries: entries), bits: bits, samplesPerRow: width)
        return try document(name, imageDict: "/ColorSpace[/Indexed \(baseSpace) \(entries - 1) \(hex(table))]"
            + "/BitsPerComponent \(bits)/Filter/FlateDecode\(extra)",
            data: try flate(map), objects: objects)
    }

    private static func rgbSamples() -> [UInt8] {
        scene(entries: 8).flatMap { i -> [UInt8] in
            let c = rgbPalette[Int(i)]
            return [c.0, c.1, c.2]
        }
    }

    // MARK: Rendern und Vergleichen

    private static func rendering(_ url: URL) throws -> (Double, Double) -> (Int, Int, Int) {
        let thumb = try #require(PDFDocument(url: url)?.page(at: 0)?
            .thumbnail(of: CGSize(width: 400, height: 534), for: .mediaBox))
        let image = try #require(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let (w, h) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Das Bild liegt links, in den unteren drei Vierteln der Seite (es
        // beginnt 67 pt über dem Seitenfuss, also bis 267 − 67 − 200 = 0 von oben).
        let copy = pixels
        return { u, v in
            let x = Int(u * 150 / 200 * Double(w))
            let y = Int(v * 200 / 267 * Double(h))
            let at = y * w * 4 + x * 4
            return (Int(copy[at]), Int(copy[at + 1]), Int(copy[at + 2]))
        }
    }

    /// Die vier Felder sehen im Ausgang aus wie im Original.
    private static func expectSameColours(_ source: URL, _ output: URL, tolerance: Int = 4,
                                          _ label: String) throws {
        let before = try rendering(source), after = try rendering(output)
        for p in patches {
            let a = before(p.u, p.v), b = after(p.u, p.v)
            #expect(abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance
                        && abs(a.2 - b.2) <= tolerance,
                    "\(label): Farbe bei \(p) von \(a) nach \(b)")
        }
    }

    private static func outputImage(_ url: URL) throws -> PDFImageResource {
        try #require(try PDFCoreDocument(path: url.path).imageResources().first)
    }

    private static func inputImage(_ url: URL) throws -> PDFImageResource {
        try outputImage(url)
    }

    /// Alle drei Stufen: Größenfolge, Farben, kein JPEG, wo es verboten ist.
    @discardableResult
    private static func runPresets(_ url: URL, label: String, forbidJPEG: Bool,
                                   tolerance: Int = 4) throws -> [Int] {
        var sizes: [Int] = []
        for mode in [CompressionMode.small, .smart, .quality] {
            let result = try Compressor().compress(inputURL: url, mode: mode)
            defer { try? FileManager.default.removeItem(at: result.outputURL) }
            sizes.append(Int(Compressor.fileSize(of: result.outputURL)))
            try expectSameColours(url, result.outputURL, tolerance: tolerance, "\(label) \(mode)")
            if forbidJPEG {
                #expect(try outputImage(result.outputURL).terminalFilter != .dct,
                        "\(label) \(mode): JPEG auf hartkantiger Grafik")
            }
        }
        #expect(sizes[0] <= sizes[1] && sizes[1] <= sizes[2], "\(label): Stufenfolge \(sizes)")
        return sizes
    }

    // MARK: Paletten

    @Test(.hangGuard) func paletteArtStaysCrispAndGetsSmaller() throws {
        let url = try Self.indexedPDF("art")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Self.inputImage(url).transformCapability.isSafe)
        let input = Int(Compressor.fileSize(of: url))
        let sizes = try Self.runPresets(url, label: "Palette", forbidJPEG: true)
        #expect(sizes[0] < input, "Klein spart nichts: \(sizes) von \(input)")
        #expect(sizes[1] < input, "Smart spart nichts: \(sizes) von \(input)")
    }

    /// Jede Bittiefe liest die Indizes richtig – falsch gepackt wäre die
    /// Farbe an den Feldern eine andere.
    @Test(.hangGuard, arguments: [(1, 2), (2, 4), (4, 8)]) func packedPaletteDepths(bits: Int, entries: Int) throws {
        // Rot und Weiss: mit 1 Bit bewusst nicht schwarz-weiss.
        let url = try Self.indexedPDF("bits\(bits)", bits: bits, entries: entries)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Self.inputImage(url).transformCapability.isSafe)
        try Self.runPresets(url, label: "\(bits) Bit", forbidJPEG: true)
    }

    /// Schwarz und Weiss in einer Palette: gehört in den Bilevel-Weg.
    @Test(.hangGuard) func blackWhitePaletteTakesTheBilevelRoute() throws {
        let url = try Self.indexedPDF("bw", bits: 1, entries: 2, palette: [255, 255, 255, 0, 0, 0])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let image = try Self.outputImage(result.outputURL)
        #expect(image.terminalFilter == .ccitt || image.terminalFilter == .jbig2,
                "Filter: \(String(describing: image.terminalFilter))")
        #expect(image.width == Self.width, "Bilevel wird nie resampelt")
        try Self.expectSameColours(url, result.outputURL, "S/W-Palette")
    }

    /// Bytes in Grau dürfen nicht unter /Indexed stehen bleiben.
    @Test(.hangGuard) func grayBasePaletteLosesIndexedWhenExpanded() throws {
        let table: [UInt8] = [255, 200, 150, 100, 60, 0, 120, 220]
        let url = try Self.indexedPDF("graybase", palette: table, baseSpace: "/DeviceGray")
        defer { try? FileManager.default.removeItem(at: url) }
        // Klein darf hier JPEG nehmen, wenn die Gates es zulassen (§9.5).
        try Self.runPresets(url, label: "Graue Basis", forbidJPEG: false)
    }

    /// Das Profil bleibt: AdobeRGB als sRGB gedeutet ergäbe andere Farben.
    @Test(.hangGuard) func iccBasePaletteKeepsTheProfile() throws {
        let profile = try #require(CGColorSpace(name: CGColorSpace.adobeRGB1998)?.copyICCData() as Data?)
        var iccObject = 0
        let url = try Self.indexedPDF("iccbase", baseSpace: "ICCREF") { b in
            iccObject = b.addStream(dictionary: "/N 3/Alternate/DeviceRGB", data: profile)
        }
        // Der Verweis steht erst nach dem Anlegen fest.
        var pdf = try Data(contentsOf: url)
        let placeholder = Data("ICCREF".utf8)
        let reference = Data("[/ICCBased \(iccObject) 0 R]".utf8)
        pdf = pdf.replacing(placeholder, with: reference)
        try pdf.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let input = try Self.inputImage(url)
        #expect(input.pixelColorSpace == .iccBased(components: 3))
        #expect(input.transformCapability.isSafe)
        for mode in [CompressionMode.small, .smart, .quality] {
            let result = try Compressor().compress(inputURL: url, mode: mode)
            defer { try? FileManager.default.removeItem(at: result.outputURL) }
            try Self.expectSameColours(url, result.outputURL, "ICC-Basis \(mode)")
            let output = try Self.outputImage(result.outputURL)
            #expect(output.pixelColorSpace == .iccBased(components: 3),
                    "Profil verloren: \(output.colorSpace) \(output.pixelColorSpace)")
            #expect(output.terminalFilter != .dct)
        }
    }

    @Test(.hangGuard) func cmykBasePaletteStaysFourChannel() throws {
        let table: [UInt8] = [0, 0, 0, 0, 0, 200, 200, 0, 200, 0, 200, 0, 200, 150, 0, 0,
                              0, 90, 230, 0, 0, 0, 0, 255, 0, 0, 0, 120, 0, 0, 230, 0]
        let url = try Self.indexedPDF("cmykbase", palette: table, baseSpace: "/DeviceCMYK")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Self.inputImage(url).pixelColorSpace == .deviceCMYK)
        for mode in [CompressionMode.small, .smart, .quality] {
            let result = try Compressor().compress(inputURL: url, mode: mode)
            defer { try? FileManager.default.removeItem(at: result.outputURL) }
            try Self.expectSameColours(url, result.outputURL, "CMYK-Basis \(mode)")
            let output = try Self.outputImage(result.outputURL)
            #expect(output.terminalFilter != .dct)
            #expect(output.pixelColorSpace == .deviceCMYK,
                    "CMYK-Palette wurde zu \(output.pixelColorSpace)")
        }
    }

    // MARK: Bittiefen

    @Test(.hangGuard, arguments: [2, 4]) func lowDepthGray(bits: Int) throws {
        let mask = UInt8((1 << bits) - 1)
        let values = Self.scene(entries: 8).map { UInt8($0) * mask / 7 }
        let url = try Self.document("gray\(bits)", imageDict: "/ColorSpace/DeviceGray/BitsPerComponent \(bits)/Filter/FlateDecode",
                                    data: try Self.flate(Self.packed(values, bits: bits, samplesPerRow: Self.width)))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Self.inputImage(url).transformCapability.isSafe)
        try Self.runPresets(url, label: "Grau \(bits) Bit", forbidJPEG: false)
    }

    @Test(.hangGuard) func sixteenBitRGBBecomesEightBitWithoutColourShift() throws {
        // Das niedere Byte rauscht wie bei echten 16-Bit-Daten. In falscher
        // Bytefolge gelesen wären die Felder Rauschen statt Farbe.
        var seed: UInt64 = 11
        var deep = Data(capacity: Self.width * Self.height * 6)
        for byte in Self.rgbSamples() {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            deep.append(byte); deep.append(UInt8(truncatingIfNeeded: seed >> 56))
        }
        let url = try Self.document("deep", imageDict: "/ColorSpace/DeviceRGB/BitsPerComponent 16/Filter/FlateDecode",
                                    data: try Self.flate(deep))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Self.inputImage(url).transformCapability.isSafe)
        let input = Int(Compressor.fileSize(of: url))
        let sizes = try Self.runPresets(url, label: "16 Bit", forbidJPEG: false)
        #expect(sizes.allSatisfy { $0 < input / 4 }, "\(sizes) von \(input)")
        for mode in [CompressionMode.small, .smart, .quality] {
            let result = try Compressor().compress(inputURL: url, mode: mode)
            defer { try? FileManager.default.removeItem(at: result.outputURL) }
            #expect(try Self.outputImage(result.outputURL).bitsPerComponent <= 8, "\(mode)")
        }
    }

    /// Ein konstantes unteres Byte auf hartkantigem Inhalt: Verkleinern lohnt
    /// nicht, Smart darf trotzdem nicht über Qualität liegen.
    @Test(.hangGuard) func sixteenBitWithConstantLowByteKeepsPresetOrder() throws {
        var deep = Data(capacity: Self.width * Self.height * 6)
        for byte in Self.rgbSamples() { deep.append(byte); deep.append(0xA5) }
        let url = try Self.document("deepflat", imageDict: "/ColorSpace/DeviceRGB/BitsPerComponent 16/Filter/FlateDecode",
                                    data: try Self.flate(deep))
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.runPresets(url, label: "16 Bit konstant", forbidJPEG: false)
    }

    /// Flächen wie in einem Diagramm: Der Repack ist so klein, dass Verkleinern
    /// hier nichts bringt. Dann bleibt das Bild scharf und die Folge gewahrt.
    @Test(.hangGuard) func sparsePaletteArtKeepsOrderAndStaysCrisp() throws {
        let (w, h) = (Self.width, Self.height)
        var map = [UInt8](repeating: 0, count: w * h)
        for row in 0..<14 { for column in 0..<10 {
            let (x, y) = (20 + column * 80, 20 + row * 78)
            for yy in y..<(y + 60) { for xx in x..<(x + 62) {
                map[yy * w + xx] = UInt8((row * 3 + column) % 7 + 1)
            } }
        } }
        let table = Self.rgbPalette.flatMap { [$0.0, $0.1, $0.2] }
        let url = try Self.document("sparse",
            imageDict: "/ColorSpace[/Indexed/DeviceRGB 7 \(Self.hex(table))]/BitsPerComponent 8/Filter/FlateDecode",
            data: try Self.flate(Data(map)))
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.runPresets(url, label: "Diagramm", forbidJPEG: true)
    }

    // MARK: /Decode bleibt gesperrt

    @Test(.hangGuard) func effectiveDecodeKeepsPaletteAndDeepImagesUntouched() throws {
        let palette = try Self.indexedPDF("idxdecode", extra: "/Decode[255 0]")
        defer { try? FileManager.default.removeItem(at: palette) }
        var deep = Data(capacity: Self.width * Self.height * 6)
        for byte in Self.rgbSamples() { deep.append(byte); deep.append(byte) }
        let deepURL = try Self.document("deepdecode",
            imageDict: "/ColorSpace/DeviceRGB/BitsPerComponent 16/Filter/FlateDecode/Decode[1 0 1 0 1 0]",
            data: try Self.flate(deep))
        defer { try? FileManager.default.removeItem(at: deepURL) }
        for url in [palette, deepURL] {
            let input = try Self.inputImage(url)
            #expect(input.transformCapability == .decodeArrayUnsupported)
            let result = try Compressor().compress(inputURL: url, mode: .small)
            defer { try? FileManager.default.removeItem(at: result.outputURL) }
            let output = try Self.outputImage(result.outputURL)
            #expect(output.width == input.width)
            #expect(output.decodeArray == input.decodeArray)
        }
    }

    /// Die ausgeschriebene Vorgabe bewirkt nichts und sperrt deshalb nicht.
    @Test(.hangGuard) func defaultDecodeOnPaletteStillCompresses() throws {
        let url = try Self.indexedPDF("idxdefault", extra: "/Decode[0 255]")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Self.inputImage(url).transformCapability.isSafe)
        try Self.runPresets(url, label: "Vorgabe-Decode", forbidJPEG: true)
    }

    @Test(.hangGuard) func matteOnPaletteMaskStaysUntouched() throws {
        var maskObject = 0
        let mask = try Self.flate(Data(repeating: 200, count: Self.width * Self.height))
        let url = try Self.indexedPDF("matte", extra: "/SMask SMASKREF") { b in
            maskObject = b.addStream(
                dictionary: "/Type/XObject/Subtype/Image/Width \(Self.width)/Height \(Self.height)"
                    + "/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/FlateDecode/Matte[0]",
                data: mask)
        }
        var pdf = try Data(contentsOf: url)
        pdf = pdf.replacing(Data("SMASKREF".utf8), with: Data("\(maskObject) 0 R".utf8))
        try pdf.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try Self.inputImage(url)
        #expect(!input.transformCapability.isSafe, "\(input.transformCapability)")
    }

    // MARK: JPX

    private static func jpx(_ samples: [UInt8], components: Int) throws -> Data {
        let provider = try #require(CGDataProvider(data: Data(samples) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components,
            bytesPerRow: width * components,
            space: components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "public.jpeg-2000" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test(.hangGuard) func jpxWithoutColorSpaceOrDepthCompressesInEveryPreset() throws {
        let url = try Self.document("jpxrgb", imageDict: "/Filter/JPXDecode",
                                    data: try Self.jpx(Self.rgbSamples(), components: 3))
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try Self.inputImage(url)
        #expect(input.bitsPerComponent == 0)
        #expect(input.colorSpace == .none)
        #expect(input.pixelColorSpace == .deviceRGB, "\(input.pixelColorSpace)")
        #expect(input.transformCapability.isSafe, "\(input.transformCapability.reason)")
        let before = Int(Compressor.fileSize(of: url))
        let sizes = try Self.runPresets(url, label: "JPX", forbidJPEG: false, tolerance: 6)
        #expect(sizes[0] < before && sizes[1] < before, "\(sizes) von \(before)")
    }

    @Test(.hangGuard) func jpxGrayWithoutColorSpace() throws {
        let gray = Self.scene(entries: 8).map { $0 &* 30 }
        let url = try Self.document("jpxgray", imageDict: "/Filter/JPXDecode",
                                    data: try Self.jpx(gray, components: 1))
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try Self.inputImage(url)
        #expect(input.pixelColorSpace == .deviceGray, "\(input.pixelColorSpace)")
        try Self.runPresets(url, label: "JPX Grau", forbidJPEG: false, tolerance: 6)
    }

    /// Kopfdaten, deren Farbe wir nicht benennen können, sperren.
    @Test(.hangGuard) func jp2HeaderRefusesWhatItCannotName() throws {
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let n = body.count + 8
            return [0, 0, UInt8(n >> 8), UInt8(n & 255)] + Array(type.utf8) + body
        }
        func file(components: UInt8, enumerated: UInt8, extra: [UInt8] = []) -> Data {
            let ihdr = box("ihdr", [0, 0, 0, 9, 0, 0, 0, 9, 0, components, 7, 7, 0, 0])
            let colr = box("colr", [1, 0, 0, 0, 0, 0, enumerated])
            return Data(box("jP  ", [0x0D, 0x0A, 0x87, 0x0A])
                + box("jp2h", ihdr + colr + extra) + box("jp2c", [0xFF, 0x4F]))
        }
        #expect(JPXDecoder.colorInfo(of: file(components: 3, enumerated: 16))?.space == .deviceRGB)
        #expect(JPXDecoder.colorInfo(of: file(components: 1, enumerated: 17))?.space == .deviceGray)
        #expect(JPXDecoder.colorInfo(of: file(components: 4, enumerated: 12))?.space == .deviceCMYK)
        // sYCC, CIELab, falsche Kanalzahl.
        #expect(JPXDecoder.colorInfo(of: file(components: 3, enumerated: 18)) == nil)
        #expect(JPXDecoder.colorInfo(of: file(components: 3, enumerated: 14)) == nil)
        #expect(JPXDecoder.colorInfo(of: file(components: 4, enumerated: 16)) == nil)
        // Palette und Alpha im JP2.
        #expect(JPXDecoder.colorInfo(of: file(components: 3, enumerated: 16,
                                              extra: box("pclr", [0, 2, 1, 7, 0, 0]))) == nil)
        let alpha = box("cdef", [0, 2, 0, 0, 0, 0, 0, 1, 0, 3, 0, 1, 0, 0])
        #expect(JPXDecoder.colorInfo(of: file(components: 4, enumerated: 16, extra: alpha)) == nil)
        // Nackter Codestream und abgeschnittener Kopf.
        #expect(JPXDecoder.colorInfo(of: Data([0xFF, 0x4F, 0xFF, 0x51])) == nil)
        #expect(JPXDecoder.colorInfo(of: Data(file(components: 3, enumerated: 16).prefix(30))) == nil)
    }

    // MARK: Lab, Separation, DeviceN

    private static func expectOwnSpaceKept(_ url: URL, family: String, label: String,
                                           expectSmaller: Bool = true) throws {
        let input = try inputImage(url)
        #expect(input.transformCapability.isSafe, "\(input.transformCapability.reason)")
        let before = Int(Compressor.fileSize(of: url))
        var sizes: [Int] = []
        for mode in [CompressionMode.small, .smart, .quality] {
            let result = try Compressor().compress(inputURL: url, mode: mode)
            defer { try? FileManager.default.removeItem(at: result.outputURL) }
            sizes.append(Int(Compressor.fileSize(of: result.outputURL)))
            try expectSameColours(url, result.outputURL, tolerance: 6, "\(label) \(mode)")
            let info = try #require(try PDFCoreDocument(path: result.outputURL.path).inspectImages().first)
            #expect(info.colorspace.hasPrefix(family), "\(label) \(mode): \(info.colorspace)")
            #expect(try outputImage(result.outputURL).terminalFilter == .flate,
                    "\(label) \(mode): kein Flate")
        }
        #expect(sizes[0] <= sizes[1] && sizes[1] <= sizes[2], "\(label): \(sizes)")
        if expectSmaller { #expect(sizes[0] < before, "\(label): \(sizes) von \(before)") }
    }

    @Test(.hangGuard) func labStaysLabAndKeepsItsColours() throws {
        // L*, a*, b* je Feld: farbig und mit a/b fern der Mitte.
        let triple: [[UInt8]] = [[255, 128, 128], [120, 200, 170], [150, 60, 180], [90, 170, 60],
                                 [190, 140, 220], [0, 128, 128], [130, 128, 128], [240, 120, 230]]
        let samples = Self.scene(entries: 8).flatMap { triple[Int($0)] }
        let url = try Self.document("lab",
            imageDict: "/ColorSpace[/Lab<</WhitePoint[0.9642 1 0.8249]/Range[-128 127 -128 127]>>]/BitsPerComponent 8/Filter/FlateDecode",
            data: try Self.flate(Data(samples)))
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.expectOwnSpaceKept(url, family: "Lab", label: "Lab")
    }

    @Test(.hangGuard) func labWithAnyDecodeArrayStaysUntouched() throws {
        let samples = Self.scene(entries: 8).flatMap { [$0 &* 30, 128, 128] as [UInt8] }
        let url = try Self.document("labdecode",
            imageDict: "/ColorSpace[/Lab<</WhitePoint[0.9642 1 0.8249]>>]/BitsPerComponent 8/Filter/FlateDecode/Decode[0 100 -100 100 -100 100]",
            data: try Self.flate(Data(samples)))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Self.inputImage(url).transformCapability == .decodeArrayUnsupported)
    }

    private static let spotTint = "<</FunctionType 2/Domain[0 1]/C0[0 0 0 0]/C1[0 0.9 1 0.1]/N 1>>"

    @Test(.hangGuard) func separationKeepsSpotColourAndTint() throws {
        // Ein voller Tintenanteil ist kräftig, 0 ist weiss: Wer das als Grau
        // deutet, kehrt das Bild um.
        let tints = Self.scene(entries: 8).map { $0 &* 36 }
        let url = try Self.document("separation",
            imageDict: "/ColorSpace[/Separation/Spot/DeviceCMYK \(Self.spotTint)]/BitsPerComponent 8/Filter/FlateDecode",
            data: try Self.flate(Data(tints)))
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.expectOwnSpaceKept(url, family: "Separation", label: "Separation")
    }

    private static func deviceN(_ names: [String], samples: [UInt8], label: String) throws -> URL {
        var fn = 0
        let n = names.count
        let domain = (0..<n).map { _ in "0 1" }.joined(separator: " ")
        // Summe der ersten beiden Kanäle als Magenta, Rest fest: reicht für
        // eine sichtbare, kanalabhängige Farbe. Stapel: c1 … cn → C M Y K
        let pop = String(repeating: "pop ", count: max(n - 2, 0))
        let body = "{ \(pop) 0 0 }"
        let url = try document(label,
            imageDict: "/ColorSpace[/DeviceN[\(names.map { "/" + $0 }.joined(separator: " "))]/DeviceCMYK FNREF]/BitsPerComponent 8/Filter/FlateDecode",
            data: try flate(Data(samples))) { b in
                fn = b.addStream(dictionary: "/FunctionType 4/Domain[\(domain)]/Range[0 1 0 1 0 1 0 1]",
                                 content: body)
            }
        var pdf = try Data(contentsOf: url)
        pdf = pdf.replacing(Data("FNREF".utf8), with: Data("\(fn) 0 R".utf8))
        try pdf.write(to: url)
        return url
    }

    @Test(.hangGuard) func deviceNWithRenderableChannelCountKeepsItsSpace() throws {
        let values: [[UInt8]] = [[0, 0, 0], [200, 30, 0], [30, 200, 0], [120, 120, 0],
                                 [240, 240, 0], [255, 0, 0], [0, 255, 0], [90, 180, 0]]
        let samples = Self.scene(entries: 8).flatMap { values[Int($0)] }
        let url = try Self.deviceN(["A", "B", "C"], samples: samples, label: "devn3")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Self.inputImage(url).pixelColorSpace == .ownSamples(components: 3))
        try Self.expectOwnSpaceKept(url, family: "DeviceN", label: "DeviceN 3")
    }

    /// Zwei oder fünf Kanäle passen in kein CGImage: Das Bild bleibt, wie es ist.
    @Test(.hangGuard) func deviceNWithOtherChannelCountsStaysUntouched() throws {
        let samples = Self.scene(entries: 8).flatMap { [$0 &* 30, 255 &- $0 &* 30] as [UInt8] }
        let url = try Self.deviceN(["A", "B"], samples: samples, label: "devn2")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try Self.inputImage(url)
        #expect(!input.transformCapability.isSafe, "\(input.transformCapability)")
        let result = try Compressor().compress(inputURL: url, mode: .small)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(try Self.outputImage(result.outputURL).width == input.width)
    }

    /// Ein JPEG mit Separation käme grau und umgekehrt zurück.
    @Test(.hangGuard, arguments: [PDFColorSpaceDescriptor.lab, .separation, .deviceN, .indexed])
    func dctInForeignSpacesStaysUntouched(space: PDFColorSpaceDescriptor) {
        let resource = PDFImageResource(
            objectID: PDFObjectID(objectNumber: 1, generation: 0), width: 100, height: 100,
            bitsPerComponent: 8, colorSpace: space, filters: [.dct], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            encodedByteCount: 1000, placements: [])
        #expect(!resource.transformCapability.isSafe)
    }

    // MARK: Zweiter Lauf

    @Test(.hangGuard) func secondRunDoesNotErode() throws {
        let url = try Self.indexedPDF("again")
        defer { try? FileManager.default.removeItem(at: url) }
        for mode in [CompressionMode.small, .smart, .quality] {
            let first = try Compressor().compress(inputURL: url, mode: mode)
            defer { try? FileManager.default.removeItem(at: first.outputURL) }
            let second = try Compressor().compress(inputURL: first.outputURL, mode: mode)
            defer { try? FileManager.default.removeItem(at: second.outputURL) }
            #expect(Int(Compressor.fileSize(of: second.outputURL)) <= Int(Compressor.fileSize(of: first.outputURL)))
            try Self.expectSameColours(url, second.outputURL, "Zweitlauf \(mode)")
            let a = try #require(PDFDocument(url: first.outputURL)?.page(at: 0)?
                .thumbnail(of: CGSize(width: 400, height: 534), for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil))
            let b = try #require(PDFDocument(url: second.outputURL)?.page(at: 0)?
                .thumbnail(of: CGSize(width: 400, height: 534), for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil))
            let ssim = QualityMetrics.ssim(original: a, candidate: b)
            #expect(ssim > 0.99, "Zweitlauf \(mode) zehrt: SSIM \(ssim)")
        }
    }

    // MARK: Abtastwerte im Einzelnen

    private static func resource(bits: Int, space: PDFColorSpaceDescriptor, base: PDFColorSpaceDescriptor? = nil,
                                 width: Int, height: Int) -> PDFImageResource {
        var r = PDFImageResource(
            objectID: PDFObjectID(objectNumber: 1, generation: 0), width: width, height: height,
            bitsPerComponent: bits, colorSpace: space, filters: [.flate], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            encodedByteCount: 10, placements: [])
        r.decodedColorSpace = base
        return r
    }

    @Test func paletteExpansionHandlesPackingAndHighIndices() throws {
        let r = Self.resource(bits: 2, space: .indexed, base: .deviceRGB, width: 3, height: 2)
        let palette = ImageSamples.Palette(highestIndex: 1, table: Data([1, 2, 3, 4, 5, 6]))
        // Zeile 1: 0, 1, 3 (3 > hival → hival); Zeile 2: 1, 0, 0. Füllbits am Ende.
        let data = Data([0b00_01_11_00, 0b01_00_00_11])
        let out = try #require(ImageSamples.normalized(data, resource: r, palette: palette))
        #expect(out == Data([1, 2, 3, 4, 5, 6, 4, 5, 6,
                             4, 5, 6, 1, 2, 3, 1, 2, 3]))
    }

    @Test func paletteTooShortOrStreamTooShortIsRefused() {
        let r = Self.resource(bits: 8, space: .indexed, base: .deviceRGB, width: 2, height: 1)
        let short = ImageSamples.Palette(highestIndex: 1, table: Data([1, 2, 3, 4]))
        let good = ImageSamples.Palette(highestIndex: 1, table: Data([1, 2, 3, 4, 5, 6]))
        #expect(ImageSamples.normalized(Data([0, 1]), resource: r, palette: short) == nil)
        #expect(ImageSamples.normalized(Data([0]), resource: r, palette: good) == nil)
        #expect(ImageSamples.normalized(Data([0, 1]), resource: r, palette: nil) == nil)
    }

    @Test func sixteenBitRoundsAndKeepsEndpoints() throws {
        let r = Self.resource(bits: 16, space: .deviceGray, width: 4, height: 1)
        let data = Data([0x00, 0x00, 0xFF, 0xFF, 0x80, 0x00, 0x12, 0xFF])
        let out = try #require(ImageSamples.normalized(data, resource: r, palette: nil))
        #expect(out == Data([0, 255, 128, 0x13]))
    }

    @Test func lowDepthStretchesToFullRange() throws {
        let r = Self.resource(bits: 4, space: .deviceGray, width: 3, height: 1)
        let out = try #require(ImageSamples.normalized(Data([0x0F, 0x80]), resource: r, palette: nil))
        #expect(out == Data([0, 255, 136]))
    }

    @Test func oneBitGrayStaysWithTheBilevelPolicy() {
        let r = Self.resource(bits: 1, space: .deviceGray, width: 100, height: 100)
        #expect(r.transformCapability == .unsupportedBitDepth(1))
    }

    @Test func colorSpaceNamesWithCountsAreRecognized() {
        #expect(PDFColorSpaceDescriptor(rawName: "CalRGB:3") == .calRGB)
        #expect(PDFColorSpaceDescriptor(rawName: "CalGray:1") == .calGray)
        #expect(PDFColorSpaceDescriptor(rawName: "Lab:3") == .lab)
        #expect(PDFColorSpaceDescriptor(rawName: "Separation:1") == .separation)
        #expect(PDFColorSpaceDescriptor(rawName: "DeviceN:4") == .deviceN)
        #expect(PDFColorSpaceDescriptor(rawName: "Indexed>ICCBased:3") == .indexed)
        #expect(PDFColorSpaceDescriptor(rawName: "Indexed") == .indexed)
        #expect(PDFColorSpaceDescriptor(rawName: "ICCBased:4") == .iccBased(components: 4))
    }
}

private extension Data {
    func replacing(_ old: Data, with new: Data) -> Data {
        var out = self
        while let range = out.range(of: old) { out.replaceSubrange(range, with: new) }
        return out
    }
}
