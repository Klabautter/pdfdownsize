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
            reason = .unsavedResult
            onCancel = nil
            pending = action
        } else {
            action()
        }
    }

    /// Rückfrage vor dem Beenden/Schließen. Die Antwort geht an `reply`.
    func confirmQuit(_ work: PendingWork, reply: @escaping (Bool) -> Void) {
        reason = .quit(running: work.running, unsaved: work.unsavedResult)
        onCancel = { reply(false) }
        pending = { reply(true) }
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
    }
}
