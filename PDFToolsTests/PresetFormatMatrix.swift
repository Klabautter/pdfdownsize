import AppKit
import ImageIO
import Testing
import Foundation
import UniformTypeIdentifiers
@testable import PDFTools

/// Welche Bildformate reagieren auf die Stufen?
///
/// Der Korpus enthält kaum vollseitige Farbscans und keine übergroßen Seiten;
/// deshalb fiel lange nicht auf, dass Klein, Smart und Qualität dort dasselbe
/// lieferten. Diese Messung baut jedes Format gezielt und schreibt je Stufe
/// die Ausgabegröße in eine Tabelle. Sie läuft nur auf Anforderung:
///
///     TEST_RUNNER_PDFTOOLS_PRESET_MATRIX=<ausgabe.tsv> xcodebuild test …
///         -only-testing:PDFToolsTests/PresetFormatMatrix
@Suite(.serialized) struct PresetFormatMatrix {

    private struct Stream { let dict: String; let data: Data }

    /// Weiches Motiv mit leichtem Rauschen: Foto-Charakter, gut komprimierbar.
    private static func sample(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ seed: inout UInt64) -> (Double, Double, Double) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let n = Double((seed >> 40) % 12) / 255
        let u = Double(x) / Double(w), v = Double(y) / Double(h)
        return (min(1, 0.5 + 0.4 * sin(u * 19) * cos(v * 13) + n),
                min(1, 0.5 + 0.4 * cos(u * 7 + v * 11) + n),
                min(1, 0.5 + 0.4 * sin(v * 23) + n))
    }

    private static func raw(_ w: Int, _ h: Int, components: Int) -> Data {
        var out = Data(capacity: w * h * components)
        var seed: UInt64 = 42
        for y in 0..<h { for x in 0..<w {
            let (r, g, b) = sample(x, y, w, h, &seed)
            switch components {
            case 1: out.append(UInt8(255 * (r + g + b) / 3))
            case 3: out.append(UInt8(255 * r)); out.append(UInt8(255 * g)); out.append(UInt8(255 * b))
            default: out.append(UInt8(255 * (1 - r))); out.append(UInt8(255 * (1 - g)))
                out.append(UInt8(255 * (1 - b))); out.append(0)
            }
        } }
        return out
    }

    private static func encoded(_ w: Int, _ h: Int, components: Int, type: UTType, quality: Double = 0.92) throws -> Data {
        let pixels = raw(w, h, components: components)
        let space: CGColorSpace = components == 1 ? CGColorSpaceCreateDeviceGray()
            : components == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceCMYK()
        let image = try #require(CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * components,
            bytesPerRow: w * components, space: space, bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private static func flate(_ data: Data) throws -> Data { try #require(ImageProcessor.flate(data)) }

    private static func imageDict(_ w: Int, _ h: Int, _ rest: String) -> String {
        "/Type/XObject/Subtype/Image/Width \(w)/Height \(h)\(rest)"
    }

    /// Ein Bild auf einer Seite; das Bild deckt 56 % der Seite, damit keine
    /// Scan-Regel greift. `scale` setzt die Platzierung in pt.
    private static func document(_ name: String, image: Stream, extra: [Stream] = [], placed: (Double, Double) = (300, 400),
                                 page: (Double, Double) = (400, 533), pageExtra: String = "",
                                 content: String? = nil, resources: String? = nil, wrap: ((inout RawPDFBuilder, Int) -> String)? = nil) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var dict = image.dict
        if let first = extra.first {
            let mask = b.addStream(dictionary: first.dict, data: first.data)
            dict += "/SMask \(mask) 0 R"
        }
        let imageRef = b.addStream(dictionary: dict, data: image.data)
        let res = resources?.replacingOccurrences(of: "IMG", with: "\(imageRef)")
            ?? "<</XObject<</Im0 \(imageRef) 0 R>>>>"
        let stream = b.addStream(dictionary: "",
            content: content ?? "q \(placed.0) 0 0 \(placed.1) 0 0 cm /Im0 Do Q")
        let additional = wrap?(&b, imageRef) ?? ""
        let p = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 \(page.0) \(page.1)]\(pageExtra)"
            + (additional.hasPrefix("/Resources") ? "" : "/Resources\(res)")
            + "/Contents \(stream) 0 R\(additional)>>")
        b.fill(pages, "<</Type/Pages/Kids[\(p) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = PDFFixtures.fixtureURL(prefix: "matrix-\(name)")
        try b.build(rootObject: root).write(to: url)
        return url
    }

    @Test(.measurementRun) func measure() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PDFTOOLS_PRESET_MATRIX"], !path.isEmpty else { return }

        let (w, h) = (1667, 2222) // 400 DPI auf 300 × 400 pt
        let rgb = "/ColorSpace/DeviceRGB/BitsPerComponent 8"
        let jpegRGB = try Self.encoded(w, h, components: 3, type: .jpeg)
        func jpeg400() -> Stream { Stream(dict: Self.imageDict(w, h, rgb + "/Filter/DCTDecode"), data: jpegRGB) }
        let flateRGB = try Self.flate(Self.raw(w, h, components: 3))

        var cases: [(String, () throws -> URL)] = []
        func add(_ name: String, _ make: @escaping () throws -> URL) { cases.append((name, make)) }

        add("jpeg-rgb-400dpi") { try Self.document("jpeg400", image: jpeg400()) }
        add("jpeg-rgb-200dpi") { try Self.document("jpeg200", image: jpeg400(), placed: (600, 800), page: (800, 1066)) }
        add("jpeg-rgb-100dpi") { try Self.document("jpeg100", image: jpeg400(), placed: (1200, 1600), page: (1600, 2133)) }
        add("jpeg-gray-400dpi") { try Self.document("gray", image: Stream(
            dict: Self.imageDict(w, h, "/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/DCTDecode"),
            data: try Self.encoded(w, h, components: 1, type: .jpeg))) }
        add("flate-rgb-400dpi") { try Self.document("flate", image: Stream(
            dict: Self.imageDict(w, h, rgb + "/Filter/FlateDecode"), data: flateRGB)) }
        add("flate-rgb-icc-400dpi") { try PDFFixtures.iccProfilePDF(pixelWidth: w, name: "matrix-icc") }
        add("flate-gray-200dpi") { try Self.document("flategray", image: Stream(
            dict: Self.imageDict(w, h, "/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/FlateDecode"),
            data: try Self.flate(Self.raw(w, h, components: 1))), placed: (600, 800), page: (800, 1066)) }
        add("jpx-rgb-400dpi") { try Self.document("jpx", image: Stream(
            dict: Self.imageDict(w, h, rgb + "/Filter/JPXDecode"),
            data: try Self.encoded(w, h, components: 3, type: UTType("public.jpeg-2000")!))) }
        add("jpx-ohne-farbraum-400dpi") { try Self.document("jpxnocs", image: Stream(
            dict: Self.imageDict(w, h, "/Filter/JPXDecode"),
            data: try Self.encoded(w, h, components: 3, type: UTType("public.jpeg-2000")!))) }
        add("jpeg-cmyk-400dpi") { try Self.document("cmyk", image: Stream(
            dict: Self.imageDict(w, h, "/ColorSpace/DeviceCMYK/BitsPerComponent 8/Filter/DCTDecode"),
            data: try Self.encoded(w, h, components: 4, type: .jpeg))) }
        add("jpeg-cmyk-300dpi") { try Self.document("cmyk300", image: Stream(
            dict: Self.imageDict(w, h, "/ColorSpace/DeviceCMYK/BitsPerComponent 8/Filter/DCTDecode"),
            data: try Self.encoded(w, h, components: 4, type: .jpeg)), placed: (400, 533), page: (533, 711)) }
        add("indexed-flate-400dpi") {
            let gray = Self.raw(w, h, components: 1)
            let lookup = (0..<256).map { String(format: "%02X%02X%02X", $0, 255 - $0, $0 / 2) }.joined()
            return try Self.document("indexed", image: Stream(
                dict: Self.imageDict(w, h, "/ColorSpace[/Indexed/DeviceRGB 255<\(lookup)>]/BitsPerComponent 8/Filter/FlateDecode"),
                data: try Self.flate(gray)))
        }
        add("flate-rgb-16bit-400dpi") {
            var deep = Data(capacity: w * h * 6)
            for byte in Self.raw(w, h, components: 3) { deep.append(byte); deep.append(byte) }
            return try Self.document("deep", image: Stream(
                dict: Self.imageDict(w, h, "/ColorSpace/DeviceRGB/BitsPerComponent 16/Filter/FlateDecode"),
                data: try Self.flate(deep)))
        }
        add("bilevel-flate-1200dpi") {
            let (bw, bh) = (5000, 6666)
            let row = (bw + 7) / 8
            var bits = Data(repeating: 0xFF, count: row * bh)
            bits.withUnsafeMutableBytes { p in
                for y in stride(from: 0, to: bh, by: 40) { for x in 0..<row where (x + y / 40) % 7 < 3 { for t in 0..<14 { p[(y + t) * row + x] = 0 } } }
            }
            return try Self.document("bilevel", image: Stream(
                dict: Self.imageDict(bw, bh, "/ColorSpace/DeviceGray/BitsPerComponent 1/Filter/FlateDecode"),
                data: try Self.flate(bits)))
        }
        add("jpeg-mit-smask-400dpi") { try Self.document("smask", image: jpeg400(), extra: [Stream(
            dict: Self.imageDict(w, h, "/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/FlateDecode"),
            data: try Self.flate(Self.raw(w, h, components: 1)))]) }
        add("jpeg-schmal-kacheln-64") {
            // 32 × 32 Kacheln zu je 64 px: Summe wie ein 4-MP-Bild.
            let tile = try Self.encoded(64, 64, components: 3, type: .jpeg, quality: 1.0)
            var b = RawPDFBuilder()
            let pages = b.reserveNumber()
            var res = "", ops = ""
            for row in 0..<32 { for col in 0..<32 {
                let n = b.addStream(dictionary: Self.imageDict(64, 64, rgb + "/Filter/DCTDecode") , data: tile + Data(repeating: UInt8((row * 32 + col) & 255), count: 1))
                res += "/T\(row)x\(col) \(n) 0 R"
                ops += "q 11.52 0 0 11.52 \(Double(col) * 11.52) \(Double(row) * 11.52) cm /T\(row)x\(col) Do Q\n"
            } }
            let s = b.addStream(dictionary: "", content: ops)
            let p = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 400 533]/Resources<</XObject<<\(res)>>>>/Contents \(s) 0 R>>")
            b.fill(pages, "<</Type/Pages/Kids[\(p) 0 R]/Count 1>>")
            let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
            let url = PDFFixtures.fixtureURL(prefix: "matrix-tiles")
            try b.build(rootObject: root).write(to: url)
            return url
        }
        add("jpeg-60mp-handyfoto") {
            let (bw, bh) = (9000, 6700)
            return try Self.document("huge", image: Stream(
                dict: Self.imageDict(bw, bh, rgb + "/Filter/DCTDecode"),
                data: try Self.encoded(bw, bh, components: 3, type: .jpeg, quality: 0.8)),
                placed: (500, 372), page: (595, 842))
        }
        add("musterfuellung-jpeg") { try Self.document("pattern", image: jpeg400(),
            content: "/Pattern cs /P0 scn 0 0 300 400 re f",
            resources: "<<>>",
            wrap: { b, img in
                let pattern = b.addStream(dictionary: "/Type/Pattern/PatternType 1/PaintType 1/TilingType 1/BBox[0 0 300 400]/XStep 300/YStep 400/Resources<</XObject<</Im0 \(img) 0 R>>>>",
                                          content: "q 300 0 0 400 0 0 cm /Im0 Do Q")
                return "/Resources<</Pattern<</P0 \(pattern) 0 R>>>>"
            }) }
        add("stempel-annotation-jpeg") { try Self.document("annot", image: jpeg400(),
            content: "q Q", resources: "<<>>",
            wrap: { b, img in
                let ap = b.addStream(dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 300 400]/Resources<</XObject<</Im0 \(img) 0 R>>>>",
                                     content: "q 300 0 0 400 0 0 cm /Im0 Do Q")
                return "/Annots[<</Type/Annot/Subtype/Stamp/Rect[0 0 300 400]/AP<</N \(ap) 0 R>>>>]"
            }) }
        add("userunit-2-jpeg") { try Self.document("userunit", image: jpeg400(), pageExtra: "/UserUnit 2") }
        add("nur-text") { try PDFFixtures.textPDF(lines: 400, name: "matrix-text") }

        var rows = ["fall\teingabe\tklein\tsmart\tqualitaet\tgleich\tkeep_klein\tkeep_smart\tkeep_qualitaet\tfehler"]
        let only = env["PDFTOOLS_PRESET_MATRIX_ONLY"]?.split(separator: ",").map(String.init)
        for (name, make) in cases where only?.contains(name) ?? true {
            var cells = [name]
            var problems: [String] = []
            do {
                let url = try make()
                cells.append("\(Compressor.fileSize(of: url))")
                var sizes: [Int64] = [], reasons: [String] = []
                for (mode, image) in [(CompressionMode.small, ImageCompressionOptions.small),
                                      (.smart, .smart), (.quality, .quality)] {
                    do {
                        let out = try Compressor().compress(inputURL: url, mode: mode).outputURL
                        sizes.append(Int64(Compressor.fileSize(of: out)))
                    } catch { sizes.append(-1); problems.append("\(mode): \(error)") }
                    if let planned = try? CompressionPipeline.plan(inputURL: url, options: CompressionOptions(image: image)) {
                        let keeps = planned.plan.actions.compactMap { action -> String? in
                            if case .keep(_, let reason, _) = action { return "\(reason)" }
                            return nil
                        }
                        reasons.append(keeps.isEmpty ? "-" : Set(keeps).sorted().joined(separator: ",").prefix(70).description)
                    } else { reasons.append("planfehler") }
                }
                cells += sizes.map(String.init)
                cells.append(Set(sizes).count == 1 ? "ALLE" : sizes[1] == sizes[2] ? "S=Q" : sizes[0] == sizes[1] ? "K=S" : "nein")
                cells += reasons
            } catch { problems.append("fixture: \(error)") }
            cells.append(problems.joined(separator: " | "))
            rows.append(cells.joined(separator: "\t"))
            try rows.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
