import Testing
import Foundation
import CryptoKit
import PDFKit
@testable import PDFTools

/// Compression-Smoke-Benchmark – NUR die Produktionspipeline messen.
///
/// Aufruf (nicht Teil der normalen Suite, env-gated wie das Accuracy-Lab):
///
///     TEST_RUNNER_PDFTOOLS_SMOKE_CORPUS=~/Desktop/.../Smoke_30 \
///     TEST_RUNNER_PDFTOOLS_SMOKE_OUT=<repo>/benchmark/compression-smoke/<run-id> \
///     Scripts/run-smoke-benchmark.sh
///
/// Fakten, die dieser Runner voraussetzt (im Quellcode verifiziert):
/// - `Compressor` ist der Produktions-Einstieg; der modus-basierte Aufruf
///   übersetzt EINMAL in `CompressionOptions` und fährt
///   `CompressionPipeline` (libqpdf) + Struktur-Pass + Validator.
/// - Nutzer-Presets: `CompressionMode.small/smart/quality` (Klein/Smart/
///   Qualität). `custom` ist parametrisiert und wird hier bewusst NICHT
///   gefahren; `CompressionOptions.maximum` (Zopfli-Pfad) ebenfalls nicht.
/// - `CompressionResult.returnedOriginal` ist KEIN Fehler, sondern die
///   No-Regression-Größenpolitik (Ausgabe >= Eingabe → Original durchgereicht).
///
/// Nur schnelle Validierung: Datei vorhanden, >0 Bytes, PDFKit öffnet,
/// Seitenzahl unverändert, `qpdf --check` ohne strukturellen Fehler.
/// KEIN Rendering, KEIN SSIM/CAR/OCR, KEINE Assembly-Tests.
@Suite struct CompressionSmokeBenchmark {

    private static let modes: [CompressionMode] = [.small, .smart, .quality]
    private static let standardOperationTimeout: TimeInterval = 180
    private static let largeOperationTimeout: TimeInterval = 600
    private static let veryLargeOperationTimeout: TimeInterval = 900
    private static let hardTimeoutGrace: TimeInterval = 20

    private static func requestedModes(_ env: [String: String]) -> [CompressionMode] {
        guard let raw = env["PDFTOOLS_SMOKE_MODES"]
                ?? env["TEST_RUNNER_PDFTOOLS_SMOKE_MODES"] else {
            return modes
        }
        let selected = raw.split(separator: ",").compactMap { token in
            let name = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
            return modes.first { $0.rawValue == name }
        }
        return selected.isEmpty ? modes : selected
    }

    struct RunRecord: Codable {
        var inputPath: String
        var category: String
        var preset: String
        var inputBytes: Int64
        var outputBytes: Int64
        var savedBytes: Int64
        var savedPercent: Double
        var runtimeSeconds: Double
        var pagesBefore: Int
        var pagesAfter: Int
        var returnedOriginal: Bool
        var alreadyOptimized: Bool
        var success: Bool
        var error: String
        var qpdfCheck: String
        var outputSHA256: String
        var pdfkitOpen: Bool
        /// Phase V2-1 §7.3 – Stufenzeiten (0, wenn der Lauf scheiterte).
        var stageTimings: StageTimings
    }

    /// Phase V2-1 §7.2 – Run-Metadaten: maschinenlesbarer Kontext JEDES Laufs.
    struct RunMeta: Codable {
        var schema: Int
        var timestamp: String
        var gitCommit: String
        var gitDirty: Bool
        var appVersion: String
        var macModel: String
        var macosVersion: String
        var cpuCount: Int
        var memoryBytes: Int64
        var compressionConcurrency: Int
        var engine: String
        var qpdfVersion: String
        // Versionen der Vendor-Bibliotheken als Konstanten (Quelle: NOTICE-*.md).
        var mozjpegVersion: String = "4.1.1"
        var openjpegVersion: String = "2.5.4"
        var harfbuzzVersion: String = "11.5.1"
        var libtiffVersion: String = "4.7.2"
        var jbig2encVersion: String = "@23f992c"

        enum CodingKeys: String, CodingKey {
            case schema, timestamp
            case gitCommit = "git_commit"
            case gitDirty = "git_dirty"
            case appVersion = "app_version"
            case macModel = "mac_model"
            case macosVersion = "macos_version"
            case cpuCount = "cpu_count"
            case memoryBytes = "memory_bytes"
            case compressionConcurrency = "compression_concurrency"
            case engine
            case qpdfVersion = "qpdf_version"
            case mozjpegVersion = "mozjpeg_version"
            case openjpegVersion = "openjpeg_version"
            case harfbuzzVersion = "harfbuzz_version"
            case libtiffVersion = "libtiff_version"
            case jbig2encVersion = "jbig2enc_version"
        }
    }

