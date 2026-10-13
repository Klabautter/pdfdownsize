import Testing
import Foundation
@testable import PDFTools

/// Masterplan §9.12 – Candidate Store: Ablagepolitik nach Größe und Budget.
///
/// Festgenagelt:
///   • Klein → RAM (Payload-Grenze UND Gesamtbudget).
///   • Groß → Temp-Datei (Spill-to-Disk, deterministischer Name).
///   • Sehr groß → metadata-only (regenerierbar, Executor kodiert neu).
///   • Überschreiben desselben Schlüssels gibt die alten Bytes frei.
///   • Nach `cancel` akzeptiert der Store nur noch Rezepte.
@Suite struct CandidateStoreBudgetTests {

    private func store(config: CandidateStore.Config)
        -> (store: CandidateStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("candstore-test-\(UUID().uuidString)",
                                    isDirectory: true)
        let store = CandidateStore(config: config, directory: directory)
        return (store, directory)
    }

    private var tinyConfig: CandidateStore.Config {
        var config = CandidateStore.Config()
        config.ramBudgetBytes = 4096
        config.ramPayloadLimitBytes = 1024
        config.filePayloadLimitBytes = 8192
        return config
    }

    private let object = PDFObjectID(objectNumber: 42, generation: 0)
    private let candidate = CandidateID("jpeg-42-0-q0.8500")

    @Test func kleinePayloadLandtImRam() {
        let (store, _) = store(config: tinyConfig)
        let payload = store.store(Data(repeating: 7, count: 512),
                                  resource: object, candidate: candidate,
                                  kind: .jpeg(target: PixelSize(width: 10, height: 10),
                                              quality: 0.85, backend: .mozjpeg,
                                              grayscale: false))
        guard case .memory(let data) = payload else {
            Issue.record("Kleine Payload muss im RAM liegen: \(payload)")
            return
        }
        #expect(data.count == 512)
        #expect(store.ramBytes == 512)
        #expect(store.spilledToDisk == 0)
        #expect(store.regenerableCount == 0)
    }

    @Test func grossePayloadSpilltAufDiePlatte() throws {
        let (store, directory) = store(config: tinyConfig)
        let bytes = Data(repeating: 9, count: 4096)  // > ramPayloadLimit
        let payload = store.store(bytes, resource: object, candidate: candidate,
                                  kind: .flate(target: PixelSize(width: 32, height: 32),
                                               grayscale: false, predictor: true))
        guard case .file(let url, let count) = payload else {
            Issue.record("Große Payload muss auf die Platte: \(payload)")
            return
        }
        #expect(count == 4096)
        #expect(store.spilledToDisk == 1)
        #expect(store.fileBytes == 4096)
        #expect(store.ramBytes == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.path.hasPrefix(directory.path))
        // Round-Trip über den Store.
        #expect(store.data(for: payload) == bytes)
    }

    @Test func sehrGrossePayloadBleibtNurMetadatiert() {
        let (store, _) = store(config: tinyConfig)
        let payload = store.store(Data(repeating: 1, count: 16384),
                                  resource: object, candidate: candidate,
                                  kind: .jpeg(target: PixelSize(width: 64, height: 64),
                                              quality: 0.85, backend: .mozjpeg,
                                              grayscale: false))
        guard case .regenerable(let recipe) = payload else {
            Issue.record("Sehr große Payload muss regenerierbar sein: \(payload)")
            return
        }
        #expect(recipe.resourceID == "42 0")
        #expect(recipe.candidateID == candidate.rawValue)
        #expect(recipe.estimatedBytes == 16384)
        #expect(store.regenerableCount == 1)
        #expect(store.ramBytes == 0 && store.fileBytes == 0)
        #expect(store.data(for: payload) == nil)
    }

    @Test func ramBudgetZwingtAufDiePlatte() {
        // 512-Byte-Payload passt unter die Payload-Grenze, aber die neunte
        // sprengt das 4096-Byte-Gesamtbudget (8 × 512 = 4096) → sie spillt.
        let (store, _) = store(config: tinyConfig)
        for index in 0..<9 {
            let id = CandidateID("p\(index)")
            let payload = store.store(Data(repeating: UInt8(index), count: 512),
                                      resource: object, candidate: id,
                                      kind: .keep)
            if index < 8 {
                if case .memory = payload {} else {
                    Issue.record("Payload \(index) hätte in den RAM gemusst")
                }
            } else if case .file = payload {} else {
                Issue.record("Payload über Budget hätte spillen müssen")
            }
        }
        #expect(store.ramBytes == 4096)
        #expect(store.spilledToDisk == 1)
    }

    @Test func ueberschreibenGibtAlteBytesFrei() {
        let (store, _) = store(config: tinyConfig)
        _ = store.store(Data(repeating: 3, count: 512), resource: object,
                        candidate: candidate, kind: .keep)
        _ = store.store(Data(repeating: 4, count: 256), resource: object,
                        candidate: candidate, kind: .keep)
        #expect(store.ramBytes == 256, "Alter RAM-Inhalt nicht freigegeben")
    }

    @Test func schluesselTrennenRessourcenUndKandidaten() {
        let (store, _) = store(config: tinyConfig)
        _ = store.store(Data(repeating: 1, count: 128), resource: object,
                        candidate: CandidateID("a"), kind: .keep)
        _ = store.store(Data(repeating: 2, count: 128), resource: object,
                        candidate: CandidateID("b"), kind: .keep)
        let other = PDFObjectID(objectNumber: 43, generation: 0)
        _ = store.store(Data(repeating: 3, count: 128), resource: other,
                        candidate: CandidateID("a"), kind: .keep)
        #expect(store.ramBytes == 384)
        #expect(store.payload(for: CandidateID("b"), resource: object) != nil)
        #expect(store.payload(for: CandidateID("a"), resource: other) != nil)
    }

    @Test func nachCancelNurNochRezepte() {
        let (store, directory) = store(config: tinyConfig)
        _ = store.store(Data(repeating: 9, count: 4096), resource: object,
                        candidate: candidate, kind: .keep)
        store.cancel()
        #expect(store.ramBytes == 0 && store.fileBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // Nach dem Abbruch bleibt nur noch das Rezept (RAII-Vertrag §15.5).
        let payload = store.store(Data(repeating: 1, count: 128),
                                  resource: object, candidate: CandidateID("x"),
                                  kind: .keep)
        if case .regenerable = payload {} else {
            Issue.record("Nach cancel darf der Store keine neuen Payloads halten")
        }
    }
}
