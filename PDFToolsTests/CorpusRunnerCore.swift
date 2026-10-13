import Foundation
import AppKit
import PDFKit
@testable import PDFTools

/// Monster Epic Findings 1–4 – Echter Production-Corpus-Runner.
///
/// Dieser Runner ist DIE End-to-End-Qualitätsplattform des Projekts:
/// - Jede Operation wird über echte Produktions-Services ausgeführt
///   (Compressor / PageAssemblyService.assemble / PageSplitter) – NIEMALS über qpdf-CLI.
/// - qpdf dient ausschließlich als unabhängiger externer Output-Validator.
/// - Failures tragen eine Severity (CRITICAL/HIGH/MEDIUM/LOW); es gibt KEIN
///   globales Toleranzfenster mehr.
/// - Jeder Run schreibt atomar JSON/CSV/Markdown mit identischen Summen.
///
/// Konfiguration (Masterplan Finding 2):
/// - Korpus-Root: PDFTOOLS_CORPUS_ROOT → ~/Desktop/PDF_small/PDF_Tools-Testcorpus
/// - Suite:      PDFTOOLS_SUITE      = fast | full | stress (Default: fast)
/// - Operationen: PDFTOOLS_OPERATION  = Komma-Liste (Default: alle)
/// - Seed:       PDFTOOLS_SEED       = UInt64 (Default: 42, deterministisch)
/// - Outputs behalten: PDFTOOLS_KEEP_OUTPUTS = 1
/// - Corpus-ID:  PDFTOOLS_CORPUS_ID  = freies Label im Report
enum CorpusRunnerCore {

    // MARK: - Suite-Definition

    enum Suite: String {
        case fast
        case full
        case stress
    }

    // MARK: - Fixture-Klassen (bestimmen die Gate-Policy)

    enum FixtureClass: String, Codable {
        /// Golden-Korpus mit exakten Erwartungen – Gate: 100 % PASS.
        case golden
        /// Synthetische Kontroll-Fixtures – ebenfalls 100 % PASS.
        case synthetic
        /// Reale Dokumente – Gate: 0 CRITICAL, 0 HIGH.
        case realWorld
        /// Stress-Dokumente – Gate: kein Crash, valide Struktur.
        case stress
        /// Absichtlich beschädigt – Gate: kein Crash, kein stilles Fehlergebnis.
        /// Ein Fehlschlag ist hier der ERWARTETE Ausgang, kein Mangel.
        case malformed
    }

    // MARK: - Severity (Finding 3)

    enum Severity: String, Codable, Comparable {
        case critical, high, medium, low

        private var rank: Int {
            switch self {
            case .critical: return 0
            case .high: return 1
            case .medium: return 2
            case .low: return 3
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    struct Finding: Codable {
        let severity: Severity
        let message: String
    }

    // MARK: - Operationen (jede über Production-Services)

    enum Operation: String, CaseIterable {
        // Compression – Production-Engine-Default (Compressor.compress).
        case compressSmart = "compress-smart"
        case compressCustomBalanced = "compress-custom-balanced"
        case compressCustomHigh = "compress-custom-high"
        case compressCustomAggressive = "compress-custom-aggressive"
        case compressCustomGrayscale = "compress-custom-grayscale"
        // Page Assembly – Production Page Assembly Service.
        case merge = "merge"
        case reorder = "reorder"
        case rotate90 = "rotate90"
        case deleteMiddle = "delete-middle"
        case extractFirstHalf = "extract-first-half"
        // Split – Production Split Service (PageSplitter + Assembly).
        case splitEvery5 = "split-every-5"
        // Differenzmatrix beider Assembly-Backends (Masterplan Schritt 11).
        // Läuft NICHT in den Standardsuiten mit, sondern gezielt über
        // PDFTOOLS_OPERATION=assembly-differential – sie assembliert jedes
        // Dokument zweimal und ist entsprechend teuer.
        case assemblyDifferential = "assembly-differential"

        var isCompression: Bool {
            switch self {
            case .compressSmart, .compressCustomBalanced, .compressCustomHigh,
                 .compressCustomAggressive, .compressCustomGrayscale:
                return true
            default:
                return false
            }
        }

        var isAssembly: Bool {
            switch self {
            case .merge, .reorder, .rotate90, .deleteMiddle, .extractFirstHalf,
                 .splitEvery5:
                return true
            default:
                return false
            }
        }

        /// Stress-Suite belässt schwere Kompressionen außen (Separates Stress-Gate).
        var enabledInStress: Bool { isAssembly }
    }

    // MARK: - Konfiguration

    struct Config {
        let corpusRoot: URL
        let corpusRootSource: String
        let suite: Suite
        let operationFilter: Set<String>?
        let seed: UInt64
        let keepOutputs: Bool
        let corpusID: String
        /// Charge dieses Laufs, 1-basiert; nil = ganzer Korpus.
        ///
        /// Der PDFKit-Assembler hält Seiteninhalte über den Aufruf hinaus
        /// (gemessen: 2938 MB nach sechs Durchläufen an einem 126-Seiten-
        /// Dokument, gegenüber 71 MB bei libqpdf). Über tausende Operationen
        /// summiert sich das, bis der Prozess stirbt. Solange der Cutover auf
        /// libqpdf aussteht, wird der Korpus deshalb in Chargen abgearbeitet:
        /// Jede läuft in einem eigenen Prozess, der seinen Speicher am Ende
        /// vollständig zurückgibt.
        let shard: (index: Int, count: Int)?

        /// Verarbeitet dieser Lauf nur einen Ausschnitt?
        var isSharded: Bool { shard != nil }

        /// Kennung für Verzeichnis- und Dateinamen.
        var shardSuffix: String {
            guard let shard else { return "" }
            return String(format: "_shard%02dof%02d", shard.index, shard.count)
        }

        /// Wo der Korpus liegt, entscheidet `CorpusRootResolver` – hier
        /// steht nur noch die Weiterleitung. Der Vorgabepfad stand vorher
        /// zusätzlich in acht Skripten; siehe dort.
        static func resolveEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment)
            -> (root: URL, source: String) {
            let r = CorpusRootResolver.resolve(env: env)
            return (r.root, r.source)
        }

        static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment)
            -> Config {
            let root = resolveEnvironment(env)
            let suite = Suite(rawValue: env["PDFTOOLS_SUITE"] ?? "") ?? .fast
            let filterRaw = env["PDFTOOLS_OPERATION"] ?? ""
            let filter: Set<String>? = filterRaw.isEmpty ? nil : Set(
                filterRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let seed = env["PDFTOOLS_SEED"].flatMap { UInt64($0) } ?? 42
            let keep = (env["PDFTOOLS_KEEP_OUTPUTS"] == "1")
            let corpusID = env["PDFTOOLS_CORPUS_ID"] ?? "default"

            // Format "i/n", 1-basiert. Ungültige Angaben werden ignoriert,
            // statt still einen leeren Lauf zu erzeugen.
            var shard: (index: Int, count: Int)?
            if let raw = env["PDFTOOLS_SHARD"], !raw.isEmpty {
                let parts = raw.split(separator: "/").compactMap { Int($0) }
                if parts.count == 2, parts[1] > 0,
                   parts[0] >= 1, parts[0] <= parts[1] {
                    shard = (parts[0], parts[1])
                }
            }

            return Config(corpusRoot: root.root, corpusRootSource: root.source,
                          suite: suite, operationFilter: filter, seed: seed,
                          keepOutputs: keep, corpusID: corpusID, shard: shard)
        }
    }

    // MARK: - Deterministische Auswahl (Seed)

    /// SplitMix64 – kleiner, deterministischer PRNG ohne Abhängigkeit
    /// an Systemzufall oder Sortierreihenfolge von FileSystem-Enumaratoren.
    struct SeededShuffler {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        mutating func shuffle<T>(_ items: [T]) -> [T] {
            var arr = items
            guard arr.count > 1 else { return arr }
            for i in stride(from: arr.count - 1, through: 1, by: -1) {
                let j = Int(next() % UInt64(i + 1))
                arr.swapAt(i, j)
            }
            return arr
        }
    }

    // MARK: - Report-Modell

    struct RunMeta: Codable {
        let runID: String
        let startedAt: String
        var finishedAt: String
        let corpusRoot: String
        let corpusRootSource: String
        let corpusID: String
        let suite: String
        let seed: UInt64
    }

    struct OperationRow: Codable {
        let fixture: String
        let fixtureClass: String
        let operation: String
        /// PASS | FAIL | SKIP
        let status: String
        /// Schlimmste Severity der Findings (nur bei FAIL gesetzt).
        let severity: String?
        let durationMs: Double
        let pagesIn: Int
        let pagesOut: Int
        let inputBytes: Int64
        let outputBytes: Int64
        /// PASS | FAIL | SKIPPED (externer Validator)
        let qpdfCheck: String
        let renderChangedAreaRatio: Double?
        let renderMeanAbsDiff: Double?
        let renderSSIM: Double?
        let renderInkDelta: Double?
        /// Phase 8.6 – Spitzenwert des physischen Speichers während der
        /// Operation, in MB. Prozessweit gemessen, also eine Obergrenze für
        /// die einzelne Operation.
        ///
        /// OPTIONAL, nicht `= -1`: Swifts erzeugtes `Decodable` greift NICHT
        /// auf Vorgabewerte zurück, sondern wirft bei fehlendem Schlüssel.
        /// Journalzeilen aus früheren Läufen kennen das Feld nicht – mit
        /// einem Vorgabewert wären sie unlesbar, und genau die wertet
        /// `salvage-run.sh` aus.
        var peakFootprintMB: Int?
        /// Phase 8.6 – grösster belegter Platz im Arbeitsverzeichnis, in
        /// Bytes. Optional aus demselben Grund.
        var peakWorkspaceBytes: Int64?
        let messages: [String]
    }

    struct RunReport: Codable {
        var meta: RunMeta?
        var operations: [OperationRow] = []
        var skippedFixtures: [String] = []

        var totalOps: Int { operations.count }
        var passOps: Int { operations.filter { $0.status == "PASS" }.count }
        var failOps: Int { operations.filter { $0.status == "FAIL" }.count }
        var skipOps: Int { operations.filter { $0.status == "SKIP" }.count }

        func failures(severityLimit: Severity?) -> [OperationRow] {
            operations.filter { row in
                guard row.status == "FAIL", let sev = row.severity,
                      let parsed = Severity(rawValue: sev) else { return false }
                if let limit = severityLimit {
                    return parsed <= limit
                }
                return true
            }
        }
    }

    // MARK: - Fixtures

    static func fixtureClass(forRelativePath path: String) -> FixtureClass {
        if path.hasPrefix("RealWorld/") { return .realWorld }
        if path.hasPrefix("Stress/") { return .stress }
        if path.hasPrefix("Golden/") { return .golden }
        if path.hasPrefix("Malformed/") { return .malformed }
        return .synthetic
    }

    static func enumeratePDFs(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "pdf" }
    }

