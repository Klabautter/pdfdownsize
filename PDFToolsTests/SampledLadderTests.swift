import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PDFTools

/// Masterplan C3 (Stichproben-Leiter) – N14 nannte ihn „erledigt ohne Test“.
///
/// Bei mehr als `sampleGroupThreshold` gleichartigen Bildern läuft die volle
/// Leiter zuerst auf `sampleSize` verteilten Bildern; bringt die Gruppe
/// hochgerechnet unter 3 %, bleiben die übrigen KEEP ohne Dekodierung.
///
/// Fehlermöglichkeiten: (1) die Stichprobe greift nicht (alle werden
/// gerechnet); (2) sie greift auch, wenn sich die Gruppe lohnt (Ersparnis
/// fällt weg); (3) die übrigen tragen einen falschen Grund.
@Suite(.serialized) struct SampledLadderTests {

    /// `count` Seiten mit je einem eigenen, schon knapp kodierten JPEG
    /// gleicher Maße. `quality` steuert, ob sich ein Neukodieren lohnt.
    static func document(count: Int, quality: Double, name: String) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var kids: [Int] = []
        for n in 0..<count {
            let (w, h) = (320, 420)
            let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let base = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            var state = UInt32(n + 1)
            for y in 0..<h {
                let row = base + y * ctx.bytesPerRow
                for x in 0..<w * 4 where x % 4 != 3 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    row[x] = UInt8(truncatingIfNeeded: 120 + Int(state >> 26) + (x / 40) % 3 * 30)
                }
            }
            let data = NSMutableData()
            let dest = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()),
                                       [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            #expect(CGImageDestinationFinalize(dest))
            let image = b.addStream(dictionary: "/Type/XObject/Subtype/Image/Width \(w)/Height \(h)"
                                    + "/BitsPerComponent 8/ColorSpace/DeviceRGB/Filter/DCTDecode",
                                    data: data as Data)
            let content = b.addStream(dictionary: "", content: "q 320 0 0 420 0 0 cm /Im0 Do Q")
            kids.append(b.addPage(parent: pages, mediaBox: "[0 0 320 420]",
                                  resources: "<</XObject<</Im0 \(image) 0 R>>>>", contents: content))
        }
        b.fill(pages, "<</Type/Pages/Kids[\(kids.map { "\($0) 0 R" }.joined(separator: " "))]/Count \(count)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    static func sampledKeeps(_ outcome: CompressionPipeline.Outcome) -> Int {
        outcome.plan.actions.filter {
            if case .keep(_, .sampledNoGain, _) = $0 { return true }
            return false
        }.count
    }

    /// 48 gleichartige Bilder ohne Gewinn: 8 gerechnet, 40 KEEP mit Grund.
    @Test func gleichartigeBilderOhneGewinnWerdenNurStichprobenartigGerechnet() throws {
        let count = CompressionPlanner.sampleGroupThreshold + 8
        let url = try Self.document(count: count, quality: 0.3, name: "c3-ohne-gewinn")
        defer { try? FileManager.default.removeItem(at: url) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("c3-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: CompressionPlannerGateTests.transformingOptions)
        #expect(Self.sampledKeeps(outcome) == count - CompressionPlanner.sampleSize,
                "Stichprobe griff nicht: \(Self.sampledKeeps(outcome)) von \(count)")
    }

    /// Unter der Schwelle (40 Bilder) gibt es keine Stichprobe.
    @Test func kleineGruppeWirdVollGerechnet() throws {
        let url = try Self.document(count: CompressionPlanner.sampleGroupThreshold, quality: 0.3,
                                    name: "c3-klein")
        defer { try? FileManager.default.removeItem(at: url) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("c3-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: CompressionPlannerGateTests.transformingOptions)
        #expect(Self.sampledKeeps(outcome) == 0)
    }
}
