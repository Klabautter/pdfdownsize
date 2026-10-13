import Foundation
import ImageIO
import CoreGraphics
import Compression
import Accelerate
import pdfcore

// MARK: - Konfiguration je Modus (Startwerte laut Spezifikation)

struct ImageEngineConfig {
    let targetDPI: Double
    let maxPixelEdge: Int
    let jpegQuality: Double
    let ssimThreshold: Double
    let qualityLadder: [Double]
    let tolerance: Double
    let aggressiveGraphics: Bool
    var forceGrayscale: Bool = false
    var hardPixelCap: Bool = false
}

// Hier stand eine ZWEITE Kopie der Smart-Parameter (220 DPI, SSIM 0.98) für
// `SmartCompressor.compressImages` – eine Engine, die niemand mehr aufruft und
// deren Benutzung ein Gate-Test ausdrücklich verbietet
// (CompressionEngineStateTests). Beides ist entfernt.
//
// Die Werte lagen damit an zwei Stellen, und nur eine wurde gepflegt: Als die
// Zielauflösung auf 150 DPI ging, wäre diese Kopie bei 220 stehengeblieben.
// Genau diese Falle hat in diesem Projekt schon einmal zugeschnappt.
// Maßgeblich ist `ImageCompressionOptions.smart`.

// MARK: - Klassifikation (Spezifikation §15–§20)

enum ImageClass {
    case photo
    case graphics
}

struct PixelStats {
    let uniqueColorRatio: Double
    let chromaMean: Double
    let isGrayscale: Bool
    /// Anteil der VIER häufigsten quantisierten Farbschlüssel an den opaken
    /// Pixeln. Flächengrafik (Screenshots, Charts) wird von wenigen Flächen-
    /// farben getragen; kontinuierliche Tönung (Fotos, Verläufe) verteilt.
    let dominantColorShare: Double
}

enum ImageClassifier {

    static func analyze(_ image: CGImage) -> PixelStats {
        let sampleSize = 64
        guard let ctx = CGContext(
            data: nil,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return PixelStats(uniqueColorRatio: 1, chromaMean: 128,
                              isGrayscale: false, dominantColorShare: 0)
        }

        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        guard let buf = ctx.data else {
            return PixelStats(uniqueColorRatio: 1, chromaMean: 128,
                              isGrayscale: false, dominantColorShare: 0)
        }

        let px = buf.bindMemory(to: UInt8.self, capacity: sampleSize * 4)
        var seen = Set<UInt16>()
        var keyCounts: [UInt16: Int] = [:]
        var chromaSum = 0.0
        var opaqueCount = 0
        let total = sampleSize * sampleSize
        // Bugfix (V2-3b-Fund, seit Initial-Commit): Hier stand `sampleSize * 4`
        // – gelesen wurde nur die ERSTE Pixelzeile (64 von 4096 Pixeln). Eine
        // graue/weiße Top-Zeile (Himmel, Dokumentkopf) stufte das Bild damit
        // fälschlich als Graustufen ein und löste den Farbverlust-Pfad aus.
        // bytesPerRow ist exakt sampleSize*4 (ohne Padding), daher deckt
        // sampleSize*sampleSize*4 den gesamten Puffer ab.
        let byteCount = sampleSize * sampleSize * 4

        for i in stride(from: 0, to: byteCount, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let alpha = Int(px[i + 3])
            guard alpha > 32 else { continue }
            opaqueCount += 1

            let key = UInt16((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4))
            seen.insert(key)
            keyCounts[key, default: 0] += 1

            let c = max(r, g, b) - min(r, g, b)
            chromaSum += Double(c)
        }

        let denom = max(1, opaqueCount)
        let uniqueRatio = Double(seen.count) / Double(min(total, denom))
        let chromaMean = chromaSum / Double(denom)
        let sortedCounts = keyCounts.values.sorted(by: >)
        let top4 = sortedCounts.prefix(4).reduce(0, +)
        let dominantShare = Double(top4) / Double(denom)

        return PixelStats(
            uniqueColorRatio: uniqueRatio,
            chromaMean: chromaMean,
            isGrayscale: chromaMean < 1.5,
            dominantColorShare: dominantShare
        )
    }

    static func classify(_ stats: PixelStats) -> ImageClass {
        // Kalibrierung nach dem Zeilen-Bugfix (siehe analyze): Bei
        // Vollflächenmessung haben kontinuierliche Verläufe ebenfalls wenige
        // 4-bit-Quantisierungsschlüssel – „wenige Farben“ allein ist KEIN
        // Flächengrafik-Beweis mehr. Flächengrafik (Screenshots, Charts,
        // Diagramme) wird von wenigen Flächenfarben GETRAGEN (Top-4-Schlüssel
        // decken die Mehrheit der Fläche); Verläufe verteilen ihre Farben ohne
        // Schwerpunkt und sind kontinuierliche Tönung → JPEG-Pfad (kleiner,
        // quality-gated).
        //
        // Die Schwelle 0.60 ist gemessen, nicht gegriffen (V2-3b-Diagnose,
        // /tmp/opencode/hist-*.log): Ein glatter chromatischer Verlauf
        // (NSGradient-Foto, 3000×3000) konzentriert durch die 4-bit-
        // Quantisierung immer noch auf d = 0.53 – 0.50 würde ihn als
        // Flächengrafik einstufen (Flate statt DCT). Echte Flächengrafik
        // liegt deutlich darüber: Kachelpalette 0.68, Kacheln+Verlauf 0.80,
        // Screenshot 1.00; Grau-Balkenmuster 0.71/0.87. 0.60 liegt exakt auf
        // der Messmitte zwischen Verlauf (0.53) und nächster Grafik (0.68).
        if stats.uniqueColorRatio < 0.08 && stats.dominantColorShare > 0.60 {
            return .graphics
        }
        if stats.chromaMean < 2.0 && stats.uniqueColorRatio < 0.25
            && stats.dominantColorShare > 0.50 {
            return .graphics
        }
        return .photo
    }
}

