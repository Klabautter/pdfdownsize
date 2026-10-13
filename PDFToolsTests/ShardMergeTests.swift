import Testing
import Foundation
@testable import PDFTools

/// Führt die Journale eines gechargten Korpuslaufs zu EINEM Report zusammen.
///
/// Warum überhaupt Chargen: Der PDFKit-Assembler hält Seiteninhalte über den
/// Aufruf hinaus (gemessen 2938 MB nach sechs Durchläufen an einem
/// 126-seitigen Dokument, gegenüber 71 MB beim libqpdf-Backend). Über
/// tausende Operationen summiert sich das, bis der Prozess stirbt – vier
/// Läufe endeten so. Solange der Cutover aussteht, läuft jede Charge in einem
/// eigenen Prozess, der seinen Speicher am Ende vollständig zurückgibt.
///
/// Entscheidend für die Aussagekraft: Das Gate wird über die VEREINIGUNG
/// aller Chargen bewertet, nicht je Charge. Sonst wäre ein Lauf grün, dessen
/// Chargen einzeln grün, zusammen aber unvollständig sind.
@Suite(.serialized) struct ShardMergeTests {

    @Test func mergeShardJournalsIntoSingleReport() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let groupID = environment["PDFTOOLS_SHARD_GROUP"],
              environment["PDFTOOLS_MERGE_SHARDS"] == "1" else {
            return   // Nur im Zusammenführungsschritt von run-matrix.sh aktiv.
        }

        let config = CorpusRunnerCore.Config.fromEnvironment()
        let groupDirectory = CorpusRunnerCore.Reporter.shardGroupDirectory(
            config: config, groupID: groupID)
        try #require(FileManager.default.fileExists(atPath: groupDirectory.path),
                     "Gruppenverzeichnis fehlt: \(groupDirectory.path)")

        // --- Alle Chargen einlesen ------------------------------------------
        let journals = (try? FileManager.default.contentsOfDirectory(
            at: groupDirectory, includingPropertiesForKeys: nil, options: []))?
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        try #require(!journals.isEmpty, "Keine Charge-Journale in \(groupDirectory.path)")

        var operations: [CorpusRunnerCore.OperationRow] = []
        var perShard: [(String, Int)] = []
        for journal in journals {
            let rows = CorpusRunnerCore.ResultJournal.read(at: journal)
            perShard.append((journal.lastPathComponent, rows.count))
            operations.append(contentsOf: rows)
        }

        // --- Vollständigkeit prüfen -----------------------------------------
        //
        // Eine abgestürzte Charge hinterlässt ein kurzes Journal. Ohne diese
        // Prüfung sähe der Gesamtreport grün aus, obwohl Dokumente fehlen.
        let expectedFixtures = CorpusRunnerCore.fixtures(
            for: config.suite,
            config: CorpusRunnerCore.Config(
                corpusRoot: config.corpusRoot,
                corpusRootSource: config.corpusRootSource,
                suite: config.suite, operationFilter: config.operationFilter,
                seed: config.seed, keepOutputs: config.keepOutputs,
                corpusID: config.corpusID, shard: nil))
        let coveredFixtures = Set(operations.map(\.fixture))
        let expectedRelative = Set(expectedFixtures.map {
            $0.path.replacingOccurrences(of: config.corpusRoot.path + "/", with: "")
        })
        let missing = expectedRelative.subtracting(coveredFixtures)

        // --- Report schreiben ------------------------------------------------
        let startedAt = Date()
        var report = CorpusRunnerCore.RunReport()
        report.meta = CorpusRunnerCore.RunMeta(
            runID: "\(groupID)_merged",
            startedAt: CorpusRunnerCore.Reporter.isoString(startedAt),
            finishedAt: "",
            corpusRoot: config.corpusRoot.path,
            corpusRootSource: config.corpusRootSource,
            corpusID: config.corpusID,
            suite: config.suite.rawValue,
            seed: config.seed)
        report.operations = operations.sorted {
            ($0.fixture, $0.operation) < ($1.fixture, $1.operation)
        }

        let layout = try CorpusRunnerCore.Reporter.makeStaging(
            config: config, date: startedAt, id: "\(groupID)_merged")
        var logLines = perShard.map { "\($0.0): \($0.1) Operationen" }
        logLines.append("Gesamt: \(operations.count) Operationen aus "
            + "\(journals.count) Chargen")
        if !missing.isEmpty {
            logLines.append("FEHLENDE FIXTURES: \(missing.sorted().joined(separator: ", "))")
        }

        let published = try CorpusRunnerCore.Reporter.finalize(
            report: report, layout: layout,
            runID: "\(groupID)_merged", logLines: logLines)

        let blocking = report.operations.filter { row in
            CorpusRunnerCore.blocks(
                gate: row,
                fixtureClass: CorpusRunnerCore.fixtureClass(forRelativePath: row.fixture))
        }

        print("""
        ━━ Chargen zusammengeführt ━━
        Chargen:  \(journals.count)
        Total:    \(report.totalOps) · PASS: \(report.passOps) · FAIL: \(report.failOps) · SKIP: \(report.skipOps)
        Blocking: \(blocking.count)
        Fehlende Fixtures: \(missing.count)
        Report:   \(published.path)
        """)

        // --- Gate über die VEREINIGUNG ---------------------------------------
        let missingList = missing.sorted().prefix(10).joined(separator: ", ")
        #expect(missing.isEmpty,
                "Unvollständiger Lauf – \(missing.count) Dokumente fehlen: \(missingList)")

        for row in blocking {
            let message = "GATE FAIL [\(row.severity ?? "?")] \(row.fixture) · "
                + "\(row.operation): \(row.messages.joined(separator: "; "))"
            Issue.record(Comment(rawValue: message))
        }

        // Aufräumen: Die Charge-Journale sind im Gesamtreport aufgegangen.
        if blocking.isEmpty && missing.isEmpty {
            try? FileManager.default.removeItem(at: groupDirectory)
        }
    }
}
