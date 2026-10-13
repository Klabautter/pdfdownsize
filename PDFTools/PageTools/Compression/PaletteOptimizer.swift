import Foundation
import CoreGraphics

// MARK: - Masterplan §9.6 (V2-3b) – Exact Palette / Indexed
//
// Aus einem dekodierten Bild wird eine EXAKTE Palette samt exakter Indizes
// gebaut – kein Dithering, keine Quantisierung (§4: nur exakte Palette im
// Smart-Pfad, keine Farbreduktion).
//
// Scan-Politik (dokumentiert):
//   1. STICHPROBE: bis 131 072 Pixel, deterministischer Raster-Stride.
//      Zeigt sie mehr als 256 distinkte Farben, ist kein Kandidat möglich –
//      es wird gar nicht erst vollständig gescannt.
//   2. VOLLSTÄNDIGER Scan: alle Pixel werden gezählt (gleiches Budget wie
//      der Planner: 36 Mio. Pixel – größer dekodierte Bilder erreichen diese
//      Funktion nicht, der Deckel ist defensive Kante, kein zweites Regime).
//   3. > 256 distinkte Farben im Vollscan → `.tooManyColors`, kein Kandidat.
//
// BitsPerComponent folgt exakt der Palettengröße: 1 (2 Farben), 2 (≤ 4),
// 4 (≤ 16), 8 (≤ 256).
//
// Indexpackung: MSB-first, JEDE ZEILE beginnt auf einer Bytegrenze
// (ISO 32000-1 §8.9.3: „each row of sample data shall begin on a byte
// boundary“; die Auffüllbits am Zeilenende sind Nullen und werden von
// Lesern ignoriert). Zeilenbytes = ceil(width · bpc / 8) – genau der
// Zeilenrhythmus, den der PNG-Prädiktor über /DecodeParms
// (/Columns W, /Colors 1, /BitsPerComponent bpc) rekonstruiert.
//
// Gate (§9.6 „verlustfrei beweisbar“): die gepackten Indizes werden
// zurückgelesen und über die Palette rekonstruiert; der Vergleich gegen
// die Originalpixel entscheidet. Vollvergleich bis zum Pixeldeckel,
// darüber (unerreichbare Kante, siehe oben) deterministische Stichprobe.
enum PaletteOptimizer {

    /// Ergebnis einer erfolgreichen Exact-Palette-Kodierung.
    struct Encoded {
        /// Palette: entries × components Bytes (RGB-Triplette bzw. Grauwert).
        let palette: Data
        /// Flate-kodierte PNG-geprädiktete Indizes (der Bildstream).
        let indexStream: Data
        let paletteEntries: Int
        let bitsPerComponent: Int
        /// 1 = DeviceGray-Basis, 3 = DeviceRGB-Basis.
        let components: Int
        /// true = Median-Cut-Quantisierung (lossy, nur Small/Target) statt
        /// exakter Palette. Steht im Trace über die Candidate-Reason.
        let isQuantized: Bool
        /// Volle Qualitätsmessung gegen die Referenz (nur quantisiert):
        /// trägt Preset-Floors, Pareto-Ordnung und Perceptual-Score.
        /// Exact-Kandidaten bleiben messungsfrei (bitgenau = Qualität 1.0).
        let quality: QualityGateMeasurement?
        /// Kanten-Einführung zur Messung (nur quantisiert).
        let edgeIntroduction: Double?

        init(palette: Data, indexStream: Data, paletteEntries: Int,
             bitsPerComponent: Int, components: Int,
             isQuantized: Bool = false,
             quality: QualityGateMeasurement? = nil,
             edgeIntroduction: Double? = nil) {
            self.palette = palette
            self.indexStream = indexStream
            self.paletteEntries = paletteEntries
            self.bitsPerComponent = bitsPerComponent
            self.components = components
            self.isQuantized = isQuantized
            self.quality = quality
            self.edgeIntroduction = edgeIntroduction
        }
    }

