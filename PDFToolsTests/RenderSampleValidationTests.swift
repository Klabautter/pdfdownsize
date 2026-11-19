import Testing
import Foundation
import CoreGraphics
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
        // Abstand zur Grenze dokumentieren: Grau muss klar darüber liegen.
        let measured = finding.flatMap { message in
            message.message.split(separator: " ").compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }.first
        }
        #expect((measured ?? 0) > 1.5 * PDFValidator.renderSampleMaximumPeakDeltaE,
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
