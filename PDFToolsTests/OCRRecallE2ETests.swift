import Testing
import Foundation
import AppKit
import PDFKit
import CoreText
@testable import PDFTools

/// Nutzerbefund 2026-10-01: „OCR lässt noch viel durch, was man erkennen
/// könnte.“ Messung statt Gefühl: eine Scan-Seite mit BEKANNTEM Text in
/// 7/9/11/14 pt (leicht unscharf + Rauschen wie ein Scanner), Wort-Recall
/// je Schriftgröße. Artefakt: `benchmark/ocr-recall/result.json`.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Kleine Schrift (Fußnoten, 7–9 pt) fällt durch.
///  2. Mehr Recall kostet Präzision (erfundene Wörter).
///  3. Laufzeit explodiert (z. B. durch Kachelung).
@Suite(.serialized) struct OCRRecallE2ETests {

    static let sizes: [Double] = [7, 9, 11, 14]
    static let sentences = [
        "Der Vertrag beginnt am ersten Oktober und endet nach zwei Jahren",
        "Die Rechnung enthält sieben Positionen und eine Gutschrift",
        "Bitte überweisen Sie den Betrag innerhalb von vierzehn Tagen",
        "Für Rückfragen steht Ihnen unser Kundenservice gerne zur Verfügung",
    ]

