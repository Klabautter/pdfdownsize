import Testing
import Foundation
import CoreGraphics
import Compression
@testable import PDFTools

/// Masterplan D1–D4 (18.11.2026): Robustheit im PDF-Kern. Alle Punkte
/// stammten aus Code-Lektüre; jede Fixture hier löst den Fehler an 1.0.9 aus.
///
/// Fehlermöglichkeiten je Punkt:
///  D1  Strukturprüfung rekursiert über eine lange Verweiskette und sprengt
///      den Stack eines Arbeits-Threads (512 KB).
///  D2  Ressourcen-Bereinigung entfernt Benutztes: /DefaultRGB nennt kein
///      Operator; `/Im#20A` im Content heißt im Wörterbuch „Im A“; ein
///      Inline-Bild ohne erkennbares EI lässt den Rest ungelesen.
///  D3  Deduplizierung legt zwei gleichnamige Ebenen zu einer zusammen.
///  D4  Ein winziger Flate-Strom entpackt sich zu Gigabytes.
@Suite(.serialized) struct CoreRobustnessTests {

    // MARK: Hilfen

    static func write(_ builder: RawPDFBuilder, root: Int, _ name: String) throws -> URL {
        try builder.write(rootObject: root, prefix: name)
    }

    /// Seite bei 72 DPI als Graustufen-Bytes (für Vorher/Nachher-Vergleiche).
    static func render(_ url: URL, page: Int = 1) -> [UInt8]? {
        guard let doc = CGPDFDocument(url as CFURL), let p = doc.page(at: page) else { return nil }
        let box = p.getBoxRect(.mediaBox)
        let w = Int(box.width), h = Int(box.height)
        var buffer = [UInt8](repeating: 255, count: w * h)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.drawPDFPage(p)
            return true
        }
        return ok ? buffer : nil
    }

    static func darkPixels(_ pixels: [UInt8]) -> Int { pixels.filter { $0 < 128 }.count }

    /// Läuft `body` auf einem Thread mit `stack` Bytes Stack (wie ein Arbeits-Thread).
    static func onSmallStack(_ stack: Int, _ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let thread = Thread { body(); done.resume() }
            thread.stackSize = stack
            thread.start()
        }
    }

    /// Dokument als QDF-Text (unkomprimiert, über den gebündelten qpdf-Helfer).
    static func qdf(_ url: URL) throws -> String {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("qdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let process = Process()
        process.executableURL = Compressor.bundledQPDFURL()
        process.arguments = ["--qdf", "--object-streams=disable", url.path, out.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return String(decoding: try Data(contentsOf: out), as: UTF8.self)
    }

    // MARK: D1

    @Test func tiefeVerweisketteSprengtDenStackNicht() async throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let depth = 100_000
        // Annotationen, die über /Next eine Kette bilden (Aktionsfolge).
        var next = b.addObject("<</S/JavaScript/JS(1)>>")
        for _ in 1..<depth { next = b.addObject("<</S/JavaScript/JS(1)/Next \(next) 0 R>>") }
        let annot = b.addObject("<</Type/Annot/Subtype/Link/Rect[0 0 10 10]/A \(next) 0 R>>")
        let page = b.addPage(parent: pages, extra: "/Annots[\(annot) 0 R]")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = try Self.write(b, root: root, "d1-chain")
        defer { try? FileManager.default.removeItem(at: url) }

        final class Box: @unchecked Sendable { var error: Error?; var done = false }
        let box = Box()
        await Self.onSmallStack(512 << 10) {
            do { try PDFCoreDocument(path: url.path).check() } catch { box.error = error }
            box.done = true
        }
        #expect(box.done, "Strukturprüfung kam nicht zurück")
    }

    // MARK: D2

    /// /DefaultRGB nennt kein Operator; die Bereinigung darf es nicht entfernen.
    @Test func defaultFarbraumBleibtErhalten() throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let content = b.addStream(dictionary: "", content: "0 0 1 rg 10 10 100 100 re f")
        let page = b.addPage(parent: pages,
                             resources: "<</ColorSpace<</DefaultRGB[/CalRGB<</WhitePoint[0.9505 1 1.089]>>]/Unused[/CalGray<</WhitePoint[0.9505 1 1.089]>>]>>>>",
                             contents: content)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = try Self.write(b, root: root, "d2-defaultrgb")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try PDFCoreDocument(path: url.path)
        _ = try doc.removeUnusedResources()
        let out = PDFFixtures.fixtureURL(prefix: "d2-defaultrgb-out")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let text = try Self.qdf(out)
        #expect(!text.contains("/Unused"), "Bereinigung lief nicht – Test prüft nichts")
        #expect(text.contains("/DefaultRGB"), "DefaultRGB wurde entfernt")
    }

    /// Ein XObject mit Leerzeichen im Namen (`/Im#20A` im Content).
    @Test func kodierterNameZaehltAlsBenutzt() throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let form = b.addStream(dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 100 100]",
                               content: "0 g 0 0 100 100 re f")
        let content = b.addStream(dictionary: "", content: "q 1 0 0 1 50 50 cm /Im#20A Do Q")
        let page = b.addPage(parent: pages,
                             resources: "<</XObject<</Im#20A \(form) 0 R>>>>",
                             contents: content)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = try Self.write(b, root: root, "d2-hexname")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try #require(Self.render(url))

        let doc = try PDFCoreDocument(path: url.path)
        _ = try doc.removeUnusedResources()
        let out = PDFFixtures.fixtureURL(prefix: "d2-hexname-out")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let after = try #require(Self.render(out))
        #expect(Self.darkPixels(before) > 5000)
        #expect(Self.darkPixels(after) == Self.darkPixels(before), "Die Form verschwand")
    }

    /// Inline-Bild, dessen Ende der Scanner nicht als plausibel erkennt: Die
    /// EI-Prüfung verlangt 24 druckbare ASCII-Bytes danach; ein Kommentar
    /// mit Umlaut direkt hinter `EI` reicht. Der alte Scanner kam nicht
    /// hinter das Bild und entfernte die Form, die danach gezeichnet wird.
    @Test func ungelesenerRestSchuetztRessourcen() throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let form = b.addStream(dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 100 100]",
                               content: "0 g 0 0 100 100 re f")
        var bytes = Data("q 10 0 0 10 0 0 cm BI /W 2 /H 2 /BPC 8 /CS /G ID ".utf8)
        bytes.append(Data([0x10, 0x80, 0xC0, 0xFF]))
        bytes.append(Data(" EI Q %".utf8))
        bytes.append(Data([0xC4]))
        bytes.append(Data("rger\nq 1 0 0 1 200 200 cm /Fm1 Do Q".utf8))
        let content = b.addStream(dictionary: "", data: bytes)
        let page = b.addPage(parent: pages,
                             resources: "<</XObject<</Fm1 \(form) 0 R>>>>",
                             contents: content)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = try Self.write(b, root: root, "d2-inline")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try #require(Self.render(url))

        let doc = try PDFCoreDocument(path: url.path)
        _ = try doc.removeUnusedResources()
        let out = PDFFixtures.fixtureURL(prefix: "d2-inline-out")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let after = try #require(Self.render(out))
        #expect(Self.darkPixels(before) > 5000, "Fixture zeichnet die Form nicht")
        #expect(Self.darkPixels(after) == Self.darkPixels(before),
                "Form hinter dem Inline-Bild wurde entfernt")
    }

    // MARK: D3

    @Test func gleichnamigeEbenenBleibenGetrennt() throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let ocgA = b.addObject("<</Type/OCG/Name(Ebene)>>")
        let ocgB = b.addObject("<</Type/OCG/Name(Ebene)>>")
        let content = b.addStream(dictionary: "",
            content: "/OC /A BDC 0 g 0 0 50 50 re f EMC /OC /B BDC 0 g 60 0 50 50 re f EMC")
        let page = b.addPage(parent: pages,
                             resources: "<</Properties<</A \(ocgA) 0 R/B \(ocgB) 0 R>>>>",
                             contents: content)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R/OCProperties<</OCGs[\(ocgA) 0 R \(ocgB) 0 R]/D<</OFF[\(ocgB) 0 R]>>>>>>")
        let url = try Self.write(b, root: root, "d3-ocg")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try PDFCoreDocument(path: url.path)
        _ = try doc.deduplicate()
        let out = PDFFixtures.fixtureURL(prefix: "d3-ocg-out")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let text = try Self.qdf(out)
        // Zwei verschiedene Objektverweise in /OCGs.
        let ocgs = try #require(text.firstMatch(of: /\/OCGs\s*\[\s*(\d+) 0 R\s+(\d+) 0 R/))
        #expect(ocgs.1 != ocgs.2, "Zwei Ebenen wurden ein Objekt")
    }

    // MARK: D4

    /// 2 GB Nullen, mit zlib auf rund 2 MB gepackt, als 100×100-Bild deklariert.
    @Test(.timeLimit(.minutes(2))) func dekompressionsbombeWirdBegrenzt() throws {
        let chunk = Data(count: 64 << 20)
        var inflated = 0
        var compressed = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { compressed.append($0 ?? Data()) }
        while inflated < (2 << 30) {
            try filter.write(chunk)
            inflated += chunk.count
        }
        try filter.finalize()
        // OutputFilter liefert rohes DEFLATE; /FlateDecode braucht den zlib-Rahmen.
        var zlib = Data([0x78, 0x9C]); zlib.append(compressed)
        zlib.append(Data([0, 0, 0, 1]))   // Prüfsumme bewusst falsch – gelesen wird vorher schon zu viel

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(dictionary: "/Type/XObject/Subtype/Image/Width 100/Height 100/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/FlateDecode",
                                data: zlib)
        let content = b.addStream(dictionary: "", content: "q 100 0 0 100 0 0 cm /Im0 Do Q")
        let page = b.addPage(parent: pages, resources: "<</XObject<</Im0 \(image) 0 R>>>>", contents: content)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = try Self.write(b, root: root, "d4-bomb")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try PDFCoreDocument(path: url.path)
        let resources = try doc.imageResources()
        let id = try #require(resources.first?.objectID)
        let before = CorpusRunnerCore.ResourceUsage.footprintMB
        let data = doc.imageStreamData(objectID: id, decoded: true)
        let grown = CorpusRunnerCore.ResourceUsage.footprintMB - before
        #expect(data == nil || data!.count <= 100 * 100 * 3 + (1 << 20),
                "Dekodiert: \(data?.count ?? 0) Bytes")
        #expect(grown < 512, "Speicher wuchs um \(grown) MB")
    }
}

