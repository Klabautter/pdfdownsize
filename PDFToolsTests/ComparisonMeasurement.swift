import Testing
import Foundation
@testable import PDFTools

@Suite(.serialized) struct SemanticComparisonMeasurement {

    @Test(.measurementRun) func compareExternalSemantics() throws {
        let env = ProcessInfo.processInfo.environment
        guard let sourcePath = env["PDFTOOLS_COMPARE_SOURCE"],
              let outputPath = env["PDFTOOLS_COMPARE_OUTPUT"],
              !sourcePath.isEmpty, !outputPath.isEmpty else {
            print("Semantikvergleich übersprungen: nicht angefordert.")
            return
        }

        let source = URL(fileURLWithPath: sourcePath)
        let output = URL(fileURLWithPath: outputPath)
        let report = PDFValidator.validate(
            outputURL: output,
            referenceURL: source,
            policy: .compression)

        print("Semantik:  \(report.isValid ? "PASS" : "FAIL")")
        for failure in report.failures {
            print("  FEHLER: \(failure)")
        }
        for warning in report.warnings {
            print("  WARNUNG: \(warning)")
        }
        #expect(report.isValid, "Die Ausgabe verliert PDF-Semantik")
    }
}

/// Rendervergleich für beliebige externe Kompressoren.
///
/// Der Korpus-Runner misst nur Ausgaben, die er selbst erzeugt. Für einen
/// fairen Vergleich mit Ghostscript, PDF24 oder anderen Werkzeugen brauchen
/// wir dieselbe PDFKit-basierte Metrik auf einer bereits vorhandenen Datei.
@Suite(.serialized) struct ComparisonMeasurement {

    @Test(.measurementRun) func compareExternalOutput() throws {
        let env = ProcessInfo.processInfo.environment
        guard let sourcePath = env["PDFTOOLS_COMPARE_SOURCE"],
              let outputPath = env["PDFTOOLS_COMPARE_OUTPUT"],
              !sourcePath.isEmpty, !outputPath.isEmpty else {
            print("Rendervergleich übersprungen: nicht angefordert.")
            return
        }

        let source = URL(fileURLWithPath: sourcePath)
        let output = URL(fileURLWithPath: outputPath)
        let comparisons = try RenderDifferential.compare(
            sourceURL: source, outputURL: output)
        guard !comparisons.isEmpty else {
            Issue.record("Keine vergleichbaren Seiten")
            return
        }

        let count = Double(comparisons.count)
        let meanSSIM = comparisons.reduce(0) { $0 + $1.ssim } / count
        let meanCAR = comparisons.reduce(0) { $0 + $1.changedAreaRatio } / count
        let meanMAD = comparisons.reduce(0) { $0 + $1.meanAbsDiff } / count
        let worstSSIM = comparisons.min(by: { $0.ssim < $1.ssim })!
        let worstCAR = comparisons.max(by: {
            $0.changedAreaRatio < $1.changedAreaRatio
        })!
        let worstInk = comparisons.max(by: { $0.inkDelta < $1.inkDelta })!

        let text = [
            "Quelle:    \(source.lastPathComponent)",
            "Ausgabe:   \(output.lastPathComponent)",
            "Seiten:    \(comparisons.count)",
            String(format: "SSIM:      %.6f Mittel · %.6f Minimum (Seite %d)",
                   meanSSIM, worstSSIM.ssim, worstSSIM.outputPageIndex + 1),
            String(format: "CAR:       %.6f Mittel · %.6f Maximum (Seite %d)",
                   meanCAR, worstCAR.changedAreaRatio,
                   worstCAR.outputPageIndex + 1),
            String(format: "MAD:       %.6f Mittel", meanMAD),
            String(format: "Ink-Delta: %.6f Maximum (Seite %d)",
                   worstInk.inkDelta, worstInk.outputPageIndex + 1)
        ].joined(separator: "\n")

        if let reportPath = env["PDFTOOLS_COMPARE_REPORT"],
           !reportPath.isEmpty {
            try text.write(to: URL(fileURLWithPath: reportPath),
                           atomically: true, encoding: .utf8)
        }
        print(text)
    }
}
