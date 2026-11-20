import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan E5: Unsichtbare Textebene für jede Schrift.
///
/// Befund: Die Textebene nutzte Helvetica mit CP1252 – alles jenseits
/// Westeuropas wurde „?“ (Kyrillisch, Griechisch, CJK, Polnisch „ł“).
/// Die Suche nach dem erkannten Wort fand nichts.
///
/// Fehlermöglichkeiten: (1) Zeichen werden ersetzt; (2) die Breitenanpassung
/// stimmt nicht mehr (Markierung zu kurz/zu lang); (3) jede Seite trägt eine
/// eigene Kopie der Schrift (Größe wächst mit der Seitenzahl).
@Suite struct OCRScriptCoverageTests {

    static let samples = ["Привет мир", "Ελληνικά γράμματα", "Łódź Gdańsk żółć", "漢字かな交じり文", "Grüße – € 100"]

    static func layered(pages: Int) throws -> URL {
        let doc = PDFDocument()
        for _ in 0..<pages { doc.insert(PDFPage(), at: doc.pageCount) }
        let blank = FileManager.default.temporaryDirectory.appendingPathComponent("e5-blank-\(UUID().uuidString).pdf")
        #expect(doc.write(to: blank))
        defer { try? FileManager.default.removeItem(at: blank) }
        let core = try PDFCoreDocument(path: blank.path)
        let reference = try #require(PDFDocument(url: blank)?.page(at: 0))
        for index in 0..<pages {
            let lines = samples.enumerated().map { k, text in
                OCREngine.Line(text: text,
                               boundingBox: CGRect(x: 0.1, y: 0.8 - Double(k) * 0.1, width: 0.6, height: 0.03),
                               confidence: 1)
            }
            try core.appendOCRLayer(pageIndex: index, content: OCREngine.textLayer(lines: lines, page: reference))
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("e5-ocr-\(UUID().uuidString).pdf")
        try core.save(to: out)
        return out
    }

    @Test func jedeSchriftBleibtSuchbar() throws {
        let out = try Self.layered(pages: 1)
        defer { try? FileManager.default.removeItem(at: out) }
        let doc = try #require(PDFDocument(url: out))
        let text = doc.page(at: 0)?.string ?? ""
        for sample in Self.samples {
            #expect(text.contains(sample), "„\(sample)“ fehlt in der Textebene: \(text)")
            #expect(!doc.findString(sample, withOptions: []).isEmpty, "Suche findet „\(sample)“ nicht")
        }
    }

    @Test func markierungFuelltDieErkannteZeile() throws {
        let out = try Self.layered(pages: 1)
        defer { try? FileManager.default.removeItem(at: out) }
        let doc = try #require(PDFDocument(url: out))
        let page = try #require(doc.page(at: 0))
        let width = page.bounds(for: .mediaBox).width
        for sample in Self.samples {
            let selection = try #require(doc.findString(sample, withOptions: []).first)
            let box = selection.bounds(for: page)
            #expect(abs(box.width - width * 0.6) < width * 0.06,
                    "„\(sample)“: Markierung \(box.width) statt \(width * 0.6)")
        }
    }

    @Test func schriftWirdNurEinmalAbgelegt() throws {
        let one = try Self.layered(pages: 1)
        let ten = try Self.layered(pages: 10)
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: ten) }
        let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
        // Neun weitere Seiten: Textebene je ~0,5 KB, keine neue Schrift je Seite.
        #expect(size(ten) - size(one) < 9 * 2_500, "Zuwachs \(size(ten) - size(one)) Byte für 9 Seiten")
    }

    /// N14 (E5): Ein Zeichen außerhalb der BMP wird EIN Code (U+FFFD) statt
    /// zweier einzelner Ersatzhälften; alles andere bleibt Code = Zeichen.
    @Test func zeichenAusserhalbDerBMPSindGueltigKodiert() {
        let text = "a\u{1F600}𠀀b"
        #expect(OCREngine.codes(text) == [0x61, 0xFFFD, 0xFFFD, 0x62])
        #expect(OCREngine.pdfString(text) == "<0061FFFDFFFD0062>")
        #expect(!OCREngine.codes("Grüße 日本").contains { (0xD800...0xDFFF).contains($0) })
    }

    /// N14 (E5): Die OCR-Schrift ist eingebettet (FontFile2), das Programm
    /// ist ein gültiges TrueType (CoreGraphics lädt es), und die Datei wächst
    /// dadurch nur wenig.
    @Test func schriftprogrammIstEingebettetUndGueltig() throws {
        let out = try Self.layered(pages: 1)
        defer { try? FileManager.default.removeItem(at: out) }
        // Objektnummern aus der Originaldatei (qdf nummeriert um).
        let json = try SingleSourceAssemblyE2ETests.qpdf(["--json=1", "--json-key=objects", out.path])
        let match = try #require(json.firstMatch(of: /"\/FontFile2": "(\d+) 0 R"/), "Schrift nicht eingebettet")
        let dump = FileManager.default.temporaryDirectory.appendingPathComponent("e5-font-\(UUID().uuidString).ttf")
        defer { try? FileManager.default.removeItem(at: dump) }
        let process = Process()
        process.executableURL = Compressor.bundledQPDFURL()
        process.arguments = ["--show-object=\(match.1)", "--filtered-stream-data", out.path]
        FileManager.default.createFile(atPath: dump.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dump)
        process.standardOutput = handle
        try process.run()
        process.waitUntilExit()
        try handle.close()
        let data = try Data(contentsOf: dump)
        #expect(data.count > 100)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let font = try #require(CGFont(provider), "Eingebettetes Programm ist kein gültiges TrueType")
        #expect(font.numberOfGlyphs == 2)
        #expect(font.unitsPerEm == 1000)
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        #expect(size < 30_000, "Datei \(size) Byte – Schrift oder CIDToGIDMap unkomprimiert?")
    }
}
