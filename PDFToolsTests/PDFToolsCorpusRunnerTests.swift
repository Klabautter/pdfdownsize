import Testing
import XCTest
import AppKit
import PDFKit
@testable import PDFTools

/// Monster Epic Findings 1–4 – Einstiegspunkt des echten Corpus-Runners.
///
/// Wird ausschließlich über `Scripts/run-matrix.sh` gestartet; die Skript-
/// Argumente werden als PDFTOOLS_*-Umgebungsvariablen weitergereicht.
/// Der Runner ruft Production-Services auf und validiert jeden Output;
/// qpdf dient nur als unabhängiger externer Validator.
@Suite(.serialized)
struct PDFToolsCorpusRunnerTests {

    @Test func runConfiguredSuite() async throws {
        let config = CorpusRunnerCore.Config.fromEnvironment()
        let startedAt = Date()

        // Dieser Test ist kein Unit-Test: Er fährt den gesamten Korpus mit
        // Render- und SSIM-Vergleichen. Er gehört zu `Scripts/run-matrix.sh`
        // (Release), nicht in jeden Regressionslauf.
        //
        // Der Wächter dafür prüfte bisher, ob das KORPUSVERZEICHNIS
        // existiert – als Stellvertreter für „ist ein Korpuslauf gewollt".
        // Seit der Korpuspfad fest eingetragen ist, existiert es immer, und
        // der Stellvertreter stimmt nicht mehr: Der volle Korpuslauf hing an
        // jeder Regression und machte aus zweieinhalb Minuten Stunden.
        //
        // Gefragt wird jetzt das, was gemeint ist: Hat jemand einen
        // Korpuslauf angefordert? Das Startskript sagt es ausdrücklich.
        guard ProcessInfo.processInfo.environment["PDFTOOLS_CORPUS_RUN"] == "1"
        else {
            print("Corpus-Runner übersprungen: kein Korpuslauf angefordert "
                + "(PDFTOOLS_CORPUS_RUN nicht gesetzt). "
                + "Start über Scripts/run-matrix.sh.")
            return
        }

        // Ist einer angefordert, muss der Korpus auch da sein – dann ist ein
        // fehlendes Verzeichnis ein Fehler und keine stille Leere.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: config.corpusRoot.path,
                                             isDirectory: &isDir), isDir.boolValue else {
            Issue.record(Comment(rawValue:
                "Korpuslauf angefordert, aber \(config.corpusRoot.path) fehlt "
                + "(Quelle: \(config.corpusRootSource))."))
            return
        }

