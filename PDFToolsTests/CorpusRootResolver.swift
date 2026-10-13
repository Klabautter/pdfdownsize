import Foundation

/// Phase 9.1 – die EINE Stelle, an der entschieden wird, wo der Korpus liegt.
///
/// Vorher stand die Auflösung in `CorpusRunnerCore.Config`, und jedes der
/// acht Skripte trug denselben Vorgabepfad noch einmal in seiner eigenen
/// Zeile. Neun Kopien einer Entscheidung heißt: Wer sie ändert, ändert sie
/// achtmal falsch. Die Reihenfolge ist:
///
///     Argument  →  PDFTOOLS_CORPUS_ROOT  →  Vorgabe
///
/// Für die Shell-Seite spiegelt `Scripts/corpus-root.sh` genau diese
/// Reihenfolge; der Vorgabepfad steht dort ebenfalls nur einmal.
enum CorpusRootResolver {

    /// Der Vorgabepfad. FEST, so gewünscht.
    ///
    /// Der Masterplan (2.5/Gate 9) verlangt „keine hartcodierten
    /// Entwicklerpfade". Der Projektinhaber hat hier ausdrücklich anders
    /// entschieden: Der Korpus liegt neben dem Projekt im selben
    /// Arbeitsordner, und der Pfad soll ohne Herleitung feststehen – damit
    /// auf einen Blick klar ist, worauf ein Lauf zugreift. Die Ausnahme
    /// gilt für DIESEN Pfad an DIESER Stelle, nicht allgemein.
    /// Seit der Veröffentlichung (2026-10-13) relativ zum Benutzerordner
    /// geschrieben, damit kein Benutzername im Repo steht; der Ort ist
    /// derselbe.
    static let fallbackPath = NSString(
        string: "~/Desktop/PDF_small/PDF_Tools-Testcorpus").expandingTildeInPath

    struct Resolution: Equatable {
        let root: URL
        /// Woher der Pfad stammt – steht in jedem Report, damit ein
        /// überraschendes Ergebnis nicht erst mühsam zugeordnet werden muss.
        let source: String
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case missing(path: String, source: String)
        case notADirectory(path: String, source: String)

        var description: String {
            switch self {
            case .missing(let path, let source):
                return """
                    Korpuswurzel existiert nicht: \(path)
                    (Quelle: \(source))
                    Entweder den Korpus dort anlegen oder \
                    PDFTOOLS_CORPUS_ROOT auf den richtigen Ort setzen.
                    """
            case .notADirectory(let path, let source):
                return """
                    Korpuswurzel ist kein Verzeichnis: \(path)
                    (Quelle: \(source))
                    """
            }
        }
    }

    /// Löst auf, ohne zu prüfen, ob der Pfad existiert.
    ///
    /// Leere Angaben werden übersprungen, nicht als Pfad genommen: Ein
    /// `PDFTOOLS_CORPUS_ROOT=` in der Umgebung ist eine nicht gesetzte
    /// Variable, kein Wunsch nach dem Wurzelverzeichnis.
    static func resolve(argument: String? = nil,
                        env: [String: String] = ProcessInfo.processInfo.environment)
        -> Resolution {
        if let raw = argument?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return Resolution(root: url(raw), source: "argument")
        }
        if let raw = env["PDFTOOLS_CORPUS_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return Resolution(root: url(raw), source: "env:PDFTOOLS_CORPUS_ROOT")
        }
        return Resolution(root: url(fallbackPath),
                          source: "default:PDF_small/PDF_Tools-Testcorpus")
    }

    /// Löst auf UND prüft. Ein Lauf gegen eine nicht vorhandene Wurzel
    /// erzeugte früher stillschweigend null Dokumente und meldete Erfolg –
    /// das ist die schlechteste aller Antworten.
    static func resolveValidated(
        argument: String? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) throws -> Resolution {
        let r = resolve(argument: argument, env: env)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: r.root.path,
                                     isDirectory: &isDirectory) else {
            throw Failure.missing(path: r.root.path, source: r.source)
        }
        guard isDirectory.boolValue else {
            throw Failure.notADirectory(path: r.root.path, source: r.source)
        }
        return r
    }

    private static func url(_ raw: String) -> URL {
        URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath,
            isDirectory: true)
    }
}