/// Masterplan D6 – die übrigen Lesebefunde, je mit Fixture belegt.
///
/// Fehlermöglichkeiten: (1) zwei Teilströme verschmelzen zu einem Token
/// („Qq“); (2) eine Schrift, die nur ein Kontrollkästchen-Zustand benutzt,
/// wird subsettet; (3) ein Bildexport rastert eine Posterseite zu Hunderten
/// Megapixeln.
@Suite(.serialized) struct CoreRobustnessD6Tests {

    @Test func teilstroemeBleibenGetrennt() throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let s1 = b.addStream(dictionary: "", content: "q 0 g 0 0 10 10 re f Q")
        let s2 = b.addStream(dictionary: "", content: "q 0 g 20 20 10 10 re f Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 100 100]"
                               + "/Contents[\(s1) 0 R \(s2) 0 R]>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = try b.write(rootObject: root, prefix: "d6-streams")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try PDFCoreDocument(path: url.path).pageContentBytes(pageIndex: 0)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("Qq"), "Teilströme verschmolzen: \(text)")
        #expect(text.contains("Q\nq"))
    }

    @Test func schriftEinesKontrollkaestchenZustandsBleibtGanz() throws {
        guard let fontData = PDFFixtures.systemTrueTypeFontBytes else { return }
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let fontFile = b.addStream(dictionary: "/Length1 \(fontData.count)", data: fontData)
        let descriptor = b.addObject("<</Type/FontDescriptor/FontName/ABCDEF+FixtureFont/Flags 32"
            + "/FontBBox[0 0 1000 1000]/ItalicAngle 0/Ascent 800/Descent -200/CapHeight 700"
            + "/StemV 80/FontFile2 \(fontFile) 0 R>>")
        let widths = Array(repeating: "700", count: 26).joined(separator: " ")
        let font = b.addObject("<</Type/Font/Subtype/TrueType/BaseFont/ABCDEF+FixtureFont"
            + "/FirstChar 65/LastChar 90/Widths[\(widths)]/Encoding/WinAnsiEncoding"
            + "/FontDescriptor \(descriptor) 0 R>>")
        // Nur der Zustand /On benutzt die Schrift (Zeichen „X“).
        let on = b.addStream(dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 20 20]"
                             + "/Resources<</Font<</F1 \(font) 0 R>>>>",
                             content: "BT /F1 12 Tf 4 4 Td (X) Tj ET")
        let off = b.addStream(dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 20 20]", content: "")
        let widget = b.addObject("<</Type/Annot/Subtype/Widget/FT/Btn/T(Box)/Rect[50 50 70 70]"
                                 + "/AS/Off/AP<</N<</On \(on) 0 R/Off \(off) 0 R>>>>>>")
        let content = b.addStream(dictionary: "", content: "")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 200 200]"
                               + "/Contents \(content) 0 R/Annots[\(widget) 0 R]>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R/AcroForm<</Fields[\(widget) 0 R]>>>>")
        let url = try b.write(rootObject: root, prefix: "d6-checkbox")
        defer { try? FileManager.default.removeItem(at: url) }

        let candidates = try PDFCoreDocument(path: url.path).fontSubsetCandidates()
        let entry = try #require(candidates.first { $0.objectID.objectNumber == font })
        #expect(entry.reason.rawValue == 2, "Schrift der Zustands-Appearance wäre subsettet worden: \(entry.reason)")
    }

    @Test func posterseiteWirdNichtGerastert() async throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let content = b.addStream(dictionary: "", content: "0 g 0 0 100 100 re f")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 6000 6000]"
                               + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = try b.write(rootObject: root, prefix: "d6-poster")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = SourceDocument(url: url, pageCount: 1)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("d6-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: MergeError.self) {
            _ = try await PageImageExporter.export(pages: [PageItem(source: source, pageIndex: 0)],
                                                   options: .init(format: .png, dpi: 300),
                                                   to: folder, progress: { _ in })
        }
    }
}
