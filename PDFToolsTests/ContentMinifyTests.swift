import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Content-Stream-Minify (verlustfrei, Whitelist): Whitespace-Minimum,
/// wertexakte Zahlen-Normalisierung, leere `q Q`-Paare. Kommentare,
/// Strings und Inline-Images bleiben byteidentisch; Fehlformen und
/// Streams ohne Vorteil bleiben stehen.
@Suite struct ContentMinifyTests {

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("minify-\(label)-\(UUID().uuidString).pdf")
    }

    /// Seite mit aufgeblähtem Content: Trailing-Nullen, Mehrfach-Spaces,
    /// Leerzeilen, leeres `q Q`, Kommentar, Inline-Image, echter Text.
    static func bloatedPagePDF() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let tiny = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width 2/Height 2"
                + "/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/FlateDecode",
            data: ImageProcessor.flate(Data([0, 128, 192, 255]))!)
        let resources = b.addObject(
            "<</Font<</F1 \(font) 0 R>>/XObject<</Im0 \(tiny) 0 R>>>>")
        var content = Data()
        let prefix = [
            "% Kommentar mit  Sonderzeichen (bleibt)\n",
            "q\n",
            "  612.000000   0  0  792.000000  0  0  cm\n",
            "  /Im0  Do\n",
            "Q\n",
            "q   Q\n"
        ].joined()
        content.append(Data(prefix.utf8))
        // Volumen: Viele aufgeblähte Textzeilen, damit die Stream-Ersparnis
        // den fixen Writer-Overhead (xref/trailer) dominiert wie in echten
        // Dokumenten – bei 1-KB-Fixtures misst man sonst den Writer.
        for line in 1...80 {
            let y = String(format: "%.2f", 720.0 - Double(line) * 8.0)
            content.append(Data(
                "BT  /F1  12.000  Tf  072.50  \(y)  Td  (Zeile \(line) Hallo Welt)  Tj  ET\n".utf8))
        }
        content.append(Data("BI\n/W 1 /H 1 /CS /G /BPC 1\nID ".utf8))
        content.append(Data([0x80]))
        content.append(Data(" EI\n".utf8))
        let stream = b.addStream(dictionary: "", data: content)
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R"
            + "/Contents \(stream) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = Self.tempURL("fixture")
        try b.build(rootObject: root).write(to: url)
        return url
    }

    @Test(.hangGuard) func aufgeblaehterContentWirdKleiner() throws {
        let url = try Self.bloatedPagePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let beforeBytes = Int(Compressor.fileSize(of: url))

        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.minifyContentStreams()
        #expect(stats.streams >= 1, "Mindestens der Seiten-Content muss laufen")
        #expect(stats.savedBytes > 0, "Aufgeblähter Content muss schrumpfen")

        let out = Self.tempURL("minified")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        try PDFCoreDocument(path: out.path).check()
        #expect(Int(Compressor.fileSize(of: out)) < beforeBytes,
                "Minifizierte Datei muss kleiner sein")

        // Text bleibt extrahierbar und identisch …
        let beforeText = PDFDocument(url: url)?.string ?? ""
        let afterText = PDFDocument(url: out)?.string ?? ""
        #expect(beforeText.contains("Hallo Welt"))
        #expect(afterText == beforeText, "Kein Textzeichen darf sich ändern")

        // … und das Rendering ist pixelgleich.
        let render = try RenderDifferential.compare(sourceURL: url,
                                                    outputURL: out)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 },
                "Minify darf kein Pixel ändern")
    }

    @Test(.hangGuard) func zweiterLaufIstFixpunkt() throws {
        // Minify(Minify(x)) == Minify(x) – kein iteratives Schrumpfen.
        let url = try Self.bloatedPagePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let first = try doc.minifyContentStreams()
        #expect(first.streams >= 1)
        let second = try doc.minifyContentStreams()
        #expect(second.streams == 0 && second.savedBytes == 0,
                "Zweitlauf muss Fixpunkt sein: \(second)")
    }

    @Test(.hangGuard) func kommentarUndInlineImageBleibenVerbatim() throws {
        let url = try Self.bloatedPagePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        _ = try doc.minifyContentStreams()
        let out = Self.tempURL("verbatim")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)

        let core = try PDFCoreDocument(path: out.path)
        let content = String(decoding: try core.pageContentBytes(pageIndex: 0),
                             as: UTF8.self)
        #expect(content.contains("% Kommentar mit  Sonderzeichen (bleibt)"),
                "Kommentar inkl. Doppelspace muss bleiben")
        #expect(content.contains("Hallo Welt"), "String-Literal muss bleiben")
        #expect(content.contains("BI") && content.contains("EI"),
                "Inline-Image-Klammer muss bleiben")
    }

    // MARK: Fehlgeformte Tokens (echte Google-Slides-Datei)
    //
    // Der Fehler war: „1 0 0 1 1.05 0.00-62992127 cm“ wurde als ZWEI Zahlen
    // gelesen; der Block rutschte aus der Seite, das Text-Gate schlug in allen
    // Stufen an, und die Rückstufungsleiter kennt keinen Minify-Schritt. Der
    // Nutzer bekam einen Fehler statt einer Datei. So kann es scheitern:
    //   1. Der Tokenizer zerlegt das Token (Operanden ändern sich).
    //   2. Die Regel ist zu streng und wohlgeformter Content schrumpft nicht mehr.
    //   3. Die Kompression scheitert trotz stehendem Stream an anderer Stelle.

    /// Eine Seite mit Text hinter `transform`, aufgebläht, damit Minify ohne
    /// Fehlform einen Vorteil sähe (sonst bewiese „bleibt stehen“ nichts).
    static func pagePDF(transform: String) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let resources = b.addObject("<</Font<</F1 \(font) 0 R>>>>")
        var content = "BT  /F1  12.000  Tf  072.50  760.00  Td  (Kopfzeile bleibt)  Tj  ET\n"
        content += "q\n\(transform)\n"
        for line in 1...40 {
            let y = String(format: "%.2f", 720.0 - Double(line) * 12.0)
            content += "BT  /F1  12.000  Tf  072.50  \(y)  Td  (Zeile \(line) Inhalt)  Tj  ET\n"
        }
        content += "Q\n"
        let stream = b.addStream(dictionary: "", data: Data(content.utf8))
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R"
            + "/Contents \(stream) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = Self.tempURL("fehlform")
        try b.build(rootObject: root).write(to: url)
        return url
    }

    @Test(.hangGuard, arguments: [
        "1 0 0 1 1.0578477 0.00-62992127 cm",   // die echte Fehlform
        "1 0 0 1 0 1.2.3 cm",                   // zweiter Punkt
        "1 0 0 1 0 0+5 cm",                     // Plus mitten im Token
        "1 0 0 1 0 0cm",                        // Zahl klebt am Operator
        "1 0 0 1 0 0 cm-1 0 m",                 // Operator klebt an der Zahl
    ])
    func fehlgeformtesTokenLaesstDenStreamStehen(transform: String) throws {
        let url = try Self.pagePDF(transform: transform)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFCoreDocument(path: url.path).pageContentBytes(pageIndex: 0)

        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.minifyContentStreams()
        #expect(stats.streams == 0 && stats.savedBytes == 0,
                "Fehlform darf nicht minifiziert werden: \(transform)")
        let out = Self.tempURL("fehlform-out")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let after = try PDFCoreDocument(path: out.path).pageContentBytes(pageIndex: 0)
        #expect(after == before, "Stream muss byteidentisch bleiben: \(transform)")
    }

    @Test(.hangGuard) func wohlgeformteNachbarnSchrumpfenWeiter() throws {
        // Delimiter trennen selbst: Zahl an „(“ und „]“, Operator an „/“ und „[“.
        let url = try Self.pagePDF(
            transform: "1 0 0 1 0 0 cm BT/F1 12.00 Tf[(a)-20.0(b)]TJ ET")
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = try PDFCoreDocument(path: url.path).minifyContentStreams()
        #expect(stats.streams == 1 && stats.savedBytes > 0)
    }

    /// Ende-zu-Ende: In keiner Stufe darf die Fehlform die Kompression kippen.
    /// Der Text bleibt derselbe, und zwar seitenweise nach dem Maß des Gates.
    @Test(.hangGuard, arguments: [CompressionMode.small, .smart, .quality])
    func fehlformKomprimiertInJederStufe(mode: CompressionMode) throws {
        let url = try Self.pagePDF(transform: "1 0 0 1 1.0578477 0.00-62992127 cm")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try Compressor().compress(inputURL: url, mode: mode)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let source = try #require(PDFDocument(url: url)?.page(at: 0)?.string)
        let output = try #require(PDFDocument(url: result.outputURL)?.page(at: 0)?.string)
        #expect(source.contains("Zeile 40 Inhalt"), "Fixture: Text muss lesbar sein")
        #expect(PDFSemanticSnapshot.fingerprint(output)
                == PDFSemanticSnapshot.fingerprint(source))
    }
}
