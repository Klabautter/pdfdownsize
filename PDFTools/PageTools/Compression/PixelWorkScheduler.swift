import Foundation

// MARK: - Masterplan §15.2/§15.3 – Pixel-Budget-Scheduler
//
// Nicht „maxConcurrentJobs = 4", sondern Σ estimatedWorkingBytes ≤ Budget:
// Ein Job reserviert geschätzte Arbeitsbytes als Lease, bevor er beginnt;
// neue Reservierungen fließen nur, solange die Summe im Budget bleibt.
//
// Schätzung je Job (§15.2, deterministische Funktion der Rastermaße):
//
//     decoded source        w·h·bytesPerPixel        (RGBA-Arbeitsformat)
//   + resized buffer        tw·th·bytesPerPixel      (Zielraster des Resamples)
//   + encode scratch        2 × Zielraster           (Encoder-Ein-/Ausgabe und
//                                                    offener Kandidat im Race)
//   + quality sample        max(Zielraster/16, 64 KB) (SSIM-Kachelsample)
//
// Die Formel ist eine PLANUNGSHEURISTIK für den Peak, kein exaktes Messband:
// Die Bracketed Search hält je Stufe nur eine Referenz (autoreleasepool je
// Runge), der Sample-Term deckt die Messpuffer konservativ ab.
//
// Budget: ein Sechzehntel des Arbeitsspeichers, mindestens 256 MB, höchstens
// 2 GB (8 GB → 512 MB, 16 GB → 1 GB, 24 GB → 1,5 GB). Bis 2026-10-13 fest
// 256 MB: Bei 12-Megapixel-Fotos (≈ 56 MB je Job) liefen damit nur vier Jobs
// gleichzeitig, auf einem Rechner mit 10 Kernen und 24 GB blieb mehr als die
// Hälfte der Kerne liegen (medium.pdf, Smart: 5,8 s bei 256 MB, 4,8 s bei
// 1 GB). Das Budget ändert nur, wie viele Bilder GLEICHZEITIG laufen – jedes
// einzelne wird gerechnet wie zuvor. Konfigurierbar für Benchmarks via
// CompressionOptions.pixelBudgetBytes (> 0) oder die Umgebungsvariable
// PDFTOOLS_PIXEL_BUDGET (Bytes; überschreibt die Option).
//
// §15.1 – QPDF-Mutationen (replace/execute) laufen NIE unter dem Scheduler;
// er begrenzt ausschließlich pure Pixelarbeit (decode/resize/encode/measure).
final class PixelWorkScheduler: @unchecked Sendable {

    /// Obergrenze gleichzeitig AKTIVER Jobs (kein unbounded Spawn).
    static let maximumActiveJobs = min(ProcessInfo.processInfo.activeProcessorCount, 8)

    let budgetBytes: Int64

    private let lock = NSLock()
    private var activeBytes: Int64 = 0
    private var activeJobs = 0
    private var waiters: [Waiter] = []

    // Telemetrie (SchedulerTests, Benchmark-Rapport).
    private(set) var peakActiveBytes: Int64 = 0
    private(set) var peakConcurrentJobs = 0
    private(set) var clampedRequests = 0

    init(budgetBytes: Int64) {
        self.budgetBytes = max(1, budgetBytes)
    }

    // MARK: Budget-Auflösung

    static let minimumDefaultBudget: Int64 = 256 * 1024 * 1024
    static let maximumDefaultBudget: Int64 = 2 * 1024 * 1024 * 1024
    /// Anteil des Arbeitsspeichers, den die Bildarbeit EINES Dokuments
    /// höchstens gleichzeitig belegen soll. Im Stapel laufen bis zu zwei
    /// Dokumente (`CompressionConcurrency`) – zusammen also ein Achtel.
    static let memoryShareDivisor: UInt64 = 16

    /// Budget ohne Option und Umgebung: am Arbeitsspeicher gemessen, in den
    /// Grenzen `minimumDefaultBudget` … `maximumDefaultBudget`.
    static func defaultBudget(physicalMemory: UInt64) -> Int64 {
        let share = Int64(clamping: physicalMemory / memoryShareDivisor)
        return min(max(share, minimumDefaultBudget), maximumDefaultBudget)
    }

