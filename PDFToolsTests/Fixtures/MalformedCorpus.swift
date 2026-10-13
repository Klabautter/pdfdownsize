import Foundation
@testable import PDFTools

/// Masterplan Finding 19 / Schritt 10 – Malformed-Korpus.
///
/// Ziel ist NICHT, dass die App diese Dokumente verarbeitet. Ziel ist, dass
/// sie an ihnen weder abstürzt noch stillschweigend etwas Kaputtes ausliefert:
/// entweder ein sauberes Ergebnis oder ein klarer Fehler.
///
/// Jeder Fall wird aus einem gültigen Dokument erzeugt und gezielt beschädigt –
/// so ist der Unterschied zwischen „kaputt" und „gültig" exakt eine Ursache.
enum MalformedCorpus {

    struct Entry {
        let name: String
        /// Was an dem Dokument kaputt ist – landet im Manifest und in Reports.
        let defect: String
        let make: () throws -> Data
    }

    static var entries: [Entry] {
        [
            Entry(name: "truncated",
                  defect: "Datei nach der Hälfte abgeschnitten – Objekte fehlen") {
                let data = try validBase()
                return data.prefix(data.count / 2)
            },

            Entry(name: "broken-xref",
                  defect: "startxref zeigt auf eine ungültige Position") {
                var data = try validBase()
                if let range = data.range(of: Data("startxref".utf8),
                                          options: .backwards) {
                    let tail = data[range.upperBound...]
                    if let newline = tail.firstIndex(of: 0x0A) {
                        let numberRange = tail.index(after: newline)..<data.endIndex
                        data.replaceSubrange(numberRange,
                                             with: Data("999999999\n%%EOF\n".utf8))
                    }
                }
                return data
            },

            Entry(name: "bad-stream-length",
                  defect: "/Length eines Content-Streams ist viel zu groß") {
                var b = RawPDFBuilder()
                let pages = b.reserveNumber()
                let content = "BT /F1 12 Tf 72 720 Td (Kaputt) Tj ET"
                // /Length bewusst falsch – der Stream endet lange vorher.
                let stream = b.addObject(Data(
                    "<</Length 999999>>\nstream\n\(content)\nendstream".utf8))
                let font = b.addObject(
                    "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
                let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
                    + "/MediaBox[0 0 612 792]/Resources<</Font<</F1 \(font) 0 R>>>>"
                    + "/Contents \(stream) 0 R>>")
                b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
                let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
                return b.build(rootObject: root)
            },

            Entry(name: "missing-object",
                  defect: "Seite verweist auf ein Objekt, das es nicht gibt") {
                var b = RawPDFBuilder()
                let pages = b.reserveNumber()
                // 9999 wurde nie geschrieben.
                let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
                    + "/MediaBox[0 0 612 792]/Resources<<>>/Contents 9999 0 R>>")
                b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
                let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
                return b.build(rootObject: root)
            },

            Entry(name: "broken-page-tree",
                  defect: "/Count des Seitenbaums passt nicht zu /Kids") {
                var b = RawPDFBuilder()
                let pages = b.reserveNumber()
                let page = b.addObject(
                    "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
                    + "/Resources<<>>>>")
                // Behauptet 5 Seiten, liefert eine.
                b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 5>>")
                let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
                return b.build(rootObject: root)
            },

            Entry(name: "wrong-page-tree-type",
                  defect: "Seitenbaum-Knoten trägt /Type/XXXXX statt /Type/Pages") {
                var b = RawPDFBuilder()
                let pages = b.reserveNumber()
                let font = b.addObject(
                    "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
                let content = b.addStream(
                    dictionary: "",
                    content: "BT /F1 12 Tf 72 700 Td (Seite) Tj ET")
                let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
                    + "/MediaBox[0 0 612 792]"
                    + "/Resources<</Font<</F1 \(font) 0 R>>>>"
                    + "/Contents \(content) 0 R>>")
                // Der Knoten behauptet, etwas anderes zu sein. qpdf baut den
                // Baum trotzdem aus /Kids wieder auf – ein anderer Betrachter
                // muss das nicht.
                b.fill(pages, "<</Type/XXXXX/Kids[\(page) 0 R]/Count 1>>")
                let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
                return b.build(rootObject: root)
            },

            Entry(name: "page-tree-cycle",
                  defect: "Seitenbaum verweist im Kreis auf sich selbst") {
                var b = RawPDFBuilder()
                let pages = b.reserveNumber()
                let inner = b.reserveNumber()
                b.fill(inner, "<</Type/Pages/Parent \(pages) 0 R"
                    + "/Kids[\(pages) 0 R]/Count 1>>")
                b.fill(pages, "<</Type/Pages/Kids[\(inner) 0 R]/Count 1>>")
                let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
                return b.build(rootObject: root)
            },

            Entry(name: "invalid-destination",
                  defect: "Link zeigt auf eine Named Destination, die es nicht gibt") {
                var b = RawPDFBuilder()
                let pages = b.reserveNumber()
                let page = b.reserveNumber()
                let link = b.addObject("<</Type/Annot/Subtype/Link"
                    + "/Rect[72 700 300 720]/Border[0 0 0]"
                    + "/A<</S/GoTo/D(gibtesnicht)>>>>")
                b.fill(page, "<</Type/Page/Parent \(pages) 0 R"
                    + "/MediaBox[0 0 612 792]/Resources<<>>/Annots[\(link) 0 R]>>")
                b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
                let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
                return b.build(rootObject: root)
            },

            Entry(name: "damaged-trailer",
                  defect: "Trailer ohne /Root – der Katalog ist nicht auffindbar") {
                var data = try validBase()
                if let range = data.range(of: Data("/Root".utf8), options: .backwards) {
                    data.replaceSubrange(range, with: Data("/Xoot".utf8))
                }
                return data
            },

            Entry(name: "invalid-rotation",
                  defect: "/Rotate 137 ist kein Vielfaches von 90") {
                var b = RawPDFBuilder()
                let pages = b.reserveNumber()
                let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
                    + "/MediaBox[0 0 612 792]/Resources<<>>/Rotate 137>>")
                b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
                let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
                return b.build(rootObject: root)
            },

