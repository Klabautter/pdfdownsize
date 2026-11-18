import AppKit
import SwiftUI

/// Masterplan B3: ⌘W und der rote Knopf laufen über dieselbe Rückfrage wie ⌘Q.
///
/// Ohne Eingriff schließt das Fenster sofort – die ViewModels hängen an ihm,
/// ein ungesichertes Ergebnis wäre weg, bevor `applicationShouldTerminate`
/// überhaupt gefragt wird. SwiftUI belegt `window.delegate` selbst; der Proxy
/// beantwortet nur `windowShouldClose(_:)` und reicht alles andere an den
/// ursprünglichen Delegate weiter.
@MainActor
final class WindowCloseProxy: NSObject, NSWindowDelegate {
    /// Wird nur auf dem Main Thread gesetzt; die Weiterleitung liest es dort.
    nonisolated(unsafe) weak var original: NSWindowDelegate?
    /// Liefert true, wenn sofort geschlossen werden darf; sonst übernimmt die
    /// Rückfrage und schließt bei Zustimmung selbst.
    var shouldClose: ((NSWindow) -> Bool)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let shouldClose, !shouldClose(sender) { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

/// Hängt den Proxy an das Fenster, in dem die View liegt.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: (NSWindow) -> Bool

    @MainActor
    final class Coordinator {
        let proxy = WindowCloseProxy()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { attach(view, context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.proxy.shouldClose = shouldClose
        DispatchQueue.main.async { attach(view, context.coordinator) }
    }

    private func attach(_ view: NSView, _ coordinator: Coordinator) {
        guard let window = view.window else { return }
        let proxy = coordinator.proxy
        proxy.shouldClose = shouldClose
        if window.delegate !== proxy {
            proxy.original = window.delegate
            window.delegate = proxy
        }
    }
}
