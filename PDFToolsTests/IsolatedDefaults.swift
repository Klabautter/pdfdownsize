import Foundation

/// Tests laufen in der App als Test-Host und teilen sich deren Defaults-
/// Domain. Ein ViewModel mit `UserDefaults.standard` schrieb deshalb
/// Testwerte (Graustufen an, 1234 px Kante) in die echten Custom-
/// Einstellungen des Entwicklers. Jeder Test bekommt eine frische,
/// leere Suite.
extension UserDefaults {
    static func isolatedForTest() -> UserDefaults {
        let name = "PDFToolsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
