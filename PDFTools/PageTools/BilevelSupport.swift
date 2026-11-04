import Foundation
import CoreGraphics
import AppKit
import PDFKit
import pdfcore

/// Phase 2b (Roadmap) – Bilevel-Pfad: CCITT G4 + lossless JBIG2.
///
/// Durchgehende Pixelfolge aller Puffer dieser Datei: **Bit 1 = schwarz
/// (Tinte), Bit 0 = weiss**, MSB-first je Zeile, Zeilenlänge
/// `(width + 7) / 8`, kein Padding über das Zeilenende hinaus.
///
/// Die Shims in pdfcore sprechen dieselbe Folge: Der G4-Codec (libtiff)
/// rechnet intern mit 0-Bits als weissen Läufen und kehrt die Reihen im
/// Shim; JBIG2 übernimmt die Bytes in die Leptonica-Wortbelegung
/// (Bit 31-(x&31) je 32-Bit-Wort). Die Gate-Vergleiche sind deshalb
/// reine Bytevergleiche.
///
/// Verlustfreiheit wird vom Kodierer NICHT behauptet, sondern vom Gate
/// bewiesen: Jeder Kandidat wird dekodiert (G4 über libtiff, JBIG2 über
/// PDFKit – der Dekodierer entscheidet, nicht der Kodierer) und muss
/// bitidentisch zum Ausgangspuffer sein. Sonst KEEP.

// MARK: - Pixelpuffer

/// 1-bit-Pixelpuffer in der Bilevel-Pixelfolge.
struct BilevelBuffer: Equatable, Sendable {
    let width: Int
    let height: Int
    var data: Data

    static func rowBytes(width: Int) -> Int { (width + 7) / 8 }

    init?(width: Int, height: Int, data: Data) {
        let rowBytes = Self.rowBytes(width: width)
        let expected = rowBytes * height
        guard width > 0, height > 0, data.count >= expected else { return nil }
        self.width = width
        self.height = height
        // Bits über der Bildbreite (Zeilenende-Pad) werden auf Weiss (0)
        // gezogen – Gate-Vergleiche sehen sonst Müll im Pad.
        let trailingBits = width & 7
        var normalized = Data(data.prefix(expected))
        if trailingBits != 0 {
            let mask = UInt8(0xFF) << UInt8(8 - trailingBits)
            normalized.withUnsafeMutableBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for row in 0..<height {
                    base[row * rowBytes + rowBytes - 1] &= mask
                }
            }
        }
        self.data = normalized
    }

    /// Bytegenauer Vergleich auf exakter Länge. Überschüssige Bytes
    /// (Stream-Padding) fließen nicht ein.
    func bitIdentical(to other: BilevelBuffer) -> Bool {
        guard width == other.width, height == other.height else { return false }
        let length = Self.rowBytes(width: width) * height
        return data.prefix(length) == other.data.prefix(length)
    }
}

// MARK: - Kodierbrücke

/// Dünne Brücke über die Phase-2b-Shims – Muster wie `JPEGEncoder`.
enum BilevelCodec {

