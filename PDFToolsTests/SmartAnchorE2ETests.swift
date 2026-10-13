import Testing
import Foundation
import AppKit
import PDFKit
@testable import PDFTools

/// Nutzerbefund 2026-10-05: „Bei Smart sieht man in den Bildern schon einen
/// argen Verlust, auch ohne stark reinzuzoomen.“ Vertrag (Entscheidung
/// 2026-09-29): Smart ist bei NORMALER Ansicht (144 px/Zoll) mindestens so
/// gut wie der DPI-Anker – Smart-Ziel-DPI (seit 2026-10-09: 220), JPEG q75.
/// Gemessen lag Smart darunter:
/// Die Foto-Grenze (globale SSIM 0,90) ist viel lockerer als der Anker
/// (≈ 0,986), und Smart durfte zusätzlich unter 150 DPI gehen (127 DPI).
///
/// Messung: Je Bildplatzierung SSIM des gerenderten Bildbereichs bei 144 DPI
/// gegen das Original – Smart und Anker (Custom Ziel-DPI/q75) nebeneinander.
/// Artefakt: `benchmark/smart-anchor/result.json`.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Smart liefert Bilder unter Ankerqualität (Fotos verkleinert UND
///     niedrig quantisiert; verlustfreie Bilder auf Originalgröße zu stark
///     nach JPEG gewandelt).
///  2. Die Korrektur nimmt Smart die Ersparnis: Smart wird größer als der
///     Anker selbst.
///  3. Smart rechnet Bilder hoch oder fasst Bilder an, die der Anker
///     unangetastet lässt, und wird dadurch schlechter (fällt unter 1).
@Suite(.serialized) struct SmartAnchorE2ETests {

    static let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tmp/pdfs/core-235", isDirectory: true)
    /// Nutzerdatei (aus PDF_test, lokal unter tmp/pdfs/user): 15 Handyfotos
    /// von Beamer-Folien – hier fiel der Verlust auf.
    static let userFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tmp/pdfs/user/medium.pdf")

    /// Messrauschen zwischen zwei Renderings desselben Inhalts liegt weit
    /// darunter; ein sichtbarer Unterschied weit darüber (Befund: −0,03).
    static let tolerance = 0.003

    struct Region {
        let name: String
        let smart: Double
        let anchor: Double
    }

    /// Bilder über dem Ziel, die der Anker-Lauf NICHT verändert: Für sie gibt
    /// es keinen Anker – der Custom-Lauf verwirft Ziel-DPI/q75 am Katastrophen-
    /// Floor (Punktwolken mit 1850 DPI) oder kodiert Grafiken nur verlustfrei
    /// und scheitert am Never-Grow. Sie werden berichtet, nicht geprüft.
    struct Comparison {
        var regions: [Region] = []
        var anchorRefused: [String] = []
    }

    static func render(_ url: URL, page: Int) -> CGImage? {
        guard let doc = CGPDFDocument(url as CFURL), let p = doc.page(at: page + 1) else { return nil }
        let box = p.getBoxRect(.cropBox)
        let w = Int(box.width * 2), h = Int(box.height * 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(p)
        return ctx.makeImage()
    }

    static func luma(_ image: CGImage, _ rect: CGRect) -> [Double]? {
        let w = Int(rect.width), h = Int(rect.height)
        guard let crop = image.cropping(to: rect) else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: 0) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer.map(Double.init)
    }

