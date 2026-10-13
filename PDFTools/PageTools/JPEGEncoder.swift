import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import pdfcore

/// Phase 1b (Roadmap) – DIE Kodierstelle für JPEG.
///
/// mozjpeg über die C++-Bridge: Pixelbuffer rein, JPEG-Bytes raus (Trellis,
/// progressive Scans, optimierte Huffman-Tabellen). Der reguläre Shim nimmt
/// nur Grau (1) und RGB (3) an – CMYK fällt dort in den ImageIO-Fallback,
/// weil ImageIO die Adobe-APP14-Konvention trägt (CMYKJPEGRoundTripTests).
/// Seit Phase 6C gibt es zusätzlich den KONTROLLIERTEN CMYK-Pfad
/// (`encodeCMYK`) über den eigenen Shim `pdfcore_jpeg_encode_cmyk` – YCCK
/// mit transform 2, hinter dem ΔE-Gate der Phase 6C.
///
/// Never-Grow liegt hier beim Repack: Ein Ergebnis wird nur geliefert, wenn
/// es KLEINER ist als die Originalbytes – sonst bleibt das Original stehen.
enum JPEGEncoder {

    enum RepackOutcome: Equatable {
        /// Neu verpackte Bytes – DCT-Koeffizienten bitidentisch zur Quelle.
        case repacked(Data)
        /// Bereits progressive (SOF2) – die Quelle trägt die Zielverpackung.
        case skipped
        /// Fehler oder kein Größenvorteil – der Aufrufer behält das Original.
        case keepOriginal
    }

    /// Kodiert ein CGImage über das gewählte Backend.
    /// `.mozjpeg` fällt bei Shim-Fehlern automatisch auf ImageIO zurück.
    static func encode(_ image: CGImage, quality: Double,
                       backend: JPEGBackend) -> Data? {
        switch backend {
        case .mozjpeg:
            if let data = encodeMozjpeg(image, quality: quality) { return data }
            return encodeImageIO(image, quality: quality)
        case .imageIO:
            return encodeImageIO(image, quality: quality)
        }
    }

    // MARK: V2-Maps-Perf – vorbereiteter Pixelbuffer je Referenz

    /// Einmal je Referenz bestimmter Pixelbuffer für den mozjpeg-Shim.
    ///
    /// Die Bracketed Quality Search (§9.3) encodiert dieselbe Referenz mit
    /// bis zu fünf Qualitäten – `rawBitmap` hängt NICHT von der Qualität ab
    /// und würde sonst je Rung identisch neu gerechnet. Die Vorbereitung ist
    /// exakt dieselbe Bestimmung wie in `encodeMozjpeg` (Farbmodell →
    /// Komponentenzahl, `ImageResampler.rawBitmap`) und damit
    /// deterministisch identisch zur Neuberechnung: gleiche Bytes in den
    /// Shim, gleiche Bytes heraus – am Kandidatenraum ändert sich nichts.
    struct PreparedPixels {
        let pixels: Data
        let width: Int
        let height: Int
        let components: Int
    }

    /// Bestimmt den Pixelbuffer einmalig; `nil`, wenn der mozjpeg-Shim das
    /// Farbmodell ohnehin nicht annimmt (dann bleibt der bisherige Pfad
    /// mit ImageIO-Fallback wirksam).
    static func preparePixels(_ image: CGImage) -> PreparedPixels? {
        let components: Int
        switch image.colorSpace?.model {
        case .monochrome: components = 1
        case .rgb: components = 3
        default: return nil
        }
        guard let pixels = ImageResampler.rawBitmap(image, components: components) else {
            return nil
        }
        return PreparedPixels(pixels: pixels, width: image.width,
                              height: image.height, components: components)
    }

    /// Encode gegen einen vorbereiteten Pixelbuffer – derselbe Shim-Aufruf
    /// wie `encodeMozjpeg`, derselbe ImageIO-Fallback bei Shim-Fehlern.
    static func encode(_ image: CGImage, quality: Double, backend: JPEGBackend,
                       prepared: PreparedPixels?) -> Data? {
        guard let prepared else {
            return encode(image, quality: quality, backend: backend)
        }
        let data = encode(pixels: prepared.pixels, width: prepared.width,
                          height: prepared.height,
                          components: prepared.components, quality: quality)
        if let data { return data }
        return encodeImageIO(image, quality: quality)
    }

