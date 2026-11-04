import AppKit
import Testing
import Foundation
@testable import PDFTools

/// Die Stufen müssen auf Scans unterschiedliche Ergebnisse liefern.
///
/// Ausgelöst von einem iOS-Scan (Handschrift, ein Punkt je Pixel): Die Seite
/// war 67 × 93 cm groß, das Bild zählte als 72 DPI, und Klein, Smart und
/// Qualität lieferten byteidentisch 7,8 % Ersparnis.
///
/// Mögliche Fehler, die diese Suite festhält:
/// - Übergroße Scan-Seite bleibt in allen Stufen unangetastet.
/// - Die Korrektur trifft echte Großformate, kleine Bilder auf großen Seiten
///   oder normale Seiten mit niedriger Auflösung.
/// - Smart verkleinert vollseitige Fotos auf das Scan-Ziel.
/// - Qualität verliert ihre Zusage und rechnet Scans herunter.
/// - Ein zweiter Lauf rechnet das Ergebnis weiter herunter.
@Suite(.serialized) struct ScanPresetSpreadTests {

    private enum Content { case paper, photo }

    /// Eine Seite mit einem JPEG; `placed` nil heißt: füllt die Seite.
    private static func scanPDF(_ content: Content, pixels: (Int, Int), page: (Double, Double),
                                placed: (Double, Double)? = nil, name: String) throws -> URL {
        let (w, h) = pixels
        let context = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        var seed = UInt64(w &* 31 &+ h)
        func noise(_ range: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(range))
        }
        switch content {
        case .paper:
            // Papier mit Lineatur, Tinte und Sensorrauschen.
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.setStrokeColor(CGColor(gray: 0.72, alpha: 1))
            for y in stride(from: 40, to: h, by: h / 40) {
                context.stroke(CGRect(x: 0, y: y, width: w, height: 1))
            }
            context.setStrokeColor(CGColor(red: 0.2, green: 0.25, blue: 0.75, alpha: 1))
            context.setLineWidth(max(2, CGFloat(w) / 500))
            for line in 0..<24 {
                let base = 60 + line * h / 26
                var x = w / 10
                context.move(to: CGPoint(x: x, y: base))
                while x < w * 9 / 10 {
                    x += 8 + noise(w / 60)
                    context.addLine(to: CGPoint(x: x, y: base + noise(h / 45)))
                }
                context.strokePath()
            }
        case .photo:
            for y in stride(from: 0, to: h, by: 6) {
                for x in stride(from: 0, to: w, by: 6) {
                    context.setFillColor(CGColor(
                        red: CGFloat(x * 255 / w + noise(50)) / 305,
                        green: CGFloat(y * 255 / h + noise(50)) / 305,
                        blue: CGFloat(noise(255)) / 255, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 6, height: 6))
                }
            }
        }
        let image = try #require(context.makeImage())
        let jpeg = try #require(NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.92]))