    /// Ergebnis der Analyse EINES Bildes.
    enum Outcome {
        /// Stichprobe oder Vollscan zeigte mehr als 256 distinkte Farben.
        case tooManyColors
        /// Bitmap oder Kodierung fehlgeschlagen (kein Kandidat, kein Fehler).
        case encodeFailed
        /// Rekonstruktion war nicht bitgenau – Palette verweigert (Gate).
        case verificationFailed
        case success(Encoded)
    }

    /// Palette-Obergrenze des /Indexed-Farbraums.
    static let maximumPaletteEntries = 256
    /// Stichprobengröße (64–128k Pixel laut Vorgabe, Deckel: 128k).
    static let samplePixelLimit = 131_072
    /// Deckel des Vollvergleichs (Pixel). Identisch zum Dekodierbudget des
    /// Planners – größere Bilder erreichen diese Funktion nicht.
    static let fullVerificationPixelCap = 36_000_000

    /// Spitzen-Arbeitsmenge der Analyse (Rohpixel + Indizes) für die
    /// Kandidatenmetrik `expectedPeakWorkingBytes`.
    static func workingBytes(pixelCount: Int, components: Int) -> Int64 {
        Int64(pixelCount * (components + 1))
    }

    /// Analysiert und kodiert EIN Bild zu Exact Palette + Indizes.
    /// `components`: 1 = Graustufen (DeviceGray-Basis), 3 = RGB.
    static func encodeExact(_ image: CGImage, components: Int) -> Outcome {
        guard components == 1 || components == 3 else { return .encodeFailed }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= fullVerificationPixelCap else {
            return .encodeFailed
        }
        // Derselbe Rohbitmap-Aufruf wie die Flate-/JPEG-Pfade: die Indizes
        // müssen zu DENSELBEN Pixeln passen, mit denen die Konkurrenten
        // gerechnet haben (Determinismus, Finding 11).
        guard let raw = ImageResampler.rawBitmap(image, components: components) else {
            return .encodeFailed
        }
        let pixelCount = width * height

        // 1. Stichprobe – erst bei Hinweis auf ≤ 256 Farben wird voll gescannt.
        if sampleColorCount(raw: raw, pixelCount: pixelCount,
                            components: components) > maximumPaletteEntries {
            return .tooManyColors
        }

        // 2. Vollständiger Scan: exakte Palette in Erstfund-Reihenfolge plus
        //    exakte Indizes je Pixel.
        var paletteKeys: [UInt32] = []          // Erstfund-Reihenfolge
        var keyToIndex: [UInt32: Int] = [:]     // Farbe → Palettenplatz
        var indices = [UInt8](repeating: 0, count: pixelCount)
        let bytes = [UInt8](raw)

        for pixel in 0..<pixelCount {
            let key = colorKey(bytes: bytes, pixel: pixel, components: components)
            if let known = keyToIndex[key] {
                indices[pixel] = UInt8(known)
            } else {
                let index = paletteKeys.count
                guard index < maximumPaletteEntries else { return .tooManyColors }
                paletteKeys.append(key)
                keyToIndex[key] = index
                indices[pixel] = UInt8(index)
            }
        }
        let entries = paletteKeys.count
        guard entries > 0 else { return .encodeFailed }

        // 3. BitsPerComponent exakt nach Palettengröße.
        let bpc: Int = entries <= 2 ? 1 : (entries <= 4 ? 2 : (entries <= 16 ? 4 : 8))

        // 4. Indizes packen (MSB-first, zeilen-ausgerichtet) und verlustfrei
        //    kodieren.
        guard let packed = pack(indices: indices, width: width, height: height,
                                bitsPerComponent: bpc) else { return .encodeFailed }

        // 5. Gate: Rekonstruktion muss bitgenau sein.
        guard isBitExact(packed: packed, paletteKeys: paletteKeys,
                         raw: bytes, width: width, height: height,
                         components: components, bitsPerComponent: bpc) else {
            return .verificationFailed
        }

        // 6. PNG-Prädiktor über die GEPACKTEN Bytes: prädiktiert wird
        //    byteweise – Zeilenlänge = ceil(width·bpc/8), /DecodeParms
        //    erklärt dem Leser dieselbe Zeilenlänge (/Colors 1).
        guard let predicted = ImageResampler.pngPredictor(
                  Data(packed), width: bytesPerRow(width: width,
                                                  bitsPerComponent: bpc),
                  height: height, components: 1),
              let flated = ImageProcessor.flateBest(predicted) else {
            return .encodeFailed
        }

        var palette = [UInt8]()
        palette.reserveCapacity(entries * components)
        for key in paletteKeys {
            palette.append(UInt8((key >> 16) & 0xFF))
            if components == 3 {
                palette.append(UInt8((key >> 8) & 0xFF))
                palette.append(UInt8(key & 0xFF))
            }
        }
        return .success(Encoded(palette: Data(palette),
                                indexStream: flated,
                                paletteEntries: entries,
                                bitsPerComponent: bpc,
                                components: components))
    }

