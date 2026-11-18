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
    /// „Gespart" – die Systemfarbe für Erfolg (Flächen, Balken).
    static let savings = Color(nsColor: .systemGreen)
    /// Masterplan F3: Grün und Orange als TEXT. Die Systemfarben erreichen
    /// auf hellem Grund nur rund 2:1; diese Asset-Farben ≥ 4,5:1 auf Weiß
    /// und Fenstergrau (hell #177A33 / #A64D00, dunkel #32D74B / #FF9F0A).
    static let savingsText = Color("SavingsText")
    static let warningText = Color("WarningText")

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
    /// Schwebende Glaskarte im Stil der macOS-26-Inspektoren. Masterplan F3:
    /// Mit „Transparenz reduzieren“ eine deckende Fläche statt Glas.
    func glassPanel() -> some View {
        modifier(GlassPanelModifier())
    }

    /// Masterplan F3: Animation nur ohne „Bewegung reduzieren“.
    func motionSafeAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(MotionSafeAnimation(animation: animation, value: value))
    }
}

private struct GlassPanelModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let padded = content.padding(Theme.panelPadding)
        if reduceTransparency {
            padded.background(Color(nsColor: .controlBackgroundColor),
                              in: .rect(cornerRadius: Theme.panelRadius))
        } else {
            padded.glassEffect(.regular, in: .rect(cornerRadius: Theme.panelRadius))
        }
    }
}

private struct MotionSafeAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
