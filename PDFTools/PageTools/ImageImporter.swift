import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Images → PDF (Review §65, Feature 4): Bilder werden beim Import in eine
/// Temp-PDF umgewandelt (eine Seite je Bild, mehrseitige TIFFs komplett) und sind danach normale Organizer-Seiten –
/// mischbar mit PDF-Seiten, inkl. Reorder/Extract/Split/Bildexport.
enum ImageImporter {

    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp",
    ]

    /// Fester Session-Ordner für konvertierte Bild-PDFs.
    static var sessionDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-image-imports", isDirectory: true)
    }

    /// Räumt Reste FRÜHERER Sessions weg (jeder App-Start beginnt eine neue Session;
    /// Dateien der laufenden Session entstehen erst danach und bleiben unberührt).
    static func cleanupStaleImports() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: sessionDirectory,
                                                         includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? fm.removeItem(at: url)
        }
    }

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static var allowedTypes: [UTType] { [.pdf, .image] }

    // MARK: Echte Pixelmaße (Review P0.3)

    struct PixelInfo {
        let width: Int
        let height: Int
        /// EXIF-Orientierung (1–8), 1 = up.
        let orientation: Int
    }

    /// Liest Pixelmaße + Orientation aus den Metadaten – NICHT `NSImage.size`
    /// (das ist eine durch DPI-Metadaten skalierte Punktgröße).
    static func pixelInfo(of url: URL, index: Int = 0) -> PixelInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelInfo(of: source, index: index)
    }

    private static func pixelInfo(of source: CGImageSource, index: Int) -> PixelInfo? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return PixelInfo(width: w, height: h, orientation: orientation)
    }

    /// Masterplan E5: Seiten einer Bilddatei. Mehrseitige TIFFs (Fax, Scanner)
    /// liefern jede Seite; vorher kam nur Bild 0 an. Andere Formate mit
    /// mehreren Bildern (animiertes GIF, HEIC-Serien) bleiben bei einem Bild –
    /// dort sind die weiteren Bilder keine Seiten.
    static func pageCount(of source: CGImageSource) -> Int {
        let type = CGImageSourceGetType(source) as String?
        guard type == UTType.tiff.identifier else { return 1 }
        return max(1, CGImageSourceGetCount(source))
    }

    /// Dekodiert ein Bild in Originalpixeln und richtet die EXIF-Orientierung auf.
    ///
    /// N14 (D6): Über `maximumPixels` dekodiert ImageIO gleich auf die
    /// gedeckelte Kantenlänge – vorher entstand erst das volle Raster (ein
    /// 400-MP-Scan: 1,6 GB) und wurde danach verkleinert.
    private static func uprightCGImage(of source: CGImageSource, index: Int) -> CGImage? {
        guard let info = pixelInfo(of: source, index: index) else { return nil }
        let count = info.width * info.height
        var edge = max(info.width, info.height)
        if count > maximumPixels {
            let factor = (Double(maximumPixels) / Double(count)).squareRoot()
            edge = max(1, Int((Double(edge) * factor).rounded(.down)))
        }
        // Thumbnail-API mit Transform = orientierungskorrigiert, bis `edge`.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// Wandelt eine Bilddatei in eine PDF um – eine Seite je Bild (mehrseitige
    /// TIFFs: jede Seite, Masterplan E5).
    /// Seitenpunkte = Originalpixel (1:1, „An Bild anpassen“); die EXIF-
    /// Orientierung wird beim Dekodieren aufgerichtet (Thumbnail-Transform).
    /// Kein Upscaling, kein DPI-bedingtes Downsamplen (Review P0.3).
    static let maximumPixels = CompressionPlanner.maximumDecodablePixels

    static func capped(_ cg: CGImage, name: String) throws -> CGImage {
        let count = cg.width * cg.height
        guard count > maximumPixels else { return cg }
        let factor = (Double(maximumPixels) / Double(count)).squareRoot()
        let target = PixelSize(width: max(1, Int((Double(cg.width) * factor).rounded(.down))),
                               height: max(1, Int((Double(cg.height) * factor).rounded(.down))))
        guard let resized = ImageResampler.resize(cg, to: target, components: 3) else {
            throw ImportError.encodingFailed(name)
        }
        return resized
    }

    struct ImportedPDF {
        let url: URL
        let pageCount: Int
    }

    static func pdf(from imageURL: URL) throws -> ImportedPDF {
        let name = imageURL.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
            throw ImportError.unreadable(name)
        }
        let doc = PDFDocument()
        for index in 0..<pageCount(of: source) {
            // Der Dekodier-Schritt hat bereits transformiert → cg ist „upright“;
            // Seitengröße = echte Pixelmaße des dekodierten Bildes.
            //
            // Pixel-Deckel (Befund A8, Review 2026-10-09): Die Kompression
            // dekodiert nichts über `maximumDecodablePixels`; ein Import darüber
            // bliebe später unoptimierbar und frisst beim Einbetten Speicher.
            // Deshalb hier proportional auf das Budget verkleinern.
            try autoreleasepool {
                guard let decoded = uprightCGImage(of: source, index: index) else {
                    throw ImportError.unreadable(name)
                }
                let cg = try Self.capped(decoded, name: name)
                let image = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
                guard let page = PDFPage(image: image) else { throw ImportError.encodingFailed(name) }
                doc.insert(page, at: doc.pageCount)
            }
        }

        try FileManager.default.createDirectory(at: sessionDirectory,
                                                withIntermediateDirectories: true)
        let tempURL = sessionDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        guard doc.write(to: tempURL) else {
            throw ImportError.encodingFailed(name)
        }
        return ImportedPDF(url: tempURL, pageCount: doc.pageCount)
    }

    enum ImportError: LocalizedError {
        case unreadable(String)
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return String(localized: "Bild konnte nicht gelesen werden: \(name)")
            case .encodingFailed(let name):
                return String(localized: "Bild konnte nicht in eine PDF-Seite umgewandelt werden: \(name)")
            }
        }
    }
}