    /// Phase V2-1 §7.3 – Median/p90 EINER Stufe in EINER Gruppe.
    struct StageTimingStat: Codable {
        var stage: String
        var medianMs: Double
        var p90Ms: Double

        enum CodingKeys: String, CodingKey {
            case stage
            case medianMs = "median_ms"
            case p90Ms = "p90_ms"
        }
    }

    /// Phase V2-1 §7.1 – Zelle der Kategorie-×-Preset-Matrix.
    struct CategoryPresetCell: Codable {
        var category: String
        var preset: String
        var successful: Int
        var failed: Int
        var inputBytes: Int64
        var outputBytes: Int64
        var weightedSavingPercent: Double
        var medianRuntimeSeconds: Double

        enum CodingKeys: String, CodingKey {
            case category, preset, successful, failed
            case inputBytes = "input_bytes"
            case outputBytes = "output_bytes"
            case weightedSavingPercent = "weighted_saving_percent"
            case medianRuntimeSeconds = "median_runtime_seconds"
        }
    }

    struct Aggregate: Codable {
        var preset: String
        var successful: Int
        var failed: Int
        var returnedOriginalCount: Int
        var alreadyOptimizedCount: Int
        var totalInputBytes: Int64
        var totalOutputBytes: Int64
        var weightedSavingPercent: Double
        var medianSavingPercent: Double
        var meanSavingPercent: Double
        var p10SavingPercent: Double
        var p90SavingPercent: Double
        var medianRuntimeSeconds: Double
        var p90RuntimeSeconds: Double
    }

    @Test(.measurementRun) func smoke30SmallSmartQuality() async throws {
        let env = ProcessInfo.processInfo.environment
        // xcodebuild leitet TEST_RUNNER_<X>=<Y> als <X>=<Y> an den Test-
        // prozess weiter – der Guard akzeptiert beide Schreibweisen.
        let smokeOn = env["PDFTOOLS_SMOKE"] ?? env["TEST_RUNNER_PDFTOOLS_SMOKE"]
        guard smokeOn == "1" else { return }

        // Repo-Root zuverlässig über #filePath (…/PDFToolsTests/<file>).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let corpus = URL(fileURLWithPath: env["PDFTOOLS_SMOKE_CORPUS"]
            ?? env["TEST_RUNNER_PDFTOOLS_SMOKE_CORPUS"]
            ?? home.appendingPathComponent("Desktop/PDF_small/PDF_Corpus_System/"
                + "Compression_Benchmark/Smoke_30").path)
        guard fm.fileExists(atPath: corpus.path) else {
            Issue.record("Smoke-Korpus fehlt: \(corpus.path)")
            return
        }

        let runID = Self.utcTimestamp()
        let outRoot = URL(fileURLWithPath: env["PDFTOOLS_SMOKE_OUT"]
            ?? env["TEST_RUNNER_PDFTOOLS_SMOKE_OUT"]
            ?? repoRoot.appendingPathComponent("benchmark/compression-smoke/\(runID)").path)
        let outputsDir = outRoot.appendingPathComponent("outputs")
        let errorsDir = outRoot.appendingPathComponent("errors")
        try fm.createDirectory(at: outputsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: errorsDir, withIntermediateDirectories: true)

