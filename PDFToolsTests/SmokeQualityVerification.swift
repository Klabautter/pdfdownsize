import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Qualitäts-Verifikation der Smoke-Baseline: rendert die DELIVERED Outputs
/// gegen die Originale und misst SSIM/CAR seitenweise (RenderDifferential,
/// 150 DPI, max. 12 gestreute Seiten je Dokument).
///
/// Zweck: Die Smoke-Benchmark fuhr bewusst OHNE Bildmetriken (schnelle
/// Baseline). Diese Prüfung holt die Qualitätsevidenz nach – NUR messend,
/// keine Kompression, keine Engine-Änderung.
///
/// Aufruf:
///     TEST_RUNNER_PDFTOOLS_SMOKE_QC=1 \
///     TEST_RUNNER_PDFTOOLS_SMOKE_RUN=<run-dir> \
///     xcodebuild ... -only-testing:PDFToolsTests/SmokeQualityVerification
@Suite struct SmokeQualityVerification {

    private static let maxPagesPerDoc = 12

    @Test(.measurementRun) func verifySmokeOutputs() async throws {
        let env = ProcessInfo.processInfo.environment
        let on = env["PDFTOOLS_SMOKE_QC"] ?? env["TEST_RUNNER_PDFTOOLS_SMOKE_QC"]
        guard on == "1" else { return }

        let fm = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let runDir = URL(fileURLWithPath: env["PDFTOOLS_SMOKE_RUN"]
            ?? env["TEST_RUNNER_PDFTOOLS_SMOKE_RUN"]
            ?? repoRoot.appendingPathComponent(
                "benchmark/compression-smoke/20260831-205146").path)
        let corpus = URL(fileURLWithPath: env["PDFTOOLS_SMOKE_CORPUS"]
            ?? env["TEST_RUNNER_PDFTOOLS_SMOKE_CORPUS"]
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(
                "Desktop/PDF_small/PDF_Corpus_System/Compression_Benchmark/Smoke_30").path)
        let outputsDir = runDir.appendingPathComponent("outputs")
        let presetNames = (env["PDFTOOLS_SMOKE_QC_PRESETS"]
            ?? env["TEST_RUNNER_PDFTOOLS_SMOKE_QC_PRESETS"])
            .map { value in
                value.split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            } ?? ["Klein", "Smart", "Qualität"]
        let requestedTier = env["PDFTOOLS_SMOKE_QC_TIER"]
            ?? env["TEST_RUNNER_PDFTOOLS_SMOKE_QC_TIER"]
        guard fm.fileExists(atPath: outputsDir.path) else {
            Issue.record("outputs/ fehlt: \(outputsDir.path)")
            return
        }

        struct Row {
            var category: String; var preset: String; var stem: String
            var pages: Int
            var ssimMin: Double; var ssimMean: Double; var ssimP05: Double
            var carMax: Double
            var pageSSIM: [Double]
        }
        var rows: [Row] = []

        let recordsURL = runDir.appendingPathComponent("records.json")
        let checkpointURL = runDir.appendingPathComponent("checkpoint.json")
        let manifestURL = fm.fileExists(atPath: checkpointURL.path) ? checkpointURL : recordsURL
        var successfulOutputNames: Set<String>?
        if fm.fileExists(atPath: manifestURL.path) {
            guard let records = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [[String: Any]] else {
                Issue.record("Ungültiges Output-Manifest: \(manifestURL.path)"); return
            }
            var names = Set<String>()
            for record in records where record["success"] as? Bool == true {
                if let requestedTier, record["tier"] as? String != requestedTier { continue }
                if let path = record["output_path"] as? String {
                    names.insert(URL(fileURLWithPath: path).lastPathComponent)
                } else if let input = record["inputPath"] as? String,
                          let category = record["category"] as? String,
                          let preset = record["preset"] as? String {
                    let stem = URL(fileURLWithPath: input).deletingPathExtension().lastPathComponent
                    names.insert("\(category)__\(stem)__\(preset).pdf")
                } else {
                    Issue.record("Erfolgreicher Manifest-Eintrag ohne Output-Zuordnung"); return
                }
            }
            successfulOutputNames = names
        }
        let available = try fm.contentsOfDirectory(atPath: outputsDir.path)
        for missing in (successfulOutputNames ?? []).subtracting(Set(available))
            where presetNames.contains(missing.dropLast(4).components(separatedBy: "__").last ?? "") {
            Issue.record("Erwarteter Output fehlt: \(missing)")
        }
        let outputs = available
            .filter { name in
                name.hasSuffix(".pdf")
                    && (successfulOutputNames?.contains(name) ?? true)
            }.sorted()

        for name in outputs {
            // <Kategorie>__<Stem>__<Preset>.pdf – ABER Stem kann selbst "__"
            // enthalten (RealWorld__<Titel>__<Hash>). Kategorie enthält kein
            // "__", der Preset ist aus fester Vokabelmenge: also vorne und
            // hinten abschneiden, Mitte = Stem.
            let parts = name.dropLast(4).components(separatedBy: "__")
            guard parts.count >= 3, presetNames.contains(parts.last!)
            else { continue }
            let preset = parts.last!
            let stem = parts.dropFirst().dropLast().joined(separator: "__")
            let category = parts[0]

            let outputURL = outputsDir.appendingPathComponent(name)
            let original = corpus.appendingPathComponent(category)
                .appendingPathComponent(stem + ".pdf").resolvingSymlinksInPath()
            guard fm.fileExists(atPath: original.path) else {
                Issue.record("Original fehlt: \(original.path)"); continue
            }

            guard let outDoc = PDFDocument(url: outputURL),
                  let srcDoc = PDFDocument(url: original) else {
                Issue.record("PDF nicht lesbar: \(name)"); continue
            }
            let n = srcDoc.pageCount
            guard n > 0, n == outDoc.pageCount else {
                Issue.record("Seitenzahl ungleich oder leer: \(name) Original=\(n), Output=\(outDoc.pageCount)"); continue
            }

            // Gestreute Stichprobe bei großen Dokumenten (Renderbudget).
            let indices: [Int]
            if n <= Self.maxPagesPerDoc {
                indices = Array(0..<n)
            } else {
                let stride = Double(n - 1) / Double(Self.maxPagesPerDoc - 1)
                indices = (0..<Self.maxPagesPerDoc).map { Int((Double($0) * stride).rounded()) }
            }
            let mapping = Dictionary(uniqueKeysWithValues: indices.map { ($0, $0) })

            let comparisons = try RenderDifferential.compare(
                sourceURL: original, outputURL: outputURL,
                dpi: RenderDifferential.standardDPI, pageMapping: mapping)
            guard comparisons.count == indices.count else {
                Issue.record("Unvollständige Render-Stichprobe: \(name)"); continue
            }
            let ssims = comparisons.map(\.ssim).sorted()
            let p05idx = max(0, Int((Double(ssims.count - 1) * 0.05).rounded()))
            rows.append(Row(
                category: category, preset: preset, stem: stem,
                pages: comparisons.count,
                ssimMin: ssims.first ?? 0, ssimMean: ssims.reduce(0, +) / Double(ssims.count),
                ssimP05: ssims[p05idx],
                carMax: comparisons.map(\.changedAreaRatio).max() ?? 0, pageSSIM: ssims))
        }

        if rows.isEmpty { Issue.record("Keine Dokument-/Preset-Paare verifiziert") }

        // Artefakte schreiben.
        var csv = "category,stem,preset,pages_sampled,ssim_min,ssim_mean,ssim_p05,car_max\n"
        for r in rows {
            csv += "\(r.category),\(r.stem),\(r.preset),\(r.pages),"
            csv += String(format: "%.4f,%.4f,%.4f,%.4f\n",
                          r.ssimMin, r.ssimMean, r.ssimP05, r.carMax)
        }
        try csv.write(to: runDir.appendingPathComponent("quality.csv"),
                      atomically: true, encoding: .utf8)

        // Dokumentmittel und tatsächliche Werte aller Stichprobenseiten getrennt.
        func agg(_ preset: String) -> (mean: Double, min: Double, p05: Double,
                                       below090: Int, below095: Int, pages: Int) {
            let rs = rows.filter { $0.preset == preset }
            let all = rs.map(\.ssimMean)
            let mins = rs.map(\.ssimMin)
            let p05s = rs.map(\.ssimP05).sorted()
            let pages = rs.reduce(0) { $0 + $1.pages }
            let below090 = rs.reduce(0) { $0 + ($1.ssimMin < 0.90 ? 1 : 0) }
            let below095 = rs.reduce(0) { $0 + ($1.ssimMin < 0.95 ? 1 : 0) }
            return (all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count),
                    mins.min() ?? 0,
                    p05s.isEmpty ? 0 : p05s[p05s.count / 20 * (p05s.count >= 20 ? 1 : 0)],
                    below090, below095, pages)
        }