    /// CCITT G4: nackter T6-Stream ohne TIFF-Container.
    static func encodeG4(_ buffer: BilevelBuffer) -> Data? {
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status: Int32 = buffer.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_INTERNAL.rawValue)
            }
            return pdfcore_g4_encode(base, raw.count,
                                     Int32(buffer.width), Int32(buffer.height),
                                     &out, &outLen)
        }
        guard status == PDFCORE_OK.rawValue, let allocated = out, outLen > 0 else {
            if let allocated = out { free(allocated) }
            return nil
        }
        defer { free(allocated) }
        return Data(bytes: allocated, count: outLen)
    }

    /// Dekodiert einen G4-Kandidaten zurück in die Pixelfolge. `nil` heißt:
    /// nicht lesbar – der Kandidat ist dann ungültig. Ein nackter T6-Strom
    /// trägt keine Masse; Breite und Höhe muss der Aufrufer mitliefern.
    static func decodeG4(_ g4: Data, width: Int, height: Int) -> BilevelBuffer? {
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status: Int32 = g4.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_INTERNAL.rawValue)
            }
            return pdfcore_g4_decode(base, raw.count,
                                     Int32(width), Int32(height),
                                     &out, &outLen)
        }
        guard status == PDFCORE_OK.rawValue, let allocated = out, outLen > 0 else {
            if let allocated = out { free(allocated) }
            return nil
        }
        defer { free(allocated) }
        return BilevelBuffer(width: width, height: height,
                             data: Data(bytes: allocated, count: outLen))
    }

    /// V2-3c (§9.10) – CCITT-EINGANGS-Decode (G4 und G3) über den
    /// generalisierten Shim. Die Annahme-Politik liegt beim Aufrufer
    /// (`CCITTDecodeParms.acceptanceIssue`); hier wird nur noch dekodiert.
    /// Das Ergebnis trägt dieselbe Tinten-1-Pixelfolge wie `decodeG4`.
    static func decodeCCITT(_ data: Data,
                            parms: PDFCoreDocument.CCITTDecodeParms,
                            width: Int, height: Int) -> BilevelBuffer? {
        var cParms = pdfcore_ccitt_parms_t()
        cParms.present = 1
        cParms.k = Int32(parms.k)
        cParms.columns = Int32(parms.columns)
        cParms.rows = Int32(parms.rows)
        cParms.black_is_1 = parms.blackIs1 ? 1 : 0
        cParms.end_of_line = parms.endOfLine ? 1 : 0
        cParms.end_of_block = parms.endOfBlock ? 1 : 0
        cParms.byte_aligned = parms.encodedByteAlign ? 1 : 0
        cParms.damaged_rows = Int32(parms.damagedRowsBeforeError)
        cParms.known_keys_only = parms.knownKeysOnly ? 1 : 0

        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status: Int32 = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_INTERNAL.rawValue)
            }
            return pdfcore_ccitt_decode(base, raw.count, &cParms,
                                        &out, &outLen)
        }
        guard status == PDFCORE_OK.rawValue, let allocated = out, outLen > 0 else {
            if let allocated = out { free(allocated) }
            return nil
        }
        defer { free(allocated) }
        // Breite/Höhe kommen aus dem geprüften Katalog (Columns/Rows ==
        // Width/Height); die BilevelBuffer-Initialisierung normalisiert
        // das Zeilenende zusätzlich.
        return BilevelBuffer(width: width, height: height,
                             data: Data(bytes: allocated, count: outLen))
    }

    /// V2-3c – Fixture-Encoder (nur Tests): G3-/G4-Strom mit wählbarem
    /// /EndOfLine-Verhalten aus derselben libtiff-Familie. Eingabe wie
    /// `encodeG4` (Bit 1 = Tinte), ABER fax-nativ geschrieben (kein
    /// Komplement) – der Strom entspricht dem PDF-Default. k < 0 → G4,
    /// 0 → G3 1D, > 0 → G3 2D.
    static func encodeCCITTFixture(_ buffer: BilevelBuffer, k: Int,
                                   endOfLine: Bool) -> Data? {
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status: Int32 = buffer.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_INTERNAL.rawValue)
            }
            return pdfcore_ccitt_encode_fixture(base, raw.count,
                                                Int32(buffer.width),
                                                Int32(buffer.height),
                                                Int32(k), endOfLine ? 1 : 0,
                                                &out, &outLen)
        }
        guard status == PDFCORE_OK.rawValue, let allocated = out, outLen > 0 else {
            if let allocated = out { free(allocated) }
            return nil
        }
        defer { free(allocated) }
        return Data(bytes: allocated, count: outLen)
    }

    /// Lossless JBIG2 über den Symbolpfad (Refinement im Shim hart aus).
    /// Globals können leer sein, wenn kein Symbol-Dictionary entstanden ist.
    static func encodeJBIG2(_ buffer: BilevelBuffer)
        -> (page: Data, globals: Data)? {
        var pageOut: UnsafeMutablePointer<UInt8>?
        var pageLen = 0
        var globalsOut: UnsafeMutablePointer<UInt8>?
        var globalsLen = 0
        let status: Int32 = buffer.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_INTERNAL.rawValue)
            }
            return pdfcore_jbig2_encode(base, raw.count,
                                        Int32(buffer.width), Int32(buffer.height),
                                        &pageOut, &pageLen,
                                        &globalsOut, &globalsLen)
        }
        guard status == PDFCORE_OK.rawValue, let pagePtr = pageOut, pageLen > 0 else {
            if let pagePtr = pageOut { free(pagePtr) }
            if let globalsPtr = globalsOut { free(globalsPtr) }
            return nil
        }
        defer { free(pagePtr) }
        let page = Data(bytes: pagePtr, count: pageLen)
        let globals: Data
        if let globalsPtr = globalsOut, globalsLen > 0 {
            globals = Data(bytes: globalsPtr, count: globalsLen)
            free(globalsPtr)
        } else {
            globals = Data()
        }
        return (page, globals)
    }

    /// Lossless JBIG2 über die generische Region – reine Entropiekodierung
    /// des exakten Bitmaps, konstruktiv verlustfrei, ohne Symbol-Dict und
    /// damit ohne Globals.
    static func encodeJBIG2Generic(_ buffer: BilevelBuffer) -> Data? {
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status: Int32 = buffer.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_INTERNAL.rawValue)
            }
            return pdfcore_jbig2_encode_generic(base, raw.count,
                                                Int32(buffer.width), Int32(buffer.height),
                                                &out, &outLen)
        }
        guard status == PDFCORE_OK.rawValue, let allocated = out, outLen > 0 else {
            if let allocated = out { free(allocated) }
            return nil
        }
        defer { free(allocated) }
        return Data(bytes: allocated, count: outLen)
    }
}

