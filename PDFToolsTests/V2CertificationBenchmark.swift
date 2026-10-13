import Testing
import Foundation
import CryptoKit
import PDFKit
@testable import PDFTools

/// V2-11 – Zertifizierungslauf V1 (Legacy-Pfad, Flags AUS) gegen V2
/// (Candidate-Engine, Flags ON) auf dem Smoke-30-Korpus.
///
/// Aufruf (nicht Teil der normalen Suite, env-gated):
///
///     TEST_RUNNER_PDFTOOLS_V2_CERT=1 \
///     TEST_RUNNER_PDFTOOLS_V2_CERT_OUT=<dir> \
///     TEST_RUNNER_PDFTOOLS_V2_CERT_CORPUS=<resolved smoke30> \
///     xcodebuild ... -only-testing:PDFToolsTests/V2CertificationBenchmark
///
/// Die V2-Outputs landen unter `<dir>/outputs` im Standard-Namensschema
/// (`<Kategorie>__<Stem>__<Preset>.pdf`), damit die bestehende
/// SmokeQualityVerification direkt darüber laufen kann. Die V1-Outputs
/// liegen daneben unter `<dir>/outputs_v1`.
@Suite struct V2CertificationBenchmark {

    private static let modes: [CompressionMode] = [.small, .smart, .quality]
    private static let operationTimeout: TimeInterval = 300
    private static let hardTimeout: TimeInterval = 330

    struct CertRecord: Codable {
        var engine: String
        var inputPath: String
        var category: String
        var preset: String
        var inputBytes: Int64
        var outputBytes: Int64
        var savedPercent: Double
        var runtimeSeconds: Double
        var pagesBefore: Int
        var pagesAfter: Int
        var returnedOriginal: Bool
        var success: Bool
        var error: String
        var qpdfCheck: String
        var pdfkitOpen: Bool
    }

    struct EnginePresetAggregate: Codable {
        var engine: String
        var preset: String
        var successful: Int
        var failed: Int
        var returnedOriginalCount: Int
        var totalInputBytes: Int64
        var totalOutputBytes: Int64
        var weightedSavingPercent: Double
        var medianSavingPercent: Double
        var medianRuntimeSeconds: Double
        var p90RuntimeSeconds: Double
    }

    struct MatrixCell: Codable {
        var engine: String
        var category: String
        var preset: String
        var successful: Int
        var failed: Int
        var inputBytes: Int64
        var outputBytes: Int64
        var weightedSavingPercent: Double
        var medianRuntimeSeconds: Double
    }

