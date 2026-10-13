import Testing
import Foundation
@testable import PDFTools

/// Phase 3-Followup – Zopfli-Repack großer Flate-Streams (nur Max-Preset).
///
/// Der Pass ersetzt die zlib-Verpackung großer Flate-Streams durch Zopfli –
/// verlustfrei (dekodierte Bytes bitidentisch) und nur, wenn er kleiner ist.
/// Der Predictor im Wörterbuch bleibt unberührt: Er wirkt auf den Inhalt,
/// nicht auf die Verpackung. Parallel läuft ausschließlich die reine
/// Byteschnur (inflate + zopfli); das Dokument-Handle bleibt seriell.
@Suite struct ZopfliRepackTests {

    // MARK: - Fixture

    /// Gültiger Content-Stream (PDF-Kommentarzeilen) mit PRNG-gestreuten
    /// Base36-Tokens: textnah genug, dass deflate komprimiert, entropiereich
    /// genug, dass die Verpackung die 64-KB-Schwelle überschreitet und
    /// Zopfli real gegen sie gewinnt.
    static func redundantContentStream(lines: Int = 3000) -> Data {
        var seed: UInt64 = 20260831
        func next(_ modulo: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(modulo))
        }
        var content = ""
        for i in 0..<lines {
            content += "% "
            if i % 23 == 0 {
                content += "variation \(i) — \(i * i) — "
            }
            for _ in 0..<6 {
                content += String(next(2_176_782_336), radix: 36) + " "
            }
            content += "\n"
        }
        return Data(content.utf8)
    }

    static func flateContentPDF(_ deflated: Data) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let content = b.addStream(dictionary: "/Filter/FlateDecode",
                                  data: deflated)
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "zopfli")
    }

    // MARK: - 1) Max-Preset repackt, verlustfrei und kleiner

    @Test(.hangGuard) func maxPresetRepacktGrossenFlateStream() throws {
        let content = Self.redundantContentStream()
        let deflated = try #require(ImageProcessor.flate(content))
        #expect(deflated.count >= CompressionExecutor.zopfliMinimumRawBytes,
                "Fixture liegt mit \(deflated.count) B unter der Schwelle")

        let url = try Self.flateContentPDF(deflated)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("zopfli-max-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(
            inputURL: url, outputURL: out,
            options: CompressionPresetFactory.maximum())
        #expect(outcome.execution.zopfliRepackedStreams >= 1,
                "Der Zopfli-Pass hat den Stream nicht angefasst")
        #expect(outcome.execution.zopfliEstimatedBytesSaved > 0,
                "Zopfli brachte nichts gegen die Ausgangsverpackung")

        // Verlustfrei: der dekodierte Inhalt ist bitidentisch.
        let core = try PDFCoreDocument(path: out.path)
        let candidate = try #require(try core.flateStreams(minimumRawBytes: 1).first)
        let raw = try #require(core.streamBytes(objectID: candidate.objectID))
        #expect(raw.count < deflated.count,
                "Der Stream ist nicht kleiner: \(deflated.count) → \(raw.count)")
        let inflated = try #require(ZopfliCodec.inflate(
            raw, maxContentBytes: CompressionExecutor.zopfliMaximumContentBytes))
        #expect(inflated == content,
                "Der dekodierte Inhalt hat sich verändert")

        // Strukturcheck wie `qpdf --check`.
        try core.check()
    }

    // MARK: - 2) Andere Presets fassen Flate-Streams nicht an

    @Test(.hangGuard) func smartPresetLaesstFlateStreamsByteidentisch() throws {
        let deflated = try #require(ImageProcessor.flate(
            Self.redundantContentStream()))
        let url = try Self.flateContentPDF(deflated)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("zopfli-smart-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: .smart)
        #expect(outcome.execution.zopfliRepackedStreams == 0,
                "Smart darf den Zopfli-Pass nicht fahren")

        let core = try PDFCoreDocument(path: out.path)
        let candidate = try #require(try core.flateStreams(minimumRawBytes: 1).first)
        let raw = try #require(core.streamBytes(objectID: candidate.objectID))
        // V2-11 – Der finale Single-Write rekompromittiert Flate-Streams
        // mit zlib Level 9 (verlustfrei, §15.6); die BYTES des Wrappers
        // sind daher kein Vertrag mehr – wohl aber der INHALT und das
        // Never-Grow am Wrapper.
        let content = try #require(
            ZopfliCodec.inflate(raw, maxContentBytes: 1 << 20),
            "Rekomprimierter Stream lässt sich nicht inflaten")
        #expect(content == Self.redundantContentStream(),
                "Der Streaminhalt wurde außerhalb des Max-Presets verändert")
        #expect(raw.count <= deflated.count,
                "Rekompression wuchs: \(deflated.count) → \(raw.count)")
    }
}
