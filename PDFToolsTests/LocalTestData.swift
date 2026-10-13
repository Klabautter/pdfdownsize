import Foundation
import Testing

/// Tests, die Dateien brauchen, die nicht im Repository liegen (Korpus unter
/// `tmp/pdfs/`, interne Statusdokumente), melden sich als ÜBERSPRUNGEN, wenn
/// diese Dateien fehlen – statt in einem frischen Klon fehlzuschlagen.
/// Liegen die Dateien vor, läuft der Test unverändert und so streng wie zuvor.
enum LocalTestData {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func missing(_ relativePaths: [String]) -> [String] {
        relativePaths.filter {
            !FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent($0).path)
        }
    }
}

extension Trait where Self == ConditionTrait {
    /// Pfade relativ zur Projektwurzel; fehlt einer, wird der Test übersprungen.
    static func needsLocalFiles(_ relativePaths: String...) -> Self {
        let missing = LocalTestData.missing(relativePaths)
        return .enabled(if: missing.isEmpty,
                        Comment(rawValue: "Lokale Testdaten fehlen: " + missing.joined(separator: ", ")))
    }
}
