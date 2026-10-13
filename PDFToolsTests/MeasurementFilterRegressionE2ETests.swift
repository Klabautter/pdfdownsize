import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// P0.3 – Rückschritte seit 2026-09-04, E2E über den App-Pfad
/// (`CompressionOptions.make(mode:)`, MRC unter Budget aktiv).
///
/// Befund (Trace + Probe 2026-09-29): Die Qualitätsprüfung verkleinerte die
/// Referenz mit CoreGraphics (mittlere Interpolation), Kandidaten dagegen mit
/// dem Produktions-Resampler. Schon ein UNVERÄNDERTES Bild maß dadurch nur
/// SSIM 0,90–0,93 (schwächste Kacheln 0,71–0,87). Folgen:
///  • Graustufen-Scan: jedes JPEG fiel durch, die größere MRC-Zerlegung
///    gewann (151 KB statt 66 KB im September).
///  • Mischinhalt: ein 864-KB-Foto (407 DPI) blieb unverändert, weil keine
///    Verkleinerung das Gate hielt (1,98 MB statt 1,12 MB).
///
/// Vorher aufgeschriebene Fehlermöglichkeiten des Fixes:
///  1. Die Rückschritte bleiben (Filterunterschied weiter vorhanden).
///  2. Das Gate wird zu locker: sichtbare Verluste bei normaler Ansicht.
///  3. Seitenzahl/Text leiden.
///  4. Verbesserte Messung verschiebt andere Dateien ins Schlechtere –
///     abgedeckt durch den Core-235-Lauf, nicht durch diesen Test.
///  5. (Core-235-Befund) Die Grafik-Rückfallsuche reicht nur ihre KLEINSTE
///     bestandene Stufe weiter; verletzt die die Katastrophen-Grenze, bleibt
///     die Kachel im Original, obwohl eine sichere Stufe existiert
///     (USGS-Karte: 51 Kacheln in Originalauflösung).
///
/// Ergebnisartefakt: `benchmark/p03-measurement-filter/result.json`.
@Suite(.serialized) struct MeasurementFilterRegressionE2ETests {

    struct Case {
        let name: String
        let url: URL
        /// September-Stand + Luft; weit unter dem Rückschritt.
        let maximumBytes: Int64
        let minimumPageSSIM: Double
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    static var cases: [Case] {
        [Case(name: "scan-grayscale",
              url: repoRoot.appendingPathComponent("tmp/pdfs/core-235/07_Scans_Grayscale/phase1b_008.pdf"),
              // 2026-10-09, Smart-Ziel 220 statt 150 DPI: 48.845 → 102.810 Bytes
              // ((220/150)² ≈ 2,15); Grenze 3 % darüber, weiterhin unter dem
              // Fehlerbild von 151 KB (MRC gewann gegen fälschlich verworfene JPEGs).
              maximumBytes: 106_000, minimumPageSSIM: 0.96),
         Case(name: "mixed-content",
              url: CorpusRootResolver.resolve().root
                .appendingPathComponent("RealWorld/arXiv/2608.23486v1.pdf"),
              maximumBytes: 1_350_000, minimumPageSSIM: 0.98),
         // Fehlerbild: 5.408.178 Bytes (51 Kacheln im Original). Nach dem Fix
         // 4.472.179 Bytes; Grenze 3 % darüber. Der P0.1-Stand (4.041.650)
         // beruhte auf der fehlerhaften Messung: q-0,6-Kacheln liegen korrekt
         // gemessen über der Katastrophen-Grenze (0,072–0,084), gewählt wird
         // die sichere q-0,9-Stufe – Kartenbeschriftungen bleiben intakt.
         Case(name: "map-tiles",
              url: repoRoot.appendingPathComponent(
                "tmp/pdfs/core-235/11_Maps_CAD_Technical/usgs_light_010_USGS_1_125000-scale_Quadrangle_for_Boston_MA_1943.pdf"),
              // 2026-10-09, Smart-Ziel 220 DPI: 4.859.119 Bytes; Grenze 3 % darüber,
              // weiterhin unter dem Fehlerbild von 5.408.178 Bytes.
              maximumBytes: 5_010_000, minimumPageSSIM: 0.97)]
    }

    @Test(.timeLimit(.minutes(10)), .needsLocalFiles("tmp/pdfs/core-235"))
    func rueckschritteSindBehoben() throws {
        var artifact: [String: Any] = [:]
        for c in Self.cases {
            try #require(FileManager.default.fileExists(atPath: c.url.path), "Fehlt: \(c.url.path)")
            let options = CompressionOptions.make(mode: .smart, customConfig: nil,
                                                  stripMetadata: false, linearize: false)
            let r = try Compressor().compress(inputURL: c.url, options: options,
                                              isCancelled: nil, progress: nil)
            defer { try? FileManager.default.removeItem(at: r.outputURL) }

            #expect(r.outputBytes <= c.maximumBytes,
                    "\(c.name): \(r.outputBytes) Bytes – Ziel ≤ \(c.maximumBytes)")
            let pages = try RenderDifferential.compare(sourceURL: c.url,
                                                       outputURL: r.outputURL, dpi: 144)
            let minSSIM = pages.map(\.ssim).min() ?? 0
            #expect(minSSIM >= c.minimumPageSSIM,
                    "\(c.name): minimale Seiten-SSIM \(minSSIM) bei 144 DPI")
            let src = try #require(PDFDocument(url: c.url))
            let out = try #require(PDFDocument(url: r.outputURL))
            #expect(out.pageCount == src.pageCount)
            for i in 0..<src.pageCount {
                #expect(out.page(at: i)?.string == src.page(at: i)?.string,
                        "\(c.name): Text Seite \(i + 1) weicht ab")
            }
            artifact[c.name] = ["input_bytes": r.inputBytes, "output_bytes": r.outputBytes,
                                "min_page_ssim_144dpi": (minSSIM * 10000).rounded() / 10000,
                                "limit_bytes": c.maximumBytes]
        }
        let dir = Self.repoRoot.appendingPathComponent("benchmark/p03-measurement-filter", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("result.json"))
    }
}
