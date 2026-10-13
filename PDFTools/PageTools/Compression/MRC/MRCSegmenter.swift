import Foundation
import CoreGraphics

// MARK: - Masterplan §13.5 – MRC-Segmentierung
//
// Zerlegt den Full-Page-Raster einer Scan-Seite in MRC-Layer (§13.6):
//
//   source raster → luma/chroma features → adaptive Schwelle (Sauvola)
//     → Edge-Map → Connected Components → text/line-art-Maske
//     → Photo-Region-Erkennung → Hintergrund-Rekonstruktion
//
// V1-Scope (§13.4): dunkler Text/Line-Art auf hellem Papier, Photos erlaubt.
// Nicht segmentierbar (nil → kein MRC-Kandidat, dokumentierte Grenzen):
//
//   • dunkles Papier (Median-Luminanz < 160) – Nacht-Scan/Invertierung
//   • chromadominierte Seiten (> 50 % kräftige Pixel) – farbige Typo/
//     Vollfarb-Magazin
//   • Photo-Regionen über 45 % der Fläche – Vollfarb-Magazin
//   • mehr als 4 dunkle Blobs außerhalb der Photo-Regionen
//   • Tintenanteil außerhalb [0.2 %, 35 %] – keine Struktur bzw. keine
//     erkennbare Papier-/Text-Struktur
//
// Alle Konstanten stehen als benannte Konstanten unten und sind gegen
// die Render-QA (§13.10) abgeschaltet: Was die Segmentierung falsch
// macht, fällt dort durch und führt zurück zum Original-Raster.
enum MRCSegmenter {

    // MARK: Dokumentierte Konstanten

    /// Sauvola-Fenster (Seitenlänge in px, ungerade). ~25 px entsprechen bei
    /// 300 DPI rund 2 mm – groß genug für Wortformulare, klein genug gegen
    /// lokal wechselndes Papier.
    static let thresholdWindow = 25
    /// Sauvola-Empfindlichkeit k (Standardliteratur 0.2–0.34; 0.2 = konservativ).
    static let thresholdSensitivity = 0.2
    /// Sauvola-Normierungs-R = Standardabweichung eines Grauwerts (128).
    static let thresholdRange = 128.0
    /// Sobel-Schwelle der Edge-Map (Luminanz-Differenz, 0–255).
    static let edgeThreshold = 24.0

    /// Helles Papier als §13.4-Voraussetzung: Median-Luminanz.
    static let minimumPaperLuma = 160.0
    /// Chroma-Schwelle eines „kräftigen" Pixels (max−min über RGB).
    static let strongChroma = 32.0
    /// Maximaler Anteil kräftiger Pixel (farbige Typo/Vollfarbe → Verweigerung).
    static let maximumChromaFraction = 0.50

    /// Kachelgröße der Photo-Vorprüfung (px).
    static let photoTileSize = 32
    /// Farb-Signal: mittlerer Chroma-Anteil und kräftiger Anteil je Kachel.
    static let photoTileChromaMean = 10.0
    static let photoTileChromaFraction = 0.25
    /// Textur-Signal: Kantendichte plus „mittlere" Luminanz (weder Papier
    /// noch schwarze Fläche).
    static let photoTileEdgeDensity = 0.20
    static let photoTileTextureFractionLow = 0.15
    static let photoTileTextureFractionHigh = 0.85
    /// Mindest-Kachelanzahl einer zusammenhängenden Photo-Region (~1 % Fläche).
    static let minimumPhotoTiles = 4
    /// Pad um erkannte Regionen (px) – verhindert Haarlinien am Übergang.
    static let photoRectPadding = 2
    /// Maximaler Photo-Flächenanteil (Vollfarb-Magazin → Verweigerung).
    static let maximumPhotoAreaFraction = 0.45

