import Foundation
import CoreGraphics
import ImageIO

/// Farbneutralität eines JPEG über ein 64-px-Vorschaubild.
///
/// Für die Schnellschätzung: Scans liegen oft als RGB-JPEG mit grauem
/// Inhalt vor. ImageIO erzeugt das Vorschaubild über die DCT-Skalierung des
/// Decoders – ohne die volle Auflösung zu dekodieren (Millisekunden).
enum NeutralChromaProbe {

    /// Mittlere Kanalabweichung (0–255), bis zu der ein Bild als neutral gilt.
    /// Deckt Scanner-Farbstich und JPEG-Chroma-Rauschen ab.
    static let maximumMeanChroma = 6.0
    static let thumbnailEdge = 64

    /// true = farbneutral, false = farbig, nil = nicht lesbar.
    static func isNeutral(jpeg: Data) -> Bool? {
        guard !jpeg.isEmpty,
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: thumbnailEdge,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let width = thumb.width, height = thumb.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &bytes, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
            total += max(abs(r - g), abs(g - b), abs(r - b))
        }
        return Double(total) / Double(width * height) <= maximumMeanChroma
    }
}
