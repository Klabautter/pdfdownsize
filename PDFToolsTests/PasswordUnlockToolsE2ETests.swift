import Testing
import Foundation
import PDFKit
import AppKit
@testable import PDFTools

/// Masterplan B2 für OCR, Konvertieren und Organisieren.
///
/// Befund: Nur Komprimieren konnte gesperrte PDFs entsperren; OCR,
/// Konvertieren und Organisieren zeigten bloß „passwortgeschützt“.
///
/// Fehlermöglichkeiten: (1) falsches Passwort öffnet; (2) das Ergebnis ist
/// UNverschlüsselt, obwohl es eine PDF bleibt (OCR, Organisieren mit einer
/// Quelle); (3) die Arbeitskopie bleibt nach dem Schließen liegen.
@MainActor
@Suite(.serialized) struct PasswordUnlockToolsE2ETests {

    static func within(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        await PasswordUnlockE2ETests.within(seconds, condition)
    }

    @Test(.timeLimit(.minutes(5))) func ocrEntsperrtErkenntUndSichertGeschuetzt() async throws {
        let url = try PasswordUnlockE2ETests.lockedLetter()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = OCRViewModel()
        vm.accept([url])
        #expect(await Self.within(5) { vm.stage == .rejected(.locked) })
        vm.unlock(password: "falsch")
        #expect(await Self.within(5) { vm.passwordError != nil })
        #expect(vm.stage == .rejected(.locked))

        vm.unlock(password: PasswordUnlockE2ETests.password)
        #expect(await Self.within(10) { vm.stage == .ready && vm.unlocked != nil })
        let copy = try #require(vm.unlocked?.workingCopy)
        #expect(await Self.within(120) { vm.survey != nil })
        vm.runOCR()
        #expect(await Self.within(240) { vm.stage == .done || vm.errorMessage != nil }, "\(vm.errorMessage ?? "")")
        #expect(vm.canSaveSearchablePDF)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("b2-ocr-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: dest) }
        try vm.saveOutcome(to: dest)
        #expect(DocumentProbe.inspect(dest) == .locked, "Ergebnis ist nicht mehr geschützt")
        let pdf = try #require(PDFDocument(url: dest))
        #expect(pdf.unlock(withPassword: PasswordUnlockE2ETests.password))
        #expect((pdf.page(at: 0)?.string ?? "").isEmpty == false, "keine Textebene")

        vm.reset()
        #expect(!FileManager.default.fileExists(atPath: copy.path), "Arbeitskopie blieb liegen")
    }