// MARK: - PDFKit-Dekodier-Gate

/// Dekodiert einen JBIG2-Kandidaten über PDFKit: Der Kandidat wird in eine
/// Minimal-PDF eingeschlossen und 1:1 gerendert (1 PDF-Einheit = 1 Pixel,
/// keine Skalierung, kein Anti-Aliasing). Das Raster liefert den
/// Vergleichspuffer – Render-Verifikation gemäß Roadmap-Regel (c).
enum BilevelRenderGate {

    /// `nil` = PDFKit konnte nicht liefern; der Kandidat gilt als ungültig.
    static func decodedBuffer(page: Data, globals: Data?,
                              width: Int, height: Int) -> BilevelBuffer? {
        guard let document = PDFDocument(data: gatePDF(page: page,
                                                       globals: globals,
                                                       width: width,
                                                       height: height)),
              let pdfPage = document.page(at: 0) else { return nil }
        return autoreleasepool {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = NSSize(width: width, height: height)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.current = context
            let cg = context.cgContext
            cg.setFillColor(CGColor(gray: 1, alpha: 1))
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            pdfPage.draw(with: .mediaBox, to: cg)
            return inkBuffer(from: rep, width: width, height: height)
        }
    }

    private static func gatePDF(page: Data, globals: Data?,
                                width: Int, height: Int) -> Data {
        var builder = RawPDFBuilder()
        let pages = builder.reserveNumber()
        var imageDict = "/Type/XObject/Subtype/Image/Width \(width)"
            + "/Height \(height)/BitsPerComponent 1/ColorSpace/DeviceGray"
            + "/Filter/JBIG2Decode"
        if let globals, !globals.isEmpty {
            let globalsObject = builder.addStream(dictionary: "", data: globals)
            imageDict += "/DecodeParms<</JBIG2Globals \(globalsObject) 0 R>>"
        }
        let image = builder.addStream(dictionary: imageDict, data: page)
        let content = builder.addStream(
            dictionary: "",
            content: "q \(width) 0 0 \(height) 0 0 cm /Im0 Do Q")
        let resources = builder.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let pdfPage = builder.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 \(width) \(height)]/Resources \(resources) 0 R"
            + "/Contents \(content) 0 R>>")
        builder.fill(pages, "<</Type/Pages/Kids[\(pdfPage) 0 R]/Count 1>>")
        let root = builder.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return builder.build(rootObject: root)
    }

    /// Raster → Bilevel-Puffer: Luminanz < 0,5 zählt als Tinte.
    /// Schwellwert je Pixel: Tinte, wenn die Luminanz unter 0,5 liegt.
    ///
    /// Liest die Bytes des Rasters direkt (2026-10-13). Vorher fragte die
    /// Schleife jedes Pixel über `colorAt(x:y:)` ab – das legt je Pixel ein
    /// Farbobjekt an und kostete bei einer Scan-Seite (1900×2700) rund
    /// 1,8 s, etwa 40 % der gesamten Laufzeit. Die Rechnung ist dieselbe:
    /// Komponenten als Byte/255, gleiche Gewichte, gleiche Schwelle. Für
    /// alles, was nicht das erwartete 8-Bit-RGBA-Raster mit voller Deckung
    /// ist, bleibt der alte Weg über `colorAt` stehen.
    static func inkBuffer(from rep: NSBitmapImageRep,
                          width: Int, height: Int) -> BilevelBuffer? {
        let rowBytes = BilevelBuffer.rowBytes(width: width)
        var data = Data(count: rowBytes * height)
        let direct = rep.bitsPerSample == 8 && rep.samplesPerPixel == 4
            && rep.bitsPerPixel == 32 && !rep.isPlanar
            && rep.bitmapFormat.isDisjoint(with: [.alphaFirst, .floatingPointSamples,
                                                  .sixteenBitLittleEndian, .thirtyTwoBitLittleEndian,
                                                  .sixteenBitBigEndian, .thirtyTwoBitBigEndian])
            && rep.pixelsWide >= width && rep.pixelsHigh >= height
        let source = direct ? rep.bitmapData : nil
        let sourceRowBytes = rep.bytesPerRow
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                let row = base + y * rowBytes
                let sourceRow = source.map { $0 + y * sourceRowBytes }
                for x in 0..<width {
                    let luminance: Double
                    if let pixel = sourceRow.map({ $0 + x * 4 }), pixel[3] == 255 {
                        luminance = 0.299 * (Double(pixel[0]) / 255)
                            + 0.587 * (Double(pixel[1]) / 255)
                            + 0.114 * (Double(pixel[2]) / 255)
                    } else {
                        guard let color = rep.colorAt(x: x, y: y) else { continue }
                        luminance = 0.299 * color.redComponent
                            + 0.587 * color.greenComponent
                            + 0.114 * color.blueComponent
                    }
                    if luminance < 0.5 {
                        row[x >> 3] |= UInt8(0x80 >> (x & 7))
                    }
                }
            }
        }
        return BilevelBuffer(width: width, height: height, data: data)
    }

    /// Der frühere Weg über `colorAt` – nur noch als Vergleichsmaßstab für
    /// den Test, der die Gleichheit beider Wege festhält.
    static func inkBufferViaColorObjects(from rep: NSBitmapImageRep,
                                         width: Int, height: Int) -> BilevelBuffer? {
        let rowBytes = BilevelBuffer.rowBytes(width: width)
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                let row = base + y * rowBytes
                for x in 0..<width {
                    guard let color = rep.colorAt(x: x, y: y) else { continue }
                    let luminance = 0.299 * color.redComponent
                        + 0.587 * color.greenComponent
                        + 0.114 * color.blueComponent
                    if luminance < 0.5 {
                        row[x >> 3] |= UInt8(0x80 >> (x & 7))
                    }
                }
            }
        }
        return BilevelBuffer(width: width, height: height, data: data)
    }
}