    /// A4 bei 300 DPI; je Schriftgröße ein Block mit allen Sätzen.
    static func page() throws -> (url: URL, words: [Double: [String]]) {
        let width = 2480, height = 3508
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 0.97, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var y = Double(height) - 250
        var words: [Double: [String]] = [:]
        for size in sizes {
            let px = size / 72 * 300
            let font = CTFontCreateWithName("Times New Roman" as CFString, px, nil)
            for sentence in sentences {
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: sentence, attributes: [.font: font, .foregroundColor: NSColor(white: 0.12, alpha: 1)]))
                ctx.textPosition = CGPoint(x: 220, y: y)
                CTLineDraw(line, ctx)
                y -= px * 1.6
                words[size, default: []] += sentence.split(separator: " ").map(String.init)
            }
            y -= px * 2
        }
        // Scanner-Look: leichte Unschärfe + Rauschen.
        let image = try #require(ctx.makeImage())
        let ci = CIImage(cgImage: image)
            .applyingGaussianBlur(sigma: 1.2)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.06, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.06, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.06, w: 0),
                "inputBiasVector": CIVector(x: -0.03, y: -0.03, z: -0.03, w: 0)])
            .cropped(to: ci.extent)
        let noisy = noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: ci])
        let rendered = try #require(CIContext().createCGImage(noisy, from: ci.extent))
        let page = try #require(PDFPage(image: NSImage(cgImage: rendered, size: NSSize(width: 595, height: 842))))
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-recall-\(UUID().uuidString).pdf")
        try #require(doc.write(to: url))
        return (url, words)
    }

    static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    @Test(.timeLimit(.minutes(5)))
    func kleineSchriftWirdErkannt() async throws {
        let (url, expected) = try Self.page()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        let output = try await OCREngine.run(sourceURL: url, languages: ["de-DE", "en-US"]) { _ in }
        let seconds = Date().timeIntervalSince(start)
        defer { try? FileManager.default.removeItem(at: output.outputURL) }
        let recognized = output.pages.flatMap(\.lines).flatMap {
            $0.text.split(separator: " ").map { Self.normalized(String($0)) }
        }
        var remaining = Dictionary(recognized.map { ($0, 1) }, uniquingKeysWith: +)
        var artifact: [String: Any] = ["seconds": (seconds * 10).rounded() / 10]
        var recall: [Double: Double] = [:]
        for size in Self.sizes {
            let words = expected[size]!.map(Self.normalized)
            var hits = 0
            for word in words where (remaining[word] ?? 0) > 0 {
                remaining[word]! -= 1
                hits += 1
            }
            recall[size] = Double(hits) / Double(words.count)
            artifact["recall_\(Int(size))pt"] = (recall[size]! * 1000).rounded() / 1000
        }
        let invented = remaining.values.reduce(0, +)
        artifact["invented_words"] = invented
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("benchmark/ocr-recall", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("result.json"))

        #expect((recall[14] ?? 0) >= 0.95, "14 pt: \(recall[14] ?? 0)")
        #expect((recall[11] ?? 0) >= 0.95, "11 pt: \(recall[11] ?? 0)")
        #expect((recall[9] ?? 0) >= 0.90, "9 pt: \(recall[9] ?? 0)")
        #expect((recall[7] ?? 0) >= 0.80, "7 pt: \(recall[7] ?? 0)")
        #expect(invented <= 6, "erfundene Wörter: \(invented)")
    }

    /// Vision verwarf auf diesem Handyfoto-Scan die gut lesbaren Zeilen 12
    /// und 20 – abhängig von minimalen Renderunterschieden. Der zweite
    /// Durchgang (skalierte Fassung) holt sie zurück. Fehlermöglichkeiten:
    /// Zeilen fehlen weiter, oder Zeilen erscheinen doppelt in der Textebene.
    @Test(.timeLimit(.minutes(3)), .needsLocalFiles("tmp/pdfs/core-235"))
    func verworfeneZeilenWerdenZurueckgeholt() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tmp/pdfs/core-235/09_Scans_PhoneCamera/phase1b_007.pdf")
        try #require(FileManager.default.fileExists(atPath: url.path), "Fehlt: \(url.path)")
        let output = try await OCREngine.run(sourceURL: url, languages: ["de-DE", "en-US"]) { _ in }
        defer { try? FileManager.default.removeItem(at: output.outputURL) }
        let numbers = output.pages.flatMap(\.lines).compactMap { line -> Int? in
            guard let match = line.text.range(of: #"Line \d\d"#, options: .regularExpression) else { return nil }
            return Int(line.text[match].dropFirst(5))
        }
        #expect(Set(numbers) == Set(1...22), "fehlend: \(Set(1...22).subtracting(numbers).sorted())")
        #expect(numbers.count == Set(numbers).count, "doppelt: \(numbers.sorted())")
    }

    /// Nutzerdatei (Desktop, 2026-10-01): Seite 4 – zwei Handyfotos von
    /// Beamer-Folien auf Karopapier. Visions genauer Modus lieferte für die
    /// GANZE Seite null Zeilen (bei 150–400 DPI), für die obere Hälfte allein
    /// elf korrekte. Fehlermöglichkeiten: Seite bleibt leer; Zeilen an der
    /// Schnittkante der Hälften erscheinen doppelt oder abgeschnitten.
    static let userFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tmp/pdfs/user/medium_kleinö.pdf")

    @Test(.timeLimit(.minutes(3)), .needsLocalFiles("tmp/pdfs/user/medium_kleinö.pdf"))
    func ganzseitigesVersagenWirdUeberHaelftenAufgefangen() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.userFile.path), "Fehlt: \(Self.userFile.path)")
        let output = try await OCREngine.run(sourceURL: Self.userFile,
                                             languages: ["de-DE", "en-US"]) { _ in }
        defer { try? FileManager.default.removeItem(at: output.outputURL) }
        let page4 = try #require(output.pages.first { $0.pageIndex == 3 })
        let text = page4.text
        #expect(page4.lines.count >= 20, "Seite 4: \(page4.lines.count) Zeilen")
        for phrase in ["Kündigungsverbot", "Grundgesetz", "Eigentumsgarantie"] {
            #expect(text.localizedCaseInsensitiveContains(phrase), "„\(phrase)“ fehlt")
        }
        // Wiederholungen sind auf den Folien echt („(1 Punkt)“, zweimal die
        // Überschrift) – doppelt heißt: gleicher Text an derselben Stelle.
        let placed = page4.lines.map { "\($0.text.lowercased())@\(Int($0.boundingBox.midY * 100))" }
        #expect(placed.count == Set(placed).count, "doppelte Zeilen auf Seite 4: \(placed)")
        for phrase in ["MuSchG", "BEEG", "Wirtschaftsverfassung"] {
            #expect(text.localizedCaseInsensitiveContains(phrase), "„\(phrase)“ fehlt")
        }
    }
}
