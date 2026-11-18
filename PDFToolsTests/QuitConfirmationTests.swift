import Testing
import AppKit
@testable import PDFTools

/// Masterplan B3: ⌘Q verwarf ein ungesichertes Ergebnis und einen laufenden
/// Lauf ohne Rückfrage – es gab kein `applicationShouldTerminate`.
///
/// Fehlermöglichkeiten: (1) Beenden fragt nicht; (2) es fragt auch ohne
/// Grund und hält jedes Beenden auf; (3) „Abbrechen“ beendet trotzdem;
/// (4) nach „Beenden“ fragt das Schließen des letzten Fensters ein zweites Mal.
@MainActor
struct QuitConfirmationTests {

    @Test func ohneUngesichertesBeendetSofort() {
        let delegate = OpenFilesDelegate()
        delegate.pendingWork = { PendingWork() }
        var asked = false
        delegate.confirmQuit = { _, _ in asked = true }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(!asked)
    }

    @Test(arguments: [PendingWork(unsavedResult: true), PendingWork(running: true),
                      PendingWork(unsavedResult: true, running: true)])
    func mitArbeitWirdGefragt(_ work: PendingWork) {
        let delegate = OpenFilesDelegate()
        delegate.pendingWork = { work }
        var asked: PendingWork?
        delegate.confirmQuit = { w, _ in asked = w }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(asked == work)
    }

    @Test func dialogTexteUnterscheidenErgebnisUndLauf() {
        let guardian = DiscardGuard()
        var replies: [Bool] = []
        guardian.confirmQuit(PendingWork(running: true)) { replies.append($0) }
        #expect(guardian.title.contains("Laufende"))
        #expect(guardian.confirmLabel == String(localized: "Beenden"))
        guardian.cancel()
        #expect(replies == [false], "Abbrechen muss das Beenden ablehnen")

        guardian.confirmQuit(PendingWork(unsavedResult: true)) { replies.append($0) }
        #expect(guardian.message.contains("nicht gesichert"))
        guardian.confirm()
        #expect(replies == [false, true])
        #expect(guardian.pending == nil)
    }

    /// Die normale Verwerfen-Rückfrage bleibt, wie sie war.
    @Test func verwerfenRueckfrageUnveraendert() {
        let guardian = DiscardGuard()
        var ran = false
        guardian.run(ifUnsaved: true) { ran = true }
        #expect(guardian.confirmLabel == String(localized: "Verwerfen"))
        guardian.cancel()
        #expect(!ran)
        guardian.run(ifUnsaved: false) { ran = true }
        #expect(ran)
    }
}
