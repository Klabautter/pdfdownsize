import Foundation
import AppKit
import PDFKit
@testable import PDFTools

/// Synthetische PDF-Fixtures (Epic Phase 6) – reproduzierbar erzeugbar,
/// keine urheberrechtlich belasteten Inhalte.
enum PDFFixtures {

    // MARK: Seiten-Bausteine

    static func textPage(_ text: String, size: CGSize = CGSize(width: 612, height: 792)) -> PDFPage {
        let rep = bitmapRep(size: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        ("Fixture\n" + text).draw(
            in: NSRect(x: 40, y: size.height - 200, width: size.width - 80, height: 300),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph,
            ])
        NSGraphicsContext.restoreGraphicsState()
        return PDFPage(image: NSImage(cgImage: rep.cgImage!, size: size))!
    }

    static func solidColorPage(_ color: NSColor, size: CGSize = CGSize(width: 612, height: 792),
                               pixelsPerPoint: CGFloat = 2) -> PDFPage {
        let rep = bitmapRep(size: CGSize(width: size.width * pixelsPerPoint,
                                         height: size.height * pixelsPerPoint))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return PDFPage(image: NSImage(cgImage: rep.cgImage!, size: size))!
    }

    /// Seite mit Transparenz (halbtransparentes Rechteck über Farbe).
    static func transparentPage(size: CGSize = CGSize(width: 400, height: 300)) -> PDFPage {
        let rep = bitmapRep(size: CGSize(width: 800, height: 600))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.red.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: NSRect(x: 50, y: 50, width: size.width - 100, height: size.height - 100)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return PDFPage(image: NSImage(cgImage: rep.cgImage!, size: size))!
    }

    private static func bitmapRep(size: CGSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: max(1, Int(size.width)),
                                   pixelsHigh: max(1, Int(size.height)),
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        return rep
    }

    static func document(pages: [PDFPage]) -> PDFDocument {
        let doc = PDFDocument()
        for (i, page) in pages.enumerated() {
            doc.insert(page, at: i)
        }
        return doc
    }