// MARK: - Bildverarbeitung

enum ImageProcessorError: Error {
    case unsupported
}

enum ImageProcessor {
    // Der früherer Engine-Pfad (optimize/decode/planResize) ist mit dem
    // V2-Cutover entfernt (§4.18): Dekodieren und Resampeln laufen über
    // LibQPDFPixelSource/ImageResampler im Candidate-Pfad. Geblieben sind
    // die reinen Byte-/Pixelhelfer (flate) und die Qualitätsmessung.

    // MARK: Deflate mit zlib-Wrapper

    /// Echtes zlib (Standard-Level 6) über die C-Bridge – für alle Bild-
    /// Streams, die die Pipeline erzeugt oder bewertet. Apples ZLIB-Variante
    /// (`flate`) fiel auf glatten Bildern bis 4× größer aus (34.244 statt
    /// 7.963 B); die Planung bewertete Flate-Kandidaten damit falsch
    /// (2026-10-01). `flate` bleibt für Testvorlagen, deren Bytes Tests
    /// festhalten.
    static func flateBest(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status: Int32 = input.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_INTERNAL.rawValue)
            }
            return pdfcore_flate_compress(base, raw.count, -1, &out, &outLen)
        }
        guard status == PDFCORE_OK.rawValue, let buffer = out, outLen > 0 else {
            if let allocated = out { free(allocated) }
            return nil
        }
        defer { free(buffer) }
        return Data(bytes: buffer, count: outLen)
    }

    static func flate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = max(64, input.count + input.count / 2 + 64)
        var dst = Data(count: capacity)

        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            input.withUnsafeBytes { srcPtr -> Int in
                guard let src = srcPtr.bindMemory(to: UInt8.self).baseAddress,
                      let dstBase = dstPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstBase, capacity, src, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }

        var out = Data([0x78, 0x9C])
        out.append(dst.prefix(written))

        var a1: UInt32 = 1, a2: UInt32 = 0
        for byte in input {
            a1 = (a1 + UInt32(byte)) % 65521
            a2 = (a2 + a1) % 65521
        }
        let adler = (a2 << 16) | a1
        out.append(contentsOf: [
            UInt8((adler >> 24) & 0xFF),
            UInt8((adler >> 16) & 0xFF),
            UInt8((adler >> 8) & 0xFF),
            UInt8(adler & 0xFF)
        ])
        return out
    }
}

// MARK: - Perceptual Quality Measurement (Spezifikation §26)

enum QualityMetrics {

    static let sampleEdge = 320
    private static let c1: Float = 6.5025    // (0.01 * 255)^2
    private static let c2: Float = 58.5225   // (0.03 * 255)^2
    private static let window = 8

    static func ssim(original: CGImage, candidate: CGImage) -> Double {
        guard let ref = luma(original), let cand = luma(candidate),
              ref.width == cand.width, ref.height == cand.height else {
            return 1.0
        }

        let w = ref.width
        let h = ref.height
        var total: Float = 0
        var blocks = 0

        let wa = ref.values
        let wb = cand.values

        var by = 0
        while by + window <= h {
            var bx = 0
            while bx + window <= w {
                var sumA: Float = 0, sumB: Float = 0
                for y in by..<(by + window) {
                    let row = y * w + bx
                    for i in 0..<window {
                        sumA += wa[row + i]
                        sumB += wb[row + i]
                    }
                }
                let n = Float(window * window)
                let muA = sumA / n
                let muB = sumB / n

                var varA: Float = 0, varB: Float = 0, cov: Float = 0
                for y in by..<(by + window) {
                    let row = y * w + bx
                    for i in 0..<window {
                        let da = wa[row + i] - muA
                        let db = wb[row + i] - muB
                        varA += da * da
                        varB += db * db
                        cov += da * db
                    }
                }
                varA /= n - 1
                varB /= n - 1
                cov /= n - 1

                let num = (2 * muA * muB + c1) * (2 * cov + c2)
                let den = (muA * muA + muB * muB + c1) * (varA + varB + c2)
                total += num / den
                blocks += 1
                bx += window
            }
            by += window
        }

        guard blocks > 0 else { return 1.0 }
        defer { ref.free(); cand.free() }
        return Double(total / Float(blocks))
    }

    private struct Luma {
        let values: UnsafeMutablePointer<Float>
        let width: Int
        let height: Int

        func free() {
            values.deallocate()
        }
    }

    private static func luma(_ image: CGImage) -> Luma? {
        var w = min(sampleEdge, max(window, image.width))
        let rawH = Int((Double(w) / max(0.0001, Double(image.width) / Double(max(1, image.height)))).rounded())
        var h = min(sampleEdge, max(window, rawH))
        w -= w % window
        h -= h % window
        guard w >= window, h >= window else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }

        let src = data.bindMemory(to: UInt8.self, capacity: w * h)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: w * h)

        vDSP_vfltu8(src, 1, out, 1, vDSP_Length(w * h))

        return Luma(values: out, width: w, height: h)
    }
}

// MARK: - Orchestrierung
