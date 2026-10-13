import Foundation

/// Begrenzte Parallelität für REINE Rechenarbeit (2026-10-13).
///
/// Führt `body` für die Indizes 0..<count auf höchstens `limit` Threads aus
/// und liefert die Ergebnisse IN INDEXREIHENFOLGE – das Ergebnis hängt damit
/// nicht davon ab, welcher Job zuerst fertig wird. `body` darf keinen
/// gemeinsamen veränderlichen Zustand anfassen; Dokument-Mutationen gehören
/// nicht hierher, sie laufen seriell beim Aufrufer.
///
/// Eigene serielle Queue je Job (Overcommit-Pool) statt
/// `DispatchQueue.global()` – derselbe Grund wie in
/// `CompressionPlanner.generateCandidateEntries` (Deadlock-Befund).
enum ParallelWork {
    /// Obergrenze wie die Kandidatensuche: nie mehr als acht Jobs, damit auf
    /// Rechnern mit vielen Kernen Luft für den Rest bleibt.
    static var defaultLimit: Int { PixelWorkScheduler.maximumActiveJobs }

    static func map<T>(count: Int, limit: Int = defaultLimit,
                       _ body: @escaping @Sendable (Int) -> T) -> [T] where T: Sendable {
        guard count > 0 else { return [] }
        if count == 1 || limit <= 1 { return (0..<count).map(body) }
        let slots = DispatchSemaphore(value: max(1, limit))
        let group = DispatchGroup()
        let lock = NSLock()
        nonisolated(unsafe) var results = [T?](repeating: nil, count: count)
        for index in 0..<count {
            slots.wait()
            group.enter()
            DispatchQueue(label: "pdftools.parallel.\(index)", qos: .userInitiated).async {
                defer { slots.signal(); group.leave() }
                let value = autoreleasepool { body(index) }
                lock.lock()
                results[index] = value
                lock.unlock()
            }
        }
        group.wait()
        return results.map { $0! }
    }

    /// Gemeinsame Kernreserve für Arbeit INNERHALB eines Bild-Jobs.
    ///
    /// Die Kandidatensuche verteilt Bilder schon auf bis zu
    /// `defaultLimit` Jobs. Hat ein Dokument nur wenige Bilder, bleiben
    /// Kerne frei – dann darf ein Job Teilschritte vorausrechnen. Jeder
    /// laufende Bild-Job belegt einen Platz; Zusatzplätze gibt es nur,
    /// solange die Summe unter der Grenze bleibt. So entsteht bei vielen
    /// Bildern keine Überbuchung, bei einem einzelnen Bild arbeiten trotzdem
    /// mehrere Kerne.
    enum Slots {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var inUse = 0

        /// Ein Bild-Job beginnt bzw. endet (belegt immer, wartet nie).
        static func enter() { lock.lock(); inUse += 1; lock.unlock() }
        static func leave() { lock.lock(); inUse = max(0, inUse - 1); lock.unlock() }

        /// Versucht, `count` Zusatzplätze zu belegen; `false` = keine Luft.
        static func tryReserve(_ count: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard inUse + count <= defaultLimit else { return false }
            inUse += count
            return true
        }

        static func release(_ count: Int) {
            lock.lock(); inUse = max(0, inUse - count); lock.unlock()
        }
    }
}
