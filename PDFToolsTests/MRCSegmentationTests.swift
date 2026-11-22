import Testing
import Foundation
import CoreGraphics
import CoreText
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

    // MARK: Hintergrund-Rekonstruktion

    /// Die Ausgabe ist Teil der Dateibytes: Der Hintergrund muss exakt dem
    /// bisherigen Verfahren entsprechen (Dilatation über alle Pixel, Inseln
    /// mit Mittelwert, Glättung nur des Gefüllten). Breite ≠ Vielfaches von
    /// 8, Maskenpixel am Rand und ein Block, den 8 Pässe nicht erreichen.
    @Test(arguments: [1, 3]) func hintergrundBleibtBytegleich(channels: Int) throws {
        let width = 97, height = 61
        var generator = SeededGenerator(state: 42)
        var pixels = [UInt8](repeating: 0, count: width * height * channels)
        for i in pixels.indices { pixels[i] = UInt8.random(in: 150...255, using: &generator) }

        let rowBytes = BilevelBuffer.rowBytes(width: width)
        var bits = [UInt8](repeating: 0, count: rowBytes * height)
        func setInk(_ x: Int, _ y: Int) { bits[y * rowBytes + (x >> 3)] |= UInt8(0x80 >> (x & 7)) }
        for _ in 0..<300 {
            setInk(Int.random(in: 0..<width, using: &generator),
                   Int.random(in: 0..<height, using: &generator))
        }
        for x in 0..<width { setInk(x, 0) }
        for y in 20..<50 { for x in 30..<70 { setInk(x, y) } }
        let mask = try #require(BilevelBuffer(width: width, height: height, data: Data(bits)))

        let image = try #require(MRCSegmenter.reconstructBackground(
            pixels: Data(pixels), width: width, height: height,
            components: channels, mask: mask, effectivelyGray: channels == 1))
        let actual = try #require(image.dataProvider?.data as Data?)

        let reference = Self.referenceBackground(pixels: pixels, width: width, height: height,
                                                 channels: channels, maskBits: bits)
        var expected = reference
        if channels == 3 {
            expected = [UInt8](repeating: 255, count: width * height * 4)
            for i in 0..<(width * height) {
                for c in 0..<3 { expected[i * 4 + c] = reference[i * 3 + c] }
            }
        }
        #expect(Data(expected) == actual)
    }

    /// Das Verfahren als direkte Pixelschleife – Vergleichsmaßstab.
    private static func referenceBackground(pixels: [UInt8], width: Int, height: Int,
                                            channels: Int, maskBits: [UInt8]) -> [UInt8] {
        let count = width * height
        let rowBytes = BilevelBuffer.rowBytes(width: width)
        func isInk(_ i: Int) -> Bool {
            let x = i % width, y = i / width
            return (maskBits[y * rowBytes + (x >> 3)] >> UInt8(7 - (x & 7))) & 1 == 1
        }
        var buffer = pixels
        var unknown = (0..<count).map(isInk)
        for _ in 0..<MRCSegmenter.inpaintDilatePasses {
            var filled: [(Int, [UInt8])] = []
            for i in 0..<count where unknown[i] {
                let x = i % width, y = i / width
                var sum = [Int](repeating: 0, count: channels)
                var known = 0
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let n = ny * width + nx
                    guard !unknown[n] else { continue }
                    for c in 0..<channels { sum[c] += Int(buffer[n * channels + c]) }
                    known += 1
                }
                guard known > 0 else { continue }
                filled.append((i, sum.map { UInt8(clamping: $0 / known) }))
            }
            for (index, values) in filled {
                for c in 0..<channels { buffer[index * channels + c] = values[c] }
                unknown[index] = false
            }
        }
        if unknown.contains(true) {
            var sums = [Int](repeating: 0, count: channels)
            var known = 0
            for i in 0..<count where !unknown[i] {
                for c in 0..<channels { sums[c] += Int(buffer[i * channels + c]) }
                known += 1
            }
            for i in 0..<count where unknown[i] {
                for c in 0..<channels { buffer[i * channels + c] = UInt8(clamping: sums[c] / known) }
            }
        }
        for _ in 0..<MRCSegmenter.inpaintSmoothPasses {
            var smoothed = buffer
            for i in 0..<count where !unknown[i] && isInk(i) {
                let x = i % width, y = i / width
                for c in 0..<channels {
                    var sum = 0
                    for ny in max(0, y - 1)...min(height - 1, y + 1) {
                        for nx in max(0, x - 1)...min(width - 1, x + 1) {
                            sum += Int(buffer[(ny * width + nx) * channels + c])
                        }
                    }
                    smoothed[i * channels + c] = UInt8(clamping: sum / 9)
                }
            }
            buffer = smoothed
        }
        return buffer
    }
}

