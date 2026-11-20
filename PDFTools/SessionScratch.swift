import Foundation
import AppKit
import Darwin

/// Temporäre Ergebnisse der laufenden App-Sitzung (Kompression, OCR,
/// Konvertierung), bis der Nutzer sie sichert oder verwirft.
///
/// Früher lagen sie lose im Temp-Ordner: Nach Beenden oder Absturz blieben
/// sie liegen. Jetzt hat jeder Prozess einen eigenen Ordner; er verschwindet
/// beim Beenden, Reste beendeter Prozesse räumt der nächste Start weg.
/// Ordner LAUFENDER Prozesse bleiben unberührt (Tests neben der offenen App).
enum SessionScratch {

    static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-results", isDirectory: true)
    }

    /// `<pid>-<uuid>` – die PID entscheidet beim Aufräumen, ob der Besitzer lebt.
    static let directory: URL = {
        let url = root.appendingPathComponent(
            "\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Neuer, eindeutiger Pfad im Sitzungsordner.
    static func makeURL(prefix: String = "", pathExtension: String = "pdf") -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(prefix + UUID().uuidString)
            .appendingPathExtension(pathExtension)
    }

    /// Beim Start: Ordner von Prozessen entfernen, die nicht mehr laufen.
    static func cleanupAbandoned() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where entry.standardizedFileURL != directory.standardizedFileURL {
            guard let pidText = entry.lastPathComponent.split(separator: "-").first,
                  let pid = Int32(pidText) else { continue }
            if !isRunning(pid) {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Beim Beenden: eigener Ordner samt nicht gesicherter Ergebnisse – und
    /// samt entsperrter Arbeitskopien und Zwischenstände (N10, N23).
    static func removeOwnDirectory(_ url: URL = directory) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Hängt das Aufräumen an `willTerminate`. Die App ruft das einmal beim
    /// Start mit den Vorgaben; ein Test mit eigenem Center und Ordner (N28).
    @discardableResult
    static func removeOnTermination(center: NotificationCenter = .default,
                                    directory url: URL = directory) -> NSObjectProtocol {
        center.addObserver(forName: NSApplication.willTerminateNotification,
                           object: nil, queue: nil) { _ in
            removeOwnDirectory(url)
        }
    }

    private static func isRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // Signal 0 prüft nur die Existenz; EPERM heißt: läuft, gehört aber
        // einem anderen Nutzer.
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
