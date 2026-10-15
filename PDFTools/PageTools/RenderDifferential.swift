import Foundation
import AppKit
import PDFKit

/// Monster Epic Finding 5 – Render Differential als messbasiertes
/// visuelles Regressions-Werkzeug.
///
/// Metriken pro Seitenpaar:
/// - `changedAreaRatio`: Anteil Pixel mit wahrnehmbarem Unterschied (>15/255)
/// - `meanAbsDiff`: mittlerer absoluter Kanalunterschied (0–255)
/// - `ssim`: strukturelle Ähnlichkeit (1 = identisch, 0 = unähnlich)
///
/// Standard-Auflösung ist 150 DPI; die maximale Kantenlänge wird gekappt,
/// damit auch Poster-/Plan-Seiten kein unkontrolliertes RAM-Verhalten erzeugen.
struct RenderDifferential {

    struct PageComparison {
        let sourcePageIndex: Int
        let outputPageIndex: Int
        let dpi: Int
        /// Effektiv gerenderte DPI nach dem Kantencap (Metrik bleibt vergleichbar).
        let effectiveDPI: Int
        /// 0.0 = identisch, 1.0 = komplett unterschiedlich
        let changedAreaRatio: Double
        /// Durchschnittlicher Farbunterschied pro Kanal (0–255).
        let meanAbsDiff: Double
        /// Strukturelle Ähnlichkeit (0–1, 1 = identisch).
        let ssim: Double
        /// |Tintenabdeckung(Output) − Tintenabdeckung(Quelle)|.
        /// Anteil dunkler Pixel (<128 Luminanz). Sub-Pixel-Rasterungsrauschen
        /// bewegt diese Metrik kaum; fehlender Text/fehlende Bilder deutlich.
        let inkDelta: Double
        /// Tintenabdeckung der QUELLSEITE (0–1).
        ///
        /// Entscheidet, ob `inkDelta` überhaupt etwas aussagt: Auf einer
        /// Textseite ist Tinte gleich Inhalt – verschwindet Text, sinkt sie
        /// messbar. Auf einer vollflächig bebilderten Seite liegt dagegen ein
        /// großer Teil der Fläche nahe der Dunkelschwelle, und schon eine
        /// minimale Farbverschiebung kippt viele Pixel darüber. Dort ist
        /// Tinte keine Inhaltsmetrik.
        let sourceInkCoverage: Double

        /// Nur bei text-artiger Quelle ist `inkDelta` ein Inhaltsindikator.
        var inkDeltaIsMeaningful: Bool {
            sourceInkCoverage <= RenderDifferential.textLikeInkCoverage
        }
    }

    /// Bis zu dieser Tintenabdeckung gilt eine Seite als text-artig.
    /// Fließtext liegt typisch bei 5–15 %, dichte Tabellen bei 25–30 %;
    /// eine vollflächig bebilderte Seite liegt weit darüber.
    static let textLikeInkCoverage = 0.35

    /// Harte Kantenbegrenzung pro Render – Schutz vor Poster-Seiten.
    static let maxRenderEdge = 4000
    /// Kantenbegrenzung der VERGLEICHSCANVAS: Die Metriken (CAR/MAD/SSIM)
    /// werden auf einer verkleinerten Leinwand berechnet – ausreichend sensitiv
    /// für Cropping-/Missing-Image-/Rotationsfehler, aber auch im Debug-Build
    /// schnell genug für Corpus-Läufe.
    static let maxMetricEdge = 1400
    /// Standard-DPI für Corpus-Regressionen (Masterplan Finding 5).
    static let standardDPI = 150