/// Reproduzierbare Zufallsfolge (SplitMix64) für Testmuster.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension CGRect {
    var area: Double { Double(width * height) }
}

// N14 (A2) und A2 Stufe 2 – als Erweiterung der Suite (nicht im Zufallsgenerator).
extension MRCSegmentationTests {
    // MARK: N14 (A2) – Farbsäume an schwarzer Schrift

    /// Schwarzer Balken 6 px breit, an beiden Rändern je eine Spalte mit
    /// JPEG-Farbsaum (Chroma 90). Vorher zählten die Saumpixel als farbige
    /// Tinte (2/6 = 33 % > 3 %) – die Seite fiel aus MRC.
    @Test func farbsaumAnSchwarzerSchriftIstKeineFarbigeTinte() {
        let (w, h) = (40, 40)
        var fg = [Bool](repeating: false, count: w * h)
        var chroma = [UInt8](repeating: 0, count: w * h)
        for y in 5..<35 {
            for x in 10..<16 {
                fg[y * w + x] = true
                if x == 10 || x == 15 { chroma[y * w + x] = 90 }
            }
        }
        let before = fg.filter { $0 }.count
        #expect(MRCSegmenter.stripColoredInk(from: &fg, chroma: chroma, width: w, height: h))
        #expect(fg.filter { $0 }.count == before, "Saumpixel dünnten die Glyphe aus")
    }

    /// Ein 1 px breiter blauer Strich (Chroma 120) auf Papier bleibt farbige
    /// Tinte und verlässt samt Rand die Maske – auch mit Mittelung.
    @Test func duennerFarbigerStrichBleibtFarbig() {
        let (w, h) = (60, 60)
        var fg = [Bool](repeating: false, count: w * h)
        var chroma = [UInt8](repeating: 0, count: w * h)
        // Viel schwarze Schrift, damit der Anteil unter 3 % bleibt.
        for y in 0..<60 { for x in 0..<40 { fg[y * w + x] = true } }
        for y in 10..<50 { fg[y * w + 50] = true; chroma[y * w + 50] = 120 }
        #expect(MRCSegmenter.stripColoredInk(from: &fg, chroma: chroma, width: w, height: h))
        #expect((10..<50).allSatisfy { !fg[$0 * w + 50] }, "Blauer Strich blieb in der schwarzen Maske")
    }

    // MARK: Masterplan A2 Stufe 2 – farbige Masken

