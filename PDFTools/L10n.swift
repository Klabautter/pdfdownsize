import Foundation

/// Mengenangaben mit Ein- und Mehrzahl. Die Formen stehen im String-Katalog
/// (`Localizable.xcstrings`), damit Deutsch und Englisch je ihre eigene
/// Mehrzahlregel bekommen.
enum Counted {
    static func pages(_ count: Int) -> String { String(localized: "\(count) Seiten") }
    static func images(_ count: Int) -> String { String(localized: "\(count) Bilder") }
}
