import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import PDFTools

/// Masterplan A1/A2 (18.11.2026): Farbige Tinte darf beim Komprimieren nicht
/// verschwinden.
///
/// Befund an 1.0.9: Ein sauberer Brief (300-DPI-JPEG) mit blauer Unterschrift
/// kam aus „Klein“ als 1-Kanal-Bild zurück – die Unterschrift grau. Die
/// Grau-Erkennung mittelte auf 64×64 Pixeln, ein dünner Strich auf viel Weiß
/// verschwand darin. „Smart“ malte die Unterschrift über die MRC-Maske
/// schwarz-blau gescheckt, weil die Maske immer schwarz gefüllt wird.
///
/// Messung: Seite bei 100 DPI rendern, Pixel mit max−min > 40 zählen
/// (deutlich farbig). Nach dem Lauf müssen mindestens 70 % davon übrig sein.
/// Artefakt: `benchmark/color-ink/result.json`.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Die Klassifikation hält das Bild für grau → Graustufen-Kandidat.
///  2. Das Gate misst Farbe nur im Mittel über das ganze Bild → ein grauer
///     Kandidat besteht, weil der Farbfehler auf 0,1 % der Fläche verdünnt ist.
///  3. Die MRC-Maske nimmt farbige Tinte auf und malt sie schwarz.
///  4. Die MRC-Hintergrundrekonstruktion übermalt die Tinte mit Papierfarbe.
///  5. Eine Stufe verkleinert so stark, dass ein 2-px-Strich wegfällt – das
///     wäre ein Auflösungs-, kein Farbfehler; die Testseite hat deshalb einen
///     Strich von 0,5 mm.
@Suite(.serialized) struct ColorInkSurvivesCompressionE2ETests {

    static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    /// Die Datei aus dem Gesamtscan vom 18.11. (lokal, nicht im Repo).
    static let reviewFile = "tmp/review-20261118/blaue-unterschrift-test.pdf"

    static let strongChroma = 40
    static let requiredShare = 0.70

    // MARK: Fixture

    /// Briefseite A4: 300-DPI-JPEG, schwarzer Fließtext, blaue Unterschrift
    /// (0,5 mm Strich). Deterministisch, kein Zufall.
    static func signedLetterPDF() throws -> URL {
        let decoded = try signedLetterImage()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("color-ink-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil)
        else { throw CocoaError(.featureUnsupported) }
        pdf.beginPDFPage(nil)
        pdf.draw(decoded, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    /// Die Seite als dekodiertes JPEG (so, wie sie in der PDF steckt).
    static func signedLetterImage() throws -> CGImage {
        let w = 2480, h = 3508
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.featureUnsupported) }
        ctx.setFillColor(CGColor(red: 0.985, green: 0.985, blue: 0.985, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Fließtext: 10 pt bei 300 DPI ≈ 42 px.
        let font = CTFontCreateWithName("Helvetica" as CFString, 42, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1),
        ]
        let sentence = "Sehr geehrte Damen und Herren, anbei erhalten Sie die unterschriebenen Unterlagen zurück."
        for line in 0..<38 {
            let text = NSAttributedString(string: sentence, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(text)
            ctx.textPosition = CGPoint(x: 236, y: h - 400 - line * 62)
            CTLineDraw(ctLine, ctx)
        }

        // Unterschrift: blaue Kugelschreibertinte, 6 px = 0,5 mm.
        ctx.setStrokeColor(CGColor(red: 0.10, green: 0.22, blue: 0.75, alpha: 1))
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: 300, y: 520))
        ctx.addCurve(to: CGPoint(x: 620, y: 600), control1: CGPoint(x: 380, y: 760), control2: CGPoint(x: 520, y: 380))
        ctx.addCurve(to: CGPoint(x: 900, y: 540), control1: CGPoint(x: 700, y: 760), control2: CGPoint(x: 780, y: 360))
        ctx.addCurve(to: CGPoint(x: 1250, y: 620), control1: CGPoint(x: 1000, y: 720), control2: CGPoint(x: 1120, y: 420))
        ctx.addLine(to: CGPoint(x: 1400, y: 560))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: 280, y: 470))
        ctx.addCurve(to: CGPoint(x: 1420, y: 480), control1: CGPoint(x: 700, y: 430), control2: CGPoint(x: 1000, y: 500))
        ctx.strokePath()

