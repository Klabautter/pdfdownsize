import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan B2: Passwortgeschützte PDFs entsperren.
///
/// Vorher gingen PDFs mit Benutzerpasswort nie: kein Passwortfeld für die
/// Engine, stattdessen die rohe Meldung.
///
/// Fehlermöglichkeiten: (1) falsches Passwort öffnet trotzdem oder hängt;
/// (2) richtiges Passwort, aber der Lauf arbeitet auf dem verschlüsselten
/// Original und scheitert; (3) die Ausgabe ist UNverschlüsselt – der Schutz
/// ginge beim Komprimieren verloren; (4) die Ausgabe trägt ein anderes
/// Passwort; (5) die Größe wird gegen die Arbeitskopie statt gegen das
/// Original gerechnet.
@MainActor
@Suite(.serialized) struct PasswordUnlockE2ETests {

    static let password = "geheim-123"

    static func lockedLetter() throws -> URL {
        let plain = try ColorInkSurvivesCompressionE2ETests.signedLetterPDF()
        defer { try? FileManager.default.removeItem(at: plain) }
        let locked = FileManager.default.temporaryDirectory
            .appendingPathComponent("locked-\(UUID().uuidString).pdf")
        let process = Process()
        process.executableURL = Compressor.bundledQPDFURL()
        process.arguments = ["--encrypt", "--user-password=\(password)", "--owner-password=besitzer",
                             "--bits=256", "--", plain.path, locked.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return locked
    }

    static func within(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func falschesPasswortBleibtGesperrt() async throws {
        let url = try Self.lockedLetter()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.select(url)
        #expect(await Self.within(1) { vm.rejection == .locked })
        vm.unlock(password: "falsch")
        #expect(await Self.within(5) { vm.passwordError != nil }, "Kein Hinweis nach falschem Passwort")
        #expect(vm.rejection == .locked)
        #expect(!vm.canCompress)
        #expect(vm.unlocked == nil)
    }

    @Test func richtigesPasswortKomprimiertUndBehaeltDenSchutz() async throws {
        let url = try Self.lockedLetter()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.mode = .small
        vm.select(url)
        #expect(await Self.within(1) { vm.rejection == .locked })
        vm.unlock(password: Self.password)
        #expect(await Self.within(10) { vm.documentStatus == .ready(pageCount: 1) },
                "Nicht entsperrt: \(vm.documentStatus), \(vm.passwordError ?? "")")
        #expect(vm.canCompress)

        vm.compress()
        #expect(await Self.within(180) { vm.pendingResult != nil || vm.errorMessage != nil })
        let result = try #require(vm.pendingResult, "\(vm.errorMessage ?? "")")
        defer { vm.discardPending() }

        #expect(result.inputBytes == Compressor.fileSize(of: url), "Größe nicht gegen das Original gerechnet")
        #expect(result.outputBytes < result.inputBytes)
        // Ohne Passwort gesperrt, mit demselben Passwort offen.
        #expect(DocumentProbe.inspect(result.outputURL) == .locked, "Ausgabe ist nicht mehr geschützt")
        #expect(DocumentProbe.inspect(result.outputURL, password: Self.password) == .ok(pageCount: 1))
        let pdf = try #require(PDFDocument(url: result.outputURL))
        #expect(pdf.isLocked && pdf.unlock(withPassword: Self.password))
    }

    /// Das Passwort gehört zur Datei: Eine andere Datei verwirft die Arbeitskopie.
    @Test func andereDateiVerwirftDieArbeitskopie() async throws {
        let url = try Self.lockedLetter()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.select(url)
        #expect(await Self.within(1) { vm.rejection == .locked })
        vm.unlock(password: Self.password)
        #expect(await Self.within(10) { vm.unlocked != nil })
        let copy = try #require(vm.unlocked?.workingCopy)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        vm.clearSingleSelection()
        #expect(vm.unlocked == nil)
        #expect(!FileManager.default.fileExists(atPath: copy.path), "Entschlüsselte Kopie blieb liegen")
    }
}