            Entry(name: "negative-mediabox",
                  defect: "MediaBox mit negativer Ausdehnung") {
                var b = RawPDFBuilder()
                let pages = b.reserveNumber()
                let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
                    + "/MediaBox[500 500 100 100]/Resources<<>>>>")
                b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
                let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
                return b.build(rootObject: root)
            },

            Entry(name: "image-dimension-mismatch",
                  defect: "Bildstream ist viel kürzer als Width × Height erwarten lässt") {
                var b = RawPDFBuilder()
                let pages = b.reserveNumber()
                // Behauptet 800×800 RGB (1,9 MB), liefert 30 Byte.
                let image = b.addStream(
                    dictionary: "/Type/XObject/Subtype/Image/Width 800/Height 800"
                        + "/BitsPerComponent 8/ColorSpace/DeviceRGB",
                    data: Data(repeating: 0x7F, count: 30))
                let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
                let content = b.addStream(dictionary: "",
                                          content: "q 612 0 0 792 0 0 cm /Im0 Do Q")
                let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
                    + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R"
                    + "/Contents \(content) 0 R>>")
                b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
                let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
                return b.build(rootObject: root)
            },

            Entry(name: "not-a-pdf",
                  defect: "Kein PDF – nur Zufallsbytes mit passender Endung") {
                var data = Data("%PDF-1.7\n".utf8)
                var seed: UInt64 = 0x2545F4914F6CDD1D
                for _ in 0..<4096 {
                    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                    data.append(UInt8(truncatingIfNeeded: seed))
                }
                return data
            }
        ]
    }

    /// Gültiges Ausgangsdokument, das gezielt beschädigt wird.
    private static func validBase() throws -> Data {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        var kids: [Int] = []
        for index in 0..<3 {
            let content = b.addStream(
                dictionary: "",
                content: "BT /F1 12 Tf 72 720 Td (Seite \(index + 1)) Tj ET")
            kids.append(b.addObject("<</Type/Page/Parent \(pages) 0 R"
                + "/MediaBox[0 0 612 792]/Resources<</Font<</F1 \(font) 0 R>>>>"
                + "/Contents \(content) 0 R>>"))
        }
        b.fill(pages, "<</Type/Pages/Kids["
            + kids.map { "\($0) 0 R" }.joined(separator: " ")
            + "]/Count \(kids.count)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return b.build(rootObject: root)
    }

    /// Schreibt den Malformed-Korpus nach `<root>/Malformed/` inklusive
    /// Manifest mit der jeweiligen Defektbeschreibung.
    @discardableResult
    static func generate(into root: URL) throws -> URL {
        let fm = FileManager.default
        let destination = root.appendingPathComponent("Malformed", isDirectory: true)
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var manifest: [String: String] = [:]
        for entry in entries {
            let data = try entry.make()
            try data.write(to: destination.appendingPathComponent("\(entry.name).pdf"))
            manifest["\(entry.name).pdf"] = entry.defect
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest)
            .write(to: destination.appendingPathComponent("manifest.json"))
        return destination
    }
}