        guard let page = ctx.makeImage() else { throw CocoaError(.featureUnsupported) }
        let jpeg = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.featureUnsupported) }
        CGImageDestinationAddImage(dest, page, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest),
              let source = CGImageSourceCreateWithData(jpeg, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CocoaError(.featureUnsupported) }
        return decoded
    }

    // MARK: Messung

    /// Pixel mit max−min > 40 bei 100 DPI, über alle Seiten.
    static func strongColorPixels(_ url: URL) -> Int? {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { return nil }
        var count = 0
        for index in 1...doc.numberOfPages {
            guard let page = doc.page(at: index) else { return nil }
            let box = page.getBoxRect(.cropBox)
            let scale = 100.0 / 72.0
            let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            let ok: Bool = buffer.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return false }
                ctx.setFillColor(.white)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -box.minX, y: -box.minY)
                ctx.drawPDFPage(page)
                return true
            }
            guard ok else { return nil }
            for i in stride(from: 0, to: buffer.count, by: 4) {
                let r = Int(buffer[i]), g = Int(buffer[i + 1]), b = Int(buffer[i + 2])
                if max(r, g, b) - min(r, g, b) > strongChroma { count += 1 }
            }
        }
        return count
    }

    struct Row {
        let file: String
        let mode: String
        let original: Int
        let result: Int
        let inputBytes: Int64
        let outputBytes: Int64
        var share: Double { original > 0 ? Double(result) / Double(original) : 1 }
    }

    static func run(_ input: URL, name: String) throws -> [Row] {
        let original = try #require(strongColorPixels(input))
        try #require(original > 500, "Testseite trägt zu wenig Farbe (\(original) px)")
        var rows: [Row] = []
        for mode in CompressionMode.allCases {
            let result = try Compressor().compress(inputURL: input, mode: mode)
            defer {
                if result.outputURL != input { try? FileManager.default.removeItem(at: result.outputURL) }
            }
            let after = try #require(strongColorPixels(result.outputURL))
            rows.append(Row(file: name, mode: mode.rawValue, original: original, result: after,
                            inputBytes: result.inputBytes, outputBytes: result.outputBytes))
        }
        return rows
    }

    static func writeArtifact(_ rows: [Row], name: String) throws {
        let dir = projectRoot.appendingPathComponent("benchmark/color-ink", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [[String: Any]] = rows.map {
            ["file": $0.file, "mode": $0.mode, "colorPixelsOriginal": $0.original,
             "colorPixelsResult": $0.result, "share": ($0.share * 1000).rounded() / 1000,
             "inputBytes": $0.inputBytes, "outputBytes": $0.outputBytes]
        }
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("\(name).json"))
    }

    static func check(_ rows: [Row]) {
        for row in rows {
            #expect(row.share >= requiredShare, """
                \(row.file) / \(row.mode): nur \(row.result) von \(row.original) \
                farbigen Pixeln übrig (\(Int((row.share * 100).rounded())) %).
                """)
        }
    }

    // MARK: Tests

    @Test func syntheticSignedLetterKeepsBlueInk() throws {
        let input = try Self.signedLetterPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let rows = try Self.run(input, name: "synthetic-signed-letter")
        try Self.writeArtifact(rows, name: "synthetic-signed-letter")
        Self.check(rows)
    }

    /// A2, Segmenter: Keine Maskenpixel auf farbiger Tinte. Die Maske wird
    /// schwarz gemalt; was dort liegt, verliert seine Farbe. Verweigert der
    /// Segmenter die Seite ganz (zu viel farbige Tinte), ist das ebenfalls
    /// farbrichtig – dann läuft die normale Leiter.
    @Test func mrcMaskExcludesColoredInk() throws {
        let image = try Self.signedLetterImage()
        guard let segmentation = MRCSegmenter.segment(image) else { return }
        let rgb = try #require(ImageResampler.rawBitmap(image, components: 3))
        let mask = segmentation.mask
        let rowBytes = BilevelBuffer.rowBytes(width: mask.width)
        var coloredInMask = 0
        var colored = 0
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                let o = (y * image.width + x) * 3
                let r = Int(rgb[o]), g = Int(rgb[o + 1]), b = Int(rgb[o + 2])
                guard max(r, g, b) - min(r, g, b) > Self.strongChroma else { continue }
                colored += 1
                let byte = mask.data[mask.data.startIndex + y * rowBytes + x / 8]
                if byte & (0x80 >> UInt8(x % 8)) != 0 { coloredInMask += 1 }
            }
        }
        #expect(colored > 1000)
        #expect(coloredInMask == 0, "\(coloredInMask) von \(colored) farbigen Pixeln liegen in der MRC-Maske")
    }

    @Test(.needsLocalFiles(reviewFile)) func reviewFileKeepsBlueInk() throws {
        let input = Self.projectRoot.appendingPathComponent(Self.reviewFile)
        let rows = try Self.run(input, name: "blaue-unterschrift-test")
        try Self.writeArtifact(rows, name: "blaue-unterschrift-test")
        Self.check(rows)
    }
}
