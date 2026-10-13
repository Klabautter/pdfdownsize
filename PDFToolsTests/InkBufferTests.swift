import AppKit
import Testing
@testable import PDFTools

/// Schwellwertbildung der Masken-Verifikation (2026-10-13).
///
/// Der direkte Byte-Zugriff ersetzt die Abfrage je Pixel über Farbobjekte.
/// Fehlermöglichkeit: Beide Wege setzen an der Schwelle (Luminanz 0,5) oder
/// bei Mischfarben unterschiedliche Bits – die Bitgleichheits-Prüfung der
/// Maske fiele dann anders aus als bisher.
@Suite struct InkBufferTests {

    private static func rep(width: Int, height: Int,
                            fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let data = rep.bitmapData!
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = fill(x, y)
                let p = data + y * rep.bytesPerRow + x * 4
                p[0] = r; p[1] = g; p[2] = b; p[3] = a
            }
        }
        return rep
    }

    /// Alle Grauwerte, alle Kanalstufen einzeln und gemischte Farben rund um
    /// die Schwelle – deckend.
    @Test func direkterZugriffGleichtDemFarbobjektWeg() throws {
        let width = 256, height = 96
        let rep = Self.rep(width: width, height: height) { x, y in
            let v = UInt8(x)
            switch y % 6 {
            case 0: return (v, v, v, 255)
            case 1: return (v, 0, 0, 255)
            case 2: return (0, v, 0, 255)
            case 3: return (0, 0, v, 255)
            case 4: return (v, UInt8(255 - x), UInt8((x * 7 + y * 13) % 256), 255)
            default: return (UInt8((x * 3 + y) % 256), UInt8((x + y * 5) % 256), v, 255)
            }
        }
        let fast = try #require(BilevelRenderGate.inkBuffer(from: rep, width: width, height: height))
        let reference = try #require(BilevelRenderGate.inkBufferViaColorObjects(
            from: rep, width: width, height: height))
        #expect(fast.bitIdentical(to: reference))
        // Der Test prüft wirklich beide Seiten der Schwelle.
        let ink = fast.data.reduce(0) { $0 + $1.nonzeroBitCount }
        #expect(ink > 0 && ink < width * height)
    }

    /// Nicht deckende Pixel laufen weiter über den alten Weg – auch dann
    /// stimmen beide überein.
    @Test func halbtransparentePixelBleibenGleich() throws {
        let width = 64, height = 16
        let rep = Self.rep(width: width, height: height) { x, y in
            let a = UInt8([0, 64, 128, 200, 255][(x + y) % 5])
            let v = UInt8(min(Int(a), (x * 4) % 256))   // vormultipliziert: Wert ≤ Alpha
            return (v, v, v, a)
        }
        let fast = try #require(BilevelRenderGate.inkBuffer(from: rep, width: width, height: height))
        let reference = try #require(BilevelRenderGate.inkBufferViaColorObjects(
            from: rep, width: width, height: height))
        #expect(fast.bitIdentical(to: reference))
    }
}
