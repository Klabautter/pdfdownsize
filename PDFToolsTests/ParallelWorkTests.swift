import Foundation
import Testing
@testable import PDFTools

/// Parallelisierung der Engine (2026-10-13). Fehlermöglichkeiten:
/// (1) Ergebnisse kommen in Fertigstellungs- statt Indexreihenfolge – die
///     Ausgabe hinge vom Zufall ab.
/// (2) Die Obergrenze gleichzeitiger Jobs wird überschritten.
/// (3) Die Kernreserve vergibt mehr Zusatzplätze, als frei sind, oder gibt
///     sie nicht zurück.
/// (4) Vorausgerechnete Qualitätsstufen ändern, welche Stufen die Suche
///     verwendet.
@Suite(.serialized) struct ParallelWorkTests {

    @Test func ergebnisseInIndexreihenfolge() {
        let values = ParallelWork.map(count: 64, limit: 8) { index -> Int in
            // Spätere Indizes werden früher fertig.
            usleep(UInt32((64 - index) * 200))
            return index * index
        }
        #expect(values == (0..<64).map { $0 * $0 })
        #expect(ParallelWork.map(count: 0) { $0 }.isEmpty)
        #expect(ParallelWork.map(count: 1) { $0 + 7 } == [7])
    }

    @Test func obergrenzeWirdEingehalten() {
        let lock = NSLock()
        nonisolated(unsafe) var active = 0
        nonisolated(unsafe) var peak = 0
        _ = ParallelWork.map(count: 40, limit: 3) { _ -> Int in
            lock.lock(); active += 1; peak = max(peak, active); lock.unlock()
            usleep(2_000)
            lock.lock(); active -= 1; lock.unlock()
            return 0
        }
        #expect(peak <= 3)
        #expect(peak >= 2, "lief gar nicht parallel")
    }

    @Test func kernreserveVergibtNurFreiePlaetze() {
        let limit = ParallelWork.defaultLimit
        #expect(ParallelWork.Slots.tryReserve(limit))
        #expect(!ParallelWork.Slots.tryReserve(1), "Platz über der Grenze vergeben")
        ParallelWork.Slots.release(limit)
        #expect(ParallelWork.Slots.tryReserve(1))
        ParallelWork.Slots.release(1)
    }

    /// Dieselbe Suche einmal mit freier Kernreserve (rechnet voraus) und
    /// einmal mit belegter Reserve (rein nacheinander): gleiche Stufen in
    /// gleicher Reihenfolge, gleiche Bytes je Stufe.
    @Test(.hangGuard) func vorausrechnenAendertDieSucheNicht() throws {
        let url = try PDFFixtures.placedTexturedPhotoPDF(pixels: 1400)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try PDFCoreDocument(path: url.path)
        let resource = try #require(try document.imageResources().first)
        let image = try #require(LibQPDFPixelSource(document: document).decodedImage(for: resource))
        let policy = BracketedJPEGSearch.Policy.bracketed(
            qLow: 0.50, qHigh: 0.90, gate: QualityGatePolicy.policy(preset: .smart, imageClass: .photo),
            imageClass: .photo, minimumSSIM: 0.95)

        let speculative = BracketedJPEGSearch.run(reference: image, grayscale: false,
                                                  backend: .mozjpeg, policy: policy)
        #expect(ParallelWork.Slots.tryReserve(ParallelWork.defaultLimit))
        let sequential = BracketedJPEGSearch.run(reference: image, grayscale: false,
                                                 backend: .mozjpeg, policy: policy)
        ParallelWork.Slots.release(ParallelWork.defaultLimit)

        #expect(!speculative.isEmpty)
        #expect(speculative.map(\.quality) == sequential.map(\.quality))
        #expect(speculative.map(\.data) == sequential.map(\.data))
        #expect(speculative.map(\.passed) == sequential.map(\.passed))
    }
}
