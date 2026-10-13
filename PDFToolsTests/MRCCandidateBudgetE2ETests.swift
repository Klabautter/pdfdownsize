import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// P0.3-Nachbefund (Core-235, 2026-09-30): Fünf Schwarzweiß-Scans
/// (`08_Scans_Monochrome/light_00x`) wuchsen gegenüber P0.1 von ~7,6 KB auf
/// ~15,5 KB.
///
/// Ursache (Trace + Probe): Das Kandidatenbudget je Bild (§9.2, zehn inkl.
/// KEEP) füllte sich mit acht JPEG-Stufen, die seit der korrigierten Messung
/// alle bestehen. Die MRC-Seitenbündel werden erst DANACH aufgenommen – die
/// Stufe „balanced“ (6.287 B, Seiten-QA SSIM 0,9983 wie „conservative“)
/// fiel ohne Ablehnungsgrund aus dem Set, gewählt wurde „conservative“
/// (14.312 B).
///
/// Vorher aufgeschriebene Fehlermöglichkeiten des Fixes:
///  1. Die MRC-Stufen fehlen weiter im Set (Budget weiter von JPEG belegt).
///  2. Das Budget wird überschritten (mehr als zehn Kandidaten je Bild).
///  3. Die freigehaltenen Plätze verdrängen den JPEG-Kandidaten, der ohne
///     MRC gewinnen müsste (Bilder ohne MRC-Bündel dürfen nichts verlieren –
///     abgedeckt durch den Core-235-Lauf).
///  4. Qualität/Text der Seite leiden (die kleinere Stufe muss dieselbe
///     Seiten-QA bestanden haben).
///
/// Ergebnisartefakt: `benchmark/p03-measurement-filter/mrc-budget.json`.
@Suite(.serialized) struct MRCCandidateBudgetE2ETests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test(.timeLimit(.minutes(5)), .needsLocalFiles("tmp/pdfs/core-235"))
    func mrcStufenWerdenNichtVomJPEGBudgetVerdraengt() throws {
        let url = Self.repoRoot.appendingPathComponent(
            "tmp/pdfs/core-235/08_Scans_Monochrome/light_001.pdf")
        try #require(FileManager.default.fileExists(atPath: url.path), "Fehlt: \(url.path)")
        let options = CompressionOptions.make(mode: .smart, customConfig: nil,
                                              stripMetadata: false, linearize: false)
        let r = try Compressor().compress(inputURL: url, options: options,
                                          isCancelled: nil, progress: nil)
        defer { try? FileManager.default.removeItem(at: r.outputURL) }

        // P0.1-Stand 7.569 B (balanced-Stufe); Fehlerbild 15.487 B.
        #expect(r.outputBytes <= 9_000, "\(r.outputBytes) Bytes – Ziel ≤ 9.000")

        let pages = try RenderDifferential.compare(sourceURL: url, outputURL: r.outputURL, dpi: 144)
        let minSSIM = pages.map(\.ssim).min() ?? 0
        #expect(minSSIM >= 0.97, "minimale Seiten-SSIM \(minSSIM) bei 144 DPI")
        let src = try #require(PDFDocument(url: url))
        let out = try #require(PDFDocument(url: r.outputURL))
        #expect(out.pageCount == src.pageCount)

        let dir = Self.repoRoot.appendingPathComponent("benchmark/p03-measurement-filter",
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact: [String: Any] = ["input_bytes": r.inputBytes, "output_bytes": r.outputBytes,
                                       "min_page_ssim_144dpi": (minSSIM * 10000).rounded() / 10000,
                                       "limit_bytes": 9_000]
        try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("mrc-budget.json"))
    }
}
