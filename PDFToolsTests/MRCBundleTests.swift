import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Phase V2-7 – Bundle-Container (§13.8) und Layer-Herleitung für die
/// Ausführung: Der Container ist selbstbeschreibend, deterministisch und
/// verweigert strukturelle Abweichungen vom Deskriptor.
@Suite struct MRCBundleTests {

    static func sampleDescriptor(photos: Int = 1) -> MRCCandidateDescriptor {
        var descriptor = MRCCandidateDescriptor(
            pageIndex: 3,
            maskDPI: 300,
            backgroundDPI: 135,
            backgroundQuality: 0.85,
            photoDPI: 200,
            photoQuality: 0.875)
        descriptor.maskCodec = .jbig2
        descriptor.imageObjectNumber = 42
        descriptor.imageObjectGeneration = 0
        descriptor.resourceName = "Im0"
        descriptor.maskWidth = 1275
        descriptor.maskHeight = 1650
        descriptor.backgroundWidth = 1148
        descriptor.backgroundHeight = 1485
        descriptor.backgroundComponents = 3
        var rects: [Double] = []
        for index in 0..<photos {
            rects.append(contentsOf: [Double(100 + index), 200, 300, 250])
        }
        descriptor.photoRects = rects
        descriptor.photoWidths = Array(repeating: 240, count: photos)
        descriptor.photoHeights = Array(repeating: 200, count: photos)
        descriptor.photoComponents = Array(repeating: 3, count: photos)
        return descriptor
    }

    static func sampleLayers(descriptor: MRCCandidateDescriptor) -> [PDFCoreDocument.MRCLayer] {
        var layers: [PDFCoreDocument.MRCLayer] = [
            PDFCoreDocument.MRCLayer(kind: .jpeg(components: 3),
                                     width: descriptor.backgroundWidth,
                                     height: descriptor.backgroundHeight,
                                     data: Data([1, 2, 3, 4]), rect: nil)
        ]
        for index in 0..<descriptor.photoRegionCount {
            let x = descriptor.photoRects[index * 4]
            let y = descriptor.photoRects[index * 4 + 1]
            let w = descriptor.photoRects[index * 4 + 2]
            let h = descriptor.photoRects[index * 4 + 3]
            layers.append(PDFCoreDocument.MRCLayer(
                kind: .jpeg(components: 3),
                width: descriptor.photoWidths[index],
                height: descriptor.photoHeights[index],
                data: Data([5, 6, 7]),
                rect: CGRect(x: x, y: y, width: w, height: h)))
        }
        layers.append(PDFCoreDocument.MRCLayer(
            kind: .jbig2Mask(globals: Data([9, 8])),
            width: descriptor.maskWidth, height: descriptor.maskHeight,
            data: Data([0xAA, 0x55]), rect: nil))
        return layers
    }

    @Test func bundleRoundtripIstStrukturgetreu() throws {
        let descriptor = Self.sampleDescriptor()
        let layers = Self.sampleLayers(descriptor: descriptor)
        var entries: [MRCEncoder.Bundle.Entry] = []
        for layer in layers {
            switch layer.kind {
            case .jpeg(let components):
                entries.append(MRCEncoder.Bundle.Entry(
                    kind: 0, isMask: false, components: components,
                    width: layer.width, height: layer.height,
                    rect: layer.rect, globals: Data(), data: layer.data))
            case .jbig2Mask(let globals):
                entries.append(MRCEncoder.Bundle.Entry(
                    kind: 1, isMask: true, components: 1,
                    width: layer.width, height: layer.height,
                    rect: nil, globals: globals ?? Data(), data: layer.data))
            case .ccittG4Mask:
                entries.append(MRCEncoder.Bundle.Entry(
                    kind: 2, isMask: true, components: 1,
                    width: layer.width, height: layer.height,
                    rect: nil, globals: Data(), data: layer.data))
            }
        }
        let bundle = MRCEncoder.Bundle.encode(entries)
        let decoded = try #require(MRCEncoder.Bundle.decode(bundle))
        #expect(decoded.count == entries.count)
        #expect(decoded[0].data == entries[0].data)
        #expect(decoded[0].width == entries[0].width)
        #expect(decoded.last?.globals == entries.last?.globals)
        // Reihenfolge [BG, Photo, Maske] bleibt erhalten.
        #expect(decoded[1].rect.map { Double($0.minX) } == 100)

        // Die Layer-Herleitung für die Ausführung verdrahtet Rechtecke und
        // Maske aus dem Deskriptor.
        let rebuilt = try MRCPageRewriter.layers(from: descriptor, bundle: bundle)
        #expect(rebuilt.count == layers.count)
        guard case .jbig2Mask(let globals) = rebuilt.last?.kind else {
            Issue.record("Masken-Layer fehlt am Ende")
            return
        }
        #expect(globals == Data([9, 8]))
        if let photoRect = rebuilt[1].rect {
            #expect(photoRect.minX == 100 && photoRect.height == 250)
        } else {
            Issue.record("Photo-Rect verloren")
        }
    }

    @Test func strukturabweichungWirdVerweigert() throws {
        // Ein Bundle ohne Photo-Ebene passt nicht zum Deskriptor.
        let descriptor = Self.sampleDescriptor(photos: 2)
        let layers = Self.sampleLayers(descriptor: Self.sampleDescriptor())
        var entries: [MRCEncoder.Bundle.Entry] = []
        for layer in layers {
            entries.append(MRCEncoder.Bundle.Entry(
                kind: layer.isMask ? 1 : 0, isMask: layer.isMask,
                components: 3, width: layer.width, height: layer.height,
                rect: layer.rect, globals: Data(), data: layer.data))
        }
        let bundle = MRCEncoder.Bundle.encode(entries)
        #expect(throws: PDFCoreError.checkFailed) {
            try MRCPageRewriter.layers(from: descriptor, bundle: bundle)
        }

        // Unbekanntes Format/Version ebenfalls.
        #expect(MRCEncoder.Bundle.decode(Data([0, 1, 2, 3])) == nil)
    }
}