    @Test(.measurementRun) func certifyV1AgainstV2() async throws {
        let env = ProcessInfo.processInfo.environment
        let on = env["PDFTOOLS_V2_CERT"] ?? env["TEST_RUNNER_PDFTOOLS_V2_CERT"]
        guard on == "1" else { return }

        let fm = FileManager.default
        let corpus = URL(fileURLWithPath: env["PDFTOOLS_V2_CERT_CORPUS"]
            ?? env["TEST_RUNNER_PDFTOOLS_V2_CERT_CORPUS"]
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(
                "PDFToolsCertCorpus/smoke30-resolved").path)
        guard fm.fileExists(atPath: corpus.path) else {
            Issue.record("Zertifizierungskorpus fehlt: \(corpus.path)")
            return
        }

        let runID = Self.utcTimestamp()
        let outRoot = URL(fileURLWithPath: env["PDFTOOLS_V2_CERT_OUT"]
            ?? env["TEST_RUNNER_PDFTOOLS_V2_CERT_OUT"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("v2-cert-\(runID)").path)
        let outputsV2 = outRoot.appendingPathComponent("outputs")
        let outputsV1 = outRoot.appendingPathComponent("outputs_v1")
        let errorsDir = outRoot.appendingPathComponent("errors")
        for dir in [outputsV2, outputsV1, errorsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var jobs: [(category: String, file: URL)] = []
        let categories = ((try? fm.contentsOfDirectory(atPath: corpus.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        for category in categories {
            let dir = corpus.appendingPathComponent(category)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".pdf") && !$0.hasPrefix(".") }
                .sorted()
            for f in files { jobs.append((category, dir.appendingPathComponent(f))) }
        }
        guard !jobs.isEmpty else {
            Issue.record("Keine PDFs im Zertifizierungskorpus.")
            return
        }

        let compressor = Compressor()
        let qpdf = Self.repoRoot.appendingPathComponent("Vendor/qpdf/qpdf").path
        var records: [CertRecord] = []

        // Reihenfolge: je Preset erst der komplette V1-Block, dann V2 – die
        // V1-Blöcke bleiben mit der 205146-Baseline direkt vergleichbar.
        // PDFTOOLS_V2_CERT_ENGINES beschränkt die Arme (Teilnachläufe).
        let engines = (env["PDFTOOLS_V2_CERT_ENGINES"]
                       ?? env["TEST_RUNNER_PDFTOOLS_V2_CERT_ENGINES"]
                       ?? "V1,V2").split(separator: ",").map(String.init)
        for mode in Self.modes {
            for engine in engines {
                for job in jobs {
                    records.append(Self.runOne(
                        compressor: compressor, qpdfPath: qpdf,
                        input: job.file, category: job.category,
                        mode: mode, engine: engine,
                        outputsDir: engine == "V2" ? outputsV2 : outputsV1,
                        errorsDir: errorsDir, fm: fm))
                }
            }
        }

        let presets = Self.aggregate(records)
        let matrix = Self.aggregateMatrix(records)
        let meta = Self.runMeta(timestamp: runID)
        try Self.writeJSON(meta: meta, aggregates: presets, matrix: matrix,
                           records: records, runID: runID, corpus: corpus.path,
                           to: outRoot)
        try Self.writeReport(meta: meta, aggregates: presets, matrix: matrix,
                             records: records, runID: runID,
                             corpus: corpus.path, to: outRoot)
        print("V2 CERT DONE: \(records.count) Ops → \(outRoot.path)")
    }

    // MARK: - V2-Flagset (§26: mrc bleibt Advanced → AUS)
    //
    // V2-11-Ergebnis: classifierV2 bleibt AUS (§8.6-Acceptance auf Scan-
    // Inhalt verletzt, gemessen); alle übrigen Core-Flags ON.

    static func v2Options(for mode: CompressionMode) -> CompressionOptions {
        var options = CompressionOptions.make(mode: mode, customConfig: nil,
                                              stripMetadata: false,
                                              linearize: false)
        options.featureFlags.candidateEngine = true
        // §8.6-Reparatur: classifierPolicy ist jetzt Produktion-Default (.v2)
        // – der V2-Arm der Zertifizierung fährt folgerichtig mit .v2.
        options.featureFlags.selectiveFontSubset = true
        options.resourceGCPolicy = .auto
        options.featureFlags.pixelBudgetScheduler = true
        options.featureFlags.singleWrite = true
        // options.featureFlags.mrc bleibt false – MRC ist V2-Advanced (§26/§27)
        // und wird separat zertifiziert.
        return options
    }

    // MARK: - Einzeloperation

    private static func runOne(compressor: Compressor,
                               qpdfPath: String,
                               input: URL,
                               category: String,
                               mode: CompressionMode,
                               engine: String,
                               outputsDir: URL,
                               errorsDir: URL,
                               fm: FileManager) -> CertRecord {
        let inputBytes = (try? fm.attributesOfItem(
            atPath: input.path))?[.size] as? Int64 ?? 0
        let pagesBefore = pageCount(qpdfPath: qpdfPath, url: input)
        let started = Date()
        let deadline = Date().addingTimeInterval(operationTimeout)

        var result: CompressionResult?
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                if engine == "V2" {
                    result = try compressor.compress(
                        inputURL: input, options: v2Options(for: mode),
                        isCancelled: { Date() > deadline })
                } else {
                    result = try compressor.compress(
                        inputURL: input,
                        options: CompressionOptions.make(mode: mode,
                                                         customConfig: nil,
                                                         stripMetadata: false,
                                                         linearize: false),
                        isCancelled: { Date() > deadline })
                }
            } catch {
                failure = error
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + hardTimeout)
        if semaphore.wait(timeout: .now() + .zero) == .timedOut {
            task.cancel()
        }
        let runtime = Date().timeIntervalSince(started)

        var rec = CertRecord(
            engine: engine, inputPath: input.path, category: category,
            preset: mode.rawValue, inputBytes: inputBytes, outputBytes: 0,
            savedPercent: 0, runtimeSeconds: runtime, pagesBefore: pagesBefore,
            pagesAfter: -1, returnedOriginal: false, success: false,
            error: "", qpdfCheck: "not-run", pdfkitOpen: false)

        guard let r = result, failure == nil else {
            rec.error = Self.errorText(failure)
                + (result == nil && failure == nil
                    ? "TIMEOUT nach \(Int(hardTimeout))s" : "")
            rec.outputBytes = rec.inputBytes
            writeError(errorsDir: errorsDir, category: category,
                       file: input.lastPathComponent, preset: mode.rawValue,
                       engine: engine, text: rec.error)
            return rec
        }

        let deliveredURL = r.returnedOriginal ? input : r.outputURL
        let deliveredBytes = (try? fm.attributesOfItem(
            atPath: deliveredURL.path))?[.size] as? Int64 ?? 0
        rec.outputBytes = r.outputBytes > 0 ? r.outputBytes : Int64(deliveredBytes)
        rec.savedPercent = rec.inputBytes > 0
            ? (1.0 - Double(rec.outputBytes) / Double(rec.inputBytes)) * 100 : 0
        rec.returnedOriginal = r.returnedOriginal
        rec.pagesAfter = pageCount(qpdfPath: qpdfPath, url: deliveredURL)
        rec.pdfkitOpen = PDFDocument(url: deliveredURL) != nil
        rec.qpdfCheck = qpdfCheck(qpdfPath: qpdfPath, url: deliveredURL)

        let sizeOK = fm.fileExists(atPath: deliveredURL.path) && deliveredBytes > 0
        let pagesOK = rec.pagesBefore > 0
            ? rec.pagesAfter == rec.pagesBefore : rec.pagesAfter > 0
        rec.success = sizeOK && rec.pdfkitOpen && pagesOK
            && !rec.qpdfCheck.hasPrefix("fatal")

        // Delivered Output behalten – Namensschema wie der Smoke-Runner, damit
        // die SmokeQualityVerification die V2-Outputs direkt lesen kann.
        let stem = input.deletingPathExtension().lastPathComponent
        let target = outputsDir.appendingPathComponent(
            "\(category)__\(stem)__\(mode.rawValue).pdf")
        try? fm.removeItem(at: target)
        _ = try? fm.copyItem(at: deliveredURL, to: target)

        if !rec.success {
            writeError(errorsDir: errorsDir, category: category,
                       file: input.lastPathComponent, preset: mode.rawValue,
                       engine: engine,
                       text: "success=false pages "
                           + "\(rec.pagesBefore)->\(rec.pagesAfter)"
                           + " qpdf=\(rec.qpdfCheck)")
        }
        return rec
    }

    // MARK: - Aggregation

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = Double(sorted.count - 1) * p
        let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - Double(lo))
    }