    /// Option, Env-Überschreibung (PDFTOOLS_PIXEL_BUDGET in Bytes), sonst
    /// das Budget nach Arbeitsspeicher – Reihenfolge: Env > Option > Default.
    static func resolvedBudget(optionsBytes: Int64 = 0,
                               env: [String: String] = ProcessInfo.processInfo.environment,
                               physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int64 {
        if let raw = env["PDFTOOLS_PIXEL_BUDGET"]?.trimmingCharacters(in: .whitespaces),
           let bytes = Int64(raw), bytes > 0 {
            return bytes
        }
        if optionsBytes > 0 { return optionsBytes }
        return defaultBudget(physicalMemory: physicalMemory)
    }

    /// Schätzung je Job (Formel siehe Klassendoku). Rein aus den Maßen –
    /// deterministisch, damit zwei Läufe dieselben Reservierungen fahren.
    static func estimatedWorkingBytes(source: PixelSize,
                                      target: PixelSize,
                                      bytesPerPixel: Int = 4) -> Int64 {
        let bpp = Int64(max(1, bytesPerPixel))
        let decodedSource = Int64(max(0, source.pixelCount)) * bpp
        let resized = Int64(max(0, target.pixelCount)) * bpp
        let encodeScratch = 2 * resized
        let qualitySample = max(resized / 16, 64 * 1024)
        return decodedSource + resized + encodeScratch + qualitySample
    }

    // MARK: Lease-API (§15.3)

    /// Reserviert `bytes` Arbeitsbytes; wartet, bis sie ins Budget passen.
    /// `bytes > Budget` wird aufs Budget geklemmt (Job läuft allein).
    /// Nicht abbruchs-fähig: Aufrufer prüfen Cancel VOR dem `acquire`.
    func acquire(bytes: Int64) async -> Lease {
        let request = clamp(bytes)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Lease, Never>) in
            lock.lock()
            waiters.append(Waiter(bytes: request, resume: .async(continuation)))
            grantLocked()
            lock.unlock()
        }
    }

    /// Synchrone Brücke für die (bewusst Dispatch-basierte) Planung: gleiches
    /// Budget, gleiche First-Fit-Fairness, blockiert bis zur Zuteilung.
    func acquireBlocking(bytes: Int64) -> Lease {
        let request = clamp(bytes)
        let waiter = Waiter(bytes: request, resume: .sync)
        lock.lock()
        waiters.append(waiter)
        grantLocked()
        lock.unlock()
        waiter.awaitSync()
        return Lease(scheduler: self, bytes: request)
    }

    /// Unter lock: bedient passende Wartende – First Fit in Queue-Reihenfolge
    /// (kleine Jobs dürfen an großen vorbeiziehen; die neue Anfrage selbst
    /// steht aber nie vor älteren Wartenden).
    private func grantLocked() {
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            guard activeBytes + waiter.bytes <= budgetBytes else {
                index += 1
                continue
            }
            activeBytes += waiter.bytes
            activeJobs += 1
            waiters.remove(at: index)
            peakActiveBytes = max(peakActiveBytes, activeBytes)
            peakConcurrentJobs = max(peakConcurrentJobs, activeJobs)
            waiter.fulfill(self)
        }
    }

    private func clamp(_ bytes: Int64) -> Int64 {
        guard bytes > budgetBytes else { return max(1, bytes) }
        lock.lock(); clampedRequests += 1; lock.unlock()
        return budgetBytes
    }

    private func release(_ bytes: Int64) {
        lock.lock()
        activeBytes = max(0, activeBytes - bytes)
        activeJobs = max(0, activeJobs - 1)
        grantLocked()
        lock.unlock()
    }

    // MARK: Lease

    /// Reservierte Arbeitsbytes. Genau EINMAL freigeben (idempotent,
    /// RAII-Fallback im deinit für abgebrochene Pfade).
    final class Lease: @unchecked Sendable {
        private let scheduler: PixelWorkScheduler
        private let bytes: Int64
        private let lock = NSLock()
        private var released = false

        fileprivate init(scheduler: PixelWorkScheduler, bytes: Int64) {
            self.scheduler = scheduler
            self.bytes = bytes
        }

        func release() {
            lock.lock()
            if released { lock.unlock(); return }
            released = true
            lock.unlock()
            scheduler.release(bytes)
        }

        deinit { release() }
    }

    // MARK: Wartende

    /// Eine Zuteilungsanfrage bytes → Fortsetzung. `grantLocked` bedient den
    /// ERSTEN passenden Wartenden; die Queue selbst bleibt in Reihenfolge.
    private final class Waiter {
        let bytes: Int64
        private let resume: Resume

        enum Resume {
            /// Asynchroner Pfad: Fortsetzung erhält die Lease direkt.
            case async(CheckedContinuation<Lease, Never>)
            /// Sync-Pfad wartet auf ein Signal; die Bytes wurden bei der
            /// Zuteilung bereits verrechnet.
            case sync
        }

        private let syncSemaphore = DispatchSemaphore(value: 0)

        init(bytes: Int64, resume: Resume) {
            self.bytes = bytes
            self.resume = resume
        }

        /// Bedient die Anfrage. Muss UNTER der Scheduler-Sperre laufen.
        func fulfill(_ scheduler: PixelWorkScheduler) {
            switch resume {
            case .async(let continuation):
                continuation.resume(returning: Lease(scheduler: scheduler, bytes: bytes))
            case .sync:
                syncSemaphore.signal()
            }
        }

        func awaitSync() {
            syncSemaphore.wait()
        }
    }
}
