import CoreGraphics

/// Farbzählung eines Bilds – die EINE Grau/Farbe-Entscheidung, die
/// Klassifikation (`ImageClassifier`) und Qualitäts-Gate (`QualityGates`)
/// teilen (Masterplan A1, 18.11.2026).
///
/// Vorher entschied ein Mittelwert: Chroma (max−min je Pixel) über eine
/// 64×64-Stichprobe, „grau“ unter 1,5. Eine blaue Unterschrift auf einem
/// weißen Brief mittelte sich dabei auf null weg – Klein lieferte die Seite
/// als Graustufenbild, und das ΔE-Gate griff nicht, weil es dieselbe
/// Schwelle benutzte.
///
/// Jetzt gilt ein Bild nur dann als grau, wenn es im Mittel farblos ist UND
/// keine zusammenhängende farbige Stelle hat:
///  - `strongFraction`: Anteil der 4×4-Blöcke mit Chroma > 40. Die
///    Mittelung dämpft Farbsäume an schwarzer Schrift und einzelne
///    JPEG-Rauschpixel; ein Kugelschreiberstrich bleibt stehen.
///  - `peakTileFraction`: höchster Anteil solcher Blöcke in einer Kachel
///    von 16×16 Blöcken (64 px) – ein Stempel in der Ecke zählt, auch wenn
///    er auf der ganzen Seite nur wenig Fläche hat.
///
/// Der Plan nannte 2×2 als Startwert. Ein 1-px-Farbsaum mit Chroma 140
/// (ChromaCensusTests) ergab nach 2×2-Mittelung noch Chroma 70 und kippte
/// eine Schwarzweiß-Seite auf „farbig“ – genau der dort vorgesehene Fall für
/// die gröbere Mittelung statt einer weicheren Schwelle.
struct ChromaCensus: Equatable, Sendable {
    /// Mittlere Chroma je Pixel (wie bisher; trägt Papierton und Farbstich).
    let meanChroma: Double
    /// Anteil der 4×4-Blöcke mit Chroma > `strongChroma`.
    let strongFraction: Double
    /// Höchster Anteil starker Blöcke in einer Kachel aus 16×16 Blöcken.
    let peakTileFraction: Double

    /// max−min nach Mittelung über einen Block.
    static let strongChroma = 40
    /// Startwerte (Masterplan A1); Kalibrierung am Korpus siehe
    /// `ChromaCensusCalibration`. Kippt ein echter Schwarzweiß-Scan wegen
    /// Farbsäumen, wird die Mittelung vergröbert – nicht die Schwelle weich.
    static let maxStrongFraction = 0.0002
    static let maxPeakTileFraction = 0.05
    /// Mittelwert-Schwelle der bisherigen Entscheidung.
    static let maxNeutralMeanChroma = 1.5
    /// Kantenlänge des Zählrasters.
    static let rasterEdge = 1024
    /// Kantenlänge eines Mittelungsblocks in Pixeln.
    static let blockEdge = 4
    static let tileBlocks = 16

    static let neutral = ChromaCensus(meanChroma: 0, strongFraction: 0, peakTileFraction: 0)

    /// Grau heißt: wenig mittlere Farbe UND keine zusammenhängende farbige Stelle.
    var isNeutral: Bool {
        meanChroma < Self.maxNeutralMeanChroma
            && strongFraction <= Self.maxStrongFraction
            && peakTileFraction <= Self.maxPeakTileFraction
    }

    /// Zeichnet das Bild auf höchstens `rasterEdge` px Kantenlänge (nie
    /// hoch) und zählt dort. nil nur, wenn kein Zeichenkontext entsteht.
    static func of(_ image: CGImage, maxEdge: Int = rasterEdge) -> ChromaCensus? {
        let scale = min(1, Double(maxEdge) / Double(max(image.width, image.height, 1)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return measure(rgba: buffer, width: w, height: h)
    }

    /// Zählt auf einem vorhandenen RGBA-Raster (4 Byte je Pixel, Alpha zuletzt).
    /// Pixel mit Alpha ≤ 32 zählen nicht (wie in `ImageClassifier`).
    static func measure(rgba: [UInt8], width: Int, height: Int) -> ChromaCensus {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return .neutral }
        return rgba.withUnsafeBufferPointer { px -> ChromaCensus in
            var chromaSum = 0
            var opaque = 0
            for i in stride(from: 0, to: width * height * 4, by: 4) where px[i + 3] > 32 {
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                chromaSum += max(r, g, b) - min(r, g, b)
                opaque += 1
            }
            let mean = opaque > 0 ? Double(chromaSum) / Double(opaque) : 0

            // Blöcke von blockEdge × blockEdge; ein Rest am Rand zählt nicht.
            let e = blockEdge
            let bw = width / e, bh = height / e
            guard bw > 0, bh > 0 else {
                return ChromaCensus(meanChroma: mean, strongFraction: 0, peakTileFraction: 0)
            }
            let tilesX = (bw + tileBlocks - 1) / tileBlocks
            let tilesY = (bh + tileBlocks - 1) / tileBlocks
            var tileStrong = [Int](repeating: 0, count: tilesX * tilesY)
            var tileTotal = [Int](repeating: 0, count: tilesX * tilesY)
            var strong = 0
            var blocks = 0
            let threshold = strongChroma * e * e   // Summe statt Mittel
            for by in 0..<bh {
                let tileRow = (by / tileBlocks) * tilesX
                for bx in 0..<bw {
                    var r = 0, g = 0, b = 0
                    var transparent = false
                    for dy in 0..<e {
                        var o = ((by * e + dy) * width + bx * e) * 4
                        for _ in 0..<e {
                            if px[o + 3] <= 32 { transparent = true }
                            r += Int(px[o]); g += Int(px[o + 1]); b += Int(px[o + 2])
                            o += 4
                        }
                    }
                    // Ein Block mit durchsichtigen Pixeln zählt nicht.
                    if transparent { continue }
                    let tile = tileRow + bx / tileBlocks
                    blocks += 1
                    tileTotal[tile] += 1
                    if max(r, g, b) - min(r, g, b) > threshold {
                        strong += 1
                        tileStrong[tile] += 1
                    }
                }
            }
            var peak = 0.0
            // Randkacheln mit weniger als einem Viertel der Blöcke zählen
            // nicht: Dort machte schon ein einzelner Farbblock 5 % aus.
            let minimumTileBlocks = tileBlocks * tileBlocks / 4
            for t in 0..<tileTotal.count where tileTotal[t] >= minimumTileBlocks {
                peak = max(peak, Double(tileStrong[t]) / Double(tileTotal[t]))
            }
            return ChromaCensus(meanChroma: mean,
                                strongFraction: blocks > 0 ? Double(strong) / Double(blocks) : 0,
                                peakTileFraction: peak)
        }
    }
}
