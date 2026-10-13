import Foundation

// MARK: - Masterplan §11.2 – Structured QA (V2-5)
//
// `PDFValidator.Report` war eine String-Sammlung („Seite 12 Textinhalt …") –
// für Menschen lesbar, für Maschinen unbrauchbar. Die QA-Rollback-Kette
// (§11.5) braucht aber maschinenlesbare Befunde: ART des Verstoßes, SCHWERE
// und die BETROFFENEN Seiten, um daraus implicierte Ressourcen und
// Rückstufungen herzuleiten.
//
// Das Finding ist bewusst ein eigener Datentyp NEBEN dem bestehenden
// String-Report: Die Texte bleiben unverändert sichtbar (additiv), die
// maschinelle Auswertung liest die strukturierte Seite.

/// Ein maschinenlesbarer QA-Befund. `pages` trägt PDF-Seitennummern,
/// 1-basiert – dieselbe Konvention wie der Berichtstext („Seite 12"); leer
/// heißt: Befund auf Dokumentebene (z. B. Seitenzahl, Struktur).
struct ValidationFinding: Codable, Sendable, Equatable {

    enum Kind: String, Codable, Sendable, CaseIterable {
        case structure
        case pageCount
        case geometry
        case text
        case annotation
        case link
        case form
        case outline
        case attachment
        case render
        case color
        case size
    }

    /// Schwere eines Befunds. Nur `error` und `fatal` dürfen einen
    /// Rollback (§11.5) auslösen; `info`/`warning` sind Meldungen.
    enum Severity: String, Codable, Sendable, Comparable {
        case info
        case warning
        case error
        case fatal

        private var rank: Int {
            switch self {
            case .info: return 0
            case .warning: return 1
            case .error: return 2
            case .fatal: return 3
            }
        }

        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }

        /// Löst dieser Schweregrad einen Re-Plan aus? (§11.5: nur Failures.)
        var triggersRollback: Bool {
            self == .error || self == .fatal
        }
    }

    let kind: Kind
    let severity: Severity
    let pages: [Int]
    let message: String
}
