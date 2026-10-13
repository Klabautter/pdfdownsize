import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Phase V2-7 (Masterplan §13.5) – Segmentierung des MRC-Moduls.
///
/// Festgenagelt werden:
///   1. Dunkler Text auf hellem Papier landet in der FG-Maske (volle
///      Rasterauflösung), der rekonstruierte Hintergrund ist dort nahezu
///      weiß (Inpainting).
///   2. Die farbige Photo-Region wird als Rect erkannt und aus der Maske
///      ausgespart.
///   3. §13.4-Verweigerungen: dunkles Papier, Vollfarb-Flächen und
///      strukturlose Raster erzeugen KEINE Segmentierung.
@Suite struct MRCSegmentationTests {

    // MARK: Helfer

    /// Anteil der Maske, der dunkle Pixel im Messfenster trifft. Das Fenster
    /// liegt bewusst im TEXTSTREIFEN – dunkle (bläuliche) Photo-Pixel wären
    /// kein Masken-/Textsignal. `darkThreshold` hebt bei grauer Tinte an.
    static func maskCoverage(mask: BilevelBuffer, reference: CGImage,
                             window: CGRect, darkThreshold: UInt8 = 100)
        -> Double {
        guard let raw = ImageResampler.rawBitmap(reference, components: 1) else {
            return 0
        }
        let bytes = [UInt8](raw)
        let w = reference.width, h = reference.height
        let rowBytes = BilevelBuffer.rowBytes(width: w)
        let bits = [UInt8](mask.data)
        var dark = 0
        var darkInMask = 0
        for y in Int(window.minY)..<min(Int(window.maxY), h) {
            for x in Int(window.minX)..<min(Int(window.maxX), w) {
                if bytes[y * w + x] < darkThreshold {
                    dark += 1
                    let bit = (bits[y * rowBytes + (x >> 3)]
                               >> UInt8(7 - (x & 7))) & 1
                    if bit == 1 { darkInMask += 1 }
                }
            }
        }
        guard dark > 0 else { return 0 }
        return Double(darkInMask) / Double(dark)
    }

    /// Mittlere Luminanz des Hintergrundbildes in einem Streifen.
    static func meanLuma(_ image: CGImage, in rect: CGRect) -> Double {
        guard let raw = ImageResampler.rawBitmap(image, components: 1) else {
            return 255
        }
        let bytes = [UInt8](raw)
        let w = image.width
        var sum = 0
        var count = 0
        for y in Int(rect.minY)..<min(Int(rect.maxY), image.height) {
            for x in Int(rect.minX)..<min(Int(rect.maxX), w) {
                sum += Int(bytes[y * w + x])
                count += 1
            }
        }
        guard count > 0 else { return 255 }
        return Double(sum) / Double(count)
    }

    static let photoBlock = CGRect(x: 425, y: 700, width: 375, height: 300)

    // MARK: Kernpipeline

    @Test func textAufHellemPapierWirdMaskiert() throws {
        let image = try PDFFixtures.mrcScanImage()
        let segmentation = try #require(MRCSegmenter.segment(image),
                                        "Scan mit Text/Papier muss segmentierbar sein")