    /// Text-Komponenten: Fläche ≤ 2 % der Seite (Buchstaben, Wortformulare).
    static let maximumTextComponentAreaFraction = 0.02
    /// Größere Komponenten bleiben Vordergrund, wenn sie linienartig sind
    /// (Füllgrad ≤ 0.35: Linien, Rahmen, Tabellenregeln).
    static let maximumLineArtFillRatio = 0.35
    /// Maximal 4 dunkle Blobs werden als Photo-Region umgebettet.
    static let maximumBlobRegions = 4
    /// Eine Einzelkomponente über der halben Seite = kein Tint/auf-Papier-Muster.
    static let maximumSingleComponentFraction = 0.5

    /// Sanitätsgrenzen des Tintenanteils der FG-Maske.
    static let minimumInkFraction = 0.002
    static let maximumInkFraction = 0.35

    /// Inpainting: 8 Passes nearest-known (Dilatation), dann 2 Glättungs-
    /// pässe (3×3-Mittel) über die gefüllten Pixel. Qualitätsgate (§13.10)
    /// fängt Restartefakte – bewusst KEINE aggressive Morphologie (§13.5).
    static let inpaintDilatePasses = 8
    static let inpaintSmoothPasses = 2

    // MARK: Ergebnisse

    struct PhotoRegion {
        /// Rect im BILDPIXELRAUM, oben-links-Ursprung (Pixel).
        let rect: CGRect
        /// Original-Ausschnitt (volle Auflösung) – Quelle des Photo-Layers.
        let crop: CGImage
    }

    struct Segmentation {
        /// FG-Maske in der Bilevel-Pixelfolge (Bit 1 = Tinte), volle
        /// Rasterauflösung (§13.6 „hohe Auflösung").
        let mask: BilevelBuffer
        /// Rekonstruierter Hintergrund (volle Auflösung; der Encoder resampelt
        /// auf backgroundDPI).
        let background: CGImage
        let backgroundIsGray: Bool
        let photoRegions: [PhotoRegion]
        /// Diagnose für Trace/Begründung.
        let inkFraction: Double
        let paperLuma: Double
    }