    /// Echte Textseite als Page (für Fixtures mit expectsText = true).
    static func vectorTextPage(lines: Int = 8) -> PDFPage {
        guard let url = try? vectorTextPDF(lines: lines, name: "vpage-\(UUID().uuidString)"),
              let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            return textPage("Fallback")
        }
        // PDFKit-Pages haben kein removeFromParent – Kopie verwenden,
        // dann ist sie quelldokument-unabhängig einsetzbar.
        return page.copy() as! PDFPage
    }

    // MARK: Dokumente

    /// GENAU EIN Ort für alle Fixture-Dateien.
    ///
    /// Masterplan §9 verlangt „Temp ownership klar". Vorher schrieben zwei
    /// Pfade an zwei Stellen, und die Aufräumpflicht lag bei jedem einzelnen
    /// Aufrufer – über 180 Aufrufe hinweg ging das schief und hinterließ
    /// hunderte Dateien im Temp-Verzeichnis. Jetzt gibt es ein Verzeichnis
    /// mit einem Besitzer, das sich selbst aufräumt.
    static var workingDirectory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        pruneStaleFixturesOnce(in: dir)
        return dir
    }

    private static let pruneToken = NSObject()
    nonisolated(unsafe) private static var didPrune = false

    /// Entfernt Fixtures älterer Läufe – einmal pro Prozess.
    ///
    /// Die Altersgrenze schützt parallel laufende Prozesse: Was gerade erst
    /// entstanden ist, gehört möglicherweise einem anderen Lauf.
    private static func pruneStaleFixturesOnce(in dir: URL) {
        objc_sync_enter(pruneToken)
        defer { objc_sync_exit(pruneToken) }
        guard !didPrune else { return }
        didPrune = true

        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: []) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: entry) }
        }
    }

    /// Eindeutiger Dateiname im Fixture-Verzeichnis.
    static func fixtureURL(prefix: String) -> URL {
        workingDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString).pdf")
    }

    @discardableResult
    static func write(_ doc: PDFDocument, name: String) throws -> URL {
        let url = fixtureURL(prefix: name)
        guard doc.write(to: url) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// Ein Bild mit eigenem `/Metadata`-Stream.
    ///
    /// XMP-Metadaten hängen regelmässig an Bildobjekten. Sie beim Ersetzen
    /// zu KOPIEREN wirft in qpdf („stream objects cannot be cloned") – jedes
    /// solche Bild liess sich dadurch gar nicht komprimieren. Der Fehler lag
    /// lange unentdeckt, weil kein Korpusdokument ihn traf.
    static func imageWithMetadataPDF(pixelWidth: Int = 1600,
                                     name: String = "image-metadata") throws -> URL {
        let height = pixelWidth * 3 / 4
        // Bewusst schlecht komprimierbar: Ein glatter Verlauf schrumpft
        // unter Flate so stark, dass Verkleinern nichts mehr brächte – der
        // Planner meldete dann „kein Größenvorteil", und der Test bewiese
        // nichts über die Ersetzung.
        var samples = [UInt8](repeating: 0, count: pixelWidth * height)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<samples.count {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            samples[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
        guard let flate = ImageProcessor.flate(Data(samples)) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let xmp = """
            <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF             xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">            <rdf:Description rdf:about=""/></rdf:RDF></x:xmpmeta>
            <?xpacket end="w"?>
            """
        let meta = b.addStream(dictionary: "/Type/Metadata/Subtype/XML",
                               content: xmp)
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixelWidth)"
                + "/Height \(height)/ColorSpace/DeviceGray/BitsPerComponent 8"
                + "/Filter/FlateDecode/Metadata \(meta) 0 R",
            data: flate)
        let content = b.addStream(dictionary: "",
                                  content: "q 512 0 0 384 50 300 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</XObject<</Im0 \(image) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Ein hochaufgelöstes Bild mit ICC-Profil.
    ///
    /// So kommen Kamerafotos und Scans: Das Bild verweist auf ein
    /// eingebettetes Farbprofil statt auf einen Geräte-Farbraum. Sie waren
    /// ausgeschlossen, weil sich aus dem Profilnamen allein die
    /// Komponentenzahl nicht ablesen liess – 11,5 MB im Korpus.
    static func iccProfilePDF(pixelWidth: Int = 1800,
                              name: String = "icc") throws -> URL {
        let height = pixelWidth * 3 / 4
        let rep = bitmapRep(size: CGSize(width: pixelWidth, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for x in stride(from: 0, to: pixelWidth, by: 5) {
            NSColor(calibratedHue: CGFloat(x) / CGFloat(pixelWidth),
                    saturation: 0.75, brightness: 0.9, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: x, y: 0, width: 5, height: height)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage,
              let raw = ImageResampler.rawBitmap(cg, components: 3),
              let flate = ImageProcessor.flate(raw),
              let profile = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData()
                as Data? else {
            throw CocoaError(.fileWriteUnknown)
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let profileObj = b.addStream(dictionary: "/N 3", data: profile)
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixelWidth)"
                + "/Height \(height)/ColorSpace[/ICCBased \(profileObj) 0 R]"
                + "/BitsPerComponent 8/Filter/FlateDecode",
            data: flate)
        let content = b.addStream(dictionary: "",
                                  content: "q 512 0 0 384 50 300 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</XObject<</Im0 \(image) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Ein hochaufgelöstes CMYK-Bild – Druckmaterial.
    ///
    /// CMYK-Bilder waren von der Kompression ausgeschlossen: 42,4 MB im
    /// Korpus. Sie nach RGB umzurechnen wäre bei Druckdaten eine
    /// Farbveränderung; verkleinert man sie im eigenen Farbraum, bleibt
    /// jede Farbe, wie sie war.
    static func cmykPhotoPDF(pixelWidth: Int = 2000,
                             name: String = "cmyk") throws -> URL {
        let height = pixelWidth * 3 / 4
        // Vier Kanäle direkt erzeugen – kein Umweg über RGB.
        var samples = [UInt8](repeating: 0, count: pixelWidth * height * 4)
        for y in 0..<height {
            for x in 0..<pixelWidth {
                let i = (y * pixelWidth + x) * 4
                samples[i]     = UInt8(255 * x / max(pixelWidth - 1, 1))   // C
                samples[i + 1] = UInt8(255 * y / max(height - 1, 1))       // M
                samples[i + 2] = UInt8((x + y) % 256)                      // Y
                samples[i + 3] = UInt8((x / 8) % 60)                       // K
            }
        }
        guard let flate = ImageProcessor.flate(Data(samples)) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixelWidth)"
                + "/Height \(height)/ColorSpace/DeviceCMYK"
                + "/BitsPerComponent 8/Filter/FlateDecode",
            data: flate)
        let content = b.addStream(dictionary: "",
                                  content: "q 512 0 0 384 50 300 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</XObject<</Im0 \(image) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Ein Bild mit umkehrendem `/Decode`-Array.
    ///
    /// `[1 0 1 0 1 0]` kehrt die Farbwerte um: Was als helles Bild
    /// gespeichert ist, erscheint dunkel. Wer das Array beim Neukodieren
    /// ignoriert, liefert ein invertiertes Bild aus – deshalb war dieser
    /// Fall gesperrt. Über den Korpus gemessen betrifft er 38 300 Bilder
    /// mit zusammen 55,7 MB.
    static func decodeArrayPDF(pixelWidth: Int = 1600,
                               name: String = "decode-array") throws -> URL {
        let height = pixelWidth * 3 / 4
        let rep = bitmapRep(size: CGSize(width: pixelWidth, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for x in stride(from: 0, to: pixelWidth, by: 8) {
            let v = CGFloat(x) / CGFloat(pixelWidth)
            NSColor(calibratedRed: v, green: 1 - v, blue: 0.4, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: x, y: 0, width: 8, height: height)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage,
              let raw = ImageResampler.rawBitmap(cg, grayscale: false),
              let flate = ImageProcessor.flate(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixelWidth)"
                + "/Height \(height)/ColorSpace/DeviceRGB/BitsPerComponent 8"
                + "/Filter/FlateDecode/Decode[1 0 1 0 1 0]",
            data: flate)
        let content = b.addStream(dictionary: "",
                                  content: "q 512 0 0 384 50 300 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</XObject<</Im0 \(image) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Ein Bild mit FARBSCHLÜSSEL-Maskierung (`/Mask` als Array).
    ///
    /// Die Werte benennen einen Farbbereich im Farbraum des Bildes, der
    /// durchsichtig dargestellt wird. Eine verlustbehaftete Neukodierung
    /// verschiebt genau diese Werte – deshalb bleibt dieser Fall
    /// ausgeschlossen.
    static func colorKeyMaskedPDF(name: String = "colorkey") throws -> URL {
        let side = 400
        let rep = bitmapRep(size: CGSize(width: side, height: side))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: NSRect(x: 50, y: 50, width: 300, height: 300)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage,
              let png = NSBitmapImageRep(cgImage: cg)
                .representation(using: .png, properties: [:]),
              let src = CGImageSourceCreateWithData(png as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let raw = ImageResampler.rawBitmap(decoded, grayscale: false),
              let flate = ImageProcessor.flate(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        // /Mask als Array: Weiss (255,255,255) wird durchsichtig.
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(side)/Height \(side)"
                + "/ColorSpace/DeviceRGB/BitsPerComponent 8"
                + "/Filter/FlateDecode/Mask[250 255 250 255 250 255]",
            data: flate)
        let content = b.addStream(dictionary: "",
                                  content: "q 300 0 0 300 100 300 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</XObject<</Im0 \(image) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Ein hochaufgelöstes Foto mit weicher Maske – freigestellt.
    ///
    /// So sehen Logos, Diagramme und freigestellte Produktfotos aus: ein
    /// Farbbild plus ein Graustufenbild als `/SMask`, das die Deckkraft je
    /// Bildpunkt angibt. Über den Korpus gemessen ist das mit 143,5 MB der
    /// grösste Posten, den die Kompression nicht angefasst hat.
    ///
    /// Die Maske ist bewusst KLEINER als das Bild: Nach PDF 32000-1
    /// §8.9.6.4 muss sie das nicht sein, sie wird skaliert. Genau darauf
    /// beruht, dass wir das Bild neu kodieren dürfen, ohne die Maske
    /// anzufassen.
    static func softMaskedPhotoPDF(pixelWidth: Int = 2400,
                                   name: String = "soft-masked") throws -> URL {
        let height = pixelWidth * 3 / 4
        // Farbbild
        let rep = bitmapRep(size: CGSize(width: pixelWidth, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for x in stride(from: 0, to: pixelWidth, by: 6) {
            NSColor(calibratedHue: CGFloat(x) / CGFloat(pixelWidth),
                    saturation: 0.7, brightness: 0.85, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: x, y: 0, width: 6, height: height)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage,
              let jpeg = NSBitmapImageRep(cgImage: cg)
                .representation(using: .jpeg,
                                properties: [.compressionFactor: 0.9]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        // Maske: halb so gross, weicher Verlauf von durchsichtig nach deckend.
        let mw = pixelWidth / 2, mh = height / 2
        var maskBytes = [UInt8](repeating: 0, count: mw * mh)
        for y in 0..<mh {
            for x in 0..<mw {
                maskBytes[y * mw + x] = UInt8(255 * x / max(mw - 1, 1))
            }
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let mask = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(mw)/Height \(mh)"
                + "/ColorSpace/DeviceGray/BitsPerComponent 8",
            data: Data(maskBytes))
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixelWidth)"
                + "/Height \(height)/ColorSpace/DeviceRGB"
                + "/BitsPerComponent 8/Filter/DCTDecode/SMask \(mask) 0 R",
            data: jpeg)
        let content = b.addStream(dictionary: "",
                                  content: "q 512 0 0 384 50 300 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</XObject<</Im0 \(image) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Dasselbe Bild mehrfach gespeichert – als eigene Objekte.
    ///
    /// So sehen echte Dokumente aus, die ein Logo oder einen Hintergrund auf
    /// jeder Seite tragen: Statt eines Objekts mit mehreren Verweisen liegt
    /// dieselbe Bytefolge mehrfach im Dokument. Über den Korpus gemessen sind
    /// das 30 MB, also 8 % aller Bilddaten.
    ///
    /// - Parameter copies: Wie oft dasselbe Bild abgelegt wird.
    static func duplicateImagePDF(copies: Int = 4,
                                  name: String = "duplicates") throws -> URL {
        let side = 700
        let rep = bitmapRep(size: CGSize(width: side, height: side))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for i in stride(from: 0, to: side, by: 10) {
            NSColor(calibratedHue: CGFloat(i) / CGFloat(side),
                    saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: i, y: 0, width: 10, height: side)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage,
              let jpeg = NSBitmapImageRep(cgImage: cg)
                .representation(using: .jpeg,
                                properties: [.compressionFactor: 0.9]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var pageObjects: [Int] = []
        for index in 0..<copies {
            // BEWUSST je Seite ein eigenes Objekt mit denselben Bytes.
            let image = b.addStream(
                dictionary: "/Type/XObject/Subtype/Image/Width \(side)"
                    + "/Height \(side)/ColorSpace/DeviceRGB"
                    + "/BitsPerComponent 8/Filter/DCTDecode",
                data: jpeg)
            let content = b.addStream(
                dictionary: "",
                content: "q 400 0 0 400 100 200 cm /Im0 Do Q")
            pageObjects.append(b.addObject(
                "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
                + "/Resources<</XObject<</Im0 \(image) 0 R>>>>"
                + "/Contents \(content) 0 R>>"))
            _ = index
        }
        let kids = pageObjects.map { "\($0) 0 R" }.joined(separator: " ")
        b.fill(pages, "<</Type/Pages/Kids[\(kids)]/Count \(pageObjects.count)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Phase 23c – Bilder in einem Form-XObject (Page → Form → /Image).
    ///
    /// Genau das Muster, an dem der reine Seiten-Scan scheitert: Die zwei
    /// DCT-Bilder hängen NUR in den Resources der Form, ihr cm/Do steht im
    /// Form-Content. Ein direktes Seiten-Bild dient als Kontrolle. Die Form
    /// wird auf Seite 2 halb so groß WIEDER VERWENDET – über mehrere
    /// Platzierungen entscheidet weiterhin die größte.
    static func nestedFormImagesPDF(name: String = "nested-form-images") throws -> URL {
        func jpeg(_ pixels: Int) throws -> Data {
            let height = pixels * 3 / 4
            let rep = bitmapRep(size: CGSize(width: pixels, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            for y in stride(from: 0, to: height, by: 4) {
                for x in stride(from: 0, to: pixels, by: 4) {
                    NSColor(calibratedRed: CGFloat(x % 255) / 255.0,
                            green: CGFloat(y % 255) / 255.0,
                            blue: CGFloat((x + y) % 255) / 255.0,
                            alpha: 1).setFill()
                    NSBezierPath(rect: NSRect(x: x, y: y, width: 4, height: 4)).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = rep.cgImage,
                  let data = NSBitmapImageRep(cgImage: cg)
                    .representation(using: .jpeg,
                                    properties: [.compressionFactor: 0.9]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let imageA = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width 1600/Height 1200"
                + "/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode",
            data: try jpeg(1600))
        let imageB = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width 1200/Height 900"
                + "/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode",
            data: try jpeg(1200))
        let control = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width 600/Height 450"
                + "/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode",
            data: try jpeg(600))
        // Form-Content: die cm/Do-Platzierungen, die der Seiten-Scan nie
        // sieht – 480 pt bzw. 360 pt Breite (je 240 dpi).
        let form = b.addStream(
            dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 612 792]"
                + "/Resources<</XObject<</Im10 \(imageA) 0 R/Im11 \(imageB) 0 R>>>>",
            content: "q 480 0 0 360 50 100 cm /Im10 Do Q "
                + "q 360 0 0 270 60 60 cm /Im11 Do Q")
        let content0 = b.addStream(dictionary: "",
            content: "q /Fm0 Do Q q 300 0 0 225 100 500 cm /Im0 Do Q")
        let page0 = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</XObject<</Fm0 \(form) 0 R/Im0 \(control) 0 R>>>>"
            + "/Contents \(content0) 0 R>>")
        let content1 = b.addStream(dictionary: "",
            content: "q 0.5 0 0 0.5 60 60 cm /Fm0 Do Q")
        let page1 = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</XObject<</Fm0 \(form) 0 R>>>>"
            + "/Contents \(content1) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page0) 0 R \(page1) 0 R]/Count 2>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    /// Phase 23c – Form-ZYKLUS (A → B → A) mit einem Bild in B. Der Walk
    /// muss den Zykel abschneiden, ohne das Bild zu verlieren; qpdf meldet
    /// an einem solchen Zykel keine Warnung (verifiziert).
    static func cyclicFormImagesPDF(name: String = "cyclic-form-images") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var raw = Data(count: 64 * 64)
        for i in 0..<raw.count { raw[i] = UInt8(i % 251) }
        guard let flate = ImageProcessor.flate(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width 64/Height 64"
                + "/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/FlateDecode",
            data: flate)
        let contentA = "q /FmA Do Q"
        let contentB = "q /FmB Do Q q 120 0 0 60 5 5 cm /Im0 Do Q"
        let formA = b.reserveNumber()
        let formB = b.addStream(
            dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 200 100]"
                + "/Resources<</XObject<</FmB \(formA) 0 R/Im0 \(image) 0 R>>>>",
            content: contentB)
        // Reservierte Nummer nachträglich: Body wie bei addStream.
        b.fill(formA,
               "<</Type/XObject/Subtype/Form/BBox[0 0 200 100]"
               + "/Resources<</XObject<</FmA \(formB) 0 R>>>>"
               + "/Length \(contentA.utf8.count)>>\nstream\n\(contentA)\nendstream")
        let content = b.addStream(dictionary: "",
                                  content: "q /Fm0 Do Q")
        let page = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</XObject<</Fm0 \(formA) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }
    ///
    /// Das Bild ist bewusst klein (64 px), damit die Bildpolitik es behält
    /// (zu klein zum Transformieren) und der Dedup-Pass die Arbeit zeigt.
    static func dedupStreamsPDF(pages: Int = 2,
                                name: String = "dedup-streams") throws -> URL {
        let side = 64
        let rep = bitmapRep(size: CGSize(width: side, height: side))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for i in stride(from: 0, to: side, by: 8) {
            NSColor(calibratedHue: CGFloat(i) / CGFloat(side),
                    saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: i, y: 0, width: 8, height: side)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage,
              let jpeg = NSBitmapImageRep(cgImage: cg)
                .representation(using: .jpeg,
                                properties: [.compressionFactor: 0.9]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var b = RawPDFBuilder()
        let pagesNode = b.reserveNumber()
        var pageObjects: [Int] = []
        for index in 0..<max(1, pages) {
            // BEWUSST je Seite eigene Objekte mit identischen Bytes.
            let font = b.addObject(
                "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
            let image = b.addStream(
                dictionary: "/Type/XObject/Subtype/Image/Width \(side)"
                    + "/Height \(side)/ColorSpace/DeviceRGB"
                    + "/BitsPerComponent 8/Filter/DCTDecode",
                data: jpeg)
            // Der Content-Stream ist absichtlich AUF JEDER SEITE GLEICH –
            // identische Content-Streams sind Teil des Dedup-Szenarios.
            let content = b.addStream(
                dictionary: "",
                content: "BT /F1 12 Tf 72 700 Td (Dedup) Tj ET"
                    + " q 400 0 0 400 100 200 cm /Im0 Do Q")
            pageObjects.append(b.addObject(
                "<</Type/Page/Parent \(pagesNode) 0 R/MediaBox[0 0 612 792]"
                + "/Resources<</Font<</F1 \(font) 0 R>>"
                + "/XObject<</Im0 \(image) 0 R>>>>"
                + "/Contents \(content) 0 R>>"))
            _ = index
        }
        let kids = pageObjects.map { "\($0) 0 R" }.joined(separator: " ")
        b.fill(pagesNode, "<</Type/Pages/Kids[\(kids)]/Count \(pageObjects.count)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pagesNode) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Phase 3b – Zwei JBIG2-Bilder mit IDENTISCHEM Seitenstrom, aber
    /// VERSCHIEDENEN /JBIG2Globals-Strömen (aus den Bilevel-Fixtures
    /// abgeleitet). Globals sind kontextabhängig – der Dedup-Pass darf
    /// solche Streams nie zusammenführen, sonst rendert das zweite Bild
    /// mit fremdem Symbolwörterbuch.
    static func jbig2GlobalsPDF(pixels: Int = 480, rows: Int = 640,
                                name: String = "jbig2-globals") throws -> URL {
        guard
            let bufferA = BilevelBuffer(
                width: pixels, height: rows,
                data: bilevelPattern(width: pixels, height: rows, seed: 11)),
            let encodedA = BilevelCodec.encodeJBIG2(bufferA),
            let bufferB = BilevelBuffer(
                width: pixels, height: rows,
                data: bilevelPattern(width: pixels, height: rows, seed: 22)),
            let encodedB = BilevelCodec.encodeJBIG2(bufferB),
            !encodedA.globals.isEmpty, !encodedB.globals.isEmpty,
            encodedA.globals != encodedB.globals else {
            throw CocoaError(.fileWriteUnknown)
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let globalsA = b.addStream(dictionary: "", data: encodedA.globals)
        let globalsB = b.addStream(dictionary: "", data: encodedB.globals)
        func imageDict(globals: Int) -> String {
            "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(rows)/BitsPerComponent 1/ColorSpace/DeviceGray"
                + "/Filter/JBIG2Decode"
                + "/DecodeParms<</JBIG2Globals \(globals) 0 R>>"
        }
        // Derselbe Seitenstrom für beide Bilder – nur die Globals unterscheiden
        // sich. Genau der Fall, in dem ein naiver Byte-Hash korruptiert.
        let imageA = b.addStream(dictionary: imageDict(globals: globalsA),
                                 data: encodedA.page)
        let imageB = b.addStream(dictionary: imageDict(globals: globalsB),
                                 data: encodedA.page)
        let contentA = b.addStream(dictionary: "",
                                   content: "q 300 0 0 400 100 200 cm /Im0 Do Q")
        let contentB = b.addStream(dictionary: "",
                                   content: "q 250 0 0 333 150 250 cm /Im0 Do Q")
        let pageA = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</XObject<</Im0 \(imageA) 0 R>>>>"
            + "/Contents \(contentA) 0 R>>")
        let pageB = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</XObject<</Im0 \(imageB) 0 R>>>>"
            + "/Contents \(contentB) 0 R>>")
        let kids = "\(pageA) 0 R \(pageB) 0 R"
        b.fill(pages, "<</Type/Pages/Kids[\(kids)]/Count 2>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Phase 5a – /ToUnicode-CMap für die Font-Fixtures: bildet die Codes
    /// 65..68 auf "TEST" ab, damit die Textextraktion unabhängig davon ist,
    /// was die Renderer aus dem (bewusst synthetischen) Fontprogramm machen.
    static let fontCMap = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CMapName /DedupFont def
        /CMapType 2 def
        1 begincodespacerange
        <00> <FF>
        endcodespacerange
        4 beginbfchar
        <41> <0054>
        <42> <0045>
        <43> <0053>
        <44> <0054>
        endbfchar
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """

    /// Deterministisches Pseudo-Fontprogramm (512 Bytes). Niemand validiert
    /// die Glyphen – Renderer substituieren, aber JEDES Dokument, das diese
    /// Bytes trägt, tut dasselbe; Renderdiff und Extraktion bleiben damit
    /// vergleichbar. Der Hash der Bytes ist die Basis des Font-Dedup.
    static let fontProgramBytes: Data = {
        var bytes = [UInt8](repeating: 0, count: 512)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<bytes.count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
        return Data(bytes)
    }()

    /// Phase 5a – N Seiten, je ein EIGENES Font-Dict mit identischem
    /// Fontprogramm (/FontFile2), eigener /ToUnicode mit identischen Bytes
    /// und gleicher semantischer Form (BaseFont, Subtype, Encoding, Widths,
    /// Descriptor). Genau das Muster, das der Font-Dedup zusammenführen soll.
    ///
    /// `widthsVary` gibt Seite 1 (0-basiert) andere /Widths – der Gegenfall:
    /// gleiche Bytes, aber semantisch verschieden → kein Merge (Test 5).
    static func dedupFontsPDF(pages: Int = 2,
                              widthsVary: Bool = false,
                              name: String = "dedup-fonts") throws -> URL {
        var b = RawPDFBuilder()
        let pagesNode = b.reserveNumber()
        var pageObjects: [Int] = []
        for index in 0..<max(1, pages) {
            // BEWUSST je Seite eigene Objekte: ToUnicode und FontFile tragen
            // identische BYTES, liegen aber auf verschiedenen Objektnummern –
            // der Document-Dedup (kanonische Form) fasst sie nicht zusammen,
            // der Font-Dedup (semantische Form) schon.
            let toUnicode = b.addStream(dictionary: "", content: fontCMap)
            let fontFile = b.addStream(
                dictionary: "/Length1 \(fontProgramBytes.count)",
                data: fontProgramBytes)
            let descriptor = b.addObject(
                "<</Type/FontDescriptor/FontName/ABCDEF+DedupFont/Flags 4"
                + "/FontBBox[0 0 1000 1000]/ItalicAngle 0/Ascent 800"
                + "/Descent -200/CapHeight 700/StemV 80"
                + "/FontFile2 \(fontFile) 0 R>>")
            let widths = widthsVary && index % 2 == 1
                ? "[600 600 600 600]" : "[500 500 500 500]"
            let font = b.addObject(
                "<</Type/Font/Subtype/TrueType/BaseFont/ABCDEF+DedupFont"
                + "/FirstChar 65/LastChar 68/Widths\(widths)"
                + "/Encoding/WinAnsiEncoding"
                + "/FontDescriptor \(descriptor) 0 R"
                + "/ToUnicode \(toUnicode) 0 R>>")
            let content = b.addStream(
                dictionary: "",
                content: "BT /F1 24 Tf 72 700 Td (TEST) Tj ET")
            pageObjects.append(b.addObject(
                "<</Type/Page/Parent \(pagesNode) 0 R/MediaBox[0 0 612 792]"
                + "/Resources<</Font<</F1 \(font) 0 R>>>>"
                + "/Contents \(content) 0 R>>"))
        }
        let kids = pageObjects.map { "\($0) 0 R" }.joined(separator: " ")
        b.fill(pagesNode, "<</Type/Pages/Kids[\(kids)]/Count \(pageObjects.count)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pagesNode) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Phase 5a – Seite mit EINEM genutzten Font (/F1, per Tf benutzt) und
    /// EINEM unbenutzten eingebetteten Font (/F2, kein Tf) im selben
    /// Resources-Dict. Die GC muss /F2 tragen, /F1 behalten.
    static func unusedFontPDF(name: String = "unused-font") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()

        let toUnicode = b.addStream(dictionary: "", content: fontCMap)
        let fontFile = b.addStream(
            dictionary: "/Length1 \(fontProgramBytes.count)",
            data: fontProgramBytes)
        let descriptor = b.addObject(
            "<</Type/FontDescriptor/FontName/ABCDEF+UnusedFont/Flags 4"
            + "/FontBBox[0 0 1000 1000]/ItalicAngle 0/Ascent 800"
            + "/Descent -200/CapHeight 700/StemV 80"
            + "/FontFile2 \(fontFile) 0 R>>")
        let unused = b.addObject(
            "<</Type/Font/Subtype/TrueType/BaseFont/ABCDEF+UnusedFont"
            + "/FirstChar 65/LastChar 68/Widths[500 500 500 500]"
            + "/Encoding/WinAnsiEncoding"
            + "/FontDescriptor \(descriptor) 0 R"
            + "/ToUnicode \(toUnicode) 0 R>>")
        let used = b.addObject(
            "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let content = b.addStream(
            dictionary: "",
            content: "BT /F1 24 Tf 72 700 Td (TEST) Tj ET")
        let page = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</Font<</F1 \(used) 0 R/F2 \(unused) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// V2-5 (§11.7, statab_2012) – Tf-Nutzung über die /Contents-ARRAY-
    /// Grenze: Stream 1 endet mit dem NAMEN („/F1 "), Stream 2 beginnt mit
    /// der ZAHL und dem Operator („12 Tf …"). Im zusammengesetzten Content
    /// ist das eine gültige, VOLLWERTIGE Font-Nutzung – der Tf-Scanner
    /// (Unused-Font-GC und Subsetting) darf den Eintrag deshalb nicht
    /// beräumen. Genau dieses Muster drehte in statab_2012 Seite 12 die
    /// Textextraktion.
    static func splitTfContentsPDF(name: String = "split-tf-contents") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()

        let font = b.addObject(
            "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        // Der SPLIT: der Name steht am ENDE von Stream 1 (Name plus
        // Leerzeichen, ohne operatorisches Ende), Zahl + Tf am ANFANG von
        // Stream 2.
        let content1 = b.addStream(
            dictionary: "",
            content: "BT 72 700 Td /F1 ")
        let content2 = b.addStream(
            dictionary: "",
            content: "12 Tf (TEST) Tj ET")
        let page = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</Font<</F1 \(font) 0 R>>>>"
            + "/Contents[\(content1) 0 R \(content2) 0 R]>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    // MARK: - V2-8 (Masterplan §14) – Fixtures für den Born-Digital-
    // Resource-Optimizer: selektives Font-Subsetting, ICC-Dedup,
    // Resource-GC und Form-Dedup-Status.

    /// Zweiter, VERSCHIEDENER TrueType-Systemfont – das Zwei-Font-Fixture
    /// braucht Programme, die der Font-Dedup nicht verschmelzen darf.
    static let secondaryTrueTypeFontBytes: Data? = {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Verdana.ttf",
            "/System/Library/Fonts/Supplemental/Tahoma.ttf",
            "/System/Library/Fonts/Supplemental/Georgia.ttf",
        ]
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  data.count > 16, data != systemTrueTypeFontBytes else {
                continue
            }
            let version = (UInt32(data[data.startIndex]) << 24)
                | (UInt32(data[data.startIndex + 1]) << 16)
                | (UInt32(data[data.startIndex + 2]) << 8)
                | UInt32(data[data.startIndex + 3])
            if version == 0x0001_0000 || version == 0x7472_7565 { return data }
        }
        return nil
    }()

    /// Kleines 8×8-RGB-Bild als Flate-Stream (Resource-GC-/ICC-Fixtures).
    static func tinyFlateImage(seed: UInt8 = 7) throws -> (data: Data, dict: String) {
        var pixels = Data()
        for y in 0..<8 {
            for x in 0..<8 {
                let xByte = UInt8(truncatingIfNeeded: x * 31)
                let yByte = UInt8(truncatingIfNeeded: y * 17)
                pixels.append(xByte &+ seed)
                pixels.append(yByte &+ seed)
                pixels.append(seed)
            }
        }
        guard let flate = ImageProcessor.flate(pixels) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dict = "/Type/XObject/Subtype/Image/Width 8/Height 8"
            + "/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/FlateDecode"
        return (flate, dict)
    }

    /// V2-8 (§14.1/§14.4) – Zwei Seiten mit VERSCHIEDENEN echten TrueType-
    /// Systemfonts (Subsetting-Kandidaten, die der Font-Dedup nicht mergt).
    /// `withUnusedResources` hängt Seite 1 zusätzlich unbenutzte Resource-
    /// Einträge an (XObject/ExtGState/Shading) – das E2E-Szenario
    /// „font-lastig + ungenutzte Ressourcen“. nil ohne Systemfonts.
    static func twoSubsetFontsPDF(withUnusedResources: Bool = false,
                                  name: String = "two-subset-fonts")
        throws -> URL? {
        guard let fontA = systemTrueTypeFontBytes,
              let fontB = secondaryTrueTypeFontBytes else { return nil }
        let codes: [UInt32] = [65, 66, 67]

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var pageNumbers: [Int] = []
        for (index, fontData) in [fontA, fontB].enumerated() {
            let fontFile = b.addStream(dictionary: "/Length1 \(fontData.count)",
                                       data: fontData)
            let descriptor = b.addObject(
                "<</Type/FontDescriptor/FontName/ABCDEF+FixtureFont\(index)"
                + "/Flags 32/FontBBox[0 0 1000 1000]/ItalicAngle 0"
                + "/Ascent 800/Descent -200/CapHeight 700/StemV 80"
                + "/FontFile2 \(fontFile) 0 R>>")
            let widths = Array(repeating: "700", count: 26)
                .joined(separator: " ")
            let toUnicode = b.addStream(
                dictionary: "", content: fixtureCMap(codes: codes))
            let font = b.addObject(
                "<</Type/Font/Subtype/TrueType/BaseFont/ABCDEF+FixtureFont"
                + "\(index)/FirstChar 65/LastChar 90/Widths[\(widths)]"
                + "/Encoding/WinAnsiEncoding"
                + "/FontDescriptor \(descriptor) 0 R"
                + "/ToUnicode \(toUnicode) 0 R>>")
            let content = b.addStream(
                dictionary: "",
                content: "BT /F\(index + 1) 24 Tf 72 700 Td (ABC) Tj ET")
            var resources = "<</Font<</F\(index + 1) \(font) 0 R>>>>"
            if index == 0 && withUnusedResources {
                let unusedImage = try tinyFlateImage(seed: 91)
                let im1 = b.addStream(dictionary: unusedImage.dict,
                                      data: unusedImage.data)
                resources = "<</Font<</F\(index + 1) \(font) 0 R>>"
                    + "/XObject<</ImUnused \(im1) 0 R>>"
                    + "/ExtGState<</GSUnused<</Type/ExtGState/CA 0/ca 0>>>>"
                    + "/Shading<</SHUnused<</ShadingType 2/ColorSpace"
                    + "/DeviceRGB/Coords[0 0 100 0]/Function"
                    + "<</FunctionType 2/Domain[0 1]/C0[0 0 0]/C1[1 1 1]"
                    + "/N 1>>>>>>>>"
            }
            pageNumbers.append(b.addObject(
                "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
                + "/Resources\(resources)"
                + "/Contents \(content) 0 R>>"))
        }
        let kids = pageNumbers.map { "\($0) 0 R" }.joined(separator: " ")
        b.fill(pages, "<</Type/Pages/Kids[\(kids)]/Count 2>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// V2-8 (§14.5) – Zwei Bilder mit JEDEM eigenen /ICCBased-Farbraum.
    /// `identicalBytes`: gleiches Profil (sonst um ein Byte verschoben);
    /// `secondN`/`secondAlternate`: Varianten des /N-/Range-/Alternate-
    /// Vertrags. Alles über den RawPDFBuilder, damit die Objektidentität
    /// der Profile kontrolliert bleibt.
    static func duplicateICCProfilesPDF(identicalBytes: Bool = true,
                                        secondN: Int? = nil,
                                        secondAlternate: String? = nil,
                                        name: String = "icc-dedup") throws -> URL {
        guard let profile = CGColorSpace(name: CGColorSpace.sRGB)?
            .copyICCData() as Data? else {
            throw CocoaError(.fileWriteUnknown)
        }
        let imageA = try tinyFlateImage(seed: 3)
        let imageB = try tinyFlateImage(seed: 4)

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let profileA = b.addStream(dictionary: "/N 3/Alternate/DeviceRGB",
                                   data: profile)
        var dictB = secondN.map { "/N \($0)" } ?? "/N 3"
        dictB += "/Alternate \(secondAlternate ?? "/DeviceRGB")"
        let profileBytes = identicalBytes ? profile : profile + Data([0xFF])
        let profileB = b.addStream(dictionary: dictB, data: profileBytes)
        let im0 = b.addStream(
            dictionary: imageA.dict
                + "/ColorSpace[/ICCBased \(profileA) 0 R]",
            data: imageA.data)
        let im1 = b.addStream(
            dictionary: imageB.dict
                + "/ColorSpace[/ICCBased \(profileB) 0 R]",
            data: imageB.data)
        let content = b.addStream(
            dictionary: "",
            content: "q 100 0 0 100 40 500 cm /Im0 Do Q "
                + "q 100 0 0 100 300 500 cm /Im1 Do Q")
        let page = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</XObject<</Im0 \(im0) 0 R/Im1 \(im1) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// V2-8 (§14.6) – Resource-GC-Fixture: EINE Seite mit benutzten und
    /// unbenutzten Einträgen je Kategorie.
    ///   benutzt:   /Im0 (Do), /GS0 (gs), /CS0 (cs), /P0 (scn)
    ///   unbenutzt: /Im1, /GS1, /SH0, /CS1, /MC0 (Properties)
    /// `structTree`: Katalog mit /StructTreeRoot → Properties geschützt.
    /// `brokenContent`: Content mit nicht dekodierbarem Filter → die ganze
    /// Map ist geschützt (Whitelist-Muster der Font-GC).
    /// `acroFormDR`: /AcroForm/DR trägt ein XObject, das kein Seitencontent
    /// je zeichnet – die Default-Ressourcen bleiben grundsätzlich stehen.
    static func unusedResourcesPDF(structTree: Bool = false,
                                   brokenContent: Bool = false,
                                   acroFormDR: Bool = false,
                                   name: String = "unused-resources")
        throws -> URL {
        let usedImage = try tinyFlateImage(seed: 11)
        let unusedImage = try tinyFlateImage(seed: 22)

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let im0 = b.addStream(dictionary: usedImage.dict, data: usedImage.data)
        let im1 = b.addStream(dictionary: unusedImage.dict,
                              data: unusedImage.data)
        // Unbenutzter indirekter Farbraum (CalRGB-Array-Form).
        let colorSpaceUnused = b.addObject(
            "[/CalRGB << /WhitePoint [0.9505 1 1.089] /Gamma [2.2 2.2 2.2] >>]")

        let contentBody = brokenContent
            ? ""   // Stream unten mit fremdem Filter
            : "q /GS0 gs 72 500 200 100 re S Q "
                + "/CS0 cs /P0 scn 72 300 200 200 re f "
                + "q 150 0 0 150 72 100 cm /Im0 Do Q"
        let content = brokenContent
            ? b.addStream(dictionary: "/Filter/UnknownV2Filter", data: Data([0x01, 0x02]))
            : b.addStream(dictionary: "", content: contentBody)

        // Tiling-Pattern als Stream – addStream rechnet /Length.
        let pattern = b.addStream(
            dictionary: "/PatternType 1/PaintType 1/TilingType 1"
                + "/BBox[0 0 10 10]/XStep 10/YStep 10/Resources<<>>",
            content: "0.5 g 0 0 10 10 re f")

        let page = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<<"
            + "/XObject<</Im0 \(im0) 0 R/Im1 \(im1) 0 R>>"
            + "/ExtGState<</GS0<</Type/ExtGState/CA 1/ca 1>>"
            + "/GS1<</Type/ExtGState/LW 2>>>>"
            + "/ColorSpace<</CS0[/Pattern/DeviceRGB]/CS1 \(colorSpaceUnused) 0 R>>"
            + "/Pattern<</P0 \(pattern) 0 R>>"
            + "/Shading<</SH0<</ShadingType 2/ColorSpace/DeviceRGB"
            + "/Coords[0 0 100 0]/Function<</FunctionType 2/Domain[0 1]"
            + "/C0[0 0 0]/C1[1 1 1]/N 1>>>>>>"
            + "/Properties<</MC0<</Type/OCPG/Subtype/Foreground>>>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        var rootDict = "<</Type/Catalog/Pages \(pages) 0 R"
        if acroFormDR {
            let drImage = try tinyFlateImage(seed: 33)
            let imDR = b.addStream(dictionary: drImage.dict, data: drImage.data)
            rootDict += "/AcroForm<</DR<</XObject<</ImDR \(imDR) 0 R>>>>>>"
        }
        rootDict += structTree
            ? "/StructTreeRoot<</Type/StructTreeRoot>>"
                + "/MarkInfo<</Marked true>>>>"
            : ">>"
        let root = b.addObject(rootDict)
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// V2-8 (§14.7) – Zwei SEITEN mit je EINEM Form-XObject. Ohne
    /// `/matrix`: identischer Content-Hash + identische (leere) /Resources
    /// → der bestehende Dedup-Pass merger die Formen. Mit `/matrix`: die
    /// Dicts tragen einen Schlüssel außerhalb der Vergleichs-Whitelist –
    /// bewusst NICHT gemerged (Reference-/State-Semantik).
    static func identicalFormXObjectsPDF(withMatrix: Bool = false,
                                         name: String = "identical-forms")
        throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let matrix = withMatrix ? "/Matrix[1 0 0 1 0 0]" : ""
        func formDict() -> String {
            "/Type/XObject/Subtype/Form/BBox[0 0 100 100]"
                + "/Resources<<>>\(matrix)"
        }
        let formBody = Data("0.5 g 20 20 60 60 re f\n".utf8)
        var pageNumbers: [Int] = []
        for index in 0..<2 {
            // Identischer Form-Inhalt, je Seite ein EIGENES Objekt.
            let form = b.addStream(dictionary: formDict(), data: formBody)
            let content = b.addStream(
                dictionary: "",
                content: "q 2 0 0 2 \(50 + index * 200) 400 cm /Form0 Do Q")
            pageNumbers.append(b.addObject(
                "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
                + "/Resources<</XObject<</Form0 \(form) 0 R>>>>"
                + "/Contents \(content) 0 R>>"))
        }
        let kids = pageNumbers.map { "\($0) 0 R" }.joined(separator: " ")
        b.fill(pages, "<</Type/Pages/Kids[\(kids)]/Count 2>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// V2-5 – Fixture-Paar für maschinenlesbare ValidationFindings: gleiche
    /// Seite, aber der Textinhalt der Ausgabe weicht von der Referenz ab
    /// (nicht eingebettete Helvetica, damit PDFKit die Extraktion ohne
    /// Fontprogramm hinbekommt).
    static func textPDF(text: String, name: String) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject(
            "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let content = b.addStream(
            dictionary: "",
            content: "BT /F1 24 Tf 72 700 Td (\(text)) Tj ET")
        let page = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</Font<</F1 \(font) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Phase 5b – Echte Systemfonts für Subsetting-Tests. Nicht ins Repo
    /// committet: Tests lesen zur Laufzeit von macOS-Systempfaden und
    /// skippen graceful, wenn keiner der Kandidaten existiert (CI-fremd).
    /// Nur plain-sfnt (0x00010000 / 'true') – TTC- und OTTO-Kapseln sind
    /// auch in der Subsetting-Whitelist ausgeschlossen.
    static let systemTrueTypeFontBytes: Data? = {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/System/Library/Fonts/Supplemental/Verdana.ttf",
            "/System/Library/Fonts/Supplemental/Tahoma.ttf",
            "/System/Library/Fonts/Supplemental/Georgia.ttf",
        ]
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  data.count > 16 else { continue }
            let version = (UInt32(data[data.startIndex]) << 24)
                | (UInt32(data[data.startIndex + 1]) << 16)
                | (UInt32(data[data.startIndex + 2]) << 8)
                | UInt32(data[data.startIndex + 3])
            if version == 0x0001_0000 || version == 0x7472_7565 { return data }
        }
        return nil
    }()

    /// GID eines Unicode-Codepoints aus der cmap des Fonts (Format 4 und 12,
    /// Subtable-Präferenz (3,1)/(0,x) vor (3,0)). nil = nicht auflösbar.
    /// Nur für Fixtures: CID==GID-Fixtures brauchen die ECHTEN GIDs.
    enum TrueTypeGlyphLookup {
        static func gid(for data: Data, unicode: UInt32) -> UInt32? {
            let base = data.startIndex
            func be16(_ offset: Int) -> Int? {
                guard offset >= 0, offset + 2 <= data.count else { return nil }
                return (Int(data[base + offset]) << 8) | Int(data[base + offset + 1])
            }
            func be32(_ offset: Int) -> Int? {
                guard offset >= 0, offset + 4 <= data.count else { return nil }
                return (Int(data[base + offset]) << 24)
                    | (Int(data[base + offset + 1]) << 16)
                    | (Int(data[base + offset + 2]) << 8)
                    | Int(data[base + offset + 3])
            }
            guard let numTables = be16(4) else { return nil }
            var cmapOffset = -1
            for i in 0..<numTables {
                let record = 12 + i * 16
                guard record + 16 <= data.count else { return nil }
                let tag = String(bytes: data[base + record..<base + record + 4],
                                 encoding: .ascii)
                if tag == "cmap" {
                    cmapOffset = be32(record + 8) ?? -1
                    break
                }
            }
            guard cmapOffset >= 0, let subTableCount = be16(cmapOffset + 2) else {
                return nil
            }
            var chosen = -1
            var bestScore = -1
            for i in 0..<subTableCount {
                let record = cmapOffset + 4 + i * 8
                guard record + 8 <= data.count else { continue }
                let platform = be16(record) ?? 0
                let encoding = be16(record + 2) ?? 0
                let offset = be32(record + 4) ?? 0
                let score: Int
                switch (platform, encoding) {
                case (3, 1), (3, 10), (0, 3), (0, 4), (0, 5), (0, 6): score = 3
                case (0, _): score = 2
                case (3, 0): score = 1
                default: score = 0
                }
                if score > bestScore {
                    bestScore = score
                    chosen = cmapOffset + offset
                }
            }
            guard chosen >= 0, let format = be16(chosen) else { return nil }
            switch format {
            case 4:
                guard let segCountX2 = be16(chosen + 6) else { return nil }
                let segCount = segCountX2 / 2
                let endBase = chosen + 14
                let startBase = endBase + segCountX2 + 2
                let deltaBase = startBase + segCountX2
                let rangeBase = deltaBase + segCountX2
                let u = Int(unicode)
                for s in 0..<segCount {
                    let end = be16(endBase + s * 2) ?? 0
                    let start = be16(startBase + s * 2) ?? 0
                    guard u >= start, u <= end else { continue }
                    let delta = be16(deltaBase + s * 2) ?? 0
                    let rangeOffset = be16(rangeBase + s * 2) ?? 0
                    if rangeOffset == 0 {
                        return UInt32((u + delta) & 0xFFFF)
                    }
                    let gi = rangeBase + s * 2 + rangeOffset + (u - start) * 2
                    guard let raw = be16(gi), raw != 0 else { return nil }
                    return UInt32((raw + delta) & 0xFFFF)
                }
                return nil
            case 12:
                guard let groups = be32(chosen + 12) else { return nil }
                for g in 0..<groups {
                    let record = chosen + 16 + g * 12
                    guard record + 12 <= data.count else { return nil }
                    let start = be32(record) ?? 0
                    let end = be32(record + 4) ?? 0
                    let startGID = be32(record + 8) ?? 0
                    if unicode >= start, unicode <= end {
                        return UInt32(Int(startGID) + Int(unicode) - Int(start))
                    }
                }
                return nil
            default:
                return nil
            }
        }
    }

    /// ToUnicode-CMap für die Subsetting-Fixtures: bildet jeden Code auf
    /// denselben ASCII-Codepoint ab (`cidMode` mit 2-Byte-Quellen).
    static func fixtureCMap(codes: [UInt32], cidMode: Bool = false) -> String {
        var entries = ""
        for code in codes {
            let source = cidMode
                ? String(format: "%04X", code)
                : String(format: "%02X", code)
            entries += "<\(source)> <\(String(format: "%04X", code))>\n"
        }
        return """
            /CIDInit /ProcSet findresource begin
            12 dict begin
            begincmap
            /CMapName /FixtureFont def
            /CMapType 2 def
            1 begincodespacerange
            <\(cidMode ? "0000" : "00")> <FF>
            endcodespacerange
            \(codes.count) beginbfchar
            \(entries)endbfchar
            endcmap
            CMapName currentdict /CMap defineresource pop
            end
            end
            """
    }

    /// Phase 5b – Simple-TrueType-Fixture mit ECHTEM Fontprogramm: 26
    /// /Widths-Einträge (FirstChar 65 … LastChar 90), benutzt werden nur
    /// `text`-Codes – das Subsetting muss das Programm verkleinern und die
    /// /Widths auf die benutzten Codes kürzen. `toUnicode: false` zwingt in
    /// den Pfad der vollen Code-Raum-Abdeckung über WinAnsiEncoding.
    /// Liefert nil, wenn kein TrueType-Systemfont verfügbar ist.
    static func subsetFontPDF(text: String = "ABC",
                              toUnicode: Bool = true,
                              name: String = "subset-font") throws -> URL? {
        guard let fontData = systemTrueTypeFontBytes else { return nil }
        let codes = Array(text.utf8).map { UInt32($0) }
        guard codes.allSatisfy({ (65...90).contains($0) }) else { return nil }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let fontFile = b.addStream(dictionary: "/Length1 \(fontData.count)",
                                   data: fontData)
        let descriptor = b.addObject(
            "<</Type/FontDescriptor/FontName/ABCDEF+FixtureFont/Flags 32"
            + "/FontBBox[0 0 1000 1000]/ItalicAngle 0/Ascent 800"
            + "/Descent -200/CapHeight 700/StemV 80"
            + "/FontFile2 \(fontFile) 0 R>>")
        let widths = Array(repeating: "700", count: 26).joined(separator: " ")
        var fontDict = "<</Type/Font/Subtype/TrueType/BaseFont/ABCDEF+FixtureFont"
            + "/FirstChar 65/LastChar 90/Widths[\(widths)]"
            + "/Encoding/WinAnsiEncoding"
            + "/FontDescriptor \(descriptor) 0 R"
        if toUnicode {
            let toUnicodeStream = b.addStream(dictionary: "",
                                              content: fixtureCMap(codes: codes))
            fontDict += "/ToUnicode \(toUnicodeStream) 0 R"
        }
        fontDict += ">>"
        let font = b.addObject(fontDict)
        let content = b.addStream(
            dictionary: "",
            content: "BT /F1 24 Tf 72 700 Td (\(text)) Tj ET")
        let page = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</Font<</F1 \(font) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Phase 5b – Type0/Identity-H-Fixture mit ECHTEM Fontprogramm. Ohne
    /// `gidMapStream`: CIDs im Content sind die ECHTEN GIDs (aus der cmap
    /// gelesen, CID==GID). Mit `gidMapStream`: CIDs 0…n-1 über einen
    /// /CIDToGIDMap-Strom auf die echten GIDs gemappt – nicht-Identity,
    /// der Pass muss den Font komplett behalten. nil ohne Systemfont oder
    /// wenn eine GID nicht auflösbar ist.
    static func cidSubsetFontPDF(text: String = "ABC",
                                 gidMapStream: Bool = false,
                                 name: String = "cid-subset-font") throws -> URL? {
        guard let fontData = systemTrueTypeFontBytes else { return nil }
        var gids: [UInt32] = []
        for scalar in text.utf8 {
            guard let gid = TrueTypeGlyphLookup.gid(for: fontData,
                                                    unicode: UInt32(scalar)),
                  gid > 0, gid < 0xFFFF else { return nil }
            gids.append(gid)
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let fontFile = b.addStream(dictionary: "/Length1 \(fontData.count)",
                                   data: fontData)
        let descriptor = b.addObject(
            "<</Type/FontDescriptor/FontName/ABCDEF+FixtureFont/Flags 32"
            + "/FontBBox[0 0 1000 1000]/ItalicAngle 0/Ascent 800"
            + "/Descent -200/CapHeight 700/StemV 80"
            + "/FontFile2 \(fontFile) 0 R>>")

        // CIDs: Identitätsfall die echten GIDs, Stromfall 0…n-1.
        let cids: [UInt32] = gidMapStream
            ? Array(0..<UInt32(gids.count))
            : gids
        let wArray = cids.map { "\($0) [600]" }.joined(separator: " ")

        var descendantDict = "<</Type/Font/Subtype/CIDFontType2"
            + "/BaseFont/ABCDEF+FixtureFont"
            + "/CIDSystemInfo<</Registry(Adobe)/Ordering(Identity)/Supplement 0>>"
            + "/FontDescriptor \(descriptor) 0 R/DW 600/W[\(wArray)]"
        if gidMapStream {
            // CIDToGIDMap-Strom: je CID ein u16 (big-endian) mit dem GID.
            var mapData = Data()
            for gid in gids {
                mapData.append(UInt8((gid >> 8) & 0xFF))
                mapData.append(UInt8(gid & 0xFF))
            }
            let map = b.addStream(dictionary: "", data: mapData)
            descendantDict += "/CIDToGIDMap \(map) 0 R"
        } else {
            descendantDict += "/CIDToGIDMap/Identity"
        }
        descendantDict += ">>"
        let descendant = b.addObject(descendantDict)

        let toUnicodeStream = b.addStream(
            dictionary: "", content: fixtureCMap(codes: cids, cidMode: true))
        let type0 = b.addObject(
            "<</Type/Font/Subtype/Type0/BaseFont/ABCDEF+FixtureFont-Identity-H"
            + "/Encoding/Identity-H"
            + "/DescendantFonts[\(descendant) 0 R]"
            + "/ToUnicode \(toUnicodeStream) 0 R>>")

        let cidBytes = cids.flatMap { [UInt8(($0 >> 8) & 0xFF), UInt8($0 & 0xFF)] }
        let hex = cidBytes.map { String(format: "%02X", $0) }.joined()
        let content = b.addStream(
            dictionary: "",
            content: "BT /F1 24 Tf 72 700 Td <\(hex)> Tj ET")
        let page = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</Font<</F1 \(type0) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Phase 5b – Type3-Fixture: Glyphenprozeduren statt Fontprogramm –
    /// nie subsettet, nie beräumt.
    static func type3FontPDF(name: String = "type3-font") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let procA = b.addStream(dictionary: "",
                                content: "694 0 d0 0 0 694 700 re f")
        let font = b.addObject(
            "<</Type/Font/Subtype/Type3"
            + "/FontBBox[0 0 1000 1000]/FontMatrix[0.001 0 0 0.001 0 0]"
            + "/CharProcs<</A \(procA) 0 R>>"
            + "/Encoding<</Type/Encoding/Differences[65/A]>>"
            + "/FirstChar 65/LastChar 65/Widths[694]/Resources<<>>>>")
        let content = b.addStream(
            dictionary: "",
            content: "BT /T3 24 Tf 72 700 Td (A) Tj ET")
        let page = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
            + "/Resources<</Font<</T3 \(font) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Ein Foto mit GENAU dieser Pixelbreite, seitenfüllend platziert.
    ///
    /// Über die Pixelbreite stellt der Aufrufer die effektive Auflösung ein:
    /// Bei 612 pt Seitenbreite (8,5 Zoll) sind 1275 px genau 150 dpi. Das ist
    /// die Stellschraube, um die Auflösungspolitik zu prüfen.
    static func photoAtWidth(_ pixelWidth: Int,
                             name: String = "photo-at-width") throws -> URL {
        let height = max(1, pixelWidth * 3 / 4)
        let rep = bitmapRep(size: CGSize(width: pixelWidth, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Farbverlauf mit Rauschen: komprimierbar, aber nicht trivial.
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: pixelWidth, by: 4) {
                NSColor(calibratedRed: CGFloat(x % 255) / 255.0,
                        green: CGFloat(y % 255) / 255.0,
                        blue: CGFloat((x + y) % 255) / 255.0,
                        alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: x, y: y, width: 4, height: 4)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage,
              let jpeg = NSBitmapImageRep(cgImage: cg)
                .representation(using: .jpeg,
                                properties: [.compressionFactor: 0.9]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixelWidth)"
                + "/Height \(height)/ColorSpace/DeviceRGB"
                + "/BitsPerComponent 8/Filter/DCTDecode",
            data: jpeg)
        // Seitenfüllend: 612 × 792 pt.
        let content = b.addStream(dictionary: "",
                                  content: "q 612 0 0 792 0 0 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</XObject<</Im0 \(image) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Dokument mit einem gut komprimierbaren Anhang.
    ///
    /// `attachmentPDF` reicht für diesen Zweck nicht: Sein Anhang ist so
    /// klein, dass das Nachpacken nichts ändert. Erst ein Anhang mit viel
    /// Wiederholung zeigt den Unterschied zwischen gespeicherter und
    /// tatsächlicher Größe – genau der Unterschied, der über den Korpus 120
    /// Fehlschläge erzeugt hat.
    static func compressibleAttachmentPDF(name: String = "attach-big") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let content = b.addStream(dictionary: "",
                                  content: "BT /F1 12 Tf 72 700 Td (Mit Anhang) Tj ET")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</Font<</F1 \(font) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")

        // Stark redundanter Inhalt: unkomprimiert abgelegt, damit der
        // Struktur-Pass etwas zu tun hat.
        let payload = String(repeating: "Konfigurationszeile mit viel Wiederholung\n",
                             count: 300)
        let file = b.addStream(dictionary: "/Type/EmbeddedFile", content: payload)
        let spec = b.addObject("<</Type/Filespec/F(einstellungen.txt)"
            + "/UF(einstellungen.txt)/EF<</F \(file) 0 R>>>>")
        let embedded = b.addObject("<</Names[(einstellungen.txt) \(spec) 0 R]>>")
        let names = b.addObject("<</EmbeddedFiles \(embedded) 0 R>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R"
            + "/Names \(names) 0 R>>")

        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Ein navigationsreiches Dokument – und dasselbe mit ABSICHTLICH
    /// falschen Zielen.
    ///
    /// Gate 6 verlangt eine Fixture, deren Ziele falsch zeigen, während alle
    /// Zählungen stimmen: gleich viele Lesezeichen, gleich viele benannte
    /// Ziele, gleich viele Links. Nur führen sie woandershin. Genau dieser
    /// Fall ging jedem zählenden Vergleich durch.
    ///
    /// - Parameter misdirected: `false` liefert die richtige Fassung,
    ///   `true` dieselbe Struktur mit vertauschten Zielseiten.
    static func navigationGoldenPDF(misdirected: Bool = false,
                                    name: String = "nav-golden") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")

        var pageObjects: [Int] = []
        for index in 0..<3 {
            let content = b.addStream(
                dictionary: "",
                content: "BT /F1 14 Tf 72 700 Td (Kapitel \(index + 1)) Tj ET")
            pageObjects.append(b.addObject(
                "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]"
                + "/Resources<</Font<</F1 \(font) 0 R>>>>"
                + "/Contents \(content) 0 R>>"))
        }

        /// Richtig zeigt Eintrag i auf Seite i. Falsch: um eins verdreht –
        /// dieselbe Anzahl, dasselbe Aussehen, andere Wirkung.
        func target(_ i: Int) -> Int {
            misdirected ? (i + 1) % pageObjects.count : i
        }

        // Benannte Ziele
        var destPairs: [String] = []
        for (i, name) in ["einleitung", "hauptteil", "schluss"].enumerated() {
            destPairs.append("(\(name)) [\(pageObjects[target(i)]) 0 R /Fit]")
        }
        let dests = b.addObject("<</Names[\(destPairs.joined(separator: " "))]>>")
        let names = b.addObject("<</Dests \(dests) 0 R>>")

        // Outline: drei Einträge, einer davon verschachtelt
        let outlineRoot = b.reserveNumber()
        let titles = ["Einleitung", "Hauptteil", "Schluss"]
        // Erst alle Nummern reservieren: Die Einträge verweisen mit /Prev und
        // /Next aufeinander, also muss jede Nummer bekannt sein, bevor der
        // erste Eintrag geschrieben wird.
        let items = titles.map { _ in b.reserveNumber() }
        for (i, title) in titles.enumerated() {
            var entry = "<</Title(\(title))/Parent \(outlineRoot) 0 R"
                + "/Dest[\(pageObjects[target(i)]) 0 R /Fit]"
            if i > 0 { entry += "/Prev \(items[i - 1]) 0 R" }
            if i < items.count - 1 { entry += "/Next \(items[i + 1]) 0 R" }
            entry += ">>"
            b.fill(items[i], entry)
        }
        b.fill(outlineRoot, "<</Type/Outlines/First \(items[0]) 0 R"
            + "/Last \(items[items.count - 1]) 0 R/Count \(items.count)>>")

        let kids = pageObjects.map { "\($0) 0 R" }.joined(separator: " ")
        b.fill(pages, "<</Type/Pages/Kids[\(kids)]/Count \(pageObjects.count)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R"
            + "/Outlines \(outlineRoot) 0 R/Names \(names) 0 R>>")

        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Dokument mit gepflegter Dokumentinformation.
    ///
    /// Titel, Autor, Thema und Schlagwörter sind Eingaben des Nutzers. Ohne
    /// eine Fixture, die sie trägt, lässt sich nicht prüfen, ob eine
    /// Bearbeitung sie erhält – ein Vergleich „leer gegen leer" meldet nie
    /// etwas (Final Core Hardening 5.3).
    static func metadataPDF(name: String = "metadata") throws -> URL {
        let doc = document(pages: [textPage("Dokument mit Metadaten.")])
        doc.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Quartalsbericht Q3",
            PDFDocumentAttribute.authorAttribute: "M. Beispiel",
            PDFDocumentAttribute.subjectAttribute: "Kennzahlen",
            PDFDocumentAttribute.keywordsAttribute: ["Umsatz", "Marge"],
        ]
        return try write(doc, name: name)
    }

    /// Textlastige Einzelseite.
    static func textPDF(lines: Int = 30, name: String = "text") throws -> URL {
        let body = (1...lines).map { "Zeile \($0) des Kompatibilitäts-Fixtures." }.joined(separator: "\n")
        return try write(document(pages: [textPage(body)]), name: name)
    }

    /// Foto-lastige Seite (großes Rausch-JPEG → Bild-Engine greift an).
    static func photoHeavyPDF(pixels: Int = 1200, name: String = "photo") throws -> URL {
        let w = pixels, h = pixels
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        // Schnelles Rauschen über den Rohpuffer (kein Per-Pixel-setColor).
        if let base = rep.bitmapData {
            let bpr = rep.bytesPerRow
            for y in 0..<h {
                let row = base + y * bpr
                for x in 0..<w {
                    let p = row + x * 4
                    p[0] = UInt8(truncatingIfNeeded: x * 255 / max(1, w))
                    p[1] = UInt8(truncatingIfNeeded: y * 255 / max(1, h))
                    p[2] = UInt8(truncatingIfNeeded: (x ^ y) * 255 / max(1, max(w, 1)))
                    p[3] = 255
                }
            }
        }
        let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
        let image = NSImage(data: jpeg)!
        return try write(document(pages: [PDFPage(image: image)!]), name: name)
    }

    /// Echter Vektor-Text (selektierbar, `page.string` gefüllt) – Basis für
    /// Texterhalt-Prüfungen der Validator-Policies.
    @discardableResult
    static func vectorTextPDF(lines: Int = 20, name: String = "vector-text") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name)-\(UUID().uuidString).pdf")

        let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        var box = mediaBox
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        let body = (1...max(1, lines)).map { "Zeile \($0) des Vektor-Text-Fixtures." }
            .joined(separator: "\n")
        body.draw(in: CGRect(x: 40, y: mediaBox.height - 200, width: mediaBox.width - 80,
                             height: CGFloat(lines) * 24 + 40),
                  withAttributes: [.font: NSFont.systemFont(ofSize: 16),
                                   .foregroundColor: NSColor.black])

        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// Annotationen + externer Link auf einer Seite (für Erhalt-Tests).
    static func annotatedPDF(name: String = "annotated") throws -> URL {
        let doc = document(pages: [vectorTextPage()])
        let page = doc.page(at: 0)!
        let bounds = page.bounds(for: .mediaBox)

        let highlight = PDFAnnotation(bounds: CGRect(x: 60, y: bounds.height - 160,
                                                     width: 220, height: 28),
                                      forType: .highlight, withProperties: nil)
        highlight.color = .yellow
        page.addAnnotation(highlight)

        let link = PDFAnnotation(bounds: CGRect(x: 60, y: bounds.height - 240,
                                                width: 260, height: 26),
                                 forType: .link, withProperties: nil)
        link.contents = "https://example.com"
        link.url = URL(string: "https://example.com")
        page.addAnnotation(link)

        return try write(doc, name: name)
    }

    /// Gemischte Seitengrößen inkl. Landscape.
    static func mixedSizesPDF(name: String = "mixed-sizes") throws -> URL {
        let doc = document(pages: [
            textPage("A4 Portrait", size: CGSize(width: 595, height: 842)),
            textPage("Letter Landscape", size: CGSize(width: 792, height: 612)),
            textPage("Quadrat", size: CGSize(width: 500, height: 500)),
        ])
        return try write(doc, name: name)
    }

    /// Rotationen 0/90/180.
    static func rotatedPDF(name: String = "rotated") throws -> URL {
        let doc = document(pages: [textPage("0°"), textPage("90°"), textPage("180°")])
        doc.page(at: 1)?.rotation = 90
        doc.page(at: 2)?.rotation = 180
        return try write(doc, name: name)
    }

    /// Fake-Signatur: Content enthält den ByteRange-Marker des Detektors.
    static func fakeSignaturePDF(name: String = "fake-signed") throws -> URL {
        let doc = document(pages: [textPage("/ByteRange Marker")])
        let url = try write(doc, name: name)
        // Detector scannt Rohbytes – Marker zusätzlich anhängen, damit er sicher drin ist.
        var raw = try Data(contentsOf: url)
        raw.append(Data("%/ByteRange [0 1 2 3]\n".utf8))
        try raw.write(to: url)
        return url
    }

    /// Transparente Seite als PDF.
    static func transparentPDF(name: String = "transparent") throws -> URL {
        try write(document(pages: [transparentPage()]), name: name)
    }

    // MARK: - Epic Phase 2: semantisch reiche Fixtures

    /// Zwei-Seiten-Dokument mit Outline (Kapitel → beide Seiten) und internem Link.
    static func outlinedWithInternalLinkPDF(name: String = "outline-links") throws -> URL {
        let doc = document(pages: [
            vectorTextPage(),
            vectorTextPage(),
        ])
        let root = PDFOutline()
        let c1 = PDFOutline()
        c1.label = "Kapitel 1"
        c1.destination = PDFDestination(page: doc.page(at: 0)!, at: CGPoint(x: 0, y: 0))
        root.insertChild(c1, at: 0)
        let c2 = PDFOutline()
        c2.label = "Kapitel 2"
        c2.destination = PDFDestination(page: doc.page(at: 1)!, at: CGPoint(x: 0, y: 0))
        root.insertChild(c2, at: 1)
        doc.outlineRoot = root

        if let page = doc.page(at: 0) {
            let link = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 200, height: 24),
                                     forType: .link, withProperties: nil)
            link.destination = PDFDestination(page: doc.page(at: 1)!, at: CGPoint(x: 0, y: 0))
            page.addAnnotation(link)
        }
        return try write(doc, name: name)
    }

    /// AcroForm-artige Widget-Felder (Textfelder) über PDFKit-Annotationen.
    static func formWidgetsPDF(name: String = "form") throws -> URL {
        let doc = document(pages: [vectorTextPage(), vectorTextPage()])
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let field = PDFAnnotation(bounds: CGRect(x: 60, y: 600, width: 260, height: 30),
                                      forType: .widget, withProperties: nil)
            field.fieldName = i == 0 ? "name" : "zweites_form_feld"
            field.widgetFieldType = .text
            field.isReadOnly = false
            page.addAnnotation(field)
        }
        return try write(doc, name: name)
    }

    /// Page Labels setzen (i, ii / A-1-Stil über PDFKit nicht direkt API-gestützt;
    /// wir schreiben Labels als rohen NumberStyle-Stub per qpdf-freiem Fallback:
    /// aktuell NUR Erkennung leer → dokumentierte Limitierung).
    static func pageLabelsAttemptPDF(name: String = "labels-attempt") throws -> URL {
        // PDFKit bietet keine Schreib-API für Page Labels; Fixture bleibt ohne
        // Labels – Snapshot erwartet leer (regressionssicher dokumentiert).
        return try write(document(pages: [vectorTextPage(), vectorTextPage()]),
                         name: name)
    }

    /// Object Streams / XRef Streams: erzwinge moderne Struktur via qpdf-CLI
    /// (falls verfügbar); sonst Fallback auf normale Ausgabe.
    static func objectStreamPDF(name: String = "object-streams") throws -> URL {
        let base = try write(document(pages: [vectorTextPage(),
                                              solidColorPage(.systemIndigo)]),
                             name: name + "-raw")
        guard let qpdf = Compressor.findQPDF() else { return base }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: base) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qpdf)
        p.arguments = ["--object-streams=generate", "--stream-data=compress",
                       base.path, out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return base }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? out : base
    }

    // MARK: - Manifest (Epic Phase 2)

    struct FixtureExpectation {
        let name: String
        let expectedPageCount: Int
        let expectsText: Bool
        let minAnnotations: Int
        let minLinks: Int
        let expectsOutline: Bool
        let expectsFormWidgets: Int
    }

    /// Maschinenlesbare Erwartungen je Fixture (Gate-2-Grundlage).
    static func manifest() -> [FixtureExpectation] {
        [
            .init(name: "vector-text", expectedPageCount: 1, expectsText: true,
                  minAnnotations: 0, minLinks: 0, expectsOutline: false,
                  expectsFormWidgets: 0),
            .init(name: "photo", expectedPageCount: 1, expectsText: false,
                  minAnnotations: 0, minLinks: 0, expectsOutline: false,
                  expectsFormWidgets: 0),
            .init(name: "mixed-sizes", expectedPageCount: 3, expectsText: false,
                  minAnnotations: 0, minLinks: 0, expectsOutline: false,
                  expectsFormWidgets: 0),
            .init(name: "rotated", expectedPageCount: 3, expectsText: false,
                  minAnnotations: 0, minLinks: 0, expectsOutline: false,
                  expectsFormWidgets: 0),
            .init(name: "annotated", expectedPageCount: 1, expectsText: true,
                  minAnnotations: 2, minLinks: 1, expectsOutline: false,
                  expectsFormWidgets: 0),
            .init(name: "transparent", expectedPageCount: 1, expectsText: false,
                  minAnnotations: 0, minLinks: 0, expectsOutline: false,
                  expectsFormWidgets: 0),
            .init(name: "outline-links", expectedPageCount: 2, expectsText: true,
                  minAnnotations: 1, minLinks: 1, expectsOutline: true,
                  expectsFormWidgets: 0),
            .init(name: "form", expectedPageCount: 2, expectsText: true,
                  minAnnotations: 0, minLinks: 0, expectsOutline: false,
                  expectsFormWidgets: 2),
            .init(name: "object-streams", expectedPageCount: 2, expectsText: true,
                  minAnnotations: 0, minLinks: 0, expectsOutline: false,
                  expectsFormWidgets: 0),
        ]
    }
}

// MARK: - Phase 26 – Erweiterte Fixtures

extension PDFFixtures {

    /// Mehrseitiges Dokument mit unterschiedlichen Inhaltstypen pro Seite.
    static func multiContentTypePDF(name: String = "multi-content") throws -> URL {
        let doc = PDFDocument()
        doc.insert(textPage("Seite 1: Nur Text mit ausreichend Inhalt für die Validierung."), at: 0)
        doc.insert(solidColorPage(.systemBlue, size: CGSize(width: 595, height: 842)), at: 1)
        doc.insert(transparentPage(size: CGSize(width: 500, height: 400)), at: 2)
        doc.insert(solidColorPage(.systemOrange, size: CGSize(width: 600, height: 400)), at: 3)
        return try write(doc, name: name)
    }

    /// Gemischte Rotationen über mehrere Seiten.
    static func mixedRotationPDF(name: String = "mixed-rot") throws -> URL {
        let doc = PDFDocument()
        for (i, rot) in [0, 90, 180, 270].enumerated() {
            let page = textPage("Rotation \(rot)° auf Seite \(i+1).")
            page.rotation = rot
            doc.insert(page, at: i)
        }
        return try write(doc, name: name)
    }

    /// PDF mit Annotationen verschiedener Typen.
    static func multiAnnotationPDF(name: String = "multi-anno") throws -> URL {
        let doc = document(pages: [textPage("Annotierte Seite.")])
        let page = doc.page(at: 0)!
        let bounds = page.bounds(for: .mediaBox)

        let highlight = PDFAnnotation(bounds: CGRect(x: 40, y: bounds.height - 120,
                                                     width: 200, height: 24),
                                      forType: .highlight, withProperties: nil)
        highlight.color = .yellow
        page.addAnnotation(highlight)

        let underline = PDFAnnotation(bounds: CGRect(x: 40, y: bounds.height - 160,
                                                     width: 180, height: 20),
                                      forType: .underline, withProperties: nil)
        page.addAnnotation(underline)

        let strikeout = PDFAnnotation(bounds: CGRect(x: 40, y: bounds.height - 200,
                                                     width: 160, height: 18),
                                      forType: .strikeOut, withProperties: nil)
        page.addAnnotation(strikeout)

        let link = PDFAnnotation(bounds: CGRect(x: 40, y: bounds.height - 260,
                                                width: 240, height: 22),
                                 forType: .link, withProperties: nil)
        link.url = URL(string: "https://www.apple.com")
        page.addAnnotation(link)

        return try write(doc, name: name)
    }
}

// MARK: - Phase 26 Erweiterungen: alle fehlenden Spec-Kategorien

extension PDFFixtures {

    /// Kleine Schrift (tiny text) für OCR-/Lesbarkeits-Edge-Cases.
    static func tinyTextPDF(name: String = "tiny-text") throws -> URL {
        return try write(document(pages: [textPage("Microscopic text 6pt for edge case testing.")]), name: name)
    }

    /// Graustufen-Seite.
    static func grayscalePDF(name: String = "grayscale") throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 612, pixelsHigh: 792,
                                   bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false,
                                   isPlanar: false, colorSpaceName: .deviceWhite,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = CGSize(width: 612, height: 792)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.85, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 50, y: 50, width: 512, height: 692)).fill()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 100, y: 100, width: 200, height: 200)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(cgImage: rep.cgImage!, size: CGSize(width: 612, height: 792))
        return try write(document(pages: [PDFPage(image: image)!]), name: name)
    }

    /// Viele kleine Bilder auf einer Seite.
    /// Viele VERSCHIEDENE Bilder auf einer Seite.
    ///
    /// Diese Fixture erzeugte zuvor gar keine Bilder: Sie baute in einer
    /// Schleife NSImages und verwarf sie wieder („let _ = img"), zurück blieb
    /// eine leere Seite. Sie stand trotzdem im Golden-Korpus als Dokument
    /// „viele Bilder" – und prüfte dort nichts.
    ///
    /// Die Bilder unterscheiden sich tatsächlich, sonst wäre sie als
    /// Gegenprobe zum Zusammenführen von Duplikaten wertlos.
    static func manyImagesPDF(count: Int = 20, name: String = "many-images") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var xobjects: [String] = []
        var content = ""

        for index in 0..<max(1, count) {
            let side = 64
            let rep = bitmapRep(size: CGSize(width: side, height: side))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // Jedes Bild bekommt einen eigenen Farbton UND ein eigenes
            // Muster – gleiche Farbe allein könnte nach der JPEG-Kodierung
            // bitgleich werden.
            NSColor(calibratedHue: CGFloat(index) / CGFloat(max(count, 1)),
                    saturation: 0.85, brightness: 0.9, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
            NSColor.black.setFill()
            for stripe in 0...(index % 7) {
                NSBezierPath(rect: NSRect(x: stripe * 8, y: 0,
                                          width: 3, height: side)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = rep.cgImage,
                  let jpeg = NSBitmapImageRep(cgImage: cg)
                    .representation(using: .jpeg,
                                    properties: [.compressionFactor: 0.9]) else {
                continue
            }
            let obj = b.addStream(
                dictionary: "/Type/XObject/Subtype/Image/Width \(side)"
                    + "/Height \(side)/ColorSpace/DeviceRGB"
                    + "/BitsPerComponent 8/Filter/DCTDecode",
                data: jpeg)
            xobjects.append("/Im\(index) \(obj) 0 R")
            let column = index % 8, row = index / 8
            content += "q 60 0 0 60 \(20 + column * 70) "
                + "\(700 - row * 70) cm /Im\(index) Do Q "
        }

        let stream = b.addStream(dictionary: "", content: content)
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]"
            + "/Resources<</XObject<<\(xobjects.joined(separator: " "))>>>>"
            + "/Contents \(stream) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    /// Sehr großes Bild (hohe Auflösung).
    static func hugeImagePDF(pixels: Int = 4000, name: String = "huge-image") throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = CGSize(width: pixels / 4, height: pixels / 4)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemIndigo.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: rep.size)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: pixels/8, y: pixels/8, width: pixels*3/4, height: pixels*3/4)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(cgImage: rep.cgImage!, size: rep.size)
        return try write(document(pages: [PDFPage(image: image)!]), name: name)
    }

    /// Gemischt: Annotationen + Bilder + Outlines + Links in EINEM Dokument.
    static func complexCombinationPDF(name: String = "complex-combo") throws -> URL {
        let doc = document(pages: [
            textPage("Komplexe Seite 1: Annotations + Link."),
            solidColorPage(.systemTeal, size: CGSize(width: 595, height: 842)),
            transparentPage(),
            textPage("Komplexe letzte Seite."),
        ])
        // Annotationen auf Seite 0:
        if let p = doc.page(at: 0) {
            let b = p.bounds(for: .mediaBox)
            let hl = PDFAnnotation(bounds: CGRect(x: 40, y: b.height-100, width: 150, height: 22),
                                   forType: .highlight, withProperties: nil)
            hl.color = .yellow
            p.addAnnotation(hl)
            let link = PDFAnnotation(bounds: CGRect(x: 40, y: b.height-140, width: 200, height: 22),
                                     forType: .link, withProperties: nil)
            link.url = URL(string: "https://example.org")
            p.addAnnotation(link)
        }
        // Rotation auf Seite 1:
        doc.page(at: 1)?.rotation = 90
        // Outline:
        let root = PDFOutline()
        let c1 = PDFOutline(); c1.label = "Section A"; if let pg = doc.page(at: 0) { c1.destination = PDFDestination(page: pg, at: CGPoint(x: 0, y: 0)) }
        root.insertChild(c1, at: 0)
        let c2 = PDFOutline(); c2.label = "Section B"; if let pg = doc.page(at: 3) { c2.destination = PDFDestination(page: pg, at: CGPoint(x: 0, y: 0)) }
        root.insertChild(c2, at: 1)
        doc.outlineRoot = root

        return try write(doc, name: name)
    }

    /// 300-Seiten-Stress-Dokument.
    static func largeStressPDF(pages: Int = 300, name: String = "stress-300") throws -> URL {
        let doc = PDFDocument()
        for i in 0..<pages {
            doc.insert(textPage("Stress-Seite \(i+1) von \(pages).\n" +
                                String(repeating: "Inhaltsblock für Speicher- und Performance-Test. ", count: 6)), at: i)
        }
        return try write(doc, name: name)
    }

    /// Malformed: Corrupt object stream.
    static func corruptObjectStreamPDF(name: String = "corrupt-objstm") throws -> URL {
        let base = try objectStreamPDF(name: name + "-raw")
        var raw = try Data(contentsOf: base)
        // Zerstöre die Mitte des Streams:
        if raw.count > 100 {
            let mid = raw.count / 2
            raw.replaceSubrange(mid..<min(mid + 50, raw.count), with: Data(repeating: 0xFF, count: 50))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
        try raw.write(to: url)
        try? FileManager.default.removeItem(at: base)
        return url
    }

    /// Malformed: Invalid rotation value.
    static func invalidRotationPDF(name: String = "invalid-rot") throws -> URL {
        var data = Data()
        var offsets: [Int] = []
        func add(_ s: String) { offsets.append(data.count); data.append(Data(s.utf8)) }
        data.append(Data("%PDF-1.4\n".utf8))
        add("1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n")
        add("2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n")
        // Nur EIN Defekt: die Rotation. /Resources ist korrekt gesetzt,
        // damit die Fixture nicht zwei Ursachen mischt.
        add("3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Resources<<>>/Rotate 137>>endobj\n")
        let sx = data.count
        data.append(Data("xref\n0 4\n".utf8))
        data.append(Data(String(format: "0000000000 65535 f \n").utf8))
        for o in offsets { data.append(Data(String(format: "%010d 00000 n \n", o).utf8)) }
        data.append(Data("trailer<</Size 4/Root 1 0 R>>\nstartxref\n\(sx)\n%%EOF\n".utf8))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    // MARK: - Masterplan Finding 6 – Snapshot-Gate-Fixtures
    //
    // Alle folgenden Fixtures werden auf Byte-Ebene geschrieben: PDFKit
    // normalisiert beim Speichern genau die Strukturen, die hier geprüft
    // werden sollen (CropBox-Ursprung, Name-Trees, Feldhierarchie).

    /// Seite mit CropBox, die NICHT im MediaBox-Ursprung beginnt.
    static func croppedPagePDF() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let content = b.addStream(dictionary: "", content: "BT /F1 12 Tf 100 700 Td (Crop) Tj ET")
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let page = b.addObject("""
        <</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]\
        /CropBox[36 72 576 720]/Resources<</Font<</F1 \(font) 0 R>>>>\
        /Contents \(content) 0 R>>
        """)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "cropbox")
    }

    /// Zwei Seiten + Named-Destination-Name-Tree („kapitel1"/„kapitel2").
    static func namedDestinationPDF() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let c1 = b.addStream(dictionary: "", content: "BT /F1 12 Tf 72 720 Td (Kapitel 1) Tj ET")
        let c2 = b.addStream(dictionary: "", content: "BT /F1 12 Tf 72 720 Td (Kapitel 2) Tj ET")
        let p1 = b.addObject("""
        <</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]\
        /Resources<</Font<</F1 \(font) 0 R>>>>/Contents \(c1) 0 R>>
        """)
        let p2 = b.addObject("""
        <</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]\
        /Resources<</Font<</F1 \(font) 0 R>>>>/Contents \(c2) 0 R>>
        """)
        b.fill(pages, "<</Type/Pages/Kids[\(p1) 0 R \(p2) 0 R]/Count 2>>")
        let dests = b.addObject("""
        <</Names[(kapitel1)[\(p1) 0 R/XYZ null null null]\
        (kapitel2)[\(p2) 0 R/XYZ null null null]]>>
        """)
        let names = b.addObject("<</Dests \(dests) 0 R>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R/Names \(names) 0 R>>")
        return try b.write(rootObject: root, prefix: "nameddest")
    }

    /// Drei Seiten mit /PageLabels (römisch, dann dezimal ab 5).
    static func pageLabelPDF() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var kids: [Int] = []
        for _ in 0..<3 {
            kids.append(b.addObject(
                "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]/Resources<<>>>>"))
        }
        b.fill(pages, "<</Type/Pages/Kids[\(kids.map { "\($0) 0 R" }.joined(separator: " "))]"
            + "/Count \(kids.count)>>")
        let labels = b.addObject("<</Nums[0<</S/r>>2<</S/D/St 5>>]>>")
        let root = b.addObject(
            "<</Type/Catalog/Pages \(pages) 0 R/PageLabels \(labels) 0 R>>")
        return try b.write(rootObject: root, prefix: "pagelabels")
    }

    /// Dokument mit genau einem eingebetteten Anhang (EmbeddedFiles-Name-Tree).
    static func attachmentPDF() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]/Resources<<>>>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let payload = Data("hallo welt".utf8)
        let file = b.addStream(dictionary: "/Type/EmbeddedFile/Subtype/text#2Fplain"
            + "/Params<</Size \(payload.count)>>", data: payload)
        let spec = b.addObject(
            "<</Type/Filespec/F(anhang.txt)/UF(anhang.txt)/EF<</F \(file) 0 R>>>>")
        let tree = b.addObject("<</Names[(anhang.txt) \(spec) 0 R]>>")
        let names = b.addObject("<</EmbeddedFiles \(tree) 0 R>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R/Names \(names) 0 R>>")
        return try b.write(rootObject: root, prefix: "attachment")
    }

    /// AcroForm mit Feldhierarchie: „adresse" → „strasse"/„ort" mit Werten.
    static func formHierarchyPDF() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let parent = b.reserveNumber()
        let page = b.reserveNumber()

        let strasse = b.addObject("""
        <</Type/Annot/Subtype/Widget/Parent \(parent) 0 R/T(strasse)/FT/Tx\
        /V(Hauptstrasse 1)/Rect[72 700 300 720]/P \(page) 0 R/F 4>>
        """)
        let ort = b.addObject("""
        <</Type/Annot/Subtype/Widget/Parent \(parent) 0 R/T(ort)/FT/Tx\
        /V(Berlin)/Rect[72 660 300 680]/P \(page) 0 R/F 4>>
        """)
        b.fill(parent, "<</T(adresse)/Kids[\(strasse) 0 R \(ort) 0 R]>>")
        b.fill(page, "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]/Resources<<>>"
            + "/Annots[\(strasse) 0 R \(ort) 0 R]>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let acro = b.addObject("<</Fields[\(parent) 0 R]/DA(/Helv 0 Tf 0 g)>>")
        let root = b.addObject(
            "<</Type/Catalog/Pages \(pages) 0 R/AcroForm \(acro) 0 R>>")
        return try b.write(rootObject: root, prefix: "formtree")
    }

    /// Unsigniertes Signaturfeld (/FT /Sig) – prüft die Signatur-Erfassung,
    /// ohne eine echte Signatur zu fälschen.
    static func signatureFieldPDF() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let page = b.reserveNumber()
        let field = b.addObject("""
        <</Type/Annot/Subtype/Widget/T(sig1)/FT/Sig/Rect[72 600 300 660]\
        /P \(page) 0 R/F 4>>
        """)
        b.fill(page, "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]/Resources<<>>"
            + "/Annots[\(field) 0 R]>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let acro = b.addObject("<</Fields[\(field) 0 R]/SigFlags 3>>")
        let root = b.addObject(
            "<</Type/Catalog/Pages \(pages) 0 R/AcroForm \(acro) 0 R>>")
        return try b.write(rootObject: root, prefix: "sigfield")
    }

    /// Zweistufige Outline-Hierarchie mit auflösbaren Zielen.
    static func nestedOutlinePDF() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let outlines = b.reserveNumber()
        let top = b.reserveNumber()
        let child = b.reserveNumber()

        var kids: [Int] = []
        for _ in 0..<2 {
            kids.append(b.addObject(
                "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]/Resources<<>>>>"))
        }
        b.fill(pages, "<</Type/Pages/Kids[\(kids[0]) 0 R \(kids[1]) 0 R]/Count 2>>")
        b.fill(top, """
        <</Title(Kapitel 1)/Parent \(outlines) 0 R/Dest[\(kids[0]) 0 R/Fit]\
        /First \(child) 0 R/Last \(child) 0 R/Count 1>>
        """)
        b.fill(child, "<</Title(Abschnitt 1.1)/Parent \(top) 0 R"
            + "/Dest[\(kids[1]) 0 R/Fit]>>")
        b.fill(outlines, "<</Type/Outlines/First \(top) 0 R/Last \(top) 0 R/Count 2>>")
        let root = b.addObject(
            "<</Type/Catalog/Pages \(pages) 0 R/Outlines \(outlines) 0 R>>")
        return try b.write(rootObject: root, prefix: "nestedoutline")
    }

    /// Alias auf die bestehende Outline-/Internal-Link-Fixture.
    static func outlineLinkPDF() throws -> URL {
        try outlinedWithInternalLinkPDF()
    }


    // MARK: - Masterplan Findings 13–15 / Schritt 1–4 – Bildidentitäts-Fixtures

    /// Ein JPEG mit definierter Größe und Farbe, als Bytes.
    private static func jpegBytes(width: Int, height: Int,
                                  hue: CGFloat) -> Data {
        let image = NSImage(size: CGSize(width: width, height: height))
        image.lockFocus()
        // Farbverlauf statt Volltonfläche: ein Volltonbild überlebt jede
        // Requantisierung identisch und würde Unterschiede verstecken.
        let gradient = NSGradient(starting: NSColor(hue: hue, saturation: 0.9,
                                                    brightness: 0.95, alpha: 1),
                                  ending: NSColor(hue: hue, saturation: 0.2,
                                                  brightness: 0.35, alpha: 1))
        gradient?.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                       angle: 35)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: 0.95])
        else { return Data() }
        return jpeg
    }

    /// Der P0-Regressionsfall aus Finding 13:
    /// Seite 1 `/Im0` → Foto A, Seite 2 `/Im0` → Foto B – gleicher Resource-
    /// Name, VERSCHIEDENE Objekte. Ein namensbasiertes Replacement macht aus
    /// B eine Kopie von A.
    struct SameNameDifferentObjects {
        let url: URL
        let firstObjectNumber: Int
        let secondObjectNumber: Int
    }

    static func sameResourceNameDifferentObjectsPDF(pixels: Int = 600) throws
        -> SameNameDifferentObjects {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let content = "q 612 0 0 792 0 0 cm /Im0 Do Q"

        let jpegA = jpegBytes(width: pixels, height: pixels, hue: 0.02)   // rot
        let jpegB = jpegBytes(width: pixels, height: pixels, hue: 0.58)   // blau

        let imageA = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/DCTDecode", data: jpegA)
        let imageB = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/DCTDecode", data: jpegB)

        let contentA = b.addStream(dictionary: "", content: content)
        let contentB = b.addStream(dictionary: "", content: content)
        // Getrennte Resource-Dictionaries, gleicher Name /Im0.
        let resA = b.addObject("<</XObject<</Im0 \(imageA) 0 R>>>>")
        let resB = b.addObject("<</XObject<</Im0 \(imageB) 0 R>>>>")
        let pageA = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resA) 0 R/Contents \(contentA) 0 R>>")
        let pageB = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resB) 0 R/Contents \(contentB) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(pageA) 0 R \(pageB) 0 R]/Count 2>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")

        return SameNameDifferentObjects(
            url: try b.write(rootObject: root, prefix: "samename"),
            firstObjectNumber: imageA,
            secondObjectNumber: imageB)
    }

    /// EIN Bildobjekt, auf zwei Seiten platziert (geteiltes XObject).
    /// Muss genau eine Objektidentität mit zwei Platzierungen ergeben.
    static func sharedImageObjectPDF(pixels: Int = 600) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let content = "q 612 0 0 792 0 0 cm /Im0 Do Q"
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/DCTDecode",
            data: jpegBytes(width: pixels, height: pixels, hue: 0.33))
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let c1 = b.addStream(dictionary: "", content: content)
        let c2 = b.addStream(dictionary: "", content: content)
        let p1 = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(c1) 0 R>>")
        let p2 = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(c2) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(p1) 0 R \(p2) 0 R]/Count 2>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "sharedobj")
    }

    /// Bild mit weicher Maske (/SMask) – darf niemals ersetzt werden.
    static func softMaskedImagePDF(pixels: Int = 600) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        // Alphakanal als eigenständiges Graustufenbild.
        var maskBytes = Data(count: pixels * pixels)
        for i in 0..<(pixels * pixels) {
            maskBytes[i] = UInt8((i / pixels) * 255 / max(pixels - 1, 1))
        }
        let mask = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceGray",
            data: maskBytes)
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/DCTDecode/SMask \(mask) 0 R",
            data: jpegBytes(width: pixels, height: pixels, hue: 0.75))
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(dictionary: "",
                                  content: "q 612 0 0 792 0 0 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "smask")
    }

    /// Bild mit /Decode-Array (invertierte Tonwerte) – nicht ersetzbar.
    static func decodeArrayImagePDF(pixels: Int = 600) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/DCTDecode/Decode[1 0 1 0 1 0]",
            data: jpegBytes(width: pixels, height: pixels, hue: 0.12))
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(dictionary: "",
                                  content: "q 612 0 0 792 0 0 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "decodearray")
    }

    /// Bild mit einem Filter, für den es keinen XObject-Decoder gibt.
    /// Muss deterministisch übersprungen werden – früher wurde stattdessen
    /// die ganze Seite gerendert und als Bild eingesetzt (Finding 15).
    ///
    /// Phase V2-3c (§9.10): CCITTFaxDecode ist als EINGANG inzwischen
    /// dekodierbar (Bilevel-Race) – diese Fixture bleibt trotzdem
    /// untransformierbar, weil sie als Bild schlicht ungültig ist:
    /// BitsPerComponent 8 statt 1 und DecodeParms ohne /K. Der Katalog
    /// verweigert beides deterministisch.
    static func unsupportedFilterImagePDF(pixels: Int = 600) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceGray"
                + "/Filter/CCITTFaxDecode",
            data: Data(repeating: 0x42, count: 4096))
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(dictionary: "",
                                  content: "q 612 0 0 792 0 0 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "jpx")
    }

    // MARK: - JPX-Codestream-Bytes (Phase 4b)

    /// Base64 eingebackene Codestreams (opj_compress, OpenJPEG 2.5.4) –
    /// deterministisch, Tests brauchen kein externes Tool.
    private static func jpxBase64(_ source: String) -> Data {
        Data(base64Encoded: source, options: [.ignoreUnknownCharacters])!
    }

    /// 240×180 RGB, verlustbehaftet (4683 Bytes).
    private static let jpxPhotoRGBLossyBase64 =
        "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"

    /// 128×96 Grau, verlustfrei (1755 Bytes).
    private static let jpxGrayLosslessBase64 =
        "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"

    /// 96×64 Grau 16-bit, verlustfrei (3408 Bytes).
    private static let jpxGray16BitLosslessBase64 =
        "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" +
        "LsKdEjJX1CRuTQOXkGDjt/vxyBZVS3R26Ip6boRDryl02ifnPIq3TWPMMcpe+DAPu/n3Lo68atFSoO2kEmZ4zwxtl5t8+jRmNzKq" +
        "82+fRozG5lVebfPo0ZjcyqvNvn0aMxuZVXm3z6NGY3Mqrzb6FhiI9Si80OOIvQ4UMgY8PcYDf5YjhcJj7TGSJiYh7uKJ644zSLob" +
        "goxktC7RFLZuZrSaYrE5kyO//hFtL6qvTyiFjVN3r/9Mb93KuZgAAAAAAQADAAAAAAADzAyAAAAAAA0UMoAAAAAANFDKAAAAAADR" +
        "QygAAAAAA0UMoAAAAAANgDSSSSShiZEL4e6SCdlzyEBu+OHRQF1FAXUUBdRQEqTVuc+phJhkHQ8oh05jpRXwHE1fU3bnf3vaLVZc" +
        "epq+pu3O/ve0Wqy49TV9Tdud/e9otVlx6mr6m7c7+97RarLj1NX1N253972i1WXHqavqbtzv73tFqyXoR2vC4c6fIAAawVXlDCnv" +
        "b5d/zH7p/vvvvvvvvvvvlKMtLNJn7777777775SjLSzSZ++++++++++Uoy0s0mfvvvvvvvvvlKMtLNJn7777777775SjLSzSZ+++" +
        "+++++++Uoy0s0mfvvvvvvvvvlJ0Od+/3d3d3b4G1hD9SUm3yugozrb0X3pNCWZFkV044zSiS7YiFHPcKrV28yrIsiyLIrpxxmlEl" +
        "2xEKOe4VWrt5lWRZFkWRXTjjNKJLtiIUc9wqtXbzKsiyLIsiunHGaUSXbEQo57hVau3mVZFkWRZFdOOM0oku2IhRz3Cq1dvMqyLI" +
        "siyK6ccZpRJdsRCjnuFVq7eZVkWRZFkV04h0Tjfw1NlK8jd+mc9CKVSnk+EfsiDIZH6IAN8b43xvhXumyGpGp7ppid3kyGR+iADf" +
        "G+N8b4V7pshqRqe6aYnd5MhkfogA3xvjfG+Fe6bIakanummJ3eTIZH6IAN8b43xvhXumyGpGp7ppid3kyGR+iADfG+N8b4V7pshq" +
        "Rqe6aYnd5MhkfogA3xvjfG+Fe6bIakanummJ3eTIZH6IAN8b43xvhXumyGpGp8T1UcxC3VxApZ19iE767VkspjWpDUjUjUiX7hUN" +
        "SNSNSJfuFQ1I1Iyx2l5UjUjUjUiX7hUNSNSNSJfuFQ1I1Iyx2l5UjUjUjUiX7hUNSNSNSJfuFQ1I1Iyx2l5UjUjUjUiX7hUNSNSN" +
        "SJfuFQ1I1Iyx2l5UjUjUjUiX7hUNSNSNSJfuFQ1I1Iyx2l5UjUjUjUiX7hUNSNSNSJfuFQ1I1Iyx2l5UjUjUjUiX7hUNSNSNSJfu" +
        "FQ1I1Iyw1tsjV2rGNu1vrtWMbdrfXau/Ds+TqUK3dsvLeAQGZY2uVk6vN8/mzO0lnOit3k4u0DFODE3fmAUUyJxOuNah7V1P5Jcv" +
        "yQx7bAafggaqXNoGQkymJaWcnQEyF3mgAVk6OIL1YbgmHp5wo+Nt23Z6wAuX3u+Je5ype/nNvYmu4lbkyFXtrfb3l1OXpGm204rd" +
        "EACoBDwx2HfwFCuBcFnU63tT7RxACoBDwx2HfwFCuBVOj1tMXdlXT6J9+VzcEm3NdVBXp5SljHb3HJInPC92W4I//sdMHfvudDY3" +
        "fSJVM2yT0REWST0PAExfAgMvJQGYAvNr/f9YNoaGLbrwCMzQDVSermRhKVcpG5SNykWNLokZFWbeTTVH0yAQiMu0RkIQv+zqr9EZ" +
        "dojIQhf9nVX6Iy7RGQhC/1nVX6Iy7RGQhC/7Oqv0Rl2iMhCF/zOqv0Rl2iMhCF/2dVfojLtEUNIqABQ/q89sPBC/7Oqv0RqQV5FR" +
        "9Mf536I1IK8io+mP879EakFeRUfTH+d+iNSCvIqPpj/O/RGpBXkVH0x/nfojUgryKj6Y/x36I1ICZ+yMMl4gHFc013oiv7O/RGXa" +
        "IyEIX/Z1V+iMu0RkIQv+zqr9EZdojIQhf9nVX6Iy7RGQhC/7Oqv0Rl2iMhCF/zOqv0Rl2iMhCF/2dVfojLtEUNIqABQ/q8oUkIX/" +
        "M6q/RGpBXkVH0x/nfojUgryKj6Y/zv0RqQV5FR9Mf536I1IK8io+mP8d+iNSCvIqPpj/HfojUgryKj6Y/x36I1ICZ+yMMl4f50Or" +
        "b0MWJuxvbLqyWa2mmggHbp7g7IihB26e4OyIoQdunuDsiKEHbp7g7IihB26e4OyIoQdurEdunRdny0ia70RX9nLU5ZpM4Y9M/KTz" +
        "0LiJxE3StTAyZwx6Z+UnnoXETiJulamBkzhj0z8pPPQuInETdK1MDJnDHpn5SeehcROIm6VqYGTOGPTPyk89C4icRN0rUwMmcMem" +
        "flJ56FxE4ibpWpgZM4Y9M/KScTgAALqys4qpA7n/f//Z"

    /// JPXDecode-Bild mit BYTES, die kein Codestream sind (Phase 4b).
    /// Die Capability ist seit dem OpenJPEG-Eingangsdecoder .safe; die
    /// Dekodierung selbst scheitert deterministisch (KeepReason.decodeFailed)
    /// – der Filter bleibt JPXDecode, es wird nichts erfunden.
    static func corruptJpxImagePDF(pixels: Int = 600) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/JPXDecode",
            data: Data(repeating: 0x42, count: 4096))
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(dictionary: "",
                                  content: "q 612 0 0 792 0 0 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "jpxcorrupt")
    }

    // MARK: - Phase 4b – JPX-Eingabefixtures (echte JPEG-2000-Codestreams)

    /// Die JPX-Codestreams sind EINMALIG mit opj_compress (OpenJPEG 2.5.4,
    /// /tmp/opencode/pdftools-vendor/openjpeg-universal) erzeugt und als
    /// Base64 eingebacken – deterministisch, ohne externe Tool-Abhängigkeit
    /// der Tests. Quell-Hashes (SHA-256):
    ///   photoRGBLossy      240×180, 4683 B, q=45 dB, 9/7 (irreversibel)
    ///   grayLossless       1bb1a828… (1755 B, reversibel 5/3)
    ///   gray16BitLossless  0d7ead93… (3408 B, reversibel 5/3, maxval 65535)
    enum JPXFixtureKind {
        /// 240×180, 8-bit RGB, verlustbehaftet – fotoreifer Verlauf mit Kanten.
        case photoRGBLossy
        /// 128×96, 8-bit Grau, verlustfrei – textartiges Balkenmuster
        /// (Zeile y%8 < 5 → 255, sonst 40; linker Balken 30).
        case grayLossless
        /// 96×64, 16-bit Grau, verlustfrei – Horizontalverlauf in der
        /// oberen Halbbeite, XOR 0x00FF in der unteren.
        case gray16BitLossless
        /// 700×700-Dummy: Bytes ohne gültigen Codestream (0x42-Füllung).
        case corrupt

        var pixelWidth: Int {
            switch self {
            case .photoRGBLossy: return 240
            case .grayLossless: return 128
            case .gray16BitLossless: return 96
            case .corrupt: return 700
            }
        }

        var pixelHeight: Int {
            switch self {
            case .photoRGBLossy: return 180
            case .grayLossless: return 96
            case .gray16BitLossless: return 64
            case .corrupt: return 700
            }
        }

        /// /BitsPerComponent des Bilddictionarys – laut ISO 32000 für
        /// JPXDecode stets 8, auch bei 16-bit-Codestreams (die Präzision
        /// steht allein im Codestream).
        var bitsPerComponent: Int { 8 }

        var colorSpaceName: String {
            switch self {
            case .photoRGBLossy: return "/DeviceRGB"
            case .grayLossless, .gray16BitLossless: return "/DeviceGray"
            case .corrupt: return "/DeviceRGB"
            }
        }

        var streamData: Data {
            switch self {
            case .photoRGBLossy: return jpxBase64(jpxPhotoRGBLossyBase64)
            case .grayLossless: return jpxBase64(jpxGrayLosslessBase64)
            case .gray16BitLossless: return jpxBase64(jpxGray16BitLosslessBase64)
            case .corrupt: return Data(repeating: 0x42, count: 4096)
            }
        }
    }

    /// Seite mit EINEM /JPXDecode-Bild, seitenfüllend auf `placedWidth`
    /// pt platziert. DPI = Pixel / Platziert * 72: 240 px auf 60 pt ergeben
    /// 288 DPI (Budget überschritten), auf 240 pt genau 72 DPI (im Budget).
    static func jpxImagePDF(kind: JPXFixtureKind, placedWidth: CGFloat) throws -> URL {
        let w = kind.pixelWidth, h = kind.pixelHeight
        let placedHeight = placedWidth * CGFloat(h) / CGFloat(w)
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(w)"
                + "/Height \(h)/BitsPerComponent \(kind.bitsPerComponent)"
                + "/ColorSpace\(kind.colorSpaceName)/Filter/JPXDecode",
            data: kind.streamData)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(dictionary: "",
            content: "q \(placedWidth) 0 0 \(placedHeight) 0 0 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 \(placedWidth) \(placedHeight)]"
            + "/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "jpx-\(kind.pixelWidth)x\(kind.pixelHeight)")
    }

    /// Unkomprimiertes RGB-Bild (kein Filter) – muss über den echten
    /// Stream dekodiert werden, nicht über einen Seitenrender.
    static func flateImagePDF(pixels: Int = 400) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var raw = Data(count: pixels * pixels * 3)
        for y in 0..<pixels {
            for x in 0..<pixels {
                let i = (y * pixels + x) * 3
                raw[i] = UInt8(x * 255 / max(pixels - 1, 1))
                raw[i + 1] = UInt8(y * 255 / max(pixels - 1, 1))
                raw[i + 2] = 128
            }
        }
        guard let deflated = ImageProcessor.flate(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/FlateDecode", data: deflated)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        // Klein platziert → hohe effektive DPI → Verkleinerung erwartet.
        let content = b.addStream(dictionary: "",
                                  content: "q 100 0 0 100 20 20 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "flateimg")
    }


    /// Screenshot-artige Grafik: wenige Volltonflächen, harte Kanten.
    /// Der `ImageClassifier` erkennt sie über den geringen Farbanteil als
    /// `.graphics` – JPEG würde hier sichtbare Artefakte an den Kanten
    /// erzeugen, deshalb ist sie die Fixture für die Graphics-Politik.
    static func screenshotLikePDF(pixels: Int = 1400) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()

        var raw = Data(count: pixels * pixels * 3)
        // Vier Volltonblöcke plus ein Raster – wenige distinkte Farben.
        let palette: [(UInt8, UInt8, UInt8)] = [
            (250, 250, 250), (30, 90, 200), (240, 240, 240), (20, 20, 20)
        ]
        for y in 0..<pixels {
            for x in 0..<pixels {
                let block = (y < pixels / 2 ? 0 : 2) + (x < pixels / 2 ? 0 : 1)
                let color = palette[block]
                let i = (y * pixels + x) * 3
                raw[i] = color.0
                raw[i + 1] = color.1
                raw[i + 2] = color.2
            }
        }
        guard let deflated = ImageProcessor.flate(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/FlateDecode", data: deflated)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(dictionary: "",
                                  content: "q 400 0 0 400 50 200 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "screenshot")
    }

    /// Verlauf-Screenshot: Flachflächen + Textbalken + schmaler Gradient.
    /// Der Gradient trägt > 256 Farben (exakte Palette unmöglich), die
    /// dominanten Flach-/Text-Anteile halten die Grafik-Route (keine
    /// Farbreduktion im Smart-Pfad – die Fixture ist der Negativ- und
    /// Positivbeleg für das Small/Target-Gate der quantisierten Palette).
    ///
    /// Platzierung bewusst NICHT vollseitig (300 pt wie limitedPalettePDF):
    /// Ein ≥ 90-%-Vollbild würde die Scan-Regel (§8.4) ziehen und die
    /// Fixture liefe in den JPEG-Scan-Pfad statt in die Grafik-Route.
    static func gradientScreenshotPDF(pixels: Int = 1200,
                                      name: String = "gradient-screenshot") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()

        var raw = Data(count: pixels * pixels * 3)
        raw.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            guard let p = buf.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            // Schmaler Verlauf unten (12 %): Rot-Rampe + Grün-Modulation.
            let gradientTop = pixels * 88 / 100
            for y in 0..<pixels {
                for x in 0..<pixels {
                    let i = (y * pixels + x) * 3
                    if y >= gradientTop {
                        p[i] = UInt8(x * 255 / max(pixels - 1, 1))
                        p[i + 1] = UInt8((y - gradientTop) * 64
                            / max(pixels - gradientTop - 1, 1))
                        p[i + 2] = 128
                    } else if (y / 24) % 2 == 0 && (x % 96) < 60 {
                        // Textbalken (schwarz auf papierweiß).
                        p[i] = 20; p[i + 1] = 20; p[i + 2] = 20
                    } else {
                        p[i] = 250; p[i + 1] = 250; p[i + 2] = 250
                    }
                }
            }
        }
        guard let deflated = ImageProcessor.flate(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/FlateDecode", data: deflated)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        // Klein platziert (300 pt, DPI ≈ 288): keine Scan-Seite, aber alle
        // Presets verkleinern (Smart-Ziel 220, Small-Ziel 110 DPI).
        let content = b.addStream(dictionary: "",
                                  content: "q 300 0 0 300 150 200 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }


    // MARK: - V2-3b (Masterplan §9.6) – Exact-Palette-Fixtures

    /// Screenshot-artige Grafik mit 6 Volltonfarben in 5×5-Kacheln (≤ 256).
    ///
    /// Zwei bewusste Konstruktionsentscheidungen:
    ///   • Platzierung 288 pt → Effective DPI exakt 300 → Smart-Ziel exakt
    ///     die halbe Kantenlänge (1200 → 600). Der Interpolator resampelt
    ///     mit EINER Phase – die Kantenmischfarben bleiben wenige und die
    ///     Palette (Kacheln + Mischfarben) bleibt sicher unter 256.
    ///   • Die OBERSTE Kachelzeile ist bewusst CHROMATISCH (blau/rot): Der
    ///     bestehende `ImageClassifier` sampelt für seine Chroma- und
    ///     Unique-Mittel die oberste Bildzeile – ein Grau-Start würde das
    ///     Bild als Graustufen einstufen und die Kandidaten in die Grau-
    ///     Konvertierung zwingen. Flächige 2D-Kacheln halten zudem das
    ///     ORIGINAL-Flate fern vom informationstheoretischen Minimum.
    static func limitedPalettePDF(pixels: Int = 1200,
                                  name: String = "limited-palette") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()

        let palette: [(UInt8, UInt8, UInt8)] = [
            (250, 250, 250), (30, 90, 200), (20, 20, 20),
            (200, 60, 60), (60, 160, 60), (230, 180, 40)
        ]
        // 5×5-Kachellayout: Die oberste Kachelzeile ist bewusst CHROMATISCH
        // (blau … rot) und auf ≤ 4 distinkte Stichproben-Keys beschränkt –
        // der bestehende `ImageClassifier` sampelt für Unique-Ratio und
        // Chroma-Mittel die oberste Bildzeile. Alle 6 Farben verteilt.
        let layout = [
            [1, 1, 1, 1, 3],
            [1, 2, 4, 5, 0],
            [3, 4, 5, 0, 1],
            [4, 5, 0, 1, 2],
            [5, 0, 1, 2, 3],
        ]
        var raw = Data(count: pixels * pixels * 3)
        raw.withUnsafeMutableBytes { base -> Void in
            let p = base.bindMemory(to: UInt8.self)
            let cell = max(1, pixels / 5)
            for y in 0..<pixels {
                for x in 0..<pixels {
                    let color = palette[layout[min(y / cell, 4)][min(x / cell, 4)]]
                    let i = (y * pixels + x) * 3
                    p[i] = color.0; p[i + 1] = color.1; p[i + 2] = color.2
                }
            }
        }
        guard let deflated = ImageProcessor.flate(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/FlateDecode", data: deflated)
        let content = b.addStream(dictionary: "",
                                  content: "q 288 0 0 288 50 250 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</XObject<</Im0 \(image) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    /// Grafik mit MEHR ALS 256 Farben: oben das Kachelmuster der
    /// Palette-Fixture, unten ein horizontaler Verlauf mit > 256 distinkten
    /// RGB-Farben. Die 64×64-Stichprobe des ImageClassifier sieht davon nur
    /// wenige Farben (Kacheln + schmaler Streifen) – das Bild bleibt in der
    /// Graphics-Sicht, der exakte Vollscan muss den Palette-Kandidaten
    /// verweigern (§9.6: > 256 Farben → kein Kandidat).
    static func manyColorsPDF(pixels: Int = 1200,
                              name: String = "many-colors") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()

        let palette: [(UInt8, UInt8, UInt8)] = [
            (250, 250, 250), (30, 90, 200), (240, 240, 240), (20, 20, 20)
        ]
        var raw = Data(count: pixels * pixels * 3)
        raw.withUnsafeMutableBytes { base -> Void in
            let p = base.bindMemory(to: UInt8.self)
            let gradientTop = pixels * 4 / 5
            let steps = 320   // > 256 distinkte Verlaufsfarben
            for y in 0..<pixels {
                for x in 0..<pixels {
                    let i = (y * pixels + x) * 3
                    if y >= gradientTop {
                        // Horizontaler Verlauf: je Spaltengruppe eine eigene
                        // Farbe – 320 distinkte RGB-Triplette.
                        let step = x * steps / pixels
                        p[i] = UInt8(40 + step % 200)
                        p[i + 1] = UInt8(30 + (step * 7) % 200)
                        p[i + 2] = UInt8(20 + (step * 13) % 200)
                    } else {
                        let block = (y < gradientTop / 2 ? 0 : 2)
                            + (x < pixels / 2 ? 0 : 1)
                        let color = palette[block]
                        p[i] = color.0; p[i + 1] = color.1; p[i + 2] = color.2
                    }
                }
            }
        }
        guard let deflated = ImageProcessor.flate(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/FlateDecode", data: deflated)
        let content = b.addStream(dictionary: "",
                                  content: "q 300 0 0 300 50 250 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</XObject<</Im0 \(image) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    /// Vertikaler Grau-Verlauf mit genau 250 Farben (≤ 256, bpc 8): Die
    /// Erstfund-Reihenfolge der Palette folgt der Zeilenfolge, der Index-
    /// Strom ist damit BYTEIDENTISCH zum Grauwert-Strom des Flate-
    /// Konkurrenten – der Palette-Kandidat trägt aber zusätzlich die
    /// 250-Byte-Palette und verliert den Race DETERMINISTISCH. Klein
    /// gehalten (Original ohne Prädiktor, Zeilenkonstanz), damit auch der
    /// Flate-Kandidat gegen das Original scheitert → KEEP.
    static func tinyGradientPalettePDF(pixels: Int = 250,
                                       name: String = "tiny-gradient") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var raw = Data(count: pixels * pixels * 3)
        raw.withUnsafeMutableBytes { base -> Void in
            let p = base.bindMemory(to: UInt8.self)
            for y in 0..<pixels {
                let value = UInt8(y * 255 / max(pixels - 1, 1))
                for x in 0..<pixels {
                    let i = (y * pixels + x) * 3
                    p[i] = value; p[i + 1] = value; p[i + 2] = value
                }
            }
        }
        guard let deflated = ImageProcessor.flate(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/FlateDecode", data: deflated)
        let content = b.addStream(dictionary: "",
                                  content: "q 100 0 0 100 50 250 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</XObject<</Im0 \(image) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    // MARK: - V2-2 (Masterplan §8) – Klassifikator-Fixtures

    /// Deterministisches Foto-artiges Rauschraster als Data (Gradient plus
    /// LCG-Rauschen – hoher Entropie-/Textur-Signalcharakter wie ein Foto).
    private static func noisyGradientPixels(pixels: Int) -> Data {
        var raw = Data(count: pixels * pixels * 3)
        raw.withUnsafeMutableBytes { base -> Void in
            let p = base.bindMemory(to: UInt8.self)
            var state: UInt32 = 0x9E3779B9
            for y in 0..<pixels {
                for x in 0..<pixels {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    let noise = UInt8(truncatingIfNeeded: state >> 24) % 24
                    let i = (y * pixels + x) * 3
                    p[i] = UInt8(max(0, min(255, x * 255 / max(1, pixels - 1) + Int(noise) - 12)))
                    p[i + 1] = UInt8(max(0, min(255, y * 255 / max(1, pixels - 1) + Int(noise) - 12)))
                    p[i + 2] = UInt8(max(0, min(255, (x + y) * 255 / max(1, 2 * pixels - 2)
                                                + Int(noise) - 12)))
                }
            }
        }
        return raw
    }

    /// Vollflächige „Scan“-Seite: Ein Foto-artiges Raster deckt die GANZE
    /// Seite, kein Text, keine Vektoren. `PageScanAnalyzer` muss daraus
    /// rasterScan lesen – Fixture für die Scan-Erkennung (§8.4).
    static func scanPagePDF(pixels: Int = 850, name: String = "scan-page") throws -> URL {
        try fullPageRasterPDF(pixels: pixels, name: name, extraContent: "")
    }

    /// Dieselbe Scan-Seite MIT unsichtbarem OCR-Overlay (`3 Tr`) –
    /// rasterScanWithOCR-Fixture für die OCR-Heuristik (§8.4).
    static func ocrOverlayScanPDF(pixels: Int = 850,
                                  name: String = "ocr-scan") throws -> URL {
        let ocr = "BT /Fix 12 Tf 3 Tr 1 0 0 1 72 720 Tm "
            + "(Selektierbarer OCR-Text der Scan-Erkennung) Tj ET"
        return try fullPageRasterPDF(pixels: pixels, name: name, extraContent: ocr)
    }

    /// Gemeinsamer Rumpf der Scan-Fixtures: Vollbild-Raster, optionaler
    /// Text-Abschnitt, Helvetica-Font als Standard-Type1-Ressource.
    private static func fullPageRasterPDF(pixels: Int,
                                          name: String,
                                          extraContent: String) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/FlateDecode",
            data: ImageProcessor.flate(noisyGradientPixels(pixels: pixels))!)
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>"
            + "/Font<</Fix \(font) 0 R>>>>")
        let content = b.addStream(
            dictionary: "",
            content: "q 612 0 0 792 0 0 cm /Im0 Do Q " + extraContent)
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    /// Mixed-Page (§5.4): Foto auf rund 40 % der Seitenfläche PLUS
    /// sichtbarer born-digitaler Text → `mixed`.
    static func mixedPagePDF(name: String = "mixed-page") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let pixels = 600
        let jpeg = jpegBytes(width: pixels, height: pixels, hue: 0.55)
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/DCTDecode", data: jpeg)
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>"
            + "/Font<</Fix \(font) 0 R>>>>")
        // 400 × 450 pt auf 612 × 792 pt ≈ 37 % Deckung – genug für die
        // Mixed-Schwelle (≥ 30 %), zu wenig für den Scan-Kandidaten (≥ 90 %).
        let content = b.addStream(
            dictionary: "",
            content: "q 400 0 0 450 106 250 cm /Im0 Do Q "
                + "BT /Fix 14 Tf 1 0 0 1 60 60 Tm (Born-digital Text) Tj ET")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }


    /// Formularfeld mit UTF-16BE-kodiertem Namen und Wert (BOM + NUL-Bytes)
    /// sowie Umlauten. Solche Strings sind in echten Formularen die Regel;
    /// eine NUL-terminierte Bridge-API schneidet sie nach zwei Bytes ab.
    static func utf16FormFieldPDF() throws -> URL {
        func utf16Literal(_ text: String) -> String {
            // PDF-Hexstring mit UTF-16BE-BOM – so schreiben es echte
            // Formular-Werkzeuge.
            var hex = "FEFF"
            for unit in Array(text.utf16) {
                hex += String(format: "%04X", unit)
            }
            return "<\(hex)>"
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let page = b.reserveNumber()
        let field = b.addObject("""
        <</Type/Annot/Subtype/Widget/T\(utf16Literal("Straße"))/FT/Tx\
        /V\(utf16Literal("Grüße aus München"))/Rect[72 700 300 720]\
        /P \(page) 0 R/F 4>>
        """)
        b.fill(page, "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]/Resources<<>>"
            + "/Annots[\(field) 0 R]>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let acro = b.addObject("<</Fields[\(field) 0 R]>>")
        let root = b.addObject(
            "<</Type/Catalog/Pages \(pages) 0 R/AcroForm \(acro) 0 R>>")
        return try b.write(rootObject: root, prefix: "utf16form")
    }


    /// Foto mit BEKANNTER Platzierung: `pixels` Bildpunkte auf `placedPoints`
    /// PDF-Punkte. Damit ist die effektive DPI exakt berechenbar –
    /// Grundlage aller DPI-Regel-Tests.
    static func placedPhotoPDF(pixels: Int = 2000,
                               placedPoints: Double = 400) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let jpeg = jpegBytes(width: pixels, height: pixels, hue: 0.08)
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/DCTDecode", data: jpeg)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let size = Int(placedPoints)
        let content = b.addStream(
            dictionary: "",
            content: "q \(size) 0 0 \(size) 40 40 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "placedphoto")
    }

    /// Foto-TYPISCHE Signatur (V2-Klassifikator, §8.3): wie `placedPhotoPDF`,
    /// aber mit weicher Mehrfrequenz-Modulation über dem Gefälle – breite
    /// Luminanzverteilung, Textur-Kacheln ohne Sobel-Kanten. Der reine
    /// NSGradient-Verlauf ist auf Stichprobenauflösung flach/privilegiert
    /// (flat 1.0, texture 0.0) und liest sich als screenshot-Familie; Tests,
    /// die die FOTO-Route (DCT) festnageln, brauchen dieses Fixture.
    static func placedTexturedPhotoPDF(pixels: Int = 3000,
                                       placedPoints: Double = 400) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data
        else { throw CocoaError(.fileWriteUnknown) }
        let px = data.bindMemory(to: UInt8.self, capacity: pixels * pixels * 4)
        for y in 0..<pixels {
            let v = Double(y) / Double(pixels)
            for x in 0..<pixels {
                let u = Double(x) / Double(pixels)
                let luma = 0.06 + 0.86 * (0.6 * u + 0.4 * v)
                    + 0.10 * sin(2 * .pi * (3 * u + 2 * v))
                let chroma = 0.12 * sin(2 * .pi * (2 * u - 1.5 * v) + 0.6)
                let o = (y * pixels + x) * 4
                px[o] = UInt8(max(0, min(255, (luma + chroma) * 255).rounded()))
                px[o + 1] = UInt8(max(0, min(255, (luma + 0.3 * chroma) * 255).rounded()))
                px[o + 2] = UInt8(max(0, min(255, (luma - chroma) * 255).rounded()))
                px[o + 3] = 255
            }
        }
        let base = ctx.makeImage()
        guard let base,
              let jpeg = NSBitmapImageRep(cgImage: base)
                  .representation(using: .jpeg,
                                  properties: [.compressionFactor: 0.95])
        else { throw CocoaError(.fileWriteUnknown) }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/DCTDecode", data: jpeg)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let size = Int(placedPoints)
        let content = b.addStream(
            dictionary: "",
            content: "q \(size) 0 0 \(size) 40 40 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "placed-textured-photo")
    }


    /// Seite mit mehreren Standardschriften – deckt Font-Vielfalt ab, ohne
    /// echte Subset-Fonts einzubetten (die kann PDFKit nicht erzeugen).
    static func multipleFontsPDF() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let fonts = ["Helvetica", "Times-Roman", "Courier",
                     "Helvetica-Bold", "Times-Italic"]
        var fontRefs: [Int] = []
        for name in fonts {
            fontRefs.append(b.addObject(
                "<</Type/Font/Subtype/Type1/BaseFont/\(name)/Encoding/WinAnsiEncoding>>"))
        }
        var content = ""
        for (index, name) in fonts.enumerated() {
            content += "BT /F\(index) 14 Tf 72 \(720 - index * 30) Td "
                + "(Schriftprobe \(name)) Tj ET\n"
        }
        let contentRef = b.addStream(dictionary: "", content: content)
        let fontDict = fontRefs.enumerated()
            .map { "/F\($0.offset) \($0.element) 0 R" }
            .joined(separator: " ")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</Font<<\(fontDict)>>>>"
            + "/Contents \(contentRef) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "multifont")
    }

    /// Scan-Charakteristik: jede Seite besteht aus genau einem seitenfüllenden
    /// Graustufenbild, es gibt keinen Text. Genau das erwartet OCR später.
    static func scanLikePDF(pages pageCount: Int = 3, pixels: Int = 1200) throws -> URL {
        var b = RawPDFBuilder()
        let pagesRef = b.reserveNumber()
        var kids: [Int] = []

        for pageIndex in 0..<pageCount {
            // Papierweiß mit leichtem Grauverlauf und „Textzeilen" als
            // dunkle Bänder – genug Struktur für Klassifikation und Render.
            var raw = Data(count: pixels * pixels)
            for y in 0..<pixels {
                let isTextBand = (y / max(pixels / 40, 1)) % 3 == 0
                    && y > pixels / 10 && y < pixels * 9 / 10
                for x in 0..<pixels {
                    let background = 235 + (x * 12 / max(pixels, 1))
                    let value = isTextBand && x > pixels / 8 && x < pixels * 7 / 8
                        ? 60 + ((x + pageIndex) % 24)
                        : background
                    raw[y * pixels + x] = UInt8(min(255, value))
                }
            }
            guard let deflated = ImageProcessor.flate(raw) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let image = b.addStream(
                dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                    + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceGray"
                    + "/Filter/FlateDecode", data: deflated)
            let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
            let content = b.addStream(dictionary: "",
                                      content: "q 612 0 0 792 0 0 cm /Im0 Do Q")
            kids.append(b.addObject("<</Type/Page/Parent \(pagesRef) 0 R"
                + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R"
                + "/Contents \(content) 0 R>>"))
        }

        b.fill(pagesRef, "<</Type/Pages/Kids["
            + kids.map { "\($0) 0 R" }.joined(separator: " ")
            + "]/Count \(kids.count)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pagesRef) 0 R>>")
        return try b.write(rootObject: root, prefix: "scanlike")
    }


    /// Echter Vektortext über mehrere Absätze und Seiten.
    ///
    /// Es gab hier einmal eine PDFKit-Variante (`multiParagraphTextPDF`).
    /// Sie zeichnete den Text in ein Bitmap und verpackte es als Seite – das
    /// Ergebnis war eine BILD-Fixture ohne ein einziges extrahierbares
    /// Zeichen, obwohl Name und Kommentar „echter Vektortext" versprachen.
    /// Benutzt hat sie niemand; entfernt beim Aufräumen (Phase 10).
    ///
    /// Für Texterhalt-Nachweise braucht es Text, der auch nach dem
    /// Schreiben noch Text ist – deshalb hier der rohe Aufbau.
    static func rawMultiParagraphPDF(pages pageCount: Int = 2) throws -> URL {
        var b = RawPDFBuilder()
        let pagesRef = b.reserveNumber()
        let font = b.addObject(
            "<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>")
        var kids: [Int] = []
        for pageIndex in 0..<pageCount {
            var content = ""
            for paragraph in 0..<4 {
                let top = 720 - paragraph * 160
                content += "BT /F1 13 Tf 72 \(top) Td 16 TL "
                for line in 0..<6 {
                    content += "(Absatz \(paragraph + 1) Zeile \(line + 1) auf "
                        + "Seite \(pageIndex + 1) mit ausreichend Text.) Tj T* "
                }
                content += "ET\n"
            }
            let contentRef = b.addStream(dictionary: "", content: content)
            kids.append(b.addPage(parent: pagesRef,
                                  resources: "<</Font<</F1 \(font) 0 R>>>>",
                                  contents: contentRef))
        }
        b.fill(pagesRef, "<</Type/Pages/Kids["
            + kids.map { "\($0) 0 R" }.joined(separator: " ")
            + "]/Count \(kids.count)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pagesRef) 0 R>>")
        return try b.write(rootObject: root, prefix: "rawparagraphs")
    }

    /// Sehr kleine Schriftgrade – Grenzfall für Rasterung und OCR.
    static func rawTinyTextPDF() throws -> URL {
        var b = RawPDFBuilder()
        let pagesRef = b.reserveNumber()
        let font = b.addObject(
            "<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>")
        var content = ""
        for (index, size) in [4, 5, 6, 7, 8].enumerated() {
            content += "BT /F1 \(size) Tf 40 \(740 - index * 90) Td \(size + 2) TL "
            for line in 0..<8 {
                content += "(Kleingedrucktes in \(size) pt, Zeile \(line + 1): "
                    + "abcdefghijklmnopqrstuvwxyz 0123456789) Tj T* "
            }
            content += "ET\n"
        }
        let contentRef = b.addStream(dictionary: "", content: content)
        let page = b.addPage(parent: pagesRef,
                             resources: "<</Font<</F1 \(font) 0 R>>>>",
                             contents: contentRef)
        b.fill(pagesRef, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pagesRef) 0 R>>")
        return try b.write(rootObject: root, prefix: "rawtiny")
    }

    /// Text MIT externem Link – die PDFKit-Variante rastert die Seite und
    /// verliert damit den Text.
    static func rawExternalLinkPDF() throws -> URL {
        var b = RawPDFBuilder()
        let pagesRef = b.reserveNumber()
        let page = b.reserveNumber()
        let font = b.addObject(
            "<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>")
        let content = b.addStream(dictionary: "", content:
            "BT /F1 14 Tf 72 700 Td (Weiterfuehrende Informationen online) Tj ET")
        let link = b.addObject("<</Type/Annot/Subtype/Link/Rect[72 695 400 720]"
            + "/Border[0 0 0]/A<</S/URI/URI(https://example.com)>>>>")
        b.fillPage(page, parent: pagesRef,
                   resources: "<</Font<</F1 \(font) 0 R>>>>",
                   contents: content,
                   extra: "/Annots[\(link) 0 R]")
        b.fill(pagesRef, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pagesRef) 0 R>>")
        return try b.write(rootObject: root, prefix: "rawextlink")
    }


    /// Seite mit klar asymmetrischem Inhalt und definierter Eigenrotation.
    ///
    /// Asymmetrisch ist wesentlich: Ein symmetrisches Motiv sähe nach einer
    /// 90°-Drehung gleich aus und könnte einen Rotationsfehler verbergen.
    static func rotatedContentPDF(rotation: Int) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject(
            "<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>")
        // Balken oben links + Text – oben/unten und links/rechts unterscheidbar.
        let content = b.addStream(dictionary: "", content: """
        0 0 0.8 rg 40 700 250 60 re f
        0.9 0.1 0.1 rg 40 60 90 90 re f
        BT /F1 22 Tf 0 g 40 640 Td (OBEN LINKS) Tj ET
        BT /F1 14 Tf 300 100 Td (unten rechts) Tj ET
        """)
        let page = b.addPage(parent: pages,
                             resources: "<</Font<</F1 \(font) 0 R>>>>",
                             contents: content,
                             extra: "/Rotate \(rotation)")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "rotcontent")
    }

    /// Leere weiße Seite – Referenz für „Inhalt vollständig verloren".
    static func blankPagePDF() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let page = b.addPage(parent: pages)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "blank")
    }


    /// Dicht gefüllte, asymmetrische Seite – Referenz für die Empfindlichkeit
    /// des Render-Diffs. Eine überwiegend weiße Seite liefert bei einer
    /// Fehldrehung nur ein schwaches Signal; hier soll es unübersehbar sein.
    static func densePagePDF(rotation: Int = 0) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject(
            "<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>")
        var content = ""
        // Farbstreifen mit nach unten abnehmender Breite: oben/unten und
        // links/rechts sind eindeutig unterscheidbar.
        for row in 0..<16 {
            let y = 740 - row * 45
            let width = 520 - row * 28
            let shade = Double(row) / 16.0
            content += String(format: "%.2f %.2f 0.7 rg 46 %d %d 30 re f\n",
                              shade, 1 - shade, y, max(width, 40))
        }
        for row in 0..<16 {
            content += "BT /F1 11 Tf 0 g 60 \(748 - row * 45) Td "
                + "(Zeile \(row + 1) – dicht gefuellte Referenzseite) Tj ET\n"
        }
        let contentRef = b.addStream(dictionary: "", content: content)
        let page = b.addPage(parent: pages,
                             resources: "<</Font<</F1 \(font) 0 R>>>>",
                             contents: contentRef,
                             extra: "/Rotate \(rotation)")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "dense")
    }

    // MARK: - V2-7 (Masterplan §13) – MRC-Fixtures

    /// Deterministisches „Scan“-Raster: dunkler Text auf hellem Papier
    /// (§13.4), Textur-Line-Art (Regel) plus EINER farbigen Photo-Region.
    /// Kein Zufall – jede Zeile folgt einer festen Wortbreitenfolge.
    ///
    /// `textLuma` steuert die Tinten-Dunkelheit: 30 = Normalfall (maske
    /// trägt schwarze Tinte fast verlustfrei), 180 = hellgraue Tinte für den
    /// QA-Fallback-Test (die schwarze Masken-Tinte verschiebt die Dunkel-
    /// abdeckung messbar → inkDelta-Gate greift).
    static func mrcScanRaster(width: Int = 850, height: Int = 1100,
                              textLuma: UInt8 = 30,
                              withPhoto: Bool = true,
                              withRule: Bool = true) -> Data {
        var raw = Data(count: width * height * 3)
        raw.withUnsafeMutableBytes { (rawBase: UnsafeMutableRawBufferPointer) in
            let p = rawBase.bindMemory(to: UInt8.self)
            func setPixel(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
                let i = (y * width + x) * 3
                p[i] = r; p[i + 1] = g; p[i + 2] = b
            }
            // Papier: 250.
            for i in 0..<(width * height) {
                p[i * 3] = 250; p[i * 3 + 1] = 250; p[i * 3 + 2] = 250
            }
            // Textzeilen: deterministische Wortbreiten, Wortlücken,
            // Buchstaben-Lücken alle 9 px (kleine CCs). Zeilen außerhalb des
            // Rasters entfallen (kleine Rastermaße).
            let wordWidths = [46, 92, 64, 118, 54, 84, 38, 104]
            var lineY = min(80, height / 4)
            var wordIndex = 0
            while lineY + 16 < min(560, height) {
                var x = 70
                var index = wordIndex
                while x + 40 < width - 80 {
                    let wordWidth = wordWidths[index % wordWidths.count]
                    index += 1
                    guard x + wordWidth < width - 60 else { break }
                    for wx in x..<min(x + wordWidth, width) {
                        // Lücken alle 9 px → Buchstaben-CCs statt Platte.
                        if (wx - x) % 9 != 8 {
                            for wy in lineY..<min(lineY + 16, height) {
                                setPixel(wx, wy, textLuma, textLuma, textLuma)
                            }
                        }
                    }
                    x += wordWidth + 14
                }
                lineY += 36
                wordIndex += 1
            }
            // Regel (Line-Art): durchgehende dünne Linie.
            if withRule, 622 < height {
                for x in 70..<(width - 70) {
                    for dy in 0..<3 {
                        setPixel(x, 620 + dy, textLuma, textLuma, textLuma)
                    }
                }
            }
            // Photo-Region: kräftiger Blau-Verlauf plus LCG-Rauschen
            // (Chroma-Signal für die Photo-Erkennung, §13.5). Clamping gegen
            // kleine Rastermaße (leere Bereiche sind erlaubt).
            if withPhoto {
                let x0 = width / 2, x1 = width - 50
                let y0 = min(700, height / 2), y1 = min(1000, height - 2)
                guard x0 < x1, y0 < y1 else { return }
                var state: UInt32 = 0x9E3779B9
                for y in y0..<min(y1, height) {
                    for x in x0..<min(x1, width) {
                        state = state &* 1_664_525 &+ 1_013_904_223
                        let noise = Int(truncatingIfNeeded: state >> 24) % 30
                        let r = UInt8(clamping: 60 + (x - x0) * 60 / max(x1 - x0, 1) + noise)
                        let g = UInt8(clamping: 90 + (y - y0) * 60 / max(y1 - y0, 1) + noise)
                        let b = UInt8(clamping: 170 - (x - x0) * 40 / max(x1 - x0, 1) + noise)
                        setPixel(x, y, r, g, b)
                    }
                }
            }
        }
        return raw
    }

    /// Das Scan-Raster als CGImage (für direkte Segmentier-Tests).
    static func mrcScanImage(width: Int = 850, height: Int = 1100,
                             textLuma: UInt8 = 30,
                             withPhoto: Bool = true,
                             withRule: Bool = true) throws -> CGImage {
        let raw = mrcScanRaster(width: width, height: height,
                                textLuma: textLuma, withPhoto: withPhoto,
                                withRule: withRule)
        guard let provider = CGDataProvider(data: raw as CFData) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 24,
                                  bytesPerRow: width * 3,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(
                                      rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return image
    }

    /// Vollflächige Scan-Seite mit dem MRC-Raster; optionaler unsichtbarer
    /// OCR-Overlay-Text (`3 Tr`) und/oder Link-Annotation.
    ///
    /// Der Raster-Draw folgt der üblichen Scan-Schreibweise
    /// `q <cm> /Im0 Do Q` – genau die Sequenz, die die MRC-Rekonstruktion
    /// (§13.7) ersetzt.
    static func mrcScanPagePDF(width: Int = 850, height: Int = 1100,
                               textLuma: UInt8 = 30,
                               withPhoto: Bool = true,
                               withOCR: Bool = false,
                               withLink: Bool = false,
                               name: String = "mrc-scan") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(width)"
                + "/Height \(height)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/FlateDecode",
            data: ImageProcessor.flate(mrcScanRaster(width: width, height: height,
                                                     textLuma: textLuma,
                                                     withPhoto: withPhoto))!)
        // Resources als EIGENES indirektes Objekt (wie in allen Fixtures) –
        // ein direktes Dict plus hängendem „0 R" wäre ein defektes Wörterbuch.
        var resourcesDict = "<</XObject<</Im0 \(image) 0 R>>>>"
        var contentExtra = ""
        var pageExtra = ""
        if withOCR {
            let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
            resourcesDict = "<</XObject<</Im0 \(image) 0 R>>"
                + "/Font<</Fix \(font) 0 R>>>>"
            contentExtra = "BT /Fix 12 Tf 3 Tr 1 0 0 1 72 720 Tm "
                + "(Selektierbarer OCR-Text der MRC-Erkennung) Tj ET"
        }
        if withLink {
            let action = b.addObject("<</Type/Action/S/URI"
                + "/URI(https://example.com/mrc)>>")
            let annotation = b.addObject("<</Type/Annot/Subtype/Link"
                + "/Rect[60 640 300 660]/Border[0 0 0]/A \(action) 0 R>>")
            pageExtra = "/Annots[\(annotation) 0 R]"
        }
        let resources = b.addObject(resourcesDict)
        let content = b.addStream(
            dictionary: "",
            content: "q 612 0 0 792 0 0 cm /Im0 Do Q " + contentExtra)
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R"
            + "/Contents \(content) 0 R"
            + (pageExtra.isEmpty ? "" : "/" + pageExtra.trimmingCharacters(
                in: CharacterSet(charactersIn: "/"))) + ">>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    /// Scan-Seite mit dominantem Vollbild-Raster PLUS kleinem Sekundärraster
    /// (Scope-Erweiterung §13.1): Nur der dominante Draw wird per MRC ersetzt,
    /// der Sekundär-Draw bleibt. `secondaryPoints` steuert die platzierte
    /// Kantenlänge des Sekundärbilds (60 pt ≈ 0.7 % Deckung → zugelassen;
    /// 220 pt ≈ 10 % → über `maximumSecondaryCoverage`, kein MRC).
    static func mrcScanPageWithSecondaryPDF(
        secondaryPoints: Double = 60,
        name: String = "mrc-scan-secondary") throws -> URL {
        let width = 850, height = 1100
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let dominant = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(width)"
                + "/Height \(height)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/FlateDecode",
            data: ImageProcessor.flate(mrcScanRaster(width: width, height: height))!)
        let small = 60
        let secondary = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(small)"
                + "/Height \(small)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/FlateDecode",
            data: ImageProcessor.flate(mrcScanRaster(width: small, height: small,
                                                     withPhoto: false,
                                                     withRule: false))!)
        let resources = b.addObject(
            "<</XObject<</Im0 \(dominant) 0 R/Im1 \(secondary) 0 R>>>>")
        let edge = String(format: "%.0f", secondaryPoints)
        let content = b.addStream(
            dictionary: "",
            content: "q 612 0 0 792 0 0 cm /Im0 Do Q "
                + "q \(edge) 0 0 \(edge) 480 680 cm /Im1 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

}

// MARK: - Phase 2b – Bilevel-Fixtures

extension PDFFixtures {

    /// Deterministisches „Textseiten"-Muster als 1-bit-Pixelfolge
    /// (Bit 1 = schwarz, MSB-first, rowBytes = (breite+7)/8). Textzeilen aus
    /// Wortblöcken (Rechtecke über mehrere Rasterzeilen) wie im Phase-2a-
    /// Funktionstest – wiederholte Formen und lange Weissläufe, damit G4 und
    /// Symbolkodierung etwas zu holen haben.
    static func bilevelPattern(width: Int, height: Int, seed: UInt32 = 20260830) -> Data {
        let rowBytes = (width + 7) / 8
        var image = [UInt8](repeating: 0, count: rowBytes * height)
        func fillRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            guard w > 0, h > 0 else { return }
            for row in y..<min(y + h, height) {
                for column in x..<min(x + w, width) {
                    image[row * rowBytes + (column >> 3)] |= UInt8(0x80 >> (column & 7))
                }
            }
        }
        var state = seed
        func random(_ bound: UInt32) -> Int {
            state = state &* 1103515245 &+ 12345
            return Int((state >> 16) % max(bound, 1))
        }
        // Textzeilen: Wortblöcke mit unterschiedlicher Breite und Höhe.
        var y = 40
        while y < height - 40 {
            var x = 60
            let lineHeight = 10 + random(4)
            while x < width - 60 {
                let wordWidth = 24 + random(70)
                fillRect(x, y, wordWidth, lineHeight)
                x += wordWidth + 12 + random(14)
            }
            y += lineHeight + 8
        }
        // Kopf- und Fusslinie als durchgehende Tinte.
        fillRect(60, 20, width - 120, 3)
        fillRect(60, height - 24, width - 120, 3)
        return Data(image)
    }

    /// Sparsames 1-bit-Muster (fast weiss, ein Tintenstreifen) in derselben
    /// Pixelfolge wie bilevelPattern. Auf solchen Bildern gewinnt G4 den
    /// Bilevel-Race deterministisch gegen JBIG2 (lange Weissläufe) – V2-3c
    /// nutzt es für die G4-Eingangs-Fixtures.
    static func bilevelSparsePattern(width: Int, height: Int) -> Data {
        let rowBytes = (width + 7) / 8
        var image = [UInt8](repeating: 0xFF, count: rowBytes * height)
        func inkRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            for row in y..<min(y + h, height) {
                for column in x..<min(x + w, width) {
                    image[row * rowBytes + (column >> 3)]
                        &= ~UInt8(0x80 >> (column & 7))
                }
            }
        }
        inkRect(width / 4, height / 2, width / 2, 6)
        return Data(image)
    }

    /// Echtes 1-bit-Bild (DeviceGray, BitsPerComponent 1) als UNKOMPRIMIERTER
    /// Stream – der Naiv-Scanner-Fall: riesiger Rohstrom, platziert klein
    /// (600 dpi wirksam). Der Bilevel-Race muss ihn mit G4/JBIG2 deutlich
    /// unterbieten.
    ///
    /// Das Muster ist in der Tintenkonvention (Bit 1 = schwarz); der Stream
    /// trägt PDF-Abtastwerte (0 = schwarz, 1 = weiss) und bekommt es
    /// deshalb byteweise invertiert – inklusive Zeilenpadbits, die so zu
    /// 1 (= weiss) werden.
    static func bilevelScanPDF(pixels: Int = 1728, rows: Int = 2339,
                               placedPoints: Double = 207,
                               name: String = "bilevel-scan") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let raw = bilevelPattern(width: pixels, height: rows).map { ~$0 }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(rows)/BitsPerComponent 1/ColorSpace/DeviceGray",
            data: Data(raw))
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(
            dictionary: "",
            content: String(format: "q %.2f 0 0 %.2f 0 0 cm /Im0 Do Q",
                            placedPoints, placedPoints * Double(rows) / Double(pixels)))
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    /// 1-bit-Rauschen (deterministisch, Seed 7) – inkompressibel: Kein
    /// G4-/JBIG2-Kandidat kommt unter die Rohbytes, der Race muss verlieren.
    static func bilevelNoisePDF(pixels: Int = 900, rows: Int = 900,
                                name: String = "bilevel-noise") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let rowBytes = (pixels + 7) / 8
        var state: UInt32 = 7
        var raw = [UInt8](repeating: 0, count: rowBytes * rows)
        for i in 0..<raw.count {
            state = state &* 1103515245 &+ 12345
            raw[i] = UInt8(truncatingIfNeeded: state >> 16)
        }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(rows)/BitsPerComponent 1/ColorSpace/DeviceGray",
            data: Data(raw))
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(
            dictionary: "",
            content: "q 400 0 0 400 106 196 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    /// Bereits G4-kodiertes 1-bit-Bild (CCITTFaxDecode-INPUT). Der Inhalt
    /// wird mit dem Produktions-Codec erzeugt – die Fixture ist damit ein
    /// echter Round-Trip-Anker. Solche Bilder bleiben unangetastet.
    static func ccittG4InputPDF(pixels: Int = 800, rows: Int = 600,
                                name: String = "ccitt-input") throws -> URL {
        let pattern = bilevelPattern(width: pixels, height: rows, seed: 4242)
        guard let buffer = BilevelBuffer(width: pixels, height: rows, data: pattern),
              let g4 = BilevelCodec.encodeG4(buffer) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(rows)/BitsPerComponent 1/ColorSpace/DeviceGray"
                + "/Filter/CCITTFaxDecode/DecodeParms<</K -1/Columns \(pixels)"
                + "/Rows \(rows)/BlackIs1 true>>",
            data: g4)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(
            dictionary: "",
            content: "q 300 0 0 225 156 283 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    // MARK: - CCITT-Eingangs-Fixtures (V2-3c, §9.10)

    /// Verweigerungsfälle des DecodeParms-Katalogs (§9.10): Jede Variante
    /// muss deterministisch KEEP ergeben, bevor ein Decode versucht wird.
    enum CCITTRefusalCase: String {
        case encodedByteAlign      // /EncodedByteAlign true – nicht abgedeckt
        case damagedRows           // /DamagedRowsBeforeError 1 – nicht abgedeckt
        case missingK              // /K fehlt (Pflicht)
        case columnsMismatch       // /Columns ≠ /Width
        case foreignKey            // fremder Schlüssel im DecodeParms
        case kOutOfRange           // /K -3
        case endOfLineOnG4         // /EndOfLine true bei K -1 (T.6 ohne EOLs)
        case twoDWithoutEOL        // K 2 ohne /EndOfLine (2D braucht EOLs)
    }

    /// Extern anmutender G4-Eingang: FAX-NATIVER Strom (weisse Läufe =
    /// weisse Flächen, PDF-Default: Abtastwert 1 = schwarz) plus angehängtem
    /// EOFB (zwei EOL-Codes = 24 Bits) und /EndOfBlock true – wie Scanner-
    /// Writer ihn ablegen. Mit `inverted: true` stattdessen die eigene
    /// Output-Konvention (komplementierter Strom mit /BlackIs1 true) –
    /// dieselben Pixel, andere Strom-/Flag-Kombination.
    ///
    /// Das Muster ist absichtlich SPARSAM (fast weiss): Auf solchen Bildern
    /// gewinnt G4 den §9.10-Race deterministisch gegen JBIG2.
    static func ccittG4ExternalPDF(pixels: Int = 800, rows: Int = 600,
                                   inverted: Bool = false,
                                   endOfBlock: Bool = true,
                                   name: String = "ccitt-external") throws -> URL {
        let pattern = bilevelSparsePattern(width: pixels, height: rows)
        guard let buffer = BilevelBuffer(width: pixels, height: rows, data: pattern) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stream: Data
        if inverted {
            guard let g4 = BilevelCodec.encodeG4(buffer) else {
                throw CocoaError(.fileWriteUnknown)
            }
            stream = g4
        } else {
            guard let g4 = BilevelCodec.encodeCCITTFixture(buffer, k: -1,
                                                           endOfLine: false) else {
                throw CocoaError(.fileWriteUnknown)
            }
            stream = g4
        }
        var data = stream
        if endOfBlock {
            data.append(contentsOf: [0x00, 0x10, 0x01])   // EOFB: EOL EOL
        }
        var parms = "/K -1/Columns \(pixels)/Rows \(rows)"
        if endOfBlock { parms += "/EndOfBlock true" }
        if inverted { parms += "/BlackIs1 true" }
        return try ccittStreamPDF(width: pixels, height: rows,
                                  stream: data, parms: parms, name: name)
    }

    /// G3-Eingang (K ≥ 0) vom libtiff-Fixture-Encoder, FAX-NATIV (PDF-
    /// Default: Abtastwert 1 = schwarz). `k == 0`: reines 1-D; `k > 0`:
    /// gemischt 1D/2D (dann ist endOfLine Pflicht). `blackIs1` nil lässt
    /// den Flag weg; true erfordert inhaltlich einen invertierten Strom –
    /// der Fixture-Encoder ist fax-nativ, also ist true hier nur für
    /// Verweigerungs-/Konventionstests sinnvoll.
    static func ccittG3InputPDF(pixels: Int = 800, rows: Int = 600,
                                k: Int, endOfLine: Bool,
                                blackIs1: Bool? = nil,
                                name: String = "ccitt-g3") throws -> URL {
        let pattern = bilevelPattern(width: pixels, height: rows, seed: 4242)
        guard let buffer = BilevelBuffer(width: pixels, height: rows, data: pattern),
              let stream = BilevelCodec.encodeCCITTFixture(buffer, k: k,
                                                           endOfLine: endOfLine) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var parms = "/K \(k)/Columns \(pixels)/Rows \(rows)"
        if endOfLine { parms += "/EndOfLine true" }
        if let blackIs1 { parms += blackIs1 ? "/BlackIs1 true" : "/BlackIs1 false" }
        return try ccittStreamPDF(width: pixels, height: rows, stream: stream,
                                  parms: parms, name: name)
    }

    /// DecodeParms-Verweigerungs-Fixtures. Der Strom ist ein gültiger G4-
    /// Stream – die Verweigerung muss trotzdem VOR jedem Decode greifen.
    static func ccittRefusalPDF(_ refusal: CCITTRefusalCase,
                                pixels: Int = 400, rows: Int = 300,
                                name: String = "ccitt-refusal") throws -> URL {
        let pattern = bilevelPattern(width: pixels, height: rows, seed: 99)
        guard let buffer = BilevelBuffer(width: pixels, height: rows, data: pattern),
              let g4 = BilevelCodec.encodeG4(buffer) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let base = "/Columns \(pixels)/Rows \(rows)"
        let parms: String
        switch refusal {
        case .encodedByteAlign: parms = "/K -1" + base + "/EncodedByteAlign true"
        case .damagedRows: parms = "/K -1" + base + "/DamagedRowsBeforeError 1"
        case .missingK: parms = base
        case .columnsMismatch: parms = "/K -1/Columns \(pixels + 8)/Rows \(rows)"
        case .foreignKey: parms = "/K -1" + base + "/Preview true"
        case .kOutOfRange: parms = "/K -3" + base
        case .endOfLineOnG4: parms = "/K -1" + base + "/EndOfLine true"
        case .twoDWithoutEOL: parms = "/K 2" + base
        }
        return try ccittStreamPDF(width: pixels, height: rows, stream: g4,
                                  parms: parms, name: name)
    }

    /// Gemeinsamer Aufbau: ein 1-bit-Bild mit CCITTFaxDecode und
    /// DecodeParms-String, platziert wie die übrigen Bild-Fixtures.
    private static func ccittStreamPDF(width: Int, height: Int,
                                       stream: Data, parms: String,
                                       name: String) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(width)"
                + "/Height \(height)/BitsPerComponent 1/ColorSpace/DeviceGray"
                + "/Filter/CCITTFaxDecode/DecodeParms<<" + parms + ">>",
            data: stream)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(
            dictionary: "",
            content: "q 300 0 0 225 156 283 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    /// Fast weisses 1-bit-Bild mit einem einzelnen Tintenstreifen. Bei so
    /// wenig Inhalt schlägt G4s Huffman-Kodierung jbig2encs generische
    /// Region inklusive Segment-Overhead – der Race wählt hier
    /// deterministisch CCITT.
    static func bilevelSparsePDF(pixels: Int = 256, rows: Int = 256,
                                 placedPoints: Double = 128,
                                 name: String = "bilevel-sparse") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        // PDF-Abtastwerte: 0 = schwarz, 1 = weiss → Grund 0xFF.
        let rowBytes = (pixels + 7) / 8
        var raw = [UInt8](repeating: 0xFF, count: rowBytes * rows)
        func inkRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            for row in y..<min(y + h, rows) {
                for column in x..<min(x + w, pixels) {
                    let inkMask = ~UInt8(0x80 >> (column & 7))
                    raw[row * rowBytes + (column >> 3)] &= inkMask
                }
            }
        }
        inkRect(60, 100, 120, 6)
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(rows)/BitsPerComponent 1/ColorSpace/DeviceGray",
            data: Data(raw))
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(
            dictionary: "",
            content: String(format: "q %.2f 0 0 %.2f 0 0 cm /Im0 Do Q",
                            placedPoints, placedPoints * Double(rows) / Double(pixels)))
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    /// 8-bit Graustufen mit EXAKT den beiden Werten 0 und 255 – der
    /// „nahezu bilevel"-Fall, der verlustfrei nach 1-bit abgebildet werden
    /// darf (Schwarz = 0-Bytes, Weiss = 255-Bytes).
    static func nearBilevelGrayPDF(pixels: Int = 1000, rows: Int = 700,
                                   name: String = "near-bilevel") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let pattern = bilevelPattern(width: pixels, height: rows, seed: 99)
        var raw = Data(count: pixels * rows)
        raw.withUnsafeMutableBytes { ptr in
            let base = ptr.bindMemory(to: UInt8.self)
            let rowBytes = (pixels + 7) / 8
            for y in 0..<rows {
                for x in 0..<pixels {
                    let bit = pattern[y * rowBytes + (x >> 3)] & UInt8(0x80 >> (x & 7))
                    base[y * pixels + x] = bit != 0 ? 0 : 255
                }
            }
        }
        guard let deflated = ImageProcessor.flate(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(rows)/BitsPerComponent 8/ColorSpace/DeviceGray"
                + "/Filter/FlateDecode",
            data: deflated)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(
            dictionary: "",
            content: "q 300 0 0 210 156 291 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    /// 8-bit Scan MIT Anti-Aliasing-Grauabstufungen – darf NIEMALS in den
    /// Bilevel-Pfad geraten (kein blindes Thresholding).
    static func antiAliasedScanPDF(pixels: Int = 700, rows: Int = 500,
                                   name: String = "aa-scan") throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var raw = Data(count: pixels * rows)
        raw.withUnsafeMutableBytes { ptr in
            let base = ptr.bindMemory(to: UInt8.self)
            for y in 0..<rows {
                for x in 0..<pixels {
                    // Balkenmuster mit weichen Kanten (Grauverlauf ±40 um 128).
                    let bar = (x / 14) % 2 == 0
                    let edge = x % 14 < 3 || x % 14 > 10
                    let value: UInt8 = bar ? (edge ? 88 : 20) : (edge ? 167 : 235)
                    base[y * pixels + x] = value
                }
            }
        }
        guard let deflated = ImageProcessor.flate(raw) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(rows)/BitsPerComponent 8/ColorSpace/DeviceGray"
                + "/Filter/FlateDecode",
            data: deflated)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(
            dictionary: "",
            content: "q 200 0 0 143 206 324 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }
}

// MARK: - RawPDFBuilder: Schreiben ins Fixture-Verzeichnis

/// Lag bis 2026-10-13 am Builder selbst und zog damit die Fixtures ins
/// App-Ziel. Der Builder bleibt in der App (`BilevelSupport`,
/// `MalformedCorpus`), das Schreiben ins Fixture-Verzeichnis ist Testsache.
extension RawPDFBuilder {
    /// Schreibt das Dokument in das gemeinsame Fixture-Verzeichnis.
    ///
    /// Nicht direkt ins Temp-Wurzelverzeichnis: Dort sammelten sich die
    /// Dateien an, weil die Aufräumpflicht bei jedem Aufrufer lag
    /// (Masterplan §9 „Temp ownership klar").
    func write(rootObject: Int, prefix: String) throws -> URL {
        let url = PDFFixtures.fixtureURL(prefix: prefix)
        try build(rootObject: rootObject).write(to: url)
        return url
    }
}
