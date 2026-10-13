import Foundation
import CoreGraphics

// MARK: - Masterplan §8.1/§8.2 – Feature Extractor

/// Extrahiert `ContentFeatures` aus dekodierten Pixeln.
///
/// Multi-Resolution-Sampling (§8.2):
///
///     64×64  → cheap global (Farbe, Entropie, verbundene Komponenten)
///     128×128 → edge/texture (Sobel, Kachelvarianz, Text-Kacheln)
///     256×256 → nur bei ambiger Klassifikation (Vertrauen < Schwelle)
///
/// Hohe Confidence überspringt den dritten Pass. Alles arbeitet auf EINER
/// downgesampelten RGBA-Stichprobe je Stufe (ein Zeichenvorgang je Stufe,
/// Interpolation `.medium` wie `ImageClassifier`/`QualityGates`) und ist
/// deterministisch: gleiche Bytes → gleiche Features (gleicher Build).
enum ContentFeatureExtractor {

    /// Kantenlänge der globalen Stichprobe.
    static let globalEdge = 64
    /// Kantenlänge der Detailstichprobe (edge/texture).
    static let detailEdge = 128
    /// Kantenlänge des optionalen dritten Passes.
    static let fineEdge = 256
    /// Vertrauen, ab dem kein dritter Pass nötig ist.
    static let confidentThreshold = 0.75

    /// Sobel-Schwelle und Flat-Grenze – bewusst dieselben Größenordnungen wie
    /// `QualityGates` (edgeMagnitudeThreshold 32, Kachelvarianz als Fläche).
    static let edgeMagnitudeThreshold: Float = 32.0
    static let flatTileVariance: Double = 25.0
    /// Kachel-Kantendichte, ab der eine Kachel als „harte Kanten“ zählt.
    static let hardEdgeTileDensity = 0.06

    /// Extrahiert die Merkmale; nil, wenn das Bild nicht sampelbar ist.
    static func extract(from image: CGImage) -> ContentFeatures? {
        // Pass 1 – global: Farbe, Entropie, verbundene Komponenten.
        guard let global = Sample(image: image, edge: globalEdge) else { return nil }
        let color = colorFeatures(global)
        let entropy = lumaEntropy(global.luma)
        let components = connectedComponents(global)

        // Pass 2 – detail: Struktur.
        guard let detail = Sample(image: image, edge: detailEdge) else { return nil }
        var structure = structureFeatures(detail)

        var verdict = ContentClassifier.classify(
            features: features(color: color, entropy: entropy, components: components,
                               structure: structure),
            context: ContentClassifier.ClassificationContext())

        // Pass 3 – nur bei ambiger Klasse (§8.2: hohe Confidence spart ihn).
        if verdict.confidence < confidentThreshold,
           let fine = Sample(image: image, edge: fineEdge) {
            structure = structureFeatures(fine)
            verdict = ContentClassifier.classify(
                features: features(color: color, entropy: entropy, components: components,
                                   structure: structure),
                context: ContentClassifier.ClassificationContext())
        }

        return ContentFeatures(
            sampleWidth: structure.sampleEdge,
            sampleHeight: structure.sampleEdge,
            uniqueColorRatio: color.uniqueColorRatio,
            exactColorCountHint: color.exactColorCountHint,
            chromaMean: color.chromaMean,
            grayscaleScore: color.grayscaleScore,
            entropy: entropy,
            localVarianceMean: structure.localVarianceMean,
            localVarianceP90: structure.localVarianceP90,
            edgeDensity: structure.edgeDensity,
            horizontalEdgeRatio: structure.horizontalEdgeRatio,
            verticalEdgeRatio: structure.verticalEdgeRatio,
            diagonalEdgeRatio: structure.diagonalEdgeRatio,
            connectedComponentDensity: components?.density,
            smallComponentRatio: components?.smallRatio,
            flatAreaRatio: structure.flatAreaRatio,
            textureRatio: structure.textureRatio,
            textLikeTileRatio: structure.textLikeTileRatio,
            confidence: verdict.confidence)
    }

    // MARK: Stichprobe

    /// Eine RGBA-Stichprobe fester Kantenlänge. Bei nicht-quadratischen
    /// Bildern bestimmt das Seitenverhältnis die zweite Kante (wie
    /// `QualityGates.sample`), mindestens 8 px.
    struct Sample {
        let width: Int
        let height: Int
        /// RGBA-Bytes (4 je Bildpunkt).
        let rgba: [UInt8]
        /// Luminanz (Rec. 601) je Bildpunkt.
        let luma: [Int]

