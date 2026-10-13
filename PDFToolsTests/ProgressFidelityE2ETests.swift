import Testing
import Foundation
@testable import PDFTools

/// Nutzerbefund 2026-09-30: Der Fortschrittsbalken steht beim Komprimieren
/// am Anfang und springt erst zum Schluss ans Ende.
///
/// Ursache: Die teure Planung (Kandidatensuche, MRC-Seiten-QA) meldete
/// keinen Fortschritt; nur der schnelle Executor füllte 15–70 %.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten des Fixes:
///  1. Der Balken steht weiter den Großteil der Laufzeit am Anfang.
///  2. Der Balken läuft rückwärts (Gesamtarbeit wächst nachträglich).
///  3. Der Balken erreicht 100 %, bevor die Arbeit fertig ist (vorzeitiges
///     Ende, danach langes Warten ohne Anzeige).
///  4. Fortschrittsmeldungen verändern das Ergebnis (Bytes).
@Suite(.serialized) struct ProgressFidelityE2ETests {

    /// Der Foto-Fall des Nutzers (sechs große Fotos, lange Suche).
    static let corpusFile = "RealWorld/arXiv/2608.23479v1.pdf"

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [(time: Double, value: Double)] = []
        let start = Date()
        func record(_ value: Double) {
            lock.lock(); defer { lock.unlock() }
            events.append((Date().timeIntervalSince(start), value))
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func balkenFolgtDerArbeit() throws {
        let input = CorpusRootResolver.resolve().root.appendingPathComponent(Self.corpusFile)
        try #require(FileManager.default.fileExists(atPath: input.path),
                     "Korpusdatei fehlt: \(input.path)")
        let recorder = Recorder()
        let result = try Compressor().compress(inputURL: input, options: .smart,
                                               isCancelled: nil) { value, _ in
            recorder.record(value)
        }
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let total = Date().timeIntervalSince(recorder.start)
        let events = recorder.events
        try #require(events.count >= 2)

        // 2. Monoton.
        for (a, b) in zip(events, events.dropFirst()) {
            #expect(b.value >= a.value - 1e-9, "rückwärts: \(a.value) → \(b.value) bei \(b.time) s")
        }

        // Stand zu einem Zeitpunkt = letzter gemeldeter Wert davor.
        func value(at time: Double) -> Double {
            events.last(where: { $0.time <= time })?.value ?? 0
        }
        // 1. Zur halben Laufzeit deutlich über dem Start (früher 0,05).
        let half = value(at: total * 0.5)
        #expect(half >= 0.25, "Stand zur halben Laufzeit: \(half)")
        // Keine lange Standphase: der Anteil der Laufzeit bei ≤ 10 % bleibt klein.
        var stuck = 0.0
        for (a, b) in zip(events, events.dropFirst()) where a.value <= 0.10 {
            stuck += b.time - a.time
        }
        #expect(stuck / total <= 0.25, "Anteil der Laufzeit bei ≤ 10 %: \(stuck / total)")
        // 3. Kein vorzeitiges Ende: 90 % frühestens nach 60 % der Laufzeit.
        if let ninety = events.first(where: { $0.value >= 0.9 }) {
            #expect(ninety.time >= total * 0.6,
                    "90 % nach \(ninety.time) s von \(total) s")
        }
        #expect(events.last?.value == 1.0)
    }
}