    private static func aggregate(_ records: [CertRecord]) -> [EnginePresetAggregate] {
        var aggregates: [EnginePresetAggregate] = []
        for engine in ["V1", "V2"] {            for preset in modes.map(\.rawValue) {
                let group = records.filter {
                    $0.engine == engine && $0.preset == preset
                }
                guard !group.isEmpty else { continue }
                let ok = group.filter(\.success)
                let inTotal = group.reduce(Int64(0)) { $0 + $1.inputBytes }
                let outTotal = group.reduce(Int64(0)) { $0 + $1.outputBytes }
                let runtimes = ok.map(\.runtimeSeconds)
                aggregates.append(EnginePresetAggregate(
                    engine: engine, preset: preset,
                    successful: ok.count, failed: group.count - ok.count,
                    returnedOriginalCount: group.filter(\.returnedOriginal).count,
                    totalInputBytes: inTotal, totalOutputBytes: outTotal,
                    weightedSavingPercent: inTotal > 0
                        ? (1.0 - Double(outTotal) / Double(inTotal)) * 100 : 0,
                    medianSavingPercent: percentile(ok.map(\.savedPercent), 0.5),
                    medianRuntimeSeconds: percentile(runtimes, 0.5),
                    p90RuntimeSeconds: percentile(runtimes, 0.9)))
            }
        }
        return aggregates
    }