        var pixelCount: Int { width * height }

        init?(image: CGImage, edge: Int) {
            guard edge >= 8 else { return nil }
            let w = max(8, edge)
            let rawH = Int((Double(w) / max(0.0001,
                Double(image.width) / Double(max(1, image.height)))).rounded())
            let h = max(8, min(rawH, edge * 2))

            guard let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { return nil }

            let count = w * h
            let px = data.bindMemory(to: UInt8.self, capacity: count * 4)
            self.width = w
            self.height = h
            self.rgba = Array(UnsafeBufferPointer(start: px, count: count * 4))

            var luma = [Int](repeating: 0, count: count)
            for i in 0..<count {
                let o = i * 4
                luma[i] = (299 * Int(rgba[o]) + 587 * Int(rgba[o + 1])
                           + 114 * Int(rgba[o + 2])) / 1000
            }
            self.luma = luma
        }
    }

    // MARK: Farbmerkmale (§8.1 Farbe)

    struct ColorFeatures {
        let uniqueColorRatio: Double
        let exactColorCountHint: Int?
        let chromaMean: Double
        let grayscaleScore: Double
        let meanLuma: Double
    }

    static func colorFeatures(_ sample: Sample) -> ColorFeatures {
        var seenQuantized = Set<UInt16>()
        var seenExact = Set<UInt32>()
        var chromaSum = 0
        var nearGray = 0
        var lumaSum = 0
        var opaque = 0

        let count = sample.pixelCount
        for i in 0..<count {
            let o = i * 4
            let r = Int(sample.rgba[o])
            let g = Int(sample.rgba[o + 1])
            let b = Int(sample.rgba[o + 2])
            let alpha = Int(sample.rgba[o + 3])
            guard alpha > 32 else { continue }
            opaque += 1

            // 4-bit-Quantisierung – derselbe Schlüssel wie ImageClassifier.
            seenQuantized.insert(UInt16((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)))
            // Exakte Tripel nur solange die Menge klein bleibt (Hint).
            if seenExact.count <= 512 {
                seenExact.insert(UInt32(r << 16 | g << 8 | b))
            }

            let chroma = max(r, g, b) - min(r, g, b)
            chromaSum += chroma
            if chroma <= 2 { nearGray += 1 }
            lumaSum += sample.luma[i]
        }

        let denom = max(1, opaque)
        let exact = seenExact.count <= 512 ? seenExact.count : nil
        return ColorFeatures(
            uniqueColorRatio: Double(seenQuantized.count) / Double(denom),
            exactColorCountHint: exact,
            chromaMean: Double(chromaSum) / Double(denom),
            grayscaleScore: Double(nearGray) / Double(denom),
            meanLuma: Double(lumaSum) / Double(denom))
    }

    /// Shannon-Entropie des 64-Bin-Luminanzhistogramms in bit.
    static func lumaEntropy(_ luma: [Int]) -> Double {
        var bins = [Int](repeating: 0, count: 64)
        for v in luma { bins[min(255, max(0, v)) >> 2] += 1 }
        let total = Double(max(1, luma.count))
        var entropy = 0.0
        for b in bins where b > 0 {
            let p = Double(b) / total
            entropy -= p * log2(p)
        }
        return entropy
    }

    // MARK: Strukturmerkmale (§8.1 Struktur/Statistik)

    struct StructureFeatures {
        let sampleEdge: Int
        let localVarianceMean: Double
        let localVarianceP90: Double
        let edgeDensity: Double
        let horizontalEdgeRatio: Double
        let verticalEdgeRatio: Double
        let diagonalEdgeRatio: Double
        let flatAreaRatio: Double
        let textureRatio: Double
        let textLikeTileRatio: Double
    }

