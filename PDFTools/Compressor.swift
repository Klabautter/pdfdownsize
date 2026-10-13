import Foundation
import PDFKit

/// Compression-Backend.
///
/// Seit Masterplan Schritt 11 gibt es nur noch einen Pfad: libqpdf. Der
/// frühere `legacySmart` (PDFKit-Bildoptimierung) ist entfernt, und die
/// Prototype-Bezeichnung ist mit der bewiesenen Parität gefallen – der Name
/// verspricht jetzt genau das, was der Gate-Stand hergibt.
enum CompressionEngine: String, CaseIterable {
    case libqpdf = "libqpdf"
}

/// Die Stufen benennen den ZWECK, nicht die Technik.
///
/// Niemand muss wissen, was DPI ist, um zu wissen, ob eine Datei zum
/// Verschicken oder zum Drucken gedacht ist. Die Fachbegriffe stehen im
/// Custom-Bereich, wo sie hingehören.
///
/// Dahinter steht die übliche Trennung von „Preservation Master“ und
/// „Delivery Derivat“: Ein Archivstück soll konservativ behandelt werden, eine
/// Datei für den Mailanhang darf deutlich stärker schrumpfen. Statt beides in
/// einen Kompromiss zu zwingen, kann der Nutzer sagen, was er vorhat.
enum CompressionMode: String, CaseIterable, Identifiable {
    /// Für Mailanhänge und Uploads – so klein wie vertretbar.
    case small = "Klein"
    /// Voreinstellung: Bildschirmlesen.
    case smart = "Smart"
    /// Für Druck und Weiterverarbeitung.
    case quality = "Qualität"
    case custom = "Custom"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .small: return String(localized: "Klein")
        case .smart: return String(localized: "Smart")
        case .quality: return String(localized: "Qualität")
        case .custom: return String(localized: "Eigene")
        }
    }

    /// Dateisuffix für Vorschläge im Save-Panel und Bulk-Ablage.
    /// Umlautfrei und deterministisch. „druck" für Qualität war irreführend
    /// (die Stufe heißt „Qualität", nicht „Druck"; G7, Review 2026-10-09).
    var filenameSuffix: String {
        switch self {
        case .small: return String(localized: "klein", comment: "Dateisuffix")
        case .smart: return String(localized: "smart", comment: "Dateisuffix")
        case .quality: return String(localized: "qualitaet", comment: "Dateisuffix")
        case .custom: return String(localized: "eigene", comment: "Dateisuffix")
        }
    }

    var tagline: String {
        switch self {
        case .small:
            return String(localized: "Zum Verschicken – kleinstmöglich bei lesbarer Darstellung")
        case .smart:
            return String(localized: "Empfohlen – gute Bildschirmqualität, deutlich kleiner")
        case .quality:
            return String(localized: "Zum Drucken – Bilder bleiben druckfähig")
        case .custom:
            return String(localized: "Alle Parameter selbst bestimmen – Engine schützt weiterhin das Dokument")
        }
    }
}

struct CompressionResult {
    let outputURL: URL
    let inputBytes: Int64
    let outputBytes: Int64
    var alreadyOptimized: Bool = false

    /// Die Ausgabe IST die Eingabe – unverändert durchgereicht, weil die
    /// Kompression sie nicht kleiner bekommen hat.
    ///
    /// Das ist mehr als eine Statistik: Nur was wir SELBST erzeugen, ist auch
    /// von uns geprüft. Ein durchgereichtes Original trägt weiter alles, was
    /// der Nutzer mitgebracht hat, Schäden eingeschlossen – dafür ist es
    /// garantiert byte-identisch. Wer die Zusage „geprüft" braucht, muss
    /// dieses Feld ansehen.
    var returnedOriginal: Bool = false

    /// V2-5 (§11.5) – Anzahl der Re-Plan-Läufe der QA-Rollback-Kette
    /// (0 = es gab keinen Rollback). Additives Telemetriefeld.
    var qaReplanCount: Int = 0

    /// V2-5 (§11.5) – 1, wenn der letzte Lauf der erzwungene safe-lossless-
    /// Fallback war (Endstufe der Kette), sonst 0.
    var qaFallbackCount: Int = 0

    // MARK: Phase V2-6 (§17) – Zielgrößen-Telemetrie
    //
    // Alle Felder sind additive Defaults: Ohne Zielgrößen-Ziel verhalten
    // sich mode-basierte Aufrufe exakt wie bisher.

    /// §12.1 – das angeforderte Ziel in Bytes; nil ohne Ziel.
    var targetRequestedBytes: Int64? = nil
    /// §12.7 – true, wenn die AUSGELIEFERTE Datei das Ziel hält
    /// (output <= target); nil ohne Ziel.
    var targetMet: Bool? = nil
    /// Anzahl der ausgewählten (transformierten) Kandidaten des finalen
    /// Plans.
    var selectedCandidateCount: Int = 0
    /// §12.8 – Meldungen des Zielgrößen-Loops (z. B. „Ziel X MB – sicher
    /// erreichbar ca. Y MB“); leer ohne Zielgrößen-Ziel.
    var warningSummary: [String] = []