    private static func aggregateMatrix(_ records: [CertRecord]) -> [MatrixCell] {
        var cells: [MatrixCell] = []
        for engine in ["V1", "V2"] {
            for category in Set(records.map(\.category)).sorted() {
                for preset in modes.map(\.rawValue) {
                    let group = records.filter {
                        $0.engine == engine && $0.category == category
                            && $0.preset == preset
                    }
                    guard !group.isEmpty else { continue }
                    let ok = group.filter(\.success)
                    let inTotal = group.reduce(Int64(0)) { $0 + $1.inputBytes }
                    let outTotal = group.reduce(Int64(0)) { $0 + $1.outputBytes }
                    cells.append(MatrixCell(
                        engine: engine, category: category, preset: preset,
                        successful: ok.count, failed: group.count - ok.count,
                        inputBytes: inTotal, outputBytes: outTotal,
                        weightedSavingPercent: inTotal > 0
                            ? (1.0 - Double(outTotal) / Double(inTotal)) * 100 : 0,
                        medianRuntimeSeconds: percentile(
                            ok.map(\.runtimeSeconds), 0.5)))
                }
            }
        }
        return cells
    }

    // MARK: - Artefakte

    private static func errorText(_ error: Error?) -> String {
        guard let error else { return "" }
        if let e = error as? LocalizedError, let msg = e.errorDescription {
            return msg + " "
        }
        return String(describing: error) + " "
    }

    private static func writeError(errorsDir: URL, category: String,
                                   file: String, preset: String,
                                   engine: String, text: String) {
        let name = "\(engine)__\(category)__\(file)__\(preset).txt"
        try? text.data(using: .utf8)?
            .write(to: errorsDir.appendingPathComponent(name))
    }

