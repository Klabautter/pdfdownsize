import Testing
import Foundation
import Darwin
@testable import PDFTools

/// Masterplan N16 (Prüfung 19.11.2026): Aufrufe in PDFKit und CoreGraphics,
/// die bei kaputten Dateien nicht zurückkommen, laufen in einem
/// Hilfsprozess, den man wirklich beenden kann.
///
/// Befund: Der Zeitlimit-Wächter (D5) startete den Aufruf auf einem eigenen
/// Thread und gab nach Ablauf auf. Der Thread rechnete weiter – je hängender
/// Seite dauerhaft ein Kern, dazu unbegrenzt Speicher. Die volle Testsuite
/// trieb den Test-Host so auf 78 GB.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Nach einer Problem-Datei verbraucht der Prozess weiter CPU/Speicher.
///  2. Der Hilfsprozess bleibt nach dem Zeitlimit als Waise liegen.
///  3. Ein Absturz im Framework (Objective-C-Ausnahme) reißt die App mit.
///  4. Der Hilfsprozess liefert für gesunde Dateien etwas anderes als die
///     Erfassung im eigenen Prozess.
///  5. Der Hilfsprozess startet in der Testumgebung selbst Tests oder ein
///     Fenster.
@Suite(.serialized) struct FrameworkProbeTests {