    /// Vergleicht zwei PDFs seitenweise bei fester DPI.
    /// `pageMapping` mappt Output-Index → Source-Index (nil = identische Lage).
    /// `sourceRotationDegrees`: zusätzliche erwartete Drehung der QUELLE in der
    /// Gegenrichtung (z. B. Rotate-Operation +90 → Quelle um −90 vorrendern),
    /// sodass erwartet == transformiert verglichen wird.
    static func compare(sourceURL: URL,
                        outputURL: URL,
                        dpi: Int = RenderDifferential.standardDPI,
                        pageMapping: [Int: Int]? = nil,
                        sourceRotationDegrees: Int = 0) throws -> [PageComparison] {
        // Der gesamte Vergleich läuft in einem eigenen Pool: Neben den
        // gerasterten Seiten erzeugt schon `PDFDocument(url:)` autoreleased
        // Objekte samt internem Seitencache. Wird `compare` in einer Schleife
        // aufgerufen – im Korpuslauf tausendfach –, sammelt sich das sonst an,
        // bis der Prozess stirbt. Das Ergebnis besteht nur aus Structs und
        // übersteht das Leeren des Pools.
        try autoreleasepool {
        guard let srcDoc = PDFDocument(url: sourceURL),
              let outDoc = PDFDocument(url: outputURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let mapping = pageMapping ?? Dictionary(
            uniqueKeysWithValues: (0..<min(srcDoc.pageCount, outDoc.pageCount)).map { ($0, $0) })

        var comparisons: [PageComparison] = []
        for (outIdx, srcIdx) in mapping.sorted(by: { $0.key < $1.key }) {
            // Ein Seitenvergleich hält zwei gerasterte Seiten, zwei
            // Bitmap-Kontexte und zwei Luminanzpuffer – bei 1400 px Kantenlänge
            // zusammen leicht 30 MB. PDFKit und CoreGraphics liefern diese
            // Objekte autoreleased; ohne eigenen Pool gibt sie niemand frei,
            // bevor die umgebende Funktion endet. Über einen Korpuslauf hinweg
            // wuchs der Verbrauch dadurch unbegrenzt, bis der Prozess starb.
            let comparison: PageComparison? = autoreleasepool {
            guard srcIdx >= 0, srcIdx < srcDoc.pageCount,
                  outIdx >= 0, outIdx < outDoc.pageCount,
                  let srcPage = srcDoc.page(at: srcIdx),
                  let outPage = outDoc.page(at: outIdx) else { return nil }

            // Effektive ANZEIGE-Größen: `bounds(for:.mediaBox)` liefert nicht auf
            // allen OS-Versionen rotierte Maße – daher über die Rotation selbst
            // rechnen (Finding 5: Rotation muss im Vergleich exakt sitzen).
            let outRaw = outPage.bounds(for: .mediaBox).size
            let outDisplay = RotationNormalizer.rotatedSize(
                width: outRaw.width, height: outRaw.height,
                rotation: outPage.rotation)

            let scale = Double(dpi) / 72.0
            var w = Int((outDisplay.width * scale).rounded())
            var h = Int((outDisplay.height * scale).rounded())
            let capFactor = min(1.0,
                Double(maxMetricEdge) / Double(max(w, h, 1)),
                Double(maxRenderEdge) / Double(max(w, h, 1)))
            w = max(1, Int((Double(w) * capFactor).rounded()))
            h = max(1, Int((Double(h) * capFactor).rounded()))
            let size = CGSize(width: w, height: h)

            // Zusätzlich anzuwendende Drehung ist AUSSCHLIESSLICH die der
            // Operation. Die Eigenrotation der Seite (/Rotate) wendet PDFKit
            // beim Rendern bereits an – sie hier erneut zu drehen, drehte
            // jede rotierte Seite um 90° zu weit und meldete an ihr eine
            // Regression, die es nicht gab.
            let operationRotation = RotationNormalizer.normalized(sourceRotationDegrees)
            let srcRaw = srcPage.bounds(for: .mediaBox).size
            let srcDisplay = RotationNormalizer.rotatedSize(
                width: srcRaw.width, height: srcRaw.height,
                rotation: srcPage.rotation)
            let expectedDisplay = RotationNormalizer.rotatedSize(
                width: srcDisplay.width, height: srcDisplay.height,
                rotation: operationRotation)

            // Deckt sich die erwartete Anzeigefläche der Quelle mit der der
            // Ausgabe, wird die Quelle DIREKT auf die Zielleinwand gerendert.
            //
            // Vorher wurde `baseSize` über `fitScale` aus den bereits
            // gerundeten Pixelmaßen zurückgerechnet. `fitScale` ist ein
            // Minimum – bei nicht ganzzahligem Seitenverhältnis fällt die
            // Rückrechnung um ein Pixel kleiner aus als die Zielleinwand.
            // Damit galt `baseSize != targetSize`, und die Quelle nahm den
            // aspectFit-Umweg: ein zweiter Resampling-Schritt plus halber
            // Pixel Versatz durch die Zentrierung. Auf einer Textseite ergibt
            // das CAR 0.0965 / SSIM 0.9012 / MAD 8.32 – gemessen an Seite 85
            // von nist_qm-i-v11 (A4 595.56×842.04 zwischen Letter-Seiten):
            // Ziel 991×1400, zurückgerechnet 990×1400. Der Korpuslauf meldete
            // an drei Operationen eine Regression, deren Ursache allein in
            // dieser Rundung lag; die Assemblierung selbst war über alle 85
            // Seiten deckungsgleich.
            //
            // Der Vergleich läuft deshalb auf den Punktmaßen, nicht auf ihrer
            // Rasterung. Weichen sie wirklich ab, bleibt es beim aspectFit –
            // ein echter Geometrieunterschied muss sichtbar bleiben.
            let geometryMatches =
                abs(expectedDisplay.width - outDisplay.width) < 0.01 &&
                abs(expectedDisplay.height - outDisplay.height) < 0.01

            // `expectedDisplay` ist die Anzeigefläche der Quelle NACH der
            // Operationsdrehung – und genau die rendert `renderTransformed`,
            // weil es die Drehung auf einer Seitenkopie setzt statt sie
            // nachträglich auf das Rasterbild anzuwenden.
            let baseW: Int, baseH: Int
            if geometryMatches {
                baseW = w
                baseH = h
            } else {
                let fitScale = min(Double(w) / max(expectedDisplay.width, 1),
                                   Double(h) / max(expectedDisplay.height, 1))
                baseW = max(1, Int((expectedDisplay.width * fitScale).rounded()))
                baseH = max(1, Int((expectedDisplay.height * fitScale).rounded()))
            }

            guard let srcCG = renderTransformed(srcPage,
                                                baseSize: CGSize(width: baseW, height: baseH),
                                                targetSize: size,
                                                rotation: operationRotation),
                  let outCG = renderPage(outPage, size: size) else { return nil }

            let diff = pixelMetrics(srcCG, outCG)
            return PageComparison(
                sourcePageIndex: srcIdx,
                outputPageIndex: outIdx,
                dpi: dpi,
                effectiveDPI: Int((Double(dpi) * capFactor).rounded()),
                changedAreaRatio: diff.changedRatio,
                meanAbsDiff: diff.meanAbs,
                ssim: diff.ssim,
                inkDelta: diff.inkDelta,
                sourceInkCoverage: diff.sourceInk)
            }
            if let comparison { comparisons.append(comparison) }
        }
        return comparisons
        }
    }

    /// Sind die genannten Seiten beider Dokumente PIXELGLEICH (gleiche
    /// Anzeigemaße, identische Luminanz bei `dpi`)? Dieselbe Rasterung wie
    /// `compare`, aber ohne SSIM-, Tinte- und Differenzmetriken – für
    /// Prüfungen, die nur Gleichheit brauchen (je-Font-QA §14.4). Eine
    /// fehlende Seite oder abweichende Geometrie zählt als ungleich.
    static func pagesIdentical(sourceURL: URL, outputURL: URL,
                               pages: [Int],
                               dpi: Int = RenderDifferential.standardDPI) throws -> Bool {
        try autoreleasepool {
        guard let srcDoc = PDFDocument(url: sourceURL),
              let outDoc = PDFDocument(url: outputURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for index in pages.sorted() {
            let identical: Bool = autoreleasepool {
                guard index >= 0, index < srcDoc.pageCount, index < outDoc.pageCount,
                      let srcPage = srcDoc.page(at: index),
                      let outPage = outDoc.page(at: index) else { return false }
                let srcRaw = srcPage.bounds(for: .mediaBox).size
                let outRaw = outPage.bounds(for: .mediaBox).size
                let srcDisplay = RotationNormalizer.rotatedSize(
                    width: srcRaw.width, height: srcRaw.height, rotation: srcPage.rotation)
                let outDisplay = RotationNormalizer.rotatedSize(
                    width: outRaw.width, height: outRaw.height, rotation: outPage.rotation)
                guard abs(srcDisplay.width - outDisplay.width) < 0.01,
                      abs(srcDisplay.height - outDisplay.height) < 0.01 else { return false }
                let scale = Double(dpi) / 72.0
                var w = Int((outDisplay.width * scale).rounded())
                var h = Int((outDisplay.height * scale).rounded())
                let capFactor = min(1.0,
                    Double(maxMetricEdge) / Double(max(w, h, 1)),
                    Double(maxRenderEdge) / Double(max(w, h, 1)))
                w = max(1, Int((Double(w) * capFactor).rounded()))
                h = max(1, Int((Double(h) * capFactor).rounded()))
                let size = CGSize(width: w, height: h)
                guard let a = renderPage(srcPage, size: size),
                      let b = renderPage(outPage, size: size),
                      let lumaA = grayscaleBuffer(a, w: w, h: h),
                      let lumaB = grayscaleBuffer(b, w: w, h: h) else { return false }
                return lumaA == lumaB
            }
            if !identical { return false }
        }
        return true
        }
    }

    // MARK: - Rendering

    private static func renderPage(_ page: PDFPage, size: CGSize) -> CGImage? {
        let thumb = page.thumbnail(of: size, for: .mediaBox)
        return thumb.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Rendert die Quelle in `baseSize` (Anzeigemaße × Skalierung) und dreht
    /// sie um die OPERATIONS-Drehung auf die Zielleinwand. Die Leinwand wird
    /// weiß initialisiert – PDF-Seiten haben opaken Hintergrund.
    private static func renderTransformed(_ page: PDFPage,
                                          baseSize: CGSize,
                                          targetSize: CGSize,
                                          rotation: Int) -> CGImage? {
        // Die Operationsdrehung wird auf einer KOPIE der Seite gesetzt und
        // dann von PDFKit gerendert – demselben Weg, den auch die Ausgabe
        // nimmt, deren Drehung als /Rotate im Dokument steht.
        //
        // Vorher wurde die Quelle ungedreht gerastert und das fertige Bild
        // per CoreGraphics nachgedreht. Zwei verschiedene Rasterungswege
        // ergeben bei Text Subpixelunterschiede: An f3800 (9 Seiten,
        // gemischte Ausrichtung) meldete JEDE Seite CAR 0.06–0.11, obwohl
        // die Drehung pixelgenau korrekt war – über die Kopie gerendert
        // messen dieselben neun Seiten CAR 0.0000.
        //
        // Beide Seiten müssen denselben Weg nehmen; jeder zusätzliche
        // Zeichenschritt kostet Empfindlichkeit für echte Fehler.
        let source: PDFPage
        if rotation != 0, let rotated = page.copy() as? PDFPage {
            rotated.rotation = page.rotation + rotation
            source = rotated
        } else {
            source = page
        }

        guard baseSize != targetSize else {
            return renderPage(source, size: targetSize)
        }
        // Nur bei echtem Geometrieunterschied: seitenverhältnistreu
        // einpassen, damit der Unterschied sichtbar bleibt.
        guard let base = renderPage(source, size: baseSize) else { return nil }
        return drawOnWhite(base, size: targetSize)
    }

    private static func fillWhite(_ ctx: CGContext, _ size: CGSize) {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
    }

    /// Zeichnet `image` SEITENVERHÄLTNISTREU zentriert auf eine weiße Leinwand.
    ///
    /// Früher wurde auf die Zielgröße gestreckt. Das verzerrte die Quelle
    /// gerade dann, wenn sich die Seitenverhältnisse unterscheiden – also
    /// genau im Fehlerfall – und ließ eine falsche Rotation ähnlicher
    /// aussehen, als sie ist. Ein Verhältnisunterschied muss sichtbar
    /// bleiben, nicht weggerechnet werden.
    private static func drawOnWhite(_ image: CGImage, size: CGSize) -> CGImage? {
        guard let ctx = makeContext(Int(size.width), Int(size.height)) else { return nil }
        fillWhite(ctx, size)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: aspectFitRect(imageWidth: CGFloat(image.width),
                                          imageHeight: CGFloat(image.height),
                                          in: size))
        return ctx.makeImage()
    }

    /// Größtes zentriertes Rechteck mit dem Verhältnis des Bildes.
    private static func aspectFitRect(imageWidth: CGFloat, imageHeight: CGFloat,
                                      in size: CGSize) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / imageWidth, size.height / imageHeight)
        let w = imageWidth * scale, h = imageHeight * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2,
                      width: w, height: h)
    }


    // MARK: - Pixel-Metriken

    private static func pixelMetrics(_ a: CGImage, _ b: CGImage)
        -> (changedRatio: Double, meanAbs: Double, ssim: Double,
            inkDelta: Double, sourceInk: Double) {
        let w = min(a.width, b.width)
        let h = min(a.height, b.height)
        guard w > 0, h > 0 else { return (1.0, 255.0, 0.0, 1.0, 1.0) }

        guard let lumaA = grayscaleBuffer(a, w: w, h: h),
              let lumaB = grayscaleBuffer(b, w: w, h: h) else {
            return (1.0, 255.0, 0.0, 1.0, 1.0)
        }

        var changedPixels = 0
        var totalDiff = 0
        var inkA = 0
        var inkB = 0
        let totalPixels = w * h

        for i in 0..<totalPixels {
            let pa = lumaA[i]
            let pb = lumaB[i]
            let d = abs(Int(pa) - Int(pb))
            if d > 15 {   // Toleranz für Anti-Aliasing
                changedPixels += 1
            }
            totalDiff += d
            if pa < 128 { inkA += 1 }
            if pb < 128 { inkB += 1 }
        }

        let changedRatio = Double(changedPixels) / Double(max(totalPixels, 1))
        let meanAbs = Double(totalDiff) / Double(max(totalPixels, 1))
        let ssim = ssimOnLuminance(lumaA, lumaB, width: w, height: h)
        let inkDelta = abs(Double(inkA) - Double(inkB)) / Double(max(totalPixels, 1))
        let sourceInk = Double(inkA) / Double(max(totalPixels, 1))
        return (changedRatio, meanAbs, ssim, inkDelta, sourceInk)
    }

    /// Luminanz-Puffer (8 Bit) aus einem beliebigen CGImage.
    private static func grayscaleBuffer(_ image: CGImage, w: Int, h: Int) -> [UInt8]? {
        guard let ctx = makeContext(w, h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var luma = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            luma[i] = UInt8(clamping: (299 * Int(px[o]) + 587 * Int(px[o + 1])
                                       + 114 * Int(px[o + 2])) / 1000)
        }
        return luma
    }

    /// Globaler SSIM über 8×8-Fenster auf Luminanz (Standard-Konstanten C1/C2).
    private static func ssimOnLuminance(_ a: [UInt8], _ b: [UInt8],
                                        width: Int, height: Int) -> Double {
        let c1 = 6.5025   // (0.01*255)^2
        let c2 = 58.5225  // (0.03*255)^2
        let window = 8
        var totalSSIM = 0.0
        var windows = 0

        func stats(_ samples: [UInt8], _ ox: Int, _ oy: Int)
            -> (mean: Double, variance: Double) {
            var sum = 0.0
            for y in oy..<(oy + window) {
                let row = y * width
                for x in ox..<(ox + window) {
                    sum += Double(samples[row + x])
                }
            }
            let count = Double(window * window)
            let mean = sum / count
            var varianceSum = 0.0
            for y in oy..<(oy + window) {
                let row = y * width
                for x in ox..<(ox + window) {
                    let d = Double(samples[row + x]) - mean
                    varianceSum += d * d
                }
            }
            return (mean, varianceSum / count)
        }

        var oy = 0
        while oy + window <= height {
            var ox = 0
            while ox + window <= width {
                let sa = stats(a, ox, oy)
                let sb = stats(b, ox, oy)
                var covariance = 0.0
                for y in oy..<(oy + window) {
                    let row = y * width
                    for x in ox..<(ox + window) {
                        let da = Double(a[row + x]) - sa.mean
                        let db = Double(b[row + x]) - sb.mean
                        covariance += da * db
                    }
                }
                covariance /= Double(window * window)
                let numerator = (2 * sa.mean * sb.mean + c1) * (2 * covariance + c2)
                let denominator = (sa.mean * sa.mean + sb.mean * sb.mean + c1)
                    * (sa.variance + sb.variance + c2)
                totalSSIM += numerator / denominator
                windows += 1
                ox += window / 2
            }
            oy += window / 2
        }
        guard windows > 0 else { return 0 }
        return totalSSIM / Double(windows)
    }

    private static func makeContext(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h,
                  bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

// MARK: - Phase 7 – Multi-Gate für Seitenpaare

extension RenderDifferential {

    /// Phase 7 (Roadmap) – Multi-Gate-Messung zwischen zwei gerenderten
    /// Seitenbildern: dieselben Metriken wie das Bild-Gate (p05-Kachel-SSIM,
    /// Kanten-, Text-Score, ΔE), als Erweiterung neben `pixelMetrics`.
    /// Bewusst KEIN Umbau der bestehenden Seitenmetriken.
    static func multiGateMetrics(source: CGImage, output: CGImage)
        -> QualityGateMeasurement? {
        QualityGates.measure(reference: source, candidate: output)
    }
}