        let (pw, ph) = page
        let (iw, ih) = placed ?? page
        var b = RawPDFBuilder()
        let pagesRef = b.reserveNumber()
        let imageRef = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(w)/Height \(h)"
                + "/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode",
            data: jpeg)
        let contents = b.addStream(dictionary: "",
                                   content: "q \(iw) 0 0 \(ih) 0 0 cm /Im0 Do Q")
        let pageRef = b.addObject(
            "<</Type/Page/Parent \(pagesRef) 0 R/MediaBox[0 0 \(pw) \(ph)]"
            + "/Resources<</XObject<</Im0 \(imageRef) 0 R>>>>/Contents \(contents) 0 R>>")
        b.fill(pagesRef, "<</Type/Pages/Kids[\(pageRef) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pagesRef) 0 R>>")
        let url = PDFFixtures.fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    private static func compressed(_ url: URL, _ mode: CompressionMode) throws -> URL {
        try Compressor().compress(inputURL: url, mode: mode).outputURL
    }

    private static func imageWidth(_ url: URL) throws -> Int {
        try #require(try PDFCoreDocument(path: url.path).imageResources().first).width
    }

    private static func effectiveDPI(_ url: URL) throws -> Double {
        try #require(try PDFCoreDocument(path: url.path).imageResources().first?.effectiveDPI)
    }

    /// Der ursprüngliche Fehler: Jede Stufe muss etwas anderes liefern.
    @Test(.hangGuard) func oversizedScanDiffersPerPreset() throws {
        let url = try Self.scanPDF(.paper, pixels: (1898, 2645), page: (1898, 2645), name: "oversized")
        #expect(abs(try Self.effectiveDPI(url) - 230) < 2)

        let klein = try Self.imageWidth(Self.compressed(url, .small))
        let smart = try Self.imageWidth(Self.compressed(url, .smart))
        let qualitaet = try Self.imageWidth(Self.compressed(url, .quality))
        #expect(klein < smart, "Klein \(klein) nicht kleiner als Smart \(smart)")
        #expect(smart <= 1240, "Smart \(smart) nicht auf das Scan-Ziel gekommen")
        #expect(qualitaet == 1898, "Qualität hat einen Scan unter 300 DPI verkleinert")
    }

    /// Die Seitengröße bleibt erhalten; nur die Bewertung ändert sich.
    @Test(.hangGuard) func outputKeepsPageSize() throws {
        let url = try Self.scanPDF(.paper, pixels: (1898, 2645), page: (1898, 2645), name: "page-size")
        let out = try Self.compressed(url, .small)
        let media = try PDFCoreDocument(path: out.path).pageInfo(at: 0).mediaBox
        #expect(media[2] == 1898 && media[3] == 2645)
    }

    /// Ein zweiter Lauf darf nicht weiter verkleinern.
    @Test(.hangGuard) func secondRunIsStable() throws {
        let url = try Self.scanPDF(.paper, pixels: (1898, 2645), page: (1898, 2645), name: "second-run")
        let first = try Self.compressed(url, .smart)
        let second = try Self.compressed(first, .smart)
        #expect(try Self.imageWidth(first) == Self.imageWidth(second))
    }

    /// Auch auf echtem A4 verkleinert Smart JPEG-Dokumentscans.
    @Test(.hangGuard) func a4PaperScanGoesToScanTarget() throws {
        let url = try Self.scanPDF(.paper, pixels: (1898, 2645), page: (595, 829), name: "a4-paper")
        #expect(try Self.imageWidth(Self.compressed(url, .smart)) <= 1240)
    }

    /// Vollseitige Fotos behalten das allgemeine Smart-Ziel.
    @Test(.hangGuard) func a4PhotoStaysAtGeneralTarget() throws {
        let url = try Self.scanPDF(.photo, pixels: (1898, 2645), page: (595, 829), name: "a4-photo")
        #expect(try Self.imageWidth(Self.compressed(url, .smart)) == 1898)
    }

    /// Die Vorschau kennt das Scan-Ziel: Homework_2 zeigte 15 % statt 90 %.
    @Test(.hangGuard) func estimateFollowsSmartPaperScan() throws {
        let url = try Self.scanPDF(.paper, pixels: (1898, 2645), page: (1898, 2645), name: "est-paper")
        let smart = try #require(CompressionEstimator.quickEstimate(url: url, options: .smart))
        let actual = try FileManager.default.attributesOfItem(
            atPath: Self.compressed(url, .smart).path)[.size] as? Int64 ?? 0
        #expect(smart.pointBytes < smart.originalBytes / 2, "Schätzung \(smart.pointBytes)")
        #expect(Double(smart.pointBytes) <= Double(actual) * 3,
                "Schätzung \(smart.pointBytes), tatsächlich \(actual)")
    }

    /// Die Vorprobe trennt wie der Lauf: Papier ja, vollseitiges Foto nein.
    @Test(.hangGuard) func paperProbeSeparatesPaperFromPhoto() throws {
        func verdict(_ content: Content, _ name: String) throws -> Bool? {
            let url = try Self.scanPDF(content, pixels: (1898, 2645), page: (595, 829), name: name)
            let document = try PDFCoreDocument(path: url.path)
            let resource = try #require(try document.imageResources().first)
            let jpeg = try #require(LibQPDFPixelSource(document: document).rawImageData(for: resource))
            return PaperScanProbe.isPaper(jpeg: jpeg)
        }
        #expect(try verdict(.paper, "probe-paper") == true)
        #expect(try verdict(.photo, "probe-photo") == false)
    }

    /// Echte Großformate werden nicht umgedeutet: 150 DPI auf A1 bleiben 150.
    @Test(.hangGuard) func largeFormatScanIsNotRescaled() throws {
        let url = try Self.scanPDF(.paper, pixels: (3508, 4961), page: (1684, 2381), name: "a1-plan")
        #expect(abs(try Self.effectiveDPI(url) - 150) < 1)
    }

    /// Ein kleines Bild auf großer Seite ist kein Scan.
    @Test(.hangGuard) func smallImageOnLargePageIsNotRescaled() throws {
        let url = try Self.scanPDF(.paper, pixels: (800, 600), page: (1898, 2645),
                                   placed: (800, 600), name: "poster-logo")
        #expect(abs(try Self.effectiveDPI(url) - 72) < 1)
    }

    /// Normale Seite mit niedriger Auflösung: Sie ist wirklich niedrig.
    @Test(.hangGuard) func normalPageLowResolutionIsNotRescaled() throws {
        let url = try Self.scanPDF(.paper, pixels: (595, 842), page: (595, 842), name: "a4-72dpi")
        #expect(abs(try Self.effectiveDPI(url) - 72) < 1)
    }
}
