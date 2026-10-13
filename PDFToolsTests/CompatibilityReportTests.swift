import Testing
import Foundation
@testable import PDFTools

/// Masterplan Finding 19 – `PDF_CORE_COMPATIBILITY_REPORT.md` wird ERZEUGT.
///
/// Der Plan ist hier ausdrücklich: „Statusdokumente werden künftig möglichst
/// aus Runner-Ergebnissen generiert. Nicht manuell Zahlen kopieren."
///
/// Der Anlass ist konkret: Die handgepflegte Fassung nannte 47 Korpus-PDFs,
/// 9 Golden und 4 Malformed – tatsächlich waren es 288, 35 und 12. Ein
/// Statusdokument, das man von Hand nachzieht, veraltet zwangsläufig, und
/// zwar unbemerkt.
///
/// Quelle sind ausschließlich Maschinendaten: `report.json` des jüngsten
/// Korpuslaufs, der Korpusbestand und – falls vorhanden – das Accuracy Lab.
@Suite(.serialized) struct CompatibilityReportTests {

    // MARK: - Eingangsdaten

    struct RunData {
        let meta: CorpusRunnerCore.RunMeta
        let operations: [CorpusRunnerCore.OperationRow]
        let skippedFixtures: [String]
        let sourcePath: String
    }