        var md = "# Smoke-Qualitätsverifikation (nachträglich, messend)\n\n"
        md += "RenderDifferential 150 DPI, max. \(Self.maxPagesPerDoc) gestreute Seiten je Dokument, "
            + "\(rows.count) Dokument-/Preset-Paare.\n\n"
        md += "| Preset | Paare | Ø SSIM (je Doc) | Ø SSIM (Stichprobenseite) | Stichprobenseiten | min SSIM | Docs min<0,90 | Docs min<0,95 | max CAR |\n"
        md += "|---|--:|--:|--:|--:|--:|--:|--:|--:|\n"
        for preset in presetNames {
            let a = agg(preset)
            let carMax = rows.filter { $0.preset == preset }.map(\.carMax).max() ?? 0
            md += "| \(preset) | \(rows.filter { $0.preset == preset }.count) | "
            let pages = rows.filter { $0.preset == preset }.flatMap(\.pageSSIM)
            let pageMean = pages.isEmpty ? 0 : pages.reduce(0, +) / Double(pages.count)
            md += String(format: "%.4f | %.4f | %d | %.4f | %d | %d | %.3f |\n",
                         a.mean, pageMean, pages.count, a.min, a.below090, a.below095, carMax)
        }
        md += "\nHinweis: Seiten-SSIM ist ein INDIKATOR – die Produktions-Gates "
            + "arbeiten bildebene (Multi-Gate je Bild mit Klasse/Preset-Grenzwerten) "
            + "und sind dort teils strenger, teils toleranter als ein Seitenwert.\n"
        try md.write(to: runDir.appendingPathComponent("quality-report.md"),
                     atomically: true, encoding: .utf8)

        // Harte Erwartung: KEIN delivered Output darf strukturell unähnlich sein.
        for r in rows where r.ssimMin < 0.80 {
            Issue.record("\(r.preset) \(r.stem): min SSIM \(String(format: "%.3f", r.ssimMin)) < 0,80")
        }
        print("QC DONE: \(rows.count) Paare verifiziert")
    }
}
