import Testing
import Foundation

/// Masterplan F1: Englisches UI ohne deutschen Rest – per Test erzwungen.
///
/// Befund an 1.0.9: 20 benutzte Texte fehlten im Katalog, darunter die
/// Hauptkennzahl „≈ 49 % kleiner“ und „Alles bleibt auf diesem Mac“. Im
/// englischen UI standen sie deutsch.
///
/// Der Test zieht alle Literale aus `String(localized:)`, `Text(…)`,
/// `Button(…)`, `Label(…)`, `Toggle(…)`, `LabeledContent(…)`, `Picker(…)`,
/// `.help(…)`, `.navigationTitle(…)` und prüft je Schlüssel: steht im
/// Katalog und hat eine englische Übersetzung (einfach oder als Variante).
/// Interpolationen `\(…)` werden zu Formatplatzhaltern (%lld, %@, %lf …).
///
/// Fehlermöglichkeiten: (1) ein neuer Text ohne Katalogeintrag; (2) ein
/// Eintrag ohne Englisch; (3) ein Platzhalter-Typ passt nicht – dann sucht
/// SwiftUI einen anderen Schlüssel und zeigt den deutschen Text.
@Suite struct LocalizationHygieneTests {

    static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    static func sourceFiles() -> [URL] {
        let root = projectRoot.appendingPathComponent("PDFTools")
        return (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }) ?? []
    }

    /// Aufrufe, deren erstes Argument ein Lokalisierungsschlüssel ist.
    static let callPrefixes = ["String(localized: ", "Text(", "Button(", "Label(", "Toggle(",
                               "LabeledContent(", "Picker(", ".help(", ".navigationTitle(",
                               "ContentUnavailableView("]

    /// Liest ab `start` (direkt hinter dem öffnenden `"`) ein Swift-String-
    /// Literal bis zum schließenden `"` – Interpolationen `\( … )` dürfen
    /// selbst Anführungszeichen und Klammern enthalten.
    static func literal(in text: [Character], from start: Int) -> String? {
        var i = start
        var out = ""
        while i < text.count {
            let c = text[i]
            if c == "\"" { return out }
            if c == "\\", i + 1 < text.count, text[i + 1] == "(" {
                // Interpolation bis zur passenden Klammer, Strings darin überspringen.
                var depth = 0
                var j = i + 1
                var inString = false
                while j < text.count {
                    let d = text[j]
                    if inString {
                        if d == "\\" { j += 2; continue }
                        if d == "\"" { inString = false }
                    } else if d == "\"" {
                        inString = true
                    } else if d == "(" {
                        depth += 1
                    } else if d == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j += 1
                }
                out += "\\(…)"
                i = j + 1
                continue
            }
            if c == "\\", i + 1 < text.count {
                out.append(c); out.append(text[i + 1]); i += 2; continue
            }
            if c == "\n" { return nil }
            out.append(c)
            i += 1
        }
        return nil
    }

    static func literals(in source: String) -> [String] {
        let chars = Array(source)
        let text = source
        var result: [String] = []
        for prefix in callPrefixes {
            var search = text.startIndex
            while let range = text.range(of: prefix + "\"", range: search..<text.endIndex) {
                let offset = text.distance(from: text.startIndex, to: range.upperBound)
                if let lit = literal(in: chars, from: offset) { result.append(lit) }
                search = range.upperBound
            }
        }
        return result
    }

    /// Schlüssel → Regex über Katalogschlüssel: Interpolation = beliebiger Platzhalter.
    static func keyPattern(_ literal: String) -> NSRegularExpression? {
        // Mit Interpolation verdoppelt Swift ein wörtliches „%“ im Schlüssel.
        let interpolated = literal.contains("\\(…)")
        var pattern = "^"
        var i = literal.startIndex
        while i < literal.endIndex {
            if literal[i...].hasPrefix("\\(…)") {
                pattern += "%(?:lld|ld|d|@|lf|f|llu|lu)"
                i = literal.index(i, offsetBy: 4)
                continue
            }
            if literal[i...].hasPrefix("\\\"") {
                pattern += NSRegularExpression.escapedPattern(for: "\"")
                i = literal.index(i, offsetBy: 2)
                continue
            }
            if literal[i...].hasPrefix("\\n") {
                pattern += "\\n"
                i = literal.index(i, offsetBy: 2)
                continue
            }
            if interpolated && literal[i] == "%" {
                pattern += "%%"
                i = literal.index(after: i)
                continue
            }
            pattern += NSRegularExpression.escapedPattern(for: String(literal[i]))
            i = literal.index(after: i)
        }
        return try? NSRegularExpression(pattern: pattern + "$")
    }

    /// Schlüssel ohne Buchstaben (nur Zahlen/Zeichen) brauchen keine Übersetzung.
    static func needsTranslation(_ literal: String) -> Bool {
        literal.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            && !literal.hasPrefix("%")
    }

    @Test func jederBenutzteTextHatEnglisch() throws {
        let catalogURL = Self.projectRoot.appendingPathComponent("PDFTools/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        func hasEnglish(_ entry: Any?) -> Bool {
            guard let dict = entry as? [String: Any],
                  let en = (dict["localizations"] as? [String: Any])?["en"] as? [String: Any]
            else { return false }
            if let unit = en["stringUnit"] as? [String: Any] {
                return (unit["state"] as? String) == "translated"
            }
            return en["variations"] != nil
        }
        var missing: [String] = []
        for file in Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for literal in Self.literals(in: text) {
                guard Self.needsTranslation(literal), let pattern = Self.keyPattern(literal) else { continue }
                let found = strings.first { key, value in
                    pattern.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil
                        && hasEnglish(value)
                }
                if found == nil { missing.append("\(file.lastPathComponent): \(literal)") }
            }
        }
        let unique = Array(Set(missing)).sorted()
        #expect(unique.isEmpty, Comment(rawValue: "Ohne englische Übersetzung (\(unique.count)):\n" + unique.joined(separator: "\n")))
    }
}