// MARK: - Erkennung

/// Bilevel-Erkennung. Zwei Klassen:
///
/// - `trueBilevel`: BitsPerComponent == 1 im Bilddictionary in einer
///   Grau-Familie – die Abtastwerte sind bereits bilevel.
/// - `nearBilevel`: 8-bit Grau/RGB, das NUR aufgenommen wird, wenn eine
///   exakte Prüfung über ALLE Pixel die Zweiwertigkeit Schwarz/Weiss
///   beweist. Grauabstufungen (Anti-Aliasing!) scheitern an der Prüfung,
///   es gibt bewusst kein Thresholding auf Verdacht.
enum BilevelDetection {

    enum Kind: Equatable {
        case trueBilevel
        case nearBilevel
        case none
    }

    /// Dictionary-Ebene, ohne Dekodierung.
    static func classify(resource: PDFImageResource) -> Kind {
        switch resource.bitsPerComponent {
        case 1:
            switch resource.colorSpace {
            case .deviceGray, .calGray:
                return .trueBilevel
            case .iccBased(let components) where components == 1:
                return .trueBilevel
            default:
                return .none
            }
        case 8:
            switch resource.colorSpace {
            case .deviceGray, .calGray, .deviceRGB, .calRGB:
                return .nearBilevel
            case .iccBased(let components) where components == 1 || components == 3:
                return .nearBilevel
            default:
                return .none
            }
        default:
            return .none
        }
    }

