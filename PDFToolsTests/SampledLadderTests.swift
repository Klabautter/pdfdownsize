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
/// fällt weg); (3) die übrigen tragen einen falschen Grund. (1) und (3)
/// prüft der erste Test, (2) der zweite.
@Suite(.serialized) struct SampledLadderTests {

    /// `count` Seiten mit je einem eigenen, schon knapp kodierten JPEG
    /// gleicher Maße. `quality` steuert, ob sich ein Neukodieren lohnt.
    /// `smooth`: weicher Verlauf in hoher Auflösung statt Rauschen – er darf
    /// verkleinert werden und schrumpft dabei deutlich.
    static func document(count: Int, quality: Double, name: String, smooth: Bool = false) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var kids: [Int] = []
        for n in 0..<count {
            // Verlauf: 960 × 1260 px auf 320 × 420 pt (216 DPI) – über dem
            // Ziel von 96 DPI, damit Neukodieren erlaubt ist (im Budget wird
            // ein JPEG nur verlustfrei umgepackt).
            let (w, h) = smooth ? (960, 1260) : (320, 420)
            let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let base = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            var state = UInt32(n + 1)
            for y in 0..<h {
                let row = base + y * ctx.bytesPerRow
                for x in 0..<w * 4 where x % 4 != 3 {
                    if smooth {
                        row[x] = UInt8(truncatingIfNeeded: 40 + (x / 4) * 160 / w + y * 50 / h + (x % 4) * 20 + n)
                        continue
                    }
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

    /// Fall 2 (N28): Lohnt sich die Gruppe (Verläufe mit q 1,0), greift die
    /// Stichprobe NICHT – alle Bilder werden gerechnet, keines bleibt mit
    /// `sampledNoGain` stehen, und die Datei schrumpft.
    @Test func gleichartigeBilderMitGewinnWerdenAlleGerechnet() throws {
        let count = CompressionPlanner.sampleGroupThreshold + 8
        let url = try Self.document(count: count, quality: 1.0, name: "c3-mit-gewinn", smooth: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("c3-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: CompressionPlannerGateTests.transformingOptions)
        #expect(Self.sampledKeeps(outcome) == 0, "Stichprobe griff trotz Gewinn: \(Self.sampledKeeps(outcome))")
        let before = Compressor.fileSize(of: url), after = Compressor.fileSize(of: out)
        #expect(Double(after) < Double(before) * 0.97, "\(before) → \(after) Bytes – Gruppe lohnt nicht, Test prüft nichts")
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
