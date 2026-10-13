import Testing
import Foundation
@testable import PDFTools

/// Befund 2026-10-01 (`scan-like.pdf`, Klein): Ein verlustfreier Kandidat
/// wurde mit 12,6 KB geplant, landete aber mit 15,9 KB im Dokument. Der
/// finale Writer (`--recompress-flate`) dekodierte den Stream samt PNG-
/// Prädiktor und komprimierte ihn ohne Prädiktor neu. Zugleich bewertete die
/// Planung mit Apples zlib-Variante, die auf glatten Bildern bis 4× größer
/// ausfiel als echtes zlib – Planung und Dokument sprachen verschiedene
/// Größen.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten des Fixes:
///  1. Der Writer verändert unsere Bildstreams weiter (Größe ≠ Planung).
///  2. Prädiktor-Streams werden unlesbar (DecodeParms verloren, Bild kaputt).
///  3. Nicht angefasste Streams (Inhalt, Fonts, behaltene Bilder) werden
///     nicht mehr neu komprimiert – Strukturgewinn geht verloren.
///  4. Die Planung bewertet weiter mit den aufgeblähten Größen.
@Suite(.serialized) struct LosslessStreamFidelityE2ETests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 1 + 2 + 4: Geplante Bytes = Bytes im Dokument, Seite rendert gleich.
    /// Vorlage: großer Verlaufs-Screenshot (Grafikklasse → verlustfreie
    /// Verkleinerung); `scan-like.pdf` behält seit der KEEP-Bewertung die
    /// Originale und eignet sich dafür nicht mehr.
    @Test(.timeLimit(.minutes(5)))
    func verlustfreieKandidatenLandenWieGeplant() throws {
        let url = try PDFFixtures.gradientScreenshotPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url, options: .smart)
        let plannedLossless = planned.plan.actions.compactMap { action -> Int? in
            if case .losslessResize(_, _, _, _, let expected, _) = action { return expected }
            return nil
        }
        try #require(!plannedLossless.isEmpty, "Vorlage muss verlustfrei verkleinert werden")
        let r = try Compressor().compress(inputURL: url, options: .smart,
                                          isCancelled: nil, progress: nil)
        defer { try? FileManager.default.removeItem(at: r.outputURL) }
        let output = try PDFCoreDocument(path: r.outputURL.path)
        let flateImages = try output.imageResources().filter { $0.filters == [.flate] }
        let plannedTotal = plannedLossless.reduce(0, +)
        let actualTotal = flateImages.map(\.encodedByteCount).reduce(0, +)
        #expect(Double(actualTotal) <= Double(plannedTotal) * 1.01
                    && Double(actualTotal) >= Double(plannedTotal) * 0.99,
                "geplant \(plannedTotal) B, im Dokument \(actualTotal) B")
        let pages = try RenderDifferential.compare(sourceURL: url, outputURL: r.outputURL, dpi: 144)
        #expect((pages.map(\.ssim).min() ?? 0) >= 0.97, "Seiten-SSIM \(pages.map(\.ssim))")
    }

    /// 3: Behaltene, schwach komprimierte Flate-Bilder schrumpft der Writer
    /// weiter (Smart behält die Bilder dieses Dokuments).
    @Test(.timeLimit(.minutes(5)), .needsLocalFiles("tmp/pdfs/core-235"))
    func behalteneStreamsWerdenWeiterNeuKomprimiert() throws {
        let url = Self.repoRoot.appendingPathComponent(
            "tmp/pdfs/core-235/07_Scans_Grayscale/scan-like.pdf")
        let r = try Compressor().compress(inputURL: url, options: .smart,
                                          isCancelled: nil, progress: nil)
        defer { try? FileManager.default.removeItem(at: r.outputURL) }
        // Vorher: 104.365 B Eingabe, 24.262 B nach Neukompression.
        #expect(r.outputBytes <= 30_000, "Smart: \(r.outputBytes) B")
    }
}