    static func isRGB(_ resource: PDFImageResource) -> Bool {
        resource.colorSpace.componentCount == 3
    }

    struct ExactScan {
        let buffer: BilevelBuffer
        /// Originalpixel (8-bit) – Grundlage des Rekonstruktionsvergleichs.
        let raw: Data
    }

    /// Exakte Zweiwert-Prüfung über das GESAMTE Bild. Für RGB zählt nur
    /// reines Schwarz/Weiss – ein zweifarbiger Blau-Weiss-Verlauf ließe
    /// sich als DeviceGray-1-bit nicht verlustfrei abbilden.
    ///
    /// Puffer↔Pixel ist bijektiv (Bit 1 ↔ 0/255 bzw. (0,0,0)), deshalb
    /// genügt für das Gate später der Bitvergleich.
    static func exactBilevel(_ image: CGImage, rgb: Bool) -> ExactScan? {
        // Vorprüfung auf einer Stichprobe – Fotos scheitern hier fast
        // immer, ohne dass das Vollbild angefasst werden müsste.
        guard sampleIsTwoValued(image) else { return nil }

        let components = rgb ? 3 : 1
        guard let raw = ImageResampler.rawBitmap(image, components: components),
              let buffer = binarize(raw, width: image.width,
                                    height: image.height, rgb: rgb) else {
            return nil
        }
        return ExactScan(buffer: buffer, raw: raw)
    }

    /// Stichprobe (96×96): nur wenn sie exakt zweiwertig ist, lohnt der
    /// Vollbild-Scan. Ein Verfehlen der Stichprobe kostet nichts – das
    /// Bild bleibt in der photo/graphics-Klasse.
    private static func sampleIsTwoValued(_ image: CGImage) -> Bool {
        let edge = 96
        let scale = min(Double(edge) / Double(max(image.width, 1)),
                        Double(edge) / Double(max(image.height, 1)), 1.0)
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
            let isBlack = r == 0 && g == 0 && b == 0
            let isWhite = r == 255 && g == 255 && b == 255
            if !isBlack && !isWhite { return false }
        }
        return true
    }

    /// Vollbild-Binarisierung nach bestandener Exaktprüfung.
    private static func binarize(_ raw: Data, width: Int, height: Int,
                                 rgb: Bool) -> BilevelBuffer? {
        let rowBytes = BilevelBuffer.rowBytes(width: width)
        var ink = [UInt8](repeating: 0, count: rowBytes * height)
        // Beide Werte müssen vorkommen: Ein einfarbiges Bild trägt keine
        // bilevel-Struktur und bleibt in den regulären Pfaden.
        var sawInk = false
        var sawPaper = false

        let bytes = [UInt8](raw)
        if rgb {
            for y in 0..<height {
                for x in 0..<width {
                    let o = (y * width + x) * 3
                    let r = bytes[o], g = bytes[o + 1], b = bytes[o + 2]
                    let isBlack = r == 0 && g == 0 && b == 0
                    let isWhite = r == 255 && g == 255 && b == 255
                    guard isBlack || isWhite else { return nil }
                    if isBlack {
                        sawInk = true
                        ink[y * rowBytes + (x >> 3)] |= UInt8(0x80 >> (x & 7))
                    } else {
                        sawPaper = true
                    }
                }
            }
        } else {
            for y in 0..<height {
                for x in 0..<width {
                    let value = bytes[y * width + x]
                    guard value == 0 || value == 255 else { return nil }
                    if value == 0 {
                        sawInk = true
                        ink[y * rowBytes + (x >> 3)] |= UInt8(0x80 >> (x & 7))
                    } else {
                        sawPaper = true
                    }
                }
            }
        }
        guard sawInk, sawPaper else { return nil }
        return BilevelBuffer(width: width, height: height, data: Data(ink))
    }
}