    /// Nutzer- plus Systemzeit des ganzen Prozesses (alle Threads).
    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Speicherabdruck wie in der Aktivitätsanzeige („Speicher").
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static let hangFiles = ["tmp/fuzz-findings/hang-2156.pdf", "tmp/fuzz-findings/hang-107468.pdf"]

    /// Zwei Dateien, an denen PDFKit bzw. CoreGraphics nicht zurückkommen,
    /// nacheinander im selben Prozess. Ob der Lauf mit einem Ergebnis oder
    /// einem Fehler endet, ist hier gleich – danach muss der Prozess ruhig sein.
    @Test(.timeLimit(.minutes(8)),
          .needsLocalFiles("tmp/fuzz-findings/hang-2156.pdf", "tmp/fuzz-findings/hang-107468.pdf"))
    func nachProblemDateienBleibtDerProzessRuhig() throws {
        for path in Self.hangFiles {
            let url = LocalTestData.repoRoot.appendingPathComponent(path)
            if let result = try? Compressor().compress(inputURL: url, mode: .smart),
               result.outputURL != url {
                try? FileManager.default.removeItem(at: result.outputURL)
            }
        }
        let before = Self.processCPUSeconds()
        Thread.sleep(forTimeInterval: 20)
        let burned = Self.processCPUSeconds() - before
        let footprint = Double(Self.footprintBytes()) / 1_073_741_824
        #expect(burned <= 1.0, "In 20 s Ruhe verbrauchte der Prozess \(String(format: "%.1f", burned)) s CPU")
        #expect(footprint < 1.0, "Speicherabdruck \(String(format: "%.2f", footprint)) GB")
    }

    /// Laufende Hilfsprozesse DIESES Prozesses: seine Kindprozesse mit
    /// `--probe`. Eine Suche über alle Prozesse träfe auch fremde
    /// Befehlszeilen, in denen die Wörter nur vorkommen (eine Shell, die
    /// selbst danach sucht) – daran scheiterte der Test zweimal zu Unrecht.
    static func runningProbes() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // „--" vor dem Muster: Ohne es las pgrep „--probe" als Option, brach
        // mit „illegal option" ab, und die Liste war IMMER leer – jede
        // Erwartung „kein Hilfsprozess mehr" galt ungeprüft (N28).
        process.arguments = ["-P", String(getpid()), "-fl", "--", "--probe"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 0 = Treffer, 1 = keiner; alles andere ist ein Aufruffehler.
        if process.terminationStatus > 1 { Issue.record("pgrep scheiterte mit \(process.terminationStatus)") }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Nach dem Zeitlimit ist der Hilfsprozess beendet – kein Waise.
    @Test(.timeLimit(.minutes(4)), .needsLocalFiles("tmp/fuzz-findings/hang-107468.pdf"))
    func haengenderHilfsprozessWirdBeendet() throws {
        let url = LocalTestData.repoRoot.appendingPathComponent("tmp/fuzz-findings/hang-107468.pdf")
        let started = Date()
        #expect(throws: (any Error).self) { try PDFSemanticSnapshot.capture(url) }
        // Ein Zeitlimit je Seite plus Start – nicht die Summe über Rückfallstufen.
        #expect(Date().timeIntervalSince(started) < PDFSemanticSnapshot.pageTextTimeout + 20)
        #expect(Self.runningProbes().isEmpty, "Hilfsprozess läuft noch: \(Self.runningProbes())")
    }

    /// Masterplan N27: Der früh gestartete Referenz-Snapshot (C5) endet mit
    /// `cancel()` – vorher lief er nach Abbruch, Fehler oder entfallener
    /// Validierung bis zu seinem Zeitlimit weiter. Die hängende Datei hält
    /// den Hilfsprozess über 150 s fest; nach dem Abbruch ist er binnen
    /// Sekunden weg.
    @Test(.timeLimit(.minutes(2)), .needsLocalFiles("tmp/fuzz-findings/hang-107468.pdf"))
    func fruehenSnapshotAbbrechenBeendetDenHilfsprozess() throws {
        let url = LocalTestData.repoRoot.appendingPathComponent("tmp/fuzz-findings/hang-107468.pdf")
        let early = EarlyReferenceSnapshot(url)
        Thread.sleep(forTimeInterval: 2)
        #expect(!Self.runningProbes().isEmpty, "Kein Hilfsprozess – Test prüft nichts")
        let started = Date()
        early.cancel()
        #expect(throws: CancellationError.self) { try early.value() }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(Self.runningProbes().isEmpty, "Hilfsprozess läuft noch: \(Self.runningProbes())")
    }

    /// Fuzz-Fund crash-108408: `PDFAnnotation.type` wirft bei einem ungültigen
    /// /Subtype eine Objective-C-Ausnahme. Im Hilfsprozess beendet das nur
    /// ihn; der Lauf endet mit Ergebnis oder Fehler, die App lebt.
    @Test(.timeLimit(.minutes(3)), .needsLocalFiles("tmp/fuzz-findings/crash-108408.pdf"))
    func absturzImFrameworkTrifftNurDenHilfsprozess() {
        let url = LocalTestData.repoRoot.appendingPathComponent("tmp/fuzz-findings/crash-108408.pdf")
        if let result = try? Compressor().compress(inputURL: url, mode: .smart), result.outputURL != url {
            try? FileManager.default.removeItem(at: result.outputURL)
        }
        #expect(Self.runningProbes().isEmpty)
    }

    /// Gesunde Datei: Der Hilfsprozess liefert dasselbe wie die Erfassung im
    /// eigenen Prozess – für beide Backends, die PDFKit benutzen.
    @Test(arguments: [PDFSemanticSnapshot.Backend.merged, .pdfKit])
    func hilfsprozessLiefertDasselbeWieDerEigeneProzess(backend: PDFSemanticSnapshot.Backend) throws {
        let input = try SingleSourceAssemblyE2ETests.leakyDocument()
        defer { try? FileManager.default.removeItem(at: input) }
        let viaProbe = try PDFSemanticSnapshot.capture(input, backend: backend)
        let inProcess = try PDFSemanticSnapshot.captureInProcess(input, backend: backend)
        #expect(viaProbe == inProcess)
        #expect(viaProbe.pageCount == 5)
        #expect(viaProbe.pages.allSatisfy { $0.textCharacterCount > 0 })
    }

    /// Nicht lesbare Datei: derselbe Fehler wie bisher, kein „Hilfsprozess
    /// gescheitert".
    @Test func nichtLesbareDateiMeldetDenBisherigenFehler() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("n16-kein-pdf-\(UUID().uuidString).pdf")
        try Data("kein PDF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: CocoaError.self) { try PDFSemanticSnapshot.capture(url) }
    }

    /// Der Hilfsprozess erbt nichts, womit er unter XCTest selbst Tests laden
    /// oder fremde Bibliotheken einschleusen würde.
    @Test func umgebungDesHilfsprozessesIstBereinigt() {
        let child = FrameworkProbe.childEnvironment(from: [
            "HOME": "/Users/x", "TMPDIR": "/tmp/", "PATH": "/usr/bin",
            "DYLD_INSERT_LIBRARIES": "/x/libXCTestBundleInject.dylib",
            "XCTestConfigurationFilePath": "/x.xctestconfiguration",
            "XCInjectBundleInto": "/x", "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/x"])
        #expect(Set(child.keys) == ["HOME", "TMPDIR", "PATH"])
    }

    /// Unbekannte oder unvollständige Aufrufe enden mit dem Aufruf-Fehlercode,
    /// ohne etwas zu schreiben.
    @Test func falscherAufrufDesHilfsprozesses() {
        #expect(ProbeMode.run([]) == FrameworkProbe.ExitCode.usage)
        #expect(ProbeMode.run(["snapshot", "/x.pdf"]) == FrameworkProbe.ExitCode.usage)
        #expect(ProbeMode.run(["unbekannt", "a", "b", "c"]) == FrameworkProbe.ExitCode.usage)
    }

    /// Endet der Aufrufer, während der Hilfsprozess hängt, endet auch der
    /// Hilfsprozess: Er liest auf seiner Standardeingabe und geht beim
    /// Dateiende. Sonst bliebe nach dem Beenden der App ein Prozess zurück,
    /// der weiter einen Kern belegt.
    @Test(.timeLimit(.minutes(2)), .needsLocalFiles("tmp/fuzz-findings/hang-107468.pdf"))
    func hilfsprozessEndetMitSeinemAufrufer() throws {
        let hang = LocalTestData.repoRoot.appendingPathComponent("tmp/fuzz-findings/hang-107468.pdf")
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("n16-waise-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: result) }
        let process = Process()
        process.executableURL = try #require(FrameworkProbe.executableURL())
        process.arguments = ["--probe", "snapshot", hang.path, "merged", result.path]
        process.environment = FrameworkProbe.childEnvironment()
        let lifeline = Pipe()
        process.standardInput = lifeline
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Der Prozess hängt an dieser Datei (über 150 s). Jetzt „stirbt" der Aufrufer.
        #expect(exited.wait(timeout: .now() + 3) == .timedOut, "Die Datei hängt nicht mehr – Test prüft nichts")
        try lifeline.fileHandleForWriting.close()
        let gone = exited.wait(timeout: .now() + 5) == .success
        if !gone { kill(process.processIdentifier, SIGKILL) }
        #expect(gone, "Der Hilfsprozess lief nach dem Ende des Aufrufers weiter")
    }

    /// Wie macOS den Prozess `pid` führt: "Foreground" (eigenes Dock-Symbol),
    /// "UIElement", "BackgroundOnly" – oder nil, solange er nicht angemeldet ist.
    static func launchServicesType(of pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let line = text.split(separator: "\n").first(where: { $0.contains("pid = \(pid) ") }),
              let start = line.range(of: "type=\"") else { return nil }
        return String(line[start.upperBound...].prefix { $0 != "\"" })
    }

    /// Befund der Release-Messung (19.11.): Der Hilfsprozess liegt im
    /// App-Bundle. Sobald PDFKit in ihm die Verbindung zum Fensterserver
    /// aufbaut, meldet macOS ihn als normales Programm an (`lsappinfo`:
    /// type="Foreground", in der Liste der sichtbaren Programme) – bei jedem
    /// Komprimieren erschiene ein zweites PDFdownsize-Symbol im Dock.
    ///
    /// Der Prozess hängt an der Datei, bis der Test ihn beendet; in dieser
    /// Zeit wird laufend abgefragt, wie macOS ihn führt.
    @Test(.timeLimit(.minutes(2)), .needsLocalFiles("tmp/fuzz-findings/hang-107468.pdf"))
    func hilfsprozessErscheintNichtImDock() throws {
        let hang = LocalTestData.repoRoot.appendingPathComponent("tmp/fuzz-findings/hang-107468.pdf")
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("n16-dock-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: result) }
        let process = Process()
        process.executableURL = try #require(FrameworkProbe.executableURL())
        process.arguments = ["--probe", "snapshot", hang.path, "merged", result.path]
        process.environment = FrameworkProbe.childEnvironment()
        let lifeline = Pipe()
        process.standardInput = lifeline
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? lifeline.fileHandleForWriting.close()
            process.waitUntilExit()
        }

        var seen: Set<String> = []
        var samples = 0
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, process.isRunning {
            if let type = Self.launchServicesType(of: process.processIdentifier) { seen.insert(type) }
            samples += 1
            usleep(20_000)
        }
        #expect(process.isRunning, "Die Datei hängt nicht mehr – Test prüft nichts")
        #expect(samples > 20)
        #expect(!seen.contains("Foreground"),
                "Der Hilfsprozess war als normales Programm angemeldet (Dock-Symbol): \(seen.sorted())")
    }
}
