import Testing
import Foundation
import PDFKit
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
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("b2-org-\(UUID().uuidString).pdf")
        try await PageAssemblyService.assemble(pages: vm.project.pages, to: out) { _ in }
        let outcome = MergeViewModel.MergeOutcome(url: out, pageCount: 1, outputBytes: 1,
                                                  combinedInputBytes: 1, kind: .extracted)
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
}
