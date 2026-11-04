import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PDFTools

/// Bilder über `maximumDecodablePixels` müssen in jeder Stufe schrumpfen.
///
/// Ausgelöst von Handyfotos mit 48 Megapixeln und einem 60-MP-JPEG mit rund
/// 1296 ppi: Die Grenze prüfte die Quelle statt der tatsächlich dekodierten
/// Pixel; alle Stufen endeten mit derselben Größe (16 %, nur der Writer).
///
/// Mögliche Fehler, die diese Suite festhält:
/// - Ein großes JPEG bleibt in einer Stufe unangetastet, oder zwei Stufen
///   liefern dasselbe.
/// - Das Ergebnis liegt über der DPI-Zusage der Stufe.
/// - Eine Qualitätsprüfung oder eine Nativ-Stufe der Leiter dekodiert doch das
///   volle Raster; die Speichergrenze wäre dann nur Fassade.
/// - Die Grenze fällt für absurde Quellen ganz weg (Dekompressionsbombe).
/// - Das Bilddictionary lügt, und der JPEG-Kopf nennt viel mehr Pixel.
/// - Bilder bis zur Grenze werden plötzlich reduziert dekodiert und ändern
///   ihr Ergebnis (Ebene ≠ 0).
/// - Flate über der Grenze wird voll entpackt, obwohl dafür kein Reduktionsweg
///   existiert.
/// - Ein Ziel, das nur das volle Raster abdeckt, wird hochskaliert oder
///   sprengt die Grenze.
/// - Ein zweiter Lauf rechnet das Ergebnis weiter herunter.
@Suite(.serialized) struct LargeImagePresetTests {

    // MARK: Spion

    /// Echte Pixelquelle, die jedes gelieferte Raster notiert: Die Aussage
    /// „nie mehr als die Grenze dekodiert" misst so den Generator selbst,
    /// nicht den Speicher des ganzen Testprozesses.
    private final class RecordingPixelSource: ImagePixelSource, @unchecked Sendable {
        let base: LibQPDFPixelSource
        private let lock = NSLock()
        private var rasters: [Int] = []

        init(document: PDFCoreDocument) { base = LibQPDFPixelSource(document: document) }

        private func noted(_ image: CGImage?) -> CGImage? {
            if let image {
                lock.lock(); rasters.append(image.width * image.height); lock.unlock()
            }
            return image
        }

        var largestRaster: Int { lock.lock(); defer { lock.unlock() }; return rasters.max() ?? 0 }
        var rasterCount: Int { lock.lock(); defer { lock.unlock() }; return rasters.count }

        func decodedImage(for resource: PDFImageResource) -> CGImage? {
            noted(base.decodedImage(for: resource))
        }
        func decodedImage(for resource: PDFImageResource, target: PixelSize) -> CGImage? {
            noted(base.decodedImage(for: resource, target: target))
        }
        func bilevelBuffer(for resource: PDFImageResource) -> BilevelBuffer? {
            base.bilevelBuffer(for: resource)
        }
        func rawImageData(for resource: PDFImageResource) -> Data? { base.rawImageData(for: resource) }
        func decodedStreamData(for resource: PDFImageResource) -> Data? {
            base.decodedStreamData(for: resource)
        }
        func decodeLevel(for resource: PDFImageResource, target: PixelSize) -> Int {
            base.decodeLevel(for: resource, target: target)
        }
        func decodedSize(for resource: PDFImageResource, target: PixelSize) -> PixelSize {
            base.decodedSize(for: resource, target: target)
        }
    }

    // MARK: Fixtures

    private static let presets: [(mode: CompressionMode, image: ImageCompressionOptions, dpi: Double)] = [
        (.small, .small, 110), (.smart, .smart, 220), (.quality, .quality, 300)
    ]

