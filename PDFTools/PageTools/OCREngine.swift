import Foundation
import AppKit
import PDFKit
import Vision
import CoreText

/// OCR-Engine (v2, 2026-10-01): macht ein PDF lokal durchsuchbar, OHNE
/// es zu rastern.
///
/// v1 baute aus 300-DPI-Bildern ein neues PDF – Vektoren, vorhandener Text,
/// Links, Formulare und Lesezeichen gingen verloren, der Nutzer musste der
/// „gerasterten Kopie“ zustimmen. v2 lässt jede Seite unangetastet und legt
/// nur eine unsichtbare Textebene (Render-Modus 3) über die erkannten Zeilen,
/// wie Vorschau und Acrobat. Seiten mit vorhandenem Text (born-digital oder
/// bereits erkannt) werden übersprungen.
///
/// Ablauf je Scan-Seite: rendern (300 dpi, Anzeige-Ausrichtung) → Apple
/// Vision `VNRecognizeTextRequest` (.accurate) → Zeilen in Seitenkoordinaten
/// (Drehung berücksichtigt) → Content-Stream über `pdfcore_append_ocr_layer`.
/// Alles lokal; Fortschritt/Abbruch/Validierung liegen beim `OCRViewModel`.
enum OCREngine {

    /// Feste Render-Auflösung: Kompromiss aus Erkennungsqualität und Tempo.
    static let renderDPI = 300

    /// Ab so vielen Nicht-Leerzeichen gilt eine Seite als „hat Text“ …
    static let existingTextThreshold = 20
    /// … sofern sie kein großes Rasterbild trägt. Mit Vollseiten-Scan zählt
    /// erst substanzieller Text: Eine digital eingefügte Kopf- oder
    /// Stempelzeile ließ früher den ganzen Scan unerkannt (2026-10-01).
    static let substantialTextThreshold = 200
    static let scanCoverage = 0.5

    enum OCRLanguagePreset: String, CaseIterable, Hashable {
        case germanEnglish
        case german
        case english

        var label: String {
            switch self {
            case .germanEnglish: return String(localized: "Deutsch + Englisch")
            case .german: return String(localized: "Nur Deutsch")
            case .english: return String(localized: "Nur Englisch")
            }
        }

        var recognitionLanguages: [String] {
            switch self {
            case .germanEnglish: return ["de-DE", "en-US"]
            case .german: return ["de-DE"]
            case .english: return ["en-US"]
            }
        }
    }

    struct Line: Hashable, Sendable {
        let text: String
        /// Normalisiert (0…1) auf die ANGEZEIGTE Seite, Ursprung unten-links
        /// (Vision-Konvention).
        let boundingBox: CGRect
        let confidence: Float
    }

    struct PageResult: Sendable {
        let pageIndex: Int
        let lines: [Line]
        /// Seite hatte schon Text und wurde nicht erkannt.
        var skippedExistingText = false

        var text: String { lines.map(\.text).joined(separator: "\n") }
        var wordCount: Int {
            text.split { $0.isWhitespace || $0.isNewline }.count
        }
        var meanConfidence: Float? {
            guard !lines.isEmpty else { return nil }
            return lines.map(\.confidence).reduce(0, +) / Float(lines.count)
        }
    }

    struct RunOutput: Sendable {
        /// Validierungs-pflichtiges Temp-PDF (VM prüft + speichert).
        let outputURL: URL
        let pages: [PageResult]

        var totalWords: Int { pages.map(\.wordCount).reduce(0, +) }
        var recognizedPageCount: Int { pages.filter { !$0.skippedExistingText }.count }
        var skippedPageCount: Int { pages.filter(\.skippedExistingText).count }
        var meanConfidence: Float? {
            let all = pages.flatMap(\.lines)
            guard !all.isEmpty else { return nil }
            return all.map(\.confidence).reduce(0, +) / Float(all.count)
        }
    }