    @Test func konvertierenEntsperrtUndExportiertBilder() async throws {
        let url = try PasswordUnlockE2ETests.lockedLetter()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = ConversionViewModel()
        vm.accept([url])
        #expect(await Self.within(5) { vm.stage == .rejected(.locked) })
        vm.unlock(password: "falsch")
        #expect(await Self.within(5) { vm.passwordError != nil })
        vm.unlock(password: PasswordUnlockE2ETests.password)
        #expect(await Self.within(10) { vm.stage == .ready })
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("b2-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        vm.exportPdfToImages(to: parent)
        #expect(await Self.within(60) { vm.resultFolder != nil || vm.errorMessage != nil }, "\(vm.errorMessage ?? "")")
        let folder = try #require(vm.resultFolder)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 1, "\(files)")
    }

    @Test func organisierenFragtNachDemPasswortUndBehaeltDenSchutz() async throws {
        let url = try PasswordUnlockE2ETests.lockedLetter()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = MergeViewModel()
        vm.attachUndoManager(UndoManager())
        vm.importDocuments([url])
        #expect(await Self.within(5) { vm.lockedPending == [url] }, "keine Passwortfrage")
        #expect(vm.project.pages.isEmpty)
        vm.unlockPending(password: "falsch")
        #expect(await Self.within(5) { vm.passwordError != nil })
        vm.unlockPending(password: PasswordUnlockE2ETests.password)
        #expect(await Self.within(10) { vm.project.pages.count == 1 })
        #expect(vm.lockedPending.isEmpty)
        #expect(vm.project.documents.first?.fileName == url.lastPathComponent)

        // Eine Quelle: Ergebnis bleibt mit demselben Passwort geschützt.
        // (N10: über den echten Weg – der Kontext hängt am Ergebnis.)
        vm.mergeAndPrepare()
        #expect(await Self.within(30) { vm.outcome != nil || vm.errorMessage != nil })
        let outcome = try #require(vm.outcome, "\(vm.errorMessage ?? "")")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("b2-org-dest-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: dest) }
        #expect(throws: SourceOverwriteError.self) { try vm.saveOutcome(outcome, to: url) }
        try vm.saveOutcome(outcome, to: dest)
        #expect(DocumentProbe.inspect(dest) == .locked)
        #expect(DocumentProbe.inspect(dest, password: PasswordUnlockE2ETests.password) == .ok(pageCount: 1))

        // Mehrere Quellen: der Hinweis nennt die Verschlüsselung.
        let plain = try PDFFixtures.vectorTextPDF(lines: 2)
        defer { try? FileManager.default.removeItem(at: plain) }
        let losses = MergeLossSummary.losses(for: vm.project.documents.map(\.url) + [plain],
                                             unlocked: vm.unlockedOriginalNames)
        #expect(losses.contains { $0.feature == .encryption && $0.files == [url.lastPathComponent] })
    }

    // MARK: Masterplan N10 – Passwortschutz in Organisieren

    /// Drei Seiten, mit Benutzerpasswort (AES-256) verschlüsselt.
    static func lockedThreePages() throws -> URL {
        let doc = PDFFixtures.document(pages: (1...3).map { PDFFixtures.textPage("N10-SEITE-\($0)") })
        let plain = try PDFFixtures.write(doc, name: "n10-plain")
        defer { try? FileManager.default.removeItem(at: plain) }
        let locked = FileManager.default.temporaryDirectory
            .appendingPathComponent("n10-locked-\(UUID().uuidString).pdf")
        let process = Process()
        process.executableURL = Compressor.bundledQPDFURL()
        process.arguments = ["--encrypt", "--user-password=\(PasswordUnlockE2ETests.password)",
                             "--owner-password=besitzer", "--bits=256", "--", plain.path, locked.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return locked
    }

    static func unlockedOrganizer(_ url: URL) async throws -> MergeViewModel {
        let vm = MergeViewModel()
        vm.attachUndoManager(UndoManager())
        vm.importDocuments([url])
        #expect(await within(5) { vm.lockedPending == [url] })
        vm.unlockPending(password: PasswordUnlockE2ETests.password)
        #expect(await within(10) { vm.project.pages.count == 3 })
        try #require(vm.project.pages.count == 3)
        return vm
    }

    static func isLockedWithTestPassword(_ url: URL, pages: Int) -> Bool {
        DocumentProbe.inspect(url) == .locked
            && DocumentProbe.inspect(url, password: PasswordUnlockE2ETests.password) == .ok(pageCount: pages)
    }

    /// Aufteilen einer entsperrten Quelle: Jeder Teil ist mit demselben
    /// Passwort verschlüsselt. Vorher schrieb `writeChunks` Klartext.
    @Test func aufteilenBehaeltDenSchutz() async throws {
        let url = try Self.lockedThreePages()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = try await Self.unlockedOrganizer(url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("n10-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pages = vm.project.pages
        let written = try await vm.writeChunks([[pages[0]], [pages[1], pages[2]]], to: folder, baseName: "teil")
        #expect(written.count == 2)
        #expect(Self.isLockedWithTestPassword(written[0], pages: 1), "Teil 1 ist Klartext")
        #expect(Self.isLockedWithTestPassword(written[1], pages: 2), "Teil 2 ist Klartext")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    }

    /// Übergabe an Komprimieren: geschützt hinüber, Komprimieren entsperrt
    /// selbst, und das Ergebnis ist wieder geschützt.
    @Test(.timeLimit(.minutes(3))) func uebergabeAnKomprimierenBehaeltDenSchutz() async throws {
        let url = try Self.lockedThreePages()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = try await Self.unlockedOrganizer(url)
        vm.selectAll()
        vm.extractSelectedPages()
        #expect(await Self.within(30) { vm.outcome != nil || vm.errorMessage != nil })
        let outcome = try #require(vm.outcome, "\(vm.errorMessage ?? "")")
        let handoff = try #require(vm.handOffOutcome(outcome))
        #expect(handoff.password == PasswordUnlockE2ETests.password)
        #expect(Self.isLockedWithTestPassword(handoff.url, pages: 3), "Übergabe als Klartext")

        let compress = CompressionViewModel(defaults: .isolatedForTest())
        compress.select(handoff.url, password: handoff.password)
        #expect(await Self.within(15) { compress.unlocked != nil }, "Komprimieren hat nicht selbst entsperrt")
        compress.compress()
        #expect(await Self.within(120) { compress.pendingResult != nil || compress.errorMessage != nil })
        let result = try #require(compress.pendingResult, "\(compress.errorMessage ?? "")")
        defer { compress.discardPending() }
        #expect(DocumentProbe.inspect(result.outputURL) == .locked, "Komprimiertes Ergebnis ist Klartext")
    }

    /// Alle Zwischenstände liegen im Sitzungsordner (der beim Beenden
    /// verschwindet), nicht lose im Temp-Stamm. Eine Auswahl aus der
    /// geschützten Quelle eines Mehr-Quellen-Projekts bleibt geschützt.
    @Test func zwischenstaendeImSitzungsordnerUndKontextAmErgebnis() async throws {
        let url = try Self.lockedThreePages()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = try await Self.unlockedOrganizer(url)
        let plain = try PDFFixtures.vectorTextPDF(lines: 2)
        defer { try? FileManager.default.removeItem(at: plain) }
        vm.importDocuments([plain])
        #expect(await Self.within(10) { vm.project.pages.count == 4 })
        let session = SessionScratch.directory.standardizedFileURL.path
        for doc in vm.project.documents where doc.url != plain {
            #expect(doc.url.standardizedFileURL.path.hasPrefix(session), "Arbeitskopie außerhalb: \(doc.url.path)")
        }
        // Nur Seiten der geschützten Quelle auswählen.
        vm.selectAll()
        let lockedPages = vm.project.pages.filter { $0.sourceURL != plain }
        #expect(lockedPages.count == 3)
        #expect(vm.encryption(for: lockedPages) != nil)
        #expect(vm.encryption(for: vm.project.pages) == nil, "Mehr-Quellen-Ergebnis kann nicht geschützt sein")

        vm.mergeAndPrepare()
        #expect(await Self.within(30) { vm.outcome != nil || vm.errorMessage != nil })
        let merged = try #require(vm.outcome)
        #expect(merged.url.standardizedFileURL.path.hasPrefix(session), "Ergebnis außerhalb: \(merged.url.path)")
        vm.discardOutcome()
        #expect(!FileManager.default.fileExists(atPath: merged.url.path))
    }

    /// N28 (Testlücke N10): Beenden lässt keinen Klartext zurück. Die
    /// entsperrte Arbeitskopie liegt im Sitzungsordner und ist Klartext; das
    /// Aufräumen, das die App an `willTerminate` hängt, entfernt den Ordner
    /// samt Inhalt. Geprüft mit eigenem Center und Ordner, damit parallel
    /// laufende Tests ihren Sitzungsordner behalten.
    @Test func beendenLaesstKeinenKlartextZurueck() async throws {
        let url = try Self.lockedThreePages()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = try await Self.unlockedOrganizer(url)
        let session = SessionScratch.directory.standardizedFileURL.path
        let workingCopy = try #require(vm.project.documents.first?.url)
        #expect(workingCopy.standardizedFileURL.path.hasPrefix(session), "Arbeitskopie außerhalb: \(workingCopy.path)")
        #expect(DocumentProbe.inspect(workingCopy) == .ok(pageCount: 3), "Arbeitskopie ist nicht entsperrt – Test prüft nichts")

        // Derselbe Aufbau wie der Sitzungsordner, mit der Klartext-Kopie darin.
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("n10-quit-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory.appendingPathComponent("compress-x"), withIntermediateDirectories: true)
        let plaintext = directory.appendingPathComponent("compress-x/unlocked.pdf")
        try fm.copyItem(at: workingCopy, to: plaintext)

        let center = NotificationCenter()
        let token = SessionScratch.removeOnTermination(center: center, directory: directory)
        defer { center.removeObserver(token) }
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(!fm.fileExists(atPath: plaintext.path), "Klartext überlebt das Beenden")
        #expect(!fm.fileExists(atPath: directory.path))
    }
}