    /// Sobel, Kachelvarianz und Flächencharakter auf EINER Stichprobe.
    /// Kachelraster: 8×8 Kacheln über die Stichprobe (wie QualityGates) –
    /// damit bleibt die Merkmalssemantik auflösungsinvariant zwischen den
    /// Detail- und Fine-Pässen.
    static func structureFeatures(_ sample: Sample) -> StructureFeatures {
        let w = sample.width
        let h = sample.height
        let luma = sample.luma.map { Float($0) }

        // Sobel (identische Konstanten wie QualityGates.sobelMagnitudes).
        var magnitudes = [Float](repeating: 0, count: w * h)
        var horizontal = 0
        var vertical = 0
        var diagonal = 0
        var edgePixels = 0
        var interior = 0
        if w >= 3, h >= 3 {
            for y in 1..<(h - 1) {
                let row = y * w
                for x in 1..<(w - 1) {
                    interior += 1
                    let tl = luma[row - w + x - 1], t = luma[row - w + x]
                    let tr = luma[row - w + x + 1]
                    let l = luma[row + x - 1], r = luma[row + x + 1]
                    let bl = luma[row + w + x - 1], b = luma[row + w + x]
                    let br = luma[row + w + x + 1]
                    let gx = (tr + 2 * r + br) - (tl + 2 * l + bl)
                    let gy = (bl + 2 * b + br) - (tl + 2 * t + tr)
                    let mag = (gx * gx + gy * gy).squareRoot() / 4
                    magnitudes[row + x] = mag
                    guard mag >= edgeMagnitudeThreshold else { continue }
                    edgePixels += 1
                    let ax = abs(gx), ay = abs(gy)
                    if ay >= 2 * ax {
                        horizontal += 1     // horizontale Kante: starker Vertikalgradient
                    } else if ax >= 2 * ay {
                        vertical += 1
                    } else {
                        diagonal += 1
                    }
                }
            }
        }
        let edgeCount = max(1, edgePixels)
        let edgeDensity = interior > 0 ? Double(edgePixels) / Double(interior) : 0

        // 8×8-Kachelraster: Varianz, Flach-/Textur-/Text-Charakter.
        let tilesX = 8
        let tilesY = 8
        let tileW = max(1, w / tilesX)
        let tileH = max(1, h / tilesY)
        var variances: [Double] = []
        var flatTiles = 0
        var textureTiles = 0
        var textTiles = 0
        var tileCount = 0

        var tileY = 0
        while tileY < h {
            let tileHUsed = min(tileH, h - tileY)
            var tileX = 0
            while tileX < w {
                let tileWUsed = min(tileW, w - tileX)
                let n = tileWUsed * tileHUsed
                var sum = 0
                var minV = 255
                var maxV = 0
                var dark = 0
                var transitions = 0
                var edgeInTile = 0
                for y in tileY..<(tileY + tileHUsed) {
                    let row = y * w
                    for x in tileX..<(tileX + tileWUsed) {
                        let v = sample.luma[row + x]
                        sum += v
                        if v < minV { minV = v }
                        if v > maxV { maxV = v }
                        if v < 128 { dark += 1 }
                        if magnitudes[row + x] >= edgeMagnitudeThreshold { edgeInTile += 1 }
                        if x + 1 < tileX + tileWUsed {
                            if (v < 128) != (sample.luma[row + x + 1] < 128) { transitions += 1 }
                        }
                        if y + 1 < tileY + tileHUsed {
                            if (v < 128) != (sample.luma[row + w + x] < 128) { transitions += 1 }
                        }
                    }
                }
                let mean = Double(sum) / Double(n)
                var variance = 0.0
                for y in tileY..<(tileY + tileHUsed) {
                    let row = y * w
                    for x in tileX..<(tileX + tileWUsed) {
                        let d = Double(sample.luma[row + x]) - mean
                        variance += d * d
                    }
                }
                variance /= Double(n)
                variances.append(variance)

                let edgeFraction = Double(edgeInTile) / Double(n)
                let darkFraction = Double(dark) / Double(n)
                let transitionDensity = Double(transitions) / Double(2 * n)
                let contrast = maxV - minV
                let isFlat = variance <= flatTileVariance
                let isHardEdge = edgeFraction >= hardEdgeTileDensity
                if isFlat { flatTiles += 1 }
                // Textur-Kachel = Fotomaterial: mittlere Struktur OHNE harte
                // Kanten und OHNE die Schwarz-Weiß-Wechsel von Linien/Text.
                // Die früheren Dunkelanteil-Grenzen verfehlten Gradienten-
                // fotos (ganz helle/ganz dunkle Kacheln); der Wechsel-Schwelle
                // genügt: Linien-/Textkacheln haben viele, Fotos kaum.
                if !isFlat && !isHardEdge
                    && contrast < 240 && transitionDensity < 0.05 {
                    textureTiles += 1
                }
                // Text-Kachel: Kriterien analog QualityGates.textRegionScore.
                if darkFraction >= 0.01 && darkFraction <= 0.92
                    && transitionDensity >= 0.02 && contrast >= 64 {
                    textTiles += 1
                }
                tileCount += 1
                tileX += tileWUsed
            }
            tileY += tileHUsed
        }

        let tiles = max(1, tileCount)
        let sortedVariances = variances.sorted()
        return StructureFeatures(
            sampleEdge: w,
            localVarianceMean: variances.reduce(0, +) / Double(tiles),
            localVarianceP90: percentile(sortedVariances, 0.90),
            edgeDensity: edgeDensity,
            horizontalEdgeRatio: Double(horizontal) / Double(edgeCount),
            verticalEdgeRatio: Double(vertical) / Double(edgeCount),
            diagonalEdgeRatio: Double(diagonal) / Double(edgeCount),
            flatAreaRatio: Double(flatTiles) / Double(tiles),
            textureRatio: Double(textureTiles) / Double(tiles),
            textLikeTileRatio: Double(textTiles) / Double(tiles))
    }

