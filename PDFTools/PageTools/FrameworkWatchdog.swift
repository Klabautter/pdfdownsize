import Foundation

/// Masterplan D5 (Fuzz-Funde): Zeitlimit für Aufrufe in Apple-Frameworks, die
/// sich nicht abbrechen lassen – PDFKits Textextraktion und das Zeichnen einer
/// Seite durch CoreGraphics kamen bei mutierten Dateien nicht mehr zurück
/// (> 300 s). Der Aufruf läuft auf einem eigenen Thread; nach Ablauf liefert
/// `run` nil, und der Aufrufer darf das betroffene Dokument nicht weiter
/// benutzen (der stehengebliebene Thread hält seine eigene Referenz).
enum FrameworkWatchdog {

    private final class Box<T>: @unchecked Sendable { var value: T? }

    static func run<T>(timeout seconds: Double, _ body: @escaping () -> T) -> T? {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let work = body
        Thread.detachNewThread {
            box.value = work()
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.value
    }
}
