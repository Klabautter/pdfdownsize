import Testing
import Foundation
@testable import PDFTools

/// Schnellschätzung über einen Ordner messen, ohne zu komprimieren.
///
/// Läuft nur auf Anforderung: `PDFTOOLS_ESTIMATE_CORPUS` (Ordner, rekursiv) und
/// `PDFTOOLS_ESTIMATE_OUT` (CSV). Der Vergleich mit den echten Größen geschieht
/// außerhalb, gegen die `summary.csv` eines Smoke-Laufs.
@Suite(.serialized) struct QuickEstimateReport {
    @Test(.measurementRun) func writeReport() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["PDFTOOLS_ESTIMATE_CORPUS"], !root.isEmpty,
              let out = env["PDFTOOLS_ESTIMATE_OUT"], !out.isEmpty else { return }
        let urls = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? [])
            .filter { $0.lowercased().hasSuffix(".pdf") }.sorted()
            .map { URL(fileURLWithPath: root).appendingPathComponent($0) }
        var csv = "file,preset,original,low,point,high,seconds\n"
        for url in urls {
            for (name, options) in [("Klein", CompressionOptions.make(mode: .small, customConfig: nil, stripMetadata: true, linearize: false)),
                                    ("Smart", CompressionOptions.make(mode: .smart, customConfig: nil, stripMetadata: true, linearize: false)),
                                    ("Qualität", CompressionOptions.make(mode: .quality, customConfig: nil, stripMetadata: true, linearize: false))] {
                let start = Date()
                guard let e = CompressionEstimator.quickEstimate(url: url, options: options) else {
                    csv += "\(url.lastPathComponent),\(name),,,,,\n"
                    continue
                }
                let seconds = Date().timeIntervalSince(start)
                csv += "\(url.lastPathComponent),\(name),\(e.originalBytes),\(e.lowBytes),"
                    + "\(e.pointBytes),\(e.highBytes),\(String(format: "%.3f", seconds))\n"
            }
        }
        try csv.write(toFile: out, atomically: true, encoding: .utf8)
    }
}
