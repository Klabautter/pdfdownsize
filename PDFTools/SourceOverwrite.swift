import AppKit

/// Masterplan E3: Ein Ergebnis darf nie über eine seiner Quellen gesichert
/// werden. Eine Prüfung für alle Sichern-Wege (Komprimieren einzeln und im
/// Stapel, Organisieren, OCR, Konvertieren) – vorher prüfte nur OCR.
enum SourceOverwrite {

    static var message: String {
        String(localized: "Diese Datei ist eine der Quellen. Bitte einen anderen Namen wählen.")
    }

    /// Dieselbe Datei, egal über welchen Pfad: Existieren beide, entscheidet
    /// die Datei-Identität (Symlink, Groß/klein, Hardlink); sonst der
    /// bereinigte Pfad.
    static func isSource(_ destination: URL, among sources: [URL]) -> Bool {
        let dest = destination.standardizedFileURL.resolvingSymlinksInPath()
        let destID = identity(of: dest)
        return sources.contains { source in
            let src = source.standardizedFileURL.resolvingSymlinksInPath()
            if let destID, let srcID = identity(of: src) { return destID.isEqual(srcID) }
            return src.path == dest.path
        }
    }

    /// Wirft, wenn `destination` eine der Quellen ist.
    static func check(_ destination: URL, sources: [URL]) throws {
        if isSource(destination, among: sources) { throw SourceOverwriteError.destinationIsSource }
    }

    private static func identity(of url: URL) -> NSObjectProtocol? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    }
}

enum SourceOverwriteError: LocalizedError, Equatable {
    case destinationIsSource
    var errorDescription: String? { SourceOverwrite.message }
}

/// Lehnt im Sichern-Dialog eine Quelldatei ab, BEVOR macOS nach dem
/// Ersetzen fragt. Die Prüfung im Sichern-Weg selbst bleibt als zweite
/// Sicherung (Wege ohne Dialog, Tests).
final class SourceNameGuard: NSObject, NSOpenSavePanelDelegate {
    let sources: [URL]

    init(sources: [URL]) { self.sources = sources }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard !sources.isEmpty, let panel = sender as? NSSavePanel, let directory = panel.directoryURL else {
            return filename
        }
        var candidate = directory.appendingPathComponent(filename)
        if candidate.pathExtension.isEmpty { candidate.appendPathExtension("pdf") }
        guard SourceOverwrite.isSource(candidate, among: sources) else { return filename }
        let alert = NSAlert()
        alert.messageText = String(localized: "Bitte einen anderen Namen wählen")
        alert.informativeText = SourceOverwrite.message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: panel)
        return nil
    }
}
