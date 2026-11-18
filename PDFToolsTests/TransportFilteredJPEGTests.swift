import Testing
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import PDFTools

/// Masterplan B5 (Nebenbefund): JPEG hinter einem Transportfilter.
///
/// Befund: Ein Bild mit /Filter [/ASCII85Decode /DCTDecode] blieb in allen
/// Stufen unberührt („Pixel nicht dekodierbar“) – der Dekoder bekam die
/// ASCII85-Bytes. Die Schätzung rechnete mit dem Ersatz (78 % gegen real 1,6 %).
///
/// Fehlermöglichkeiten: (1) das Bild bleibt; (2) die Ausgabe trägt weiter den
/// Vorfilter vor neuen JPEG-Bytes (kaputtes Bild).
@MainActor
@Suite struct TransportFilteredJPEGTests {

    static func ascii85(_ data: Data) -> Data {
        var out = ""
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let chunk = Array(bytes[i..<min(i + 4, bytes.count)])
            var value: UInt32 = 0
            for k in 0..<4 { value = value << 8 | UInt32(k < chunk.count ? chunk[k] : 0) }
            if value == 0 && chunk.count == 4 { out += "z" } else {
                var digits = [Character](repeating: "!", count: 5)
                for k in (0..<5).reversed() { digits[k] = Character(UnicodeScalar(UInt8(value % 85) + 33)); value /= 85 }
                out += String(digits.prefix(chunk.count + 1))
            }
            i += 4
        }
        return Data((out + "~>").utf8)
    }

    static func prefiltered(_ prefilter: String, quality: Double) throws -> URL {
        let w = 1600, h = 1200
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for k in 0..<40 {
            ctx.setFillColor(CGColor(red: CGFloat(k % 7) / 7, green: CGFloat(k % 5) / 5, blue: CGFloat(k % 3) / 3, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: (k * 97) % w, y: (k * 61) % h, width: 300, height: 220))
        }
        let jpeg = NSMutableData()
        let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let wrapped = prefilter == "/ASCII85Decode" ? Self.ascii85(jpeg as Data) : try (jpeg as Data).zlibCompressedForTest()

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let img = b.addStream(dictionary: "/Type/XObject/Subtype/Image/Width \(w)/Height \(h)/BitsPerComponent 8"
            + "/ColorSpace/DeviceRGB/Filter[\(prefilter)/DCTDecode]", data: wrapped)
        let content = b.addStream(dictionary: "", content: "q 400 0 0 300 0 0 cm /Im0 Do Q")
        let page = b.addPage(parent: pages, mediaBox: "[0 0 400 300]",
                             resources: "<</XObject<</Im0 \(img) 0 R>>>>", contents: content)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "b5-prefilter")
    }

    @Test(arguments: ["/ASCII85Decode", "/FlateDecode"])
    func jpegHinterVorfilterWirdErsetzt(prefilter: String) throws {
        let input = try Self.prefiltered(prefilter, quality: 0.98)
        defer { try? FileManager.default.removeItem(at: input) }

        let result = try Compressor().compress(inputURL: input, mode: .small)
        defer { if result.outputURL != input { try? FileManager.default.removeItem(at: result.outputURL) } }
        #expect(!result.returnedOriginal)
        #expect(Double(result.outputBytes) < 0.5 * Double(result.inputBytes),
                "\(result.outputBytes) von \(result.inputBytes)")
        let out = try #require(try PDFCoreDocument(path: result.outputURL.path).imageResources().first)
        #expect(out.filters == [.dct], "Filterkette der Ausgabe: \(out.filters)")
        #expect(NSImage(contentsOf: result.outputURL) != nil)
    }

    /// Bleibt das Bild (Qualität hält kein kleinerer Kandidat), fällt
    /// wenigstens die Transporthülle weg – verlustfrei.
    @Test func behaltenesJPEGVerliertDieASCII85Huelle() throws {
        let input = try Self.prefiltered("/ASCII85Decode", quality: 0.5)
        defer { try? FileManager.default.removeItem(at: input) }
        let before = try #require(try PDFCoreDocument(path: input.path).imageResources().first)
        let result = try Compressor().compress(inputURL: input, mode: .quality)
        defer { if result.outputURL != input { try? FileManager.default.removeItem(at: result.outputURL) } }
        let out = try #require(try PDFCoreDocument(path: result.outputURL.path).imageResources().first)
        #expect(out.filters == [.dct], "Filterkette der Ausgabe: \(out.filters)")
        #expect(out.encodedByteCount < before.encodedByteCount * 85 / 100,
                "\(out.encodedByteCount) von \(before.encodedByteCount)")
        #expect(NSImage(contentsOf: result.outputURL) != nil)
    }
}

extension Data {
    /// zlib-Strom (RFC 1950) für Flate-Fixtures.
    func zlibCompressedForTest() throws -> Data {
        let compressed = try (self as NSData).compressed(using: .zlib) as Data
        // NSData liefert rohes Deflate; PDF-Flate braucht den zlib-Rahmen.
        var framed = Data([0x78, 0x9C])
        framed.append(compressed)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in self { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = (b << 16) | a
        framed.append(contentsOf: [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
        return framed
    }
}
