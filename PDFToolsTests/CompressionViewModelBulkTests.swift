import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Phase 8 am ViewModel: Der Bulk-Kern von CompressionViewModel über
/// CompressionConcurrency – Reihenfolge, Fehlerpropagation, Fortschritt
/// und Abbruch sowie die Trennung von temporaeren und gespeicherten Dateien.
@Suite struct CompressionViewModelBulkTests {

    // MARK: - Fixtures

    /// Kleine PDFs mit unterscheidbarer Seitenzahl – daran ist jedes
    /// Ergebnis seiner Quelle zuzuordnen.
    private func fixtures(_ pageCounts: [Int]) throws -> [URL] {
        try pageCounts.map { count in
            try PDFFixtures.write(
                PDFFixtures.document(pages: (0..<count).map {
                    PDFFixtures.textPage("Bulk-Dokument Seite \($0 + 1).")
                }),
                name: "bulk-vm-\(count)-\(UUID().uuidString)")
        }
    }

    // MARK: - Reihenfolge und Fortschritt

    /// Drei Fixtures, Ergebnisse in EINGABEREIHENFOLGE; die bestehende
    /// Fortschrittsanzeige läuft auf 1 und meldet Abschluss.
    @Test(.hangGuard) @MainActor func bulkLaufLiefertErgebnisseInEingabereihenfolge() async throws {
        CompressionConcurrency.maxConcurrentDocuments = 2
        defer { CompressionConcurrency.resetLimit() }

        let expected = [1, 3, 2]
        let inputs = try fixtures(expected)
        defer { for url in inputs { try? FileManager.default.removeItem(at: url) } }

        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        let results = try await viewModel.runBulkCompression(inputs)

        #expect(results.count == inputs.count)
        #expect(viewModel.bulkResults.count == inputs.count)
        #expect(viewModel.isWorking == false)
        #expect(viewModel.workStartedAt == nil)
        #expect(viewModel.isCancelling == false)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.progressValue == 1,
                "Fortschritt steht bei \(viewModel.progressValue)")
        #expect(viewModel.progressLabel.contains("3"),
                "Abschlussmeldung fehlt: \(viewModel.progressLabel)")

        for (index, result) in results.enumerated() {
            let document = try #require(PDFDocument(url: result.outputURL))
            #expect(document.pageCount == expected[index],
                    Comment(rawValue: "Ergebnis \(index) gehört zu \(expected[index]) Seiten, "
                            + "hat aber \(document.pageCount)"))
            try? FileManager.default.removeItem(at: result.outputURL)
        }
    }

    /// Der Runner meldet je Dokument Fortschritt mit dem RICHTIGEN Index,
    /// monoton steigend, und jedes Dokument endet bei 1.0.
    @Test(.hangGuard) func runnerMeldetFortschrittJeDokumentMitIndex() async throws {
        CompressionConcurrency.maxConcurrentDocuments = 2
        defer { CompressionConcurrency.resetLimit() }

        let inputs = try fixtures([2, 1, 3])
        defer { for url in inputs { try? FileManager.default.removeItem(at: url) } }

        let lock = NSLock()
        var reports: [(index: Int, fraction: Double)] = []
        let results = try await CompressionConcurrency.compressDocuments(
            inputURLs: inputs,
            mode: .smart,
            onDocumentProgress: { index, _, fraction, label in
                #expect(!label.isEmpty, "Stufentext fehlt")
                lock.lock()
                reports.append((index, fraction))
                lock.unlock()
            })
        #expect(results.count == inputs.count)

        for index in inputs.indices {
            let fractions = reports.filter { $0.index == index }.map { $0.fraction }
            #expect(fractions.count >= 2,
                    "Dokument \(index) hat keinen Fortschritt gemeldet")
            #expect(fractions == fractions.sorted(),
                    "Fortschritt von Dokument \(index) nicht monoton: \(fractions)")
            #expect(fractions.last == 1.0,
                    "Dokument \(index) endete bei \(String(describing: fractions.last))")
        }
    }

    // MARK: - Fehlersemantik (sammelnd)

    /// Eine defekte Datei bricht den Lauf NICHT ab: Die übrigen Ergebnisse
    /// kommen in Eingabereihenfolge, der Fehler steht in `bulkErrors`,
    /// geworfen wird nichts (nur der globale Abbruch wirft).
    @Test(.hangGuard) @MainActor func bulkLaufSammeltFehlerOhneAbbruch() async throws {
        CompressionConcurrency.maxConcurrentDocuments = 2
        defer { CompressionConcurrency.resetLimit() }

        let inputs = try fixtures([1, 2])
        defer { for url in inputs { try? FileManager.default.removeItem(at: url) } }

        let broken = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-vm-broken-\(UUID().uuidString).txt")
        try Data("kein PDF".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }

        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        let results = try await viewModel.runBulkCompression(inputs + [broken])

        #expect(results.count == 2, "Erfolge fehlen: \(results.count)")
        #expect(viewModel.bulkResults.count == 2)
        #expect(viewModel.bulkResultInputs == inputs)
        #expect(viewModel.bulkErrors[broken] != nil, "Fehlervermerk fehlt")
        #expect(viewModel.errorMessage == nil, "Einzelfehler ist kein globaler Fehler")
        #expect(viewModel.isWorking == false)
        for r in viewModel.bulkResults {
            try? FileManager.default.removeItem(at: r.outputURL)
        }
    }

    // MARK: - Abbruch

    /// Abbruch über die bestehende Mechanik (cancelWork bzw. Task-Abbruch)
    /// bricht den Runner: CancelFlag UND Task-Abbruch sind gebrückt.
    /// Abbruch ist kein Fehler – keine errorMessage, isWorking geräumt.
    @Test(.hangGuard) @MainActor func bulkLaufLaesstSichAbbrechen() async throws {
        CompressionConcurrency.maxConcurrentDocuments = 2
        defer { CompressionConcurrency.resetLimit() }

        let inputs = try fixtures([2, 2, 2])
        defer { for url in inputs { try? FileManager.default.removeItem(at: url) } }

        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        let run = Task { try await viewModel.runBulkCompression(inputs) }
        run.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await run.value
        }
        #expect(viewModel.isWorking == false)
        #expect(viewModel.workStartedAt == nil)
        #expect(viewModel.isCancelling == false)
        #expect(viewModel.errorMessage == nil, "Abbruch ist kein Fehler")
    }

    // MARK: - Dateinamen und Zusammenfassung

    /// Namensvorschlag trägt den Modus (kein starres „klein").
    @Test func namensvorschlagTraegtModusSuffix() {
        let url = URL(fileURLWithPath: "/tmp/Bericht.pdf")
        #expect(Compressor.suggestedOutputName(for: url, mode: .small) == "Bericht_klein.pdf")
        #expect(Compressor.suggestedOutputName(for: url, mode: .smart) == "Bericht_smart.pdf")
        #expect(Compressor.suggestedOutputName(for: url, mode: .quality) == "Bericht_qualitaet.pdf")
        #expect(Compressor.suggestedOutputName(for: url, mode: .custom) == "Bericht_eigene.pdf")
    }

    /// Sammel-Zusammenfassung nennt Erfolge, Abbrüche und Fehler.
    @Test func bulkZusammenfassungNenntAlleAnteile() {
        #expect(CompressionViewModel.bulkSummaryText(total: 3, ok: 3, cancelled: 0, failed: 0)
            == "3 von 3 komprimiert")
        #expect(CompressionViewModel.bulkSummaryText(total: 4, ok: 2, cancelled: 1, failed: 1)
            == "2 von 4 komprimiert (1 abgebrochen, 1 fehlgeschlagen)")
    }

    /// Der Bulk-Lauf übernimmt den gewählten Modus – auch für die Namen
    /// bei „Alle speichern" (hier Qualität → `_qualitaet`, nicht `_klein`).
    @Test(.hangGuard) @MainActor func bulkLaufUebernimmtModusFuerNamen() async throws {
        CompressionConcurrency.maxConcurrentDocuments = 2
        defer { CompressionConcurrency.resetLimit() }

        let inputs = try fixtures([1, 1])
        defer { for url in inputs { try? FileManager.default.removeItem(at: url) } }

        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        viewModel.mode = .quality
        _ = try await viewModel.runBulkCompression(inputs)
        #expect(viewModel.bulkMode == .quality)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-namen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let saved = try viewModel.saveAllBulk(to: folder)
        #expect(saved.count == 2)
        #expect(saved.allSatisfy { $0.lastPathComponent.hasSuffix("_qualitaet.pdf") },
                "Falsche Namen: \(saved.map(\.lastPathComponent))")
    }

    @Test(.hangGuard) @MainActor func bulkSpeichernBewahrtDateienUndNamenskonflikte() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let originals = try fixtures([1, 2])
        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        defer {
            viewModel.clearBulk()
            try? fm.removeItem(at: root)
            for url in originals { try? fm.removeItem(at: url) }
        }
        let inputs = try originals.enumerated().map { index, original in
            let directory = root.appendingPathComponent("source-\(index)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let input = directory.appendingPathComponent("scan.pdf")
            try fm.copyItem(at: original, to: input)
            return input
        }
        let results = try await viewModel.runBulkCompression(inputs)
        #expect(results.count == 2)

        // A failed export must leave both temporary results available for retry.
        #expect(throws: (any Error).self) {
            try viewModel.saveAllBulk(to: root.appendingPathComponent("missing"))
        }
        #expect(results.allSatisfy { fm.fileExists(atPath: $0.outputURL.path) })

        let occupied = root.appendingPathComponent(
            Compressor.suggestedOutputName(for: inputs[0], mode: .smart))
        let sentinel = Data("existing user file".utf8)
        try sentinel.write(to: occupied)

        let firstSave = try viewModel.saveAllBulk(to: root)
        let secondSave = try viewModel.saveAllBulk(to: root)
        let saved = firstSave + secondSave
        #expect(Set(saved).count == 4)
        #expect(try Data(contentsOf: occupied) == sentinel)
        #expect(viewModel.bulkResults.map(\.outputURL) == results.map(\.outputURL))
        for batch in [firstSave, secondSave] {
            #expect(batch.compactMap { PDFDocument(url: $0)?.pageCount } == [1, 2])
        }

        viewModel.removeBulkInput(at: 0)
        viewModel.clearBulk()
        #expect(results.allSatisfy { !fm.fileExists(atPath: $0.outputURL.path) })
        #expect(saved.allSatisfy { fm.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: occupied) == sentinel)
    }

    @Test func finalizeKopiertOhneTempOderVorherigeSicherungZuVerlieren() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("temporary.pdf")
        let destination = root.appendingPathComponent("saved.pdf")
        let content = Data("compressed result".utf8)
        try content.write(to: source)
        try Data("old output".utf8).write(to: destination)
        let result = CompressionResult(outputURL: source, inputBytes: 100,
                                       outputBytes: Int64(content.count), returnedOriginal: true)
        let saved = try Compressor.finalize(result: result, destination: destination,
                                             preservingSource: true)
        #expect(saved.outputURL == destination)
        #expect(saved.returnedOriginal)
        #expect(try Data(contentsOf: destination) == content)
        #expect(try Data(contentsOf: source) == content)
        #expect(try fm.contentsOfDirectory(atPath: root.path).sorted()
                == ["saved.pdf", "temporary.pdf"])
    }

    // MARK: - Entfernen und Einzelabbruch

    /// Entfernen im Ruhezustand nimmt die Datei aus der Liste.
    @Test(.hangGuard) @MainActor func bulkEingabeLaesstSichEntfernen() throws {
        let inputs = try fixtures([1, 1, 1])
        defer { for url in inputs { try? FileManager.default.removeItem(at: url) } }

        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        viewModel.selectMany(inputs)
        #expect(viewModel.bulkInputs.count == 3)

        let removed = viewModel.bulkInputs[1]
        viewModel.removeBulkInput(at: 1)
        #expect(viewModel.bulkInputs.count == 2)
        #expect(!viewModel.bulkInputs.contains(removed))
        #expect(viewModel.bulkPageCounts[removed] == nil)
    }

    /// Seitenzahlen werden billig nachgeladen (nur Öffnen, kein Planen).
    @Test(.hangGuard) @MainActor func bulkSeitenzahlenWerdenNachgeladen() async throws {
        let inputs = try fixtures([2, 1])
        defer { for url in inputs { try? FileManager.default.removeItem(at: url) } }

        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        viewModel.selectMany(inputs)
        var waited = 0
        while viewModel.bulkPageCounts.count < 2 && waited < 40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        #expect(Set(viewModel.bulkPageCounts.values) == Set([1, 2]))
    }

    /// Einzelabbruch vermerkt nur diese Datei (kein globaler Abbruch).
    @Test(.hangGuard) @MainActor func bulkEinzelabbruchVermerktNurDieseDatei() throws {
        let inputs = try fixtures([1, 1])
        defer { for url in inputs { try? FileManager.default.removeItem(at: url) } }

        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        viewModel.selectMany(inputs)
        // Ruhezustand: kein Abbruch möglich, nichts vermerkt.
        viewModel.cancelBulkFile(at: 0)
        #expect(viewModel.bulkCancelledURLs.isEmpty)
    }
}
