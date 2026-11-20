import Foundation

/// Masterplan E2: Was beim Zusammenfügen MEHRERER Quellen nicht übernommen
/// wird. Der Neuaufbau kopiert Seiten, Formulare, Ziele und Lesezeichen; der
/// Katalog der Quellen (Tags, Anhänge, Ebenen, Skripte, Verschlüsselung)
/// bleibt zurück. Der Hinweis nennt nur, was die konkreten Quellen haben.
/// Bei einer Quelle geht nichts verloren – dort wird im Dokument umgebaut (E1).
enum MergeLossSummary {

    enum Feature: String, CaseIterable, Sendable {
        case tags, attachments, layers, scripts, encryption

        var label: String {
            switch self {
            case .tags: return String(localized: "Tags für Barrierefreiheit")
            case .attachments: return String(localized: "Anhänge")
            case .layers: return String(localized: "Ebenen")
            case .scripts: return String(localized: "Skripte")
            case .encryption: return String(localized: "Verschlüsselung")
            }
        }
    }

    struct Loss: Equatable, Sendable {
        let feature: Feature
        let files: [String]
    }

    /// Verluste je Merkmal, in fester Reihenfolge; leer bei weniger als zwei
    /// Quellen. Aus Bildern erzeugte Quellen haben keinen Katalog.
    /// `unlocked`: Arbeitskopien entsperrter Quellen → Name des Originals
    /// (Masterplan B2) – die Kopie ist unverschlüsselt, das Original nicht.
    nonisolated static func losses(for urls: [URL], unlocked: [URL: String] = [:]) -> [Loss] {
        var unique: [URL] = []
        for url in urls where !unique.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            unique.append(url)
        }
        guard unique.count > 1 else { return [] }
        return detect(unique, unlocked: unlocked)
    }

    /// N1-Rest: Eine einzige Quelle, die neu aufgebaut werden musste (der
    /// Kern meldete `needsRebuild`). Die Verschlüsselung zählt nicht – ein
    /// Ergebnis aus einer entsperrten Quelle wird beim Sichern wieder
    /// verschlüsselt (N10).
    nonisolated static func rebuildLosses(for url: URL, displayName: String? = nil) -> [Loss] {
        let unlocked = displayName.map { [url: $0] } ?? [:]
        return detect([url], unlocked: unlocked).filter { $0.feature != .encryption }
    }

    /// Ein Satz für das Ergebnis nach einem Neuaufbau einer einzelnen Quelle.
    static func rebuildSentence(for losses: [Loss]) -> String? {
        guard !losses.isEmpty else { return nil }
        let list = losses.map(\.feature.label).joined(separator: ", ")
        return String(localized: "Diese PDF ließ sich nicht im Original umbauen und wurde neu aufgebaut. Dabei nicht übernommen: \(list).")
    }

    private nonisolated static func detect(_ unique: [URL], unlocked: [URL: String]) -> [Loss] {
        var files: [Feature: [String]] = [:]
        for url in unique where !url.path.hasPrefix(ImageImporter.sessionDirectory.path) {
            let name = unlocked[url] ?? url.lastPathComponent
            if unlocked[url] != nil { files[.encryption, default: []].append(name) }
            // Nicht lesbar (z. B. Benutzerpasswort): Das meldet schon der
            // Import; hier gibt es nichts zu zählen.
            guard let doc = try? PDFCoreDocument(path: url.path),
                  let features = try? doc.catalogFeatures() else { continue }
            for raw in features {
                if let feature = Feature(rawValue: raw), !(files[feature]?.contains(name) ?? false) {
                    files[feature, default: []].append(name)
                }
            }
        }
        return Feature.allCases.compactMap { feature in
            files[feature].map { Loss(feature: feature, files: $0) }
        }
    }

    /// Ein Satz für den Hinweis vor „PDF erstellen“.
    static func sentence(for losses: [Loss]) -> String? {
        guard !losses.isEmpty else { return nil }
        let parts = losses.map { "\($0.feature.label) (\($0.files.joined(separator: ", ")))" }
        let list = parts.joined(separator: ", ")
        return String(localized: "Beim Zusammenfügen nicht übernommen: \(list).")
    }
}
