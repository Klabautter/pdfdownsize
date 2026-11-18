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
}
