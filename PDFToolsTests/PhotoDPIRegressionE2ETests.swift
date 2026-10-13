import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// P0.1 – Foto-Regression, E2E über den Produktionspfad (`Compressor`).
///
/// Befund (2026-09-29, Trace `PDFTOOLS_JPEG_SEARCH_TRACE`): Auf Seite 4 von
/// `RealWorld/arXiv/2608.23479v1.pdf` bleiben sechs 2000×2000-px-Bilder
/// (≈ 1.850 DPI) erhalten. Die Qualitätsprüfung verglich jede Stufe auf
/// einer festen 320-px-Stichprobe des Originals; ein auf die Ziel-DPI
/// verkleinertes Bild (163 px bei 150 DPI) wurde dafür hochskaliert und fiel
/// allein wegen der erlaubten Verkleinerung durch (SSIM 0,83 bei q = 0,9).
/// Smart lieferte 54 % statt der früheren 95 %.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten des Fixes (AGENTS.md):
///  1. Die erlaubte Verkleinerung wird weiter abgelehnt → Ausgabe bleibt groß.
///  2. Das Gate wird zu locker → Bilder landen deutlich UNTER der Ziel-DPI.
///  3. Bei normaler Ansicht (100 % auf Retina ≈ 144 px/Zoll) wird die Seite
///     sichtbar schlechter.
///  4. Dokumentfunktion leidet: Seitenzahl oder Text ändern sich.
///  5. Verkleinerung auf die Ziel-DPI umgeht jede Messung, auch
///     Farbwandlung/Qualitätsverlust (Review 2026-09-26, P1) – abgedeckt in
///     `QualityGateGridTests` (Messraster bleibt am Original verankert).
///
/// Ergebnisartefakt: `benchmark/p01-photo-dpi/result.json`.
@Suite struct PhotoDPIRegressionE2ETests {

    static let corpusFile = "RealWorld/arXiv/2608.23479v1.pdf"
    /// Smart-Ziel 220 DPI (bis 2026-10-09: 150); die Leiter darf eine Stufe darunter
    /// wählen, aber nicht beliebig tief.
    static let minimumPlacedDPI = 120.0
    /// Historisch 1.234.729 Bytes; Obergrenze mit Luft, aber weit unter den
    /// 12,5 MB der Regression.
    static let maximumOutputBytes: Int64 = 3_000_000
    static let minimumPageSSIM = 0.985

    @Test(.timeLimit(.minutes(10)))
    func smartVerkleinertFotosAufZielDPI() throws {
        let root = CorpusRootResolver.resolve().root
        let input = root.appendingPathComponent(Self.corpusFile)
        try #require(FileManager.default.fileExists(atPath: input.path),
                     "Korpusdatei fehlt: \(input.path)")

        let result = try Compressor().compress(inputURL: input, options: .smart,
                                               isCancelled: nil, progress: nil)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        // 1 – Größe
        #expect(result.outputBytes <= Self.maximumOutputBytes,
                "Smart-Ausgabe \(result.outputBytes) Bytes – Ziel ≤ \(Self.maximumOutputBytes)")

        // 2 – keine Bilder weit unter der Ziel-DPI
        let output = try PDFCoreDocument(path: result.outputURL.path)
        let placedDPIs = try output.imageResources()
            .filter { $0.placements.contains { $0.pageIndex == 3 } }
            .compactMap(\.effectiveDPI)
        #expect(!placedDPIs.isEmpty)
        for dpi in placedDPIs {
            #expect(dpi >= Self.minimumPlacedDPI,
                    "Bild auf Seite 4 mit \(Int(dpi)) DPI – unter \(Int(Self.minimumPlacedDPI))")
        }

        // 3 – normale Ansicht: Retina 100 % ≈ 144 px/Zoll
        let pages = try RenderDifferential.compare(sourceURL: input,
                                                   outputURL: result.outputURL, dpi: 144)
        #expect(pages.count == 5)
        let minSSIM = pages.map(\.ssim).min() ?? 0
        #expect(minSSIM >= Self.minimumPageSSIM,
                "Minimale Seiten-SSIM \(minSSIM) bei 144 DPI")

        // 4 – Dokumentfunktion
        let src = try #require(PDFDocument(url: input))
        let out = try #require(PDFDocument(url: result.outputURL))
        #expect(out.pageCount == src.pageCount)
        for index in 0..<src.pageCount {
            #expect(out.page(at: index)?.string == src.page(at: index)?.string,
                    "Text von Seite \(index + 1) weicht ab")
        }

        try Self.writeArtifact([
            "input": Self.corpusFile,
            "input_bytes": result.inputBytes,
            "output_bytes": result.outputBytes,
            "saved_percent": (1 - Double(result.outputBytes) / Double(result.inputBytes)) * 100,
            "page4_image_dpi": placedDPIs.map { Int($0.rounded()) }.sorted(),
            "page_ssim_144dpi": pages.map { ($0.ssim * 10000).rounded() / 10000 },
            "limits": ["max_output_bytes": Self.maximumOutputBytes,
                       "min_placed_dpi": Self.minimumPlacedDPI,
                       "min_page_ssim": Self.minimumPageSSIM],
        ])
    }

    static func writeArtifact(_ payload: [String: Any]) throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("benchmark/p01-photo-dpi", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("result.json"))
    }
}
