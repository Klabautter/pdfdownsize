import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan B4: Der Stapel verhält sich wie der Einzelweg.
///
/// Befund an 1.0.9: „Alle sichern“ schrieb ein schon gesichertes Ergebnis
/// erneut als `_2`; ein globaler Abbruch verwarf fertige Dateien; nach dem
/// Lauf gab es kein Wiederholen.
///
/// Fehlermöglichkeiten: (1) doppelte Dateien beim „Alle sichern“; (2) kaputte
/// Dateien laufen mit und zählen als Fehler; (3) Wiederholen ersetzt oder
/// verliert die übrigen Ergebnisse; (4) ein Moduswechsel nach dem Lauf lässt
/// alte Ergebnisse stehen.
@MainActor
@Suite(.serialized) struct BulkLikeSingleE2ETests {

    static func healthy(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let doc = PDFDocument()
        doc.insert(PDFFixtures.textPage(name), at: 0)
        #expect(doc.write(to: url))
        return url
    }

    static func workDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-b4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func waitIdle(_ vm: CompressionViewModel) async {
        for _ in 0..<6000 where vm.isWorking { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func sechsDateienZweiKaputtEinzelnUndAlleSichern() async throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var inputs = try (1...4).map { try Self.healthy("gut-\($0).pdf", in: dir) }
        let empty = dir.appendingPathComponent("leer.pdf"); try Data().write(to: empty)
        let text = dir.appendingPathComponent("text.pdf"); try Data("kein pdf".utf8).write(to: text)
        inputs += [empty, text]

        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.selectMany(inputs)
        for _ in 0..<100 where vm.bulkRejected.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let results = try await vm.runBulkCompression(vm.bulkInputs)
        #expect(results.count == 4)
        #expect(vm.bulkErrors.isEmpty)

        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let first = try #require(vm.bulkResultInputs.first)
        try vm.saveBulkResult(for: first, to: out.appendingPathComponent(
            Compressor.suggestedOutputName(for: first, mode: vm.mode)))
        let saved = try vm.saveAllBulk(to: out)
        #expect(saved.count == 3, "Alle sichern schrieb \(saved.count) statt der 3 fehlenden")

        let files = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(files.count == 4, "\(files)")
        #expect(!files.contains { $0.contains("_2") }, "\(files)")
        #expect(vm.allBulkResultsSaved)
        vm.clearBulk()
    }

    @Test func wiederholenBehaeltDieUebrigenErgebnisse() async throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = try (1...3).map { try Self.healthy("w-\($0).pdf", in: dir) }
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.selectMany(inputs)
        for _ in 0..<100 where vm.bulkVerdicts.count < 3 { try await Task.sleep(for: .milliseconds(10)) }

        // Die mittlere Datei ist während des Laufs nicht da (z. B. Netzlaufwerk
        // kurz weg): ein echter Fehlschlag. Danach ist sie wieder da.
        let target = vm.bulkInputs[1]
        let parked = dir.appendingPathComponent("geparkt.pdf")
        try FileManager.default.moveItem(at: target, to: parked)
        _ = try await vm.runBulkCompression(vm.bulkInputs)
        #expect(vm.bulkSuccesses.count == 2)
        #expect(vm.bulkErrors[target] != nil)
        try FileManager.default.moveItem(at: parked, to: target)

        vm.retryBulkFile(at: 1)
        await Self.waitIdle(vm)
        #expect(vm.bulkErrors.isEmpty)
        #expect(vm.bulkSuccesses.map(\.input) == vm.bulkInputs, "Reihenfolge oder Vollständigkeit verletzt")
        vm.clearBulk()
    }

    @Test func moduswechselNachDemLaufStartetNeu() async throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = try (1...2).map { try Self.healthy("m-\($0).pdf", in: dir) }
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.selectMany(inputs)
        _ = try await vm.runBulkCompression(vm.bulkInputs)
        let before = vm.bulkSuccesses.map(\.result.outputURL)
        vm.changeBulkMode(to: .quality)
        await Self.waitIdle(vm)
        #expect(vm.mode == .quality)
        #expect(vm.bulkSuccesses.count == 2)
        #expect(Set(vm.bulkSuccesses.map(\.result.outputURL)).isDisjoint(with: before),
                "Ergebnisse des alten Modus stehen noch")
        vm.clearBulk()
    }

    /// N14 (B4): Wechsel zu „Eigene“ nach dem Lauf startet nicht mit
    /// Startwerten, sondern wartet auf den Knopf; danach geänderte
    /// Einstellungen bieten den Knopf erneut an.
    @Test func eigeneImStapelStartetErstAufWunsch() async throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = try (1...2).map { try Self.healthy("e-\($0).pdf", in: dir) }
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.selectMany(inputs)
        _ = try await vm.runBulkCompression(vm.bulkInputs)
        #expect(vm.bulkSuccesses.count == 2)
        vm.changeBulkMode(to: .custom)
        #expect(!vm.isWorking, "„Eigene“ startete sofort")
        #expect(vm.bulkSuccesses.isEmpty, "Ergebnisse des alten Modus stehen noch")
        #expect(vm.bulkNeedsCustomStart)
        vm.startBulkWithCurrentSettings()
        await Self.waitIdle(vm)
        #expect(vm.bulkSuccesses.count == 2)
        #expect(!vm.bulkNeedsCustomStart)
        vm.customQuality = vm.customQuality > 0.5 ? 0.4 : 0.8
        #expect(vm.bulkNeedsCustomStart, "Geänderte Einstellungen ohne Neustart-Knopf")
        vm.clearBulk()
    }

    /// N14 (B2): Eine gesperrte Datei im Stapel lässt sich entsperren; das
    /// Ergebnis ist wieder mit demselben Passwort geschützt. Ein falsches
    /// Passwort heißt so.
    @Test func gesperrteDateiImStapelEntsperren() async throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let healthy = try Self.healthy("offen.pdf", in: dir)
        let locked = try PasswordUnlockE2ETests.lockedLetter()
        defer { try? FileManager.default.removeItem(at: locked) }
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.selectMany([healthy, locked])
        _ = try await vm.runBulkCompression(vm.bulkInputs)
        #expect(vm.bulkVerdicts[locked] == .locked)
        #expect(vm.bulkSuccesses.count == 1)

        let wrong = await vm.unlockBulkFile(locked, password: "falsch")
        #expect(wrong == String(localized: "Das Passwort stimmt nicht."))
        #expect(await vm.unlockBulkFile(locked, password: PasswordUnlockE2ETests.password) == nil)
        #expect(vm.bulkVerdicts[locked]?.isOK == true)

        _ = try await vm.runBulkCompression(vm.bulkInputs)
        let result = try #require(vm.bulkResult(for: locked), "\(vm.bulkErrors[locked] ?? "")")
        #expect(DocumentProbe.inspect(result.outputURL) == .locked, "Ergebnis ist Klartext")
        #expect(DocumentProbe.inspect(result.outputURL, password: PasswordUnlockE2ETests.password).isOK)
        let workingCopy = try #require(vm.bulkUnlocked[locked]?.workingCopy)
        vm.clearBulk()
        #expect(!FileManager.default.fileExists(atPath: workingCopy.path), "Arbeitskopie blieb liegen")
    }
}
