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

    /// Masterplan N7: ⌘Q mit ungesichertem Ergebnis, dann eine PDF per Finder
    /// öffnen – die Beenden-Antwort ging verloren, die App hing in
    /// `terminateLater`. Erwartung: genau einmal „nicht beenden“.
    @Test func offeneBeendenFrageWirdBeimNeuenOeffnenBeantwortet() {
        let guardian = DiscardGuard()
        var replies: [Bool] = []
        guardian.confirmQuit(PendingWork(unsavedResult: true)) { replies.append($0) }
        var ran = false
        guardian.run(ifUnsaved: true) { ran = true }
        #expect(replies == [false])
        #expect(guardian.confirmLabel == String(localized: "Verwerfen"))
        guardian.confirm()
        #expect(ran)
        #expect(replies == [false], "die alte Antwort darf nicht ein zweites Mal kommen")
    }

    /// Zweites ⌘Q, während die erste Frage noch steht: die erste wird abgelehnt,
    /// die zweite gilt.
    @Test func zweiteBeendenFrageErsetztDieErste() {
        let guardian = DiscardGuard()
        var first: [Bool] = [], second: [Bool] = []
        guardian.confirmQuit(PendingWork(running: true)) { first.append($0) }
        guardian.confirmQuit(PendingWork(running: true)) { second.append($0) }
        #expect(first == [false])
        guardian.confirm()
        #expect(second == [true])
        #expect(first == [false])
    }

    /// N14 (B1): Erst prüfen, dann fragen. Eine unlesbare Datei kostet das
    /// ungesicherte Ergebnis nicht; eine lesbare (auch gesperrte) fragt wie
    /// bisher.
    @Test func unlesbareDateiFragtNichtUndVerwirftNichts() async {
        let guardian = DiscardGuard()
        let url = URL(fileURLWithPath: "/nicht/da.pdf")
        var ran = false
        guardian.runAfterProbe([url], ifUnsaved: true, probe: { _ in .unreadable }) { ran = true }
        let deadline = ContinuousClock.now + .seconds(5)
        while guardian.refusal == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(guardian.refusal != nil)
        #expect(guardian.pending == nil, "Verwerfen-Frage trotz unlesbarer Datei")
        #expect(!ran)

        guardian.refusal = nil
        guardian.runAfterProbe([url], ifUnsaved: true, probe: { _ in .locked }) { ran = true }
        while guardian.pending == nil, ContinuousClock.now < deadline + .seconds(5) { await Task.yield() }
        #expect(guardian.pending != nil, "Gesperrte Datei muss wie bisher fragen")
        guardian.confirm()
        #expect(ran)

        // Ohne ungesichertes Ergebnis: sofort, ohne Prüfung.
        var direct = false
        guardian.runAfterProbe([url], ifUnsaved: false, probe: { _ in .unreadable }) { direct = true }
        #expect(direct)
    }
}
