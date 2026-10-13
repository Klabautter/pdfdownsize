import Foundation
import Darwin

/// Phase 8.6 – Spitzenspeicher und Zwischendateien je Operation.
///
/// Der Plan verlangt sechs Messwerte. Vier standen bereits in der
/// Ergebniszeile (Laufzeit, Eingangs- und Ausgangsgröße, Prüfergebnis);
/// diese beiden fehlten. Ohne sie prüft der Belastungskorpus zwar, DASS ein
/// 400-MB-Dokument durchläuft, aber nicht, zu welchem Preis – und genau das
/// ist bei grossen Dateien die interessante Frage.
///
/// WARUM EIN EIGENER THREAD
///
/// Das Projekt hat mit `ScopedMemoryMeasurement` bereits einen Abtaster. Der
/// taktet über den MainActor. Der Korpuslauf läuft selbst auf dem MainActor
/// und blockiert ihn, solange eine Operation rechnet – die Abtastung käme
/// also ausgerechnet während der Messung nicht zum Zug und meldete den
/// Ruhewert. Ein eigener Thread misst unabhängig davon weiter.
///
/// Der Speicherwert ist prozessweit, nicht operationsweit: Er enthält, was
/// der Testprozess ohnehin schon hält. Für die Frage „verkraftet die Maschine
/// dieses Dokument" ist das die richtige Grösse; für „wie viel kostet genau
/// diese Operation" ist es eine Obergrenze.
final class OperationResourceSampler: @unchecked Sendable {

    private let lock = NSLock()
    private var peakFootprint: Int64 = 0
    /// -1 heisst NICHT GEMESSEN, nicht „null Bytes".
    ///
    /// Mit 0 als Ausgangswert meldete der Abtaster ohne Arbeitsverzeichnis
    /// „0 Bytes Zwischendateien" – ein plausibel aussehender Wert für eine
    /// Messung, die gar nicht stattgefunden hat. Genau diese Sorte Zahl
    /// führt später zu falschen Schlüssen im Report.
    private var peakWorkspace: Int64 = -1
    private var running = true
    private let workspace: URL?

    /// Speicher wird häufig abgetastet, der Plattenplatz seltener: Ein
    /// Verzeichnis zu vermessen kostet Systemaufrufe je Datei, 50-mal pro
    /// Sekunde wäre selbst eine Last.
    private static let memoryIntervalMicroseconds: UInt32 = 25_000   // 25 ms
    private static let diskEveryNTicks = 10                          // ~250 ms

    init(workspace: URL?) {
        self.workspace = workspace
        let thread = Thread { [weak self] in
            var tick = 0
            while true {
                guard let self, self.stillRunning else { return }
                let footprint = Self.currentFootprint()
                var workspaceBytes: Int64 = -1
                if tick % Self.diskEveryNTicks == 0, let dir = self.workspace {
                    workspaceBytes = Self.directoryBytes(dir)
                }
                self.lock.lock()
                if footprint > self.peakFootprint { self.peakFootprint = footprint }
                if workspaceBytes > self.peakWorkspace { self.peakWorkspace = workspaceBytes }
                self.lock.unlock()
                tick &+= 1
                usleep(Self.memoryIntervalMicroseconds)
            }
        }
        thread.name = "corpus-resource-sampler"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private var stillRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Beendet die Abtastung und liefert die Spitzenwerte.
    /// `peakWorkspaceBytes` ist -1, wenn kein Verzeichnis übergeben wurde.
    func finish() -> (peakFootprintMB: Int, peakWorkspaceBytes: Int64) {
        // Der Plattenwert wird zum Schluss noch einmal genommen: Eine kurze
        // Operation könnte sonst zwischen zwei Abtastungen liegen und mit
        // "0 Bytes Zwischendateien" enden, obwohl sie welche geschrieben hat.
        let finalWorkspace = workspace.map(Self.directoryBytes) ?? -1
        lock.lock()
        running = false
        if finalWorkspace > peakWorkspace { peakWorkspace = finalWorkspace }
        let mb = Int(peakFootprint / 1_048_576)
        let disk = peakWorkspace
        lock.unlock()
        return (mb, disk)
    }

    static func currentFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    /// Summe der Dateigrössen unterhalb von `url`. Ein fehlendes Verzeichnis
    /// ergibt 0, kein Fehler: Es entsteht erst, wenn die Operation etwas
    /// schreibt, und vorher ist 0 die richtige Antwort.
    static func directoryBytes(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileAllocatedSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