    private static func utcTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date())
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func pageCount(qpdfPath: String, url: URL) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qpdfPath)
        p.arguments = ["--show-npages", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return -1 }
        guard p.terminationStatus == 0,
              let data = String(data: pipe.fileHandleForReading
                  .readDataToEndOfFile(), encoding: .utf8),
              let n = Int(data.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return -1 }
        return n
    }

    private static func qpdfCheck(qpdfPath: String, url: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qpdfPath)
        p.arguments = ["--check", url.path]
        let errPipe = Pipe(); p.standardOutput = Pipe(); p.standardError = errPipe
        do { try p.run(); p.waitUntilExit() } catch { return "fatal:spawn" }
        switch p.terminationStatus {
        case 0: return "ok"
        case 3: return "warnings"
        default:
            let err = String(data: errPipe.fileHandleForReading
                .readDataToEndOfFile(), encoding: .utf8) ?? ""
            let first = err.split(separator: "\n").first.map(String.init) ?? ""
            return "fatal:exit\(p.terminationStatus)"
                + (first.isEmpty ? "" : ": \(first)")
        }
    }

    private static func runMeta(timestamp: String) -> [String: String] {
        let info = ProcessInfo.processInfo
        return ["runID": timestamp,
                "host": "\(info.activeProcessorCount) CPUs",
                "macos": "\(info.operatingSystemVersion.majorVersion)."
                    + "\(info.operatingSystemVersion.minorVersion)",
                "engineV2": "candidateEngine+selectiveFontSubset"
                    + "+resourceGC(auto)+pixelBudgetScheduler+singleWrite",
                "engineV2mrc": "aus (V2-Advanced, §26)",
                "engineV2classifier": "legacy (§8.6-Acceptance auf Scan-"
                    + "Inhalt verletzt – V2-11-Messung, Flag bleibt AUS)"]
    }

    private static func writeJSON(meta: [String: String],
                                  aggregates: [EnginePresetAggregate],
                                  matrix: [MatrixCell],
                                  records: [CertRecord], runID: String,
                                  corpus: String, to outRoot: URL) throws {
        struct Top: Codable {
            var meta: [String: String]
            var corpus: String
            var scope: [String]
            var perEnginePreset: [EnginePresetAggregate]
            var categoryByPresetByEngine: [MatrixCell]
            var records: [CertRecord]
        }
        let top = Top(meta: meta, corpus: corpus,
                      scope: ["V1", "V2"] + modes.map(\.rawValue),
                      perEnginePreset: aggregates,
                      categoryByPresetByEngine: matrix, records: records)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(top).write(to: outRoot.appendingPathComponent("summary.json"),
                                  options: [.atomic])
    }

    private static func writeReport(meta: [String: String],
                                    aggregates: [EnginePresetAggregate],
                                    matrix: [MatrixCell], records: [CertRecord],
                                    runID: String,
                                    corpus: String, to outRoot: URL) throws {
        func mb(_ b: Int64) -> String {
            String(format: "%.2f MB", Double(b) / 1_048_576)
        }
        var md = "# V2-Zertifizierung V1 vs V2 – \(runID)\n\n"
        md += "Korpus: `\(corpus)` · 30 PDFs × Klein/Smart/Qualität × V1/V2\n\n"
        md += "V2-Flagset: \(meta["engineV2"] ?? "") · MRC: "
            + "\(meta["engineV2mrc"] ?? "aus")\n\n"

        md += "### Preset × Engine\n\n"
        md += "| Engine | Preset | ok | fail | retOrig | in | out | gewichtet | Median | Med-Laufzeit | p90-Laufzeit |\n"
        md += "|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|\n"
        for a in aggregates {
            md += "| \(a.engine) | \(a.preset) | \(a.successful) | \(a.failed) | "
            md += "\(a.returnedOriginalCount) | \(mb(a.totalInputBytes)) | "
            md += "\(mb(a.totalOutputBytes)) | "
            md += String(format: "%.1f%% | %.1f%% | %.1fs | %.1fs |\n",
                         a.weightedSavingPercent, a.medianSavingPercent,
                         a.medianRuntimeSeconds, a.p90RuntimeSeconds)
        }

        md += "\n### Kategorie × Preset × Engine (gewichtete Ersparnis, V2−V1)\n\n"
        let categories = Set(matrix.map(\.category)).sorted()
        md += "| Kategorie | Preset | V1 | V2 | Δ (V2−V1) |\n|---|---|--:|--:|--:|\n"
        for category in categories {
            for preset in modes.map(\.rawValue) {
                let v1 = matrix.first {
                    $0.engine == "V1" && $0.category == category
                        && $0.preset == preset
                }
                let v2 = matrix.first {
                    $0.engine == "V2" && $0.category == category
                        && $0.preset == preset
                }
                guard v1 != nil || v2 != nil else { continue }
                let delta = (v2?.weightedSavingPercent ?? 0)
                    - (v1?.weightedSavingPercent ?? 0)
                md += "| \(category) | \(preset) | "
                md += String(format: "%.1f%% | %.1f%% | %+.1fpp |\n",
                             v1?.weightedSavingPercent ?? 0,
                             v2?.weightedSavingPercent ?? 0, delta)
            }
        }

        var failRows = 0
        for r in records where !r.success {
            if failRows == 0 {
                md += "\n### Fehlgeschlagene Operationen\n\n"
                md += "| Engine | Kategorie | Preset | Fehler |\n|---|---|---|---|\n"
            }
            failRows += 1
            md += "| \(r.engine) | \(r.category) | \(r.preset) | "
            md += "\(r.error.isEmpty ? r.qpdfCheck : r.error) |\n"
        }
        if failRows == 0 {
            md += "\nKeine fehlgeschlagenen Operationen.\n"
        }
        try md.write(to: outRoot.appendingPathComponent("report.md"),
                     atomically: true, encoding: .utf8)
    }
}