// MARK: - Pufferbeschaffung

/// Deterministische Pufferherleitung – Planner und Executor-Fallback nutzen
/// denselben Weg, damit die im Plan erzeugten Bytes reproduzierbar sind.
enum BilevelSource {

    /// Protokoll-Erweiterung: gepackte 1-bit-Pixel aus dem Dokument.
    /// `nil` heißt: nicht lieferbar – der Bilevel-Pfad scheidet dann aus.
    static func buffer(for resource: PDFImageResource,
                       pixels: ImagePixelSource) -> BilevelBuffer? {
        switch BilevelDetection.classify(resource: resource) {
        case .trueBilevel:
            return pixels.bilevelBuffer(for: resource)
        case .nearBilevel:
            guard let image = pixels.decodedImage(for: resource),
                  let scan = BilevelDetection.exactBilevel(
                      image, rgb: BilevelDetection.isRGB(resource)) else { return nil }
            return scan.buffer
        case .none:
            return nil
        }
    }
}

// MARK: - Verkleinern sehr hoher Auflösungen

/// Bilevel über 600 DPI trägt mehr, als Bildschirm und Bürodrucker zeigen. Klein
/// darf ab rund 600 DPI halbieren, Smart erst darüber; das Ergebnis liegt nie
/// unter 300 DPI (Klein) und bleibt damit gestochen. Qualität und Custom bleiben
/// bei „Bilevel wird nie resampelt“.
enum BilevelResampling {

    struct Reduction {
        let buffer: BilevelBuffer
        /// Anteil der Zielzellen mit irgendeiner Tinte, die Tinte behalten.
        let inkCellSurvival: Double
        /// Relative Änderung der Tintenfläche.
        let inkAreaChange: Double

        /// Haarlinien und feine Raster enden in Zellen unter der Hälfte und
        /// verschwinden; dann bleibt das Original.
        var preservesInk: Bool {
            inkCellSurvival >= BilevelResampling.minimumInkCellSurvival
                && inkAreaChange <= BilevelResampling.maximumInkAreaChange
        }
    }

    /// Gemessen an gesetztem Text (Times, Faktor → Überleben / Flächenänderung):
    /// 11 pt, 1200 → 600 DPI: 0,96 / 0,06; 600 → 300: 0,93 / 0,10; 1200 → 300:
    /// 0,80 / 0,05. Abgelehnt: 5,5 pt, 600 → 300: 0,88 / 0,17; 1200 → 300: 0,68 / 0,07.
    static let minimumInkCellSurvival = 0.75
    static let maximumInkAreaChange = 0.15
    /// Klein: „etwa 600 DPI“; das Band fängt Scans auf, die knapp größer
    /// platziert sind. Smart: erst klar über 600 DPI (Toleranz wie die Bilder).
    static let smallMinimumDPI = 570.0
    static let smartMinimumDPI = 690.0
    static let smallFloorDPI = 300.0
    /// Messraster: halbe Kandidatenkante (bei 300 DPI also rund 150 DPI, nah an
    /// der normalen Ansicht), höchstens diese Kante.
    static let measurementEdge = 2048

