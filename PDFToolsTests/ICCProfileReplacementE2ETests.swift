import Testing
import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import PDFTools

/// Masterplan A4: ICC-Profil beim JPEG-Ersatz.
///
/// Verdacht: Ein Profil, das nur im PDF steht (`/ICCBased`, das JPEG selbst
/// trägt keins), wird beim Dekodieren nie angewendet. Die Pixel bleiben
/// Display-P3-Werte, die Ausgabe nennt sie `/DeviceRGB` – gesättigte Farben
/// werden blasser.
///
/// Abnahme laut Plan: ΔE76 zwischen Original und Ausgabe (beide nach sRGB
/// gerendert) unter 2 im Mittel der Farbflächen.
///
/// Fehlermöglichkeiten: (1) das Profil wird ignoriert (große ΔE); (2) das
/// Profil wird doppelt angewendet (Ausgabe nennt weiter P3, Pixel schon sRGB);
/// (3) die Ausgabe wird größer als das Original (Ersatz lohnt nicht).
@MainActor
@Suite(.serialized) struct ICCProfileReplacementE2ETests {

    /// Zwei Farbflächen (P3-Rot, P3-Grün) mit leichtem Rauschen, JPEG ohne
    /// eigenes Profil, im PDF als [/ICCBased <Display-P3>] beschrieben.
    static func p3Document() throws -> URL {
        let w = 1800, h = 1200
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 7
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 1_103_515_245 &+ 12_345
                let noise = Int((seed >> 16) % 9) - 4
                let i = (y * w + x) * 4
                let left = x < w / 2
                pixels[i] = UInt8(clamping: (left ? 235 : 20) + noise)
                pixels[i + 1] = UInt8(clamping: (left ? 20 : 220) + noise)
                pixels[i + 2] = UInt8(clamping: 30 + noise)
                pixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let jpeg = NSMutableData()
        let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.97] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let icc = try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?)
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let profile = b.addStream(dictionary: "/N 3", data: icc)
        let img = b.addStream(dictionary: "/Type/XObject/Subtype/Image/Width \(w)/Height \(h)/BitsPerComponent 8"
            + "/ColorSpace[/ICCBased \(profile) 0 R]/Filter/DCTDecode", data: jpeg as Data)
        let content = b.addStream(dictionary: "", content: "q 600 0 0 400 0 0 cm /Im0 Do Q")
        let page = b.addPage(parent: pages, mediaBox: "[0 0 600 400]",
                             resources: "<</XObject<</Im0 \(img) 0 R>>>>", contents: content)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "a4-p3")
    }

    /// Mittlere Farbe einer Fläche (Anteile der Seite) nach sRGB gerendert, als Lab.
    static func meanLab(_ url: URL, region: CGRect) throws -> (Double, Double, Double) {
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let w = 600, h = 400
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        page.draw(with: .mediaBox, to: ctx)
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var sum = (0.0, 0.0, 0.0), n = 0.0
        for y in Int(region.minY * Double(h))..<Int(region.maxY * Double(h)) {
            for x in Int(region.minX * Double(w))..<Int(region.maxX * Double(w)) {
                let i = (y * w + x) * 4
                sum.0 += Double(data[i]); sum.1 += Double(data[i + 1]); sum.2 += Double(data[i + 2]); n += 1
            }
        }
        return lab(sum.0 / n / 255, sum.1 / n / 255, sum.2 / n / 255)
    }

    static func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (R, G, B) = (lin(r), lin(g), lin(b))
        let X = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let Z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
        return (116 * f(Y) - 16, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z)))
    }

    @Test func profilImPDFWirdBeimErsatzAngewendet() async throws {
        let input = try Self.p3Document()
        defer { try? FileManager.default.removeItem(at: input) }
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.mode = .small
        vm.select(input)
        vm.compress()
        #expect(await PasswordUnlockE2ETests.within(180) { vm.pendingResult != nil || vm.errorMessage != nil })
        let result = try #require(vm.pendingResult, "\(vm.errorMessage ?? "")")
        defer { vm.discardPending() }
        #expect(!result.returnedOriginal, "Bild wurde nicht ersetzt – Test misst nichts")
        #expect(result.outputBytes < result.inputBytes)
        // Die Ausgabe nennt ihr Profil (sRGB) statt /DeviceRGB.
        let replaced = try #require(try PDFCoreDocument(path: result.outputURL.path).imageResources().first)
        #expect(replaced.colorSpace == .iccBased(components: 3), "Farbraum der Ausgabe: \(replaced.colorSpace)")

        for region in [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.6),
                       CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.6)] {
            let a = try Self.meanLab(input, region: region)
            let o = try Self.meanLab(result.outputURL, region: region)
            let dE = ((a.0 - o.0) * (a.0 - o.0) + (a.1 - o.1) * (a.1 - o.1) + (a.2 - o.2) * (a.2 - o.2)).squareRoot()
            #expect(dE < 2, "ΔE76 \(dE) in \(region) – Original \(a), Ausgabe \(o)")
        }
    }

    // MARK: Masterplan N5 – Farben außerhalb von sRGB

    enum SourceFilter: String, CaseIterable, Sendable { case dct, unfiltered }

    /// Gesättigte Display-P3-Flächen am Rand des P3-Umfangs (Rot, Grün) –
    /// außerhalb von sRGB. 2400 × 1600 px auf 600 × 400 pt (288 DPI), damit
    /// jede Stufe verkleinert und das Bild wirklich ersetzt.
    static func p3EdgeDocument(_ filter: SourceFilter) throws -> URL {
        let w = 2400, h = 1600
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        var seed: UInt32 = 11
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 1_103_515_245 &+ 12_345
                let noise = Int((seed >> 16) % 7) - 3
                let i = (y * w + x) * 3
                let left = x < w / 2
                rgb[i] = UInt8(clamping: (left ? 252 : 4) + noise)
                rgb[i + 1] = UInt8(clamping: (left ? 4 : 252) + noise)
                rgb[i + 2] = UInt8(clamping: 4 + noise)
            }
        }
        let icc = try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?)
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let profile = b.addStream(dictionary: "/N 3", data: icc)
        let head = "/Type/XObject/Subtype/Image/Width \(w)/Height \(h)/BitsPerComponent 8"
            + "/ColorSpace[/ICCBased \(profile) 0 R]"
        let img: Int
        switch filter {
        case .dct:
            let provider = CGDataProvider(data: Data(rgb) as CFData)!
            let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent)!
            let jpeg = NSMutableData()
            let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.97] as CFDictionary)
            #expect(CGImageDestinationFinalize(dest))
            img = b.addStream(dictionary: head + "/Filter/DCTDecode", data: jpeg as Data)
        case .unfiltered:
            img = b.addStream(dictionary: head, data: Data(rgb))
        }
        let content = b.addStream(dictionary: "", content: "q 600 0 0 400 0 0 cm /Im0 Do Q")
        let page = b.addPage(parent: pages, mediaBox: "[0 0 600 400]",
                             resources: "<</XObject<</Im0 \(img) 0 R>>>>", contents: content)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "n5-p3-\(filter.rawValue)")
    }

    /// Mittlere Farbe einer Fläche, in ein Display-P3-Raster gerendert, als
    /// Lab (D65). In sRGB gerendert wäre der Verlust unsichtbar: Beide
    /// Seiten würden auf den sRGB-Rand abgeschnitten.
    static func meanLabP3(_ url: URL, region: CGRect) throws -> (Double, Double, Double) {
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let w = 600, h = 400
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        page.draw(with: .mediaBox, to: ctx)
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var sum = (0.0, 0.0, 0.0), n = 0.0
        for y in Int(region.minY * Double(h))..<Int(region.maxY * Double(h)) {
            for x in Int(region.minX * Double(w))..<Int(region.maxX * Double(w)) {
                let i = (y * w + x) * 4
                sum.0 += lin(Double(data[i]) / 255)
                sum.1 += lin(Double(data[i + 1]) / 255)
                sum.2 += lin(Double(data[i + 2]) / 255)
                n += 1
            }
        }
        let (R, G, B) = (sum.0 / n, sum.1 / n, sum.2 / n)
        // Display P3 (D65) → XYZ
        let X = (0.4866 * R + 0.2657 * G + 0.1982 * B) / 0.95047
        let Y = 0.2290 * R + 0.6917 * G + 0.0793 * B
        let Z = (0.0451 * G + 1.0439 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
        return (116 * f(Y) - 16, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z)))
    }

    /// Masterplan N5: A4 rechnete die Pixel beim Dekodieren nach sRGB um –
    /// alles außerhalb von sRGB ging verloren, in jeder Stufe, auch beim
    /// verlustfreien Ersatz. Seit N5 bleiben Profil und Originalwerte der
    /// Quelle. Abnahme: ΔE76 unter 2 im P3-Rendering, Farbraum der Ausgabe
    /// weiter das Quellprofil (dreikanalig ICC).
    @Test(arguments: [CompressionMode.small, .smart, .quality], SourceFilter.allCases)
    func p3FarbenAusserhalbVonSRGBBleiben(_ mode: CompressionMode, _ filter: SourceFilter) async throws {
        let input = try Self.p3EdgeDocument(filter)
        defer { try? FileManager.default.removeItem(at: input) }
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.mode = mode
        vm.select(input)
        vm.compress()
        #expect(await PasswordUnlockE2ETests.within(240) { vm.pendingResult != nil || vm.errorMessage != nil })
        let result = try #require(vm.pendingResult, "\(vm.errorMessage ?? "")")
        defer { vm.discardPending() }
        #expect(!result.returnedOriginal, "Bild wurde nicht ersetzt – Test misst nichts (\(mode), \(filter))")
        // Auch eine Palette (Smart wählt sie bei wenigen Farben) behält das
        // Profil – als Basis von /Indexed.
        let replaced = try #require(try PDFCoreDocument(path: result.outputURL.path).imageResources().first)
        #expect(replaced.pixelColorSpace == .iccBased(components: 3),
                "Farbraum der Ausgabe: \(replaced.colorSpace) / \(replaced.pixelColorSpace)")
        for region in [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.6),
                       CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.6)] {
            let a = try Self.meanLabP3(input, region: region)
            let o = try Self.meanLabP3(result.outputURL, region: region)
            let dE = ((a.0 - o.0) * (a.0 - o.0) + (a.1 - o.1) * (a.1 - o.1) + (a.2 - o.2) * (a.2 - o.2)).squareRoot()
            #expect(dE < 2, "\(mode) \(filter): ΔE76 \(dE) in \(region) – Original \(a), Ausgabe \(o)")
        }
    }
}