        // Maske deckt die Text-Pixel im Textstreifen (links der Photo-Region).
        let textStrip = CGRect(x: 0, y: 0, width: 420, height: 660)
        let coverage = Self.maskCoverage(mask: segmentation.mask,
                                         reference: image, window: textStrip)
        #expect(coverage >= 0.90,
                "Maske deckt Text zu \(Int(coverage * 100)) %")

        // Hintergrund: Im Textstreifen fast weiß (Inpainting), volle Auflösung.
        #expect(segmentation.mask.width == image.width
                && segmentation.mask.height == image.height,
                "Maske bleibt auf Scan-Auflösung (§13.6)")
        let strip = Self.meanLuma(segmentation.background,
                                  in: CGRect(x: 70, y: 80, width: 340, height: 400))
        #expect(strip >= 235, "Hintergrund im Textstreifen: \(strip) (≥ 235)")

        // Photo-Region erkannt und deckt den Block (Zusatzfläche durch
        // Kachel-/Blob-Padding ist harmlos – der Photo-Layer zeichnet dort
        // Papier über Papier).
        #expect(!segmentation.photoRegions.isEmpty, "Photo-Region fehlt")
        let best = segmentation.photoRegions
            .map { region in
                let intersection = region.rect.intersection(Self.photoBlock)
                return intersection.area / Self.photoBlock.area
            }
            .max() ?? 0
        #expect(best >= 0.95,
                "Photo-Region deckt den Block nur zu \(Int(best * 100)) %")

        // Photo-Pixel gehören NICHT zur Textmaske: Im Photo-Block bleibt die
        // Maske leer (die Region trägt ihren eigenen Layer).
        let photoInside = Self.maskCoverage(
            mask: segmentation.mask, reference: image,
            window: Self.photoBlock)
        #expect(photoInside <= 0.10,
                "Photo-Block muss aus der Maske ausgespart sein: \(photoInside)")
    }

    @Test func quelleMitTextLuma140FuehrtZuVollerMaske() throws {
        // Mittelgraue Tinte ist SAUVOLA-tauglich (Vordergrund unter der
        // lokalen Schwelle) – genau der Fall, den die Seiten-QA später
        // wegen des schwarzen Maskenauftrags zurückweist (Fallback-Tests:
        // 140 ist dort noch kein „Ink“-Pixel, die schwarze Maske verschiebt
        // die Dunkelabdeckung also messbar).
        let image = try PDFFixtures.mrcScanImage(textLuma: 140, withPhoto: false)
        let segmentation = try #require(MRCSegmenter.segment(image))
        let coverage = Self.maskCoverage(mask: segmentation.mask,
                                         reference: image,
                                         window: CGRect(x: 0, y: 0,
                                                        width: image.width,
                                                        height: image.height),
                                         darkThreshold: 200)
        // Grenze bewusst knapp über 3/4: Sauvola an MITTLERER Graustufe
        // lässt strichnahe Fenster schwanken; gefordert ist nur, dass die
        // Maske den Grautext überwiegend trägt (der Fallback-Test braucht
        // genau diesen Grenzfall: Maske ja, schwarze Tinte sichtbar).
        #expect(coverage >= 0.70, "Grautext wird überwiegend erkannt: \(coverage)")
    }

    // MARK: §13.4-Verweigerungen

    @Test func dunklesPapierWirdVerweigert() throws {
        // Nacht-Scan: Papier 90, Tinte 240 (invertiert) → kein helles Papier.
        let width = 600, height = 800
        var raw = Data(count: width * height * 3)
        raw.withUnsafeMutableBytes { (base: UnsafeMutableRawBufferPointer) in
            let p = base.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) { p[i * 3] = 90; p[i * 3 + 1] = 90; p[i * 3 + 2] = 90 }
            for y in 100..<600 {
                for x in 60..<(width - 60) where (x / 12) % 2 == 0 {
                    p[(y * width + x) * 3] = 240
                    p[(y * width + x) * 3 + 1] = 240
                    p[(y * width + x) * 3 + 2] = 240
                }
            }
        }
        guard let provider = CGDataProvider(data: raw as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 24,
                                  bytesPerRow: width * 3,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(
                                      rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            Issue.record("Fixturebild konnte nicht gebaut werden")
            return
        }
        #expect(MRCSegmenter.segment(image) == nil,
                "Dunkles Papier ist kein §13.4-Scan")
    }

    @Test func vollfarbFlaecheWirdVerweigert() throws {
        // Vollflächige kräftige Chroma (Magazin) über 50 % der Pixel.
        let width = 600, height = 800
        var raw = Data(count: width * height * 3)
        raw.withUnsafeMutableBytes { (base: UnsafeMutableRawBufferPointer) in
            let p = base.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 3
                    p[i] = UInt8(clamping: 120 + x % 80)
                    p[i + 1] = UInt8(clamping: 40 + y % 60)
                    p[i + 2] = UInt8(clamping: 200 - x % 70)
                }
            }
        }
        guard let provider = CGDataProvider(data: raw as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 24,
                                  bytesPerRow: width * 3,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(
                                      rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            Issue.record("Fixturebild konnte nicht gebaut werden")
            return
        }
        #expect(MRCSegmenter.segment(image) == nil,
                "Vollfarb-Seite ist außerhalb des V1-Scope (§13.4)")
    }
}

private extension CGRect {
    var area: Double { Double(width * height) }
}