        let fixtures = CorpusRunnerCore.fixtures(for: config.suite, config: config)
        let operations = CorpusRunnerCore.operations(for: config.suite,
                                                     filter: config.operationFilter)
        // Ein leerer Korpus ist ein Fehler – eine leere CHARGE nicht: Bei
        // wenigen Dokumenten und fester Chargenzahl geht die hintere Charge
        // reihum leer aus. Sie darf dann nichts melden, nicht scheitern.
        if config.isSharded, fixtures.isEmpty {
            print("Charge\(config.shardSuffix): keine Fixtures in dieser Charge.")
            return
        }
        try #require(!fixtures.isEmpty,
                     "Keine Fixtures für Suite \(config.suite.rawValue) unter \(config.corpusRoot.path)")
        try #require(!operations.isEmpty, "Keine Operationen selektiert")

        let runID = CorpusRunnerCore.Reporter.runID(for: startedAt, config: config)
        let layout = try CorpusRunnerCore.Reporter.makeStaging(config: config,
                                                               date: startedAt,
                                                               id: runID)

        var report = CorpusRunnerCore.RunReport()
        report.meta = CorpusRunnerCore.RunMeta(
            runID: runID,
            startedAt: CorpusRunnerCore.Reporter.isoString(startedAt),
            finishedAt: "",
            corpusRoot: config.corpusRoot.path,
            corpusRootSource: config.corpusRootSource,
            corpusID: config.corpusID,
            suite: config.suite.rawValue,
            seed: config.seed)

        // Live-Protokoll: Jede Zeile steht sofort auf der Platte, damit ein
        // abgebrochener Lauf nachvollziehbar bleibt (siehe LiveLog).
        let live = CorpusRunnerCore.LiveLog(directory: layout.staging)
        // Journal: Jede fertige Operationszeile wird sofort persistiert, damit
        // ein abgebrochener Lauf auswertbar bleibt statt vollständig verloren
        // zu gehen.
        let journal = CorpusRunnerCore.ResultJournal(directory: layout.staging)

        // Bei einem gechargten Lauf wandert das Journal zusätzlich in das
        // gemeinsame Gruppenverzeichnis – nur so kann die Zusammenführung
        // später alle Chargen finden.
        let shardGroup = ProcessInfo.processInfo.environment["PDFTOOLS_SHARD_GROUP"]
        var groupJournal: CorpusRunnerCore.ResultJournal?
        if let shardGroup, config.isSharded {
            let directory = CorpusRunnerCore.Reporter.shardGroupDirectory(
                config: config, groupID: shardGroup)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            groupJournal = CorpusRunnerCore.ResultJournal(
                directory: directory,
                fileName: "operations\(config.shardSuffix).jsonl")
        }
        // EINE Stelle, die eine Operationszeile aufzeichnet.
        //
        // Vorher gab es drei Senken (lokales Journal, Gruppen-Journal für die
        // Chargen, Report) und zwei Aufrufstellen, die sie einzeln bedienten.
        // Prompt lief es auseinander: Die SKIP-Zeilen für unlesbare Dokumente
        // erreichten das Gruppen-Journal nicht, und fünf Dokumente fehlten im
        // Gesamtreport – im Einzellauf korrekt, im gechargten nicht. Mit einer
        // gemeinsamen Funktion kann eine Senke nicht mehr vergessen werden
        // (Masterplan 2.1).
        func record(_ row: CorpusRunnerCore.OperationRow) {
            journal?.record(row)
            groupJournal?.record(row)
            report.operations.append(row)
        }

        var logLines: [String] = []
        logLines.append("runID=\(runID)")
        logLines.append("corpusRoot=\(config.corpusRoot.path) (\(config.corpusRootSource))")
        logLines.append("suite=\(config.suite.rawValue) seed=\(config.seed) "
            + "fixtures=\(fixtures.count) operations=\(operations.count)")
        for line in logLines { live?.append(line) }

        let fm = FileManager.default

        for fixture in fixtures {
            let relPath = fixture.path.replacingOccurrences(
                of: config.corpusRoot.path + "/", with: "")
            let fixtureClass = CorpusRunnerCore.fixtureClass(forRelativePath: relPath)
            let doc = PDFDocument(url: fixture)

            guard let doc, doc.pageCount > 0, !doc.isLocked else {
                report.skippedFixtures.append(relPath)
                let reason = doc == nil ? "nicht lesbar"
                    : (doc?.isLocked == true ? "verschlüsselt" : "keine Seiten")
                logLines.append("SKIP-FIXTURE \(relPath): \(reason)")

                // Auch ein nicht lesbares Dokument gehört ins Journal.
                // Vorher hinterliess es dort keine Zeile – im Gesamtreport
                // fehlte es damit vollständig, und nur die
                // Vollständigkeitsprüfung der Zusammenführung verriet, dass
                // fünf Malformed-Dokumente nie geprüft worden waren. Ein
                // Dokument darf nicht stillschweigend verschwinden
                // (Masterplan 2.7: Fehler dürfen nicht verschwinden).
                for operation in operations {
                    let row = CorpusRunnerCore.OperationRow(
                        fixture: relPath, fixtureClass: fixtureClass.rawValue,
                        operation: operation.rawValue, status: "SKIP",
                        severity: nil, durationMs: 0, pagesIn: 0, pagesOut: 0,
                        inputBytes: Compressor.fileSize(of: fixture),
                        outputBytes: 0, qpdfCheck: "SKIPPED",
                        renderChangedAreaRatio: nil, renderMeanAbsDiff: nil,
                        renderSSIM: nil, renderInkDelta: nil,
                        messages: ["Dokument \(reason) – Operation nicht anwendbar"])
                    record(row)
                }
                continue
            }
            let pageCount = doc.pageCount

            for operation in operations {
                // VOR der Ausführung protokollieren – nur so ist erkennbar,
                // bei welcher Operation ein Abbruch passiert ist.
                live?.append("BEGIN \(relPath) \(operation.rawValue) "
                    + CorpusRunnerCore.ResourceUsage.snapshot)
                let slug = relPath.replacingOccurrences(of: "/", with: "__")
                    .replacingOccurrences(of: ".pdf", with: "")
                    + "@" + operation.rawValue
                let workspace = fm.temporaryDirectory
                    .appendingPathComponent("corpus-run-\(UUID().uuidString)",
                                            isDirectory: true)
                defer { try? fm.removeItem(at: workspace) }

                let t0 = Date()
                // Phase 8.6 – Spitzenspeicher und Zwischendateien messen,
                // solange die Operation läuft.
                let sampler = OperationResourceSampler(workspace: workspace)
                var row = CorpusRunnerCore.OperationRow(
                    fixture: relPath, fixtureClass: fixtureClass.rawValue,
                    operation: operation.rawValue, status: "PASS", severity: nil,
                    durationMs: 0, pagesIn: pageCount, pagesOut: 0,
                    inputBytes: Compressor.fileSize(of: fixture),
                    outputBytes: 0, qpdfCheck: "SKIPPED",
                    renderChangedAreaRatio: nil, renderMeanAbsDiff: nil,
                    renderSSIM: nil, renderInkDelta: nil, messages: [])

                do {
                    let output = try await CorpusRunnerCore.execute(
                        operation: operation, fixture: fixture,
                        pageCount: pageCount, workspace: workspace)

                    let evaluated = CorpusRunnerCore.evaluate(
                        output: output, operation: operation, fixture: fixture,
                        pageCount: pageCount, workspace: workspace)

                    let worst = evaluated.findings.map(\.severity).min()
                    // `.low` ist eine BEOBACHTUNG, kein Fehlschlag: Sie hält
                    // etwas fest, das im Report stehen soll, ohne dass die
                    // Operation misslungen wäre. Genutzt wird sie von der
                    // Differenzmatrix für die Richtung „PDFKit verliert
                    // gegenüber libqpdf" – das ist kein Mangel des geprüften
                    // Ergebnisses, sondern gerade dessen Begründung.
                    let failed = evaluated.findings.contains { $0.severity <= .medium }
                    row = CorpusRunnerCore.OperationRow(
                        fixture: relPath, fixtureClass: fixtureClass.rawValue,
                        operation: operation.rawValue,
                        status: failed ? "FAIL" : "PASS",
                        severity: worst?.rawValue,
                        durationMs: Date().timeIntervalSince(t0) * 1000,
                        pagesIn: pageCount, pagesOut: evaluated.pagesOut,
                        inputBytes: Compressor.fileSize(of: fixture),
                        outputBytes: evaluated.outputBytes,
                        qpdfCheck: evaluated.qpdfStatus,
                        renderChangedAreaRatio: evaluated.render?.car,
                        renderMeanAbsDiff: evaluated.render?.mad,
                        renderSSIM: evaluated.render?.ssim,
                        renderInkDelta: evaluated.render?.ink,
                        messages: evaluated.findings.map(\.message))

                    // Fehlerartefakte reproduzierbar ablegen.
                    if !evaluated.findings.isEmpty || config.keepOutputs {
                        let artifactDir = (!evaluated.findings.isEmpty
                            ? layout.failures : layout.staging.appendingPathComponent("outputs"))
                            .appendingPathComponent(slug, isDirectory: true)
                        try? fm.createDirectory(at: artifactDir,
                                                withIntermediateDirectories: true)
                        try? fm.copyItem(at: output.url, to: artifactDir
                            .appendingPathComponent(output.url.lastPathComponent))
                        // Auch die Nebenausgaben sichern – bei der
                        // Differenzmatrix ist die Vergleichsausgabe des
                        // anderen Backends der halbe Befund. Ohne sie liess
                        // sich nicht nachvollziehen, WORIN sich die beiden
                        // unterschieden.
                        for extra in output.additional {
                            try? fm.copyItem(at: extra.url, to: artifactDir
                                .appendingPathComponent(extra.url.lastPathComponent))
                        }
                        if !evaluated.findings.isEmpty {
                            let text = evaluated.findings
                                .map { "[\($0.severity.rawValue)] \($0.message)" }
                                .joined(separator: "\n")
                            try? text.write(
                                to: artifactDir.appendingPathComponent("findings.txt"),
                                atomically: true, encoding: .utf8)
                        }
                    }
                } catch CorpusRunnerCore.OperationError.unsupportedFixture(let reason) {
                    row = CorpusRunnerCore.OperationRow(
                        fixture: relPath, fixtureClass: fixtureClass.rawValue,
                        operation: operation.rawValue, status: "SKIP", severity: nil,
                        durationMs: Date().timeIntervalSince(t0) * 1000,
                        pagesIn: pageCount, pagesOut: 0,
                        inputBytes: Compressor.fileSize(of: fixture),
                        outputBytes: 0, qpdfCheck: "SKIPPED",
                        renderChangedAreaRatio: nil, renderMeanAbsDiff: nil,
                        renderSSIM: nil, renderInkDelta: nil, messages: [reason])
                } catch let error as CancellationError {
                    throw error
                } catch {
                    row = CorpusRunnerCore.OperationRow(
                        fixture: relPath, fixtureClass: fixtureClass.rawValue,
                        operation: operation.rawValue, status: "FAIL",
                        severity: CorpusRunnerCore.Severity.critical.rawValue,
                        durationMs: Date().timeIntervalSince(t0) * 1000,
                        pagesIn: pageCount, pagesOut: 0,
                        inputBytes: Compressor.fileSize(of: fixture),
                        outputBytes: 0, qpdfCheck: "SKIPPED",
                        renderChangedAreaRatio: nil, renderMeanAbsDiff: nil,
                        renderSSIM: nil, renderInkDelta: nil,
                        messages: ["Service-Ausnahme: \(String(describing: error))"])
                }

                // Phase 8.6 – Messwerte eintragen, bevor die Zeile
                // geschrieben wird. Einmal an dieser Stelle statt an jedem
                // der vier Zuweisungspunkte oben: Sonst fehlten sie genau
                // dort, wo etwas schiefging.
                let usage = sampler.finish()
                row.peakFootprintMB = usage.peakFootprintMB
                row.peakWorkspaceBytes = usage.peakWorkspaceBytes

                let logLine = "\(row.status) \(relPath) \(operation.rawValue) "
                    + "\(String(format: "%.0f", row.durationMs))ms"
                    + (row.severity.map { " severity=\($0)" } ?? "")
                    + " peak=\(usage.peakFootprintMB)MB"
                    + (usage.peakWorkspaceBytes >= 0
                       ? " tmp=\(usage.peakWorkspaceBytes / 1_048_576)MB" : "")
                    + " " + CorpusRunnerCore.ResourceUsage.snapshot
                logLines.append(logLine)
                live?.append(logLine)
                record(row)
            }
        }

        live?.append("ALLE OPERATIONEN ABGESCHLOSSEN (\(report.operations.count))")

        // Report atomar veröffentlichen – erst nach Konsistenzprüfung.
        let published = try CorpusRunnerCore.Reporter.finalize(report: report,
                                                              layout: layout,
                                                              runID: runID,
                                                              logLines: logLines)

        // Zusammenfassung für die Konsole.
        let blocking = report.operations.filter { row in
            CorpusRunnerCore.blocks(
                gate: row,
                fixtureClass: CorpusRunnerCore.fixtureClass(forRelativePath: row.fixture))
        }
        print("""
        ━━ Corpus Run \(runID) ━━
        Total: \(report.totalOps) · PASS: \(report.passOps) · FAIL: \(report.failOps) · SKIP: \(report.skipOps)
        Blocking: \(blocking.count)
        Report: \(published.path)
        """)

        // Gate (Finding 3): blockierende Failures dürfen nicht existieren.
        //
        // Bei einem gechargten Lauf bewertet NICHT die einzelne Charge, sondern
        // die Zusammenführung über alle Chargen (ShardMergeTests). Würde eine
        // Charge hier scheitern, bräche das Skript ab und die übrigen Chargen
        // liefen nie – man sähe die Befunde eines Sechstels statt des ganzen
        // Korpus. Die Befunde stehen im Charge-Report und im Journal; verloren
        // geht dadurch nichts.
        guard !config.isSharded else {
            if !blocking.isEmpty {
                print("Charge\(config.shardSuffix): \(blocking.count) blockierende "
                    + "Befunde – Bewertung erfolgt nach der Zusammenführung.")
            }
            return
        }

        for row in blocking {
            let message = "GATE FAIL [\(row.severity ?? "?")] \(row.fixture) · "
                + "\(row.operation): \(row.messages.joined(separator: "; "))"
            Issue.record(Comment(rawValue: message))
        }
    }
}