    /// Segmentiert den Raster. `nil` heißt „nicht segmentierbar" (§13.4/§13.5)
    /// – der Aufrufer erzeugt dann keinen MRC-Kandidaten.
    static func segment(_ image: CGImage) -> Segmentation? {
        let width = image.width
        let height = image.height
        guard width >= thresholdWindow * 2, height >= thresholdWindow * 2,
              width * height <= 36_000_000 else { return nil }

        // Gray-Quellen behalten einen Kanal; RGB wird als 3-Byte-Rohbild
        // gelesen (dieselbe Herleitung wie überall in der Engine).
        let rgb = ImageResampler.rawBitmap(image, components: 3)
        let gray = rgb == nil ? ImageResampler.rawBitmap(image, components: 1) : nil
        guard rgb != nil || gray != nil else { return nil }
        let isGray = rgb == nil
        let pixels = rgb ?? gray!

        // Luminanz + Chroma (max−min über RGB; Grauquellen: 0).
        var luma = [UInt8](repeating: 0, count: width * height)
        var chroma = [UInt8](repeating: 0, count: width * height)
        var isGrayPixel = true
        for i in 0..<(width * height) {
            let r: Int, g: Int, b: Int
            if isGray {
                let v = Int(pixels[i])
                r = v; g = v; b = v
            } else {
                let o = i * 3
                r = Int(pixels[o]); g = Int(pixels[o + 1]); b = Int(pixels[o + 2])
            }
            luma[i] = UInt8(clamping: (299 * r + 587 * g + 114 * b) / 1000)
            chroma[i] = UInt8(clamping: max(r, max(g, b)) - min(r, min(g, b)))
            if !isGray, r != g || g != b { isGrayPixel = false }
        }
        // Grauerkannte RGB-Quellen (alle r==g==b) später grau kodieren.
        let effectivelyGray = isGray || isGrayPixel

        // --- §13.4-Gates vor jedem aufwendigen Schritt ---------------------
        // Papier-Luminanz über das Histogramm (Median).
        var histogram = [Int](repeating: 0, count: 256)
        for value in luma { histogram[Int(value)] += 1 }
        var paperLuma = 0
        var seen = 0
        let half = width * height / 2
        for value in 0..<256 {
            seen += histogram[value]
            if seen > half { paperLuma = value; break }
        }
        guard Double(paperLuma) >= minimumPaperLuma else { return nil }

        var chromaHeavy = 0
        for value in chroma where Int(value) > Int(strongChroma) { chromaHeavy += 1 }
        let chromaFraction = Double(chromaHeavy) / Double(width * height)
        guard chromaFraction <= maximumChromaFraction else { return nil }

        // --- Edge-Map (Sobel) ----------------------------------------------
        let edges = edgeMap(luma: luma, width: width, height: height)

        // --- Photo-Regionen (Chroma + Textur + Kachel-Dichte) ---------------
        let photoRects = detectPhotoRects(luma: luma, chroma: chroma,
                                          edges: edges,
                                          width: width, height: height)
        var photoArea = 0.0
        for rect in photoRects { photoArea += rect.width * rect.height }
        if photoArea / Double(width * height) > maximumPhotoAreaFraction {
            return nil
        }

        // --- Adaptive Schwelle (Sauvola) über Integralbilder ----------------
        var foreground = sauvolaForeground(luma: luma, width: width, height: height)

        // Photo-Rect-Pixel gehören zum Photo-Layer, nicht zur Textmaske.
        stripPhotoRects(from: &foreground, width: width, height: height,
                        rects: photoRects)

        // --- Connected Components → text/line-art-Maske ----------------------
        guard let (mask, blobRects, inkCount) =
            classifyComponents(foreground: foreground,
                               width: width, height: height)
        else { return nil }

        var regions = photoRects
        for rect in blobRects {
            regions = mergeRect(regions, rect)
        }
        // Blobs können die Flächen-Grenze reißen – erneut prüfen.
        photoArea = 0.0
        for rect in regions { photoArea += rect.width * rect.height }
        if regions.count > 0, photoArea / Double(width * height)
            > maximumPhotoAreaFraction { return nil }

        let inkFraction = Double(inkCount) / Double(width * height)
        guard inkFraction >= minimumInkFraction,
              inkFraction <= maximumInkFraction else { return nil }

        // --- Hintergrund-Rekonstruktion --------------------------------------
        let background = reconstructBackground(
            pixels: pixels, width: width, height: height,
            components: isGray ? 1 : 3, mask: mask,
            effectivelyGray: effectivelyGray)
        guard let background else { return nil }

        // Photo-Ausschnitte aus dem ORIGINAL-Raster (volle Auflösung).
        var photoRegions: [PhotoRegion] = []
        for rect in regions {
            let clamped = rect.intersection(
                CGRect(x: 0, y: 0, width: width, height: height))
                .integral
            guard clamped.width >= 2, clamped.height >= 2,
                  let crop = image.cropping(to: clamped) else { continue }
            photoRegions.append(PhotoRegion(rect: clamped, crop: crop))
        }

        return Segmentation(mask: mask, background: background,
                            backgroundIsGray: effectivelyGray,
                            photoRegions: photoRegions,
                            inkFraction: inkFraction,
                            paperLuma: Double(paperLuma))
    }

    // MARK: Sobel-Edge-Map