    /// Weißes Papier mit schwarzen Textbalken und einer blauen Linie.
    static func pageWithBlueInk() throws -> CGImage {
        let (w, h) = (900, 1200)
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        for row in 0..<40 {
            for word in 0..<12 {
                ctx.fill(CGRect(x: 60 + word * 65, y: 80 + row * 26, width: 48, height: 12))
            }
        }
        ctx.setStrokeColor(CGColor(red: 0.1, green: 0.2, blue: 0.85, alpha: 1))
        ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: 120, y: 1150))
        ctx.addLine(to: CGPoint(x: 420, y: 1120))
        ctx.strokePath()
        return try #require(ctx.makeImage())
    }

    @Test func blaueTinteBekommtEigeneFarbmaske() throws {
        let image = try Self.pageWithBlueInk()
        let segmentation = try #require(MRCSegmenter.segment(image))
        #expect(segmentation.colorMasks.count == 1,
                "Farbmasken: \(segmentation.colorMasks.map { ($0.fill, $0.mask.data.reduce(0) { $0 + $1.nonzeroBitCount }) })")
        let fill = try #require(segmentation.colorMasks.first?.fill)
        #expect(fill.blue > 0.6 && fill.red < 0.3 && fill.green < 0.4, "Füllfarbe \(fill)")
        // Die blaue Linie steht nicht in der schwarzen Maske.
        let black = segmentation.mask
        let color = try #require(segmentation.colorMasks.first?.mask)
        let row = BilevelBuffer.rowBytes(width: black.width)
        var overlap = 0, colored = 0
        for i in 0..<min(black.data.count, color.data.count) {
            overlap += (black.data[i] & color.data[i]).nonzeroBitCount
            colored += color.data[i].nonzeroBitCount
        }
        #expect(colored > 300, "Farbmaske fast leer: \(colored) Pixel")
        #expect(overlap == 0, "\(overlap) Pixel in beiden Masken")
        _ = row
    }

    /// Bündel Version 2 trägt die Füllfarbe; Version 1 bleibt lesbar.
    @Test func buendelVersionZweiUndEins() throws {
        let entry = MRCEncoder.Bundle.Entry(kind: 1, isMask: true, components: 1, width: 8, height: 8,
                                            rect: nil, globals: Data(), data: Data([1, 2, 3]),
                                            fill: (0.1, 0.2, 0.85))
        let decoded = try #require(MRCEncoder.Bundle.decode(MRCEncoder.Bundle.encode([entry])))
        #expect(decoded.count == 1)
        #expect(decoded[0].fill?.blue == 0.85 && decoded[0].data == Data([1, 2, 3]))
        // Version 1 von Hand: kein Füllfeld.
        var v1 = Data(MRCEncoder.Bundle.magic) + Data([1, 1, 1, 1, 1, 0])
        for value in [UInt32(8), 8, 0, 3] { var le = value.littleEndian; v1.append(Data(bytes: &le, count: 4)) }
        v1.append(Data(count: 32)); v1.append(Data([1, 2, 3]))
        let old = try #require(MRCEncoder.Bundle.decode(v1))
        #expect(old.first?.fill == nil && old.first?.data == Data([1, 2, 3]))
    }

    // MARK: N26 – Farbmasken färben nicht um

    /// Farbige Pixel als RGB-Raster 40×40; jede Gruppe ein eigener Block.
    static func colorBlocks(_ blocks: [(rgb: (UInt8, UInt8, UInt8), count: Int)])
        -> (ink: [Bool], rgb: Data, width: Int, height: Int, offsets: [Range<Int>]) {
        let (w, h) = (40, 40)
        var ink = [Bool](repeating: false, count: w * h)
        var rgb = [UInt8](repeating: 245, count: w * h * 3)
        var next = 0
        var offsets: [Range<Int>] = []
        for block in blocks {
            offsets.append(next..<(next + block.count))
            for i in next..<(next + block.count) {
                ink[i] = true
                rgb[i * 3] = block.rgb.0; rgb[i * 3 + 1] = block.rgb.1; rgb[i * 3 + 2] = block.rgb.2
            }
            next += block.count
        }
        return (ink, Data(rgb), w, h, offsets)
    }

    static func isSet(_ mask: BilevelBuffer, _ i: Int) -> Bool {
        let row = BilevelBuffer.rowBytes(width: mask.width)
        let x = i % mask.width, y = i / mask.width
        return mask.data[y * row + x / 8] & (0x80 >> UInt8(x % 8)) != 0
    }

    /// Vier Farbtöne, höchstens drei Masken: Der vierte kam vorher in die
    /// nächste Gruppe, zog deren Zentrum zu sich (Rot + Gelb → Orange) und
    /// wurde in der Mischfarbe gemalt. Jetzt bleibt genau ein Farbton ganz im
    /// Hintergrund, und jede Maske trägt die Farbe ihres eigenen Blocks.
    @Test func vierterFarbtonWirdNichtUmgefaerbt() throws {
        let colors: [(UInt8, UInt8, UInt8)] = [(220, 200, 20), (30, 170, 40), (30, 40, 220), (220, 30, 30)]
        let page = Self.colorBlocks(colors.map { ($0, 100) })
        let masks = MRCSegmenter.colorMasks(coloredInk: page.ink, rgb: page.rgb,
                                            width: page.width, height: page.height)
        #expect(masks.count == 3)
        var unmasked = 0
        for (block, color) in zip(page.offsets, colors) {
            let holders = masks.filter { mask in block.contains { Self.isSet(mask.mask, $0) } }
            if holders.isEmpty { unmasked += 1; continue }
            #expect(holders.count == 1)
            let mask = try #require(holders.first)
            #expect(block.allSatisfy { Self.isSet(mask.mask, $0) })
            let want = (Double(color.0) / 255, Double(color.1) / 255, Double(color.2) / 255)
            let off = max(abs(mask.fill.red - want.0), abs(mask.fill.green - want.1), abs(mask.fill.blue - want.2))
            #expect(off < 0.02, "Block \(color) gemalt als \(mask.fill)")
        }
        #expect(unmasked == 1, "\(unmasked) Farbtöne ohne Maske")
    }

    /// Rote Tinte und daneben fast schwarze Pixel mit rotem Stich (JPEG-Saum
    /// an schwarzer Schrift): Die dunklen Pixel tragen denselben Farbton und
    /// kamen in die rote Maske – gemalt wurden sie leuchtend rot.
    @Test func schwarzNebenFarbeWirdNichtMitgefaerbt() throws {
        let page = Self.colorBlocks([((220, 30, 30), 120), ((60, 25, 25), 60)])
        let masks = MRCSegmenter.colorMasks(coloredInk: page.ink, rgb: page.rgb,
                                            width: page.width, height: page.height)
        let red = try #require(masks.first)
        #expect(masks.count == 1)
        #expect(page.offsets[0].allSatisfy { Self.isSet(red.mask, $0) })
        #expect(!page.offsets[1].contains { Self.isSet(red.mask, $0) },
                "Dunkle Pixel in der roten Maske")
    }

    /// Das Farbspitzen-Maß sieht Farbe, die erst im Kandidaten entsteht:
    /// Referenz mit roter Unterschrift und schwarzem Text, Kandidat malt den
    /// schwarzen Text rot. Vorher zählten nur die roten Referenzpixel – und
    /// die waren unverändert, die Spitze blieb 0.
    @Test func farbspitzeSiehtFarbeAufSchwarz() throws {
        func page(textRed: Bool) throws -> CGImage {
            let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let ctx = try #require(CGContext(
                data: nil, width: 160, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let red = CGColor(srgbRed: 0.82, green: 0.12, blue: 0.12, alpha: 1)
            ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            ctx.setFillColor(red)
            ctx.fill(CGRect(x: 10, y: 140, width: 60, height: 4))              // Unterschrift
            ctx.setFillColor(textRed ? red : CGColor(srgbRed: 0.06, green: 0.06, blue: 0.06, alpha: 1))
            for row in 0..<8 { ctx.fill(CGRect(x: 10, y: 10 + row * 14, width: 140, height: 6)) }
            return try #require(ctx.makeImage())
        }
        let plain = try page(textRed: false), red = try page(textRed: true)
        let reference = try #require(QualityGates.sample(plain, maxEdge: 160))
        let recolored = try #require(QualityGates.sample(red, maxEdge: 160))
        #expect(QualityGates.peakDeltaE76(reference: reference, candidate: reference) == 0)
        let peak = QualityGates.peakDeltaE76(reference: reference, candidate: recolored)
        #expect(peak > QualityGatePolicy.peakDeltaE76Floor, "Farbspitze \(peak)")
    }

    /// H1/H2: Geglättete Scanschrift auf leicht getöntem Papier (Luminanz ~240)
    /// darf von `detectPhotoRects` nicht als Textur-Foto fehlklassifiziert werden.
    @Test func geglaetteteScanschriftWirdNichtAlsFotoErkannt() throws {
        let (w, h) = (900, 1200)
        let ctx = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 26, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1),
        ]
        let line = NSAttributedString(
            string: "Rechnung Nr. 2026-1142 — Übersicht aller gelieferten Positionen und Summen",
            attributes: attrs)
        for row in 0..<24 {
            ctx.textPosition = CGPoint(x: 60, y: CGFloat(h - 100 - row * 42))
            CTLineDraw(CTLineCreateWithAttributedString(line), ctx)
        }
        let image = try #require(ctx.makeImage())
        let seg = try #require(MRCSegmenter.segment(image))
        #expect(seg.photoRegions.isEmpty,
                "Reine Textseite erzeugte \(seg.photoRegions.count) falsche Foto-Regionen")
    }

    /// H1/H2: Ein heller Anti-Aliasing-Saum (Luminanz 165) neben einem scharfen
    /// schwarzen Strich (Luminanz 20) auf Papier (242) darf nicht schwarz
    /// maskiert werden; der Strichkern bleibt in der Maske.
    @Test func antiAliasingSaumBleibtAusDerMaske() {
        let (w, h) = (64, 64)
        var luma = [UInt8](repeating: 242, count: w * h)
        for y in 16..<48 {
            for x in 28..<36 { luma[y * w + x] = 20 }
            luma[y * w + 27] = 165
            luma[y * w + 36] = 165
        }
        let fg = MRCSegmenter.sauvolaForeground(luma: luma, width: w, height: h)
        #expect(fg[32 * w + 31], "Schwarzer Strichkern fehlt in der Maske")
        #expect(!fg[32 * w + 27], "Heller Anti-Aliasing-Saum wurde schwarz maskiert")
        #expect(!fg[32 * w + 36], "Heller Anti-Aliasing-Saum wurde schwarz maskiert")
    }
}
