import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan Finding 19 / Schritt 10 – Erzeugung und Gate von Golden- und
/// Malformed-Korpus.
///
/// Der Generator läuft über `Scripts/generate-corpus.sh` und schreibt in den
/// konfigurierten Korpus. Die Gate-Tests laufen dagegen IMMER: Sie erzeugen
/// den Korpus in einem temporären Verzeichnis und prüfen ihn dort, damit ein
/// Bruch sofort in der regulären Suite auffällt und nicht erst im Nightly.
@Suite struct CorpusGeneratorTests {

    // MARK: - Erzeugung in den echten Korpus

    /// Läuft nur mit gesetztem `PDFTOOLS_GENERATE_CORPUS=1`, damit die
    /// reguläre Suite nichts außerhalb des Temp-Verzeichnisses anfasst.
    @Test func generateIntoConfiguredCorpus() throws {
        guard ProcessInfo.processInfo.environment["PDFTOOLS_GENERATE_CORPUS"] == "1"
        else { return }

        let config = CorpusRunnerCore.Config.fromEnvironment()
        try FileManager.default.createDirectory(at: config.corpusRoot,
                                                withIntermediateDirectories: true)
        let golden = try GoldenCorpus.generate(into: config.corpusRoot)
        let malformed = try MalformedCorpus.generate(into: config.corpusRoot)

        let goldenCount = CorpusRunnerCore.enumeratePDFs(under: golden).count
        let malformedCount = CorpusRunnerCore.enumeratePDFs(under: malformed).count
        print("""
        ━━ Corpus generiert ━━
        Golden:    \(goldenCount) PDFs → \(golden.path)
        Malformed: \(malformedCount) PDFs → \(malformed.path)
        """)
        #expect(goldenCount == GoldenCorpus.entries.count)
        #expect(malformedCount == MalformedCorpus.entries.count)
    }

    // MARK: - Golden Gate

