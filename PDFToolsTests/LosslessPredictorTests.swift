import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

@Suite struct LosslessPredictorTests {

    @Test func adaptivePNGPredictorRoundTripsExactly() throws {
        let width = 73, height = 41, components = 3
        var raw = Data(capacity: width * height * components)
        for row in 0..<height {
            for column in 0..<width {
                raw.append(UInt8((column * 3 + row) % 256))
                raw.append(UInt8((column * 3 + row * 2 + 17) % 256))
                raw.append(UInt8((column * 3 + row * 4 + 91) % 256))
            }
        }

        let predicted = try #require(ImageResampler.pngPredictor(
            raw, width: width, height: height, components: components))
        #expect(predicted.count == (width * components + 1) * height)
        #expect(try decode(predicted, width: width, height: height,
                           components: components) == raw)
    }

    @Test func predictorMakesStructuredGraphicsSmaller() throws {
        let width = 640, height = 360, components = 3
        var raw = Data(capacity: width * height * components)
        for row in 0..<height {
            for column in 0..<width {
                let band = UInt8(((column / 32) + (row / 24)) % 8 * 28)
                raw.append(band)
                raw.append(band &+ 12)
                raw.append(band &+ 24)
            }
        }

        let predicted = try #require(ImageResampler.pngPredictor(
            raw, width: width, height: height, components: components))
        let plainFlate = try #require(ImageProcessor.flate(raw))
        let predictedFlate = try #require(ImageProcessor.flate(predicted))
        #expect(predictedFlate.count < plainFlate.count)
    }

    /// Predictor-Race: nimmt nie mehr als der reine Predictor-Pfad, bei
    /// Rauschen gewinnt roh. Keine Qualitätsänderung – beide dekodieren
    /// bitidentisch, nur die /DecodeParms unterscheiden sich.
    @Test func bestCandidateNeverLargerThanPredictorOnly() throws {
        let image = try #require(makeCGImage(width: 211, height: 137, seed: 0xC0FFEE))
        let predictorOnly = try #require(ImageResampler.encodeLossless(image, components: 3))
        let best = try #require(ImageResampler.encodeLosslessBest(image, components: 3))
        #expect(best.data.count <= predictorOnly.count)
    }

    @Test func noisyImagePrefersRawEncoding() throws {
        // Pseudorauschen: Predictor-Overhead (Filterbyte + schlechtere
        // Entropie) verliert gegen roh.
        let image = try #require(makeCGImage(width: 211, height: 137, seed: 0x12345678))
        let best = try #require(ImageResampler.encodeLosslessBest(image, components: 3))
        let raw = try #require(ImageResampler.rawBitmap(image, components: 3))
        let rawFlate = try #require(ImageProcessor.flate(raw))
        #expect(best.data.count <= rawFlate.count)
    }

    private func decode(_ encoded: Data, width: Int, height: Int,
                        components: Int) throws -> Data {
        let rowBytes = width * components
        let bytes = [UInt8](encoded)
        var output = [UInt8](repeating: 0, count: rowBytes * height)
        var cursor = 0

        for row in 0..<height {
            let filter = bytes[cursor]
            cursor += 1
            for index in 0..<rowBytes {
                let value = bytes[cursor]
                cursor += 1
                let destination = row * rowBytes + index
                let left = index >= components ? output[destination - components] : 0
                let up = row > 0 ? output[destination - rowBytes] : 0
                let upperLeft = row > 0 && index >= components
                    ? output[destination - rowBytes - components] : 0
                let prediction: UInt8
                switch filter {
                case 0: prediction = 0
                case 1: prediction = left
                case 2: prediction = up
                case 3: prediction = UInt8((Int(left) + Int(up)) / 2)
                case 4: prediction = paeth(left, up, upperLeft)
                default:
                    Issue.record("Ungültiger PNG-Filtertyp \(filter)")
                    prediction = 0
                }
                output[destination] = value &+ prediction
            }
        }
        return Data(output)
    }

    private func paeth(_ left: UInt8, _ up: UInt8,
                       _ upperLeft: UInt8) -> UInt8 {
        let a = Int(left), b = Int(up), c = Int(upperLeft)
        let estimate = a + b - c
        let da = abs(estimate - a), db = abs(estimate - b)
        let dc = abs(estimate - c)
        if da <= db && da <= dc { return left }
        if db <= dc { return up }
        return upperLeft
    }

    private func makeCGImage(width: Int, height: Int, seed: UInt64) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        guard let buf = ctx.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else {
            return nil
        }
        var s = seed == 0 ? UInt64(12345) : seed
        for i in 0..<(width * height) {
            // Strukturiert vs. verrauscht über Seed gesteuert: kleine Seeds
            // geben Bänder, große geben Rauschen.
            let r: UInt8, g: UInt8, b: UInt8
            if seed == 0xC0FFEE {
                let band = UInt8(((i % width) / 16 + (i / width) / 12) % 8 * 28)
                r = band; g = band &+ 12; b = band &+ 24
            } else {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                r = UInt8(truncatingIfNeeded: s >> 33)
                s = s &* 6364136223846793005 &+ 1442695040888963407
                g = UInt8(truncatingIfNeeded: s >> 33)
                s = s &* 6364136223846793005 &+ 1442695040888963407
                b = UInt8(truncatingIfNeeded: s >> 33)
            }
            buf[i * 4] = r; buf[i * 4 + 1] = g; buf[i * 4 + 2] = b
        }
        return ctx.makeImage()
    }
}
