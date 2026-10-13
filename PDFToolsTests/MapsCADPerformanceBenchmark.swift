import Testing
import Foundation
@testable import PDFTools

/// Masterplan §15.8 – Maps/CAD-Hotspot-Messlauf (NUR LESEN auf dem Korpus).
///
/// Aufruf (nicht Teil der normalen Suite, env-gated wie der Smoke-Benchmark):
///
///     TEST_RUNNER_PDFTOOLS_MAPS_BENCH=1 \
///     xcodebuild -project PDFTools.xcodeproj -scheme PDFTools test \
///       -only-testing:PDFToolsTests/MapsCADPerformanceBenchmark \
///       -parallel-testing-enabled NO
///
/// Misst auf den zwei USGS-Karten-Fixtures des Smoke_30-Korpus
/// (Kategorie 11_Maps_CAD_Technical) drei Konfigurationen:
///
///   V1-Legacy            – Flags aus (Produktionsstand vor V2-9)
///   V2-Scheduler         – candidateEngine + pixelBudgetScheduler
///   V2-Scheduler+Write   – + singleWrite (moderner Pfad)
///
/// Kein fixes Laufzeitziel (§15.8) – der Rapport vergleicht dieselben
/// Inputs auf derselben Hardware über die StageTimings (§7.3).
@Suite struct MapsCADPerformanceBenchmark {

    private static func fixtures() throws -> [URL] {
        let corpus = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path)
            .appendingPathComponent("Desktop/PDF_small/PDF_Corpus_System/"
                + "Compression_Benchmark/Smoke_30/11_Maps_CAD_Technical")
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: corpus, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { $0.resolvingSymlinksInPath() }   // Symlinks nur LESEND auflösen
        guard !files.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        return files
    }

    private struct Run {
        var config: String
        var fixture: String
        var wallSeconds: Double
        var outputBytes: Int64
        var stage: StageTimings
    }

    private static func options(_ scheduler: Bool, _ singleWrite: Bool) -> CompressionOptions {
        var options = CompressionOptions.make(mode: .smart, customConfig: nil,
                                              stripMetadata: false, linearize: false)
        options.featureFlags.candidateEngine = true
        if scheduler {
            options.featureFlags.pixelBudgetScheduler = true
            options.pixelBudgetBytes = 256 * 1024 * 1024
        }
        options.featureFlags.singleWrite = singleWrite
        return options
    }

    @Test func mapsCADMesslauf() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PDFTOOLS_MAPS_BENCH"] == "1"
            || env["TEST_RUNNER_PDFTOOLS_MAPS_BENCH"] == "1" else { return }

        let configs: [(label: String, scheduler: Bool, singleWrite: Bool)] = [
            ("V1-Legacy", false, false),
            ("V2-Scheduler", true, false),
            ("V2-Scheduler+Write", true, true),
        ]
        let iterations = 3
        let inputs = try Self.fixtures()
        var runs: [Run] = []
        let compressor = Compressor()
        for config in configs {
            for fixture in inputs {
                for _ in 0..<iterations {
                    let timer = StageTimer()
                    let started = Date()
                    let result = try compressor.compress(
                        inputURL: fixture,
                        options: Self.options(config.scheduler, config.singleWrite),
                        stageTimer: timer)
                    let wall = Date().timeIntervalSince(started)
                    runs.append(Run(
                        config: config.label,
                        fixture: fixture.deletingPathExtension().lastPathComponent,
                        wallSeconds: wall,
                        outputBytes: result.outputBytes,
                        stage: timer.timings))
                    try? FileManager.default.removeItem(at: result.outputURL)
                }
            }
        }

        // Tabelle: je Konfiguration Median über alle Läufe beider Fixtures
        // (p50-ähnlich bei 2 Fixtures × 3 Iterationen) plus p90-ähnlich max.
        var table = "\n=== MAPS/CAD §15.8 (kein fixes Ziel; gleiche Hardware, gleiche Inputs) ===\n"
        table += "config            |   wall p50 | wall max |  exec_ms | cand_ms | struct_ms | write_ms | out MB\n"
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        for config in configs {
            let group = runs.filter { $0.config == config.label }
            guard !group.isEmpty else { continue }
            let label = config.label.padding(toLength: 16, withPad: " ", startingAt: 0)
            table += "\(label)"
                + String(format: " | %10.1fs | %7.1fs | %8.0f | %7.0f | %9.0f | %8.0f | %5.1f\n",
                         median(group.map(\.wallSeconds)),
                         (group.map(\.wallSeconds).max() ?? 0),
                         median(group.map { $0.stage.executionMs }),
                         median(group.map { $0.stage.candidateGenerationMs }),
                         median(group.map { $0.stage.structureMs }),
                         median(group.map { $0.stage.writeMs }),
                         median(group.map { Double($0.outputBytes) / 1_048_576 }))
        }
        for run in runs {
            let name = run.fixture.count > 40
                ? String(run.fixture.suffix(40)) : run.fixture
            table += String(format: "  · %6.1fs (exec %6.0f, cand %6.0f, struct %6.0f, write %5.0f) → %lld B  %@\n",
                            run.wallSeconds, run.stage.executionMs,
                            run.stage.candidateGenerationMs, run.stage.structureMs,
                            run.stage.writeMs, run.outputBytes, name as NSString)
        }
        print(table)
    }
}
