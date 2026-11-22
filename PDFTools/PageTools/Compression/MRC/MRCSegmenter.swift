import Foundation
import CoreGraphics
import Accelerate

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
    /// Sauvola-Empfindlichkeit k (Standardliteratur 0.2–0.34; 0.2 erkennt auch
    /// kontrastärmere Tinte zuverlässig; helle Anti-Aliasing-Säume an scharfen
    /// Kanten entfernt der lokale Mittelpunkt-Filter danach).
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
    /// noch schwarze Fläche). Mindestens die Hälfte der Kachel muss echte
    /// Mittelwerte unterhalb des Papiergrunds tragen – sonst zählt geglättete
    /// Scanschrift auf leicht getöntem Papier (20–35 % Randpixel, hohe
    /// Kantendichte) fälschlich als Photo-Region.
    static let photoTileEdgeDensity = 0.20
    static let photoTileTextureFractionLow = 0.50
    static let photoTileTextureFractionHigh = 0.95
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

    /// Masterplan A2 Stufe 2: farbige Tinte als eigene Maske mit Füllfarbe
    /// (DeviceRGB 0…1). Höchstens `maximumColorMasks` je Seite.
    struct ColorMask {
        let mask: BilevelBuffer
        let fill: (red: Double, green: Double, blue: Double)
    }

    struct Segmentation {
        /// FG-Maske in der Bilevel-Pixelfolge (Bit 1 = Tinte), volle
        /// Rasterauflösung (§13.6 „hohe Auflösung").
        let mask: BilevelBuffer
        /// A2 Stufe 2: farbige Tinte (vorher blieb sie im weichen Hintergrund).
        var colorMasks: [ColorMask] = []
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

        // Luminanz + Chroma + Histogramm + Farbzählung in EINEM zeigerbasierten Durchlauf.
        let pixelCount = width * height
        var luma = [UInt8](repeating: 0, count: pixelCount)
        var chroma = [UInt8](repeating: 0, count: pixelCount)
        var histogram = [Int](repeating: 0, count: 256)
        var isGrayPixel = true
        var chromaHeavy = 0
        let strongChromaInt = Int(strongChroma)
        pixels.withUnsafeBytes { rawBuf in
            luma.withUnsafeMutableBufferPointer { lumaPtr in
                chroma.withUnsafeMutableBufferPointer { chromaPtr in
                    guard let pBase = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let lBase = lumaPtr.baseAddress,
                          let cBase = chromaPtr.baseAddress else { return }
                    if isGray {
                        for i in 0..<pixelCount {
                            let v = pBase[i]
                            lBase[i] = v
                            histogram[Int(v)] &+= 1
                        }
                    } else {
                        for i in 0..<pixelCount {
                            let o = i &* 3
                            let r = Int(pBase[o]), g = Int(pBase[o &+ 1]), b = Int(pBase[o &+ 2])
                            let yv = (299 &* r &+ 587 &* g &+ 114 &* b) / 1000
                            let maxRGB = max(r, max(g, b))
                            let minRGB = min(r, min(g, b))
                            let cv = maxRGB &- minRGB
                            lBase[i] = UInt8(yv)
                            cBase[i] = UInt8(cv)
                            histogram[yv] &+= 1
                            if cv > strongChromaInt { chromaHeavy &+= 1 }
                            if r != g || g != b { isGrayPixel = false }
                        }
                    }
                }
            }
        }
        // Grauerkannte RGB-Quellen (alle r==g==b) später grau kodieren.
        let effectivelyGray = isGray || isGrayPixel

        // --- §13.4-Gates vor jedem aufwendigen Schritt ---------------------
        // Papier-Luminanz über das Histogramm (Median).
        var paperLuma = 0
        var seen = 0
        let half = pixelCount / 2
        for value in 0..<256 {
            seen += histogram[value]
            if seen > half { paperLuma = value; break }
        }
        guard Double(paperLuma) >= minimumPaperLuma else { return nil }

        let chromaFraction = Double(chromaHeavy) / Double(pixelCount)
        guard chromaFraction <= maximumChromaFraction else { return nil }

        // --- Edge-Map (Sobel) ----------------------------------------------
        let edges = edgeMap(luma: luma, width: width, height: height)

        // --- Photo-Regionen (Chroma + Textur + Kachel-Dichte) ---------------
        let photoRects = detectPhotoRects(luma: luma, chroma: chroma,
                                          edges: edges,
                                          width: width, height: height,
                                          paperLuma: paperLuma)
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

        // Farbige Tinte bleibt im Hintergrund (Masterplan A2, Stufe 1): Bei
        // rein grauen Quellen ist chroma überall 0 → 5×5-Prüfung entfällt.
        var coloredInk = [Bool]()
        if !effectivelyGray {
            guard stripColoredInk(from: &foreground, chroma: chroma,
                                  width: width, height: height,
                                  colored: &coloredInk) else { return nil }
        }

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

        // --- A2 Stufe 2: farbige Tinte in eigene Masken -----------------------
        // Höchstens drei Farben (Median je Gruppe); der Hintergrund wird auch
        // unter ihnen aufgefüllt, die Tinte malt die Maske in ihrer Farbe.
        let colorMasks = isGray ? [] : Self.colorMasks(coloredInk: coloredInk, rgb: pixels,
                                                       width: width, height: height)
        var inpaint = mask
        for colorMask in colorMasks { inpaint = inpaint.union(colorMask.mask) }

        let sourceProfile = ImageResampler.sourceProfile(of: image)

        // --- Hintergrund-Rekonstruktion --------------------------------------
        let background = reconstructBackground(
            pixels: pixels, width: width, height: height,
            components: isGray ? 1 : 3, mask: inpaint,
            effectivelyGray: effectivelyGray,
            sourceProfile: sourceProfile)
        guard let background else { return nil }

        // Photo-Ausschnitte aus dem ORIGINAL-Raster (volle Auflösung).
        var photoRegions: [PhotoRegion] = []
        for rect in regions {
            let clamped = rect.intersection(
                CGRect(x: 0, y: 0, width: width, height: height))
                .integral
            guard clamped.width >= 2, clamped.height >= 2,
                  let crop = image.cropping(to: clamped) else { continue }
            // N31: cropping(to:) erzeugt ein neues CGImage ohne Associated Object –
            // das Quellprofil muss mitwandern, sonst rechnet Grau wie sRGB.
            if let sourceProfile { ImageResampler.tagSourceProfile(crop, sourceProfile) }
            photoRegions.append(PhotoRegion(rect: clamped, crop: crop))
        }

        return Segmentation(mask: mask, colorMasks: colorMasks, background: background,
                            backgroundIsGray: effectivelyGray,
                            photoRegions: photoRegions,
                            inkFraction: inkFraction,
                            paperLuma: Double(paperLuma))
    }

    // MARK: Farbige Tinte (Masterplan A2, Stufe 1)

    /// Chroma, ab der ein Vordergrundpixel als farbige Tinte gilt – dieselbe
    /// Grenze wie die Farbzählung (`ChromaCensus.strongChroma`).
    static let coloredInkChroma = ChromaCensus.strongChroma
    /// Höchster Anteil farbiger Pixel an der Tinte. Darüber ist die Seite
    /// kein MRC-Fall (farbiger Text, Formular mit Farbdruck): Die Tinte
    /// landete sonst überwiegend im weichen Hintergrund.
    static let maximumColoredInkFraction = 0.03

    /// Nimmt farbige Tinte und ihren 1-px-Rand aus der Maske; der Rand trägt
    /// sonst als dunkler Saum Schwarz um die farbige Linie. Gibt `false`
    /// zurück, wenn mehr als `maximumColoredInkFraction` der Tinte farbig ist.
    ///
    /// N14 (A2): „Farbig“ entscheidet die mittlere Chroma der TINTE in der
    /// 5×5-Umgebung, nicht das Rohpixel (3×3 reichte nicht: ein Saumpixel
    /// sieht dort zur Hälfte sich selbst). JPEG-Farbsäume an schwarzer Schrift
    /// (einzelne Randpixel mit Chroma > 40 neben farblosem Kern) zählten
    /// vorher als farbige Tinte: Die Seite fiel aus MRC (über 3 %) oder die
    /// Glyphen wurden ausgedünnt. Ein farbiger Strich bleibt farbig, auch
    /// 1 px breit – gemittelt wird nur über Tinte, nicht über Papier.
    static func stripColoredInk(from foreground: inout [Bool], chroma: [UInt8],
                                width: Int, height: Int) -> Bool {
        var colored = [Bool]()
        return stripColoredInk(from: &foreground, chroma: chroma, width: width,
                               height: height, colored: &colored)
    }

    /// Wie oben; `colored` erhält die als farbige Tinte erkannten Pixel
    /// (ohne Rand) – die Quelle der Farbmasken (A2 Stufe 2).
    static func stripColoredInk(from foreground: inout [Bool], chroma: [UInt8],
                                width: Int, height: Int,
                                colored: inout [Bool]) -> Bool {
        colored = [Bool](repeating: false, count: width * height)
        var ink = 0
        var coloredCount = 0
        for y in 0..<height {
            for x in 0..<width where foreground[y * width + x] {
                ink += 1
                var sum = 0
                var count = 0
                for yy in max(0, y - 2)...min(height - 1, y + 2) {
                    for xx in max(0, x - 2)...min(width - 1, x + 2) where foreground[yy * width + xx] {
                        sum += Int(chroma[yy * width + xx])
                        count += 1
                    }
                }
                if count > 0, sum > coloredInkChroma * count {
                    colored[y * width + x] = true
                    coloredCount += 1
                }
            }
        }
        guard ink > 0, coloredCount > 0 else { return true }
        if Double(coloredCount) / Double(ink) > maximumColoredInkFraction { return false }
        for y in 0..<height {
            for x in 0..<width where foreground[y * width + x] {
                var near = false
                for dy in -1...1 where !near {
                    let yy = y + dy
                    guard yy >= 0, yy < height else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx >= 0, xx < width, colored[yy * width + xx] { near = true; break }
                    }
                }
                if near { foreground[y * width + x] = false }
            }
        }
        return true
    }

    // MARK: Farbmasken (Masterplan A2, Stufe 2)

    static let maximumColorMasks = 3
    /// Farbtonabstand (Grad), ab dem eine weitere Gruppe entsteht. Gruppiert
    /// wird nach Farbton, nicht nach RGB: Die geglätteten Kanten eines blauen
    /// Strichs sind heller, aber derselbe Farbton – nach RGB-Abstand bildeten
    /// sie zwei eigene hellblaue Masken.
    static let colorSplitHueDegrees = 40.0
    /// Kleinere Gruppen lohnen keine eigene Maske; ihre Pixel bleiben im
    /// Hintergrund (wie in Stufe 1).
    static let minimumColorMaskPixels = 16

    /// Gruppiert die farbige Tinte in höchstens drei Farbtöne.
    /// Deterministisch: Startwert ist der Farbton des Medianpixels, weitere
    /// Zentren jeweils das am weitesten entfernte Pixel (über
    /// `colorSplitHueDegrees`); danach fünf Zuordnungsschritte mit
    /// Kreismittel. Füllfarbe = Median je Kanal über den gesättigten Kern
    /// der Gruppe (Chroma mindestens Gruppenmedian) – die hellen Kanten
    /// würden die Farbe sonst ausbleichen. In eine Gruppe kommen nur Pixel
    /// höchstens `colorSplitHueDegrees` von ihrem Zentrum, in die Maske nur
    /// solche mit mindestens der halben Farbstärke der Füllung (N26); der
    /// Rest bleibt im Hintergrund wie in Stufe 1.
    static func colorMasks(coloredInk: [Bool], rgb: Data, width: Int,
                           height: Int) -> [ColorMask] {
        let count = width * height
        guard coloredInk.count == count, rgb.count >= count * 3 else { return [] }
        let bytes = [UInt8](rgb)
        var indices: [Int] = []
        for i in 0..<count where coloredInk[i] { indices.append(i) }
        guard indices.count >= minimumColorMaskPixels else { return [] }
        func hue(_ i: Int) -> Double {
            let r = Double(bytes[i * 3]), g = Double(bytes[i * 3 + 1]), b = Double(bytes[i * 3 + 2])
            let angle = atan2(3.0.squareRoot() * (g - b), 2 * r - g - b) * 180 / .pi
            return angle < 0 ? angle + 360 : angle
        }
        func chroma(_ i: Int) -> Int {
            let r = Int(bytes[i * 3]), g = Int(bytes[i * 3 + 1]), b = Int(bytes[i * 3 + 2])
            return max(r, g, b) - min(r, g, b)
        }
        func gap(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }
        let hues = indices.map(hue)
        var centers = [hues.sorted()[hues.count / 2]]
        while centers.count < maximumColorMasks {
            var farthest = -1.0
            var pick = hues[0]
            for h in hues {
                let d = centers.map { gap(h, $0) }.min() ?? 0
                if d > farthest { farthest = d; pick = h }
            }
            guard farthest > colorSplitHueDegrees else { break }
            centers.append(pick)
        }
        var assignment = [Int](repeating: 0, count: indices.count)
        for _ in 0..<5 {
            for k in indices.indices {
                var best = 0
                var bestGap = Double.infinity
                for (n, center) in centers.enumerated() where gap(hues[k], center) < bestGap {
                    bestGap = gap(hues[k], center); best = n
                }
                // N26: Ein Farbton weit von jedem Zentrum (der vierte) gehört
                // zu keiner Gruppe und zieht auch kein Zentrum zu sich – sonst
                // verschmolzen Rot und Gelb zu einer orangen Maske.
                assignment[k] = bestGap <= colorSplitHueDegrees ? best : -1
            }
            for n in centers.indices {
                var sx = 0.0, sy = 0.0
                for k in indices.indices where assignment[k] == n {
                    sx += cos(hues[k] * .pi / 180); sy += sin(hues[k] * .pi / 180)
                }
                if sx != 0 || sy != 0 {
                    let mean = atan2(sy, sx) * 180 / .pi
                    centers[n] = mean < 0 ? mean + 360 : mean
                }
            }
        }
        let rowBytes = BilevelBuffer.rowBytes(width: width)
        var masks: [ColorMask] = []
        for n in centers.indices {
            let members = indices.indices.filter { assignment[$0] == n }.map { indices[$0] }
            guard members.count >= minimumColorMaskPixels else { continue }
            let medianChroma = members.map(chroma).sorted()[members.count / 2]
            let core = members.filter { chroma($0) >= medianChroma }
            func channel(_ c: Int) -> Double {
                let values = core.map { bytes[$0 * 3 + c] }.sorted()
                return Double(values[values.count / 2]) / 255
            }
            let fill = (channel(0), channel(1), channel(2))
            // N26: Die Maske malt jedes Pixel in der Füllfarbe. Ein Pixel mit
            // deutlich weniger Farbe – Schwarz neben Farbe, das durch JPEG-
            // Säume einen Farbton trägt – bliebe sonst nicht schwarz. Solche
            // Pixel bleiben im Hintergrund wie in Stufe 1.
            let fillChroma = Int(((max(fill.0, fill.1, fill.2) - min(fill.0, fill.1, fill.2)) * 255).rounded())
            let painted = members.filter { chroma($0) * 2 >= fillChroma }
            guard painted.count >= minimumColorMaskPixels else { continue }
            var bits = [UInt8](repeating: 0, count: rowBytes * height)
            for i in painted {
                let x = i % width, y = i / width
                bits[y * rowBytes + x / 8] |= 0x80 >> UInt8(x % 8)
            }
            guard let buffer = BilevelBuffer(width: width, height: height, data: Data(bits)) else { continue }
            masks.append(ColorMask(mask: buffer, fill: fill))
        }
        return masks
    }

    // MARK: Sobel-Edge-Map

    /// Binäre Kantenkarte: Sobel-Magnitude ≥ `edgeThreshold`.
    static func edgeMap(luma: [UInt8], width: Int, height: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: width * height)
        guard width >= 3, height >= 3, luma.count >= width * height else { return out }
        let threshold = Int(edgeThreshold)
        luma.withUnsafeBufferPointer { lp in
            out.withUnsafeMutableBufferPointer { op in
                guard let src = lp.baseAddress, let dst = op.baseAddress else { return }
                for y in 1..<(height - 1) {
                    let row = y &* width
                    let prev = row &- width
                    let next = row &+ width
                    for x in 1..<(width - 1) {
                        let tl = Int(src[prev &+ x &- 1]), t = Int(src[prev &+ x])
                        let tr = Int(src[prev &+ x &+ 1])
                        let l = Int(src[row &+ x &- 1]), r = Int(src[row &+ x &+ 1])
                        let bl = Int(src[next &+ x &- 1]), b = Int(src[next &+ x])
                        let br = Int(src[next &+ x &+ 1])
                        let gx = -tl &- (l &<< 1) &- bl &+ tr &+ (r &<< 1) &+ br
                        let gy = -tl &- (t &<< 1) &- tr &+ bl &+ (b &<< 1) &+ br
                        if abs(gx) &+ abs(gy) >= threshold { dst[row &+ x] = true }
                    }
                }
            }
        }
        return out
    }

    // MARK: Sauvola-Schwelle (Integralbilder, Fenster ~25 px)

    /// Sauvola: T = m · (1 + k · (s/R − 1)), Vordergrund = Luminanz < T.
    /// Exakte `UInt64`-Integralbilder ohne Bounds-Checks.
    static func sauvolaForeground(luma: [UInt8], width: Int,
                                  height: Int) -> [Bool] {
        let count = width * height
        guard count > 0, luma.count >= count else { return [] }
        let stride = width + 1
        var sum = [UInt64](repeating: 0, count: (height + 1) * stride)
        var sumSq = [UInt64](repeating: 0, count: (height + 1) * stride)
        luma.withUnsafeBufferPointer { lp in
            sum.withUnsafeMutableBufferPointer { sp in
                sumSq.withUnsafeMutableBufferPointer { sqp in
                    guard let src = lp.baseAddress,
                          let sBase = sp.baseAddress,
                          let sqBase = sqp.baseAddress else { return }
                    for y in 0..<height {
                        var rowSum: UInt64 = 0
                        var rowSumSq: UInt64 = 0
                        let srcRow = y &* width
                        let prevInt = y &* stride
                        let curInt = prevInt &+ stride
                        for x in 0..<width {
                            let v = UInt64(src[srcRow &+ x])
                            rowSum &+= v
                            rowSumSq &+= v &* v
                            let col = x &+ 1
                            sBase[curInt &+ col] = sBase[prevInt &+ col] &+ rowSum
                            sqBase[curInt &+ col] = sqBase[prevInt &+ col] &+ rowSumSq
                        }
                    }
                }
            }
        }

        let w = thresholdWindow
        let r = w / 2
        let k = thresholdSensitivity
        let invRange = 1.0 / thresholdRange
        var out = [Bool](repeating: false, count: count)
        luma.withUnsafeBufferPointer { lp in
            sum.withUnsafeBufferPointer { sp in
                sumSq.withUnsafeBufferPointer { sqp in
                    out.withUnsafeMutableBufferPointer { op in
                        guard let src = lp.baseAddress,
                              let sBase = sp.baseAddress,
                              let sqBase = sqp.baseAddress,
                              let dst = op.baseAddress else { return }
                        for y in 0..<height {
                            let y0 = max(0, y - r), y1 = min(height - 1, y + r)
                            let ySpan = y1 - y0 + 1
                            let r0 = y0 &* stride
                            let r1 = (y1 &+ 1) &* stride
                            let srcRow = y &* width
                            for x in 0..<width {
                                let x0 = max(0, x - r), x1 = min(width - 1, x + r)
                                let invArea = 1.0 / Double(ySpan &* (x1 - x0 + 1))
                                let x1p = x1 &+ 1
                                let s = Double(sBase[r1 &+ x1p] &- sBase[r0 &+ x1p] &- sBase[r1 &+ x0] &+ sBase[r0 &+ x0])
                                let sSq = Double(sqBase[r1 &+ x1p] &- sqBase[r0 &+ x1p] &- sqBase[r1 &+ x0] &+ sqBase[r0 &+ x0])
                                let mean = s * invArea
                                let variance = max(0.0, sSq * invArea - mean * mean)
                                let threshold = mean * (1.0 + k * (variance.squareRoot() * invRange - 1.0))
                                if Double(src[srcRow &+ x]) < threshold {
                                    dst[srcRow &+ x] = true
                                }
                            }
                        }
                    }
                }
            }
        }
        // Anti-Aliasing-Säume an scharfen Kanten aus der Maske halten.
        var refined = out
        luma.withUnsafeBufferPointer { lp in
            out.withUnsafeBufferPointer { op in
                refined.withUnsafeMutableBufferPointer { rp in
                    guard let src = lp.baseAddress,
                          let orig = op.baseAddress,
                          let dst = rp.baseAddress else { return }
                    for y in 0..<height {
                        let y0 = max(0, y - 2), y1 = min(height - 1, y + 2)
                        let row = y &* width
                        for x in 0..<width where orig[row &+ x] {
                            let x0 = max(0, x - 2), x1 = min(width - 1, x + 2)
                            var localMin = 255
                            var localMax = 0
                            for yy in y0...y1 {
                                let rRow = yy &* width
                                for xx in x0...x1 {
                                    let v = Int(src[rRow &+ xx])
                                    if v < localMin { localMin = v }
                                    if v > localMax { localMax = v }
                                }
                            }
                            let span = localMax &- localMin
                            if span >= 64,
                               20 &* (Int(src[row &+ x]) &- localMin) > 9 &* span {
                                dst[row &+ x] = false
                            }
                        }
                    }
                }
            }
        }
        return refined
    }

    // MARK: Photo-Region-Erkennung (§13.5: Chroma + Textur + Kachel-Dichte)

    /// Kachelklassifikation → zusammenhängende Cluster → Rects. Kacheln sind
    /// photo-artig bei kräftiger Chroma ODER hoher Kantendichte auf
    /// „mittlerer" Luminanz (Textur). Cluster unter der Mindestgröße gelten
    /// als Rauschen und fallen weg.
    static func detectPhotoRects(luma: [UInt8], chroma: [UInt8],
                                 edges: [Bool],
                                 width: Int, height: Int,
                                 paperLuma: Int = 255) -> [CGRect] {
        let tile = photoTileSize
        let tilesX = max(1, width / tile)
        let tilesY = max(1, height / tile)
        var photoTile = [Bool](repeating: false, count: tilesX * tilesY)
        let midUpper = min(220, paperLuma - 20)

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
                        if l > 40 && l < midUpper { midLuma += 1 }
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
                                      effectivelyGray: Bool,
                                      sourceProfile: CGColorSpace? = nil) -> CGImage? {
        let count = width * height
        let channels = components
        let maskBits = [UInt8](mask.data)
        var buffer = [UInt8](pixels)

        // Nur die Maskenpixel werden durchlaufen: Handschrift deckt rund 2 %
        // der Seite. Vorher lief jeder Pass über alle Pixel und legte je
        // Maskenpixel eigene Arrays an (Debug: 24 s je Seite).
        let rowBytes = BilevelBuffer.rowBytes(width: width)
        var unknown = [Bool](repeating: false, count: count)
        var inkIndices: [Int] = []
        for y in 0..<height {
            for x in 0..<width {
                // Zeilengepackte Bilevel-Pixelfolge (wie classifyComponents).
                let bit = (maskBits[y * rowBytes + (x >> 3)] >> UInt8(7 - (x & 7))) & 1
                if bit == 1 {
                    unknown[y * width + x] = true
                    inkIndices.append(y * width + x)
                }
            }
        }
        guard !inkIndices.isEmpty else { return nil }

        // Pass 1: Dilatation – Unbekanntes füllt sich aus bekannten Nachbarn.
        // Gefüllte Werte stehen ab dem NÄCHSTEN Pass als Quelle bereit
        // (progressive Wellenausbreitung vom Rand ins Wortformular).
        var pending = inkIndices
        var sum = [Int](repeating: 0, count: channels)
        for _ in 0..<inpaintDilatePasses {
            guard !pending.isEmpty else { break }
            var filledIndices: [Int] = []
            var filledValues: [UInt8] = []
            var stillPending: [Int] = []
            for i in pending {
                let x = i % width, y = i / width
                for c in 0..<channels { sum[c] = 0 }
                var known = 0
                func addNeighbor(_ n: Int) {
                    guard !unknown[n] else { return }
                    for c in 0..<channels {
                        sum[c] += Int(buffer[n * channels + c])
                    }
                    known += 1
                }
                if x + 1 < width { addNeighbor(i + 1) }
                if x > 0 { addNeighbor(i - 1) }
                if y + 1 < height { addNeighbor(i + width) }
                if y > 0 { addNeighbor(i - width) }
                guard known > 0 else {
                    stillPending.append(i)
                    continue
                }
                filledIndices.append(i)
                for c in 0..<channels {
                    filledValues.append(UInt8(clamping: sum[c] / known))
                }
            }
            for (position, index) in filledIndices.enumerated() {
                for c in 0..<channels {
                    buffer[index * channels + c] = filledValues[position * channels + c]
                }
                unknown[index] = false
            }
            pending = stillPending
        }
        let remaining = pending.count
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
        // ohne den gesamten 25-MB-Hintergrundpuffer je Pass zu kopieren.
        let filledRegion = inkIndices.filter { !unknown[$0] }
        var smoothedValues = [UInt8](repeating: 0, count: filledRegion.count * channels)
        for _ in 0..<inpaintSmoothPasses {
            buffer.withUnsafeBufferPointer { bp in
                smoothedValues.withUnsafeMutableBufferPointer { sp in
                    guard let src = bp.baseAddress, let dst = sp.baseAddress else { return }
                    for (pos, i) in filledRegion.enumerated() {
                        let x = i % width, y = i / width
                        let outBase = pos &* channels
                        for c in 0..<channels {
                            var s = 0
                            let y0 = max(0, y - 1), y1 = min(height - 1, y + 1)
                            let x0 = max(0, x - 1), x1 = min(width - 1, x + 1)
                            for ny in y0...y1 {
                                let row = ny &* width
                                for nx in x0...x1 {
                                    s &+= Int(src[(row &+ nx) &* channels &+ c])
                                }
                            }
                            dst[outBase &+ c] = UInt8(s / 9)
                        }
                    }
                }
            }
            buffer.withUnsafeMutableBufferPointer { bp in
                smoothedValues.withUnsafeBufferPointer { sp in
                    guard let dst = bp.baseAddress, let src = sp.baseAddress else { return }
                    for (pos, i) in filledRegion.enumerated() {
                        let outBase = i &* channels
                        let inBase = pos &* channels
                        for c in 0..<channels {
                            dst[outBase &+ c] = src[inBase &+ c]
                        }
                    }
                }
            }
        }

        // CGImage je Kanalzahl (RGB als 4-Byte-Layout via vImage).
        let colorSpace: CGColorSpace = channels == 1
            ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = channels == 1
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        if channels == 3 {
            var padded = Data(count: width * 4 * height)
            let converted: Bool = buffer.withUnsafeMutableBytes { srcRaw in
                padded.withUnsafeMutableBytes { dstRaw in
                    guard let sPtr = srcRaw.baseAddress, let dPtr = dstRaw.baseAddress else {
                        return false
                    }
                    var srcBuf = vImage_Buffer(
                        data: sPtr, height: vImagePixelCount(height),
                        width: vImagePixelCount(width), rowBytes: width * 3)
                    var dstBuf = vImage_Buffer(
                        data: dPtr, height: vImagePixelCount(height),
                        width: vImagePixelCount(width), rowBytes: width * 4)
                    return vImageConvert_RGB888toRGBA8888(
                        &srcBuf, nil, 255, &dstBuf, false, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                }
            }
            guard converted,
                  let provider = CGDataProvider(data: padded as CFData),
                  let image = CGImage(width: width, height: height,
                                      bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                      provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent)
            else { return nil }
            // N31: Quellprofil am Hintergrund behalten – wird er grau kodiert
            // (z. B. ROMM-Scan), rechnet drawResize über das Profil statt sRGB.
            if let sourceProfile { ImageResampler.tagSourceProfile(image, sourceProfile) }
            return image
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