    /// Der Bericht darf NIE aus einer einzelnen Charge stammen.
    ///
    /// Genau das passierte: Der Bericht wies 517 Operationen als
    /// Gesamtergebnis aus – Charge 6 von 6 – statt der 3135 des ganzen
    /// Korpus. Ursache war die Namenssortierung: Chargen tragen ihren
    /// eigenen Startzeitpunkt, die Zusammenführung die frühere Gruppen-ID.
    @Test(.hangGuard) func reportNeverComesFromASingleShard() throws {
        let config = CorpusRunnerCore.Config.fromEnvironment()
        guard FileManager.default.fileExists(atPath: config.corpusRoot.path),
              let run = Self.latestRun(in: config.corpusRoot) else {
            return   // Ohne Korpus nichts zu prüfen.
        }
        #expect(!run.meta.runID.contains("_shard"), """
            Der Kompatibilitätsbericht stammt aus einer einzelnen Charge \
            (\(run.meta.runID)) – das ist ein Teilergebnis, kein \
            Gesamtergebnis.
            """)
    }

    /// Liest den jüngsten VOLLSTÄNDIGEN Lauf. Teilberichte abgebrochener
    /// Läufe fließen bewusst nicht ein – ein Kompatibilitätsbericht aus
    /// halben Daten wäre irreführend.
    static func latestRun(in corpusRoot: URL) -> RunData? {
        let results = corpusRoot.appendingPathComponent("Results", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: results, includingPropertiesForKeys: nil, options: []) else { return nil }

        let runDirectories = entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            // Eine einzelne Charge ist per Definition ein Teilergebnis. Ohne
            // diesen Filter gewann sie sogar regelmässig: Die Chargen tragen
            // ihren eigenen Startzeitpunkt im Namen, die Zusammenführung die
            // Gruppen-ID vom Laufbeginn – also liegt die letzte Charge in der
            // Namenssortierung VOR ihr. Der Bericht wies dadurch 517
            // Operationen als Gesamtergebnis aus, ein Sechstel des Korpus.
            .filter { !$0.lastPathComponent.contains("_shard") }
            .filter { FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("report.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for directory in runDirectories {
            let url = directory.appendingPathComponent("report.json")
            guard let data = try? Data(contentsOf: url),
                  let report = try? JSONDecoder().decode(
                    CorpusRunnerCore.RunReport.self, from: data),
                  let meta = report.meta,
                  !report.operations.isEmpty else { continue }
            return RunData(meta: meta,
                           operations: report.operations,
                           skippedFixtures: report.skippedFixtures,
                           sourcePath: url.path)
        }
        return nil
    }

    // MARK: - Erzeugung

    @Test(.hangGuard) func generateCompatibilityReport() throws {
        let config = CorpusRunnerCore.Config.fromEnvironment()
        guard FileManager.default.fileExists(atPath: config.corpusRoot.path) else {
            print("Kompatibilitätsbericht übersprungen: Korpus fehlt "
                + "(PDFTOOLS_CORPUS_ROOT setzen)")
            return
        }
        guard let run = Self.latestRun(in: config.corpusRoot) else {
            print("Kompatibilitätsbericht übersprungen: kein vollständiger "
                + "Korpuslauf unter \(config.corpusRoot.path)/Results")
            return
        }

        let markdown = Self.render(run: run, corpusRoot: config.corpusRoot)
        let destination = Self.projectRoot()
            .appendingPathComponent("PDF_CORE_COMPATIBILITY_REPORT.md")
        try markdown.write(to: destination, atomically: true, encoding: .utf8)

        print("""
        ━━ Kompatibilitätsbericht erzeugt ━━
        Quelle: \(run.sourcePath)
        Lauf:   \(run.meta.runID) (\(run.operations.count) Operationen)
        Ziel:   \(destination.path)
        """)

        // Der Bericht muss die Zahlen des Laufs tragen – nicht irgendwelche.
        #expect(markdown.contains(run.meta.runID))
        #expect(markdown.contains("\(run.operations.count)"))
    }

    /// Gegenprobe zur eigentlichen Lehre aus Finding 19: Das Dokument darf
    /// keine handgepflegten Zahlen mehr enthalten.
    @Test(.hangGuard) func reportIsGeneratedNotHandMaintained() throws {
        let url = Self.projectRoot()
            .appendingPathComponent("PDF_CORE_COMPATIBILITY_REPORT.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return   // Noch nicht erzeugt – der Generator läuft mit Korpus.
        }
        let vermerk = "Der Kompatibilitätsbericht trägt keinen "
            + "Erzeugungsvermerk – wurde er von Hand bearbeitet?"
        #expect(text.contains("Automatisch erzeugt"), "\(vermerk)")
        #expect(text.contains("report.json"),
                "Der Bericht nennt seine Datenquelle nicht")
    }

    // MARK: - Rendering

    static func render(run: RunData, corpusRoot: URL) -> String {
        var lines: [String] = []
        let operations = run.operations

        func percentage(_ part: Int, _ whole: Int) -> String {
            guard whole > 0 else { return "–" }
            return String(format: "%.1f %%", Double(part) / Double(whole) * 100)
        }

        lines.append("# PDF Core Compatibility Report")
        lines.append("")
        lines.append("**Automatisch erzeugt** von `CompatibilityReportTests` "
            + "aus `report.json` (Masterplan Finding 19). Nicht von Hand "
            + "bearbeiten – Änderungen gehen beim nächsten Lauf verloren.")
        lines.append("")
        lines.append("| Feld | Wert |")
        lines.append("|---|---|")
        lines.append("| Lauf | `\(run.meta.runID)` |")
        lines.append("| Suite | \(run.meta.suite) |")
        lines.append("| Seed | \(run.meta.seed) |")
        lines.append("| Start | \(run.meta.startedAt) |")
        lines.append("| Ende | \(run.meta.finishedAt) |")
        lines.append("| Quelle | `report.json` |")
        lines.append("| Erzeugt | \(ISO8601DateFormatter().string(from: Date())) |")
        lines.append("")

        // --- Gesamtergebnis ---
        let passed = operations.filter { $0.status == "PASS" }.count
        let failed = operations.filter { $0.status == "FAIL" }.count
        let skipped = operations.filter { $0.status == "SKIP" }.count
        let blocking = operations.filter { row in
            CorpusRunnerCore.blocks(
                gate: row,
                fixtureClass: CorpusRunnerCore.fixtureClass(forRelativePath: row.fixture))
        }

        lines.append("## Gesamtergebnis")
        lines.append("")
        lines.append("| Metrik | Wert | Anteil |")
        lines.append("|---|---:|---:|")
        lines.append("| Operationen | \(operations.count) | |")
        lines.append("| PASS | \(passed) | \(percentage(passed, operations.count)) |")
        lines.append("| FAIL | \(failed) | \(percentage(failed, operations.count)) |")
        lines.append("| SKIP | \(skipped) | \(percentage(skipped, operations.count)) |")
        lines.append("| **Gate-blockierend** | **\(blocking.count)** | |")
        lines.append("")
        if blocking.isEmpty {
            lines.append("**Gate: PASS** – keine blockierenden Fehlschläge.")
        } else {
            lines.append("**Gate: FAIL** – \(blocking.count) blockierende "
                + "Fehlschläge (siehe unten).")
        }
        lines.append("")

        // --- Je Operation ---
        lines.append("## Ergebnis je Operation")
        lines.append("")
        lines.append("| Operation | PASS | FAIL | SKIP | Ø Dauer |")
        lines.append("|---|---:|---:|---:|---:|")
        let byOperation = Dictionary(grouping: operations, by: \.operation)
        for (operation, group) in byOperation.sorted(by: { $0.key < $1.key }) {
            let durations = group.filter { $0.status != "SKIP" }.map(\.durationMs)
            let average = durations.isEmpty
                ? 0 : durations.reduce(0, +) / Double(durations.count)
            lines.append("| \(operation) "
                + "| \(group.filter { $0.status == "PASS" }.count) "
                + "| \(group.filter { $0.status == "FAIL" }.count) "
                + "| \(group.filter { $0.status == "SKIP" }.count) "
                + "| \(String(format: "%.0f ms", average)) |")
        }
        lines.append("")

        // --- Je Korpusklasse ---
        lines.append("## Ergebnis je Korpusklasse")
        lines.append("")
        lines.append("Die Gate-Politik ist je Klasse verschieden: Golden und "
            + "Synthetic müssen zu 100 % bestehen, RealWorld und Stress dürfen "
            + "keine CRITICAL/HIGH-Fehlschläge zeigen, und bei Malformed ist "
            + "ein Fehlschlag der ERWARTETE Ausgang – dort zählt nur, dass "
            + "nichts abstürzt und kein ungültiges Ergebnis ausgeliefert wird.")
        lines.append("")
        lines.append("| Klasse | Operationen | PASS | FAIL | blockierend |")
        lines.append("|---|---:|---:|---:|---:|")
        let byClass = Dictionary(grouping: operations, by: \.fixtureClass)
        for (className, group) in byClass.sorted(by: { $0.key < $1.key }) {
            let classBlocking = group.filter { row in
                CorpusRunnerCore.blocks(
                    gate: row,
                    fixtureClass: CorpusRunnerCore.fixtureClass(
                        forRelativePath: row.fixture))
            }.count
            lines.append("| \(className) | \(group.count) "
                + "| \(group.filter { $0.status == "PASS" }.count) "
                + "| \(group.filter { $0.status == "FAIL" }.count) "
                + "| \(classBlocking) |")
        }
        lines.append("")

        // --- Blockierende Fehlschläge ---
        if !blocking.isEmpty {
            lines.append("## Blockierende Fehlschläge")
            lines.append("")
            for row in blocking {
                lines.append("- **\(row.severity ?? "?")** `\(row.fixture)` · "
                    + "\(row.operation)")
                for message in row.messages { lines.append("  - \(message)") }
            }
            lines.append("")
        }

        // --- Nicht blockierende Fehlschläge ---
        let tolerated = operations.filter { $0.status == "FAIL" }
            .filter { row in
                !CorpusRunnerCore.blocks(
                    gate: row,
                    fixtureClass: CorpusRunnerCore.fixtureClass(
                        forRelativePath: row.fixture))
            }
        if !tolerated.isEmpty {
            lines.append("## Nicht blockierende Fehlschläge")
            lines.append("")
            lines.append("Diese Fälle werden dokumentiert, nicht verschwiegen – "
                + "sie blockieren das Gate nach der jeweiligen Klassenpolitik "
                + "aber nicht.")
            lines.append("")
            lines.append("| Dokument | Operation | Severity | Befund |")
            lines.append("|---|---|---|---|")
            for row in tolerated.prefix(40) {
                let message = row.messages.joined(separator: "; ")
                    .replacingOccurrences(of: "|", with: "/")
                lines.append("| `\(row.fixture)` | \(row.operation) "
                    + "| \(row.severity ?? "–") | \(message.prefix(120)) |")
            }
            if tolerated.count > 40 {
                lines.append("")
                lines.append("… und \(tolerated.count - 40) weitere.")
            }
            lines.append("")
        }

        // --- Übersprungene Operationen ---
        let skips = operations.filter { $0.status == "SKIP" }
        if !skips.isEmpty {
            lines.append("## Übersprungene Operationen")
            lines.append("")
            lines.append("Jeder Skip trägt seinen Grund. Es gibt keine stillen "
                + "Auslassungen: Ein Split alle 5 Seiten ist auf einem "
                + "einseitigen Dokument nicht anwendbar, kein Mangel.")
            lines.append("")
            lines.append("| Grund | Fälle |")
            lines.append("|---|---:|")
            let reasons = Dictionary(grouping: skips) {
                $0.messages.first ?? "ohne Angabe"
            }
            for (reason, group) in reasons.sorted(by: { $0.value.count > $1.value.count }) {
                lines.append("| \(reason) | \(group.count) |")
            }
            lines.append("")
        }

        if !run.skippedFixtures.isEmpty {
            lines.append("## Nicht lesbare Dokumente")
            lines.append("")
            for fixture in run.skippedFixtures.sorted() {
                lines.append("- `\(fixture)`")
            }
            lines.append("")
        }

        // --- Korpusbestand ---
        lines.append("## Korpusbestand")
        lines.append("")
        lines.append("| Teil | PDFs |")
        lines.append("|---|---:|")
        var total = 0
        for part in ["Golden", "Synthetic", "RealWorld", "Stress", "Malformed"] {
            let count = CorpusRunnerCore.enumeratePDFs(
                under: corpusRoot.appendingPathComponent(part)).count
            total += count
            lines.append("| \(part) | \(count) |")
        }
        lines.append("| **Gesamt** | **\(total)** |")
        lines.append("")
        lines.append("Aufschlüsselung nach Quelle, Erzeuger und Inhaltsmerkmalen: "
            + "`Results/CORPUS_INVENTORY.md`.")
        lines.append("")

        // --- Engine-Zustand ---
        lines.append("## Engine-Zustand")
        lines.append("")
        lines.append("| Eigenschaft | Wert |")
        lines.append("|---|---|")
        lines.append("| Compression-Produktionspfad | "
            + "`\(CompressionEngineState.production.rawValue)` |")
        lines.append("| Compression zertifiziert | "
            + "\(CompressionEngineState.compressionCoreCertified ? "ja" : "**nein**") |")
        lines.append("| Assembly-Produktionspfad | `libqpdf` (einziger Pfad) |")
        lines.append("")
        if !CompressionEngineState.compressionCoreCertified {
            lines.append("Solange die Compression-Engine nicht zertifiziert ist, "
                + "blockiert `Scripts/release-check.sh` jeden Release-Build. "
                + "Offene Gates:")
            lines.append("")
            for blocker in CompressionEngineState.certificationBlockers {
                lines.append("- \(blocker)")
            }
            lines.append("")
        }

        // --- Weiterführend ---
        lines.append("## Weiterführende Berichte")
        lines.append("")
        lines.append("| Datei | Inhalt |")
        lines.append("|---|---|")
        lines.append("| `Results/<lauf>/report.md` | Kurzfassung des Laufs |")
        lines.append("| `Results/<lauf>/report.csv` | Alle Operationen mit "
            + "Render-Metriken, zum Filtern |")
        lines.append("| `Results/<lauf>/report.json` | Maschinenlesbare Rohdaten |")
        lines.append("| `Results/<lauf>/progress.log` | Verlauf, Zeile je Operation |")
        lines.append("| `Results/<lauf>/failures/` | Fehlerartefakte je Fall |")
        lines.append("| `Results/CORPUS_INVENTORY.md` | Korpusbestand und Diversität |")
        lines.append("| `Results/COMPRESSION_ACCURACY_LAB.md` | Schätzgenauigkeit |")
        lines.append("| `ENGINEERING_PROGRESS.md` | Fortschritt je Masterplan-Punkt |")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func projectRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
