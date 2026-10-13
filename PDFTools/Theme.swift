import SwiftUI
import AppKit

/// Gestaltungsgrundlagen – bewusst nah am System: SF Pro in den
/// semantischen Textstilen, Systemakzentfarbe, Liquid Glass für alles, was
/// über dem Dokument schwebt. Eigene Werte gibt es nur, wo das System
/// keinen passenden Stil kennt.
enum Theme {
    /// Fläche hinter Dokumenten (wie in Vorschau).
    /// Dokumentfläche = Fensterhintergrund (Sichtabnahme 2026-10-12: die
    /// abgesetzte graue Fläche wirkte als „Schleier" hinter dem Blatt).
    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// „Gespart" – die Systemfarbe für Erfolg.
    static let savings = Color(nsColor: .systemGreen)

    /// Einheitliche Radien: Glaskarten und darin liegende Elemente sind
    /// konzentrisch (innen = außen − Innenabstand).
    static let panelRadius: CGFloat = 22
    static let panelPadding: CGFloat = 18
    static let innerRadius: CGFloat = panelRadius - 8

    /// Große Kennzahl (Größe, Ersparnis, Wörter): der semantische Stil
    /// skaliert mit der Systemeinstellung „Textgröße" (Befund S17) und
    /// bleibt SF Pro Display; feste Ziffernbreite gegen Zappeln.
    static let figure = Font.largeTitle.weight(.semibold).monospacedDigit()
}

extension View {
    /// Schwebende Glaskarte im Stil der macOS-26-Inspektoren.
    func glassPanel() -> some View {
        self
            .padding(Theme.panelPadding)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.panelRadius))
    }
}
