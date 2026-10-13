import Testing
import Foundation
@testable import PDFTools

/// Masterplan §9.12/§15.5 – Candidate Store: RAII-Aufräumen.
///
/// Temp-Dateien gehören dem Store: Beim Deinit (normales Planungsende) und
/// bei `cancel()` (Abbruch) verschwindet ALLES – keine Leichen im globalen
/// Temp. Der Directory-Check ist der harte Nachweis.
@Suite struct CandidateStoreCleanupTests {

    /// Legt eine gespillte Datei an und lässt den Store sterben.
    private static func leakSpillFile(directory: URL) {
        var config = CandidateStore.Config()
        config.ramPayloadLimitBytes = 1024
        config.filePayloadLimitBytes = 8192
        let store = CandidateStore(config: config, directory: directory)
        _ = store.store(Data(repeating: 5, count: 4096),
                        resource: PDFObjectID(objectNumber: 7, generation: 0),
                        candidate: CandidateID("jpeg-7-0"),
                        kind: .jpeg(target: PixelSize(width: 16, height: 16),
                                    quality: 0.85, backend: .mozjpeg,
                                    grayscale: false))
        // Kein cancel – der Deinit allein muss aufräumen (RAII).
    }

    @Test func deinitRaeumtSpillDateienAb() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("candstore-raii-\(UUID().uuidString)",
                                    isDirectory: true)
        Self.leakSpillFile(directory: directory)
        // Store ist hier garantiert tot (letzte Referenz im Scope verloren);
        // ARC räumt deterministisch, aber wir geben dem Lauf eine kurze
        // Frist, bevor wir den Directory-Check hart stellen.
        var attempts = 0
        while attempts < 50,
              FileManager.default.fileExists(atPath: directory.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path),
                "Deinit hat Spill-Dateien hinterlassen: \(directory.path)")
    }

        @Test func cancelEntferntAllesSofort() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("candstore-cancel-\(UUID().uuidString)",
                                    isDirectory: true)
        var config = CandidateStore.Config()
        config.ramPayloadLimitBytes = 1024
        config.filePayloadLimitBytes = 8192
        let store = CandidateStore(config: config, directory: directory)
        let object = PDFObjectID(objectNumber: 9, generation: 0)
        let payload = store.store(Data(repeating: 8, count: 4096),
                                  resource: object,
                                  candidate: CandidateID("flate-9-0"),
                                  kind: .flate(target: PixelSize(width: 16, height: 16),
                                               grayscale: false, predictor: true))
        guard case .file(let url, _) = payload else {
            Issue.record("Test braucht eine Spill-Datei")
            return
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        store.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "Abbruch muss die Spill-Datei sofort entfernen")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // Lesen nach dem Abbruch liefert nichts mehr – keine Halbzustände.
        #expect(store.data(for: payload) == nil
                || !FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Phase V2-9 (§15.5) – Spill unter Parallelität

    /// §15.4/§15.5 – Parallel laufende Candidate-Jobs legen gleichzeitig
    /// Payloads ab (Scheduler-Lauf). Der Store ist gesperrt und muss dabei
    /// korrekt buchen: RAM- und Dateikonten stimmen, Spill-Dateien existieren
    /// und RAII/cancel räumt ALLE weg.
    @Test func spillUnterParallelitaetBleibtKonsistent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("candstore-parallel-\(UUID().uuidString)",
                                    isDirectory: true)
        var config = CandidateStore.Config()
        config.ramPayloadLimitBytes = 1024
        config.filePayloadLimitBytes = 8192
        let store = CandidateStore(config: config, directory: directory)

        // 24 Jobs × 4 KB (Spill-Grenze 1024) – jede buchst ihre Datei.
        let objectCount = 24
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<objectCount {
                group.addTask {
                    _ = store.store(Data(repeating: UInt8(i + 1), count: 4096),
                                    resource: PDFObjectID(objectNumber: 100 + i,
                                                          generation: 0),
                                    candidate: CandidateID("jpeg-\(i)-0"),
                                    kind: .jpeg(target: PixelSize(width: 16, height: 16),
                                                quality: 0.85, backend: .mozjpeg,
                                                grayscale: false))
                }
            }
        }
        #expect(store.spilledToDisk == objectCount,
                "Alle \(objectCount) Payloads sind gespillt (\(store.spilledToDisk))")
        #expect(store.fileBytes == Int64(objectCount * 4096))
        #expect(store.ramBytes == 0, "4096 > Payload-Grenze 1024 → alles auf Platte")
        #expect(store.ramBytes + store.fileBytes
                <= Int64(objectCount) * 4096)

        var existingSpillFiles = 0
        for i in 0..<objectCount {
            let payload = store.payload(for: CandidateID("jpeg-\(i)-0"),
                                        resource: PDFObjectID(
                                            objectNumber: 100 + i, generation: 0))
            guard case .file(let url, _)? = payload else {
                Issue.record("Payload \(i) sollte gespillt sein")
                continue
            }
            if FileManager.default.fileExists(atPath: url.path) {
                existingSpillFiles += 1
            }
        }
        #expect(existingSpillFiles == objectCount)

        // cancel() entfernt ALLE parallel erzeugten Dateien.
        store.cancel()
        #expect(!FileManager.default.fileExists(atPath: directory.path),
                "Abbruch muss alle Spill-Dateien entfernen (§15.5)")
    }
}