    /// SSIM auf 8×8-Fenstern (Schritt 4), Mittel über alle Fenster.
    static func ssim(_ a: [Double], _ b: [Double], width w: Int, height h: Int) -> Double {
        let c1 = 6.5025, c2 = 58.5225
        var sum = 0.0, count = 0
        for y in stride(from: 0, through: h - 8, by: 4) {
            for x in stride(from: 0, through: w - 8, by: 4) {
                var ma = 0.0, mb = 0.0
                for j in 0..<8 { for i in 0..<8 { ma += a[(y + j) * w + x + i]; mb += b[(y + j) * w + x + i] } }
                ma /= 64; mb /= 64
                var va = 0.0, vb = 0.0, cov = 0.0
                for j in 0..<8 { for i in 0..<8 {
                    let da = a[(y + j) * w + x + i] - ma, db = b[(y + j) * w + x + i] - mb
                    va += da * da; vb += db * db; cov += da * db
                } }
                va /= 63; vb /= 63; cov /= 63
                sum += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 1
    }

    /// q75 mit dem JPEG-Kodierer der App – ImageIOs „0,75“ liegt deutlich
    /// feiner und wäre ein anderer, strengerer Maßstab als der Vertrag.
    static func anchorRoundTrip(_ image: CGImage) -> CGImage? {
        ImageResampler.encodeJPEG(image, quality: QualityGatePolicy.smartAnchorQuality,
                                  backend: ImageCompressionOptions.smart.jpegBackend)
            .flatMap { ImageResampler.decodeJPEG($0) }
    }

    static func regions(source: URL, smart: URL, anchor: URL) throws -> Comparison {
        let doc = try #require(CGPDFDocument(source as CFURL))

        var pages: [String: CGImage] = [:]
        func page(_ url: URL, _ index: Int) -> CGImage? {
            let key = "\(url.path)#\(index)"
            if let cached = pages[key] { return cached }
            let image = render(url, page: index)
            pages[key] = image
            return image
        }
        // Der Anker-Lauf (Custom, feste Qualität) kodiert nie auf Original-
        // größe neu: Er hat ein Bild genau dann verändert, wenn es kleiner
        // wurde. (Ein Pixelvergleich der Region täuscht, wo sich Bilder
        // überlappen.)
        var anchorSizes: [String: Int] = [:]
        for resource in try PDFCoreDocument(path: anchor.path).imageResources() {
            for placement in resource.placements {
                anchorSizes["\(placement.pageIndex)#\(placement.resourceName)"] = resource.width
            }
        }
        var result = Comparison()
        for resource in try PDFCoreDocument(path: source.path).imageResources() {
            let withinTarget = resource.placements.allSatisfy {
                Double(resource.width) / max($0.placedWidthPoints, 1) * 72
                    <= ImageCompressionOptions.smart.targetDPI * ImageCompressionOptions.smart.tolerance
            }
            for placement in resource.placements {
                let name = "S\(placement.pageIndex + 1)\(placement.resourceName)"

                guard let t = placement.transform, t.count == 6,
                      let pdfPage = doc.page(at: placement.pageIndex + 1) else { continue }
                let box = pdfPage.getBoxRect(.cropBox)
                let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
                    .applying(CGAffineTransform(a: t[0], b: t[1], c: t[2], d: t[3], tx: t[4], ty: t[5]))
                let rect = CGRect(x: (unit.minX - box.minX) * 2, y: (box.maxY - unit.maxY) * 2,
                                  width: unit.width * 2, height: unit.height * 2).integral
                    .intersection(CGRect(x: 0, y: 0, width: box.width * 2, height: box.height * 2))
                guard rect.width > 64, rect.height > 64,
                      let o = page(source, placement.pageIndex).flatMap({ luma($0, rect) }),
                      let s = page(smart, placement.pageIndex).flatMap({ luma($0, rect) }),
                      let a = page(anchor, placement.pageIndex).flatMap({ luma($0, rect) }) else { continue }
                let w = Int(rect.width), h = Int(rect.height)
                // Hat der Anker das Bild verkleinert, ist er der Maßstab.
                let anchorWidth = anchorSizes["\(placement.pageIndex)#\(placement.resourceName)"]
                if let anchorWidth, anchorWidth < resource.width {
                    result.regions.append(Region(name: name,
                                                 smart: ssim(o, s, width: w, height: h),
                                                 anchor: ssim(o, a, width: w, height: h)))
                    continue
                }
                guard withinTarget else {
                    result.anchorRefused.append(name)
                    continue
                }
                // Liegt das Bild schon auf/unter dem Ziel, lässt der Anker es
                // unangetastet. Maßstab ist dann q75 auf dem Bild in SEINER
                // Pixelgröße (so kodiert der Anker) – nicht „verlustfrei“.
                // Verglichen wird deshalb im Pixelraum des Bildes.
                let scale = min(1, (Double(resource.width * resource.height) / Double(w * h)).squareRoot())
                let native = PixelSize(width: max(8, Int((Double(w) * scale).rounded())),
                                       height: max(8, Int((Double(h) * scale).rounded())))
                let full = CGRect(x: 0, y: 0, width: native.width, height: native.height)
                guard let originalCrop = page(source, placement.pageIndex)?.cropping(to: rect),
                      let smartCrop = page(smart, placement.pageIndex)?.cropping(to: rect),
                      let originalNative = ImageResampler.resize(originalCrop, to: native, components: 3),
                      let smartNative = ImageResampler.resize(smartCrop, to: native, components: 3),
                      let anchorNative = anchorRoundTrip(originalNative),
                      let on = luma(originalNative, full), let sn = luma(smartNative, full),
                      let an = luma(anchorNative, full) else { continue }
                result.regions.append(Region(name: name,
                                             smart: ssim(on, sn, width: native.width, height: native.height),
                                             anchor: ssim(on, an, width: native.width, height: native.height)))
            }
        }
        return result
    }

    static let files: [URL] = [
        corpus.appendingPathComponent("04_PhotoHeavy/2608.23479v1.pdf"),
        corpus.appendingPathComponent("04_PhotoHeavy/Chen_3DTopia-XL_Scaling_High-quality_3D_Asset_Generation_via_Primitive_Diffusion_CVPR_2025_paper.pdf"),
        corpus.appendingPathComponent("05_Mixed_Content/2006.11239.pdf"),
        corpus.appendingPathComponent("06_Scans_Color/light_001.pdf"),
        userFile,
    ]

    @Test(.timeLimit(.minutes(20)), .needsLocalFiles("tmp/pdfs/core-235", "tmp/pdfs/user/medium.pdf"))
    func smartIstBeiNormalerAnsichtMindestensSoGutWieDerAnker() throws {
        var artifact: [[String: Any]] = []
        var failures: [String] = []
        for source in Self.files {
            try #require(FileManager.default.fileExists(atPath: source.path), "Fehlt: \(source.path)")
            let start = Date()
            let smart = try Compressor().compress(inputURL: source, mode: .smart)
            let seconds = Date().timeIntervalSince(start)
            let anchor = try Compressor().compress(
                inputURL: source, options: CompressionPresetFactory.custom(
                    dpi: ImageCompressionOptions.smart.targetDPI,
                    quality: QualityGatePolicy.smartAnchorQuality))
            defer {
                try? FileManager.default.removeItem(at: smart.outputURL)
                try? FileManager.default.removeItem(at: anchor.outputURL)
            }
            let comparison = try Self.regions(source: source, smart: smart.outputURL, anchor: anchor.outputURL)
            let regions = comparison.regions
            let below = regions.filter { $0.smart < $0.anchor - Self.tolerance }
            artifact.append([
                "file": source.lastPathComponent,
                "smart_bytes": smart.outputBytes,
                "anchor_bytes": anchor.outputBytes,
                "smart_seconds": (seconds * 10).rounded() / 10,
                "images": regions.count,
                "anchor_refused": comparison.anchorRefused,
                "below_anchor": below.map { String(format: "%@ %.4f < %.4f", $0.name, $0.smart, $0.anchor) },
                "worst_delta": regions.map { $0.smart - $0.anchor }.min() ?? 0,
            ])
            if !below.isEmpty {                                                  // 1, 3
                failures.append("\(source.lastPathComponent): \(below.count)/\(regions.count) Bilder unter dem Anker, z. B. "
                    + below.prefix(3).map { String(format: "%@ %.4f < %.4f", $0.name, $0.smart, $0.anchor) }
                        .joined(separator: ", "))
            }
            // 2: Smart soll den Anker nicht an Größe übertreffen (5 % Luft
            // für Strukturkosten wie eine zusätzliche Graustufen-Fassung).
            if Double(smart.outputBytes) > Double(anchor.outputBytes) * 1.05 {
                failures.append("\(source.lastPathComponent): Smart \(smart.outputBytes / 1024) KB > Anker \(anchor.outputBytes / 1024) KB")
            }
        }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("benchmark/smart-anchor", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("result.json"))
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}