        // Korpus lesen: <Kategorie>/<Datei>.pdf (KORPUS NUR LESEN).
        var jobs: [(category: String, file: URL)] = []
        let categories = (try? fm.contentsOfDirectory(atPath: corpus.path))?
            .filter { !$0.hasPrefix(".") } .sorted() ?? []
        for category in categories {
            let dir = corpus.appendingPathComponent(category)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".pdf") && !$0.hasPrefix(".") }
                .sorted()
            for f in files { jobs.append((category, dir.appendingPathComponent(f))) }
        }
        guard !jobs.isEmpty else {
            Issue.record("Keine PDFs im Smoke-Korpus gefunden.")
            return
        }

        let selectedModes = Self.requestedModes(env)
        let compressor = Compressor()
        let qpdf = env["PDFTOOLS_SMOKE_QPDF"] ?? env["TEST_RUNNER_PDFTOOLS_SMOKE_QPDF"]
            ?? repoRoot.appendingPathComponent("Vendor/qpdf/qpdf").path
        let checkpointURL = outRoot.appendingPathComponent("checkpoint.json")
        let resume = (env["PDFTOOLS_SMOKE_RESUME"]
            ?? env["TEST_RUNNER_PDFTOOLS_SMOKE_RESUME"]) == "1"
        let identityURL = outRoot.appendingPathComponent("baseline-identity.json")
        let identity = try Self.baselineIdentity(repoRoot: repoRoot, inputs: jobs.map(\.file))
        if resume {
            let previous = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: identityURL))
            guard previous == identity else {
                Issue.record("Resume verweigert: Code, Build, Umgebung, Konfiguration oder Korpus verändert")
                return
            }
        } else {
            guard !fm.fileExists(atPath: checkpointURL.path) else {
                Issue.record("Laufverzeichnis enthält bereits einen Checkpoint; neues Verzeichnis oder explizites Resume verwenden")
                return
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(identity).write(to: identityURL, options: [.atomic])
        }
        var records: [RunRecord] = resume
            ? try JSONDecoder().decode([RunRecord].self, from: Data(contentsOf: checkpointURL)) : []
        var completed = Set(records.map { "\($0.inputPath)\u{0}\($0.preset)" })

        for mode in selectedModes {
            for job in jobs {
                let key = "\(job.file.path)\u{0}\(mode.rawValue)"
                if completed.contains(key) { continue }
                let rec = Self.runOne(compressor: compressor,
                                      qpdfPath: qpdf,
                                      input: job.file,
                                      category: job.category,
                                      mode: mode,
                                      outputsDir: outputsDir,
                                      errorsDir: errorsDir,
                                      fm: fm)
                records.append(rec)
                completed.insert(key)
                try Self.writeCheckpoint(records, to: checkpointURL)
            }
        }

        // Aggregation je Preset und je Kategorie, dann Artefakte schreiben.
        let presets = Self.aggregate(records: records, key: \.preset)
        let perCategory = Self.aggregate(records: records, key: \.category)
        // Phase V2-1 §7.1 – die Matrix category × preset.
        let matrix = Self.aggregateMatrix(records: records,
                                          presets: selectedModes.map(\.rawValue))
        let meta = Self.runMeta(timestamp: runID, repoRoot: repoRoot, qpdfPath: qpdf)
        try Self.writeCSV(records, to: outRoot.appendingPathComponent("summary.csv"))
        try Self.writeJSON(meta: meta, presets: presets, categories: perCategory,
                           matrix: matrix, records: records, runID: runID,
                           corpus: corpus.path, to: outRoot)
        try Self.writeReport(meta: meta, presets: presets, categories: perCategory,
                             matrix: matrix, records: records, runID: runID,
                             corpus: corpus.path, outRoot: outRoot)
        print("SMOKE DONE: \(records.count) Ops → \(outRoot.path)")
    }

    // MARK: - Einzeloperation

    private static func writeCheckpoint(_ records: [RunRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url, options: .atomic)
    }

    /// Der Smoke-Runner bleibt begrenzt, verwechselt große Produktionsfälle
    /// aber nicht mehr mit einem Fehler. Die App selbst besitzt bewusst
    /// keinen Laufzeit-Timeout und läuft bis Abschluss oder Nutzerabbruch.
    private static func timeouts(inputBytes: Int64) ->
        (operation: TimeInterval, hard: TimeInterval) {
        let operation: TimeInterval
        switch inputBytes {
        case 100_000_000...:
            operation = veryLargeOperationTimeout
        case 25_000_000...:
            operation = largeOperationTimeout
        default:
            operation = standardOperationTimeout
        }
        return (operation, operation + hardTimeoutGrace)
    }

    @Test func grosseDateienErhaltenEinRealistischesSmokeZeitbudget() {
        #expect(Self.timeouts(inputBytes: 24_999_999).operation == 180)
        #expect(Self.timeouts(inputBytes: 43_000_000).operation == 600)
        #expect(Self.timeouts(inputBytes: 120_000_000).operation == 900)
        #expect(Self.timeouts(inputBytes: 43_000_000).hard == 620)
    }

    @Test func smokeModiSindFuerGrosseResumierbareLaeufeFilterbar() {
        #expect(Self.requestedModes(["PDFTOOLS_SMOKE_MODES": "Smart,Qualität"])
                == [.smart, .quality])
        #expect(Self.requestedModes(["PDFTOOLS_SMOKE_MODES": "unbekannt"])
                == Self.modes)
    }

    private static func runOne(compressor: Compressor,
                               qpdfPath: String,
                               input: URL,
                               category: String,
                               mode: CompressionMode,
                               outputsDir: URL,
                               errorsDir: URL,
                               fm: FileManager) -> RunRecord {
        // Smoke_30 referenziert die echten PDFs über SYMLINKS (65 Bytes).
        // Ohne Auflösung misst die Größenpolitik der Produktion die
        // Symlink-Länge statt der Dokumentlänge – und liefert dann
        // „returnedOriginal" für alles. Aufgelöst wird nur LESEND.
        let resolved = input.resolvingSymlinksInPath()
        let inputBytes = (try? fm.attributesOfItem(atPath: resolved.path))?[.size] as? Int64 ?? 0
        let pagesBefore = pageCount(qpdfPath: qpdfPath, url: resolved)
        let started = Date()
        let timeout = timeouts(inputBytes: inputBytes)
        let deadline = Date().addingTimeInterval(timeout.operation)

        var result: CompressionResult?
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)
        // Phase V2-1 §7.3 – Stufenzeiten je Operation.
        let stageTimer = StageTimer()
        let task = Task.detached {
            do {
                let env = ProcessInfo.processInfo.environment
                let trial = env["PDFTOOLS_SMART_PHOTO_CANDIDATES"]
                    ?? env["TEST_RUNNER_PDFTOOLS_SMART_PHOTO_CANDIDATES"]
                if trial == "1", mode == .smart {
                    var options = CompressionOptions.make(mode: mode, customConfig: nil,
                        stripMetadata: false, linearize: false)
                    options.image.experimentalSmartPhotoCandidates = true
                    result = try compressor.compress(inputURL: resolved, options: options,
                        isCancelled: { Date() > deadline }, stageTimer: stageTimer)
                } else {
                    result = try compressor.compress(
                        inputURL: resolved, mode: mode,
                        isCancelled: { Date() > deadline }, stageTimer: stageTimer)
                }
            } catch {
                failure = error
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout.hard) == .timedOut {
            task.cancel()
        }
        let runtime = Date().timeIntervalSince(started)

        var rec = RunRecord(
            inputPath: input.path, category: category,
            preset: mode.rawValue, inputBytes: inputBytes,
            outputBytes: 0, savedBytes: 0, savedPercent: 0,
            runtimeSeconds: runtime, pagesBefore: pagesBefore,
            pagesAfter: -1, returnedOriginal: false,
            alreadyOptimized: false, success: false,
            error: "", qpdfCheck: "not-run", outputSHA256: "", pdfkitOpen: false,
            stageTimings: stageTimer.timings)

        guard let r = result, failure == nil else {
            rec.error = Self.errorText(failure)
                + (result == nil && failure == nil
                    ? "TIMEOUT nach \(Int(timeout.hard))s" : "")
            // Fail-closed der Produktion: Das ORIGINAL bleibt erhalten und
            // ist das, was der Nutzer erhält. Für die gewichtete Ersparnis
            // zählt delivered = input (sonst würde ein Fehler als Ersparnis
            // von 100 % missinterpretiert).
            rec.outputBytes = rec.inputBytes
            rec.savedBytes = 0
            rec.savedPercent = 0
            Self.writeErrorFile(errorsDir: errorsDir, category: category,
                                file: input.lastPathComponent, preset: mode.rawValue,
                                text: rec.error)
            return rec
        }

        // Delivered Output behalten: Bei returnedOriginal IST das Delivered
        // das aufgelöste Original (der Kandidat wurde verworfen); sonst die
        // erzeugte Datei. Namensschema: <Kategorie>__<Stem>__<Preset>.pdf.
        let deliveredURL = r.returnedOriginal ? resolved : r.outputURL
        let deliveredBytes = (try? fm.attributesOfItem(atPath: deliveredURL.path))?[.size] as? Int64 ?? 0
        rec.outputBytes = r.outputBytes > 0 ? r.outputBytes : Int64(deliveredBytes)
        rec.savedBytes = rec.inputBytes - rec.outputBytes
        rec.savedPercent = (rec.inputBytes > 0)
            ? (1.0 - Double(rec.outputBytes) / Double(rec.inputBytes)) * 100 : 0
        rec.returnedOriginal = r.returnedOriginal
        rec.alreadyOptimized = r.alreadyOptimized
        rec.pagesAfter = pageCount(qpdfPath: qpdfPath, url: deliveredURL)
        rec.pdfkitOpen = PDFDocument(url: deliveredURL) != nil
        rec.qpdfCheck = qpdfCheck(qpdfPath: qpdfPath, url: deliveredURL)
        rec.outputSHA256 = sha256(of: deliveredURL)

        // Schnelle Validierung (kein Rendering).
        let sizeOK = fm.fileExists(atPath: deliveredURL.path) && deliveredBytes > 0
        let pagesOK = rec.pagesBefore > 0 && rec.pagesAfter == rec.pagesBefore
        let qpdfFatal = rec.qpdfCheck.hasPrefix("fatal")
        rec.success = sizeOK && rec.pdfkitOpen && pagesOK && !qpdfFatal

        // Delivered Output behalten (auch returnedOriginal = durchgereichtes
        // Original; Namensschema: <Kategorie>__<Stem>__<Preset>.pdf).
        let stem = input.deletingPathExtension().lastPathComponent
        let target = outputsDir.appendingPathComponent(
            "\(category)__\(stem)__\(mode.rawValue).pdf")
        try? fm.removeItem(at: target)
        do {
            try fm.copyItem(at: deliveredURL, to: target)
        } catch {
            rec.success = false
            rec.error = "Output konnte nicht gespeichert werden: \(error)"
        }
        // Temp-Ergebnis nach dem Kopieren entsorgen (früher blieb jedes
        // liegen: 2,8 GB nach einigen Korpusläufen). Nie das Original.
        if !r.returnedOriginal {
            try? fm.removeItem(at: r.outputURL)
        }

        if !rec.success {
            Self.writeErrorFile(errorsDir: errorsDir, category: category,
                                file: input.lastPathComponent, preset: mode.rawValue,
                                text: "success=false pages \(rec.pagesBefore)->\(rec.pagesAfter)"
                                    + " qpdf=\(rec.qpdfCheck) pdfkitOpen=\(rec.pdfkitOpen)")
        }
        return rec
    }

    // MARK: - Hilfsfunktionen

    private static func errorText(_ error: Error?) -> String {
        guard let error else { return "" }
        if let e = error as? LocalizedError, let msg = e.errorDescription { return msg + " " }
        return String(describing: error) + " "
    }

    private static func utcTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date())
    }

    private static func pageCount(qpdfPath: String, url: URL) -> Int {
        let p = Process()
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.executableURL = URL(fileURLWithPath: qpdfPath)
        p.arguments = ["--show-npages", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 || p.terminationStatus == 3,
              let data = String(data: output, encoding: .utf8),
              let n = Int(data.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0
        else { return -1 }
        return n
    }

    /// qpdf --check: 0 = sauber, 3 = nur Warnungen (kein struktureller
    /// Fehler). 2/4 und alles andere zählen als fatal.
    private static func qpdfCheck(qpdfPath: String, url: URL) -> String {
        let p = Process()
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.executableURL = URL(fileURLWithPath: qpdfPath)
        p.arguments = ["--check", url.path]
        let errPipe = Pipe(); p.standardOutput = FileHandle.nullDevice; p.standardError = errPipe
        do { try p.run() } catch { return "fatal:spawn" }
        let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let code = p.terminationStatus
        switch code {
        case 0: return "ok"
        case 3: return "warnings"
        default:
            let err = String(data: errorData,
                             encoding: .utf8) ?? ""
            let first = err.split(separator: "\n").first.map(String.init) ?? ""
            return "fatal:exit\(code)\(first.isEmpty ? "" : ": \(first)")"
        }
    }

    /// Immutable identity written before the first operation; presets may be split across runs.
    private static func baselineIdentity(repoRoot: URL, inputs: [URL]) throws -> [String: String] {
        func digest(_ urls: [URL]) throws -> String {
            var hash = SHA256()
            for url in urls.sorted(by: { $0.path < $1.path }) {
                hash.update(data: Data(url.path.utf8))
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                    hash.update(data: chunk)
                }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["PDFTOOLS_BASELINE_SOURCE_MANIFEST"]
            ?? environment["TEST_RUNNER_PDFTOOLS_BASELINE_SOURCE_MANIFEST"],
              let executable = Bundle.main.executableURL else {
            Issue.record("Baseline fehlt: Scripts/run-smoke-benchmark.sh verwenden")
            throw CocoaError(.fileReadUnknown)
        }
        let source = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        guard let sourceHash = source["source_and_vendor_sha256"], sourceHash.count == 64,
              let commit = source["git_commit"], !commit.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let configuration = environment.filter {
            ($0.key.hasPrefix("PDFTOOLS_") || $0.key.hasPrefix("TEST_RUNNER_PDFTOOLS_"))
                && !$0.key.contains("SMOKE") && !$0.key.contains("TRACE")
                && !$0.key.contains("BASELINE_SOURCE_MANIFEST")
        }
        let configData = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        let bundleFiles = (FileManager.default.enumerator(at: Bundle.main.bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { $0.path.contains("/MacOS/") || $0.pathExtension == "dylib" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        var identity = ["schema": "1", "git_commit": commit,
                        "source_and_vendor_sha256": sourceHash,
                        "executable_sha256": try digest([executable]),
                        "loaded_bundle_binaries_sha256": try digest(bundleFiles),
                        "os": ProcessInfo.processInfo.operatingSystemVersionString,
                        "architecture": {
#if arch(arm64)
                            return "arm64"
#elseif arch(x86_64)
                            return "x86_64"
#else
                            return "unknown"
#endif
                        }(),
                        "compression_concurrency": String(CompressionConcurrency.maxConcurrentDocuments),
                        "configuration_sha256": SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined()]
        for input in inputs {
            let handle = try FileHandle(forReadingFrom: input.resolvingSymlinksInPath())
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            identity["input:" + input.path] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return identity
    }

    private static func sha256(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeErrorFile(errorsDir: URL, category: String,
                                       file: String, preset: String, text: String) {
        let name = "\(category)__\(file)__\(preset).txt"
        try? text.data(using: .utf8)?
            .write(to: errorsDir.appendingPathComponent(name))
    }

    // MARK: - Aggregation

    private static func aggregate(records: [RunRecord],
                                  key: KeyPath<RunRecord, String>) -> [Aggregate] {
        let groups = Dictionary(grouping: records) { $0[keyPath: key] }
        return groups.keys.sorted().map { k in
            let rs = groups[k]!
            return aggregateGroup(k, rs)
        }
    }

    private static func aggregateGroup(_ label: String, _ rs: [RunRecord]) -> Aggregate {
        let ok = rs.filter(\.success)
        let inTotal = rs.reduce(Int64(0)) { $0 + $1.inputBytes }
        // Failed deliveries contribute the original bytes to the overall balance.
        let outTotal = rs.reduce(Int64(0)) { $0 + ($1.success ? $1.outputBytes : $1.inputBytes) }
        let savings = ok.map(\.savedPercent).sorted()
        let runtimes = ok.map(\.runtimeSeconds).sorted()
        func pct(_ arr: [Double], _ p: Double) -> Double {
            guard !arr.isEmpty else { return 0 }
            let idx = Double(arr.count - 1) * p
            let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
            return arr[lo] + (arr[hi] - arr[lo]) * (idx - Double(lo))
        }
        return Aggregate(
            preset: label, successful: ok.count, failed: rs.count - ok.count,
            returnedOriginalCount: rs.filter(\.returnedOriginal).count,
            alreadyOptimizedCount: rs.filter(\.alreadyOptimized).count,
            totalInputBytes: inTotal, totalOutputBytes: outTotal,
            weightedSavingPercent: inTotal > 0
                ? (1.0 - Double(outTotal) / Double(inTotal)) * 100 : 0,
            medianSavingPercent: pct(savings, 0.5),
            meanSavingPercent: savings.isEmpty
                ? 0 : savings.reduce(0, +) / Double(savings.count),
            p10SavingPercent: pct(savings, 0.10),
            p90SavingPercent: pct(savings, 0.90),
            medianRuntimeSeconds: pct(runtimes, 0.5),
            p90RuntimeSeconds: pct(runtimes, 0.90))
    }

    // MARK: - Phase V2-1 §7.1 – Kategorie × Preset

    private static func aggregateMatrix(records: [RunRecord],
                                        presets: [String]) -> [CategoryPresetCell] {
        let categories = Set(records.map(\.category)).sorted()
        var cells: [CategoryPresetCell] = []
        for category in categories {
            for preset in presets {
                let group = records.filter {
                    $0.category == category && $0.preset == preset
                }
                guard !group.isEmpty else { continue }
                let agg = aggregateGroup("\(category) × \(preset)", group)
                cells.append(CategoryPresetCell(
                    category: category, preset: preset,
                    successful: agg.successful, failed: agg.failed,
                    inputBytes: agg.totalInputBytes,
                    outputBytes: agg.totalOutputBytes,
                    weightedSavingPercent: agg.weightedSavingPercent,
                    medianRuntimeSeconds: agg.medianRuntimeSeconds))
            }
        }
        return cells
    }

    // MARK: - Phase V2-1 §7.3 – Stufenzeiten je Preset

    /// Median/p90 je Stufe über die ERFOLGREICHEN Läufe einer Gruppe.
    private static func stageStats(records: [RunRecord]) -> [StageTimingStat] {
        let ok = records.filter(\.success)
        func pctl(_ arr: [Double], _ p: Double) -> Double {
            guard !arr.isEmpty else { return 0 }
            let idx = Double(arr.count - 1) * p
            let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
            return arr[lo] + (arr[hi] - arr[lo]) * (idx - Double(lo))
        }
        return StageTimings.Field.allCases.map { field in
            let values = ok.map { $0.stageTimings.value(field) }.sorted()
            return StageTimingStat(stage: StageTimings.jsonKey(field),
                                   medianMs: pctl(values, 0.5),
                                   p90Ms: pctl(values, 0.90))
        }
    }

    // MARK: - Phase V2-1 §7.2 – Run-Metadaten

    private static func runMeta(timestamp: String, repoRoot: URL,
                                qpdfPath: String) -> RunMeta {
        let info = ProcessInfo.processInfo
        let env = info.environment
        let manifestPath = env["PDFTOOLS_BASELINE_SOURCE_MANIFEST"]
            ?? env["TEST_RUNNER_PDFTOOLS_BASELINE_SOURCE_MANIFEST"] ?? ""
        let source = (try? Data(contentsOf: URL(fileURLWithPath: manifestPath)))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let commit = source["git_commit"] ?? ""
        let dirty = source["git_dirty"] == "true"
        let os = info.operatingSystemVersion
        return RunMeta(
            schema: 2,
            timestamp: timestamp,
            gitCommit: commit.isEmpty ? "unbekannt" : commit,
            gitDirty: dirty,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            macModel: macModel(),
            macosVersion: String(
                format: "macOS %d.%d.%d", os.majorVersion,
                os.minorVersion, os.patchVersion),
            cpuCount: info.activeProcessorCount,
            memoryBytes: Int64(info.physicalMemory),
            compressionConcurrency: CompressionConcurrency.maxConcurrentDocuments,
            engine: "libqpdf",
            qpdfVersion: qpdfVersion(qpdfPath: qpdfPath))
    }

    /// sysctl hw.model – best effort, leer wenn nicht lesbar.
    private static func macModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unbekannt" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else {
            return "unbekannt"
        }
        return String(cString: value)
    }

    private static func qpdfVersion(qpdfPath: String) -> String {
        let process = Process()
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.executableURL = URL(fileURLWithPath: qpdfPath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "unbekannt" }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8)?
            .split(separator: "\n").first.map(String.init) ?? "unbekannt"
    }

    // MARK: - Artefakte

    private static func csvEscape(_ s: String) -> String {
        s.contains(",") || s.contains("\"") || s.contains("\n")
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    private static func writeCSV(_ records: [RunRecord], to url: URL) throws {
        var lines = ["input_path,category,preset,input_bytes,output_bytes,saved_bytes,"
            + "saved_percent,runtime_seconds,pages_before,pages_after,"
            + "returned_original,already_optimized,success,error,qpdf_check,"
            + "output_sha256,pdfkit_open"]
        for r in records {
            lines.append([
                csvEscape(r.inputPath), csvEscape(r.category), csvEscape(r.preset),
                "\(r.inputBytes)", "\(r.outputBytes)", "\(r.savedBytes)",
                String(format: "%.2f", r.savedPercent),
                String(format: "%.2f", r.runtimeSeconds),
                "\(r.pagesBefore)", "\(r.pagesAfter)",
                r.returnedOriginal ? "true" : "false",
                r.alreadyOptimized ? "true" : "false",
                r.success ? "true" : "false",
                csvEscape(r.error), csvEscape(r.qpdfCheck),
                r.outputSHA256, r.pdfkitOpen ? "true" : "false"
            ].joined(separator: ","))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true,
                                                encoding: .utf8)
    }

    private static func writeJSON(meta: RunMeta, presets: [Aggregate],
                                  categories: [Aggregate],
                                  matrix: [CategoryPresetCell],
                                  records: [RunRecord], runID: String,
                                  corpus: String, to outRoot: URL) throws {
        struct Top: Codable {
            var runID: String
            var corpus: String
            var scope: [String]
            var engine: String
            var validation: String
            var meta: RunMeta
            var perPreset: [Aggregate]
            var perCategory: [Aggregate]
            /// Phase V2-1 §7.1 – Matrix category × preset.
            var categoryByPreset: [CategoryPresetCell]
            /// Phase V2-1 §7.3 – Median/p90 je Stufe je Preset.
            var stageTimingsByPreset: [String: [StageTimingStat]]
            var records: [RunRecord]
        }
        var stageByPreset: [String: [StageTimingStat]] = [:]
        for preset in presets {
            stageByPreset[preset.preset] = stageStats(
                records: records.filter { $0.preset == preset.preset })
        }
        let top = Top(runID: runID, corpus: corpus,
                      scope: modes.map(\.rawValue),
                      engine: "Compressor().compress(inputURL:mode:) → CompressionPipeline (libqpdf) + Struktur-Pass + PDFValidator",
                      validation: "fast: exists/size>0/PDFKit-open/pages-match/qpdf --check (kein Rendering, keine Bildmetriken)",
                      meta: meta,
                      perPreset: presets, perCategory: categories,
                      categoryByPreset: matrix,
                      stageTimingsByPreset: stageByPreset,
                      records: records)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(top).write(to: outRoot.appendingPathComponent("summary.json"),
                                  options: [.atomic])
    }

    private static func writeReport(meta: RunMeta, presets: [Aggregate],
                                    categories: [Aggregate],
                                    matrix: [CategoryPresetCell],
                                    records: [RunRecord], runID: String,
                                    corpus: String, outRoot: URL) throws {
        func aggTable(_ aggs: [Aggregate], label: String) -> String {
            var s = "### \(label)\n\n"
            s += "| \(label == "Presets" ? "Preset" : "Kategorie") | ok | fail | retOrig | alreadyOpt | in | out | gewichtet | Median | Mean | p10 | p90 | Med-Laufzeit | p90-Laufzeit |\n"
            s += "|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|\n"
            for a in aggs {
                func mb(_ b: Int64) -> String { String(format: "%.2f MB", Double(b) / 1_048_576) }
                s += "| \(a.preset) | \(a.successful) | \(a.failed) | \(a.returnedOriginalCount) | \(a.alreadyOptimizedCount) | \(mb(a.totalInputBytes)) | \(mb(a.totalOutputBytes)) | \(String(format: "%.1f%%", a.weightedSavingPercent)) | \(String(format: "%.1f%%", a.medianSavingPercent)) | \(String(format: "%.1f%%", a.meanSavingPercent)) | \(String(format: "%.1f%%", a.p10SavingPercent)) | \(String(format: "%.1f%%", a.p90SavingPercent)) | \(String(format: "%.1fs", a.medianRuntimeSeconds)) | \(String(format: "%.1fs", a.p90RuntimeSeconds)) |\n"
            }
            return s
        }

        // Phase V2-1 §7.1 – Matrix category × preset (gewichtete Ersparnis).
        let presetOrder = presets.map(\.preset)
        var matrixTable = "### Kategorie × Preset (gewichtete Ersparnis)\n\n"
        matrixTable += "| Kategorie |" + presetOrder.map { " \($0) " }.joined(separator: "|") + "|\n"
        matrixTable += "|---|" + presetOrder.map { _ in "--:" }.joined(separator: "|") + "|\n"
        for category in Set(matrix.map(\.category)).sorted() {
            var cells: [String] = []
            for preset in presetOrder {
                let cell = matrix.first {
                    $0.category == category && $0.preset == preset
                }
                cells.append(cell.map {
                    String(format: "%.1f%%", $0.weightedSavingPercent)
                } ?? "–")
            }
            matrixTable += "| \(category) | " + cells.joined(separator: " | ") + " |\n"
        }

        // Phase V2-1 §7.3 – Stufenzeiten je Preset (Median/p90, ms).
        let stageByPreset = Dictionary(uniqueKeysWithValues:
            presetOrder.map { preset in
                (preset, stageStats(records: records.filter { $0.preset == preset }))
            })
        var timing = "### Stage-Timing (ms, Median/p90 der erfolgreichen Läufe)\n\n"
        timing += "| Stufe |" + presetOrder.map { " \($0) " }.joined(separator: "|") + "|\n"
        timing += "|---|" + presetOrder.map { _ in "--:" }.joined(separator: "|") + "|\n"
        for stat in stageByPreset[presetOrder.first ?? ""] ?? [] {
            var cells: [String] = []
            for preset in presetOrder {
                let found = stageByPreset[preset]?.first { $0.stage == stat.stage }
                cells.append(found.map {
                    String(format: "%.0f / %.0f", $0.medianMs, $0.p90Ms)
                } ?? "–")
            }
            timing += "| `\(stat.stage)` | " + cells.joined(separator: " | ") + " |\n"
        }

        let documentCount = Set(records.map(\.inputPath)).count
        let documentLabel = documentCount == 1 ? "1 PDF" : "\(documentCount) PDFs"
        let presetLabel = presets.map(\.preset).joined(separator: "/")
        var md = "# Compression Smoke Baseline – \(runID)\n\n"
        md += "Korpus: `\(corpus)` · Ops: \(records.count) "
            + "(\(documentLabel) × \(presetLabel))\n\n"
        md += "Engine: Produktions-`Compressor` (CompressionPipeline/libqpdf) – **custom** und **maximum** (Zopfli) bewusst ausgeschlossen.\n\n"
        md += "`returnedOriginal` = No-Regression-Politik (Kandidat nicht kleiner als Original) – **kein** Fehler.\n\n"
        // Phase V2-1 §7.2 – Run-Metadaten; Dirty-Runs klar markiert.
        md += "### Run-Metadaten\n\n"
        md += "- schema: \(meta.schema) · engine: \(meta.engine) · qpdf: \(meta.qpdfVersion)\n"
        md += "- git: `\(meta.gitCommit)`" + (meta.gitDirty ? " – **DIRTY (Arbeitsverzeichnis nicht sauber)**" : " (sauber)") + "\n"
        md += "- Host: \(meta.macModel) · \(meta.macosVersion) · \(meta.cpuCount) CPUs · \(String(format: "%.1f GB", Double(meta.memoryBytes) / 1_073_741_824))\n"
        md += "- concurrency: \(meta.compressionConcurrency) · mozjpeg \(meta.mozjpegVersion) · openjpeg \(meta.openjpegVersion) · harfbuzz \(meta.harfbuzzVersion) · libtiff \(meta.libtiffVersion) · jbig2enc \(meta.jbig2encVersion)\n\n"
        md += aggTable(presets, label: "Presets") + "\n" + aggTable(categories, label: "Kategorien") + "\n"
        md += matrixTable + "\n" + timing
        md += "\nGewichtete Ersparnis = 1 − Σ(output)/Σ(input). Validierung nur schnell "
            + "(Datei, Größe, PDFKit-Open, Seitenzahl, `qpdf --check`) – kein Rendering/SSIM.\n"
        try md.write(to: outRoot.appendingPathComponent("report.md"),
                     atomically: true, encoding: .utf8)
    }
}