    var savedPercent: Double {
        guard inputBytes > 0 else { return 0 }
        return (1 - Double(outputBytes) / Double(inputBytes)) * 100
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum CompressionError: LocalizedError {
    case notAPDF
    case loadFailed
    case writeFailed
    case validationFailed
    case qpdfMissing

    var errorDescription: String? {
        switch self {
        case .notAPDF:
            return String(localized: "Diese Datei ist kein PDF.")
        case .loadFailed:
            return String(localized: "Das PDF konnte nicht geöffnet werden (evtl. beschädigt oder passwortgeschützt).")
        case .writeFailed:
            return String(localized: "Die komprimierte Datei konnte nicht geschrieben werden.")
        case .validationFailed:
            return String(localized: "Das Ergebnis konnte nicht validiert werden. Original wurde nicht verändert.")
        case .qpdfMissing:
            // Endnutzer soll niemals Homebrew brauchen (Review P0.2).
            #if DEBUG
            return String(localized: "qpdf fehlt. Vendored Helper prüfen (Vendor/qpdf) oder brew install qpdf.")
            #else
            return String(localized: "Die Kompressionskomponente fehlt oder ist beschädigt. Bitte installiere PDFdownsize erneut.")
            #endif
        }
    }
}

struct Compressor {

    /// §12.6 – max 2 Nachjustierungs-Iterationen (Masterplan: „Max 2–3“,
    /// bewusst die Untergrenze).
    private static let maximumTargetIterations = 2

    /// Masterplan Schritt 6 – primäre API: EIN Optionsobjekt.
    ///
    /// Phase V2-1: `stageTimer` (§7.3) und `isolation` (§7.7) sind optionale
    /// Telemetrie für Benchmark/Debug. Ohne sie verhält sich der Aufruf
    /// exakt wie vorher; die Isolation wird sonst über die Umgebung
    /// `PDFTOOLS_COMPRESSION_ISOLATE=<dir>` aktiviert.
    ///
    /// Phase V2-5: `qaValidationHook` ist der Test-Seam der QA-Rollback-
    /// Kette (Muster wie `verify` in FontOptimizer.applySelectiveSubsetting).
    /// Er ersetzt die
    /// Standard-Validierung des Struktur-Outputs; nil = Produktverhalten.
    func compress(inputURL: URL,
                  options: CompressionOptions,
                  engine: CompressionEngine = CompressionEngineState.production,
                  isCancelled: (() -> Bool)? = nil,
                  progress: ((Double, String) -> Void)? = nil,
                  stageTimer: StageTimer? = nil,
                  isolation: CompressionIsolation? = nil,
                  qaValidationHook: QAValidationHook? = nil) throws -> CompressionResult {
        try compress(inputURL: inputURL,
                     mode: .custom,
                     resolvedOptions: options,
                     engine: engine,
                     isCancelled: isCancelled,
                     progress: progress,
                     stageTimer: stageTimer,
                     isolation: isolation,
                     qaValidationHook: qaValidationHook)
    }

    /// Test-Seam der QA-Rollback-Kette (V2-5, §11.5): Ersetzt die
    /// Standard-Validierung des Struktur-Outputs. Liefert der Hook nil,
    /// validiert der PDFValidator wie im Produktionslauf.
    typealias QAValidationHook = (URL) -> PDFValidator.Report?

    /// Modusbasierter Einstieg. Übersetzt die Einzelparameter GENAU EINMAL in
    /// `CompressionOptions` und gibt von da an nur noch dieses Objekt weiter.
    ///
    /// Phase V2-6 (§12.1): `goal = .targetBytes(n)` schaltet den globalen
    /// Budget-Optimizer frei (implizit Candidate-Engine, §25) und koppelt an
    /// die Preset-Floors DES GEWÄHLTEN MODUS (§12.8 – das Ziel verschärft
    /// per Budget, nie unter den Floor). `nil` = Verhalten wie bisher.
    func compress(inputURL: URL,
                  mode: CompressionMode,
                  customConfig: ImageEngineConfig? = nil,
                  stripMetadata: Bool? = nil,
                  linearize: Bool = false,
                  goal: CompressionGoal? = nil,
                  engine: CompressionEngine = CompressionEngineState.production,
                  isCancelled: (() -> Bool)? = nil,
                  progress: ((Double, String) -> Void)? = nil,
                  stageTimer: StageTimer? = nil,
                  isolation: CompressionIsolation? = nil) throws -> CompressionResult {
        try compress(inputURL: inputURL,
                     mode: mode,
                     resolvedOptions: CompressionOptions.make(
                        mode: mode,
                        customConfig: customConfig,
                        stripMetadata: stripMetadata ?? false,
                        linearize: linearize,
                        goal: goal),
                     engine: engine,
                     isCancelled: isCancelled,
                     progress: progress,
                     stageTimer: stageTimer,
                     isolation: isolation)
    }

    private func compress(inputURL: URL,
                          mode: CompressionMode,
                          resolvedOptions options: CompressionOptions,
                          engine: CompressionEngine,
                          isCancelled: (() -> Bool)?,
                          progress: ((Double, String) -> Void)?,
                          stageTimer: StageTimer? = nil,
                          isolation: CompressionIsolation? = nil,
                          qaValidationHook: QAValidationHook? = nil) throws -> CompressionResult {
        // Der Balken läuft nie rückwärts: Re-Plan-Läufe (QA-Rollback,
        // Zielgröße) melden ihre Phase als Text, der Stand bleibt stehen.
        let progress = progress.map { MonotonicProgress(forward: $0).report }
        if let isCancelled, isCancelled() { throw CancellationError() }
        guard inputURL.pathExtension.lowercased() == "pdf" else {
            throw CompressionError.notAPDF
        }

        guard Self.findQPDF() != nil else {
            throw CompressionError.qpdfMissing
        }

        // Es gibt nur noch EINEN Kompressionspfad.
        //
        // Der frühere Legacy-Pfad (PDFKit-Bildoptimierung + qpdf-Strukturlauf)
        // ist mit Masterplan Schritt 11 entfernt worden. Er war seit dem
        // Cutover nur noch Differential- und Debug-Backend; die Entscheidung
        // fällt seither im gemeinsamen `CompressionPlanner`, den Estimator und
        // Executor teilen.
        return try compressLibQPDF(inputURL: inputURL,
                                   options: options,
                                   isCancelled: isCancelled,
                                   progress: progress,
                                   stageTimer: stageTimer,
                                   isolation: isolation ?? CompressionIsolation.fromEnvironment(),
                                   qaValidationHook: qaValidationHook)
    }

    static func finalize(result: CompressionResult, destination: URL,
                         preservingSource: Bool = false) throws -> CompressionResult {
        let fm = FileManager.default
        let source: URL
        if preservingSource {
            source = destination.deletingLastPathComponent()
                .appendingPathComponent(".pdftools-\(UUID().uuidString).pdf")
            try fm.copyItem(at: result.outputURL, to: source)
        } else {
            source = result.outputURL
        }
        defer {
            if preservingSource { try? fm.removeItem(at: source) }
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
        // Verschieben ändert den Ort, nicht die Herkunft: Ob die Datei von
        // uns erzeugt oder unverändert durchgereicht wurde, gilt danach
        // genauso. Beide Kennzeichen gingen hier bisher verloren.
        return CompressionResult(
            outputURL: destination,
            inputBytes: result.inputBytes,
            outputBytes: Self.fileSize(of: destination),
            alreadyOptimized: result.alreadyOptimized,
            returnedOriginal: result.returnedOriginal,
            qaReplanCount: result.qaReplanCount,
            qaFallbackCount: result.qaFallbackCount,
            targetRequestedBytes: result.targetRequestedBytes,
            targetMet: result.targetMet,
            selectedCandidateCount: result.selectedCandidateCount,
            warningSummary: result.warningSummary
        )
    }

    private func compressLibQPDF(
        inputURL: URL,
        options: CompressionOptions,
        isCancelled: (() -> Bool)?,
        progress: ((Double, String) -> Void)?,
        stageTimer: StageTimer? = nil,
        isolation: CompressionIsolation? = nil,
        qaValidationHook: QAValidationHook? = nil
    ) throws -> CompressionResult {
        let fm = FileManager.default
        let inputBytes = Self.fileSize(of: inputURL)
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("compress-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        // Das Ergebnis wird am Ende aus dem Workspace HERAUS verschoben;
        // danach kann der Workspace immer weg – auch im Fehlerfall.
        defer { try? fm.removeItem(at: workDir) }

        // V2-6 (§12.6) – EIN CandidateStore für die GESAMTE Operation: Die
        // Payloads bleiben über den Erstlauf und alle Re-Plan-/Zielgrößen-
        // Läufe bevölkert (Actual-Size-Feedback). Der cleanup erfolgt hier
        // einmalig am Ende – weiterhin RAII-korrekt, auch im Fehlerfall.
        let candidateStore = CandidateStore()
        defer { candidateStore.cancel() }

        // §11.5 – Gesamtuhr der QA-Kette: Der ERSTE Lauf (inkl. Validierung)
        // definiert die Baseline, an der das Zeitbudget weiterer Läufe hängt.
        let chainStart = ContinuousClock.now

        // Phase V2-1 §7.7 – Isolation vorbereiten (nur Debug/Benchmark).
        let activeIsolation = try isolation.map { iso -> CompressionIsolation in
            try iso.prepare()
            try iso.record(stage: "00_original", file: inputURL,
                           qpdfPath: Self.findQPDF())
            return iso
        }

        progress?(0.05, "Analysiere Dokument …")
        let imageOutput = workDir.appendingPathComponent("images.pdf")
        var outcome = try CompressionPipeline.run(
            inputURL: inputURL,
            outputURL: imageOutput,
            options: options,
            isCancelled: isCancelled,
            progress: { progress?(0.05 + $0 * 0.75, "Optimiere Bilder …") },
            stageTimer: stageTimer,
            isolation: activeIsolation,
            store: candidateStore)

        // Phase V2-1 §7.7 – Stufe 10 (Pipeline-Output).
        if let activeIsolation {
            try? activeIsolation.record(stage: "10_images", file: imageOutput,
                                        qpdfPath: Self.findQPDF())
        }

        // Ein von der Bridge abgelehntes Objekt bedeutet, dass der Plan etwas
        // vorsah, was nicht sicher ist. Das ist ein Fehler, kein Randfall.
        if let rejected = outcome.execution.rejectedByBridge.first {
            throw CompressionExecutor.ExecutionError.bridgeRejected(rejected)
        }
        if let isCancelled, isCancelled() { throw CancellationError() }

        progress?(0.82, "Optimiere Struktur …")
        // Phase V2-9 (§15.6) – Single Final Write: Der Executor hat bereits
        // EINMAL mit finalen Writer-Optionen geschrieben; der CLI-Pass ist
        // dann redundant und entfällt (write_ms deckt beide Rollen ab).
        // Seit V2-11 ist das der Normalfall; der Zwei-Write-Pfad bleibt für
        // die dokumentierten Ausnahmen (§15.7): FlatePolicy .maximum
        // (Zopfli) und CompatibilityPolicy .maximum.
        var structureOutput = imageOutput
        if !outcome.execution.singleWriteUsed {
            structureOutput = try StageTimer.run(stageTimer, .structureMs) {
                try Self.runStructurePass(
                    input: imageOutput,
                    workDir: workDir,
                    linearize: options.linearizationPolicy == .fastWebView,
                    compatibility: options.compatibilityPolicy,
                    flate: options.flatePolicy)
            }
        }

        // Pass-Attribution §7.6 – der Struktur-Pass läuft AUSSERHALB des
        // Executors; seine Differenz wird hier am Executor-Ergebnis ergänzt.
        // Gemessene Stufendifferenz (vor/nach qpdf); 0, wenn der Pass sein
        // Feld nicht verkleinern konnte (dann gilt die Eingabe weiter).
        var execution = outcome.execution
        let structureCandidate = workDir.appendingPathComponent("structure.pdf")
        if structureOutput.path == structureCandidate.path {
            execution.bytesSavedStructure = max(0,
                Int(Self.fileSize(of: imageOutput) - Self.fileSize(of: structureOutput)))
        } else {
            execution.bytesSavedStructure = 0
        }

        // Phase V2-1 §7.7 – Stufe 50 (nach dem Struktur-Pass).
        if let activeIsolation {
            try? activeIsolation.record(stage: "50_structure", file: structureOutput,
                                        qpdfPath: Self.findQPDF())
        }

        progress?(0.92, "Validiere Ergebnis …")
        var policy = PDFValidator.Policy.compression
        policy.expectedPageCount = Self.pageCount(of: inputURL)
        // Metadaten zu entfernen ist eine Anweisung des Nutzers, kein
        // Nebeneffekt. Sie wird deshalb hier ANGEMELDET: Der Wegfall taucht
        // weiter im Bericht auf, als `[erwartet]` markiert, und lässt die
        // Validierung nicht scheitern. Ohne diese Anmeldung gilt der Verlust
        // von Titel oder Autor als Mangel – so herum stimmt es, denn ungefragt
        // darf keine Kompression Nutzereingaben wegwerfen.
        if options.metadataPolicy == .strip {
            policy.expectedDifferences.insert(.metadata)
        }

        // Validierung eines Struktur-Outputs; der Test-Seam (V2-5) ersetzt
        // den Standard-Validator, nil heißt Produktverhalten.
        func validate(_ url: URL) -> PDFValidator.Report {
            StageTimer.run(stageTimer, .semanticValidationMs) {
                qaValidationHook?(url) ?? PDFValidator.validate(
                    outputURL: url, referenceURL: inputURL, policy: policy)
            }
        }

        var report = validate(structureOutput)

        // Ein Re-Plan-Lauf (V2-5 §11.5 / V2-6 §12.6): Original öffnen, Plan
        // mit Overrides ausführen, Struktur-Pass, validieren. Alles, was der
        // erste Lauf tut – nur in einem eigenen Isolation-Unterordner, damit
        // die Stufenartefakte beider Läufe erhalten bleiben. Der gemeinsame
        // CandidateStore (V2-6) hält die Payloads über ALLE Läufe bevölkert.
        func runReplan(_ runOverrides: DecisionOverrides,
                       label: String,
                       startProgress: Double,
                       phaseText: String) throws {
            let images = workDir.appendingPathComponent("images-\(label).pdf")
            var replanIsolation: CompressionIsolation?
            if let activeIsolation {
                let sub = CompressionIsolation(directory:
                    activeIsolation.directory
                        .appendingPathComponent(label, isDirectory: true))
                try? sub.prepare()
                try? sub.record(stage: "00_original", file: inputURL,
                                qpdfPath: Self.findQPDF())
                replanIsolation = sub
            }

            outcome = try CompressionPipeline.run(
                inputURL: inputURL,
                outputURL: images,
                options: options,
                isCancelled: isCancelled,
                progress: { progress?(startProgress + $0 * 0.35, phaseText) },
                stageTimer: stageTimer,
                isolation: replanIsolation,
                overrides: runOverrides,
                store: candidateStore)
            if let replanIsolation {
                try? replanIsolation.record(stage: "10_images", file: images,
                                            qpdfPath: Self.findQPDF())
            }
            if let rejected = outcome.execution.rejectedByBridge.first {
                throw CompressionExecutor.ExecutionError.bridgeRejected(rejected)
            }

            structureOutput = images
            if !outcome.execution.singleWriteUsed {
                structureOutput = try StageTimer.run(stageTimer, .structureMs) {
                    try Self.runStructurePass(
                        input: images,
                        workDir: workDir,
                        linearize: options.linearizationPolicy == .fastWebView,
                        compatibility: options.compatibilityPolicy,
                        flate: options.flatePolicy,
                        label: "structure-\(label)")
                }
            }
            execution = outcome.execution
            let structureFile = workDir.appendingPathComponent(
                "structure-\(label).pdf")
            execution.bytesSavedStructure = structureOutput.path
                == structureFile.path
                ? max(0, Int(Self.fileSize(of: images)
                             - Self.fileSize(of: structureOutput)))
                : 0
            if let replanIsolation {
                try? replanIsolation.record(stage: "50_structure",
                                            file: structureOutput,
                                            qpdfPath: Self.findQPDF())
            }
            report = validate(structureOutput)
        }

        // MARK: §11.5 – QA-Rollback ist Re-Planning
        //
        // Der Plan-Check (traceVersion 2 – seit V2-11 der einzige Pfad)
        // bleibt als Konsistenz-Absicherung; aktiv nur mit
        // qaRollbackPolicy .auto.
        //
        // Ablauf je Versuch: Findings (nur error/fatal) → Downgrades aus der
        // Rückstufungsleiter → ORIGINAL erneut öffnen (PDFObjectID-Regel:
        // CompressionPipeline.run mit der Eingabe-URL, NIEMALS In-place am
        // Output) → Executor erneut ausführen → erneut validieren.
        var qaReplanCount = 0
        var qaFallbackCount = 0
        if options.qaRollbackPolicy == .auto, outcome.plan.traceVersion >= 2 {
            let baseline = stageMs(since: chainStart) / 1000.0
            var overrides = DecisionOverrides()
            var replans = 0

            while !report.isValid, replans < RollbackPlanner.maximumReplanAttempts {
                if let isCancelled, isCancelled() { throw CancellationError() }
                // Kostenkontrolle (§11.5): kein Re-Plan ohne Zeitbudget.
                let elapsed = stageMs(since: chainStart) / 1000.0
                guard !RollbackPlanner.timeBudgetExceeded(
                    elapsed: elapsed, baseline: baseline) else { break }
                // Kein Blind-Replan: Ressourcen-Downgrades zuerst; ohne
                // implicierte Ressourcen die §11.6-Rung (Pass-Abschaltung);
                // nichts Neues → Kette endet fail-closed.
                let downgrades = RollbackPlanner.downgrades(
                    for: report.findings, plan: outcome.plan)
                let next: DecisionOverrides
                if !downgrades.isEmpty {
                    next = DecisionOverrides(forcedCandidates: downgrades)
                } else {
                    next = RollbackPlanner.passLevelOverrides(
                        for: report.findings, plan: outcome.plan,
                        execution: execution)
                }
                guard !next.isEmpty, next != overrides else { break }
                overrides = next
                replans += 1
                progress?(0.5, "Qualitätsprüfung: vorsichtigerer Lauf \(replans) …")
                try runReplan(overrides, label: "replan-\(replans)",
                              startProgress: 0.15,
                              phaseText: "Optimiere Bilder (Re-Plan \(replans)) …")
            }

            // Endstufe (§11.5): safe lossless plan – JEDE transformierte
            // Ressource auf ihre konservativste lossless Stufe bzw. KEEP.
            // Gelingt auch das nicht, fail-closed wie bisher (Original).
            if !report.isValid {
                if let isCancelled, isCancelled() { throw CancellationError() }
                let elapsed = stageMs(since: chainStart) / 1000.0
                let safe = RollbackPlanner.forcedLosslessOverrides(plan: outcome.plan)
                if !safe.isEmpty, safe != overrides,
                   !RollbackPlanner.timeBudgetExceeded(elapsed: elapsed,
                                                       baseline: baseline) {
                    overrides = safe
                    replans += 1
                    qaFallbackCount = 1
                    progress?(0.5, "Qualitätsprüfung: verlustfreier Lauf …")
                    try runReplan(overrides, label: "replan-safe",
                                  startProgress: 0.15,
                                  phaseText: "Optimiere Bilder (sicherer Lauf) …")
                }
            }
            qaReplanCount = replans
        }

        // MARK: §12.6 – Actual-Size Feedback (V2-6, nur mit Zielgrößen-Ziel)
        //
        // Loop: plan → select → execute → final write → ACTUAL size. Die
        // Erwartung des Planers ist eine Schätzung; die gemessene Größe nach
        // dem finalen Schreiben ist die Wahrheit. Liegt sie ÜBER dem Ziel
        // und existiert ein sicherer kleinerer Stand, wird mit GEMESSENEN
        // Größen (§12.3-Nachkalibrierung) neu optimiert und via
        // DecisionOverrides (V2-5-Mechanik) erneut ausgeführt – das ORIGINAL
        // bleibt dabei stets die Eingabe (PDFObjectID-Regel), und die
        // Kandidaten-Payloads werden aus dem gemeinsamen Store wiederver-
        // wendet statt neu kodiert. Max 2 Iterationen (§12.6).
        //
        // Jede Iteration validiert erneut; gilt sie nicht, greift die
        // bestehende fail-closed-Regel unten (die Ausgabe erreicht den
        // Nutzer nicht).
        var minimumSafeBytes: Int64?
        var targetIterations = 0
        if case .targetBytes(let requested) = options.goal,
           outcome.plan.traceVersion >= 2 {
            let preset = QualityGatePreset(ssimThreshold: options.image.ssimThreshold)
            while targetIterations < Self.maximumTargetIterations {
                if let isCancelled, isCancelled() { throw CancellationError() }
                let actual = Self.fileSize(of: structureOutput)
                guard let reopt = TargetSizeOptimizer.reoptimization(
                    plan: outcome.plan,
                    actualBytes: Int64(actual),
                    requestedBytes: Int64(requested),
                    preset: preset) else { break }
                minimumSafeBytes = reopt.minimumSafeBytes
                targetIterations += 1
                progress?(0.5, "Zielgröße: Nachjustierung \(targetIterations) …")
                try runReplan(reopt.overrides, label: "target-\(targetIterations)",
                              startProgress: 0.15,
                              phaseText: "Optimiere Bilder (Zieljustierung "
                                  + "\(targetIterations)) …")
            }
        }

        // Fail-closed wie bisher – die Ausgabe erreicht den Nutzer nicht.
        // §11.6: Der Attributionstext geht als Diagnose nach stderr und
        // ändert NICHT die Fehlermeldung (deren Text ist Testvertrag).
        if !report.isValid {
            let lines = CompressionQA.explain(findings: report.findings,
                                              plan: outcome.plan,
                                              result: execution)
            if !lines.isEmpty {
                let text = lines.joined(separator: "\n") + "\n"
                FileHandle.standardError.write(Data(text.utf8))
            }
            throw PDFValidator.ValidationError.invalid(report.failures)
        }

        // Regel: Eine Kompression liefert nie eine GRÖSSERE Datei als Erfolg.
        //
        // Achtung, hier wechselt der Gegenstand: Geprüft wurde `structureOutput`,
        // ausgeliefert wird in diesem Zweig das ORIGINAL. Das ist richtig – die
        // Datei des Nutzers unverändert zurückzugeben ist besser, als sie
        // größer zu machen –, aber es heißt auch, dass die Zusage „von uns
        // geprüft" für diesen Zweig nicht gilt. Was hier gilt, ist eine
        // andere, ebenso klare Zusage: byte-identisch mit der Eingabe. Der
        // Aufrufer erfährt über `returnedOriginal`, welche der beiden er hat.
        let outputBytes = Self.fileSize(of: structureOutput)
        let delivered: URL
        let deliveredBytes: Int64
        let passedThrough: Bool
        if outputBytes >= inputBytes {
            let copy = workDir.appendingPathComponent("original.pdf")
            try fm.copyItem(at: inputURL, to: copy)
            delivered = copy
            deliveredBytes = inputBytes
            passedThrough = true
        } else {
            delivered = structureOutput
            deliveredBytes = outputBytes
            passedThrough = false
        }

        // Sitzungsordner statt losem Temp-Pfad: räumt beim Beenden auf.
        let finalURL = SessionScratch.makeURL()
        try fm.moveItem(at: delivered, to: finalURL)

        // Phase V2-1 §7.4 – Resource-Trace neben den Output schreiben.
        // Ausdrücklich NACH dem Erfolg: Ein abgebrochener Lauf hat keinen
        // Output, also auch keinen Trace daneben.
        if CompressionTraceWriter.isEnabled {
            let trace = CompressionTraceWriter.makeTrace(
                plan: outcome.plan,
                resources: outcome.resources,
                execution: execution,
                stageTimer: stageTimer,
                documentName: inputURL.lastPathComponent,
                classifications: outcome.classifications)
            try? CompressionTraceWriter.write(trace, nextTo: finalURL)
        }

        progress?(1.0, "Fertig")
        let savings = Double(inputBytes - deliveredBytes) / Double(max(inputBytes, 1))

        // Phase V2-6 (§17/§12.1) – Zielgrößen-Ergebnis. `targetMet` gilt
        // strikt für die AUSGELIEFERTE Datei (§12.7: output <= target); bei
        // unverändert durchgereichtem Original (≥ Eingabe) trägt es das
        // ebenso wie die Warnung. Ohne Ziel bleibt das Ergebnis nil –
        // das Verhalten mode-basierter Aufrufe ist unverändert.
        var warnings: [String] = []
        var targetResult: TargetSizeResult?
        if case .targetBytes(let requested) = options.goal,
           outcome.plan.traceVersion >= 2 {
            targetResult = TargetSizeResult(
                requestedBytes: Int64(requested),
                achievedBytes: deliveredBytes,
                targetMet: deliveredBytes <= Int64(requested),
                minimumSafeBytes: minimumSafeBytes)
            if targetResult?.targetMet == false {
                // §12.8 – Unerreichbares Ziel: kein Floor-Bruch, kein stiller
                // Fallback; die Meldung nennt das Sicher-Erreichbare.
                let safe = minimumSafeBytes ?? deliveredBytes
                warnings.append("Ziel "
                    + ByteCountFormatter.string(fromByteCount: Int64(requested),
                                                countStyle: .file)
                    + " – sicher erreichbar ca. "
                    + ByteCountFormatter.string(fromByteCount: safe,
                                                countStyle: .file))
            }
            if targetIterations > 0 {
                warnings.append("Zielgröße: \(targetIterations) Nachjustierung"
                    + (targetIterations == 1 ? "" : "en")
                    + " nach gemessener Größe (§12.6)")
            }
        }
        return CompressionResult(outputURL: finalURL,
                                 inputBytes: inputBytes,
                                 outputBytes: deliveredBytes,
                                 alreadyOptimized: savings < 0.01,
                                 returnedOriginal: passedThrough,
                                 qaReplanCount: qaReplanCount,
                                 qaFallbackCount: qaFallbackCount,
                                 targetRequestedBytes: targetResult?.requestedBytes,
                                 targetMet: targetResult?.targetMet,
                                 selectedCandidateCount:
                                     outcome.plan.transformedActions.count,
                                 warningSummary: warnings)
    }

    /// Verlustfreier Struktur-Pass über den gebündelten qpdf-Helfer.
    /// Wird das Ergebnis nicht kleiner, bleibt die Eingabe stehen.
    /// `label` benennt die Ausgabedatei im Workspace – Re-Plan-Läufe (V2-5)
    /// brauchen eigene Namen, sonst würde ein fehlgeschlagener qpdf-Lauf
    /// still die Datei des VORHERIGEN Laufs zurückliefern.
    private static func runStructurePass(input: URL, workDir: URL,
                                         linearize: Bool,
                                         compatibility: CompatibilityPolicy = .modern,
                                         flate: FlatePolicy = .standard,
                                         label: String = "structure") throws -> URL {
        guard let qpdfPath = findQPDF() else { throw CompressionError.qpdfMissing }
        let output = workDir.appendingPathComponent("\(label).pdf")

        let process = makeStructureProcess(qpdfPath: qpdfPath, input: input,
                                           output: output, linearize: linearize,
                                           compatibility: compatibility,
                                           flate: flate)
        try process.run()
        process.waitUntilExit()

        // Exit 3 = Warnungen, Ergebnis trotzdem gültig. Alles andere heißt:
        // Struktur-Pass hat nicht funktioniert – dann gilt die Eingabe.
        let succeeded = process.terminationStatus == 0 || process.terminationStatus == 3
        let outputSize = fileSize(of: output)
        guard succeeded, outputSize > 0 else { return input }

        // Linearisierung vergrößert die Datei planmäßig; sie ist dann trotzdem
        // das gewünschte Ergebnis.
        if linearize { return output }
        return outputSize < fileSize(of: input) ? output : input
    }

    // MARK: - Phase 3c – Struktur-Pass-Verdrahtung (Maximum, Kompatibilität)

    /// Argumente des Struktur-Passes. Reine Funktion, damit sich der Max-/
    /// Kompat-Modus ohne echten qpdf-Prozess prüfen lässt. Der Kompatibilitäts-
    /// modus verzichtet auf Objekt-Streams (PDF 1.5+); sonst bleiben es die
    /// Roadmap-Flags.
    static func structurePassArguments(linearize: Bool,
                                       objectStreamsDisabled: Bool) -> [String] {
        var arguments = [objectStreamsDisabled ? "--object-streams=disable"
                                               : "--object-streams=generate",
                         "--recompress-flate",
                         "--compression-level=9"]
        if linearize { arguments.append("--linearize") }
        return arguments
    }

    /// Prozess-Umgebung des Struktur-Passes; `nil` heißt: Parent-Umgebung
    /// erben. Zopfli (`QPDF_ZOPFLI=silent`) läuft NUR im Maximum-Preset –
    /// ~100× langsamer, deshalb bewusst nicht in Smart – und nie im
    /// Kompatibilitätsmodus. Die Parent-Umgebung wird ergänzt, nicht ersetzt.
    static func structurePassEnvironment(flate: FlatePolicy,
                                         compatibility: CompatibilityPolicy)
        -> [String: String]? {
        guard flate == .maximum, compatibility == .modern else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["QPDF_ZOPFLI"] = "silent"
        return environment
    }

    /// Der konfigurierte qpdf-Prozess des Struktur-Passes. Bewusst aus der
    /// privaten `runStructurePass` herausgezogen: So wird die Env-/Argument-
    /// Verdrahtung per Stellvertreter-Skript getestet, ohne den Produktions-
    /// pfad zu duplizieren.
    static func makeStructureProcess(qpdfPath: String, input: URL, output: URL,
                                     linearize: Bool,
                                     compatibility: CompatibilityPolicy,
                                     flate: FlatePolicy) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdfPath)
        // Ein- und Ausgabedatei gehören zum Aufruf. Bis 2026-10-13 fehlten
        // sie hier: qpdf brach mit „an input file name is required" ab, und
        // der Zwei-Write-Pfad (Kompatibilität „Maximal", Zopfli) lieferte
        // still die unveränderte Eingabe zurück.
        process.arguments = structurePassArguments(
            linearize: linearize,
            objectStreamsDisabled: compatibility == .maximum)
            + [input.path, output.path]
        if let environment = structurePassEnvironment(flate: flate,
                                                      compatibility: compatibility) {
            process.environment = environment
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    // MARK: - qpdf (verlustfreie Strukturoptimierung)

    /// Gebündelter Helper: `Contents/Helpers/qpdf` (KEIN Resource-Unterordner!).
    /// `Bundle.url(forResource:subdirectory:)` würde unter `Contents/Resources`
    /// suchen und die Binary dort nie finden – daher expliziter Pfad.
    static func bundledQPDFURL() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("qpdf")
    }

    static func findQPDF() -> String? {
        // 1. Gebündelte Binärdatei (Release: autark, kein Homebrew nötig – §61–62).
        let bundled = bundledQPDFURL()
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }

        // 2. Development-Fallbacks.
        let candidates = [
            "/opt/homebrew/bin/qpdf",
            "/usr/local/bin/qpdf",
            "/opt/local/bin/qpdf",
            "/usr/bin/qpdf"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    @discardableResult
    static func runQPDF(qpdfPath: String, input: URL, output: URL,
                        removeMetadata: Bool, linearize: Bool = false) -> Bool {
        var arguments = [
            "--object-streams=generate",
            "--recompress-flate",
            "--compression-level=9"
        ]
        if removeMetadata {
            arguments.append("--remove-metadata")
        }
        if linearize {
            arguments.append("--linearize")
        }
        arguments.append(contentsOf: [input.path, output.path])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdfPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 || process.terminationStatus == 3
        } catch {
            return false
        }
    }

    // MARK: - Analyse

    /// Byte-Rohscan auf `/ByteRange` in Fenstergröße – NIEMALS als
    /// Ganzdatei-`Data`. Phase 8: scans laufen chunked mit Überlappungsfenster,
    /// damit der Peak-RSS unabhängig von der Dateigröße bleibt.
    static func containsDigitalSignature(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let pattern = Data("/ByteRange".utf8)
        let chunkSize = 1 << 20
        var previous = Data()

        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            let window = previous + chunk
            if window.range(of: pattern) != nil {
                return true
            }
            previous = window.suffix(pattern.count + 16)
        }
        return false
    }

    static func pageCount(of url: URL) -> Int? {
        guard let document = PDFDocument(url: url) else { return nil }
        return document.pageCount
    }

    // MARK: - Helpers

    static func fileSize(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(
            atPath: url.resolvingSymlinksInPath().path)[.size] as? Int64) ?? 0
    }

    /// Producer-Vermerk in jeder erzeugten PDF – eine Stelle für alle
    /// Schreibwege. Bis 1.0.2 „PDFTools" (der Arbeitsname des Projekts).
    static let producerName = "PDFdownsize"

    static func suggestedOutputName(for inputURL: URL?,
                                      mode: CompressionMode = .small) -> String {
        guard let inputURL else { return "\(String(localized: "Dokument"))_\(CompressionMode.small.filenameSuffix).pdf" }
        let name = inputURL.deletingPathExtension().lastPathComponent
        return "\(name)_\(mode.filenameSuffix).pdf"
    }
}

/// Filtert Fortschrittsmeldungen auf monoton steigende Werte; der Text
/// wird immer weitergereicht (Phasenwechsel bleiben sichtbar).
private final class MonotonicProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var high = 0.0
    private let forward: (Double, String) -> Void

    init(forward: @escaping (Double, String) -> Void) {
        self.forward = forward
    }

    func report(_ value: Double, _ label: String) {
        lock.lock()
        high = max(high, value)
        let current = high
        lock.unlock()
        forward(current, label)
    }
}