    /// Ein Durchgang: Scan-Seiten erkennen → Textebene ins Original.
    @concurrent nonisolated static func run(sourceURL: URL,
                                languages: [String],
                                progress: @escaping (Double) -> Void) async throws -> RunOutput {
        guard let doc = PDFDocument(url: sourceURL) else {
            throw OCRError.unreadable(sourceURL.lastPathComponent)
        }
        if doc.isLocked { throw OCRError.locked(sourceURL.lastPathComponent) }
        guard doc.pageCount > 0 else { throw OCRError.noPages }
        let core: PDFCoreDocument
        do {
            core = try PDFCoreDocument(path: sourceURL.path)
        } catch {
            throw OCRError.unreadable(sourceURL.lastPathComponent)
        }

        // Größtes Rasterbild je Seite (Anteil der Seitenfläche) – Signal für
        // „Scan mit etwas digitalem Text“.
        var coverage: [Int: Double] = [:]
        let resources = (try? core.imageResources()) ?? []
        let pixels = LibQPDFPixelSource(document: core)
        for resource in resources {
            for placement in resource.placements {
                guard let page = doc.page(at: placement.pageIndex) else { continue }
                let media = page.bounds(for: .mediaBox)
                let share = placement.placedWidthPoints * placement.placedHeightPoints
                    / max(media.width * media.height, 1)
                coverage[placement.pageIndex] = max(coverage[placement.pageIndex] ?? 0, share)
            }
        }

        var results: [PageResult] = []
        let total = doc.pageCount
        for i in 0..<total {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { throw OCRError.missingPage(i + 1) }
            progress(Double(i) / Double(total) * 0.95)

            if hasExistingText(page, rasterCoverage: coverage[i] ?? 0) {
                results.append(PageResult(pageIndex: i, lines: [], skippedExistingText: true))
                continue
            }
            let render = try renderCGImage(of: page)
            // Vorhandenen digitalen Text nicht ein zweites Mal ablegen.
            var lines = try recognize(cgImage: render.image, languages: languages)
            lines += try photoLines(page: page, pageIndex: i, resources: resources,
                                    pixels: pixels, existing: lines, languages: languages)
            lines = lines.filter { !duplicatesExistingText($0, page: page) }
            results.append(PageResult(pageIndex: i, lines: lines))
            let content = textLayer(lines: lines, page: page)
            if !content.isEmpty {
                do {
                    try core.appendOCRLayer(pageIndex: i, content: content)
                } catch {
                    throw OCRError.writeFailed
                }
            }
        }

        let outURL = SessionScratch.makeURL(prefix: "ocr-")
        do {
            try core.save(to: outURL)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw OCRError.writeFailed
        }
        progress(1)
        return RunOutput(outputURL: outURL, pages: results)
    }

    // MARK: - Eingebettete Fotos

    /// Ab dieser effektiven Auflösung lohnt die Erkennung am Originalbild
    /// (1,5 × Render-DPI) …
    static let photoMinimumDPI = 450.0
    /// … sofern das Bild mindestens so viel der Seite deckt.
    static let photoMinimumShare = 0.03
    /// Obergrenze der langen Kante für Vision (Speicher, Laufzeit).
    static let photoMaximumEdge = 4000

