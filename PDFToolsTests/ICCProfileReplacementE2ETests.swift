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
}