    /// Kleinster Faktor (2, 4, …) nach Stufe; `nil`, wenn nicht verkleinert wird.
    /// Maßgeblich ist die kleinere Auflösung aller Platzierungen und Achsen.
    static func factor(for resource: PDFImageResource,
                       options: ImageCompressionOptions) -> Int? {
        guard case .adaptive = options.qualityPolicy else { return nil }
        let dpis = resource.placements.flatMap { placement -> [Double] in
            guard placement.placedWidthPoints > 1, placement.placedHeightPoints > 1 else { return [] }
            let scale = placement.pageSizeDPIScale ?? 1
            return [Double(resource.width) / placement.placedWidthPoints * 72 * scale,
                    Double(resource.height) / placement.placedHeightPoints * 72 * scale]
        }
        guard let dpi = dpis.min(), dpi > 0 else { return nil }
        var factor = 2
        switch QualityGatePreset(ssimThreshold: options.ssimThreshold) {
        case .small:
            guard dpi >= smallMinimumDPI else { return nil }
            while dpi / Double(factor * 2) >= smallFloorDPI { factor *= 2 }
        case .smart:
            guard dpi > smartMinimumDPI else { return nil }
            while dpi / Double(factor) > smartMinimumDPI { factor *= 2 }
        case .quality, .custom:
            return nil
        }
        return factor
    }

