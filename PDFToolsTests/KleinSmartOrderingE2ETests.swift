import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Core-235-Befund 2026-09-30 (Klein-Lauf gegen Smart, gleicher Codestand):
/// Klein war auf 20 Dateien GRÖSSER als Smart – Karten bis 2,6× (fünf davon
/// im 10-Minuten-Limit), Farbscans 60 → 203 KB, Screenshots +30 %. Kein Test
/// prüfte, dass „Klein“ nie größer ausfällt als „Smart“.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten des Fixes:
///  1. Klein bleibt größer als Smart.
///  2. Klein wird kleiner, aber sichtbar kaputt (Seiten-SSIM unter der
///     Klein-Schwelle, Text weicht ab).
///  3. Smart ändert sich mit (der Fix darf nur Klein betreffen).
///  4. Klein läuft weiter ins Zeitlimit.
///  5. KEEP wird mit Rohbytes statt mit der Größe nach dem verlustfreien
///     Repack bewertet – ein schlechterer Kandidat schlägt das Original.
///
/// Ergebnisartefakt: `benchmark/p03-measurement-filter/klein-ordering.json`.
@Suite(.serialized) struct KleinSmartOrderingE2ETests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    static let cases = [
        "11_Maps_CAD_Technical/usgs_light_010_USGS_1_125000-scale_Quadrangle_for_Boston_MA_1943.pdf",
        "06_Scans_Color/light_001.pdf",
        "03_Screenshots_UI/phase1b_004.pdf",
        // Nachbefund 2026-10-01: Klein wählte Flate (12,6 KB je Bild) statt
        // KEEP, weil KEEP mit den Rohbytes (34 KB) bewertet wurde – der
        // Executor packt behaltene JPEGs aber verlustfrei auf ~8 KB um.
        "07_Scans_Grayscale/scan-like.pdf",
    ]

    @Test(.timeLimit(.minutes(20)), .needsLocalFiles("tmp/pdfs/core-235"))
    func kleinIstNieGroesserAlsSmart() throws {
        var artifact: [String: Any] = [:]
        for name in Self.cases {
            let url = Self.repoRoot.appendingPathComponent("tmp/pdfs/core-235/" + name)
            try #require(FileManager.default.fileExists(atPath: url.path), "Fehlt: \(url.path)")
            var bytes: [CompressionMode: Int64] = [:]
            var ssim: [CompressionMode: Double] = [:]
            for mode in [CompressionMode.smart, .small] {
                let options = CompressionOptions.make(mode: mode, customConfig: nil,
                                                      stripMetadata: false, linearize: false)
                let start = Date()
                let r = try Compressor().compress(inputURL: url, options: options,
                                                  isCancelled: nil, progress: nil)
                defer { try? FileManager.default.removeItem(at: r.outputURL) }
                #expect(Date().timeIntervalSince(start) < 300, "\(name) \(mode.rawValue): Laufzeit")
                bytes[mode] = r.outputBytes
                let pages = try RenderDifferential.compare(sourceURL: url, outputURL: r.outputURL, dpi: 144)
                ssim[mode] = pages.map(\.ssim).min() ?? 0
                let src = try #require(PDFDocument(url: url))
                let out = try #require(PDFDocument(url: r.outputURL))
                #expect(out.pageCount == src.pageCount)
                for i in 0..<src.pageCount {
                    #expect(out.page(at: i)?.string == src.page(at: i)?.string,
                            "\(name) \(mode.rawValue): Text Seite \(i + 1)")
                }
            }
            let small = try #require(bytes[.small]), smart = try #require(bytes[.smart])
            #expect(small <= smart, "\(name): Klein \(small) B > Smart \(smart) B")
            // Klein darf verlieren, aber nicht zerfallen (Klein-Seitenschwelle).
            #expect((ssim[.small] ?? 0) >= 0.93, "\(name): Klein-Seiten-SSIM \(ssim[.small] ?? 0)")
            artifact[name] = ["smart_bytes": smart, "klein_bytes": small,
                              "smart_min_ssim": ssim[.smart] ?? 0, "klein_min_ssim": ssim[.small] ?? 0]
        }
        let dir = Self.repoRoot.appendingPathComponent("benchmark/p03-measurement-filter", isDirectory: true)
        try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("klein-ordering.json"))
    }
}
