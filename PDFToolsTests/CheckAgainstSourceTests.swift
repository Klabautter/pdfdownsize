import Testing
import Foundation
@testable import PDFTools

/// Masterplan C2 Schritt 5: Unveränderte Streams nicht dekodieren.
///
/// Die Strukturprüfung der Ausgabe dekodierte jeden Stream – auch die, die
/// der Lauf gar nicht angefasst hat (statab: Hunderte Content-Streams).
/// Gegen die Quelle geprüft gelten gleiche Rohbytes als so gültig wie dort.
///
/// Fehlermöglichkeiten: (1) ein beschädigter Stream rutscht durch, weil er
/// fälschlich als „unverändert“ gilt; (2) ein Stream, der schon in der Quelle
/// so war, lässt die Ausgabe scheitern – die Ausgabe hat nichts verschlechtert.
@Suite struct CheckAgainstSourceTests {

    /// Eine Seite, Content-Stream Flate-kodiert; `garbage` ersetzt die
    /// Flate-Bytes durch Müll (nicht dekodierbar).
    static func document(garbage: Bool, extraPages: Int = 0) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        var ids: [Int] = []
        for n in 0...extraPages {
            let text = Data("BT /F1 24 Tf 72 700 Td (Seite \(n)) Tj ET".utf8)
            let bytes = n == 0 && garbage ? Data(repeating: 0x5A, count: 40) : try text.zlibCompressedForTest()
            let content = b.addStream(dictionary: "/Filter/FlateDecode", data: bytes)
            ids.append(b.addPage(parent: pages, resources: "<</Font<</F1 \(font) 0 R>>>>", contents: content))
        }
        b.fill(pages, "<</Type/Pages/Kids[\(ids.map { "\($0) 0 R" }.joined(separator: " "))]/Count \(ids.count)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "c2-check")
    }

    @Test func beschaedigterVeraenderterStreamFaelltWeiterAuf() throws {
        let source = try Self.document(garbage: false)
        let output = try Self.document(garbage: true)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let core = try PDFCoreDocument(path: output.path)
        #expect(throws: PDFCoreError.self) { try core.check(againstSource: source) }
        #expect(throws: PDFCoreError.self) { try core.check() }
    }

    @Test func schonInDerQuelleSoGewesenIstKeinFehlerDerAusgabe() throws {
        let source = try Self.document(garbage: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let core = try PDFCoreDocument(path: source.path)
        #expect(throws: PDFCoreError.self) { try core.check() }
        try core.check(againstSource: source)
    }

    @Test func unlesbareQuelleHeisstVollePruefung() throws {
        let output = try Self.document(garbage: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("fehlt-\(UUID().uuidString).pdf")
        #expect(throws: PDFCoreError.self) { try PDFCoreDocument(path: output.path).check(againstSource: missing) }
    }
}
