import Testing
import Foundation
import AppKit
import PDFKit
import CoreText
import CoreImage
@testable import PDFTools

/// Nutzerbefund 2026-10-01 (Screenshot): Notizseite (Karopapier) mit zwei
/// eingebetteten Handyfotos von Beamer-Folien – OCR erkannte darauf nichts
/// oder nur Teile. Ursache: Die Seite wurde als Ganzes mit 300 DPI gerendert;
/// das verkleinert platzierte Foto verlor dabei rund drei Viertel seiner
/// Auflösung, die kleine graue Folienschrift fiel unter Visions Lesbarkeit.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten des Fixes:
///  1. Fototext bleibt unauffindbar.
///  2. Treffer liegen an der falschen Stelle der Seite (Platzierung falsch
///     abgebildet) – die Suche markiert Leere.
///  3. Text erscheint doppelt (Seitenrender + Foto erkennen dieselbe Zeile).
///  4. Laufzeit/Speicher explodieren bei großen Fotos.
@Suite(.serialized) struct OCREmbeddedPhotoE2ETests {

    static let slideLines = ["Beispielfragen Antwort",
                             "Kündigungsverbot gegenüber Schwangeren",
                             "Bedeutung des Grundgesetzes für das Arbeitsrecht",
                             "Werkvertrag und Dienstvertrag abgrenzen"]

    /// „Foto“ einer Folie: 3024 × 2268 px, graue Schrift, leicht unscharf.
    static func slidePhoto(lines: [String]) throws -> CGImage {
        let width = 3024, height = 2268
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.42, green: 0.40, blue: 0.38, alpha: 1)   // Raum
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0.93, green: 0.94, blue: 0.92, alpha: 1)   // Leinwand
        ctx.fill(CGRect(x: 300, y: 300, width: 2400, height: 1700))
        let font = CTFontCreateWithName("Helvetica" as CFString, 34, nil)
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor(white: 0.38, alpha: 1)]))
            ctx.textPosition = CGPoint(x: 420, y: 1800 - index * 90)
            CTLineDraw(line, ctx)
        }
        let image = try #require(ctx.makeImage())
        let blurred = CIImage(cgImage: image).applyingGaussianBlur(sigma: 1.0)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(CIContext().createCGImage(blurred, from: blurred.extent))
    }

    /// Karopapier-Seite (Vektorlinien) mit zwei kleinen Fotos.
    static func notePage() throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.setStrokeColor(gray: 0.85, alpha: 1)
        pdf.setLineWidth(0.4)
        for x in stride(from: 0, through: 595, by: 14) {
            pdf.move(to: CGPoint(x: x, y: 0)); pdf.addLine(to: CGPoint(x: x, y: 842))
        }
        for y in stride(from: 0, through: 842, by: 14) {
            pdf.move(to: CGPoint(x: 0, y: y)); pdf.addLine(to: CGPoint(x: 595, y: y))
        }
        pdf.strokePath()
        let first = try slidePhoto(lines: Array(slideLines.prefix(2)))
        let second = try slidePhoto(lines: Array(slideLines.suffix(2)))
        pdf.draw(first, in: CGRect(x: 40, y: 520, width: 280, height: 210))
        pdf.draw(second, in: CGRect(x: 40, y: 200, width: 280, height: 210))
        pdf.endPDFPage()
        pdf.closePDF()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-photos-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    @Test(.timeLimit(.minutes(5)))
    func textInEingebettetenFotosWirdErkannt() async throws {
        let url = try Self.notePage()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        let output = try await OCREngine.run(sourceURL: url, languages: ["de-DE", "en-US"]) { _ in }
        let seconds = Date().timeIntervalSince(start)
        defer { try? FileManager.default.removeItem(at: output.outputURL) }
        let doc = try #require(PDFDocument(url: output.outputURL))
        let page = try #require(doc.page(at: 0))

        for (word, photoRect) in [("Kündigungsverbot", CGRect(x: 40, y: 520, width: 280, height: 210)),
                                  ("Grundgesetzes", CGRect(x: 40, y: 200, width: 280, height: 210)),
                                  ("Werkvertrag", CGRect(x: 40, y: 200, width: 280, height: 210))] {
            let hits = doc.findString(word, withOptions: .caseInsensitive)
            #expect(hits.count == 1, "„\(word)“: \(hits.count) Treffer")            // 1 + 3
            if let hit = hits.first {
                let bounds = hit.bounds(for: page)
                #expect(photoRect.insetBy(dx: -4, dy: -4).contains(CGPoint(x: bounds.midX, y: bounds.midY)),
                        "„\(word)“ außerhalb des Fotos: \(bounds)")                  // 2
            }
        }
        #expect(seconds < 30, "Laufzeit \(seconds) s")                                // 4
    }
}