    /// Erkennt Text in eingebetteten Bildern an deren NATIVER Auflösung
    /// (2026-10-01). Beim Seitenrender mit 300 DPI verlor ein verkleinert
    /// platziertes Handyfoto einer Beamer-Folie rund drei Viertel seiner
    /// Pixel; die kleine graue Folienschrift fiel unter Visions Lesbarkeit.
    /// Die Treffer werden über die Platzierung (CTM) auf die Seite abgebildet;
    /// was der Seitenrender schon fand, wird nicht doppelt übernommen.
    /// Zunächst nur aufrechte, ungespiegelte Platzierungen auf ungedrehten
    /// Seiten – alles andere deckt weiter der Seitenrender ab.
    nonisolated static func photoLines(page: PDFPage, pageIndex: Int,
                                       resources: [PDFImageResource],
                                       pixels: ImagePixelSource,
                                       existing: [Line],
                                       languages: [String]) throws -> [Line] {
        guard RotationNormalizer.normalized(page.rotation) == 0 else { return [] }
        let media = page.bounds(for: .mediaBox)
        let pageArea = max(media.width * media.height, 1)
        var found: [Line] = []
        for resource in resources where resource.bitsPerComponent == 8 && !resource.isImageMask {
            for placement in resource.placements where placement.pageIndex == pageIndex {
                guard let t = placement.transform, t.count == 6 else { continue }
                let (a, b, c, d, e, f) = (t[0], t[1], t[2], t[3], t[4], t[5])
                guard a > 0, d > 0, abs(b) < a * 1e-6, abs(c) < d * 1e-6,
                      a * d / pageArea >= photoMinimumShare,
                      Double(resource.width) / (a / 72) >= photoMinimumDPI,
                      var image = pixels.decodedImage(for: resource) else { continue }
                let longEdge = max(image.width, image.height)
                if longEdge > photoMaximumEdge {
                    let factor = Double(photoMaximumEdge) / Double(longEdge)
                    if let smaller = ImageResampler.resize(
                        image, to: PixelSize(width: Int(Double(image.width) * factor),
                                             height: Int(Double(image.height) * factor)),
                        components: 3) {
                        image = smaller
                    }
                }
                for line in try recognize(cgImage: image, languages: languages) {
                    // Einheitsquadrat des Bildes (Vision: Ursprung unten links,
                    // wie PDF) → Seite → normiert auf die angezeigte Seite.
                    let box = line.boundingBox
                    let x = (e + box.minX * a - media.minX) / media.width
                    let y = (f + box.minY * d - media.minY) / media.height
                    let mapped = Line(text: line.text,
                                      boundingBox: CGRect(x: x, y: y,
                                                          width: box.width * a / media.width,
                                                          height: box.height * d / media.height),
                                      confidence: line.confidence)
                    guard !(existing + found).contains(where: {
                        isSameLine($0, text: mapped.text, box: mapped.boundingBox)
                    }) else { continue }
                    found.append(mapped)
                }
            }
        }
        return found
    }

    /// Born-digital oder bereits erkannt: genug extrahierbarer Text – bei
    /// einer Seite mit großem Rasterbild erst substanzieller Text.
    nonisolated static func hasExistingText(_ page: PDFPage, rasterCoverage: Double = 0) -> Bool {
        let text = page.string ?? ""
        let needed = rasterCoverage >= scanCoverage ? substantialTextThreshold : existingTextThreshold
        return text.unicodeScalars.lazy.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .prefix(needed).count >= needed
    }

    /// Erkannte Zeile, die an derselben Stelle schon als Text vorliegt.
    nonisolated static func duplicatesExistingText(_ line: Line, page: PDFPage) -> Bool {
        let rect = pageRect(of: line, page: page)
        guard let existing = page.selection(for: rect.insetBy(dx: -2, dy: -2))?.string,
              !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let a = existing.lowercased().filter { !$0.isWhitespace }
        let b = line.text.lowercased().filter { !$0.isWhitespace }
        return a.contains(b) || b.contains(a) || similarity(a, b) >= 0.6
    }

