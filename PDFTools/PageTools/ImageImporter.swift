import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Images → PDF (Review §65, Feature 4): Bilder werden beim Import in eine
/// einseitige Temp-PDF umgewandelt und sind danach normale Organizer-Seiten –
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
    static func pixelInfo(of url: URL) -> PixelInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return PixelInfo(width: w, height: h, orientation: orientation)
    }

    /// Dekodiert das Bild in Originalpixeln und richtet die EXIF-Orientierung auf.
    private static func uprightCGImage(of url: URL) -> (cgImage: CGImage,
                                                        pixelInfo: PixelInfo)? {
        guard let info = pixelInfo(of: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Thumbnail-API mit Transform = voll auflösend + orientierungskorrigiert.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(info.width, info.height),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return (cg, info)
    }

    /// Wandelt ein Bild in eine einseitige PDF um.
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

    static func singlePagePDF(from imageURL: URL) throws -> URL {
        guard let decoded = uprightCGImage(of: imageURL) else {
            throw ImportError.unreadable(imageURL.lastPathComponent)
        }

        // Der Dekodier-Schritt hat bereits transformiert → cg ist „upright“;
        // Seitengröße = echte Pixelmaße des dekodierten Bildes.
        //
        // Pixel-Deckel (Befund A8, Review 2026-10-09): Die Kompression
        // dekodiert nichts über `maximumDecodablePixels`; ein Import darüber
        // bliebe später unoptimierbar und frisst beim Einbetten Speicher.
        // Deshalb hier proportional auf das Budget verkleinern.
        let cg = try Self.capped(decoded.cgImage, name: imageURL.lastPathComponent)
        let size = CGSize(width: cg.width, height: cg.height)
        let image = NSImage(cgImage: cg, size: size)
        guard let page = PDFPage(image: image) else {
            throw ImportError.encodingFailed(imageURL.lastPathComponent)
        }

        let doc = PDFDocument()
        doc.insert(page, at: 0)

        try FileManager.default.createDirectory(at: sessionDirectory,
                                                withIntermediateDirectories: true)
        let tempURL = sessionDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        guard doc.write(to: tempURL) else {
            throw ImportError.encodingFailed(imageURL.lastPathComponent)
        }
        return tempURL
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
