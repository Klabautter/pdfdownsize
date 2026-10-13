import Testing
import Foundation
import os
import PDFKit
@testable import PDFTools

/// Phase 8 – Semantik des parallelen Dokument-Runners.
///
/// Diese Prüfungen sind absichtlich NICHT in `MemoryRegressionTests`: Sie
/// messen keinen Speicher, sie laufen deshalb in der Standardsuite und
/// müssen schnell sein. Die Speicherseite der Parallelität sichert
/// `parallelDocumentCompressionDoesNotGrowMemory` (Speicherlauf).
@Suite struct CompressionConcurrencyTests {

    // MARK: - Limit

    /// Das Sliding Window hält das Limit ein – und erreicht es auch wirklich.
    /// Ein Runner, der nie parallel ausführt, wäre unentdeckt wertlos.
    @Test func slidingWindowRespectsAndReachesLimit() async throws {
        CompressionConcurrency.maxConcurrentDocuments = 2
        defer { CompressionConcurrency.resetLimit() }

        // Zähler hinter einer unfair lock (Sendable, mitLock = async-safe
        // aufrufbar) – NSLock.lock() ist aus asynchronen Kontexten
        // verwarned; die Messung selbst ist dieselbe.
        let counter = OSAllocatedUnfairLock(initialState: (active: 0, peak: 0))
        try await CompressionConcurrency.forEachDocument((0..<8).map { $0 },
                                                         limit: 2) { _ in
            counter.withLock { state in
                state.active += 1
                state.peak = max(state.peak, state.active)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            counter.withLock { state in state.active -= 1 }
        }

        let peak = counter.withLock { $0.peak }

        #expect(peak <= 2, "Sliding Window hat das Limit überschritten: \(peak)")
        #expect(peak == 2, "Es lief nie wirklich parallel (Spitze \(peak))")
    }

    /// Der Startwert ist konfigurierbar und wird gehalten.
    @Test func limitIsConfigurable() async throws {
        CompressionConcurrency.maxConcurrentDocuments = 3
        defer { CompressionConcurrency.resetLimit() }
        #expect(CompressionConcurrency.maxConcurrentDocuments == 3)

        CompressionConcurrency.resetLimit()
        #expect(CompressionConcurrency.maxConcurrentDocuments >= 1)
    }

    // MARK: - Reihenfolge

    /// Ergebnisse kommen in EINGABEREIHENFOLGE zurück, egal in welcher
    /// Reihenfolge die Dokumente fertig werden.
    @Test func compressDocumentsKeepsInputOrder() async throws {
        CompressionConcurrency.maxConcurrentDocuments = 2
        defer { CompressionConcurrency.resetLimit() }

        // Je Dokument eine andere Seitenzahl – daran ist das Ergebnis
        // seiner Quelle zuzuordnen.
        let expected = [1, 3, 2]
        let inputs = try expected.map { count in
            try PDFFixtures.write(
                PDFFixtures.document(pages: (0..<count).map {
                    PDFFixtures.textPage("Paralleldokument Seite \($0 + 1).")
                }),
                name: "concurrency-order-\(count)")
        }
        defer { for url in inputs { try? FileManager.default.removeItem(at: url) } }

        let results = try await CompressionConcurrency.compressDocuments(
            inputURLs: inputs, mode: .smart)

        #expect(results.count == inputs.count)
        for (index, result) in results.enumerated() {
            let document = try #require(PDFDocument(url: result.outputURL))
            #expect(document.pageCount == expected[index],
                    Comment(rawValue: "Ergebnis \(index) gehört zu \(expected[index]) Seiten, "
                            + "hat aber \(document.pageCount)"))
            try? FileManager.default.removeItem(at: result.outputURL)
        }
    }

    // MARK: - Fehler

    /// Ein nicht komprimierbares Dokument bricht den Lauf ab – still
    /// durchzureichen wäre ein stiller Erfolg über einen Fehlschlag.
    /// (Bewusst falsche Endung: Sie scheitert VOR dem Öffnen, also
    /// deterministisch mit `CompressionError`.)
    @Test func compressDocumentsPropagatesErrors() async throws {
        CompressionConcurrency.maxConcurrentDocuments = 2
        defer { CompressionConcurrency.resetLimit() }

        let broken = FileManager.default.temporaryDirectory
            .appendingPathComponent("concurrency-broken-\(UUID().uuidString).txt")
        try Data("kein PDF".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }

        await #expect(throws: CompressionError.self) {
            _ = try await CompressionConcurrency.compressDocuments(
                inputURLs: [broken], mode: .smart)
        }
    }
}
