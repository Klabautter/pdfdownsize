import AppKit
import Foundation

/// Masterplan N16: Einstieg des Hilfsprozesses (siehe `FrameworkProbe`).
///
///     PDFdownsize --probe snapshot <pdf> <pdfKit|merged> <ergebnis.json>
///     PDFdownsize --probe render <referenz.pdf> <ausgabe.pdf> <seiten,kommagetrennt> <ergebnis.json>
///
/// Läuft, bevor irgendetwas von der Oberfläche entsteht (`PDFdownsizeMain`):
/// kein Fenster, kein Dock-Symbol, kein Netz, kein Zustand. Auf der
/// Standardausgabe steht je Seite `B <seite>` beim Beginn und `E <seite>`
/// beim Ende – daran erkennt der Aufrufer, ob gearbeitet wird oder der
/// Prozess hängt. Das Ergebnis steht als JSON in der Ergebnisdatei.
enum ProbeMode {

    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: "--probe") else { return }
        stayOutOfTheDock()
        exitWhenParentIsGone()
        exit(run(Array(arguments[(index + 1)...])))
    }

    /// Der Hilfsprozess ist die ausführbare Datei des App-Bundles. Sobald
    /// PDFKit in ihm die Verbindung zum Fensterserver aufbaut, meldet macOS
    /// ihn nach der `Info.plist` an – als normales Programm mit eigenem
    /// Dock-Symbol (gemessen 19.11.: `lsappinfo` type="Foreground"). Bei jedem
    /// Komprimieren erschiene ein zweites PDFdownsize im Dock.
    /// Deshalb legt er sich vor jeder anderen Arbeit selbst fest: kein
    /// Dock-Symbol, keine Fenster, nicht aktivierbar.
    private static func stayOutOfTheDock() {
        // Läuft aus `main()` auf dem Hauptthread (G6).
        MainActor.assumeIsolated { _ = NSApplication.shared.setActivationPolicy(.prohibited) }
    }

    /// Der Aufrufer hält das Schreibende unserer Standardeingabe. Endet er
    /// (App beendet, abgestürzt), kommt hier das Dateiende an – dann endet
    /// auch der Hilfsprozess, selbst wenn er gerade in PDFKit festhängt.
    /// Ohne das bliebe nach dem Beenden der App ein hängender Prozess zurück,
    /// der weiter einen Kern belegt.
    private static func exitWhenParentIsGone() {
        Thread.detachNewThread {
            while !FileHandle.standardInput.availableData.isEmpty {}
            _exit(FrameworkProbe.ExitCode.internalError)
        }
    }

    /// Fortschrittszeilen, aus mehreren Threads (parallele Seitenbereiche).
    private static let outputLock = NSLock()
    private static func emit(_ line: String) {
        outputLock.lock(); defer { outputLock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
    private static let pageProgress: PDFSemanticSnapshot.PageProgress = { began, page in
        emit("\(began ? "B" : "E") \(page)")
    }

    static func run(_ arguments: [String]) -> Int32 {
        guard let operation = arguments.first else { return FrameworkProbe.ExitCode.usage }
        switch operation {
        case "snapshot":
            guard arguments.count == 4,
                  let backend = PDFSemanticSnapshot.Backend(rawValue: arguments[2]) else {
                return FrameworkProbe.ExitCode.usage
            }
            do {
                let snapshot = try PDFSemanticSnapshot.captureInProcess(
                    URL(fileURLWithPath: arguments[1]), backend: backend, onPage: pageProgress)
                return write(snapshot, to: arguments[3])
            } catch let error as CocoaError where error.code == .fileReadCorruptFile {
                return FrameworkProbe.ExitCode.unreadable
            } catch {
                return FrameworkProbe.ExitCode.internalError
            }
        case "render":
            guard arguments.count == 5 else { return FrameworkProbe.ExitCode.usage }
            let pages = arguments[3].split(separator: ",").compactMap { Int($0) }
            guard let measurements = PDFValidator.measureRenderSample(
                referenceURL: URL(fileURLWithPath: arguments[1]),
                outputURL: URL(fileURLWithPath: arguments[2]),
                pages: pages, onPage: pageProgress)
            else { return FrameworkProbe.ExitCode.unreadable }
            return write(measurements, to: arguments[4])
        default:
            return FrameworkProbe.ExitCode.usage
        }
    }

    private static func write<T: Encodable>(_ value: T, to path: String) -> Int32 {
        do {
            try JSONEncoder().encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
            return FrameworkProbe.ExitCode.ok
        } catch {
            return FrameworkProbe.ExitCode.internalError
        }
    }
}