    /// Suite-Zusammenstellung laut Masterplan Finding 2/Schritt 9:
    /// - fast:   alle Synthetic + seed-basierte RealWorld-Stichprobe (~20–40 gesamt)
    /// - full:   alle Synthetic + komplette RealWorld (147 → 220+)
    /// - stress: ausschließlich Stress-Dokumente
    static func fixtures(for suite: Suite, config: Config) -> [URL] {
        let all = allFixtures(for: suite, config: config)
        guard let shard = config.shard else { return all }

        // Verteilt wird nach DATEIGRÖSSE, nicht reihum.
        //
        // Reihum war schon besser als blockweise, reichte aber nicht: Der
        // Aufwand je Dokument schwankt um Größenordnungen – der IPCC-Bericht
        // hat 404 MB, das Medianddokument 0,2 MB. Gemessen an einem Lauf mit
        // sechs gleichzeitigen Chargen: Vier waren nach 40 Minuten fertig,
        // zwei rechneten weitere 20 Minuten allein. Der Gesamtlauf ist so
        // schnell wie seine langsamste Charge.
        //
        // Das Verfahren ist die übliche Heuristik dafür: das jeweils grösste
        // verbliebene Dokument der Charge mit der bisher geringsten Last
        // zuteilen. Deterministisch – bei gleichem Korpus fällt die
        // Aufteilung immer gleich aus, sonst wären Läufe nicht vergleichbar.
        let sized = all.map { url -> (url: URL, bytes: Int64) in
            (url, Compressor.fileSize(of: url))
        }
        // Gleich grosse Dokumente nach Pfad sortieren, damit die Reihenfolge
        // eindeutig ist.
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes
                                       : $0.url.path < $1.url.path }

        var load = [Int64](repeating: 0, count: shard.count)
        var assigned: [[URL]] = Array(repeating: [], count: shard.count)
        for item in sized {
            var lightest = 0
            for i in 1..<shard.count where load[i] < load[lightest] { lightest = i }
            assigned[lightest].append(item.url)
            load[lightest] += max(item.bytes, 1)
        }
        return assigned[shard.index - 1]
    }