    /// Foto-Motiv: weiche Flächen mit leichtem Rauschen, klein gerechnet und
    /// hochgezogen. Pixelweises Erzeugen dauert im Debug-Build bei 60 MP zu
    /// lange. Starkes Rauschen taugt hier nicht: Daran scheitert Klein auch
    /// unter der Grenze an seinen Gates (30 MP gemessen, 2026-11-03).
    private static func seedImage(_ w: Int, _ h: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let base = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var state: UInt32 = 1
        for y in 0..<h {
            let row = base + y * context.bytesPerRow
            for x in 0..<w {
                let wave = sin(Double(x) / 37) * cos(Double(y) / 53) + sin(Double(x + y) / 211)
                for channel in 0..<3 {
                    state = state &* 1664525 &+ 1013904223
                    let level = 128 + wave * Double(40 + channel * 10) + Double(state >> 28) - 8
                    row[x * 4 + channel] = UInt8(max(0, min(255, level)))
                }
            }
        }
        return try #require(context.makeImage())
    }

    private static func photo(_ w: Int, _ h: Int, type: UTType = .jpeg, quality: Double = 0.8,
                              progressive: Bool = false, gray: Bool = false) throws -> Data {
        let seed = try seedImage(w / 6, h / 6)
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue))
        context.interpolationQuality = .medium
        context.draw(seed, in: CGRect(x: 0, y: 0, width: w, height: h))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if progressive {
            options[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
        }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// Dieses JPEG behauptet im Kopf (SOF) andere Maße als im Inhalt.
    private static func patchedHeader(_ jpeg: Data, width: Int, height: Int) throws -> Data {
        var bytes = [UInt8](jpeg)
        var index = 2
        while index + 9 < bytes.count {
            #expect(bytes[index] == 0xFF)
            let marker = bytes[index + 1]
            if marker == 0xC0 || marker == 0xC2 {
                bytes[index + 5] = UInt8(height >> 8); bytes[index + 6] = UInt8(height & 0xFF)
                bytes[index + 7] = UInt8(width >> 8); bytes[index + 8] = UInt8(width & 0xFF)
                return Data(bytes)
            }
            index += 2 + Int(bytes[index + 2]) << 8 + Int(bytes[index + 3])
        }
        Issue.record("kein SOF gefunden")
        return jpeg
    }

    private static func pdf(_ data: Data, dict: (Int, Int), filter: String = "/Filter/DCTDecode",
                            colorSpace: String = "/DeviceRGB",
                            placed: (Double, Double) = (500, 372),
                            page: (Double, Double) = (595, 842), name: String) throws -> URL {
        var b = RawPDFBuilder()
        let pagesRef = b.reserveNumber()
        let imageRef = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(dict.0)/Height \(dict.1)"
                + "/ColorSpace\(colorSpace)/BitsPerComponent 8\(filter)",
            data: data)
        let contents = b.addStream(dictionary: "",
                                   content: "q \(placed.0) 0 0 \(placed.1) 0 0 cm /Im0 Do Q")
        let pageRef = b.addObject(
            "<</Type/Page/Parent \(pagesRef) 0 R/MediaBox[0 0 \(page.0) \(page.1)]"
            + "/Resources<</XObject<</Im0 \(imageRef) 0 R>>>>/Contents \(contents) 0 R>>")
        b.fill(pagesRef, "<</Type/Pages/Kids[\(pageRef) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pagesRef) 0 R>>")
        let url = PDFFixtures.fixtureURL(prefix: "large-\(name)")
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Das 60-MP-Foto braucht die Suite mehrfach; einmal bauen reicht.
    private static let photo60: Result<Data, Error> = Result { try photo(9000, 6700) }

    private struct Plan {
        let keepReasons: [String]
        let actions: [ImageCompressionAction]
        let largestRaster: Int
        let rasterCount: Int
    }

    /// Plant über die echte Pixelquelle und notiert jedes dekodierte Raster.
    private static func plan(_ url: URL, _ image: ImageCompressionOptions) throws -> Plan {
        let document = try PDFCoreDocument(path: url.path)
        let source = RecordingPixelSource(document: document)
        let planned = try CompressionPlanner.plan(
            resources: try document.imageResources(),
            options: CompressionOptions(image: image),
            documentID: url.lastPathComponent,
            documentBytes: Int(Compressor.fileSize(of: url)),
            pixels: source)
        return Plan(keepReasons: planned.plan.keepReasons.map { $0.reason },
                    actions: planned.plan.actions,
                    largestRaster: source.largestRaster,
                    rasterCount: source.rasterCount)
    }

    private static func firstImage(_ url: URL) throws -> PDFImageResource {
        try #require(try PDFCoreDocument(path: url.path).imageResources().first)
    }

    /// Prüft die Kernaussage für ein Dokument: drei verschiedene Ergebnisse
    /// in der Reihenfolge der Stufen, jedes im DPI-Rahmen seiner Stufe.
    private static func expectPresetsShrink(_ url: URL) throws {
        var sizes: [Int64] = []
        for preset in presets {
            let out = try Compressor().compress(inputURL: url, mode: preset.mode).outputURL
            sizes.append(Compressor.fileSize(of: out))
            let dpi = try #require(try firstImage(out).effectiveDPI)
            #expect(dpi <= preset.dpi * preset.image.tolerance + 1,
                    "\(preset.mode): \(dpi) DPI über dem Ziel \(preset.dpi)")
        }
        #expect(sizes[0] < sizes[1] && sizes[1] < sizes[2], "Größen je Stufe: \(sizes)")
    }

    /// Starkes Bildrauschen: Kein Klein-Kandidat hält die perzeptuelle Grenze.
    /// Das Original darf deshalb nicht in Klein stehenbleiben, während Smart
    /// auf einen Bruchteil kommt.
    @Test(.hangGuard) func stronglyNoisyPhotoKeepsKleinAtOrBelowSmart() throws {
        let (w, h) = (2500, 3500)
        let context = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let base = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var state: UInt32 = 7
        for y in 0..<h {
            let row = base + y * context.bytesPerRow
            for x in 0..<w * 4 where x % 4 != 3 {
                state = state &* 1664525 &+ 1013904223
                let level = 90 + 80 * y / h + Int(state >> 24) / 2 - 64
                row[x] = UInt8(max(0, min(255, level)))
            }
        }
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(context.makeImage()),
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let url = try Self.pdf(out as Data, dict: (w, h), placed: (595, 842), name: "rauschen")
        let sizes = try Self.presets.map {
            Compressor.fileSize(of: try Compressor().compress(inputURL: url, mode: $0.mode).outputURL)
        }
        // Bewusst nicht Klein <= Smart: Der Rückfall landet auf Smarts Raster,
        // wählt aber eine etwas höhere Qualität als Smart (noch ungeklärt).
        #expect(Double(sizes[0]) <= Double(sizes[1]) * 1.5 && sizes[1] <= sizes[2],
                "Größen je Stufe: \(sizes)")
    }

    // MARK: Kernaussage

    @Test(.hangGuard) func sixtyMegapixelJPEGShrinksPerPreset() throws {
        let url = try Self.pdf(Self.photo60.get(), dict: (9000, 6700), name: "60mp")
        try Self.expectPresetsShrink(url)
    }

    /// Der Hauptfall: progressives 48-MP-Handyfoto auf einer A4-Seite.
    @Test(.hangGuard) func phonePhotoOnA4ShrinksPerPreset() throws {
        let data = try Self.photo(8064, 6048, progressive: true)
        let url = try Self.pdf(data, dict: (8064, 6048), placed: (595, 446), name: "48mp")
        try Self.expectPresetsShrink(url)
    }

    @Test(.hangGuard) func grayJPEGShrinksPerPreset() throws {
        let data = try Self.photo(8001, 6003, gray: true)
        let url = try Self.pdf(data, dict: (8001, 6003), colorSpace: "/DeviceGray",
                               placed: (595, 446), name: "48mp-gray")
        try Self.expectPresetsShrink(url)
    }

    /// JPX hat cp_reduce und läuft durch dieselbe Grenze.
    @Test(.hangGuard) func jpxAboveLimitShrinksWithinBound() throws {
        let data = try Self.photo(6600, 6000, type: try #require(UTType("public.jpeg-2000")), quality: 0.98, gray: true)
        let url = try Self.pdf(data, dict: (6600, 6000), filter: "/Filter/JPXDecode",
                               colorSpace: "/DeviceGray", placed: (500, 454), name: "40mp-jpx")
        let plan = try Self.plan(url, .small)
        #expect(plan.keepReasons.isEmpty, "\(plan.keepReasons)")
        #expect(plan.largestRaster <= CompressionPlanner.maximumDecodablePixels)
    }

    // MARK: Speichergrenze

    /// Weder Zielraster noch Referenz der Gates noch die Nativ-Stufe der
    /// Leiter dürfen über die Grenze dekodieren.
    @Test(.hangGuard) func noRasterAboveLimitInAnyPreset() throws {
        let url = try Self.pdf(Self.photo60.get(), dict: (9000, 6700), name: "60mp-spy")
        for preset in Self.presets {
            let plan = try Self.plan(url, preset.image)
            #expect(plan.rasterCount > 0)
            #expect(plan.largestRaster <= CompressionPlanner.maximumDecodablePixels,
                    "\(preset.mode): Raster mit \(plan.largestRaster) Pixeln")
            #expect(plan.keepReasons.isEmpty, "\(preset.mode): \(plan.keepReasons)")
        }
    }

    /// Dekompressionsbombe: Kopf und Dictionary nennen 900 MP, der Inhalt ist
    /// winzig. Weder Planer noch Writer dürfen dafür Speicher anfordern.
    @Test(.hangGuard) func absurdSourceStaysUntouchedWithoutDecoding() throws {
        let tiny = try Self.photo(240, 240)
        let bomb = try Self.patchedHeader(tiny, width: 30000, height: 30000)
        let url = try Self.pdf(bomb, dict: (30000, 30000), placed: (500, 500), name: "bomb")
        for preset in Self.presets {
            let plan = try Self.plan(url, preset.image)
            #expect(plan.rasterCount == 0, "\(preset.mode) hat dekodiert")
            #expect(plan.keepReasons.contains { $0.contains("Pixelbudget") }, "\(plan.keepReasons)")
        }
        // Der Kopf passt nicht zum Inhalt; die Endprüfung darf das abweisen.
        // Entscheidend ist, dass der Writer dafür keinen Speicher anfordert.
        let before = OperationResourceSampler.currentFootprint()
        do {
            let out = try Compressor().compress(inputURL: url, mode: .smart).outputURL
            #expect(try Self.firstImage(out).width == 30000)
        } catch PDFValidator.ValidationError.invalid {
        }
        let grown = OperationResourceSampler.currentFootprint() - before
        #expect(grown < 1_000_000_000, "Writer wuchs um \(grown) Byte")
    }

    /// Das Dictionary nennt 12 MP, der JPEG-Kopf 60 MP. Die Grenze zählt, was
    /// wirklich dekodiert würde, und das Bild bleibt unangetastet.
    @Test(.hangGuard) func lyingDictionaryCannotPassTheLimit() throws {
        let url = try Self.pdf(Self.photo60.get(), dict: (4000, 2978), name: "lying-dict")
        let plan = try Self.plan(url, .small)
        #expect(plan.largestRaster <= CompressionPlanner.maximumDecodablePixels,
                "Raster mit \(plan.largestRaster) Pixeln")
        #expect(!plan.keepReasons.isEmpty)
    }

    /// Bis zur Grenze bleibt alles beim vollen Raster: Die bisherigen
    /// Ergebnisse dürfen sich nicht ändern. Darüber greift die Reduktion.
    @Test(.hangGuard) func reductionStartsExactlyAboveTheLimit() throws {
        let tiny = try Self.photo(240, 240)
        let target = PixelSize(width: 500, height: 500)
        func level(_ w: Int, _ h: Int) throws -> Int {
            let url = try Self.pdf(tiny, dict: (w, h), name: "level-\(w)")
            let document = try PDFCoreDocument(path: url.path)
            return LibQPDFPixelSource(document: document)
                .decodeLevel(for: try #require(try document.imageResources().first), target: target)
        }
        #expect(try level(6000, 6000) == 0)
        #expect(try level(6001, 6000) > 0)
    }

    /// Flate hat keinen Reduktionsweg: Es bleibt und wird nicht entpackt.
    @Test(.hangGuard) func flateAboveLimitStaysUndecoded() throws {
        let raw = Data(count: 6500 * 6000)
        let data = try #require(ImageProcessor.flate(raw))
        let url = try Self.pdf(data, dict: (6500, 6000), filter: "/Filter/FlateDecode",
                               colorSpace: "/DeviceGray", placed: (500, 462), name: "flate")
        let plan = try Self.plan(url, .small)
        #expect(plan.rasterCount == 0)
        #expect(plan.keepReasons.contains { $0.contains("Pixelbudget") }, "\(plan.keepReasons)")
    }

    /// Qualität braucht hier ein Ziel oberhalb der halben Quelle: Das deckt
    /// nur das volle Raster ab. Es bleibt das Original, Smart und Klein
    /// schrumpfen trotzdem, und die Reihenfolge der Stufen hält.
    @Test(.hangGuard) func targetOnlyCoveredByFullRasterFailsClosed() throws {
        let url = try Self.pdf(Self.photo60.get(), dict: (9000, 6700), placed: (1440, 1072),
                               page: (1500, 1100), name: "60mp-band")
        let quality = try Self.plan(url, .quality)
        #expect(quality.largestRaster <= CompressionPlanner.maximumDecodablePixels)
        #expect(quality.keepReasons.contains { $0.contains("Pixelbudget") }, "\(quality.keepReasons)")
        let sizes: [Int64] = try Self.presets.map { preset in
            Compressor.fileSize(of: try Compressor().compress(inputURL: url, mode: preset.mode).outputURL)
        }
        #expect(sizes[0] < sizes[1] && sizes[1] < sizes[2], "Größen je Stufe: \(sizes)")
    }

    /// Ein zweiter Lauf darf nicht weiter verkleinern.
    @Test(.hangGuard) func secondRunIsStable() throws {
        let url = try Self.pdf(Self.photo60.get(), dict: (9000, 6700), name: "60mp-second")
        let first = try Compressor().compress(inputURL: url, mode: .smart).outputURL
        let second = try Compressor().compress(inputURL: first, mode: .smart).outputURL
        #expect(try Self.firstImage(first).width == Self.firstImage(second).width)
    }

    // MARK: Messung

    /// Spitzenspeicher je Stufe, nur auf Anforderung (prozessweit, deshalb
    /// keine Schwelle; siehe `OperationResourceSampler`):
    ///
    ///     TEST_RUNNER_PDFTOOLS_LARGE_IMAGE_PEAK=<ausgabe.tsv> xcodebuild test …
    ///         -only-testing:PDFToolsTests/LargeImagePresetTests/measurePeak
    ///
    /// `TEST_RUNNER_PDFTOOLS_LARGE_IMAGE_PEAK_DOC=<datei.pdf>` misst statt des
    /// erzeugten Fotos eine echte Datei.
    @Test(.measurementRun) func measurePeak() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PDFTOOLS_LARGE_IMAGE_PEAK"], !path.isEmpty else { return }
        let url = try env["PDFTOOLS_LARGE_IMAGE_PEAK_DOC"].map(URL.init(fileURLWithPath:))
            ?? Self.pdf(Self.photo60.get(), dict: (9000, 6700), name: "60mp-peak")
        var rows = ["stufe\tgroesse\truhe_mb\tspitze_mb"]
        for preset in Self.presets {
            let rest = OperationResourceSampler.currentFootprint() / 1_048_576
            let sampler = OperationResourceSampler(workspace: nil)
            let out = try Compressor().compress(inputURL: url, mode: preset.mode).outputURL
            let peak = sampler.finish().peakFootprintMB
            rows.append("\(preset.mode)\t\(Compressor.fileSize(of: out))\t\(rest)\t\(peak)")
        }
        try rows.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
