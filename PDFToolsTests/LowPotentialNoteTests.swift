import Testing
import Foundation
@testable import PDFTools

/// Masterplan H4: Ehrliche Auskunft, wo wenig geht.
///
/// Vorher stand bei Text- und bereits optimalen Dateien nur eine kleine Zahl
/// („≈ 3 % kleiner“) ohne Grund. Jetzt nennt das Pult den Grund und verweist
/// auf „Klein“.
///
/// Fehlermöglichkeiten: (1) kein Hinweis bei reinem Text; (2) ein Hinweis
/// bei einem Foto-Dokument, wo viel geht; (3) der Verweis auf „Klein“
/// erscheint, obwohl „Klein“ schon gewählt ist.
@MainActor
@Suite(.serialized) struct LowPotentialNoteTests {

    static func estimate(_ url: URL, mode: CompressionMode) async throws -> CompressionEstimate {
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.mode = mode
        vm.select(url)
        #expect(await PasswordUnlockE2ETests.within(30) { vm.estimate != nil })
        return try #require(vm.estimate)
    }

    @Test func textDateiNenntDenGrund() async throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let e = try await Self.estimate(url, mode: .smart)
        let note = try #require(CompressionViewModel.lowPotentialNote(e, mode: .smart), "kein Hinweis")
        #expect(note.contains("Klein"))
        #expect(!(CompressionViewModel.lowPotentialNote(e, mode: .small) ?? "").contains("Klein"))
    }

    @Test func fotoDokumentOhneHinweis() async throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1800, name: "h4-photo")
        defer { try? FileManager.default.removeItem(at: url) }
        let e = try await Self.estimate(url, mode: .smart)
        #expect(CompressionViewModel.lowPotentialNote(e, mode: .smart) == nil, "\(e.savingsRatio) \(e.imageByteShare)")
    }
}