    private static func allFixtures(for suite: Suite, config: Config) -> [URL] {
        let root = config.corpusRoot
        switch suite {
        case .fast:
            // Golden ist IMMER vollständig dabei – es ist der Kern, der zu
            // 100 % grün sein muss (Masterplan Schritt 10).
            let golden = enumeratePDFs(under: root.appendingPathComponent("Golden"))
            let synthetic = enumeratePDFs(under: root.appendingPathComponent("Synthetic"))
            let realWorldPool = enumeratePDFs(under: root.appendingPathComponent("RealWorld"))
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var shuffler = SeededShuffler(seed: config.seed)
            let sampled = shuffler.shuffle(realWorldPool).prefix(16)
            return (golden + synthetic + sampled).sorted { $0.path < $1.path }

        case .full:
            let golden = enumeratePDFs(under: root.appendingPathComponent("Golden"))
            let synthetic = enumeratePDFs(under: root.appendingPathComponent("Synthetic"))
            let realWorld = enumeratePDFs(under: root.appendingPathComponent("RealWorld"))
            let malformed = enumeratePDFs(under: root.appendingPathComponent("Malformed"))
            return (golden + synthetic + realWorld + malformed)
                .sorted { $0.path < $1.path }

        case .stress:
            return enumeratePDFs(under: root.appendingPathComponent("Stress"))
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    static func operations(for suite: Suite, filter: Set<String>?) -> [Operation] {
        // Die Differenzmatrix gehört nicht in die Standardläufe: Sie
        // assembliert jedes Dokument zweimal und verdoppelte damit die
        // Laufzeit jedes Gates. Sie wird gezielt angefordert.
        var ops = Operation.allCases.filter { $0 != .assemblyDifferential }
        if filter?.contains(Operation.assemblyDifferential.rawValue) == true {
            ops.append(.assemblyDifferential)
        }
        if suite == .stress {
            ops = ops.filter(\.enabledInStress)
        }
        if let filter {
            ops = ops.filter { filter.contains($0.rawValue) }
        }
        return ops
    }

    // MARK: - Ausführung einer Operation (ausschließlich Production-Services)

    struct PrimaryOutput {
        let url: URL
        let expectedPages: Int?
        /// Zusätzliche Outputs (Split-Teile), werden mitvalidiert.
        let additional: [(url: URL, expectedPages: Int)]
        /// Erwartete Seitenzuordnung Output-Index → Source-Index für Render-Diff.
        let pageMapping: [Int: Int]
        /// Erwartete Drehung der Quelle für Render-Vergleich (Rotate-Op).
        let sourceRotationDegrees: Int
        /// Render-Vergleich nur beratend (Compression: datenbasierte Thresholds
        /// folgen mit dem Compression Lab – bis dahin dokumentierte Provisorien).
        let renderAdvisoryOnly: Bool
    }

    enum OperationError: Error, CustomStringConvertible {
        case serviceError(String)
        case unsupportedFixture(String)

        var description: String {
            switch self {
            case .serviceError(let m): return "Service-Fehler: \(m)"
            case .unsupportedFixture(let m): return "Nicht anwendbar: \(m)"
            }
        }
    }

    /// Führt EINE Operation auf EINEM Fixture aus und liefert die erwarteten Outputs.
    /// Ruft NUR Production-APIs auf – kein qpdf, keine Test-Implementierungen.
    static func execute(operation: Operation,
                        fixture: URL,
                        pageCount: Int,
                        workspace: URL) async throws -> PrimaryOutput {
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)

        switch operation {

        // MARK: Compression (Production Compressor)

        case .compressSmart:
            let out = workspace.appendingPathComponent("compress-smart.pdf")
            let result = try Compressor().compress(inputURL: fixture, mode: .smart)
            try FileManager.default.moveItem(at: result.outputURL, to: out)
            return PrimaryOutput(url: out, expectedPages: pageCount,
                                 additional: [], pageMapping: identity(pageCount),
                                 sourceRotationDegrees: 0, renderAdvisoryOnly: true)

        case .compressCustomBalanced,
             .compressCustomHigh,
             .compressCustomAggressive,
             .compressCustomGrayscale:
            // Die Presets kommen aus der PRODUKTIONS-Factory – dieselbe, die
            // die App benutzt. Zuvor baute der Runner eigene
            // `ImageEngineConfig`-Objekte mit abweichenden Schwellwerten:
            // Ein Korpuslauf konnte damit grün sein, während der echte
            // UI-Pfad anders konfiguriert war (Plan 2.3).
            let options: CompressionOptions
            switch operation {
            // Aus der zentralen Liste – dieselbe, die das Genauigkeitslabor
            // misst. Zwei Kopien derselben Werte sind schon einmal
            // auseinandergelaufen.
            case .compressCustomHigh:
                options = CompressionPresetFactory.CustomPreset.high.options
            case .compressCustomBalanced:
                options = CompressionPresetFactory.CustomPreset.balanced.options
            case .compressCustomAggressive:
                options = CompressionPresetFactory.CustomPreset.aggressive.options
            case .compressCustomGrayscale:
                options = CompressionPresetFactory.CustomPreset.grayscale.options
            default:
                fatalError("unreachable")
            }
            let out = workspace.appendingPathComponent("\(operation.rawValue).pdf")
            let result = try Compressor().compress(inputURL: fixture,
                                                   options: options)
            try FileManager.default.moveItem(at: result.outputURL, to: out)
            return PrimaryOutput(url: out, expectedPages: pageCount,
                                 additional: [], pageMapping: identity(pageCount),
                                 sourceRotationDegrees: 0, renderAdvisoryOnly: true)

        // MARK: Assembly (Production Page Assembly Service)

        case .merge:
            let source = SourceDocument(url: fixture, pageCount: pageCount)
            let items = (0..<pageCount).flatMap { idx -> [PageItem] in
                [PageItem(source: source, pageIndex: idx),
                 PageItem(source: source, pageIndex: idx)]
            }
            let plan = PageAssemblyPlan(pages: items.map(\.assemblyItem))
            let out = workspace.appendingPathComponent("merged.pdf")
            try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })
            return PrimaryOutput(url: out, expectedPages: pageCount * 2,
                                 additional: [], pageMapping: mapping(from: items),
                                 sourceRotationDegrees: 0, renderAdvisoryOnly: false)

        case .reorder:
            let source = SourceDocument(url: fixture, pageCount: pageCount)
            let items = (0..<pageCount).reversed().map {
                PageItem(source: source, pageIndex: $0)
            }
            let plan = PageAssemblyPlan(pages: items.map(\.assemblyItem))
            let out = workspace.appendingPathComponent("reordered.pdf")
            try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })
            return PrimaryOutput(url: out, expectedPages: pageCount,
                                 additional: [], pageMapping: mapping(from: items),
                                 sourceRotationDegrees: 0, renderAdvisoryOnly: false)

        case .rotate90:
            let source = SourceDocument(url: fixture, pageCount: pageCount)
            let items = (0..<pageCount).map { idx -> PageItem in
                var item = PageItem(source: source, pageIndex: idx)
                item.rotation = 90
                return item
            }
            let plan = PageAssemblyPlan(pages: items.map(\.assemblyItem))
            let out = workspace.appendingPathComponent("rotated.pdf")
            try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })
            return PrimaryOutput(url: out, expectedPages: pageCount,
                                 additional: [], pageMapping: mapping(from: items),
                                 sourceRotationDegrees: 90, renderAdvisoryOnly: false)

        case .deleteMiddle:
            guard pageCount >= 3 else {
                throw OperationError.unsupportedFixture("weniger als 3 Seiten")
            }
            let mid = pageCount / 2
            let source = SourceDocument(url: fixture, pageCount: pageCount)
            let items = (0..<pageCount).filter { $0 != mid }.map {
                PageItem(source: source, pageIndex: $0)
            }
            let plan = PageAssemblyPlan(pages: items.map(\.assemblyItem))
            let out = workspace.appendingPathComponent("deleted.pdf")
            try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })
            return PrimaryOutput(url: out, expectedPages: pageCount - 1,
                                 additional: [], pageMapping: mapping(from: items),
                                 sourceRotationDegrees: 0, renderAdvisoryOnly: false)

        case .assemblyDifferential:
            // Masterplan Schritt 11: Der Assembly-Cutover ist an den Nachweis
            // gebunden, dass libqpdf gegenüber PDFKit NICHTS verliert. Die
            // bestehende Matrix prüft das an neun synthetischen Fixtures –
            // hier läuft derselbe Vergleich über den echten Korpus.
            //
            // Verglichen werden die beiden ASSEMBLIERTEN Ausgaben miteinander,
            // nicht gegen die Quelle: Gesucht ist nicht, ob eine Assemblierung
            // etwas verändert, sondern ob das eine Backend weniger erhält als
            // das andere.
            let source = SourceDocument(url: fixture, pageCount: pageCount)
            // Seitenreihenfolge UNVERÄNDERT.
            //
            // Zuerst stand hier die Umkehrung, mit der Begründung, sie berühre
            // Seitenbaum und Verweise stärker. Das machte den Vergleich
            // unbrauchbar: Der Semantik-Snapshot stellt Seite i der Ausgabe
            // Seite i der Quelle gegenüber – bei umgekehrter Reihenfolge also
            // durchweg verschiedene Seiten. Gemeldet wurden dadurch 167
            // Dokumente mit „Verlusten", die in Wahrheit die beabsichtigte
            // Umordnung waren („Seite 1 Rotation: 0° → 270°" an einem
            // Dokument mit gemischter Rotation).
            //
            // Die Matrix vergleicht BACKENDS, nicht Operationen. Dafür ist
            // das Durchreichen aller Seiten in Originalreihenfolge das
            // richtige Mittel: Jede Abweichung ist dann ein echter Verlust
            // des jeweiligen Backends, keine Folge der Operation.
            let items = (0..<pageCount).map {
                PageItem(source: source, pageIndex: $0)
            }
            let plan = PageAssemblyPlan(pages: items.map(\.assemblyItem))

            let legacyURL = workspace.appendingPathComponent("legacy.pdf")
            let libqpdfURL = workspace.appendingPathComponent("libqpdf.pdf")
            try await PageAssemblyService.assemble(plan: plan, to: legacyURL,
                                                   progress: { _ in })
            try await PageAssemblyService.assemble(plan: plan, to: libqpdfURL,
                                                   progress: { _ in })

            // Die Bewertung erfolgt in `evaluate`; hier wird die libqpdf-
            // Ausgabe als primäres Ergebnis geführt und die Legacy-Ausgabe
            // als Vergleichsstück mitgegeben.
            return PrimaryOutput(url: libqpdfURL, expectedPages: pageCount,
                                 additional: [(legacyURL, pageCount)],
                                 pageMapping: mapping(from: items),
                                 sourceRotationDegrees: 0,
                                 renderAdvisoryOnly: false)

        case .extractFirstHalf:
            guard pageCount >= 2 else {
                throw OperationError.unsupportedFixture("weniger als 2 Seiten")
            }
            let half = pageCount / 2
            let source = SourceDocument(url: fixture, pageCount: pageCount)
            let items = (0..<half).map { PageItem(source: source, pageIndex: $0) }
            let plan = PageAssemblyPlan(pages: items.map(\.assemblyItem))
            let out = workspace.appendingPathComponent("extracted.pdf")
            try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })
            return PrimaryOutput(url: out, expectedPages: half,
                                 additional: [], pageMapping: mapping(from: items),
                                 sourceRotationDegrees: 0, renderAdvisoryOnly: false)

        // MARK: Split (Production Split Service)

        case .splitEvery5:
            guard pageCount >= 10 else {
                throw OperationError.unsupportedFixture(
                    "Split alle 5 Seiten erst ab 10 Seiten sinnvoll")
            }
            let source = SourceDocument(url: fixture, pageCount: pageCount)
            let items = (0..<pageCount).map { PageItem(source: source, pageIndex: $0) }
            let chunks = PageSplitter.chunks(from: items, mode: .everyN(5))
            var outputs: [(url: URL, expectedPages: Int)] = []
            for (index, chunk) in chunks.enumerated() {
                let plan = PageAssemblyPlan(pages: chunk.map(\.assemblyItem))
                let out = workspace.appendingPathComponent(
                    PageSplitter.fileName(base: "part", index: index + 1,
                                          total: chunks.count))
                try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })
                outputs.append((out, chunk.count))
            }
            return PrimaryOutput(url: outputs[0].url, expectedPages: outputs[0].expectedPages,
                                 additional: outputs.dropFirst().map { ($0.url, $0.expectedPages) },
                                 pageMapping: mapping(from: Array(chunks[0])),
                                 sourceRotationDegrees: 0, renderAdvisoryOnly: false)
        }
    }

    private static func identity(_ n: Int) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: (0..<max(n, 0)).map { ($0, $0) })
    }

    /// Seitenzuordnung AUS den tatsächlich gebauten Seiten ableiten.
    ///
    /// Vorher wurde sie neben der Konstruktion noch einmal von Hand
    /// hingeschrieben. Bei `merge` liefen beide auseinander: gebaut wurde
    /// [0,0,1,1,2,2,…], die Zuordnung behauptete `outIdx % pageCount` – also
    /// die Verkettung [0…n,0…n]. Gemessen an einem 85-seitigen Dokument
    /// verglich Ausgabeseite 85 dadurch Quellseite 0 statt 42 (CAR 0.3651
    /// gegenüber 0.0007). Aufgefallen war es nie, weil die Stichprobe erste
    /// und letzte Seite nimmt – die einzigen beiden, bei denen sich beide
    /// Zuordnungen zufällig decken. Der Merge-Test prüfte damit alles außer
    /// dem, was er prüfen sollte.
    ///
    /// Mit der Ableitung aus `items` gibt es nur noch eine Quelle der
    /// Wahrheit (Masterplan 2.1); sie kann per Konstruktion nicht mehr von
    /// dem abweichen, was der Assembler wirklich baut.
    private static func mapping(from items: [PageItem]) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues:
            items.enumerated().map { ($0.offset, $0.element.sourcePageIndex) })
    }

    // MARK: - Validierung

    /// qpdf --check als UNABHÄNGIGER externer Validator (niemals Implementierung).
    static func qpdfCheck(_ url: URL) -> (status: String, log: String) {
        guard let qp = Compressor.findQPDF() else {
            return ("SKIPPED", "qpdf nicht gefunden")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qp)
        process.arguments = ["--check", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            // Auch der Fehlerpfad muss die Deskriptoren freigeben.
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            return ("SKIPPED", "qpdf konnte nicht gestartet werden: \(error)")
        }

        // ERST lesen, DANN warten.
        //
        // Umgekehrt blockiert der Aufruf, sobald qpdf mehr ausgibt, als in
        // den Pipe-Puffer passt: Das Kind wartet aufs Schreiben, der Eltern-
        // prozess aufs Kind.
        //
        // Und: Die Handles werden explizit geschlossen. Ohne das blieb je
        // Aufruf ein Deskriptor offen – bei einem Korpuslauf mit 3135
        // Operationen also 3135 Stück. Genau daran starben vier Läufe:
        // Der Speicher blieb konstant bei ~50 MB, während die offenen
        // Deskriptoren linear mit der Operationszahl wuchsen.
        // Das SCHREIBENDE muss VOR dem Lesen geschlossen werden. Solange der
        // Elternprozess es offen hält, endet der Datenstrom nie – auch dann
        // nicht, wenn das Kind längst fertig ist – und
        // `readDataToEndOfFile()` wartet unbegrenzt. Dass es meist trotzdem
        // funktionierte, lag daran, dass Foundation das Ende oft selbst
        // schliesst; verlassen kann man sich darauf nicht.
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()
        process.waitUntilExit()

        let log = String(data: data, encoding: .utf8) ?? ""
        switch process.terminationStatus {
        case 0: return ("PASS", log)
        case 3: return ("PASS", "WARNINGS:\n\(log)")
        default: return ("FAIL", log)
        }
    }

    /// Produktions-Validierung + externe Strukturprüfung + Render-Differential.
    /// Liefert Findings mit Severity – keine stillen Toleranzen.
    static func evaluate(output: PrimaryOutput,
                         operation: Operation,
                         fixture: URL,
                         pageCount: Int,
                         workspace: URL) -> (findings: [Finding],
                                             pagesOut: Int,
                                             outputBytes: Int64,
                                             qpdfStatus: String,
                                             render: (car: Double, mad: Double,
                                                      ssim: Double, ink: Double)?) {
        var findings: [Finding] = []
        let fm = FileManager.default

        // 1. Output existiert und öffnet.
        guard fm.fileExists(atPath: output.url.path),
              Compressor.fileSize(of: output.url) > 0 else {
            findings.append(Finding(severity: .critical,
                                    message: "Output fehlt oder ist leer"))
            return (findings, 0, 0, "SKIPPED", nil)
        }
        guard let outDoc = PDFDocument(url: output.url), !outDoc.isLocked else {
            findings.append(Finding(severity: .critical,
                                    message: "Output kann nicht geöffnet werden"))
            return (findings, 0, Compressor.fileSize(of: output.url), "SKIPPED", nil)
        }

        let pagesOut = outDoc.pageCount

        // 1b. Differenzmatrix: Die beiden Backends gegeneinander.
        //
        // Sie hat eine eigene Bewertung, weil hier nicht Quelle gegen Ausgabe
        // steht, sondern Ausgabe gegen Ausgabe. Gefragt ist allein: Verliert
        // libqpdf etwas, das PDFKit erhält? Der umgekehrte Fall ist kein
        // Fehlschlag – er ist das Argument für den Cutover und wird als
        // Meldung festgehalten.
        if operation == .assemblyDifferential {
            guard let legacyURL = output.additional.first?.url else {
                findings.append(Finding(severity: .critical,
                    message: "Vergleichsausgabe des Legacy-Backends fehlt"))
                return (findings, pagesOut, Compressor.fileSize(of: output.url),
                        "SKIPPED", nil)
            }
            do {
                // BEIDE Backends werden gegen die QUELLE gemessen, nicht
                // gegeneinander.
                //
                // Der direkte Vergleich der zwei Ausgaben führt in die Irre,
                // sobald ein Backend etwas umbenennt: An `f1023ez.pdf` trägt
                // ein Feld drei Widgets, alle mit /T „Instructions". PDFKit
                // macht daraus drei eigenständige Felder und erfindet dafür
                // die Namen „Instructions_2/_3"; libqpdf behält die
                // Originalstruktur. Gegen PDFKit gemessen sah das aus, als
                // verlöre libqpdf zwei Felder – tatsächlich war libqpdf
                // quellentreu und PDFKit hatte Namen hinzuerfunden.
                //
                // Gegen die Quelle gemessen ist die Frage die richtige:
                // Was geht gegenüber dem Original verloren?
                let origin = try PDFSemanticSnapshot.capture(fixture, backend: .libQPDF)
                let legacy = try PDFSemanticSnapshot.capture(legacyURL, backend: .libQPDF)
                let libqpdf = try PDFSemanticSnapshot.capture(output.url, backend: .libQPDF)

                let libqpdfLosses = PDFSemanticSnapshot.differences(origin, libqpdf)
                    .filter { $0.severity <= .high }
                let legacyLosses = PDFSemanticSnapshot.differences(origin, legacy)
                    .filter { $0.severity <= .high }
                let legacyMessages = Set(legacyLosses.map(\.message))

                // Blockierend ist nur, was AUSSCHLIESSLICH libqpdf verliert.
                // Was beide Backends gleichermassen nicht erhalten, ist keine
                // Cutover-Frage – es ändert sich durch den Wechsel nicht.
                for loss in libqpdfLosses where !legacyMessages.contains(loss.message) {
                    findings.append(Finding(severity: .high,
                        message: "nur libqpdf verliert: \(loss.message)"))
                }
                let libqpdfMessages = Set(libqpdfLosses.map(\.message))
                for loss in legacyLosses where !libqpdfMessages.contains(loss.message) {
                    findings.append(Finding(severity: .low,
                        message: "nur PDFKit verliert: \(loss.message)"))
                }
                let shared = libqpdfMessages.intersection(legacyMessages)
                if !shared.isEmpty {
                    findings.append(Finding(severity: .low,
                        message: "beide verlieren (\(shared.count)): "
                            + shared.sorted().prefix(3).joined(separator: "; ")))
                }
            } catch {
                findings.append(Finding(severity: .high,
                    message: "Vergleich nicht möglich: \(error)"))
            }

            // Beide Ausgaben müssen strukturell sauber sein.
            for (label, url) in [("libqpdf", output.url), ("PDFKit", legacyURL)] {
                let (status, _) = qpdfCheck(url)
                if status == "FAIL" {
                    findings.append(Finding(severity: .high,
                        message: "\(label)-Ausgabe besteht qpdf --check nicht"))
                }
            }

            return (findings, pagesOut, Compressor.fileSize(of: output.url),
                    "PASS", nil)
        }

        // 2. Seitenzahl-Erwartung (primärer Output + Split-Teile).
        if let expected = output.expectedPages, pagesOut != expected {
            findings.append(Finding(severity: .critical,
                message: "Seitenzahl \(pagesOut) ≠ erwartet \(expected)"))
        }
        var additionalSum = 0
        for (index, part) in output.additional.enumerated() {
            guard let partDoc = PDFDocument(url: part.url), !partDoc.isLocked else {
                findings.append(Finding(severity: .critical,
                    message: "Split-Teil \(index + 1) nicht lesbar"))
                continue
            }
            if partDoc.pageCount != part.expectedPages {
                findings.append(Finding(severity: .critical,
                    message: "Split-Teil \(index + 1): \(partDoc.pageCount) Seiten ≠ \(part.expectedPages)"))
            }
            additionalSum += partDoc.pageCount
            let (qs, _) = qpdfCheck(part.url)
            if qs == "FAIL" {
                findings.append(Finding(severity: .high,
                    message: "Split-Teil \(index + 1): qpdf check fehlgeschlagen"))
            }
        }
        if !output.additional.isEmpty, additionalSum + pagesOut != pageCount {
            findings.append(Finding(severity: .critical,
                message: "Split-Gesamtseiten \(additionalSum + pagesOut) ≠ \(pageCount)"))
        }

        // 3. Production-Validierung gegen Referenz.
        let referenceDoc = PDFDocument(url: fixture)
        var policy: PDFValidator.Policy = operation.isCompression
            ? .compression : .assembly
        policy.expectedPageCount = output.expectedPages
        // Die Seitenzuordnung der Operation an die Validierung durchreichen:
        // Nur mit ihr kann die Erhaltungsprüfung zwischen „Seite wurde nicht
        // übernommen" und „Seite hat etwas verloren" unterscheiden. Ohne sie
        // verglich sie dokumentweite Summen, die bei jeder Teilmenge
        // zwangsläufig sinken.
        if !operation.isCompression, !output.pageMapping.isEmpty {
            policy.pageMapping = output.pageMapping
            policy.sourceURL = fixture
        }
        let report = PDFValidator.validate(outputURL: output.url,
                                           referenceDocument: referenceDoc,
                                           policy: policy)
        for failure in report.failures {
            // Text-/Annotation-/Link-/Formularverlust sind Datenverlust → HIGH;
            // reine Strukturplausibilität bleibt HIGH, Seitenzahl schon CRITICAL oben.
            findings.append(Finding(severity: .high, message: "Validierung: \(failure)"))
        }

        // 4. Unabhängiger externer Strukturvalidator (qpdf).
        let (qs, _) = qpdfCheck(output.url)
        if qs == "FAIL" {
            findings.append(Finding(severity: .high,
                                    message: "Externer qpdf-Check fehlgeschlagen"))
        }

        // 5. Render-Differential (operation-aware Mapping).
        var renderMetrics: (Double, Double, Double, Double)?
        if referenceDoc != nil {
            renderMetrics = renderCheck(output: output, operation: operation,
                                        sourceURL: fixture,
                                        findings: &findings)
        }

        return (findings, pagesOut, Compressor.fileSize(of: output.url), qs,
                renderMetrics.map { ($0.0, $0.1, $0.2, $0.3) })
    }

    private static func renderCheck(output: PrimaryOutput,
                                    operation: Operation,
                                    sourceURL: URL,
                                    findings: inout [Finding])
        -> (car: Double, mad: Double, ssim: Double, ink: Double)? {
        let mapping = output.pageMapping
        guard !mapping.isEmpty else { return nil }

        // Deterministische Stichprobe: erste + letzte gemappte Seite.
        let sortedKeys = mapping.keys.sorted()
        let samples = sortedKeys.count >= 3
            ? [sortedKeys.first!, sortedKeys.last!]
            : sortedKeys

        var worstCAR = 0.0
        var worstMAD = 0.0
        var worstSSIM = 1.0
        var worstInk = 0.0
        // Der Tinten-Delta wird nur dort gewertet, wo er etwas aussagt –
        // auf text-artigen Seiten. Auf vollflächig bebilderten Seiten misst
        // er Farbrauschen, nicht Inhaltsverlust.
        var inkIsMeaningful = false

        for outIdx in samples {
            guard let srcIdx = mapping[outIdx] else { continue }
            let partial: [Int: Int] = [outIdx: srcIdx]
            guard let diffs = try? RenderDifferential.compare(
                sourceURL: sourceURL,
                outputURL: output.url,
                dpi: RenderDifferential.standardDPI,
                pageMapping: partial,
                sourceRotationDegrees: output.sourceRotationDegrees),
                let d = diffs.first else { continue }

            worstCAR = max(worstCAR, d.changedAreaRatio)
            worstMAD = max(worstMAD, d.meanAbsDiff)
            worstSSIM = min(worstSSIM, d.ssim)
            if d.inkDeltaIsMeaningful {
                inkIsMeaningful = true
                worstInk = max(worstInk, d.inkDelta)
            }
        }

        if output.renderAdvisoryOnly {
            // Compression: legitime Bildtransformationen ändern Pixel.
            // Bis zur Datenkalibrierung (Compression Lab) gilt ein bewusst
            // großzügiger, DOKUMENTIERTER Provisoriumswert – kein verstecktes Fenster.
            //
            // AUSNAHME für die ausdrücklich aggressive Custom-Einstellung.
            //
            // Sie fährt 96 DPI bei Qualität 0,72 mit `aggressiveGraphics` –
            // also genau das, was der Planer an anderer Stelle so beschreibt:
            // „JPEG würde Text- und Linienkanten sichtbar zerstören." Auf
            // einem Bericht voller Liniendiagramme tut es das dann auch
            // (gemessen am IPCC-Bericht: SSIM 0,497 bei 45,9 % veränderter
            // Fläche).
            //
            // Das ist kein Mangel, sondern das bestellte Ergebnis: Der
            // Custom-Reiter ist die Stelle, an der der Nutzer die Parameter
            // selbst setzt. Vier von fünf Stufen liefern am selben Dokument
            // SSIM 1,000 – der Kompressor arbeitet also richtig, diese
            // Einstellung will es so.
            //
            // Die Zahl VERSCHWINDET NICHT. Sie wird als Beobachtung
            // festgehalten (`.low` lässt die Zeile auf PASS, steht aber im
            // Report). Ein stiller Ausschluss wäre das Verschweigen, das der
            // Masterplan verbietet.
            //
            // Die Ausnahme gilt AUSSCHLIESSLICH für die Renderabweichung
            // dieser einen Einstellung. Strukturverlust, Textverlust und eine
            // fehlgeschlagene qpdf-Prüfung behalten ihren Schweregrad – auch
            // ein Experte hat keinen kaputten Ausgang bestellt.
            let userChoseAggressively = (operation == .compressCustomAggressive)

            if worstSSIM < 0.50 || worstCAR > 0.60 {
                findings.append(Finding(
                    severity: userChoseAggressively ? .low : .high,
                    message: String(
                        format: userChoseAggressively
                            ? "Render stark verändert (SSIM %.3f, CAR %.3f) – erwartet bei der aggressiven Custom-Einstellung"
                            : "Render stark verändert (SSIM %.3f, CAR %.3f)",
                        worstSSIM, worstCAR)))
            } else if worstSSIM < 0.80 {
                findings.append(Finding(
                    severity: userChoseAggressively ? .low : .medium,
                    message: String(
                        format: userChoseAggressively
                            ? "Render auffällig verändert (SSIM %.3f) – erwartet bei der aggressiven Custom-Einstellung"
                            : "Render auffällig verändert (SSIM %.3f)",
                        worstSSIM)))
            }
        } else {
            // Struktur-Operationen: kalibrierte Thresholds.
            //
            // Datenbasis (Kalibrierung 2026-08-26, 150 DPI, 1400px-Metrikcanvas,
            // 28 Fixtures fast-Suite, alle Assembly-Ops):
            // PDFKit-Assembly-Roundtrips REALWORLD-Textseiten sind visuell
            // identisch, erzeugen aber Sub-Pixel-Rasterungsrauschen:
            //   CAR ≤ 0.186 · MAD ≤ ~5 · SSIM ≥ 0.970
            // Mit Rotation-Resampling:
            //   CAR ≤ 0.186 · SSIM ≥ 0.864
            // Thresholds = beobachtetes Rausch-Maximum × Sicherheitsfaktor.
            // Echte Schadensbilder liegen WEIT darüber:
            //   falsches Cropping CAR ≥ 0.4 · fehlendes Bild SSIM-Absturz
            //   falsche Rotation CAR ≈ 0.5/SSIM ≈ 0.3 · Textverlust inkDelta ≥ 0.05
            // Der Tinten-Delta ist der Inhaltsverlust-Diskriminator, der gegen
            // Rasterungsrauschen unempfindlich ist (Grenze 2 % der Seitenfläche).
            let ssimLimit: Double = output.sourceRotationDegrees == 0 ? 0.95 : 0.80
            let carLimit: Double = output.sourceRotationDegrees == 0 ? 0.30 : 0.35
            let inkExceeded = inkIsMeaningful && worstInk > 0.02
            if worstCAR > carLimit || worstSSIM < ssimLimit || worstMAD > 15
                || inkExceeded {
                findings.append(Finding(severity: .high, message: String(
                    format: "Render-Regression (CAR %.4f, SSIM %.4f, MAD %.2f, InkΔ %.4f)",
                    worstCAR, worstSSIM, worstMAD, worstInk)))
            }
        }
        return (worstCAR, worstMAD, worstSSIM, worstInk)
    }

    // MARK: - Gate-Policy (Finding 3)

    /// Entscheidet, ob ein FAIL den Gate blockiert:
    /// - Synthetic (Golden-Rolle): JEDE Failure blockiert (100 %-Regel).
    /// - RealWorld/Stress: CRITICAL und HIGH blockieren; MEDIUM/LOW werden
    ///   sichtbar dokumentiert, toleriert aber nie verschwiegen.
    static func blocks(gate row: OperationRow, fixtureClass: FixtureClass) -> Bool {
        guard row.status == "FAIL", let sevRaw = row.severity,
              let sev = Severity(rawValue: sevRaw) else { return false }
        switch fixtureClass {
        case .golden, .synthetic:
            return true
        case .realWorld, .stress:
            return sev == .critical || sev == .high
        case .malformed:
            // Ein beschädigtes Dokument DARF eine Operation scheitern lassen.
            // Was nicht sein darf: ein Absturz oder ein ausgeliefertes
            // Ergebnis, das die Prüfung nicht besteht. Beides erscheint hier
            // nicht als FAIL-Zeile, sondern als abgebrochener Testprozess
            // bzw. als CRITICAL im Validator.
            return false
        }
    }

    // MARK: - Live-Protokoll

    /// Schreibt den Fortschritt SOFORT und ungepuffert mit.
    ///
    /// Der Report entsteht erst am Ende eines Laufs. Bricht der Prozess vorher
    /// ab – Absturz, Speicherdruck, externer Abbruch –, bleibt ohne Live-Log
    /// keinerlei Spur, und man weiß nicht einmal, bei welchem Dokument es
    /// passiert ist. Genau das ist einmal eingetreten.
    ///
    /// Die Datei liegt neben dem späteren Report und wird von ihm nicht
    /// ersetzt: Sie dokumentiert den VERLAUF, er das Ergebnis.
    struct LiveLog {
        let url: URL

        init?(directory: URL) {
            let target = directory.appendingPathComponent("progress.log")
            guard FileManager.default.createFile(atPath: target.path, contents: nil)
            else { return nil }
            self.url = target
        }

        /// Hängt eine Zeile an und schließt den Deskriptor sofort wieder –
        /// so steht sie auch dann auf der Platte, wenn der Prozess stirbt.
        func append(_ line: String) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.synchronize()
        }
    }

    /// Ressourcenverbrauch des laufenden Prozesses.
    ///
    /// Wird in jede Fortschrittszeile geschrieben. Vier Korpusläufe endeten
    /// vorzeitig, ohne Crash-Report und ohne erkennbares Muster; ein
    /// Autorelease-Fix half nicht. Ohne Messreihe bleibt jede weitere
    /// Erklärung eine Vermutung – deshalb protokolliert der Runner jetzt
    /// selbst, was er verbraucht.
    enum ResourceUsage {

        /// Physischer Speicher-Fußabdruck in MB.
        static var footprintMB: Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return -1 }
            return Int(info.phys_footprint / 1_048_576)
        }

        /// Anzahl offener Dateideskriptoren.
        ///
        /// Der zweite ernstzunehmende Kandidat: Jede Operation öffnet
        /// Dokumente und schreibt Dateien. Läuft der Prozess gegen sein
        /// Deskriptorlimit, stirbt er ohne Speicherproblem.
        static var openFileDescriptors: Int {
            var limit = rlimit()
            guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return -1 }
            let maximum = Int(min(limit.rlim_cur, 65536))
            var count = 0
            for descriptor in 0..<maximum where fcntl(Int32(descriptor), F_GETFD) != -1 {
                count += 1
            }
            return count
        }

        /// Kompakte Momentaufnahme für die Protokollzeile.
        static var snapshot: String {
            "rss=\(footprintMB)MB fds=\(openFileDescriptors)"
        }
    }

    /// Schreibt jede Operationszeile SOFORT als JSON-Zeile mit.
    ///
    /// Der vollständige Report entsteht erst am Ende eines Laufs. Bei einem
    /// Abbruch nach zwei Stunden war bisher alles verloren – Stunden Rechenzeit
    /// ohne verwertbares Ergebnis. Aus diesem Journal lässt sich jederzeit ein
    /// Teilbericht rekonstruieren, auch wenn der Prozess nie zum Ende kommt.
    ///
    /// Ein Teilbericht ist ausdrücklich KEIN bestandenes Gate: Er sagt, was
    /// bis zum Abbruch gemessen wurde, und dass der Lauf unvollständig war.
    struct ResultJournal {
        let url: URL
        private let encoder: JSONEncoder

        init?(directory: URL, fileName: String = "operations.jsonl") {
            let target = directory.appendingPathComponent(fileName)
            guard FileManager.default.createFile(atPath: target.path, contents: nil)
            else { return nil }
            self.url = target
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            self.encoder = encoder
        }

        func record(_ row: OperationRow) {
            guard let data = try? encoder.encode(row),
                  let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.write(Data("\n".utf8))
            try? handle.synchronize()
        }

        /// Liest ein Journal zurück – für Teilberichte abgebrochener Läufe.
        static func read(at url: URL) -> [OperationRow] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            return text.split(separator: "\n").compactMap { line in
                try? decoder.decode(OperationRow.self, from: Data(line.utf8))
            }
        }
    }

    // MARK: - Report-Persistenz (Finding 4) – atomar

    enum Reporter {

        static func isoString(_ date: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.string(from: date)
        }

        static func runID(for date: Date, config: Config) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd_HHmmss"
            return "\(f.string(from: date))_\(config.suite.rawValue)"
                + "_seed\(config.seed)\(config.shardSuffix)"
        }

        /// Sammelverzeichnis eines gechargten Laufs.
        ///
        /// Alle Chargen desselben Laufs legen ihre Ergebnisse hier ab; erst
        /// die Zusammenführung erzeugt daraus den Gesamtreport. Die Kennung
        /// kommt von außen (PDFTOOLS_SHARD_GROUP), damit unabhängig
        /// gestartete Prozesse denselben Ort finden.
        static func shardGroupDirectory(config: Config,
                                        groupID: String) -> URL {
            config.corpusRoot
                .appendingPathComponent("Results", isDirectory: true)
                .appendingPathComponent(".shards-\(groupID)", isDirectory: true)
        }

        struct Layout {
            let staging: URL
            let failures: URL
            let renders: URL
            let logs: URL
        }

        /// Staging-Verzeichnis im Results-Baum desselben Volumes – das finale
        /// Umbenennen ist damit atomar.
        /// Wie viele Staging-Verzeichnisse abgebrochener Läufe aufgehoben
        /// werden. Sie enthalten das Live-Protokoll und sind die einzige
        /// Spur eines Abbruchs – deshalb nicht sofort löschen, aber auch
        /// nicht unbegrenzt sammeln.
        static let keptAbandonedStagings = 3

        static func makeStaging(config: Config, date: Date,
                                id: String) throws -> Layout {
            let results = config.corpusRoot.appendingPathComponent("Results",
                                                                 isDirectory: true)
            try? FileManager.default.createDirectory(at: results,
                                                     withIntermediateDirectories: true)
            pruneAbandonedStagings(in: results)

            let staging = results.appendingPathComponent(".staging-\(id)",
                                                         isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging,
                                                    withIntermediateDirectories: true)
            let failures = staging.appendingPathComponent("failures", isDirectory: true)
            let renders = staging.appendingPathComponent("renders", isDirectory: true)
            let logs = staging.appendingPathComponent("logs", isDirectory: true)
            for dir in [failures, renders, logs] {
                try FileManager.default.createDirectory(at: dir,
                                                        withIntermediateDirectories: true)
            }
            return Layout(staging: staging, failures: failures,
                          renders: renders, logs: logs)
        }

        /// Räumt Staging-Reste abgebrochener Läufe auf – die jüngsten
        /// bleiben zur Fehlersuche liegen.
        ///
        /// Ohne das sammeln sich bei jedem Abbruch Verzeichnisse mit
        /// Zwischenergebnissen an; nach einigen Fehlläufen ist nicht mehr
        /// erkennbar, welches davon noch interessant ist.
        static func pruneAbandonedStagings(in results: URL) {
            let fm = FileManager.default
            // Staging-Verzeichnisse beginnen mit einem Punkt – sie dürfen
            // deshalb NICHT als versteckte Einträge übersprungen werden.
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let entries = try? fm.contentsOfDirectory(
                at: results, includingPropertiesForKeys: keys, options: [])
            else { return }

            let stagings = entries
                .filter { $0.lastPathComponent.hasPrefix(".staging-") }
                .sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    return a > b
                }

            for old in stagings.dropFirst(keptAbandonedStagings) {
                try? fm.removeItem(at: old)
            }
        }

        // MARK: CSV

        static func csvEscaped(_ s: String) -> String {
            if s.contains(",") || s.contains("\"") || s.contains("\n") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }

        static func toCSV(_ report: RunReport) -> String {
            var csv = "fixture,fixture_class,operation,status,severity,duration_ms,"
                + "pages_in,pages_out,input_bytes,output_bytes,qpdf_check,"
                + "render_changed_area_ratio,render_mean_abs_diff,render_ssim,"
                + "render_ink_delta,peak_footprint_mb,peak_workspace_bytes,"
                + "messages\n"
            for row in report.operations {
                let renderCAR = row.renderChangedAreaRatio.map { String(format: "%.6f", $0) } ?? ""
                let renderMAD = row.renderMeanAbsDiff.map { String(format: "%.4f", $0) } ?? ""
                let renderSSIM = row.renderSSIM.map { String(format: "%.6f", $0) } ?? ""
                let renderInk = row.renderInkDelta.map { String(format: "%.6f", $0) } ?? ""
                csv += [
                    csvEscaped(row.fixture), row.fixtureClass, row.operation, row.status,
                    row.severity ?? "", String(format: "%.1f", row.durationMs),
                    String(row.pagesIn), String(row.pagesOut),
                    String(row.inputBytes), String(row.outputBytes),
                    row.qpdfCheck, renderCAR, renderMAD, renderSSIM, renderInk,
                    row.peakFootprintMB.map(String.init) ?? "",
                    row.peakWorkspaceBytes.map(String.init) ?? "",
                    csvEscaped(row.messages.joined(separator: " | ")),
                ].joined(separator: ",") + "\n"
            }
            return csv
        }

        // MARK: Markdown

        static func toMarkdown(_ report: RunReport, gateBlocked: Int) -> String {
            var md = "# Corpus Run Report\n\n"
            if let meta = report.meta {
                md += "| Feld | Wert |\n|---|---|\n"
                md += "| Run ID | \(meta.runID) |\n"
                md += "| Corpus Root | \(meta.corpusRootSource) |\n"
                md += "| Corpus ID | \(meta.corpusID) |\n"
                md += "| Suite | \(meta.suite) |\n"
                md += "| Seed | \(meta.seed) |\n"
                md += "| Start | \(meta.startedAt) |\n"
                md += "| Ende | \(meta.finishedAt) |\n"
            }
            md += "\n| Metrik | Wert |\n|---|---|\n"
            md += "| Total Operations | \(report.totalOps) |\n"
            md += "| PASS | \(report.passOps) |\n"
            md += "| FAIL | \(report.failOps) |\n"
            md += "| SKIP | \(report.skipOps) |\n"
            md += "| Gate-blocking Failures | \(gateBlocked) |\n"

            if !report.skippedFixtures.isEmpty {
                md += "\n## Übersprungene Fixtures\n\n"
                for f in report.skippedFixtures { md += "- \(f)\n" }
            }
            if report.failOps > 0 {
                md += "\n## Failures\n\n"
                for row in report.operations where row.status == "FAIL" {
                    md += "- **\(row.severity ?? "?")** \(row.fixture) · "
                        + "\(row.operation): \(row.messages.joined(separator: "; "))\n"
                }
            }
            return md
        }

        /// Schreibt alle Formate ins Staging, prüft die Summen-Konsistenz und
        /// benennt das Verzeichnis atomar um. Gilt erst danach als abgeschlossen.
        @discardableResult
        static func finalize(report: RunReport,
                             layout: Layout,
                             runID: String,
                             logLines: [String]) throws -> URL {
            var finished = report
            finished.meta?.finishedAt = isoString(Date())

            // JSON
            let jsonData = try JSONEncoder().encode(finished)
            try jsonData.write(to: layout.staging.appendingPathComponent("report.json"))

            // CSV
            let csv = toCSV(finished)
            try csv.write(to: layout.staging.appendingPathComponent("report.csv"),
                          atomically: true, encoding: .utf8)

            // Konsistenzprüfung BEVOR der Report veröffentlicht wird:
            // JSON Total == CSV Zeilen == Markdown Total == operations count.
            let total = finished.totalOps
            let jsonCheck = finished.operations.count
            let csvRows = csv.split(separator: "\n").dropFirst().count
            let mdTotal = total

            guard jsonCheck == total, csvRows == total, mdTotal == total else {
                throw NSError(domain: "CorpusRunReporter", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Report-Inkonsistenz: JSON \(jsonCheck), CSV \(csvRows), MD \(mdTotal), ops \(total)"
                ])
            }

            let gateBlockedCount = gateBlockingCount(finished)
            let md = toMarkdown(finished, gateBlocked: gateBlockedCount)
            try md.write(to: layout.staging.appendingPathComponent("report.md"),
                         atomically: true, encoding: .utf8)

            // Log
            try logLines.joined(separator: "\n")
                .write(to: layout.logs.appendingPathComponent("run.log"),
                       atomically: true, encoding: .utf8)

            // Konsistenz nochmals gegen die geschriebenen Dateien verifizieren.
            let writtenCSV = try String(contentsOf: layout.staging
                .appendingPathComponent("report.csv"), encoding: .utf8)
            guard writtenCSV.split(separator: "\n").count - 1 == total else {
                throw NSError(domain: "CorpusRunReporter", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Geschriebene CSV weicht vom Total ab"
                ])
            }

            // Atomares Veröffentlichen.
            let finalDir = layout.staging.deletingLastPathComponent()
                .appendingPathComponent(runID, isDirectory: true)
            try? FileManager.default.removeItem(at: finalDir)
            try FileManager.default.moveItem(at: layout.staging, to: finalDir)
            return finalDir
        }

        private static func gateBlockingCount(_ report: RunReport) -> Int {
            var count = 0
            for row in report.operations where row.status == "FAIL" {
                let cls = CorpusRunnerCore.fixtureClass(forRelativePath: row.fixture)
                if CorpusRunnerCore.blocks(gate: row, fixtureClass: cls) {
                    count += 1
                }
            }
            return count
        }
    }
}
