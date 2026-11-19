import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PDFTools

/// Masterplan A3 (18.11.2026): Die fertige Ausgabe wird gegen das ORIGINAL
/// gerendert, nicht nur Bild für Bild gegen das schon verkleinerte Bild.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Ein Bild wird grau ausgeliefert – Luminanz-SSIM sieht nichts, nur ein
///     Farbmaß auf dem farbigsten Teil fängt es.
///  2. Ein Bild fehlt oder ist leer (falscher Ersatz) – Strukturkollaps.
///  3. Falscher Alarm: Eine echte, gute Kompression darf die Prüfung nicht
///     auslösen – sonst kostet sie Ersparnis über unnötige Re-Plans.
///  4. Die Stichprobe trifft die veränderte Seite nicht – deshalb nimmt sie
///     die Seiten mit den meisten veränderten Bildbytes.
///  5. Ohne Referenz darf nichts stillschweigend als geprüft gelten.
@Suite(.serialized) struct RenderSampleValidationTests {

    static func pdf(from image: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-sample-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil)
        else { throw CocoaError(.featureUnsupported) }
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    static func grayscale(_ image: CGImage) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw CocoaError(.featureUnsupported) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try #require(ctx.makeImage())
    }

    static func blank(like image: CGImage) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: 200, height: 280, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.featureUnsupported) }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 280))
        return try #require(ctx.makeImage())
    }

    static func validate(output: URL, reference: URL) -> PDFValidator.Report {
        var policy = PDFValidator.Policy.compression
        policy.expectedPageCount = 1
        policy.renderSamplePages = [0]
        return PDFValidator.validate(outputURL: output, referenceURL: reference, policy: policy)
    }

    @Test func grauGewordeneUnterschriftWirdAbgelehnt() throws {
        let page = try ColorInkSurvivesCompressionE2ETests.signedLetterImage()
        let reference = try Self.pdf(from: page)
        let gray = try Self.pdf(from: Self.grayscale(page))
        defer { for u in [reference, gray] { try? FileManager.default.removeItem(at: u) } }

        let report = Self.validate(output: gray, reference: reference)
        #expect(!report.isValid, "Grau ausgelieferte Unterschrift wurde nicht erkannt")
        let finding = report.findings.first { $0.kind == .color }
        #expect(finding != nil, "Kein Farbbefund: \(report.failures)")
        #expect(finding?.pages == [1], "Befund ohne richtige Seite – der Re-Plan wüsste nicht, was zurückzustufen ist")
        #expect(finding.map { $0.severity.triggersRollback } == true)
        // Abstand zur Grenze dokumentieren: Grau muss klar darunter liegen.
        let measured = finding.flatMap { message in
            message.message.split(separator: " ").compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }.first
        }
        // Die Meldung nennt den Farberhalt in Prozent.
        #expect((measured ?? 100) < 0.5 * PDFValidator.renderSampleMinimumChromaRetention * 100,
                "Grau liegt zu nah an der Grenze: \(finding?.message ?? "")")
    }

    @Test func leeresBildWirdAbgelehnt() throws {
        let page = try ColorInkSurvivesCompressionE2ETests.signedLetterImage()
        let reference = try Self.pdf(from: page)
        let empty = try Self.pdf(from: Self.blank(like: page))
        defer { for u in [reference, empty] { try? FileManager.default.removeItem(at: u) } }

        let report = Self.validate(output: empty, reference: reference)
        #expect(report.findings.contains { $0.kind == .render && $0.pages == [1] },
                "Leere Seite wurde nicht erkannt: \(report.failures)")
    }

    @Test func echteKompressionBestehtOhneReplan() throws {
        let input = try ColorInkSurvivesCompressionE2ETests.signedLetterPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        for mode in CompressionMode.allCases {
            let result = try Compressor().compress(inputURL: input, mode: mode)
            defer { if result.outputURL != input { try? FileManager.default.removeItem(at: result.outputURL) } }
            #expect(result.qaReplanCount == 0, "\(mode.rawValue): Render-Stichprobe löste einen Re-Plan aus")
            let report = Self.validate(output: result.outputURL, reference: input)
            #expect(!report.findings.contains { $0.kind == .render || $0.kind == .color },
                    "\(mode.rawValue): \(report.failures)")
        }
    }

    @Test func stichprobeNimmtDieSeitenMitDenMeistenVeraendertenBytes() {
        let pages = PDFValidator.renderSamplePages(pageCount: 20,
                                                   changedBytesByPage: [7: 900, 3: 5000, 12: 10, 9: 800, 15: 700])
        #expect(pages.first == 0 && pages.contains(19))
        #expect(pages.count <= PDFValidator.maximumRenderSamplePages)
        #expect(pages.contains(3) && pages.contains(7) && pages.contains(9) && pages.contains(15))
        #expect(!pages.contains(12), "Die Seite mit dem kleinsten Unterschied verdrängte eine größere")
    }

    @Test func ohneReferenzKeinStillerPass() throws {
        let page = try ColorInkSurvivesCompressionE2ETests.signedLetterImage()
        let output = try Self.pdf(from: page)
        defer { try? FileManager.default.removeItem(at: output) }
        var policy = PDFValidator.Policy.compression
        policy.renderSamplePages = [0]
        let report = PDFValidator.validate(outputURL: output, referenceURL: nil, policy: policy)
        #expect(report.warnings.contains { $0.contains("Render-Stichprobe übersprungen") })
    }

    // MARK: - Masterplan N3: große Seiten

    /// Wie `pdf(from:)`, aber mit frei gewählter Seitengröße in Punkt.
    static func pdf(from image: CGImage, pageSize: CGSize) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-sample-gross-\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: pageSize)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil)
        else { throw CocoaError(.featureUnsupported) }
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    /// Befund (Prüfung 19.11.): Über 40 Megapixel bei 110 DPI gab `renderPage`
    /// nil zurück, und der Validator machte daraus „nicht vergleichbar
    /// gerendert" – ein Fehler, den kein Re-Plan beheben kann. Plakate,
    /// Rollenplots und große Scans ließen sich nicht mehr komprimieren
    /// (1.0.9 konnte es).
    ///
    /// Fehlermöglichkeiten: (1) eine große Seite gilt als nicht vergleichbar;
    /// (2) der kleinere Maßstab macht das Netz blind – Farbverlust und leere
    /// Seite müssen auch dort auffallen; (3) Quelle und Ausgabe werden mit
    /// verschiedenem Maßstab gerendert.
    static let posterSize = CGSize(width: 5000, height: 6000)   // 69″ × 83″

    @Test func grosseSeiteWirdVerglichenStattAbgelehnt() throws {
        let page = try ColorInkSurvivesCompressionE2ETests.signedLetterImage()
        let reference = try Self.pdf(from: page, pageSize: Self.posterSize)
        let same = try Self.pdf(from: page, pageSize: Self.posterSize)
        defer { for url in [reference, same] { try? FileManager.default.removeItem(at: url) } }
        let report = Self.validate(output: same, reference: reference)
        #expect(!report.findings.contains { $0.kind == .render || $0.kind == .color },
                "Große Seite abgelehnt: \(report.failures)")
    }

    @Test func grosseSeiteMitFarbverlustOderLeerWirdWeiterAbgelehnt() throws {
        let page = try ColorInkSurvivesCompressionE2ETests.signedLetterImage()
        let reference = try Self.pdf(from: page, pageSize: Self.posterSize)
        let gray = try Self.pdf(from: try Self.grayscale(page), pageSize: Self.posterSize)
        let blank = try Self.pdf(from: try Self.blank(like: page), pageSize: Self.posterSize)
        defer { for url in [reference, gray, blank] { try? FileManager.default.removeItem(at: url) } }
        #expect(Self.validate(output: gray, reference: reference).findings.contains { $0.kind == .color },
                "Farbverlust auf großer Seite nicht erkannt")
        #expect(Self.validate(output: blank, reference: reference).findings.contains { $0.kind == .render },
                "Leere große Seite nicht erkannt")
    }

    /// Verschiedene Seitengrößen sind weiterhin „nicht vergleichbar".
    @Test func verschiedeneSeitengroessenBleibenEinBefund() throws {
        let page = try ColorInkSurvivesCompressionE2ETests.signedLetterImage()
        let reference = try Self.pdf(from: page, pageSize: Self.posterSize)
        let other = try Self.pdf(from: page, pageSize: CGSize(width: 4000, height: 6000))
        defer { for url in [reference, other] { try? FileManager.default.removeItem(at: url) } }
        #expect(Self.validate(output: other, reference: reference).findings.contains { $0.kind == .render })
    }

    // MARK: - Masterplan N17: verkleinerter Scan auf übergroßer Seite

    /// Befund (volle Suite 19.11.): Ein Papier-Scan auf übergroßer Seite
    /// (1898 × 2645 pt, die Homework_2-Klasse) ließ sich mit Smart nicht mehr
    /// komprimieren: „Farbe geht verloren (ΔE 25,6)". Die Tinte war sichtbar
    /// blau geblieben, nur blasser. Das Farbnetz maß ΔE Pixel für Pixel auf
    /// dem 110-DPI-Raster der großen Seite (2900 × 4041 px) – Helligkeit und
    /// Kantenschärfe der dünnen Striche statt ihrer Farbe. Dasselbe Maß
    /// übersah einen echten Handschrift-Scan, der komplett grau wurde
    /// (ΔE 20, Grenze 24). Seit N17 misst die Stichprobe den Farberhalt
    /// (`QualityGates.peakChromaRetention`), große Seiten auf dem geeichten
    /// Raster.
    ///
    /// Vorlage ist das Bild aus `ScanPresetSpreadTests` (Lineatur, dünne
    /// blaue Tinte), 1:1 auf der übergroßen Seite.
    ///
    /// Fehlermöglichkeiten: (1) die gewollte Verkleinerung gilt weiter als
    /// Farbverlust; (2) die Korrektur macht das Netz blind – grau gewordene
    /// Tinte auf derselben Seite muss weiter klar über der Grenze liegen.
    static let oversizedScanPage = CGSize(width: 1898, height: 2645)

    /// Auf `factor` der Kantenlänge verkleinert und als JPEG neu kodiert –
    /// was die Stufen mit einem Papier-Scan tun.
    static func downsampledJPEG(_ image: CGImage, factor: Double, quality: Double) throws -> CGImage {
        let w = Int((Double(image.width) * factor).rounded())
        let h = Int((Double(image.height) * factor).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.featureUnsupported) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let small = try #require(ctx.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, small,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithData(data, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// 1240/1898 ist das Scan-Ziel von Smart, 910/1898 das von Klein. Vor
    /// N17 war der Klein-Fall rot (ΔE 26,8); der Smart-Fall lag in dieser
    /// Nachstellung knapp unter der alten Grenze, im echten Lauf darüber
    /// (`ScanPresetSpreadTests`).
    @Test(arguments: [1240.0 / 1898.0, 910.0 / 1898.0])
    func verkleinerterScanAufUebergrosserSeiteIstKeinFarbverlust(factor: Double) throws {
        let page = try ScanPresetSpreadTests.scanImage(.paper, pixels: (1898, 2645))
        let reference = try Self.pdf(from: page, pageSize: Self.oversizedScanPage)
        let smaller = try Self.pdf(from: Self.downsampledJPEG(page, factor: factor, quality: 0.5),
                                   pageSize: Self.oversizedScanPage)
        defer { for url in [reference, smaller] { try? FileManager.default.removeItem(at: url) } }
        let report = Self.validate(output: smaller, reference: reference)
        #expect(!report.findings.contains { $0.kind == .color },
                "Verkleinerung als Farbverlust gewertet: \(report.failures)")
    }

    @Test func grauGewordeneTinteAufUebergrosserSeiteWirdWeiterAbgelehnt() throws {
        let page = try ScanPresetSpreadTests.scanImage(.paper, pixels: (1898, 2645))
        let reference = try Self.pdf(from: page, pageSize: Self.oversizedScanPage)
        let gray = try Self.pdf(
            from: Self.grayscale(Self.downsampledJPEG(page, factor: 1240.0 / 1898.0, quality: 0.5)),
            pageSize: Self.oversizedScanPage)
        defer { for url in [reference, gray] { try? FileManager.default.removeItem(at: url) } }
        let finding = Self.validate(output: gray, reference: reference).findings.first { $0.kind == .color }
        #expect(finding != nil, "Grau gewordene Tinte auf übergroßer Seite nicht erkannt")
        let measured = finding.flatMap { finding in
            finding.message.split(separator: " ")
                .compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }.first
        }
        // Die Meldung nennt den Farberhalt in Prozent.
        #expect((measured ?? 100) < 0.5 * PDFValidator.renderSampleMinimumChromaRetention * 100,
                "Grau liegt zu nah an der Grenze: \(finding?.message ?? "")")
    }

    /// Weißes Blatt mit senkrechten, 2 px breiten Strichen in `color`.
    static func stripes(_ color: CGColor, offset: Int = 0) throws -> QualityGates.Sample {
        let edge = 160
        guard let ctx = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.featureUnsupported) }
        ctx.setShouldAntialias(false)
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        ctx.setFillColor(color)
        for x in stride(from: 8 + offset, to: edge - 4, by: 16) {
            ctx.fill(CGRect(x: x, y: 0, width: 2, height: edge))
        }
        let image = try #require(ctx.makeImage())
        return try #require(QualityGates.sample(image))
    }

    /// Das Maß selbst: Es misst, ob die Farbe noch da ist – nicht, ob der
    /// Strich scharf ist oder an derselben Stelle sitzt.
    @Test func farberhaltMisstFarbeNichtSchaerfe() throws {
        let blue = CGColor(red: 0.2, green: 0.25, blue: 0.75, alpha: 1)
        let reference = try Self.stripes(blue)
        func retention(_ color: CGColor, offset: Int = 0) throws -> Double {
            let candidate = try Self.stripes(color, offset: offset)
            return try #require(QualityGates.peakChromaRetention(reference: reference, candidate: candidate))
        }
        let limit = PDFValidator.renderSampleMinimumChromaRetention

        let same = try retention(blue)
        #expect(same > 0.99, "gleiches Bild: \(same)")
        let shifted = try retention(blue, offset: 1)
        #expect(shifted > 0.9, "um 1 px versetzt: \(shifted)")
        // Blasser, aber blau: zur Hälfte mit Weiß gemischt.
        let pale = try retention(CGColor(red: 0.6, green: 0.625, blue: 0.875, alpha: 1))
        #expect(pale > limit && pale < 0.8, "blasser: \(pale)")
        // Grau gleicher Helligkeit und eine andere Farbe: nichts erhalten.
        let gray = try retention(CGColor(gray: 0.3, alpha: 1))
        #expect(gray < 0.02, "grau: \(gray)")
        let red = try retention(CGColor(red: 0.75, green: 0.25, blue: 0.2, alpha: 1))
        #expect(red < 0.05, "rot statt blau: \(red)")
        // Ohne Farbe in der Referenz gibt es nichts zu messen.
        let neutral = try Self.stripes(CGColor(gray: 0.3, alpha: 1))
        #expect(QualityGates.peakChromaRetention(reference: neutral, candidate: reference) == nil)
    }

    // MARK: - Masterplan N4: gewollte Graustufen

    /// Befund (Prüfung 19.11.): „Eigene" mit Graustufen rechnet ein farbiges
    /// Dokument absichtlich grau. Die Render-Stichprobe kannte das nicht und
    /// meldete Farbverlust – nach bis zu vier Läufen endete der Auftrag im
    /// Fehler oder ohne Wandlung. Die Bild-Gates kennen die Ausnahme.
    ///
    /// Fehlermöglichkeiten: (1) der gewollte Graustufenlauf scheitert;
    /// (2) die Ausnahme schaltet das Netz ganz ab – eine leere Seite muss
    /// auch im Graustufenlauf auffallen; (3) die Ausnahme greift ohne
    /// Graustufen-Wunsch.
    @Test func gewollteGraustufenLaufenDurchUndSindGrau() throws {
        let input = try PDFFixtures.photoHeavyPDF(pixels: 1200)
        defer { try? FileManager.default.removeItem(at: input) }
        let options = CompressionPresetFactory.custom(dpi: 150, quality: 0.8, grayscale: true)
        let result = try Compressor().compress(inputURL: input, options: options)
        defer { if result.outputURL != input { try? FileManager.default.removeItem(at: result.outputURL) } }
        #expect(!result.returnedOriginal, "Die Wandlung wurde verworfen – das Original kam zurück")
        #expect(result.qaReplanCount == 0, "Die Render-Stichprobe löste einen Re-Plan aus")
        let document = try #require(CGPDFDocument(result.outputURL as CFURL))
        let page = try #require(document.page(at: 1))
        let box = page.getBoxRect(.cropBox)
        let ctx = try #require(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        ctx.scaleBy(x: 400 / box.width, y: 400 / box.height)
        ctx.drawPDFPage(page)
        let rendered = try #require(ctx.makeImage())
        let census = try #require(ChromaCensus.of(rendered))
        #expect(census.isNeutral, "Die Ausgabe ist nicht grau")
    }

    @Test func graustufenAusnahmeLaesstDasStrukturnetzStehen() throws {
        let page = try ColorInkSurvivesCompressionE2ETests.signedLetterImage()
        let reference = try Self.pdf(from: page)
        let gray = try Self.pdf(from: try Self.grayscale(page))
        let blank = try Self.pdf(from: try Self.blank(like: page))
        defer { for url in [reference, gray, blank] { try? FileManager.default.removeItem(at: url) } }
        var policy = PDFValidator.Policy.compression
        policy.expectedPageCount = 1
        policy.renderSamplePages = [0]
        policy.renderSampleExpectsGrayscale = true
        let wanted = PDFValidator.validate(outputURL: gray, referenceURL: reference, policy: policy)
        #expect(!wanted.findings.contains { $0.kind == .color }, "Gewollte Graustufen als Farbverlust gemeldet")
        let empty = PDFValidator.validate(outputURL: blank, referenceURL: reference, policy: policy)
        #expect(empty.findings.contains { $0.kind == .render }, "Leere Seite im Graustufenlauf nicht erkannt")
        // Ohne Graustufen-Wunsch bleibt es ein Farbverlust.
        #expect(Self.validate(output: gray, reference: reference).findings.contains { $0.kind == .color })
    }

    // MARK: - Grenzfälle der Seitengröße (N3 und Fuzz-Fund crash-100406)

    /// Der Maßstab bleibt für jede Box berechenbar oder ist ausdrücklich nil –
    /// nie ein Wert, an dem die Pixelrechnung abbricht.
    @Test func massstabFuerGrenzfaelleDerSeitengroesse() {
        let full = PDFValidator.renderSampleDPI / 72.0
        #expect(PDFValidator.renderSampleScale(for: CGRect(x: 0, y: 0, width: 595, height: 842)) == full)
        let poster = PDFValidator.renderSampleScale(for: CGRect(origin: .zero, size: Self.posterSize))
        #expect(poster != nil && poster! < full)
        #expect(poster! * poster! * 5000 * 6000 <= Double(PDFValidator.maximumRenderSamplePixels))
        for box in [CGRect.zero, CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100),
                    CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
                    CGRect(x: 0, y: 0, width: 1e200, height: 1e200)] {
            #expect(PDFValidator.renderSampleScale(for: box) == nil, "\(box)")
        }
    }

    /// Riesige, aber gültige Seite (100.000 pt Kante, das 500-Fache von A4):
    /// dieselbe Datei gegen sich selbst ist kein Befund.
    @Test func riesigeGueltigeSeiteIstVergleichbar() throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let content = b.addStream(dictionary: "", content: "BT /F1 9000 Tf 5000 50000 Td (RIESIG) Tj ET")
        let page = b.addPage(parent: pages, mediaBox: "[0 0 100000 100000]",
                             resources: "<</Font<</F1 \(font) 0 R>>>>", contents: content)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = try b.write(rootObject: root, prefix: "n3-riesig")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = Self.validate(output: url, reference: url)
        #expect(!report.findings.contains { $0.kind == .render || $0.kind == .color }, "\(report.failures)")
    }

    /// Fuzz-Fund crash-100406 (mutierte Seitengröße): Der Lauf endet mit einem
    /// Ergebnis oder einem Fehler – nicht mit einem Absturz des Prozesses.
    @Test(.needsLocalFiles("tmp/fuzz-findings/crash-100406.pdf"))
    func mutierteSeitengroesseStuerztNichtAb() {
        let url = LocalTestData.repoRoot.appendingPathComponent("tmp/fuzz-findings/crash-100406.pdf")
        do {
            let result = try Compressor().compress(inputURL: url, mode: .smart)
            if result.outputURL != url { try? FileManager.default.removeItem(at: result.outputURL) }
        } catch {
            // Ein sauberer Fehler ist ein gültiger Ausgang.
        }
    }
}
