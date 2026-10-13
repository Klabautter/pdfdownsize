import Foundation

/// Fortschritt der Pixelarbeit eines Laufs (MRC-Seiten-QA + Kandidatensuche).
///
/// Früher meldete nur der schnelle Executor Fortschritt – die teure Planung
/// lief ohne Anzeige, der Balken stand ~94 % der Laufzeit am Anfang.
/// Gewicht = Pixel der Arbeitseinheit (mit Sockel für Fixkosten kleiner
/// Bilder). Die Gesamtarbeit darf wachsen, solange noch nichts erledigt ist
/// (MRC kennt seine Seiten erst nach der Eignungsprüfung); die gemeldete
/// Quote ist monoton.
final class WorkProgressLedger: @unchecked Sendable {
    /// Fixkosten je Einheit (Dekodieren, Klassifizieren, Stichproben).
    static let minimumWeight = 250_000.0

    private let lock = NSLock()
    private var total = 0.0
    private var done = 0.0
    private var reported = 0.0
    private let report: (Double) -> Void

    init(report: @escaping (Double) -> Void) {
        self.report = report
    }

    static func weight(pixels: Int, factor: Double = 1) -> Double {
        max(Double(pixels), minimumWeight) * factor
    }

    func addWork(_ weight: Double) {
        lock.lock()
        total += weight
        lock.unlock()
    }

    func complete(_ weight: Double) {
        lock.lock()
        done = min(done + weight, total)
        let fraction = total > 0 ? done / total : 0
        let publish = fraction > reported
        if publish { reported = fraction }
        lock.unlock()
        if publish { report(fraction) }
    }
}