    /// Zeilenbox (Anzeige, normiert) → Rechteck im ungedrehten Seitenraum.
    nonisolated static func pageRect(of line: Line, page: PDFPage) -> CGRect {
        let rotation = RotationNormalizer.normalized(page.rotation)
        let media = page.bounds(for: .mediaBox)
        let display = RotationNormalizer.rotatedSize(width: media.width, height: media.height,
                                                     rotation: rotation)
        let box = CGRect(x: line.boundingBox.minX * display.width,
                         y: line.boundingBox.minY * display.height,
                         width: line.boundingBox.width * display.width,
                         height: line.boundingBox.height * display.height)
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)].map {
            p -> CGPoint in
            switch rotation {
            case 90:  return CGPoint(x: media.width - p.y, y: p.x)
            case 180: return CGPoint(x: media.width - p.x, y: media.height - p.y)
            case 270: return CGPoint(x: p.y, y: media.height - p.x)
            default:  return p
            }
        }
        return CGRect(x: media.minX + min(corners[0].x, corners[1].x),
                      y: media.minY + min(corners[0].y, corners[1].y),
                      width: abs(corners[0].x - corners[1].x),
                      height: abs(corners[0].y - corners[1].y))
    }

    // MARK: - Render

    private struct Render {
        let image: CGImage
        /// Angezeigte Seitengröße in Punkten (Drehung angewendet).
        let pageSize: CGSize
    }

    /// Rendert die Seite in Anzeige-Ausrichtung (`thumbnail` wendet /Rotate
    /// an; `bounds` spiegelt die Drehung nicht wider → Zielgröße explizit).
    /// Pixel-Deckel für den Seitenrender (Befund A8, Review 2026-10-09):
    /// Ein A0-Scan ergäbe bei 300 DPI 9 933 × 14 043 px, dazu die 1,25×-
    /// Variante und zwei Hälften – über 1,5 GB Spitze. Der Deckel liegt so,
    /// dass auch die 1,25×-Variante (Faktor 1,5625) unter dem
    /// Dekodier-Budget der Engine bleibt.
    static let maximumRenderPixels = CompressionPlanner.maximumDecodablePixels / 2

    static func cappedRenderSize(_ pixels: CGSize) -> CGSize {
        let count = pixels.width * pixels.height
        guard count > CGFloat(maximumRenderPixels) else { return pixels }
        let factor = (CGFloat(maximumRenderPixels) / count).squareRoot()
        return CGSize(width: max(1, (pixels.width * factor).rounded(.down)),
                      height: max(1, (pixels.height * factor).rounded(.down)))
    }

    private nonisolated static func renderCGImage(of page: PDFPage) throws -> Render {
        let rotation = RotationNormalizer.normalized(page.rotation)
        let raw = page.bounds(for: .mediaBox)
        let size = RotationNormalizer.rotatedSize(width: raw.width,
                                                  height: raw.height,
                                                  rotation: rotation)
        let pixels = cappedRenderSize(PageImageExporter.pixelSize(
            pageBounds: CGRect(origin: .zero, size: size), dpi: renderDPI))
        let thumb = page.thumbnail(of: pixels, for: .mediaBox)
        guard let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.renderFailed
        }
        return Render(image: cg, pageSize: size)
    }

    // MARK: - Erkennung

    /// Erkennung in zwei Durchgängen (2026-10-01). Vision verwirft
    /// gelegentlich GANZE, gut lesbare Zeilen – abhängig von minimalen
    /// Pixelunterschieden (gemessen: zwei Zeilen eines Handyfoto-Scans fehlten
    /// bei einem Render, bei einem um max. 15 Graustufen abweichenden nicht).
    /// Deshalb ein zweiter Ganzseiten-Durchgang auf einer um 25 % größer
    /// skalierten Fassung; dort gefundene, im ersten fehlende Zeilen werden
    /// ergänzt. Überlappende Streifen wurden verworfen: An den Schnittkanten
    /// entstanden halbe Zeilen und damit Dubletten.
    private nonisolated static func recognize(cgImage: CGImage,
                                              languages: [String]) throws -> [Line] {
        var lines = try recognizeOnce(cgImage: cgImage, languages: languages)
        if let variant = scaled(cgImage, by: secondPassScale) {
            for line in try recognizeOnce(cgImage: variant, languages: languages)
            where !lines.contains(where: { isSameLine($0, text: line.text, box: line.boundingBox) }) {
                lines.append(line)   // normierte Koordinaten gelten unverändert
            }
        }
        // Dritter Durchgang: zwei überlappende Hälften. Visions genauer Modus
        // versagte auf einer Nutzerseite (zwei Folienfotos auf Karopapier)
        // für die GANZE Seite komplett – null Zeilen bei 150–400 DPI –, die
        // obere Hälfte allein lieferte elf korrekte (2026-10-01). Zeilen, die
        // eine Schnittkante berühren, liegen vollständig in der anderen
        // Hälfte und werden verworfen (keine abgeschnittenen Dubletten).
        let height = cgImage.height, width = cgImage.width
        let halfHeight = Int(Double(height) * halfPassShare)
        for (top, cutAtBottom) in [(0, true), (height - halfHeight, false)] {
            guard let half = cgImage.cropping(to: CGRect(x: 0, y: top, width: width,
                                                        height: halfHeight)) else { continue }
            let bottomInPage = Double(height - top - halfHeight) / Double(height)
            let scale = Double(halfHeight) / Double(height)
            for line in try recognizeOnce(cgImage: half, languages: languages) {
                let box = line.boundingBox
                if cutAtBottom ? box.minY < cutMargin : box.maxY > 1 - cutMargin { continue }
                let mapped = CGRect(x: box.minX, y: bottomInPage + box.minY * scale,
                                    width: box.width, height: box.height * scale)
                guard !lines.contains(where: { isSameLine($0, text: line.text, box: mapped) })
                else { continue }
                lines.append(Line(text: line.text, boundingBox: mapped, confidence: line.confidence))
            }
        }
        // Lesereihenfolge: von oben nach unten, innerhalb einer Zeile links → rechts.
        return lines.sorted {
            let sameRow = abs($0.boundingBox.midY - $1.boundingBox.midY)
                < min($0.boundingBox.height, $1.boundingBox.height) / 2
            return sameRow ? $0.boundingBox.minX < $1.boundingBox.minX
                           : $0.boundingBox.midY > $1.boundingBox.midY
        }
    }

    static let secondPassScale = 1.25
    /// Anteil der Seitenhöhe je Hälfte (Überlappung 2 × 0,1).
    static let halfPassShare = 0.6
    /// Abstand zur Schnittkante (Anteil der Hälfte), unter dem eine Zeile als
    /// abgeschnitten gilt.
    static let cutMargin = 0.015

    private nonisolated static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = Int((Double(image.width) * factor).rounded())
        let height = Int((Double(image.height) * factor).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Dieselbe Zeile: Boxen überdecken sich UND der Text stimmt überein.
    /// Nur über die Geometrie verwarf die Prüfung auf leicht schiefen
    /// Handyfoto-Scans die wiedergefundene Zeile, weil sich die Boxen
    /// benachbarter Zeilen vertikal überlappen.
    private nonisolated static func isSameLine(_ existing: Line, text: String, box: CGRect) -> Bool {
        let a = existing.boundingBox
        let vertical = min(a.maxY, box.maxY) - max(a.minY, box.minY)
        let horizontal = min(a.maxX, box.maxX) - max(a.minX, box.minX)
        guard horizontal > 0, vertical > 0.3 * min(a.height, box.height) else { return false }
        // Nur Buchstaben und Ziffern: Teilstücke wie „Line 19.“ (der zweite
        // Durchgang liest oft nur den Zeilenanfang) sollen als Teil von
        // „Line 19: …“ gelten – Satzzeichen verhinderten das (Korpus: 27
        // doppelte Zeilen).
        let x = existing.text.lowercased().filter { $0.isLetter || $0.isNumber }
        let y = text.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !x.isEmpty, !y.isEmpty else { return true }
        if x.contains(y) || y.contains(x) { return true }
        // Der Text muss immer passen: Auf schiefen Fotos überlappen die
        // achsparallelen Boxen BENACHBARTER Zeilen stark – eine reine
        // Geometrieregel verwarf so ganze Zeilen (Nutzerseite 4, 2026-10-01).
        // Nahezu deckungsgleiche Boxen senken nur die Textschwelle.
        let nearlyIdentical = vertical > 0.8 * max(a.height, box.height)
            && horizontal > 0.8 * max(a.width, box.width)
        return similarity(x, y) >= (nearlyIdentical ? 0.5 : 0.8)
    }

    /// Anteil gemeinsamer Zeichen-Bigramme (Dice) – robust gegen einzelne
    /// abweichende Zeichen zwischen den Durchgängen.
    private nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        func bigrams(_ s: String) -> [String: Int] {
            let chars = Array(s)
            guard chars.count > 1 else { return [s: 1] }
            var out: [String: Int] = [:]
            for i in 0..<(chars.count - 1) { out[String(chars[i...i + 1]), default: 0] += 1 }
            return out
        }
        let ba = bigrams(a), bb = bigrams(b)
        let common = ba.reduce(0) { $0 + min($1.value, bb[$1.key] ?? 0) }
        let total = ba.values.reduce(0, +) + bb.values.reduce(0, +)
        return total == 0 ? 0 : 2 * Double(common) / Double(total)
    }

    private nonisolated static func recognizeOnce(cgImage: CGImage,
                                                  languages: [String]) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            throw OCRError.recognitionFailed(error.localizedDescription)
        }
        let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
        return observations.compactMap { obs -> Line? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return Line(text: candidate.string,
                        boundingBox: obs.boundingBox,
                        confidence: candidate.confidence)
        }
    }

    // MARK: - Textebene

    /// Content-Stream der unsichtbaren Textebene. Vision-Boxen liegen auf der
    /// ANGEZEIGTEN Seite; PDF-Inhalt liegt im ungedrehten MediaBox-Raum.
    /// /Rotate dreht im Uhrzeigersinn – die Abbildung Anzeige → Seite und die
    /// Laufrichtung des Textes (Tm) folgen daraus. Breite über Tz an die
    /// erkannte Zeilenbreite angepasst, damit Markierungen passen.
    nonisolated static func textLayer(lines: [Line], page: PDFPage) -> String {
        guard !lines.isEmpty else { return "" }
        let rotation = RotationNormalizer.normalized(page.rotation)
        let media = page.bounds(for: .mediaBox)
        let display = RotationNormalizer.rotatedSize(width: media.width, height: media.height,
                                                     rotation: rotation)
        var out = ""
        for line in lines {
            guard let encoded = pdfString(line.text) else { continue }
            let box = CGRect(x: line.boundingBox.minX * display.width,
                             y: line.boundingBox.minY * display.height,
                             width: line.boundingBox.width * display.width,
                             height: line.boundingBox.height * display.height)
            guard box.width > 0.5, box.height > 0.5 else { continue }
            let fontSize = max(1, box.height * 0.9)
            let natural = helveticaWidth(line.text, size: fontSize)
            let scale = natural > 0 ? min(max(box.width / natural * 100, 10), 500) : 100
            // Grundlinie: etwas über der Boxunterkante (Unterlängen).
            let dx = box.minX, dy = box.minY + box.height * 0.2
            let (a, b, c, d, u, v): (Double, Double, Double, Double, Double, Double)
            switch rotation {
            case 90:  (a, b, c, d, u, v) = (0, 1, -1, 0, media.width - dy, dx)
            case 180: (a, b, c, d, u, v) = (-1, 0, 0, -1, media.width - dx, media.height - dy)
            case 270: (a, b, c, d, u, v) = (0, -1, 1, 0, dy, media.height - dx)
            default:  (a, b, c, d, u, v) = (1, 0, 0, 1, dx, dy)
            }
            out += "BT 3 Tr /PDFToolsOCR \(fmt(fontSize)) Tf \(fmt(scale)) Tz "
                + "\(fmt(a)) \(fmt(b)) \(fmt(c)) \(fmt(d)) "
                + "\(fmt(media.minX + u)) \(fmt(media.minY + v)) Tm \(encoded) Tj ET\n"
        }
        return out
    }

    private nonisolated static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Breite in Helvetica (dieselben Metriken wie der Standard-14-Font).
    private nonisolated static func helveticaWidth(_ text: String, size: Double) -> Double {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed),
                                          nil, nil, nil)
    }

    /// PDF-Literal in WinAnsi (Deutsch/Englisch vollständig); nicht
    /// darstellbare Zeichen werden zu „?“, Sonderzeichen oktal maskiert.
    nonisolated static func pdfString(_ text: String) -> String? {
        guard let data = text.data(using: .windowsCP1252, allowLossyConversion: true),
              !data.isEmpty else { return nil }
        var out = "("
        for byte in data {
            switch byte {
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
                out += "\\" + String(UnicodeScalar(byte))
            case 0x20...0x7E:
                out += String(UnicodeScalar(byte))
            default:
                out += String(format: "\\%03o", byte)
            }
        }
        return out + ")"
    }
}

enum OCRError: LocalizedError {
    case unreadable(String)
    case locked(String)
    case noPages
    case missingPage(Int)
    case renderFailed
    case recognitionFailed(String)
    case writeFailed
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return String(localized: "PDF konnte nicht gelesen werden: \(name)")
        case .locked(let name): return String(localized: "Passwortgeschützt, OCR nicht möglich: \(name)")
        case .noPages: return String(localized: "Das PDF enthält keine Seiten.")
        case .missingPage(let n): return String(localized: "Seite \(n) konnte nicht gelesen werden.")
        case .renderFailed: return String(localized: "Seite konnte für die Erkennung nicht gerendert werden.")
        case .recognitionFailed(let d): return String(localized: "Texterkennung fehlgeschlagen: \(d)")
        case .writeFailed: return String(localized: "Durchsuchbares PDF konnte nicht geschrieben werden.")
        case .validationFailed(let detail): return String(localized: "Die Ausgabe hat die Prüfung nicht bestanden: \(detail)")
        }
    }
}
