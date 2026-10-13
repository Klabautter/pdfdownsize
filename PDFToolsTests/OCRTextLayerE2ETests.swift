import Testing
import Foundation
import AppKit
import PDFKit
import CoreText
@testable import PDFTools

/// OCR v2 (2026-10-01): Statt einer gerasterten Kopie bekommt das ORIGINAL
/// eine unsichtbare Textebene. Nutzerbefund: Die gerasterte Kopie verlor
/// Vektoren, vorhandenen Text, Links, Formulare und Lesezeichen und verlangte
/// deshalb eine ausdrückliche Zustimmung.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Erkannter Text ist nicht durchsuchbar/kopierbar.
///  2. Die Seite sieht danach anders aus (Textebene sichtbar, Inhalt verschoben).
///  3. Born-digital-Seiten werden angefasst: doppelter Text, Link verloren.
///  4. Auf gedrehten Seiten liegt die Textebene an der falschen Stelle
///     (Suche markiert Leere statt des Wortes).
///  5. Der Output ist strukturell ungültig oder verliert Seiten.
///  6. Der Inhalt der Originalseite verändert den Grafikzustand der
///     Textebene (fehlendes q/Q) – Text landet außerhalb der Seite.
@Suite(.serialized) struct OCRTextLayerE2ETests {