    /// Nearest-rank-Perzentil (dieselbe Konvention wie QualityGates).
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1,
                        max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))
        return sorted[index]
    }

    // MARK: Verbundene Komponenten (§8.1 Dokumentähnlichkeit)

    struct ComponentFeatures {
        /// Komponenten je Tinten-Pixel.
        let density: Double
        /// Anteil der Komponenten mit Fläche ≤ 4 px.
        let smallRatio: Double
    }

    /// 4-Konnektivität auf der BINÄREN 64×64-Stichprobe – bewusst nur die
    /// kleine Stichprobe, keine Vollbild-CV (§8.1). Tinte = Minderheitsklasse
    /// (bei Gleichstand: dunkel), damit schwarze Schrift auf weißem Grund und
    /// weiße Schrift auf schwarzem Grund gleichwertig behandelt werden.
    static func connectedComponents(_ sample: Sample) -> ComponentFeatures? {
        let count = sample.pixelCount
        guard count > 0 else { return nil }
        var dark = 0
        for v in sample.luma where v < 128 { dark += 1 }
        let inkIsDark = dark <= count - dark

        var ink = [Bool](repeating: false, count: count)
        var inkPixels = 0
        for i in 0..<count {
            let isInk = inkIsDark ? sample.luma[i] < 128 : sample.luma[i] >= 128
            if isInk { ink[i] = true; inkPixels += 1 }
        }
        guard inkPixels > 0 else { return ComponentFeatures(density: 0, smallRatio: 0) }

        let w = sample.width
        let h = sample.height
        var visited = [Bool](repeating: false, count: count)
        var componentAreas: [Int] = []
        var stack: [Int] = []
        for start in 0..<count where ink[start] && !visited[start] {
            var area = 0
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            while let current = stack.popLast() {
                area += 1
                let x = current % w
                let y = current / w
                if x > 0, ink[current - 1], !visited[current - 1] {
                    visited[current - 1] = true; stack.append(current - 1)
                }
                if x < w - 1, ink[current + 1], !visited[current + 1] {
                    visited[current + 1] = true; stack.append(current + 1)
                }
                if y > 0, ink[current - w], !visited[current - w] {
                    visited[current - w] = true; stack.append(current - w)
                }
                if y < h - 1, ink[current + w], !visited[current + w] {
                    visited[current + w] = true; stack.append(current + w)
                }
            }
            componentAreas.append(area)
        }

        let components = componentAreas.count
        let small = componentAreas.filter { $0 <= 4 }.count
        return ComponentFeatures(
            density: Double(components) / Double(inkPixels),
            smallRatio: Double(small) / Double(max(1, components)))
    }

    // MARK: Zusammensetzung

    private static func features(color: ColorFeatures,
                                 entropy: Double,
                                 components: ComponentFeatures?,
                                 structure: StructureFeatures) -> ContentFeatures {
        ContentFeatures(
            sampleWidth: structure.sampleEdge,
            sampleHeight: structure.sampleEdge,
            uniqueColorRatio: color.uniqueColorRatio,
            exactColorCountHint: color.exactColorCountHint,
            chromaMean: color.chromaMean,
            grayscaleScore: color.grayscaleScore,
            entropy: entropy,
            localVarianceMean: structure.localVarianceMean,
            localVarianceP90: structure.localVarianceP90,
            edgeDensity: structure.edgeDensity,
            horizontalEdgeRatio: structure.horizontalEdgeRatio,
            verticalEdgeRatio: structure.verticalEdgeRatio,
            diagonalEdgeRatio: structure.diagonalEdgeRatio,
            connectedComponentDensity: components?.density,
            smallComponentRatio: components?.smallRatio,
            flatAreaRatio: structure.flatAreaRatio,
            textureRatio: structure.textureRatio,
            textLikeTileRatio: structure.textLikeTileRatio,
            confidence: 0)
    }
}