    /// Shim-Aufruf mit fertigem Pixelbuffer (8 Bit, Zeilen ohne Padding).
    private static func encode(pixels: Data, width: Int, height: Int,
                               components: Int, quality: Double) -> Data? {
        let q = max(1, min(100, Int((quality * 100).rounded())))
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status: Int32 = pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_INTERNAL.rawValue)
            }
            return pdfcore_jpeg_encode(base, raw.count,
                                       Int32(width), Int32(height),
                                       Int32(components), Int32(q), &out, &outLen)
        }
        guard status == PDFCORE_OK.rawValue, let buffer = out, outLen > 0 else {
            if let allocated = out { free(allocated) }
            return nil
        }
        defer { free(buffer) }
        return Data(bytes: buffer, count: outLen)
    }

    /// Verlustfreier JPEG-Repack (jpegtran-Semantik) über die Bridge.
    /// `progressive: false` setzt nur optimierte Huffman-Tabellen neu
    /// (Baseline) – für den „Maximale Kompatibilität"-Preset.
    static func repack(_ jpeg: Data, progressive: Bool = true) -> RepackOutcome {
        guard !jpeg.isEmpty else { return .keepOriginal }
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status: Int32 = jpeg.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_JPEG_REPACK_ERR.rawValue)
            }
            return pdfcore_jpeg_repack(base, raw.count,
                                       progressive ? 1 : 0, &out, &outLen)
        }
        if status == PDFCORE_JPEG_REPACK_SKIP.rawValue { return .skipped }
        guard status == PDFCORE_JPEG_REPACK_OK.rawValue, let buffer = out,
              outLen > 0, outLen < jpeg.count else {
            // Never-Grow: Nicht kleiner als das Original → Original behalten.
            if let allocated = out { free(allocated) }
            return .keepOriginal
        }
        defer { free(buffer) }
        return .repacked(Data(bytes: buffer, count: outLen))
    }

    /// Bisheriger Encode-Pfad über ImageIO – Fallback-Backend.
    static func encodeImageIO(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func encodeMozjpeg(_ image: CGImage, quality: Double) -> Data? {
        let components: Int
        switch image.colorSpace?.model {
        case .monochrome: components = 1
        case .rgb: components = 3
        default: return nil
        }
        guard let pixels = ImageResampler.rawBitmap(image, components: components) else {
            return nil
        }
        return encode(pixels: pixels, width: image.width, height: image.height,
                      components: components, quality: quality)
    }

    /// Phase 6C – verlustbehafteter CMYK-Encode über den mozjpeg-Shim.
    ///
    /// YCCK mit Adobe-APP14 (transform 2), 4:4:4 ohne Subsampling – die
    /// Entscheidung trifft der Shim, siehe pdfcore_jpeg_encode_cmyk. Bewusst
    /// KEIN ImageIO-Fallback: Ein CMYK-Kandidat kommt nur zustande, wenn der
    /// Shim ihn liefert; das ΔE-Gate der Phase 6C prüft genau diese Bytes,
    /// und der Fallback bei Misserfolg ist der 6b-Repack, nicht ein
    /// zweiter Kodierer.
    static func encodeCMYK(_ image: CGImage, quality: Double) -> Data? {
        guard let pixels = ImageResampler.rawBitmap(image, components: 4) else {
            return nil
        }
        return encodeCMYK(pixels: pixels, width: image.width,
                          height: image.height, quality: quality)
    }

    /// Variante mit fertigem 4-Kanal-Pixelbuffer (CMYK-Reihenfolge, 8 Bit,
    /// Zeilen ohne Padding).
    static func encodeCMYK(pixels: Data, width: Int, height: Int,
                           quality: Double) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let q = max(1, min(100, Int((quality * 100).rounded())))
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status: Int32 = pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_INTERNAL.rawValue)
            }
            return pdfcore_jpeg_encode_cmyk(base, raw.count,
                                            Int32(width), Int32(height),
                                            Int32(q), &out, &outLen)
        }
        guard status == PDFCORE_OK.rawValue, let buffer = out, outLen > 0 else {
            if let allocated = out { free(allocated) }
            return nil
        }
        defer { free(buffer) }
        return Data(bytes: buffer, count: outLen)
    }
}
