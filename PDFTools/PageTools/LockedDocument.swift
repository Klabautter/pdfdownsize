import Foundation
import pdfcore

/// Masterplan B2: Passwortgeschützte PDFs entsperren.
///
/// Weg: Mit dem Passwort entsteht eine entschlüsselte ARBEITSKOPIE im
/// Sitzungsordner (gelöscht beim Beenden, wie alle Sitzungsdateien). Alle
/// Werkzeuge arbeiten auf ihr – die Pipeline bleibt, wie sie ist. Was zurück
/// an den Nutzer geht, wird mit den Verschlüsselungsparametern des Originals
/// neu verschlüsselt: gleiches Passwort, gleiches Verfahren.
///
/// Das Passwort lebt nur im Speicher dieses Werts. Es wird nie gespeichert,
/// nie protokolliert und steht in keinem Trace.
struct UnlockedDocument: Equatable {
    /// Die Datei des Nutzers (verschlüsselt).
    let original: URL
    /// Entschlüsselte Arbeitskopie im Sitzungsordner.
    let workingCopy: URL
    let password: String

    /// Prüft das Passwort und legt die Arbeitskopie an. Abseits des Main
    /// Threads aufrufen.
    nonisolated static func unlock(_ url: URL, password: String) throws -> UnlockedDocument {
        let copy = SessionScratch.makeURL(prefix: "unlocked-")
        let status = pdfcore_decrypt_to(url.path, password, copy.path)
        guard status == PDFCORE_OK.rawValue else {
            try? FileManager.default.removeItem(at: copy)
            throw PDFCoreError.openFailed(code: UInt32(status))
        }
        return UnlockedDocument(original: url, workingCopy: copy, password: password)
    }

    /// Schreibt `plain` mit der Verschlüsselung des Originals nach `destination`.
    nonisolated func reencrypt(_ plain: URL, to destination: URL) throws {
        let status = pdfcore_reencrypt_like(plain.path, original.path, password, destination.path)
        guard status == PDFCORE_OK.rawValue else {
            throw PDFCoreError.openFailed(code: UInt32(status))
        }
    }

    /// Kompressionsergebnis der Arbeitskopie → Ergebnis für das Original:
    /// neu verschlüsselt, Größen gegen das ORIGINAL gerechnet.
    nonisolated func reencrypted(_ result: CompressionResult) throws -> CompressionResult {
        let out = SessionScratch.makeURL(prefix: "locked-")
        try reencrypt(result.outputURL, to: out)
        try? FileManager.default.removeItem(at: result.outputURL)
        var mapped = result
        mapped.outputURL = out
        mapped.inputBytes = Compressor.fileSize(of: original)
        mapped.outputBytes = Compressor.fileSize(of: out)
        mapped.alreadyOptimized = mapped.outputBytes >= mapped.inputBytes
        return mapped
    }

    func discard() {
        try? FileManager.default.removeItem(at: workingCopy)
    }
}
