import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PDFTools

/// 2026-10-13 – Zwischenkopie vor dem Flächenfilter gespart: Ein Bild, das
/// der Resampler selbst erzeugt hat, wird vor dem Verkleinern nicht noch
/// einmal in voller Größe gezeichnet. Fehlermöglichkeiten:
/// (1) das Ergebnis weicht von dem mit Vollkopie ab (Pixel geändert),
/// (2) ein von ImageIO stammendes Bild gilt fälschlich als flach und
///     überspringt das Flachzeichnen (P0.3-Fehlerbild kehrt zurück),
/// (3) die Marke gilt für die falsche Komponentenzahl (RGB als Grau).
@Suite struct FlatBitmapTests {

    /// Fotoartiges Testbild: Verlauf plus deterministisches Rauschen.
    private func photo(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt32 = 12345
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 1664525 &+ 1013904223
                let noise = Int(state >> 27)
                let i = (y * width + x) * 4
                bytes[i] = UInt8(clamping: x * 255 / width + noise)
                bytes[i + 1] = UInt8(clamping: y * 255 / height + noise)
                bytes[i + 2] = UInt8(clamping: (x + y) * 255 / (width + height) + noise)
                bytes[i + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Dieselben Pixel wie `image`, aber als fremdes Bitmap ohne Marke.
    private func unmarkedCopy(_ image: CGImage) throws -> CGImage {
        let raw = try #require(ImageResampler.rawBitmap(image, components: 3))
        let provider = try #require(CGDataProvider(data: raw as CFData))
        return try #require(CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: image.width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func verkleinernOhneVollkopieLiefertDieselbenPixel() throws {
        let source = try photo(width: 1203, height: 807)
        let jpeg = try #require(ImageResampler.encodeJPEG(source, quality: 0.9))
        let decoded = try #require(ImageResampler.decodeJPEG(jpeg))
        #expect(ImageResampler.isFlatBitmap(decoded, components: 3))
        let foreign = try unmarkedCopy(decoded)
        #expect(!ImageResampler.isFlatBitmap(foreign, components: 3))
        #expect(ImageResampler.rawBitmap(foreign, components: 3)
                == ImageResampler.rawBitmap(decoded, components: 3), "Ausgangspixel müssen gleich sein")

        // Mehrere Faktoren: knapp unter 1, ungerade Halbierungen, sehr klein.
        for target in [PixelSize(width: 1100, height: 738), PixelSize(width: 601, height: 403),
                       PixelSize(width: 300, height: 201), PixelSize(width: 67, height: 45)] {
            let fast = try #require(ImageResampler.resize(decoded, to: target, components: 3))
            let full = try #require(ImageResampler.resize(foreign, to: target, components: 3))
            #expect(ImageResampler.rawBitmap(fast, components: 3)
                    == ImageResampler.rawBitmap(full, components: 3),
                    "Abweichung bei \(target.width)×\(target.height)")
        }
    }

    @Test func imageIOBilderGeltenNieAlsFlach() throws {
        let source = try photo(width: 320, height: 200)
        let jpeg = try #require(ImageResampler.encodeJPEG(source, quality: 0.9))
        let imageSource = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let raw = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(!ImageResampler.isFlatBitmap(raw, components: 3))
        #expect(!ImageResampler.isFlatBitmap(raw, components: 1))
    }

    @Test func markeGiltNurFuerIhreKomponentenzahl() throws {
        let source = try photo(width: 320, height: 200)
        let rgb = try #require(ImageResampler.resize(source, to: PixelSize(width: 160, height: 100), components: 3))
        #expect(ImageResampler.isFlatBitmap(rgb, components: 3))
        #expect(!ImageResampler.isFlatBitmap(rgb, components: 1))
        // RGB → Grau muss weiter umgerechnet werden, nicht übersprungen.
        let gray = try #require(ImageResampler.resize(rgb, to: PixelSize(width: 80, height: 50), components: 1))
        #expect(ImageResampler.isFlatBitmap(gray, components: 1))
        #expect(gray.colorSpace?.model == .monochrome)
    }
}
