import Foundation

/// Messlauf ohne Oberfläche (2026-10-13), für Laufzeitvergleiche im
/// RELEASE-Build – Debug verzerrt die Zeiten, und Tests lassen sich im
/// Release nicht gegen das Modul bauen.
///
///     PDFdownsize.app/Contents/MacOS/PDFdownsize \
///         --bench <eingabe.pdf> --mode klein|smart|qualitaet \
///         --report <bericht.json> [--out <ausgabe.pdf>]
///
/// Fährt genau den Produktionspfad (`Compressor.compress`), schreibt
/// Wandzeit, Prozessorzeit, Stufenzeiten und die Ausgabegröße als JSON und
/// beendet den Prozess, bevor ein Fenster entsteht. Kein Netz, kein Zustand.
enum BenchmarkMode {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: "--bench"),
              index + 1 < arguments.count else { return }
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let input = URL(fileURLWithPath: arguments[index + 1])
        let mode: CompressionMode = switch value("--mode") {
        case "klein": .small
        case "qualitaet": .quality
        default: .smart
        }
        var report: [String: Any] = ["input": input.lastPathComponent,
                                     "mode": value("--mode") ?? "smart",
                                     "input_bytes": Compressor.fileSize(of: input)]
        let timer = StageTimer()
        let cpuBefore = processorSeconds()
        let start = ContinuousClock.now
        do {
            let result = try Compressor().compress(inputURL: input, mode: mode, stageTimer: timer)
            report["wall_ms"] = stageMs(since: start)
            report["cpu_ms"] = (processorSeconds() - cpuBefore) * 1000
            report["output_bytes"] = result.outputBytes
            report["returned_original"] = result.returnedOriginal
            for field in StageTimings.Field.allCases {
                report[StageTimings.jsonKey(field)] = timer.timings.value(field)
            }
            if let out = value("--out") {
                let target = URL(fileURLWithPath: out)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: result.outputURL, to: target)
            }
            try? FileManager.default.removeItem(at: result.outputURL)
        } catch {
            report["error"] = String(describing: error)
        }
        if let path = value("--report"),
           let data = try? JSONSerialization.data(withJSONObject: report,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        exit(report["error"] == nil ? 0 : 1)
    }

    /// Nutzer- plus Systemzeit des Prozesses.
    private static func processorSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