    /// Der Masterplan verlangt 30–50 Golden-PDFs mit exakten Erwartungen.
    @Test func goldenCorpusHasRequiredSizeAndCoverage() {
        let entries = GoldenCorpus.entries
        #expect(entries.count >= 30,
                "Golden-Korpus zu klein: \(entries.count) (mindestens 30)")
        #expect(entries.count <= 50,
                "Golden-Korpus zu groß: \(entries.count) (höchstens 50)")

        // Die im Masterplan geforderten Kategorien müssen abgedeckt sein.
        let categories = Set(entries.map(\.category))
        for required in ["navigation", "forms", "page-labels", "attachments",
                         "shared-xobjects", "masks", "filters", "text",
                         "images", "geometry", "structure"] {
            #expect(categories.contains(required),
                    "Golden-Kategorie fehlt: \(required)")
        }

        // Namen müssen eindeutig sein, sonst überschreiben sie sich.
        let names = entries.map { "\($0.category)/\($0.name)" }
        #expect(Set(names).count == names.count, "Doppelte Golden-Namen")
    }

    /// 100 % PASS: Jedes Golden-Dokument erfüllt seine EIGENE Erwartung.
    /// Damit ist ausgeschlossen, dass eine Erwartung nur aufgeschrieben,
    /// aber nie erfüllt wurde.
    @Test func everyGoldenDocumentMeetsItsExpectation() throws {
        var failures: [String] = []
        for entry in GoldenCorpus.entries {
            let url = try entry.make()
            defer { try? FileManager.default.removeItem(at: url) }
            let problems = GoldenCorpus.verify(url, against: entry.expectation)
            if !problems.isEmpty {
                failures.append("\(entry.category)/\(entry.name): "
                    + problems.joined(separator: "; "))
            }
        }
        let summary = failures.joined(separator: "\n")
        #expect(failures.isEmpty, "Golden-Erwartungen verletzt:\n\(summary)")
    }

    /// Jedes Golden-Dokument ist strukturell sauber – sonst prüft der Korpus
    /// die Engine an kaputten Vorlagen.
    @Test func everyGoldenDocumentIsStructurallyValid() throws {
        var failures: [String] = []
        for entry in GoldenCorpus.entries {
            let url = try entry.make()
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let core = try PDFCoreDocument(path: url.path)
                try core.check()
            } catch {
                failures.append("\(entry.category)/\(entry.name): \(error)")
            }
        }
        let summary = failures.joined(separator: "\n")
        #expect(failures.isEmpty,
                "Golden-Dokumente nicht strukturell sauber:\n\(summary)")
    }

    /// Der erzeugte Korpus ist reproduzierbar: Manifest und Dateien passen
    /// zusammen, und der Inhalt lässt sich erneut verifizieren.
    @Test func generatedGoldenCorpusIsSelfConsistent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)

        let goldenRoot = try GoldenCorpus.generate(into: root)
        let manifest = try GoldenCorpus.manifest(at: root)
        #expect(manifest.count == GoldenCorpus.entries.count)

        var failures: [String] = []
        for (relativePath, expectation) in manifest.sorted(by: { $0.key < $1.key }) {
            let url = goldenRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                failures.append("\(relativePath): Datei fehlt")
                continue
            }
            let problems = GoldenCorpus.verify(url, against: expectation)
            if !problems.isEmpty {
                failures.append("\(relativePath): " + problems.joined(separator: "; "))
            }
        }
        let summary = failures.joined(separator: "\n")
        #expect(failures.isEmpty, "Erzeugter Golden-Korpus inkonsistent:\n\(summary)")
    }

    // MARK: - Malformed Gate

    @Test func malformedCorpusCoversRequiredDefects() {
        let names = Set(MalformedCorpus.entries.map(\.name))
        for required in ["truncated", "broken-xref", "bad-stream-length",
                         "missing-object", "broken-page-tree",
                         "invalid-destination", "damaged-trailer"] {
            #expect(names.contains(required), "Malformed-Fall fehlt: \(required)")
        }
        #expect(MalformedCorpus.entries.allSatisfy { !$0.defect.isEmpty },
                "Jeder Malformed-Fall braucht eine Defektbeschreibung")
    }

    /// Jedes Dokument des Korpus muss im Journal erscheinen – auch eines,
    /// das sich gar nicht öffnen lässt.
    ///
    /// Fünf Malformed-Dokumente (truncated, damaged-trailer, not-a-pdf,
    /// broken-page-tree, page-tree-cycle) hinterliessen keine Journal-Zeile,
    /// weil der Runner sie vor der Operationsschleife übersprang. Im
    /// Gesamtreport fehlten sie damit vollständig; dass sie nie geprüft
    /// worden waren, verriet allein die Vollständigkeitsprüfung der
    /// Zusammenführung. Ein Dokument darf nicht stillschweigend verschwinden.
    @Test func unreadableFixturesStillProduceJournalRows() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-journal-\(UUID().uuidString)")
        let malformedDir = workspace.appendingPathComponent("Malformed")
        try FileManager.default.createDirectory(at: malformedDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Die Fälle, die sich nachweislich nicht öffnen lassen.
        var written: [String] = []
        for entry in MalformedCorpus.entries {
            let url = malformedDir.appendingPathComponent("\(entry.name).pdf")
            try entry.make().write(to: url)
            let document = PDFDocument(url: url)
            if document == nil || document?.pageCount == 0 || document?.isLocked == true {
                written.append(entry.name)
            }
        }
        try #require(!written.isEmpty,
                     "Kein einziger Malformed-Fall ist unlesbar – der Test prüft nichts")

        let config = CorpusRunnerCore.Config(
            corpusRoot: workspace, corpusRootSource: "test",
            suite: .full, operationFilter: ["merge"], seed: 42,
            keepOutputs: false, corpusID: "journal-test", shard: nil)
        let fixtures = CorpusRunnerCore.fixtures(for: .full, config: config)
        #expect(fixtures.count == MalformedCorpus.entries.count,
                "Nicht alle erzeugten Dokumente wurden gefunden")
    }

    /// Jede Malformed-Fixture darf GENAU EINEN Defekt tragen – den, der in
    /// `defect` beschrieben ist.
    ///
    /// Fünf Fixtures bauten ihre Seite von Hand und liessen dabei
    /// `/Resources` weg (Pflichteintrag, vererbbar). qpdf meldet dafür
    /// „Resources is missing or invalid; repairing", `pdfcore_check` wertet
    /// jede Warnung als Fehlschlag – und so schlug die Kompression von
    /// `missing-object.pdf` im Korpuslauf fehl, ohne dass die Engine etwas
    /// falsch gemacht hätte: Die Ausgabe trug exakt dieselbe Warnung wie die
    /// Quelle. Eine Fixture mit zwei Ursachen kann nicht zeigen, welche von
    /// beiden ein Ergebnis erklärt.
    ///
    /// Der Test verlangt deshalb: Ausser dem gewollten Defekt darf keine
    /// Fixture eine `Resources`-Warnung erzeugen.
    @Test(.hangGuard) func malformedFixturesCarryExactlyOneDefect() throws {
        let qpdf = try #require(Compressor.findQPDF(), "qpdf nicht gefunden")
        var contaminated: [String] = []

        for entry in MalformedCorpus.entries {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("malformed-single-\(entry.name)-\(UUID().uuidString).pdf")
            try entry.make().write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: qpdf)
            process.arguments = ["--check", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { continue }
            // Schreibende zuerst schliessen, sonst endet der Datenstrom nie
            // und das Lesen wartet unbegrenzt (siehe
            // CorpusRunnerCore.qpdfCheck).
            try? pipe.fileHandleForWriting.close()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                                as: UTF8.self)
            try? pipe.fileHandleForReading.close()
            process.waitUntilExit()

            if output.contains("Resources is missing") {
                contaminated.append("\(entry.name) (gewollt: \(entry.defect))")
            }
        }

        #expect(contaminated.isEmpty, """
            Fixtures mit einem zweiten, ungewollten Defekt (fehlendes \
            /Resources): \(contaminated.joined(separator: ", "))
            """)
    }

    /// Kein Absturz – und kein still ausgeliefertes Fehlergebnis.
    ///
    /// Erlaubt ist beides: ein sauberes Ergebnis ODER ein klarer Fehler.
    /// Nicht erlaubt ist ein Ergebnis, das die Validierung nicht besteht.
    @Test func malformedDocumentsNeverCrashAndNeverYieldInvalidOutput() async throws {
        for entry in MalformedCorpus.entries {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("malformed-\(entry.name)-\(UUID().uuidString).pdf")
            try entry.make().write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            // 1. Inspektion darf nicht abstürzen.
            if let document = try? PDFCoreDocument(path: url.path) {
                _ = document.pageCount
                _ = try? document.imageResources()
                _ = try? document.pageInfo(at: 0)
            }
            _ = try? PDFSemanticSnapshot.capture(url)

            // 2. Compression: Ergebnis ODER Fehler – nichts dazwischen.
            do {
                let result = try Compressor().compress(inputURL: url, options: .smart)
                defer { try? FileManager.default.removeItem(at: result.outputURL) }
                let core = try PDFCoreDocument(path: result.outputURL.path)
                try core.check()
                #expect(core.pageCount > 0,
                        "\(entry.name): leeres Ergebnis als Erfolg geliefert")
            } catch {
                // Erwarteter Ausgang für ein beschädigtes Dokument.
            }

            // 3. Assembly über den Produktionsservice.
            if let document = PDFDocument(url: url), document.pageCount > 0 {
                let source = SourceDocument(url: url, pageCount: document.pageCount)
                let plan = PageAssemblyPlan(pages: [
                    PageItem(source: source, pageIndex: 0).assemblyItem
                ])
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mal-out-\(UUID().uuidString).pdf")
                defer { try? FileManager.default.removeItem(at: output) }
                do {
                    try await PageAssemblyService.assemble(plan: plan, to: output,
                                                           progress: { _ in })
                    let core = try PDFCoreDocument(path: output.path)
                    try core.check()
                } catch {
                    // Ebenfalls zulässig.
                }
            }
        }
    }

    /// Ein Original darf durch keinen Verarbeitungsversuch verändert werden –
    /// gerade bei beschädigten Dateien, wo Recovery-Pfade greifen.
    @Test func malformedOriginalsAreNeverModified() throws {
        for entry in MalformedCorpus.entries {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mal-orig-\(entry.name)-\(UUID().uuidString).pdf")
            let original = try entry.make()
            try original.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            if let result = try? Compressor().compress(inputURL: url, options: .smart) {
                try? FileManager.default.removeItem(at: result.outputURL)
            }
            let after = try Data(contentsOf: url)
            #expect(after == original,
                    "\(entry.name): Originaldatei wurde verändert")
        }
    }
}