    /// Binäre Kantenkarte: Sobel-Magnitude ≥ `edgeThreshold`.
    static func edgeMap(luma: [UInt8], width: Int, height: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: width * height)
        guard width >= 3, height >= 3 else { return out }
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let tl = Int(luma[i - width - 1]), t = Int(luma[i - width])
                let tr = Int(luma[i - width + 1])
                let l = Int(luma[i - 1]), r = Int(luma[i + 1])
                let bl = Int(luma[i + width - 1]), b = Int(luma[i + width])
                let br = Int(luma[i + width + 1])
                let gx = -tl - 2 * l - bl + tr + 2 * r + br
                let gy = -tl - 2 * t - tr + bl + 2 * b + br
                let magnitude = abs(gx) + abs(gy)
                if Double(magnitude) >= edgeThreshold { out[i] = true }
            }
        }
        return out
    }

    // MARK: Sauvola-Schwelle (Integralbilder, Fenster ~25 px)

    /// Sauvola: T = m · (1 + k · (s/R − 1)), Vordergrund = Luminanz < T.
    /// Integralbilder machen das Fenster O(1) je Pixel. Die Summenbilder
    /// tragen (height+1)×(width+1) Zellen – der Abruf eines Fensters greift
    /// auf x1+1/y1+1 zu, deshalb darf die Matrix nicht height×width bleiben.
    static func sauvolaForeground(luma: [UInt8], width: Int,
                                  height: Int) -> [Bool] {
        let count = width * height
        let stride = width + 1
        var sum = [Double](repeating: 0, count: (height + 1) * stride)
        var sumSq = [Double](repeating: 0, count: (height + 1) * stride)
        for y in 0..<height {
            var rowSum = 0.0
            var rowSumSq = 0.0
            for x in 0..<width {
                let v = Double(luma[y * width + x])
                rowSum += v
                rowSumSq += v * v
                sum[(y + 1) * stride + x + 1] = sum[y * stride + x + 1] + rowSum
                sumSq[(y + 1) * stride + x + 1]
                    = sumSq[y * stride + x + 1] + rowSumSq
            }
        }

        let w = thresholdWindow
        let r = w / 2
        let k = thresholdSensitivity
        let range = thresholdRange
        var out = [Bool](repeating: false, count: count)
        for y in 0..<height {
            let y0 = max(0, y - r), y1 = min(height - 1, y + r)
            for x in 0..<width {
                let x0 = max(0, x - r), x1 = min(width - 1, x + r)
                let area = Double((y1 - y0 + 1) * (x1 - x0 + 1))
                let a = y0 * stride + x0
                let b = y0 * stride + x1 + 1
                let c = (y1 + 1) * stride + x0
                let d = (y1 + 1) * stride + x1 + 1
                let s = sum[d] - sum[b] - sum[c] + sum[a]
                let sSq = sumSq[d] - sumSq[b] - sumSq[c] + sumSq[a]
                let mean = s / area
                let variance = max(0, sSq / area - mean * mean)
                let std = variance.squareRoot()
                let threshold = mean * (1 + k * (std / range - 1))
                if Double(luma[y * width + x]) < threshold { out[y * width + x] = true }
            }
        }
        return out
    }

    // MARK: Photo-Region-Erkennung (§13.5: Chroma + Textur + Kachel-Dichte)

    /// Kachelklassifikation → zusammenhängende Cluster → Rects. Kacheln sind
    /// photo-artig bei kräftiger Chroma ODER hoher Kantendichte auf
    /// „mittlerer" Luminanz (Textur). Cluster unter der Mindestgröße gelten
    /// als Rauschen und fallen weg.
    static func detectPhotoRects(luma: [UInt8], chroma: [UInt8],
                                 edges: [Bool],
                                 width: Int, height: Int) -> [CGRect] {
        let tile = photoTileSize
        let tilesX = max(1, width / tile)
        let tilesY = max(1, height / tile)
        var photoTile = [Bool](repeating: false, count: tilesX * tilesY)

        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                var chromaSum = 0
                var chromaHeavy = 0
                var edgeCount = 0
                var midLuma = 0
                var count = 0
                let yEnd = min(height, (ty + 1) * tile)
                let xEnd = min(width, (tx + 1) * tile)
                for y in (ty * tile)..<yEnd {
                    for x in (tx * tile)..<xEnd {
                        let i = y * width + x
                        count += 1
                        chromaSum += Int(chroma[i])
                        if Int(chroma[i]) > Int(strongChroma) { chromaHeavy += 1 }
                        if edges[i] { edgeCount += 1 }
                        let l = Int(luma[i])
                        if l > 40 && l < 220 { midLuma += 1 }
                    }
                }
                guard count > 0 else { continue }
                let chromaMean = Double(chromaSum) / Double(count)
                let chromaFrac = Double(chromaHeavy) / Double(count)
                let edgeDensity = Double(edgeCount) / Double(count)
                let textureFrac = Double(midLuma) / Double(count)
                let colored = chromaMean >= photoTileChromaMean
                    && chromaFrac >= photoTileChromaFraction
                let textured = edgeDensity >= photoTileEdgeDensity
                    && textureFrac >= photoTileTextureFractionLow
                    && textureFrac <= photoTileTextureFractionHigh
                photoTile[ty * tilesX + tx] = colored || textured
            }
        }

        // Cluster (4-Nachbarschaft) → Bounding-Rects.
        var visited = [Bool](repeating: false, count: tilesX * tilesY)
        var rects: [CGRect] = []
        for start in 0..<photoTile.count where photoTile[start] && !visited[start] {
            var stack = [start]
            visited[start] = true
            var minX = tilesX, maxX = -1, minY = tilesY, maxY = -1
            var memberCount = 0
            while let current = stack.popLast() {
                memberCount += 1
                let cx = current % tilesX, cy = current / tilesX
                minX = min(minX, cx); maxX = max(maxX, cx)
                minY = min(minY, cy); maxY = max(maxY, cy)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, nx < tilesX, ny >= 0, ny < tilesY else { continue }
                    let next = ny * tilesX + nx
                    if photoTile[next] && !visited[next] {
                        visited[next] = true
                        stack.append(next)
                    }
                }
            }
            guard memberCount >= minimumPhotoTiles else { continue }
            let rect = CGRect(x: minX * tile, y: minY * tile,
                              width: (maxX - minX + 1) * tile,
                              height: (maxY - minY + 1) * tile)
            rects.append(pad(rect, width: width, height: height))
        }
        return rects
    }

    private static func pad(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        rect.insetBy(dx: CGFloat(-photoRectPadding),
                     dy: CGFloat(-photoRectPadding))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Vereinigt überlappende/berührende Rects (Blob-Regionen treffen oft auf
    /// Photo-Kacheln).
    private static func mergeRect(_ rects: [CGRect], _ add: CGRect) -> [CGRect] {
        var out = rects
        var current = add
        var merged = true
        while merged {
            merged = false
            for (index, rect) in out.enumerated() {
                if rect.intersects(current.insetBy(dx: -2, dy: -2)) {
                    current = rect.union(current)
                    out.remove(at: index)
                    merged = true
                    break
                }
            }
        }
        out.append(current)
        return out
    }

    private static func stripPhotoRects(from foreground: inout [Bool],
                                        width: Int, height: Int,
                                        rects: [CGRect]) {
        for rect in rects {
            let x0 = max(0, Int(rect.minX.rounded(.down)))
            let y0 = max(0, Int(rect.minY.rounded(.down)))
            let x1 = min(width, Int(rect.maxX.rounded(.up)))
            let y1 = min(height, Int(rect.maxY.rounded(.up)))
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 {
                foreground.zeroingRow(y, from: x0, to: x1, stride: width)
            }
        }
    }

    // MARK: Connected Components → Maske + Blob-Rects

    /// Sparsame 8-Nachbarschaft-CC über den gepackten Vordergrund-Bits.
    /// Bewusst OHNE Label-Array: besuchte Bits in einem zweiten gepackten
    /// Puffer, Komponenten werden direkt in die Ausgabemaske übernommen.
    ///
    /// Komponentenregeln:
    ///   • Fläche ≤ 2 % der Seite → Text/Vordergrund (Maske).
    ///   • Größer, aber Füllgrad ≤ 0.35 → Line-Art (Linien, Rahmen) → Maske.
    ///   • Größer mit dichtem Füllgrad → dunkler Blob → Photo-Region.
    ///   • Einzelkomponente > 50 % der Seite → nicht segmentierbar.
    static func classifyComponents(foreground: [Bool], width: Int,
                                   height: Int)
        -> (mask: BilevelBuffer, blobs: [CGRect], ink: Int)? {
        let count = width * height
        let rowBytes = BilevelBuffer.rowBytes(width: width)
        var visited = [Bool](repeating: false, count: count)
        var maskBits = [UInt8](repeating: 0, count: rowBytes * height)
        var blobs: [CGRect] = []
        var inkCount = 0
        var stack = [Int]()

        for start in 0..<count where foreground[start] && !visited[start] {
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true

            var area = 0
            var minX = width, maxX = -1, minY = height, maxY = -1
            var memberIndices = [Int]()

            while let current = stack.popLast() {
                area += 1
                memberIndices.append(current)
                let x = current % width, y = current / width
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        let next = ny * width + nx
                        if foreground[next] && !visited[next] {
                            visited[next] = true
                            stack.append(next)
                        }
                    }
                }
            }

            let bboxArea = (maxX - minX + 1) * (maxY - minY + 1)
            let fill = Double(area) / Double(max(bboxArea, 1))
            let fraction = Double(area) / Double(count)

            if fraction > maximumSingleComponentFraction {
                return nil   // dunkler Vollflächen-Hintergrund o. ä.
            }
            let isForeground = area <= Int(Double(count) * maximumTextComponentAreaFraction)
                || fill <= maximumLineArtFillRatio
            if isForeground {
                // Zeilengepackte Bilevel-Pixelfolge (Bit 1 = Tinte, MSB
                // first, Zeilenlänge (width+7)/8) – NICHT kontiguell
                // indizieren, sonst verschieben sich Zeilen mit Breite
                // ≠ Vielfaches von 8.
                for index in memberIndices {
                    let x = index % width, y = index / width
                    maskBits[y * rowBytes + (x >> 3)] |= UInt8(0x80 >> (x & 7))
                }
                inkCount += area
            } else {
                // Dunkler Blob → Photo-Region (bbox + Padding).
                blobs.append(pad(CGRect(x: minX, y: minY,
                                        width: maxX - minX + 1,
                                        height: maxY - minY + 1),
                                 width: width, height: height))
            }
            memberIndices.removeAll(keepingCapacity: true)
        }

        guard inkCount > 0 else { return nil }
        guard let mask = BilevelBuffer(width: width, height: height,
                                       data: Data(maskBits)) else { return nil }
        return (mask, blobs, inkCount)
    }

    // MARK: Hintergrund-Rekonstruktion (dilatieren + boxglätten)

    /// Vordergrund-Pixel werden aus lokal bekannten Nachbarn gefüllt
    /// (Pass-Weise Dilatation), danach die gefüllte Region zweifach mit dem
    /// 3×3-Mittelwert geglättet. Photo-Regionen werden NICHT gefüllt – sie
    /// bleiben im Hintergrund und werden oben zusätzlich vom Photo-Layer
    /// überdeckt.
    static func reconstructBackground(pixels: Data, width: Int, height: Int,
                                      components: Int, mask: BilevelBuffer,
                                      effectivelyGray: Bool) -> CGImage? {
        let count = width * height
        let channels = components
        let maskBits = [UInt8](mask.data)
        var buffer = [UInt8](pixels)

        var unknown = [Bool](repeating: false, count: count)
        var ink = 0
        for i in 0..<count {
            // Zeilengepackte Bilevel-Pixelfolge (wie classifyComponents).
            let y = i / width, x = i % width
            let bit = (maskBits[y * BilevelBuffer.rowBytes(width: width)
                                + (x >> 3)] >> UInt8(7 - (x & 7))) & 1
            if bit == 1 {
                unknown[i] = true
                ink += 1
            }
        }
        guard ink > 0 else { return nil }

        // Pass 1: Dilatation – Unbekanntes füllt sich aus bekannten Nachbarn.
        // Gefüllte Werte stehen ab dem NÄCHSTEN Pass als Quelle bereit
        // (progressive Wellenausbreitung vom Rand ins Wortformular).
        var remaining = ink
        for _ in 0..<inpaintDilatePasses {
            guard remaining > 0 else { break }
            var filled: [(index: Int, values: [UInt8])] = []
            for i in 0..<count where unknown[i] {
                let x = i % width, y = i / width
                var sum = [Int](repeating: 0, count: channels)
                var known = 0
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let n = ny * width + nx
                    guard !unknown[n] else { continue }
                    for c in 0..<channels {
                        sum[c] += Int(buffer[n * channels + c])
                    }
                    known += 1
                }
                guard known > 0 else { continue }
                filled.append((i, sum.map { UInt8(clamping: $0 / known) }))
            }
            for (index, values) in filled {
                for c in 0..<channels {
                    buffer[index * channels + c] = values[c]
                }
                unknown[index] = false
                remaining -= 1
            }
        }
        // Ungefüllte Inseln (geschlossene Maske): Mittelwert des Bekannten.
        if remaining > 0 {
            var sums = [Int](repeating: 0, count: channels)
            var known = 0
            for i in 0..<count where !unknown[i] {
                for c in 0..<channels { sums[c] += Int(buffer[i * channels + c]) }
                known += 1
            }
            guard known > 0 else { return nil }
            let fill = sums.map { UInt8(clamping: $0 / known) }
            for i in 0..<count where unknown[i] {
                for c in 0..<channels { buffer[i * channels + c] = fill[c] }
            }
        }

        // Glättung NUR über die gefüllte Region (3×3-Mittelwert, 2 Pässe) –
        // das Papier dort bleibt weich, der Rest unverändert.
        var filledRegion = [Bool](repeating: false, count: count)
        for i in 0..<count where !unknown[i] {
            // Nach der Dilatation ist `unknown` für Gefülltes bereits false;
            // die Region merken wir über das Ursprungs-Bit der Maske.
            let y = i / width, x = i % width
            let bit = (maskBits[y * BilevelBuffer.rowBytes(width: width)
                                + (x >> 3)] >> UInt8(7 - (x & 7))) & 1
            if bit == 1 { filledRegion[i] = true }
        }
        for _ in 0..<inpaintSmoothPasses {
            var smoothed = buffer
            for i in 0..<count where filledRegion[i] {
                let x = i % width, y = i / width
                for c in 0..<channels {
                    var sum = 0
                    for dy in -1...1 {
                        let ny = y + dy
                        guard ny >= 0, ny < height else { continue }
                        for dx in -1...1 {
                            let nx = x + dx
                            guard nx >= 0, nx < width else { continue }
                            sum += Int(buffer[(ny * width + nx) * channels + c])
                        }
                    }
                    smoothed[i * channels + c] = UInt8(clamping: sum / 9)
                }
            }
            buffer = smoothed
        }

        // CGImage je Kanalzahl (RGB als 4-Byte-Layout, wie rawBitmap).
        let colorSpace: CGColorSpace = channels == 1
            ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = channels == 1
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        if channels == 3 {
            var padded = [UInt8](repeating: 255, count: width * 4 * height)
            for i in 0..<(width * height) {
                padded[i * 4] = buffer[i * 3]
                padded[i * 4 + 1] = buffer[i * 3 + 1]
                padded[i * 4 + 2] = buffer[i * 3 + 2]
            }
            guard let provider = CGDataProvider(data: Data(padded) as CFData)
            else { return nil }
            return CGImage(width: width, height: height,
                           bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4,
                           space: colorSpace,
                           bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                           provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let provider = CGDataProvider(data: Data(buffer) as CFData)
        else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Array-Helfer (lokale Schreibvorgänge, klar getrennt)

private extension Array where Element == Bool {
    mutating func zeroingRow(_ y: Int, from: Int, to: Int, stride: Int) {
        for x in from..<to { self[y * stride + x] = false }
    }
}
