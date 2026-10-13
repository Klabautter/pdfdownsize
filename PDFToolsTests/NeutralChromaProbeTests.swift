import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PDFTools

/// Schnellschätzung (2026-10-01): Die Graustufen-Scans des Core-235 liegen
/// als RGB-JPEG vor; die Pipeline erkennt grauen Inhalt an den Pixeln, der
/// Schätzer sah nur „3 Komponenten“. Ein 64-px-Vorschaubild (JPEG-DCT-
/// Skalierung, Millisekunden) entscheidet, ob der Inhalt farbneutral ist.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Grauer Inhalt in RGB gilt als farbig (Scans weiter verfehlt).
///  2. Ein farbiges Foto gilt als neutral (Fotos zu klein geschätzt).
///  3. Leicht getöntes Papier (Scanner-Farbstich) kippt die Entscheidung.
///  4. Kaputte/fremde Daten stürzen ab statt nil zu liefern.
@Suite struct NeutralChromaProbeTests {

    private func jpeg(width: Int = 256, height: Int = 256,
                      pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> Data {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let o = (y * width + x) * 4
                bytes[o] = r; bytes[o + 1] = g; bytes[o + 2] = b
            }
        }
        let ctx = try #require(CGContext(data: &bytes, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        try #require(CGImageDestinationFinalize(dest))
        return data as Data
    }

    @Test func grauerInhaltInRGBIstNeutral() throws {   // 1
        let data = try jpeg { x, y in
            let v = UInt8((x * 7 + y * 3) % 256); return (v, v, v)
        }
        #expect(NeutralChromaProbe.isNeutral(jpeg: data) == true)
    }

    @Test func farbigesFotoIstNichtNeutral() throws {   // 2
        let data = try jpeg { x, y in (UInt8(x % 256), UInt8(y % 256), 90) }
        #expect(NeutralChromaProbe.isNeutral(jpeg: data) == false)
    }

    @Test func leichterPapierstichBleibtNeutral() throws {   // 3
        let data = try jpeg { x, _ in
            let v = UInt8(200 - (x % 40)); return (v &+ 3, v, v &- 2)
        }
        #expect(NeutralChromaProbe.isNeutral(jpeg: data) == true)
    }

    @Test func fremdeDatenLiefernNil() {   // 4
        #expect(NeutralChromaProbe.isNeutral(jpeg: Data("kein jpeg".utf8)) == nil)
        #expect(NeutralChromaProbe.isNeutral(jpeg: Data()) == nil)
    }
}
