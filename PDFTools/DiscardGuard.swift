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

    func run(ifUnsaved unsaved: Bool, _ action: @escaping () -> Void) {
        if unsaved {
            pending = action
        } else {
            action()
        }
    }

    func confirm() {
        let action = pending
        pending = nil
        action?()
    }

    func cancel() {
        pending = nil
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
            "Nicht gesichertes Ergebnis verwerfen?",
            isPresented: Binding(get: { discardGuard.pending != nil },
                                 set: { if !$0 { discardGuard.cancel() } }),
            titleVisibility: .visible
        ) {
            Button("Verwerfen", role: .destructive) { discardGuard.confirm() }
            Button("Abbrechen", role: .cancel) { discardGuard.cancel() }
        } message: {
            Text("Das Ergebnis wurde noch nicht gesichert und geht dabei verloren.")
        }
    }
}
