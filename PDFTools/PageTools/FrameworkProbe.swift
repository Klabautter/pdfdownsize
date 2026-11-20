import Foundation

/// Masterplan N16: Aufrufe in PDFKit und CoreGraphics, die bei kaputten
/// Dateien nicht zurückkommen oder abstürzen, laufen in einem Hilfsprozess.
///
/// Vorher (D5) lief der Aufruf auf einem eigenen Thread mit Zeitlimit. Nach
/// Ablauf gab der Aufrufer auf – der Thread nicht: Er rechnete weiter, je
/// hängender Seite dauerhaft ein Kern, dazu unbegrenzt Speicher (gemessen:
/// 23 GB nach zwei Problem-Dateien in zwei Minuten). Ein Thread lässt sich
/// nicht beenden, ein Prozess schon.
///
/// Der Hilfsprozess ist dieselbe ausführbare Datei mit `--probe …`
/// (`ProbeMode`). Er meldet auf seiner Standardausgabe je Seite Beginn und
/// Ende; bleibt die Arbeit an einer Seite länger als das Zeitlimit ohne
/// Meldung, wird er beendet. Das Ergebnis steht als JSON in einer Datei.
enum FrameworkProbe {

    enum Failure: Error, Equatable {
        /// Der Hilfsprozess ließ sich nicht starten.
        case launchFailed(String)
        /// Zu lange kein Fortschritt; `page` ist die Seite (0-basiert), an der
        /// er zuletzt arbeitete, falls bekannt. Der Prozess wurde beendet.
        case stalled(page: Int?)
        /// Vorzeitiges Ende durch ein Signal (Absturz im Framework).
        case crashed
        /// Regulär beendet, aber mit Fehlercode `code` (Datei nicht lesbar …).
        case failed(code: Int32)
        /// Beendet ohne lesbares Ergebnis.
        case noResult
        /// Vom Aufrufer abgebrochen (N27); der Prozess wurde beendet.
        case cancelled
    }

    /// Exit-Codes des Hilfsprozesses.
    enum ExitCode {
        static let ok: Int32 = 0
        static let unreadable: Int32 = 3
        static let usage: Int32 = 64
        static let internalError: Int32 = 70
    }

    /// So lange darf der Hilfsprozess außerhalb der Arbeit an einer Seite
    /// (Öffnen, Dokumentstruktur, Schreiben des Ergebnisses) still sein.
    static let stageTimeout: Double = 120

    // MARK: Aufrufe

    // MARK: App-Sandbox (Masterplan G5)

