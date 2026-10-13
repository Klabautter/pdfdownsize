import Foundation
import Darwin

/// Misst Peak-RSS (Resident Set Size) um Memory-Leaks und -Spitzen zu erkennen.
/// Verwendet macOS `task_vm_info.phys_footprint` – der beste Proxy für
/// tatsächlichen physischen Speicherverbrauch.
enum MemoryTracker {

    /// Aktueller physikalischer Speicher-Fußabdruck in Bytes.
    static func currentFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO),
                          $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    /// Formatierte Ausgabe (MB).
    static func formatBytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }
}

/// RAII-Wrapper: misst Peak-RSS während eines Codeblocks.
final class ScopedMemoryMeasurement {
    private let startFootprint: Int64
    private(set) var peakDelta: Int64 = 0
    private var samples: [Int64] = []
    private var monitorTask: Task<Void, Never>?

    init(label: String) {
        startFootprint = MemoryTracker.currentFootprint()
        samples.append(0)

        // Hintergrund-Monitoring alle 50ms für Peak-Erkennung:
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current = MemoryTracker.currentFootprint()
                let delta = current - self.startFootprint
                await MainActor.run {
                    if delta > self.peakDelta { self.peakDelta = delta }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    deinit {
        monitorTask?.cancel()
    }

    var peakRSS: Int64 { startFootprint + peakDelta }
}
