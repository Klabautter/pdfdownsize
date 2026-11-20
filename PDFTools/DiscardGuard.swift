import SwiftUI
import Combine

/// Rückfrage, bevor ein noch nicht gesichertes Ergebnis verloren geht
/// (Sichtabnahme 2026-10-12, M2): Eine andere Datei öffnen, ablegen oder das
/// Dokument schließen verwarf das Ergebnis vorher kommentarlos.
///
/// Eine Instanz je Fenster (RootView). Aufrufer geben an, ob gerade ein
/// ungesichertes Ergebnis vorliegt; ohne läuft die Aktion sofort. Die
/// ausdrücklichen Wege „Verwerfen" und „Mit anderem Modus versuchen" fragen
/// nicht – dort ist das Verwerfen die gewählte Aktion.
@MainActor
final class DiscardGuard: ObservableObject {
    /// Wartet auf die Antwort der Rückfrage.
    @Published private(set) var pending: (() -> Void)?
    /// Worum es in der Rückfrage geht (Masterplan B3: Beenden kennt auch
    /// den laufenden Lauf).
    @Published private(set) var reason: Reason = .unsavedResult
    private var onCancel: (() -> Void)?

    enum Reason: Equatable {
        case unsavedResult
        /// Beenden oder Fenster schließen; `running` = ein Lauf ist aktiv.
        case quit(running: Bool, unsaved: Bool)
    }

    func run(ifUnsaved unsaved: Bool, _ action: @escaping () -> Void) {
        if unsaved {
            // Masterplan N7: Eine offene Beenden-Frage wird sonst überschrieben,
            // und `reply(toApplicationShouldTerminate:)` kommt nie.
            answerOpenQuestion()
            reason = .unsavedResult
            pending = action
        } else {
            action()
        }
    }

    /// N14 (B1): Hinweis, wenn eine neue Datei sich nicht öffnen lässt und
    /// das ungesicherte Ergebnis deshalb bleibt.
    @Published var refusal: String?

    /// N14 (B1): Erst prüfen, dann fragen. Liegt ein ungesichertes Ergebnis
    /// vor, werden die neuen Dateien zuerst geprüft (abseits des Main
    /// Threads). Lässt sich keine öffnen, bleibt das Ergebnis, und es gibt
    /// einen Hinweis statt der Verwerfen-Frage. Vorher verwarf man ein
    /// Ergebnis für eine Datei, die sich danach als unlesbar herausstellte.
    /// Passwortgeschützte Dateien zählen als öffenbar (Entsperren).
    func runAfterProbe(_ urls: [URL], ifUnsaved unsaved: Bool,
                       probe: @escaping @Sendable (URL) -> DocumentProbe.Verdict = { DocumentProbe.inspect($0) },
                       _ action: @escaping () -> Void) {
        guard unsaved, !urls.isEmpty else { action(); return }
        Task {
            let verdicts = await Task.detached(priority: .userInitiated) { urls.map(probe) }.value
            if verdicts.contains(where: { $0.isOK || $0 == .locked }) {
                run(ifUnsaved: true, action)
            } else if verdicts.count == 1, let only = verdicts.first {
                refusal = String(localized: "\(only.title) Das nicht gesicherte Ergebnis bleibt erhalten.")
            } else {
                refusal = String(localized: "Keine der Dateien lässt sich öffnen. Das nicht gesicherte Ergebnis bleibt erhalten.")
            }
        }
    }

    /// Rückfrage vor dem Beenden/Schließen. Die Antwort geht an `reply`.
    func confirmQuit(_ work: PendingWork, reply: @escaping (Bool) -> Void) {
        answerOpenQuestion()
        reason = .quit(running: work.running, unsaved: work.unsavedResult)
        onCancel = { reply(false) }
        pending = { reply(true) }
    }

    /// Beantwortet eine noch offene Beenden-Frage mit „nicht beenden“, bevor
    /// eine neue Rückfrage sie ersetzt. Eine offene Verwerfen-Frage entfällt
    /// ohne Aktion – das ist dasselbe wie „Abbrechen“.
    private func answerOpenQuestion() {
        let cancelled = onCancel
        onCancel = nil
        pending = nil
        cancelled?()
    }

    func confirm() {
        let action = pending
        pending = nil
        onCancel = nil
        action?()
    }

    func cancel() {
        let cancelled = onCancel
        pending = nil
        onCancel = nil
        cancelled?()
    }

    var title: String {
        switch reason {
        case .unsavedResult:
            return String(localized: "Nicht gesichertes Ergebnis verwerfen?")
        case .quit(let running, _):
            return running
                ? String(localized: "Laufende Verarbeitung abbrechen und beenden?")
                : String(localized: "Nicht gesichertes Ergebnis verwerfen und beenden?")
        }
    }

    var message: String {
        switch reason {
        case .unsavedResult:
            return String(localized: "Das Ergebnis wurde noch nicht gesichert und geht dabei verloren.")
        case .quit(let running, let unsaved):
            if running && unsaved {
                return String(localized: "Ein Lauf ist noch nicht fertig, und ein Ergebnis ist nicht gesichert. Beides geht verloren.")
            }
            return running
                ? String(localized: "Ein Lauf ist noch nicht fertig. Das Original bleibt unverändert.")
                : String(localized: "Das Ergebnis wurde noch nicht gesichert und geht dabei verloren.")
        }
    }

    var confirmLabel: String {
        if case .quit = reason { return String(localized: "Beenden") }
        return String(localized: "Verwerfen")
    }
}

extension View {
    /// Die Rückfrage selbst – einmal am Fenster.
    func discardConfirmation(_ discardGuard: DiscardGuard) -> some View {
        modifier(DiscardConfirmation(discardGuard: discardGuard))
    }
}

private struct DiscardConfirmation: ViewModifier {
    @ObservedObject var discardGuard: DiscardGuard

    func body(content: Content) -> some View {
        content.confirmationDialog(
            discardGuard.title,
            isPresented: Binding(get: { discardGuard.pending != nil },
                                 set: { if !$0 { discardGuard.cancel() } }),
            titleVisibility: .visible
        ) {
            Button(discardGuard.confirmLabel, role: .destructive) { discardGuard.confirm() }
            Button("Abbrechen", role: .cancel) { discardGuard.cancel() }
        } message: {
            Text(discardGuard.message)
        }
        .alert("Datei nicht geöffnet", isPresented: Binding(
            get: { discardGuard.refusal != nil },
            set: { if !$0 { discardGuard.refusal = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(discardGuard.refusal ?? "")
        }
    }
}