    /// Läuft die App in der Sandbox? Dann gelten die Dateifreigaben (Dialog,
    /// Drop, „Öffnen mit“) nur für diesen Prozess – der Hilfsprozess ist ein
    /// eigener Prozess mit eigener Sandbox und dürfte die Datei des Nutzers
    /// nicht lesen.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Eine für den Hilfsprozess lesbare Fassung von `url`: in der Sandbox
    /// eine Kopie im eigenen Temp-Ordner (auf APFS ein Klon, also ohne
    /// Kopierkosten), sonst `url` selbst. `cleanup` entfernt die Kopie.
    static func readableForHelper(_ url: URL) -> (url: URL, cleanup: () -> Void) {
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard isSandboxed, !url.standardizedFileURL.path.hasPrefix(temp) else { return (url, {}) }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).pdf")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return (copy, { try? FileManager.default.removeItem(at: copy) })
        } catch {
            return (url, {})   // der Hilfsprozess meldet dann „nicht lesbar“
        }
    }

    static func snapshot(_ url: URL, backend: PDFSemanticSnapshot.Backend,
                         isCancelled: (@Sendable () -> Bool)? = nil) throws -> PDFSemanticSnapshot {
        let readable = readableForHelper(url)
        defer { readable.cleanup() }
        let result = run(["snapshot", readable.url.path, backend.rawValue],
                         pageTimeout: PDFSemanticSnapshot.pageTextTimeout,
                         isCancelled: isCancelled)
        switch result {
        case .failure(.cancelled):
            throw CancellationError()
        case .success(let data):
            do { return try JSONDecoder().decode(PDFSemanticSnapshot.self, from: data) }
            catch { throw PDFSemanticSnapshot.SnapshotError.probeFailed(reason: "Ergebnis nicht lesbar") }
        case .failure(.stalled(let page)):
            throw PDFSemanticSnapshot.SnapshotError.textExtractionTimedOut(page: page ?? 0)
        case .failure(.failed(code: ExitCode.unreadable)):
            // Wie die Erfassung im eigenen Prozess: gesperrt oder kein PDF.
            throw CocoaError(.fileReadCorruptFile)
        case .failure(let failure):
            throw PDFSemanticSnapshot.SnapshotError.probeFailed(reason: String(describing: failure))
        }
    }

    /// Render-Stichprobe: Messwerte je Seite, oder der Grund, warum es keine gibt.
    static func renderSample(referenceURL: URL, outputURL: URL,
                             pages: [Int]) -> Result<[PDFValidator.RenderSampleMeasurement], Failure> {
        let list = pages.map(String.init).joined(separator: ",")
        let reference = readableForHelper(referenceURL)
        let output = readableForHelper(outputURL)
        defer { reference.cleanup(); output.cleanup() }
        return run(["render", reference.url.path, output.url.path, list],
                   pageTimeout: PDFValidator.renderSampleTimeout)
            .flatMap { data in
                guard let pages = try? JSONDecoder().decode([PDFValidator.RenderSampleMeasurement].self, from: data)
                else { return .failure(.noResult) }
                return .success(pages)
            }
    }

    // MARK: Prozess

    /// Zustand, den der Lese-Handler der Standardausgabe und die Warteschleife teilen.
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        // Betriebszeit statt Wanduhr: Sie steht, während der Rechner schläft.
        // Mit `Date()` galt nach dem Aufwachen jede laufende Seite als
        // „seit Stunden in Arbeit", und der Hilfsprozess wurde zu Unrecht
        // beendet (Vollsuite 19.11.: drei falsche Zeitüberläufe).
        private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        private var lastEvent = Progress.now()
        private var inFlight: [Int: TimeInterval] = [:]     // Seite → Beginn
        private var buffer = Data()

        func consume(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                lastEvent = Self.now()
                let parts = line.split(separator: " ")
                guard parts.count == 2, let page = Int(parts[1]) else { continue }
                if parts[0] == "B" { inFlight[page] = Self.now() }
                if parts[0] == "E" { inFlight[page] = nil }
            }
        }

        /// Seite, an der seit mehr als `pageTimeout` gearbeitet wird; oder
        /// `.some(nil)`, wenn außerhalb einer Seite zu lange nichts kam.
        func stall(pageTimeout: Double, stageTimeout: Double) -> Int?? {
            lock.lock(); defer { lock.unlock() }
            let now = Self.now()
            if let oldest = inFlight.min(by: { $0.value < $1.value }) {
                return now - oldest.value > pageTimeout ? .some(oldest.key) : nil
            }
            return now - lastEvent > stageTimeout ? .some(nil) : nil
        }
    }

    /// Umgebung des Hilfsprozesses: nur das Nötige. Unter XCTest stehen in der
    /// Umgebung des Test-Hosts Einträge (DYLD_INSERT_LIBRARIES,
    /// XCTestConfigurationFilePath …), mit denen ein Kindprozess selbst
    /// Tests laden würde.
    static func childEnvironment(from parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let keep: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL",
                                 "__CF_USER_TEXT_ENCODING"]
        return parent.filter { keep.contains($0.key) }
    }

    static func executableURL() -> URL? {
        Bundle.main.executableURL ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0) }
    }

    /// Startet `--probe <arguments> <ergebnisdatei>`, überwacht den
    /// Fortschritt und liefert den Inhalt der Ergebnisdatei. `isCancelled`
    /// wird alle 0,2 s gefragt; `true` beendet den Prozess (N27).
    static func run(_ arguments: [String], pageTimeout: Double,
                    isCancelled: (@Sendable () -> Bool)? = nil) -> Result<Data, Failure> {
        guard let executable = executableURL() else { return .failure(.launchFailed("kein Programmpfad")) }
        if let isCancelled, isCancelled() { return .failure(.cancelled) }
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfdownsize-probe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: resultURL) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--probe"] + arguments + [resultURL.path]
        process.environment = childEnvironment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Das Schreibende bleibt hier offen, solange wir leben: Der
        // Hilfsprozess liest darauf und beendet sich beim Dateiende – also
        // auch dann, wenn dieser Prozess endet, während er noch hängt.
        let lifeline = Pipe()
        process.standardInput = lifeline
        defer { try? lifeline.fileHandleForWriting.close() }

        let progress = Progress()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { progress.consume(chunk) }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return .failure(.launchFailed(error.localizedDescription))
        }
        defer { output.fileHandleForReading.readabilityHandler = nil }

        while exited.wait(timeout: .now() + 0.2) == .timedOut {
            if let isCancelled, isCancelled() {
                stop(process, exited: exited)
                return .failure(.cancelled)
            }
            if let stalledPage = progress.stall(pageTimeout: pageTimeout, stageTimeout: stageTimeout) {
                stop(process, exited: exited)
                return .failure(.stalled(page: stalledPage))
            }
        }
        if process.terminationReason == .uncaughtSignal { return .failure(.crashed) }
        guard process.terminationStatus == ExitCode.ok else {
            return .failure(.failed(code: process.terminationStatus))
        }
        guard let data = try? Data(contentsOf: resultURL), !data.isEmpty else { return .failure(.noResult) }
        return .success(data)
    }

    /// Beenden, das wirklich endet: erst SIGTERM, nach einer halben Sekunde
    /// SIGKILL; danach ist der Prozess abgeräumt (kein Zombie, kein Waise).
    private static func stop(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        if exited.wait(timeout: .now() + 0.5) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
    }
}
