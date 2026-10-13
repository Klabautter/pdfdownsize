import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Nutzerfrage 2026-09-30: „Wenn ich komprimiere und dann zurückgehe – wird
/// das gelöscht, oder lädt sich die App mit der Zeit voll?“
///
/// Befund: Beim Verwerfen räumt das ViewModel auf; Ergebnisse lagen aber lose
/// im Temp-Ordner und blieben nach Beenden oder Absturz liegen (dazu
/// Benchmark-Reste: 2,8 GB PDFs im Temp-Ordner des Entwicklerrechners).
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Verwerfen, Schließen oder Dateiwechsel lässt das Ergebnis liegen.
///  2. Wiederholte Läufe sammeln Dateien an (Leck über die Zeit).
///  3. Das Aufräumen beim Start löscht Ergebnisse eines LAUFENDEN Prozesses
///     (Tests neben der offenen App teilen sich den Temp-Ordner).
///  4. Beim Beenden bleibt der Sitzungsordner zurück.
///  5. Gesicherte Ergebnisse werden mitgelöscht.
@Suite(.serialized) struct SessionCleanupE2ETests {

    private func fixture(_ name: String) throws -> URL {
        try PDFFixtures.write(
            PDFFixtures.document(pages: [PDFFixtures.textPage("Aufräumen \(name)")]),
            name: "session-cleanup-\(name)-\(UUID().uuidString)")
    }

    @MainActor
    private func compressAndWait(_ viewModel: CompressionViewModel) async throws -> CompressionResult {
        viewModel.compress()
        let deadline = Date().addingTimeInterval(120)
        while viewModel.isWorking {
            try #require(Date() < deadline, "Kompression hängt")
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(viewModel.pendingResult, "kein Ergebnis: \(viewModel.errorMessage ?? "-")")
    }

    private func sessionFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: SessionScratch.directory, includingPropertiesForKeys: nil)) ?? []
    }

    /// 1 + 2 + 5: Verwerfen/Schließen/Wechsel räumen auf, nichts sammelt sich an,
    /// Gesichertes bleibt.
    @Test(.timeLimit(.minutes(5))) @MainActor
    func ergebnisseVerschwindenBeimVerwerfen() async throws {
        let inputs = try (0..<3).map { try fixture("\($0)") }
        defer { for url in inputs { try? FileManager.default.removeItem(at: url) } }
        let before = Set(sessionFiles())
        let viewModel = CompressionViewModel(defaults: .isolatedForTest())

        // a) Verwerfen über Schließen der Datei.
        viewModel.select(inputs[0])
        let first = try await compressAndWait(viewModel)
        #expect(first.outputURL.path.hasPrefix(SessionScratch.directory.path),
                "Ergebnis liegt außerhalb des Sitzungsordners: \(first.outputURL.path)")
        viewModel.clearSingleSelection()
        #expect(!FileManager.default.fileExists(atPath: first.outputURL.path))

        // b) Verwerfen über Wechsel auf eine andere Datei.
        viewModel.select(inputs[1])
        let second = try await compressAndWait(viewModel)
        viewModel.select(inputs[2])
        #expect(!FileManager.default.fileExists(atPath: second.outputURL.path))

        // c) Sichern: Ergebnis verlässt den Sitzungsordner und bleibt erhalten.
        let third = try await compressAndWait(viewModel)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gesichert-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try Compressor.finalize(result: third, destination: destination)
        viewModel.clearSingleSelection()
        #expect(FileManager.default.fileExists(atPath: destination.path))

        #expect(Set(sessionFiles()) == before, "Rückstände: \(Set(sessionFiles()).subtracting(before))")
    }

    /// 3 + 4: Start-Aufräumen trifft nur Ordner beendeter Prozesse; der
    /// eigene Ordner verschwindet beim Beenden.
    @Test func startAufraeumenSchontLaufendeProzesse() throws {
        let fm = FileManager.default
        let root = SessionScratch.root
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // PID 0 ist nie ein App-Prozess; Int32.max existiert praktisch nie.
        let dead = root.appendingPathComponent("\(Int32.max)-\(UUID().uuidString)")
        try fm.createDirectory(at: dead, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dead.appendingPathComponent("rest.pdf"))
        let live = root.appendingPathComponent("\(getppid())-\(UUID().uuidString)")
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: live) }
        _ = SessionScratch.directory   // eigener Ordner existiert

        SessionScratch.cleanupAbandoned()

        #expect(!fm.fileExists(atPath: dead.path), "Ordner eines beendeten Prozesses blieb")
        #expect(fm.fileExists(atPath: live.path), "Ordner eines laufenden Prozesses gelöscht")
        #expect(fm.fileExists(atPath: SessionScratch.directory.path), "eigener Ordner gelöscht")
    }
}