    /// Kastenfilter: Eine Zielzelle wird Tinte, wenn mindestens die Hälfte ihrer
    /// Quellpixel Tinte ist (Bit 1 = schwarz). Deterministisch; der Executor
    /// erzeugt dieselben Bits neu.
    static func reduce(_ source: BilevelBuffer, factor: Int) -> Reduction? {
        guard factor >= 2 else { return nil }
        let width = (source.width + factor - 1) / factor
        let height = (source.height + factor - 1) / factor
        let sourceRow = BilevelBuffer.rowBytes(width: source.width)
        let targetRow = BilevelBuffer.rowBytes(width: width)
        var out = [UInt8](repeating: 0, count: targetRow * height)
        var counts = [Int32](repeating: 0, count: width)
        var inkCells = 0, keptCells = 0, sourceInk = 0, targetInk = 0
        source.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let bits = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for cellY in 0..<height {
                for i in 0..<width { counts[i] = 0 }
                let firstRow = cellY * factor
                let rows = min(factor, source.height - firstRow)
                for row in firstRow..<(firstRow + rows) {
                    let line = bits + row * sourceRow
                    for byteIndex in 0..<sourceRow where line[byteIndex] != 0 {
                        let byte = line[byteIndex]
                        sourceInk += byte.nonzeroBitCount
                        for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                            counts[(byteIndex * 8 + bit) / factor] += 1
                        }
                    }
                }
                for cellX in 0..<width where counts[cellX] > 0 {
                    inkCells += 1
                    let columns = min(factor, source.width - cellX * factor)
                    if Int(counts[cellX]) * 2 >= columns * rows {
                        keptCells += 1
                        targetInk += 1
                        out[cellY * targetRow + cellX / 8] |= 0x80 >> UInt8(cellX % 8)
                    }
                }
            }
        }
        guard let buffer = BilevelBuffer(width: width, height: height, data: Data(out)) else { return nil }
        let inkArea = Double(targetInk * factor * factor)
        return Reduction(
            buffer: buffer,
            inkCellSurvival: inkCells == 0 ? 1 : Double(keptCells) / Double(inkCells),
            inkAreaChange: sourceInk == 0 ? 0 : abs(inkArea - Double(sourceInk)) / Double(sourceInk))
    }

    /// Beide Puffer gehen durch denselben Kastenfilter auf dasselbe Graustufen-
    /// Raster und von dort in die üblichen Gates.
    static func measure(source: BilevelBuffer, candidate: BilevelBuffer) -> QualityGateMeasurement? {
        let edge = min(measurementEdge, max(candidate.width, candidate.height) / 2)
        guard let size = QualityGates.sampleSize(width: source.width, height: source.height,
                                                 maxEdge: edge),
              let reference = grayImage(source, size: size),
              let comparison = grayImage(candidate, size: size),
              let sample = QualityGates.sample(reference, maxEdge: edge) else { return nil }
        return QualityGates.Evaluator(reference: sample).measure(candidate: comparison)
    }

    private static func grayImage(_ buffer: BilevelBuffer, size: PixelSize) -> CGImage? {
        var ink = [UInt32](repeating: 0, count: size.width * size.height)
        var area = [UInt32](repeating: 0, count: size.width * size.height)
        let rowBytes = BilevelBuffer.rowBytes(width: buffer.width)
        let columnCell = (0..<buffer.width).map { $0 * size.width / buffer.width }
        var columnPixels = [UInt32](repeating: 0, count: size.width)
        for cell in columnCell { columnPixels[cell] += 1 }
        buffer.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let bits = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for row in 0..<buffer.height {
                let base = (row * size.height / buffer.height) * size.width
                for x in 0..<size.width { area[base + x] += columnPixels[x] }
                let line = bits + row * rowBytes
                for byteIndex in 0..<rowBytes where line[byteIndex] != 0 {
                    let byte = line[byteIndex]
                    for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                        ink[base + columnCell[byteIndex * 8 + bit]] += 1
                    }
                }
            }
        }
        var gray = [UInt8](repeating: 255, count: ink.count)
        for i in gray.indices where ink[i] > 0 && area[i] > 0 {
            gray[i] = UInt8(255 - min(255, ink[i] * 255 / area[i]))
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: size.width, height: size.height, bitsPerComponent: 8,
                       bitsPerPixel: 8, bytesPerRow: size.width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

extension ImagePixelSource {
    /// Gepackte 1-bit-Pixel eines Bildobjekts in der Bilevel-Pixelfolge.
    /// Default `nil` – nur die libqpdf-Pixelquelle liefert echte Bits.
    func bilevelBuffer(for resource: PDFImageResource) -> BilevelBuffer? { nil }
}

extension LibQPDFPixelSource {

    /// 1-bit-Streams: libqpdf liefert die gepackten Abtastwerte (Predictor
    /// bereits aufgelöst). PDF 1-bit Grau trägt 0 = schwarz / 1 = weiss –
    /// invertiert zur Tintenkonvention (Bit 1 = schwarz).
    ///
    /// V2-3c (§9.10): CCITTFaxDecode-Eingänge laufen hier NICHT über
    /// libqpdf (der kann den Filter nicht auflösen), sondern über den
    /// eigenen Decode-Shim. NUR mit vollständig abgedeckten DecodeParms –
    /// sonst nil und damit deterministisch KEEP. Das Ergebnis des
    /// Fax-Codec trägt bereits die Tinten-1-Folge, es wird NICHT invertiert.
    func bilevelBuffer(for resource: PDFImageResource) -> BilevelBuffer? {
        guard resource.bitsPerComponent == 1,
              resource.width > 0, resource.height > 0 else { return nil }
        if resource.terminalFilter == .ccitt {
            guard resource.filters == [.ccitt],
                  resource.colorSpace.isDirectlyRenderable,
                  let parms = document.ccittDecodeParms(objectID: resource.objectID),
                  parms.acceptanceIssue(expectedWidth: resource.width,
                                        expectedHeight: resource.height) == nil,
                  let data = document.imageStreamData(objectID: resource.objectID,
                                                      decoded: false),
                  let buffer = BilevelCodec.decodeCCITT(
                      data, parms: parms,
                      width: resource.width, height: resource.height)
            else { return nil }
            return buffer
        }
        guard resource.colorSpace.isDirectlyRenderable,
              let data = document.imageStreamData(objectID: resource.objectID,
                                                  decoded: true) else { return nil }
        let rowBytes = BilevelBuffer.rowBytes(width: resource.width)
        let expected = rowBytes * resource.height
        guard data.count >= expected else { return nil }
        let packed = Data(data.prefix(expected)).map { ~$0 }
        return BilevelBuffer(width: resource.width, height: resource.height,
                             data: Data(packed))
    }
}
