import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Deterministischer RGBA-Testbild-Bauer für die Klassifikator-Tests.
/// Gleiche Argumente → immer dasselbe Bild (kein Zufall, keine Uhr).
func makeClassifierImage(width: Int, height: Int,
                         pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            let i = (y * width + x) * 4
            bytes[i] = r
            bytes[i + 1] = g
            bytes[i + 2] = b
            bytes[i + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height,
                   bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

func clampByte(_ v: Int) -> UInt8 {
    UInt8(max(0, min(255, v)))
}

/// Foto-Synthetik: weiche Gradienten plus LCG-Rauschen geringer Amplitude –
/// hoher Entropie-/Textur-Charakter wie ein echtes Foto, aber ohne harte
/// Kanten (starke Amplituden würden nach Resampling falsche Kanten werfen,
/// Hochfrequenzmuster wie XOR täuschten Sobel-Kanten überall).
func photoLikePixels(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
    struct LCG {
        static var state: UInt32 = 12345
        static func next() -> Int {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Int((state >> 24) % 51) - 25
        }
    }
    let noise = LCG.next()
    return (clampByte(x * 255 / 127 + noise),
            clampByte(y * 255 / 127 + noise),
            clampByte((x + y) * 255 / 254 + noise))
}

/// Screenshot-artige Fläche mit EXAKTEN Farben: vier Vollton-Quadranten
/// (drei grau, ein gesättigt blau) – wenige distinkte Farben, harte Kanten.
func screenshotLikePixels(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
    let palette: [(UInt8, UInt8, UInt8)] = [
        (250, 250, 250), (30, 90, 200), (240, 240, 240), (20, 20, 20),
    ]
    let block = (y < 64 ? 0 : 2) + (x < 64 ? 0 : 1)
    return palette[block]
}

/// LineArt: weißer Grund, schwarze Rechteck-Konturen – flache Fläche mit
/// dünnen harten Kanten, kein Farbanteil.
func lineArtPixels(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
    let onEdge = { (rx: Int, ry: Int, rw: Int, rh: Int) -> Bool in
        (x >= rx && x < rx + rw && y >= ry && y < ry + rh)
            && (x < rx + 2 || x >= rx + rw - 2 || y < ry + 2 || y >= ry + rh - 2)
    }
    let ink = onEdge(8, 10, 50, 40) || onEdge(70, 12, 44, 38) || onEdge(34, 78, 60, 36)
    return ink ? (10, 10, 10) : (252, 252, 252)
}

/// Text-Fläche: Reihen kurzer schwarzer Balken (Wort-Silhouette) auf Weiß –
/// hohe Schwarz-Weiß-Wechsel, bimodale Kacheln.
func textLikePixels(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
    let row = y / 16
    let inBand = y % 16 >= 4 && y % 16 < 9
    let offset = (row % 2 == 0) ? 0 : 10
    let bar = inBand && ((x + offset) % 24) < 15
    return bar ? (15, 15, 15) : (250, 250, 250)
}

/// Phase V2-2 (§8.1/§8.2) – Feature-Extraktion: Merkmals-Semantik,
/// Multi-Resolution (Vertrauen → kein dritter Pass) und DETERMINISMUS.
@Suite struct ContentFeatureExtractorTests {

    @Test func fotoHatFotoMerkmaleUndWirdNieLineArt() throws {
        let image = makeClassifierImage(width: 128, height: 128, pixel: photoLikePixels)
        let features = try #require(ContentFeatureExtractor.extract(from: image))
        #expect(features.entropy >= 4.0)
        #expect(features.textureRatio >= 0.30)
        #expect(features.flatAreaRatio <= 0.45)
        let verdict = ContentClassifier.classify(
            features: features, context: ContentClassifier.ClassificationContext())
        #expect(verdict.contentClass == .photo,
                "Foto muss photo sein, war \(verdict.contentClass) (\(verdict.rule))")
        #expect(verdict.contentClass != .lineArt)
        #expect(features.sampleWidth == 128, "hohe Confidence → kein 256er-Pass")
    }

    @Test func screenshotWirdErkannt() throws {
        let image = makeClassifierImage(width: 128, height: 128, pixel: screenshotLikePixels)
        let features = try #require(ContentFeatureExtractor.extract(from: image))
        #expect(features.flatAreaRatio >= 0.45)
        #expect(features.uniqueColorRatio <= 0.10)
        let verdict = ContentClassifier.classify(
            features: features, context: ContentClassifier.ClassificationContext())
        #expect(verdict.contentClass == .screenshot,
                "Volltonfläche mit exakten Farben muss screenshot sein, war \(verdict.contentClass)")
        #expect(features.exactColorCountHint != nil
                && features.exactColorCountHint! <= 16,
                "exakte Farben: kleiner Paletten-Hinweis erwartet")
        #expect(verdict.contentClass.derivedImageClass == .graphics)
    }

    @Test func lineArtWirdErkannt() throws {
        let image = makeClassifierImage(width: 128, height: 128, pixel: lineArtPixels)
        let features = try #require(ContentFeatureExtractor.extract(from: image))
        let verdict = ContentClassifier.classify(
            features: features, context: ContentClassifier.ClassificationContext())
        #expect(verdict.contentClass == .lineArt,
                "Konturzeichnung muss lineArt sein, war \(verdict.contentClass) (\(verdict.rule))")
        #expect(features.grayscaleScore >= 0.90)
        #expect(features.textureRatio <= 0.45, "Linien sind keine Fototextur")
    }

    @Test func textKachelnWerkenGezaehlt() throws {
        let image = makeClassifierImage(width: 128, height: 128, pixel: textLikePixels)
        let features = try #require(ContentFeatureExtractor.extract(from: image))
        #expect(features.textLikeTileRatio >= 0.08,
                "Text-Balken müssen Text-Kacheln erzeugen: \(features.textLikeTileRatio)")
    }

    @Test func deterministischZweiLaeufeIdentisch() throws {
        let photo = makeClassifierImage(width: 128, height: 128, pixel: photoLikePixels)
        let screenshot = makeClassifierImage(width: 128, height: 128, pixel: screenshotLikePixels)
        let firstPhoto = ContentFeatureExtractor.extract(from: photo)
        let secondPhoto = ContentFeatureExtractor.extract(from: photo)
        let firstShot = ContentFeatureExtractor.extract(from: screenshot)
        let secondShot = ContentFeatureExtractor.extract(from: screenshot)
        #expect(firstPhoto == secondPhoto)
        #expect(firstShot == secondShot)
        let a = try #require(firstPhoto)
        let b = try #require(firstShot)
        let a2 = ContentClassifier.classify(
            features: a, context: ContentClassifier.ClassificationContext())
        let b2 = ContentClassifier.classify(
            features: b, context: ContentClassifier.ClassificationContext())
        #expect(a2.contentClass == ContentClassifier.classify(
            features: a, context: ContentClassifier.ClassificationContext()).contentClass)
        #expect(b2.contentClass == ContentClassifier.classify(
            features: b, context: ContentClassifier.ClassificationContext()).contentClass)
    }

    @Test func ambigueKlasseLoestDrittenPassAus() throws {
        // Untere Hälfte Volltongrau, obere Hälfte leiser Grau-Gradient:
        // flach genug für die Screenshot-Familie? Texturiert genug fürs Foto?
        // Beides nur grenzwertig – das Material fällt in keinen sicheren
        // Zweig, das Vertrauen bleibt unter der Schwelle → der dritte Pass
        // läuft und die Stichprobe wechselt auf 256. Deterministisch.
        var state: UInt32 = 777
        let image = makeClassifierImage(width: 200, height: 150) { x, y in
            if y < 75 {
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise = Int((state >> 24) % 31) - 15
                let gradient = 60 + y * 100 / 75
                return (clampByte(gradient + noise),
                        clampByte(gradient + noise),
                        clampByte(gradient + noise))
            }
            return (200, 200, 200)
        }
        let features = try #require(ContentFeatureExtractor.extract(from: image))
        #expect(features.confidence < ContentFeatureExtractor.confidentThreshold,
                "Testaufbau muss ambigue bleiben: \(features)")
        #expect(features.sampleWidth == 256,
                "ambigue Klasse muss den 256er-Pass auslösen, war \(features.sampleWidth)")
    }
}
