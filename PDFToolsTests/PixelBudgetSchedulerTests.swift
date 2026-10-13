import Testing
import Foundation
@testable import PDFTools

/// Masterplan §15.2/§15.3 – Pixel-Budget-Scheduler.
///
/// Festgenagelt:
///   • Σ aktiver Leases ≤ Budget (Budget-Grenze unter Konkurrenz).
///   • Release gibt Kapazität sofort zurück; wartende Jobs kommen dran.
///   • Anfragen > Budget werden aufs Budget geklemmt (Sättigung, Job allein).
///   • Async- und Sync-Pfad (Planung) teilen dasselbe Budget und dieselbe
///     First-Fit-Queue.
///   • Budget-Auflösung: Env > Option > Tier-Default.
@Suite struct PixelBudgetSchedulerTests {

    private let mb: Int64 = 1_048_576

    /// Zählt aktive Jobs von außen nach – die Grenze wird über den Peak
    /// nachgewiesen, nicht über eine Scheduler-Annahme.
    private final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var active = 0
        var peak = 0
        func enter() {
            lock.lock(); active += 1; peak = max(peak, active); lock.unlock()
        }
        func leave() {
            lock.lock(); active -= 1; lock.unlock()
        }
    }

    @Test func budgetGrenzeWirdEingehalten() async {
        // Budget 256 MB, Jobs je 100 MB → maximal 2 gleichzeitig (200 ≤ 256,
        // 300 > 256). Der Scheduler MUSS dazwischen warten lassen.
        let scheduler = PixelWorkScheduler(budgetBytes: 256 * mb)
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let lease = await scheduler.acquire(bytes: 100 * self.mb)
                    probe.enter()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    probe.leave()
                    lease.release()
                }
            }
        }
        #expect(probe.peak <= 2, "Peak \(probe.peak) über dem 256-MB-Budget")
        #expect(scheduler.peakConcurrentJobs <= 2)
        #expect(scheduler.peakActiveBytes <= 256 * mb)
        #expect(scheduler.peakConcurrentJobs == 2, "Budget muss ausgenutzt werden")
    }

    @Test func leaseReleaseGibtKapazitaetZurueck() async {
        let scheduler = PixelWorkScheduler(budgetBytes: 128 * mb)
        let lease = await scheduler.acquire(bytes: 128 * mb)
        #expect(scheduler.peakActiveBytes == 128 * mb)
        lease.release()
        // Kapazität frei: gleich große Anfrage läuft SOFORT (keine Wartenden).
        let start = Date()
        let second = await scheduler.acquire(bytes: 128 * mb)
        let elapsed = Date().timeIntervalSince(start)
        second.release()
        #expect(elapsed < 1.0, "Release muss die Lease sofort freigeben")
        // Idempotenz: doppeltes Release verfälscht die Buchhaltung nicht.
        lease.release()
        #expect(scheduler.peakActiveBytes <= 128 * mb)
    }

    @Test func saettigungKlemmtUebergrosseAnfragen() async {
        let scheduler = PixelWorkScheduler(budgetBytes: 128 * mb)
        // 512 MB > Budget 128 MB → geklemmt; ein zweiter Job muss warten,
        // bis der erste frei gibt (Job läuft allein).
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    let lease = await scheduler.acquire(bytes: 512 * self.mb)
                    probe.enter()
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    probe.leave()
                    lease.release()
                }
            }
        }
        #expect(scheduler.clampedRequests == 3, "Alle Anfragen übergroß")
        #expect(scheduler.peakConcurrentJobs == 1,
                "Geklemmte Anfrage läuft allein (Peak \(scheduler.peakConcurrentJobs))")
        #expect(scheduler.peakActiveBytes == 128 * mb)
    }

    @Test func syncUndAsyncPfadTeilenBudget() async {
        let scheduler = PixelWorkScheduler(budgetBytes: 128 * mb)
        // Sync-Brücke belegt das Budget (100 MB), die Async-Anfragen (je
        // 50 MB) warten dahinter – Release aus einem BEGLEITTASK, sonst
        // würde die Sperre den Test deadlocken.
        let blocking = scheduler.acquireBlocking(bytes: 100 * mb)
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000)
                blocking.release()
            }
            for _ in 0..<4 {
                group.addTask {
                    let lease = await scheduler.acquire(bytes: 50 * self.mb)
                    probe.enter()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    probe.leave()
                    lease.release()
                }
            }
        }
        #expect(scheduler.peakActiveBytes <= 128 * mb)
        #expect(scheduler.peakConcurrentJobs <= 2,
                "100 MB sync + 50 MB passt nicht; nach Release 2×50 MB (Peak \(scheduler.peakConcurrentJobs))")
    }

            @Test func budgetAufloesungEnvSchlaegtOption() {
        // Reihenfolge: Env > Option > Default nach Arbeitsspeicher.
        let gb: UInt64 = 1024 * 1024 * 1024
        let tier = PixelWorkScheduler.resolvedBudget(optionsBytes: 0, env: [:],
                                                     physicalMemory: 8 * gb)
        #expect(tier == 512 * mb, "8 GB Arbeitsspeicher → 512 MB")
        let option = PixelWorkScheduler.resolvedBudget(
            optionsBytes: 512 * mb, env: [:])
        #expect(option == 512 * mb, "Ohne Env gilt die Option")
        let envWins = PixelWorkScheduler.resolvedBudget(
            optionsBytes: 512 * mb, env: ["PDFTOOLS_PIXEL_BUDGET": "134217728"])
        #expect(envWins == 128 * mb, "Env schlägt die Option")
    }

    /// Budget nach Arbeitsspeicher (2026-10-13): ein Sechzehntel, nie unter
    /// dem früheren Festwert 256 MB, nie über 2 GB. Fehlermöglichkeiten:
    /// (1) kleine Rechner bekommen weniger als bisher, (2) große Rechner
    /// laufen ungedeckelt, (3) die Zwischenwerte skalieren nicht.
    @Test func budgetFolgtDemArbeitsspeicherInGrenzen() {
        let gb: UInt64 = 1024 * 1024 * 1024
        #expect(PixelWorkScheduler.defaultBudget(physicalMemory: 2 * gb) == 256 * mb)
        #expect(PixelWorkScheduler.defaultBudget(physicalMemory: 4 * gb) == 256 * mb)
        #expect(PixelWorkScheduler.defaultBudget(physicalMemory: 8 * gb) == 512 * mb)
        #expect(PixelWorkScheduler.defaultBudget(physicalMemory: 16 * gb) == 1024 * mb)
        #expect(PixelWorkScheduler.defaultBudget(physicalMemory: 24 * gb) == 1536 * mb)
        #expect(PixelWorkScheduler.defaultBudget(physicalMemory: 32 * gb) == 2048 * mb)
        #expect(PixelWorkScheduler.defaultBudget(physicalMemory: 128 * gb) == 2048 * mb)
    }

    @Test func schaetzformelIstDeterministischUndBegruendet() {
        // decoded (w·h·bpp) + resized (tw·th·bpp) + 2×Zielraster + Sample.
        let source = PixelSize(width: 4000, height: 3000)
        let target = PixelSize(width: 2000, height: 1500)
        let estimate = PixelWorkScheduler.estimatedWorkingBytes(
            source: source, target: target)
        let decoded = Int64(source.pixelCount) * 4
        let resized = Int64(target.pixelCount) * 4
        let expected = decoded + resized + 2 * resized + max(resized / 16, 64 * 1024)
        #expect(estimate == expected)
        #expect(estimate > decoded)
        // Graustufen-Job (1 Byte je Bildpunkt) schätzt kleiner.
        let gray = PixelWorkScheduler.estimatedWorkingBytes(
            source: source, target: target, bytesPerPixel: 1)
        #expect(gray < estimate)
    }
}
