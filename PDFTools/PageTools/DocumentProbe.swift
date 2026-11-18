import Foundation
import pdfcore

/// Eine Vorprüfung für alle vier Werkzeuge und den Stapel (Masterplan B1).
///
/// Vorher wurden passwortgeschützte, leere und abgeschnittene PDFs wie
/// Dokumente geladen: „Wird geschätzt …“ blieb stehen, und erst nach einem
/// Klick erschien „PDFTools.PDFCoreError-Fehler 0.“. Der Kern unterschied die
/// Fälle längst (PDFCORE_ERR_OPEN, PDFCORE_ERR_PASSWORD) – gefragt hat ihn
/// vor dem Lauf niemand.
///
/// Geöffnet wird über pdfcore, dieselbe Wahrheit wie der Lauf – nicht über
/// PDFKit, das manches öffnet, woran die Verarbeitung dann scheitert.
enum DocumentProbe {

    enum Verdict: Equatable, Sendable {
        case ok(pageCount: Int)
        /// Benutzerpasswort nötig.
        case locked
        /// 0 Byte oder 0 Seiten.
        case empty
        /// Kein PDF, abgeschnitten, kaputt.
        case unreadable
        case missing

        var isOK: Bool {
            if case .ok = self { return true }
            return false
        }

        /// Ein Satz für die Dokumentfläche – was ist los?
        var title: String {
            switch self {
            case .ok: return ""
            case .locked: return String(localized: "Diese PDF ist passwortgeschützt.")
            case .empty: return String(localized: "Diese PDF ist leer.")
            case .unreadable: return String(localized: "Diese Datei ist keine lesbare PDF.")
            case .missing: return String(localized: "Die Datei ist nicht mehr da.")
            }
        }

        /// Was jetzt? Der nächste Schritt.
        var detail: String {
            switch self {
            case .ok: return ""
            case .locked:
                return String(localized: "Ohne das Passwort lässt sie sich nicht verarbeiten. Das Original bleibt unverändert.")
            case .empty:
                return String(localized: "Sie enthält keine Seiten, die sich verarbeiten lassen.")
            case .unreadable:
                return String(localized: "Sie ist beschädigt oder unvollständig, zum Beispiel nach einem abgebrochenen Download.")
            case .missing:
                return String(localized: "Sie wurde verschoben oder gelöscht.")
            }
        }

        /// Kurzform für eine Stapelzeile.
        var shortLabel: String {
            switch self {
            case .ok: return ""
            case .locked: return String(localized: "Passwortgeschützt")
            case .empty: return String(localized: "Leer")
            case .unreadable: return String(localized: "Nicht lesbar")
            case .missing: return String(localized: "Nicht gefunden")
            }
        }
    }

    /// Abseits des Main Threads aufrufen. Kosten: ein Öffnen über qpdf (liest
    /// Trailer und Querverweise, keine Streams).
    nonisolated static func inspect(_ url: URL) -> Verdict {
        inspect(url, password: nil)
    }

    /// Mit Passwort (Masterplan B2): `.locked` heißt dann „falsches Passwort“.
    nonisolated static func inspect(_ url: URL, password: String?) -> Verdict {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .missing
        }
        if (attributes[.size] as? NSNumber)?.int64Value ?? 0 == 0 { return .empty }
        do {
            let document = try PDFCoreDocument(path: path, password: password)
            let pages = document.pageCount
            if pages < 0 { return .unreadable }
            return pages == 0 ? .empty : .ok(pageCount: pages)
        } catch PDFCoreError.openFailed(let code) where code == PDFCORE_ERR_PASSWORD.rawValue {
            return .locked
        } catch {
            return .unreadable
        }
    }
}

extension PDFCoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .openFailed(let code) where code == PDFCORE_ERR_PASSWORD.rawValue:
            return String(localized: "Diese PDF ist passwortgeschützt und lässt sich so nicht verarbeiten.")
        case .openFailed:
            return String(localized: "Die Datei ist keine lesbare PDF (beschädigt oder unvollständig).")
        case .checkFailed:
            return String(localized: "Die PDF hat Strukturfehler, die eine sichere Verarbeitung verhindern.")
        case .internalError:
            return String(localized: "Unerwarteter Fehler in der PDF-Verarbeitung. Das Original ist unverändert.")
        }
    }
}