    // MARK: - Quantisiert (lossy, nur Small/Target-Size)

    /// Fehlergrenzen der Quantisierung (8-bit-Kanäle): kein Pixel weiter als
    /// `maximumAbsoluteError` vom Original, im Mittel höchstens
    /// `maximumMeanError`. Reine Schwarz-Weiß-Textpixel (dominante Farben)
    /// landen exakt auf ihren Palettenplätzen (Fehler 0) – Fehler
    /// konzentrieren sich auf Verläufe/Kanten, wo das Auge sie toleriert.
    static let maximumAbsoluteError = 24.0
    static let maximumMeanError = 3.0

    /// Median-Cut-Quantisierung auf ≤ 256 Farben + optionales
    /// Floyd-Steinberg-Dithering. Nur RGB (Grau mit 8 bit hat höchstens 256
    /// Stufen und läuft immer über den exakten Pfad).
    ///
    /// Deterministisch: Histogramm-Bins, wertbasierte Box-Wahl
    /// (Count, dann Kanal, dann Index), euklidische Nächste mit
    /// Index-Tiebreak, Dithering links-nach-rechts ohne Serpentinen.
    /// Die Messung gegen `image` läuft hier (einzige Stelle mit beiden
    /// Rastern), damit Generator und Executor denselben Befund sehen.
    static func encodeQuantized(_ image: CGImage, dither: Bool) -> Outcome {
        let components = 3
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= fullVerificationPixelCap,
              let raw = ImageResampler.rawBitmap(image, components: components)
        else {
            return .encodeFailed
        }
        let bytes = [UInt8](raw)
        let pixelCount = width * height

        // 1. Histogramm über 15-bit-Bins (32 Stufen/Kanal).
        struct Bin { var count = 0; var r = 0; var g = 0; var b = 0 }
        var bins = [Bin](repeating: Bin(), count: 32 * 32 * 32)
        for pixel in 0..<pixelCount {
            let o = pixel * 3
            let key = (Int(bytes[o]) >> 3) << 10
                | (Int(bytes[o + 1]) >> 3) << 5
                | (Int(bytes[o + 2]) >> 3)
            bins[key].count += 1
            bins[key].r += Int(bytes[o])
            bins[key].g += Int(bytes[o + 1])
            bins[key].b += Int(bytes[o + 2])
        }
        let used = bins.indices.filter { bins[$0].count > 0 }

        // 2. Median-Cut bis 256 Boxen (Count-Priorität, Median nach Count).
        var boxes: [[Int]] = used.isEmpty ? [] : [used]
        while boxes.count < maximumPaletteEntries {
            var splitAt: Int?
            var splitChannel = 0
            var splitValue = 0
            var bestCount = 1
            for (index, box) in boxes.enumerated() where box.count > 1 {
                var rMin = 32, rMax = -1, gMin = 32, gMax = -1
                var bMin = 32, bMax = -1, count = 0
                for key in box {
                    count += bins[key].count
                    let r = key >> 10, g = (key >> 5) & 31, b = key & 31
                    rMin = min(rMin, r); rMax = max(rMax, r)
                    gMin = min(gMin, g); gMax = max(gMax, g)
                    bMin = min(bMin, b); bMax = max(bMax, b)
                }
                guard count > bestCount else { continue }
                let ranges = [(rMax - rMin, 0), (gMax - gMin, 1), (bMax - bMin, 2)]
                let channel = ranges.max {
                    $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 > $1.1
                }?.1 ?? 0
                bestCount = count
                splitAt = index
                splitChannel = channel
                // Median nach Count entlang des Kanals.
                let ordered = box.sorted {
                    channelValue($0, channel: channel)
                        < channelValue($1, channel: channel)
                }
                var seen = 0
                for (position, key) in ordered.enumerated() {
                    seen += bins[key].count
                    if seen * 2 >= count {
                        splitValue = channelValue(key, channel: channel)
                        break
                    }
                }
            }
            guard let target = splitAt else { break }
            let box = boxes[target]
            var below = box.filter {
                channelValue($0, channel: splitChannel) <= splitValue
            }
            var above = box.filter {
                channelValue($0, channel: splitChannel) > splitValue
            }
            if below.isEmpty || above.isEmpty {
                // Entarteter Median-Split (eine Farbe hält die Mehrheit der
                // Box): Fallback auf max-1 entlang des weitesten Kanals –
                // beide Seiten sind dann garantiert nicht leer (Minimum
                // unten, Maximum oben). Ein `break` hier würde alle
                // restlichen Boxen aufgeben (Suitenfund: Verlauf mit 5
                // statt 256 Farben).
                let ranges = [0, 1, 2].map { channel -> (range: Int, max: Int) in
                    let values = box.map { channelValue($0, channel: channel) }
                    return (values.max()! - values.min()!, values.max()!)
                }
                guard let fallback = ranges.enumerated().max(by: {
                    $0.element.range != $1.element.range
                        ? $0.element.range < $1.element.range
                        : $0.offset > $1.offset
                }), fallback.element.range > 0 else {
                    break // Alle Bins identisch – nichts mehr zu teilen.
                }
                let value = fallback.element.max - 1
                below = box.filter {
                    channelValue($0, channel: fallback.offset) <= value
                }
                above = box.filter {
                    channelValue($0, channel: fallback.offset) > value
                }
                guard !below.isEmpty, !above.isEmpty else { break }
            }
            boxes[target] = below
            boxes.append(above)
        }

        // 3. Palettenfarben = Count-gewichtete Mittel (gerundet).
        var palette: [(r: Int, g: Int, b: Int)] = []
        for box in boxes {
            var count = 0, r = 0, g = 0, b = 0
            for key in box {
                count += bins[key].count
                r += bins[key].r; g += bins[key].g; b += bins[key].b
            }
            guard count > 0 else { continue }
            palette.append((r: (r + count / 2) / count,
                            g: (g + count / 2) / count,
                            b: (b + count / 2) / count))
        }
        guard !palette.isEmpty, palette.count <= maximumPaletteEntries else {
            return .encodeFailed
        }

        // 4. Mapping (+ optionales Floyd-Steinberg-Dithering).
        //
        // Performance: Die Nächste-Suche läuft NICHT pro Pixel über die
        // Palette (Pixel × Einträge), sondern einmal über die 32k Bins als
        // Lookup-Tabelle – danach O(1) je Pixel. Das Dithering quantisiert
        // die fehlerbehaftete Wunschfarbe ebenfalls über die LUT
        // (Standard-Näherung, deterministisch).
        var binLUT = [UInt8](repeating: 0, count: 32 * 32 * 32)
        for bin in 0..<(32 * 32 * 32) {
            let r = min(255, (bin >> 10) * 8 + 4)
            let g = min(255, ((bin >> 5) & 31) * 8 + 4)
            let b = min(255, (bin & 31) * 8 + 4)
            binLUT[bin] = UInt8(nearestPaletteEntry(
                palette: palette, r: Double(r), g: Double(g), b: Double(b)))
        }
        func binKey(r: Int, g: Int, b: Int) -> Int {
            (min(255, max(0, r)) >> 3) << 10
                | (min(255, max(0, g)) >> 3) << 5
                | (min(255, max(0, b)) >> 3)
        }
        var indices = [UInt8](repeating: 0, count: pixelCount)
        if dither {
            var errorR = [Double](repeating: 0, count: pixelCount)
            var errorG = [Double](repeating: 0, count: pixelCount)
            var errorB = [Double](repeating: 0, count: pixelCount)
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = y * width + x
                    let o = pixel * 3
                    let wantR = Double(bytes[o]) + errorR[pixel]
                    let wantG = Double(bytes[o + 1]) + errorG[pixel]
                    let wantB = Double(bytes[o + 2]) + errorB[pixel]
                    let index = Int(binLUT[binKey(
                        r: Int(wantR.rounded()), g: Int(wantG.rounded()),
                        b: Int(wantB.rounded()))])
                    indices[pixel] = UInt8(index)
                    let entry = palette[index]
                    let eR = wantR - Double(entry.r)
                    let eG = wantG - Double(entry.g)
                    let eB = wantB - Double(entry.b)
                    func spread(_ dx: Int, _ dy: Int, _ fraction: Double) {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else {
                            return
                        }
                        let n = ny * width + nx
                        errorR[n] += eR * fraction
                        errorG[n] += eG * fraction
                        errorB[n] += eB * fraction
                    }
                    spread(1, 0, 7.0 / 16.0)
                    spread(-1, 1, 3.0 / 16.0)
                    spread(0, 1, 5.0 / 16.0)
                    spread(1, 1, 1.0 / 16.0)
                }
            }
        } else {
            for pixel in 0..<pixelCount {
                let o = pixel * 3
                indices[pixel] = binLUT[binKey(
                    r: Int(bytes[o]), g: Int(bytes[o + 1]),
                    b: Int(bytes[o + 2]))]
            }
        }

        // 5. Fehler-Gate gegen die Originalpixel.
        var maxError = 0.0
        var totalError = 0.0
        for pixel in 0..<pixelCount {
            let entry = palette[Int(indices[pixel])]
            let o = pixel * 3
            let error = max(abs(Double(bytes[o]) - Double(entry.r)),
                            abs(Double(bytes[o + 1]) - Double(entry.g)),
                            abs(Double(bytes[o + 2]) - Double(entry.b)))
            maxError = max(maxError, error)
            totalError += error
        }
        guard maxError <= maximumAbsoluteError,
              totalError / Double(max(1, pixelCount)) <= maximumMeanError
        else {
            return .verificationFailed
        }

        // 6. Packen + Prädiktor + Flate (Wege wie exakt, keine zweite Logik).
        let entries = palette.count
        let bpc: Int = entries <= 2 ? 1 : (entries <= 4 ? 2 : (entries <= 16 ? 4 : 8))
        guard let packed = pack(indices: indices, width: width, height: height,
                                bitsPerComponent: bpc),
              let predicted = ImageResampler.pngPredictor(
                  Data(packed), width: bytesPerRow(width: width,
                                                   bitsPerComponent: bpc),
                  height: height, components: 1),
              let flated = ImageProcessor.flateBest(predicted) else {
            return .encodeFailed
        }

        // 7. Volle Messung gegen die Referenz (einzige Stelle mit Original
        //    UND Rekonstruktion): Preset-Floors, Pareto und Perceptual-Score
        //    laufen darüber wie bei JPEG-Kandidaten.
        guard let recon = renderIndices(indices: indices, palette: palette,
                                        width: width, height: height),
              let quality = QualityGates.measure(reference: image,
                                                 candidate: recon) else {
            return .encodeFailed
        }
        let edgeIntro = QualityGates.Evaluator(reference: image)
            .edgeIntroduction(candidate: recon)

        var paletteBytes = [UInt8]()
        paletteBytes.reserveCapacity(entries * components)
        for entry in palette {
            paletteBytes.append(UInt8(clamping: entry.r))
            paletteBytes.append(UInt8(clamping: entry.g))
            paletteBytes.append(UInt8(clamping: entry.b))
        }
        return .success(Encoded(palette: Data(paletteBytes),
                                indexStream: flated,
                                paletteEntries: entries,
                                bitsPerComponent: bpc,
                                components: components,
                                isQuantized: true,
                                quality: quality,
                                edgeIntroduction: edgeIntro))
    }

    /// Kanalkomponente eines 15-bit-Bin-Schlüssels.
    private static func channelValue(_ key: Int, channel: Int) -> Int {
        switch channel {
        case 0: return key >> 10
        case 1: return (key >> 5) & 31
        default: return key & 31
        }
    }

    /// Nächster Palettenplatz (quadrierte euklidische Distanz, deterministischer
    /// Index-Tiebreak: der erste beste gewinnt).
    private static func nearestPaletteEntry(
        palette: [(r: Int, g: Int, b: Int)],
        r: Double, g: Double, b: Double) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, entry) in palette.enumerated() {
            let dr = Double(entry.r) - r
            let dg = Double(entry.g) - g
            let db = Double(entry.b) - b
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Rekonstruiert die Indizes über die Palette zu einem RGB-Bild (für die
    /// Qualitätsmessung – dieselben Pixel, die der Leser sieht).
    private static func renderIndices(indices: [UInt8],
                                      palette: [(r: Int, g: Int, b: Int)],
                                      width: Int, height: Int) -> CGImage? {
        var raw = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            let entry = palette[Int(indices[pixel])]
            raw[pixel * 3] = UInt8(clamping: entry.r)
            raw[pixel * 3 + 1] = UInt8(clamping: entry.g)
            raw[pixel * 3 + 2] = UInt8(clamping: entry.b)
        }
        guard let provider = CGDataProvider(data: Data(raw) as CFData) else {
            return nil
        }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 24,
                       bytesPerRow: width * 3,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(
                           rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Scan

    /// Deterministische Stichprobe: gleichmäßig über das Raster gestreift,
    /// höchstens `samplePixelLimit` Pixel.
    private static func sampleColorCount(raw: Data, pixelCount: Int,
                                         components: Int) -> Int {
        guard pixelCount > 0 else { return 0 }
        let stride = max(1, pixelCount / samplePixelLimit)
        var seen = Set<UInt32>()
        var pixel = 0
        while pixel < pixelCount {
            seen.insert(colorKey(raw: raw, pixel: pixel, components: components))
            pixel += stride
        }
        return seen.count
    }

    /// Farbschlüssel eines Pixels: RGB als 24-Bit-Zahl, Grau als Bytewert.
    private static func colorKey(raw: Data, pixel: Int, components: Int) -> UInt32 {
        let base = raw.startIndex + pixel * components
        let r = UInt32(raw[base])
        guard components == 3 else { return r }
        let g = UInt32(raw[base + 1])
        let b = UInt32(raw[base + 2])
        return (r << 16) | (g << 8) | b
    }

    /// Array-Variante (für den Vollscan, ohne Data-Indexversatz).
    private static func colorKey(bytes: [UInt8], pixel: Int, components: Int) -> UInt32 {
        let base = pixel * components
        let r = UInt32(bytes[base])
        guard components == 3 else { return r }
        let g = UInt32(bytes[base + 1])
        let b = UInt32(bytes[base + 2])
        return (r << 16) | (g << 8) | b
    }

    // MARK: - Packen / Entpacken (MSB-first, Zeilenbytegrenzen)

    static func bytesPerRow(width: Int, bitsPerComponent: Int) -> Int {
        (width * bitsPerComponent + 7) / 8
    }

    /// Packt die Indizes zeilenweise: MSB-first, letzte Bits einer Zeile
    /// werden mit Nullen auf die Bytegrenze aufgefüllt (§8.9.3).
    /// internal: der Unit-Test prüft die Packung bitweise gegen einen
    /// unabhängigen Bitleser.
    static func pack(indices: [UInt8], width: Int, height: Int,
                     bitsPerComponent: Int) -> [UInt8]? {
        let rowBytes = bytesPerRow(width: width, bitsPerComponent: bitsPerComponent)
        var packed = [UInt8](repeating: 0, count: rowBytes * height)
        for row in 0..<height {
            let rowStart = row * rowBytes
            let indexStart = row * width
            switch bitsPerComponent {
            case 8:
                for x in 0..<width { packed[rowStart + x] = indices[indexStart + x] }
            case 4:
                for x in 0..<width {
                    let value = indices[indexStart + x] & 0x0F
                    if x % 2 == 0 {
                        packed[rowStart + x / 2] |= value << 4
                    } else {
                        packed[rowStart + x / 2] |= value
                    }
                }
            case 2:
                for x in 0..<width {
                    let value = indices[indexStart + x] & 0x03
                    packed[rowStart + x / 4] |= value << (6 - (x % 4) * 2)
                }
            case 1:
                for x in 0..<width where indices[indexStart + x] != 0 {
                    packed[rowStart + x / 8] |= UInt8(1 << (7 - x % 8))
                }
            default:
                return nil
            }
        }
        return packed
    }

    /// Liest den Index eines Pixels aus dem gepackten Strom zurück
    /// (internal für den Unit-Test).
    static func unpackIndex(_ packed: [UInt8], row: Int, column: Int,
                            width: Int, bitsPerComponent: Int) -> Int {
        let rowBytes = bytesPerRow(width: width, bitsPerComponent: bitsPerComponent)
        let byte = packed[row * rowBytes + column * bitsPerComponent / 8]
        switch bitsPerComponent {
        case 8: return Int(byte)
        case 4: return column % 2 == 0 ? Int(byte >> 4) : Int(byte & 0x0F)
        case 2: return Int((byte >> (6 - (column % 4) * 2)) & 0x03)
        case 1: return Int((byte >> (7 - column % 8)) & 0x01)
        default: return 0
        }
    }

    // MARK: - Gate

    /// Bitgenau-Gate: gepackte Indizes → Palette → Pixelvergleich.
    /// Vollvergleich bis `fullVerificationPixelCap`; darüber (Kante, die der
    /// Dekodierbudget des Planners ohnehin ausschließt) eine deterministische
    /// Stichprobe im selben Rhythmus wie die Farbanalyse.
    private static func isBitExact(packed: [UInt8], paletteKeys: [UInt32],
                                   raw: [UInt8], width: Int, height: Int,
                                   components: Int, bitsPerComponent: Int) -> Bool {
        let pixelCount = width * height
        let stride = pixelCount <= fullVerificationPixelCap
            ? 1 : max(1, pixelCount / samplePixelLimit)
        var pixel = 0
        while pixel < pixelCount {
            let row = pixel / width, column = pixel % width
            let index = unpackIndex(packed, row: row, column: column,
                                    width: width, bitsPerComponent: bitsPerComponent)
            guard index < paletteKeys.count else { return false }
            let expected = colorKey(bytes: raw, pixel: pixel, components: components)
            if paletteKeys[index] != expected { return false }
            pixel += stride
        }
        return true
    }
}