    /// Gerenderter „Scan“: schwarzer Text auf Weiß, nur als Bild.
    static func scanImage(lines: [String], width: Int = 2480, height: Int = 3508) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 90, nil)
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.black])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: 300, y: height - 500 - index * 220)
            CTLineDraw(line, ctx)
        }
        return try #require(ctx.makeImage())
    }

    static func rotatedCounterClockwise(_ image: CGImage) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: image.height, height: image.width,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.translateBy(x: CGFloat(image.height), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try #require(ctx.makeImage())
    }

    /// Drei Seiten: Scan, gedrehter Scan (90°), born-digital mit Text + Link.
    static func fixture() throws -> URL {
        let doc = PDFDocument()
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        for (index, words) in [["Rechnung Nummer 4711", "Lieferung im Oktober"],
                               ["Gedrehte Seite Quittung", "Betrag dreihundert"]].enumerated() {
            let upright = try scanImage(lines: words)
            if index == 0 {
                let image = NSImage(cgImage: upright, size: pageRect.size)
                let page = try #require(PDFPage(image: image))
                page.setBounds(pageRect, for: .mediaBox)
                doc.insert(page, at: doc.pageCount)
            } else {
                // Wie ein quer eingelegter Scan: Bild liegt um 90° gegen den
                // Uhrzeigersinn gedreht, /Rotate 90 richtet die Anzeige auf.
                let stored = try Self.rotatedCounterClockwise(upright)
                let landscape = CGRect(x: 0, y: 0, width: pageRect.height, height: pageRect.width)
                let page = try #require(PDFPage(image: NSImage(cgImage: stored, size: landscape.size)))
                page.setBounds(landscape, for: .mediaBox)
                page.rotation = 90
                doc.insert(page, at: doc.pageCount)
            }
        }
        // Born-digital: echte Textzeichen + Link-Annotation.
        let data = NSMutableData()
        var box = pageRect
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        let attributed = NSAttributedString(string: "Digitaler Vertragstext mit echten Zeichen",
                                            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
        pdf.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        let digital = try #require(PDFDocument(data: data as Data)?.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 690, width: 200, height: 20),
                                 forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        digital.addAnnotation(link)
        doc.insert(digital, at: doc.pageCount)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-layer-\(UUID().uuidString).pdf")
        try #require(doc.write(to: url))
        return url
    }

    @Test(.timeLimit(.minutes(5)))
    func textebeneMachtDurchsuchbarOhneDasOriginalZuVeraendern() async throws {
        let source = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let output = try await OCREngine.run(sourceURL: source,
                                             languages: ["de-DE", "en-US"]) { _ in }
        defer { try? FileManager.default.removeItem(at: output.outputURL) }

        let doc = try #require(PDFDocument(url: output.outputURL))
        #expect(doc.pageCount == 3)                                            // 5

        // 1: erkannter Text ist durchsuchbar.
        for word in ["Rechnung", "Oktober", "Quittung"] {
            #expect(!doc.findString(word, withOptions: .caseInsensitive).isEmpty,
                    "„\(word)“ nicht durchsuchbar")
        }

        // 4 + 6: Die Fundstelle liegt dort, wo das Wort im Bild steht – auch
        // auf der gedrehten Seite (Vergleich in Anzeige-Koordinaten).
        for (word, pageIndex) in [("Rechnung", 0), ("Quittung", 1)] {
            let hit = try #require(doc.findString(word, withOptions: .caseInsensitive).first)
            let page = try #require(doc.page(at: pageIndex))
            #expect(hit.pages.first == page, "„\(word)“ auf falscher Seite")
            let bounds = hit.bounds(for: page)
            let media = page.bounds(for: .mediaBox)
            #expect(media.insetBy(dx: -1, dy: -1).contains(bounds),
                    "„\(word)“ außerhalb der Seite: \(bounds)")
            // Bild: Zeile 1 bei 500/3508 von oben, links bei 300/2480.
            // Abstand vom oberen Rand der ANGEZEIGTEN Seite in %: bei /Rotate
            // 90 ist „oben“ die linke Kante des ungedrehten MediaBox-Raums.
            let fromTop = page.rotation == 90
                ? (bounds.minX - media.minX) / media.width * 100
                : (media.maxY - bounds.maxY) / media.height * 100
            #expect(fromTop < 25, "„\(word)“ vertikal falsch: \(fromTop) % von oben")
        }

        // 3: Die born-digital-Seite bleibt unberührt.
        let digital = try #require(doc.page(at: 2))
        #expect(digital.string?.contains("Digitaler Vertragstext") == true)
        #expect(digital.string?.components(separatedBy: "Vertragstext").count == 2,
                "Text doppelt – Seite wurde erkannt statt übersprungen")
        #expect(digital.annotations.contains { $0.url?.host == "example.com" }, "Link verloren")
        #expect(output.pages.first { $0.pageIndex == 2 }?.skippedExistingText == true)

        // 2: optisch identisch (unsichtbare Textebene).
        let pages = try RenderDifferential.compare(sourceURL: source,
                                                   outputURL: output.outputURL, dpi: 72)
        #expect(pages.allSatisfy { $0.ssim >= 0.999 }, "Seiten verändert: \(pages.map(\.ssim))")

        // 5: strukturell gültig.
        let report = PDFValidator.validate(outputURL: output.outputURL,
                                           policy: .pageOperation(expectedPageCount: 3))
        #expect(report.isValid)
    }

    /// Befund A3 (Review 2026-10-09): Die Oberfläche verspricht „Links,
    /// Formulare und Lesezeichen bleiben erhalten", geprüft wurde das nur an
    /// einer ÜBERSPRUNGENEN Seite. Hier bekommt eine Seite mit Link-,
    /// Formularfeld-Annotation, Lesezeichen und Dokumenttitel tatsächlich
    /// eine Textebene.
    ///
    /// Vorher aufgeschriebene Fehlermöglichkeiten:
    ///  1. Annotationen (Link, Widget) fehlen oder sind weniger geworden.
    ///  2. Link-URL oder Feldname verändert.
    ///  3. Lesezeichen weg oder Ziel verloren; Titel verloren.
    ///  4. Seitengeometrie verändert.
    ///  5. Die Produktvalidierung (`Policy.ocr`) würde solche Verluste
    ///     durchwinken – sie muss sie hart melden.
    @Test(.timeLimit(.minutes(5)))
    func erkannteSeiteBehaeltAnmerkungenFormularLesezeichenUndTitel() async throws {
        let doc = PDFDocument()
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let image = NSImage(cgImage: try Self.scanImage(lines: ["Lieferschein Nummer 9", "Ware im November"]),
                            size: pageRect.size)
        let page = try #require(PDFPage(image: image))
        page.setBounds(pageRect, for: .mediaBox)
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 100, width: 200, height: 20),
                                 forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.org/a3")
        page.addAnnotation(link)
        let field = PDFAnnotation(bounds: CGRect(x: 72, y: 140, width: 200, height: 24),
                                  forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "FeldA3"
        page.addAnnotation(field)
        doc.insert(page, at: 0)
        let root = PDFOutline(), child = PDFOutline()
        child.label = "Lieferschein"
        child.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 842))
        root.insertChild(child, at: 0)
        doc.outlineRoot = root
        doc.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Titel A3"]
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-a3-\(UUID().uuidString).pdf")
        try #require(doc.write(to: source))
        defer { try? FileManager.default.removeItem(at: source) }
        // Vorbedingung: Die Fixture trägt wirklich alles, was geprüft wird.
        let before = try #require(PDFDocument(url: source))
        #expect(before.page(at: 0)?.annotations.count == 2)
        #expect(before.outlineRoot?.numberOfChildren == 1)

        let output = try await OCREngine.run(sourceURL: source,
                                             languages: ["de-DE", "en-US"]) { _ in }
        defer { try? FileManager.default.removeItem(at: output.outputURL) }
        #expect(output.recognizedPageCount == 1, "Seite wurde nicht erkannt")

        let out = try #require(PDFDocument(url: output.outputURL))
        let outPage = try #require(out.page(at: 0))
        #expect(!out.findString("Lieferschein", withOptions: .caseInsensitive).isEmpty)
        // 1 + 2
        let annots = outPage.annotations
        #expect(annots.count == 2, "Annotationen: \(annots.count)")
        #expect(annots.contains { $0.url?.absoluteString == "https://example.org/a3" }, "Link verloren")
        #expect(annots.contains { $0.fieldName == "FeldA3" && $0.widgetFieldType == .text },
                "Formularfeld verloren")
        // 3
        #expect(out.outlineRoot?.numberOfChildren == 1, "Lesezeichen verloren")
        #expect(out.outlineRoot?.child(at: 0)?.label == "Lieferschein")
        #expect(out.outlineRoot?.child(at: 0)?.destination?.page == outPage, "Lesezeichen-Ziel verloren")
        #expect(out.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Titel A3",
                "Titel verloren")
        // 4
        #expect(outPage.bounds(for: .mediaBox) == pageRect)
        // 5: Produktvalidierung mit Referenz – dieselbe Politik wie das ViewModel.
        let report = PDFValidator.validate(outputURL: output.outputURL,
                                           referenceURL: source,
                                           policy: .ocr(expectedPageCount: 1, sourceURL: source))
        #expect(report.isValid, "Validierung: \(report.failures)")
        // Gegenprobe: Ein Output ohne die Annotationen muss durchfallen.
        let stripped = try #require(PDFDocument(url: output.outputURL))
        for a in stripped.page(at: 0)?.annotations ?? [] { stripped.page(at: 0)?.removeAnnotation(a) }
        let strippedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-a3-stripped-\(UUID().uuidString).pdf")
        try #require(stripped.write(to: strippedURL))
        defer { try? FileManager.default.removeItem(at: strippedURL) }
        let negative = PDFValidator.validate(outputURL: strippedURL,
                                             referenceURL: source,
                                             policy: .ocr(expectedPageCount: 1, sourceURL: source))
        #expect(!negative.isValid, "Verlust von Annotationen wurde nicht gemeldet")
    }

    /// Befund A8 (Review 2026-10-09): Kein Pixel-Deckel beim 300-DPI-Render –
    /// A0 ergäbe 9 933 × 14 043 px je Durchgang. Fehlermöglichkeiten:
    ///  1. Render über dem Deckel (Speicherspitze).
    ///  2. Mit Deckel wird der Text nicht mehr gefunden.
    ///  3. Textebene landet nicht mehr auf der Seite (Punktgeometrie falsch).
    @Test(.timeLimit(.minutes(5)))
    func grossformatWirdGedeckeltUndBleibtErkennbar() async throws {
        let a0 = CGSize(width: 2384, height: 3370)
        let full = PageImageExporter.pixelSize(pageBounds: CGRect(origin: .zero, size: a0),
                                               dpi: OCREngine.renderDPI)
        let capped = OCREngine.cappedRenderSize(full)
        #expect(full.width * full.height > CGFloat(OCREngine.maximumRenderPixels))
        #expect(capped.width * capped.height <= CGFloat(OCREngine.maximumRenderPixels))
        #expect(abs(capped.width / capped.height - full.width / full.height) < 0.01)

        let doc = PDFDocument()
        let image = NSImage(cgImage: try Self.scanImage(lines: ["Grossformat Plan Nummer 12"]),
                            size: a0)
        let page = try #require(PDFPage(image: image))
        page.setBounds(CGRect(origin: .zero, size: a0), for: .mediaBox)
        doc.insert(page, at: 0)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-a0-\(UUID().uuidString).pdf")
        try #require(doc.write(to: source))
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await OCREngine.run(sourceURL: source,
                                             languages: ["de-DE", "en-US"]) { _ in }
        defer { try? FileManager.default.removeItem(at: output.outputURL) }
        let out = try #require(PDFDocument(url: output.outputURL))
        let hit = try #require(out.findString("Grossformat", withOptions: .caseInsensitive).first)
        let outPage = try #require(out.page(at: 0))
        #expect(outPage.bounds(for: .mediaBox).size == a0)
        #expect(outPage.bounds(for: .mediaBox).insetBy(dx: -1, dy: -1).contains(hit.bounds(for: outPage)))
    }

    /// Gemischte Seite: Vollseiten-Scan + digital eingefügte Kopfzeile
    /// (≥ 20 Zeichen). Früher galt die Seite als „hat Text“ und wurde ganz
    /// übersprungen. Fehlermöglichkeiten: Scan-Text bleibt unauffindbar; die
    /// digitale Kopfzeile landet ein zweites Mal in der Textebene.
    @Test(.timeLimit(.minutes(3)))
    func gemischteSeiteWirdErkanntOhneDoppeltenText() async throws {
        let scan = try Self.scanImage(lines: ["", "Lieferschein Nummer 815", "Empfang bestätigt"])
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.draw(scan, in: box)
        let header = NSAttributedString(string: "Digital eingefügter Eingangsvermerk",
                                        attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 11, nil)])
        pdf.textPosition = CGPoint(x: 72, y: 810)
        CTLineDraw(CTLineCreateWithAttributedString(header), pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-mixed-\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let output = try await OCREngine.run(sourceURL: url, languages: ["de-DE", "en-US"]) { _ in }
        defer { try? FileManager.default.removeItem(at: output.outputURL) }
        let doc = try #require(PDFDocument(url: output.outputURL))
        #expect(output.pages.first?.skippedExistingText == false, "gemischte Seite übersprungen")
        #expect(!doc.findString("Lieferschein", withOptions: .caseInsensitive).isEmpty)
        #expect(doc.findString("Eingangsvermerk", withOptions: .caseInsensitive).count == 1,
                "digitale Kopfzeile doppelt in der Textebene")
    }
}
