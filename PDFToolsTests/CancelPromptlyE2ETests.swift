import Testing
import Foundation
@testable import PDFTools

/// Masterplan C4: „Abbrechen“ wirkt in unter 1 s.
///
/// Befund: Der Generator hatte keinen Abbruch-Parameter, der Planner warf am
/// Schleifenkopf, ohne auf laufende Jobs zu warten – bis zu 8 Jobs rechneten
/// weiter und hielten Dokument und Raster.
///
/// Fehlermöglichkeiten: (1) `compress` kehrt spät zurück, weil ein Job eine
/// ganze Leiter zu Ende rechnet; (2) es kehrt sofort zurück, aber Jobs
/// laufen im Hintergrund weiter (Slots > 0); (3) ein Abbruch wird als
/// Fehler statt als `CancellationError` gemeldet.
@Suite(.serialized) struct CancelPromptlyE2ETests {

    static let map = "tmp/pdfs/core-235/11_Maps_CAD_Technical/usgs_light_003_USGS_1_100000-scale_Quadrangle_for_Boston_MA_1989.pdf"

    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    final class Report: @unchecked Sendable {
        private let lock = NSLock()
        private var _returnedAt: ContinuousClock.Instant?
        private var _error: Error?
        func set(returnedAt: ContinuousClock.Instant) { lock.withLock { _returnedAt = returnedAt } }
        func set(error: Error) { lock.withLock { _error = error } }
        var returnedAt: ContinuousClock.Instant? { lock.withLock { _returnedAt } }
        var error: Error? { lock.withLock { _error } }
    }

    @Test(.needsLocalFiles(map)) func abbruchZweiSekundenNachStart() async throws {
        let input = LocalTestData.repoRoot.appendingPathComponent(Self.map)
        let flag = Flag()
        let finished = Flag()
        let report = Report()
        let thread = Thread {
            do {
                let r = try Compressor().compress(inputURL: input, mode: .smart,
                                                  isCancelled: { flag.isSet })
                try? FileManager.default.removeItem(at: r.outputURL)
            } catch {
                report.set(error: error)
            }
            report.set(returnedAt: .now)
            finished.set()
        }
        thread.stackSize = 8 << 20
        thread.start()
        try await Task.sleep(for: .seconds(2))
        try #require(!finished.isSet, "Lauf war nach 2 s schon fertig – Datei zu klein für die Messung")
        let cancelledAt = ContinuousClock.now
        flag.set()
        while !finished.isSet { try await Task.sleep(for: .milliseconds(5)) }
        let latency = try #require(report.returnedAt) - cancelledAt
        #expect(latency < .seconds(1), "compress kehrte erst nach \(latency) zurück")
        #expect(report.error is CancellationError, "Abbruch kam als \(String(describing: report.error))")
        #expect(ParallelWork.Slots.current == 0, "Nach dem Abbruch rechnen noch \(ParallelWork.Slots.current) Jobs")
    }
}
