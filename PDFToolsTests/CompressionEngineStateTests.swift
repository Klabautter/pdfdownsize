import Testing
import Foundation
@testable import PDFTools

/// Masterplan Finding 7 – Quality Gate des Engine-Zustands.
///
///   □ Engine-Zustand eindeutig dokumentiert
///   □ kein widersprüchlicher Default
///   □ Release kann keine unzertifizierte Engine ausliefern
@Suite struct CompressionEngineStateTests {

    /// Es darf genau EINEN Default geben: den aus `CompressionEngineState`.
    /// Ein zweiter, im Compressor hartcodierter Default wäre exakt der
    /// Widerspruch, den Finding 7 beschreibt.
    @Test func compressorDefaultComesFromEngineState() throws {
        let source = try Self.projectSource("PDFTools/Compressor.swift")

        #expect(source.contains("engine: CompressionEngine = CompressionEngineState.production"),
                "Compressor-Default muss aus CompressionEngineState stammen")
        // Kein hartcodierter Case als Default-Wert eines Parameters.
        #expect(!source.contains("CompressionEngine = .libqpdf"),
                "Hartcodierter Engine-Default im Compressor gefunden")
        #expect(!source.contains("CompressionEngine = .legacySmart"),
                "Hartcodierter Engine-Default im Compressor gefunden")
    }

    /// Es gibt keinen Fallback, weil es keinen zweiten Pfad mehr gibt.
    ///
    /// Zuvor prüfte dieser Test, dass der Produktionspfad bei Fehlern nicht
    /// still auf den Legacy-Pfad zurückfällt (Masterplan 2.2 „Keine
    /// kurzfristigen Fallback-Hacks"). Seit dessen Entfernung ist die Frage
    /// konstruktiv beantwortet: Das Enum hat genau einen Fall.
    @Test func thereIsExactlyOneCompressionPath() throws {
        #expect(CompressionEngineState.production == .libqpdf)

        // Auch im Quelltext darf kein zweiter Pfad zurückkehren – geprüft
        // ohne Kommentarzeilen, weil die Begründung im Code den entfernten
        // Namen nennt und ein Test, der Erklärungen als Code zählt, das
        // Falsche misst.
        let code = try Self.projectSource("PDFTools/Compressor.swift")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("legacySmart"),
                "Der Legacy-Kompressionspfad ist zurück")
        #expect(!code.contains("SmartCompressor.compressImages"),
                "Die Legacy-Bildoptimierung wird wieder aufgerufen")
    }

    /// Solange die Engine nicht zertifiziert ist, MUSS release-check.sh
    /// fehlschlagen. Der Test führt das echte Skript aus – nicht eine
    /// nachgebaute Kopie seiner Logik.
    /// Zeitlimit: Ein Test, der einen fremden Prozess startet, darf die Suite
    /// nicht anhalten können. Ohne Limit blieb hier zweimal der gesamte Lauf
    /// stehen – ohne Fehlermeldung, ohne Ergebnis für alles Nachfolgende.
    @Test(.hangGuard) func releaseCheckBlocksUncertifiedEngine() throws {
        let script = try Self.sourceSnapshot()
            .appendingPathComponent("Scripts/release-check.sh")
        try #require(FileManager.default.isExecutableFile(atPath: script.path),
                     "release-check.sh fehlt oder ist nicht ausführbar")

        // Die Ausgabe geht in eine DATEI, nicht in eine Pipe.
        //
        // Mit `Pipe()` blieb dieser Test stehen: `readDataToEndOfFile()`
        // blockiert den aufrufenden Thread, und in einem Swift-Testing-Test
        // ist das ein Thread des Cooperative Pools. Derselbe Code ausserhalb
        // des Testkontexts läuft durch (gemessen: 845 Bytes, Status 1) –
        // gehangen hat er ausschliesslich im Test. Zweimal riss er dabei die
        // ganze Suite mit, ohne eine einzige Meldung.
        //
        // Über eine Datei gibt es weder Pipe-Puffer noch EOF-Bedingung noch
        // blockierendes Lesen: Der Prozess läuft, endet, danach wird gelesen.
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-check-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputFile) }
        let handle = try FileHandle(forWritingTo: outputFile)

        let process = Process()
        process.executableURL = script
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        // stdin ins Leere: Sonst erbt der Kindprozess das Terminal des
        // Testrunners, und ein Befehl, der von stdin liest, wartet dort
        // unbegrenzt.
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try? handle.close()

        let output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""

        if CompressionEngineState.compressionCoreCertified {
            #expect(output.contains("Compression Core Certified = true"))
        } else {
            #expect(output.contains("Compression Core Certified = false"),
                    "release-check meldet den Zertifizierungsstand nicht")
            #expect(process.terminationStatus != 0,
                    "release-check lässt eine unzertifizierte Engine durch")
            // Die offenen Gates müssen benannt sein – „blockiert" ohne Grund
            // ist für den nächsten Bearbeiter wertlos.
            for blocker in CompressionEngineState.certificationBlockers {
                #expect(output.contains(blocker), "Blocker fehlt im Report: \(blocker)")
            }
        }
    }

    /// Der Name darf nicht mehr versprechen, als der Gate-Stand hergibt –
    /// und nicht weniger.
    ///
    /// Vor der Zertifizierung hiess der Pfad `libqpdfPrototype`; die
    /// Bezeichnung sollte genau so lange stehen, bis die Parität bewiesen ist
    /// (Masterplan Schritt 11: umbenennen „nur wenn kein Prototype mehr").
    /// Jetzt ist sie gefallen, und der Test prüft die Gegenrichtung: Ein
    /// zertifizierter Pfad darf keinen Vorbehalt mehr im Namen tragen.
    @Test func namingMatchesCertificationState() {
        let name = CompressionEngineState.production.rawValue
        if CompressionEngineState.compressionCoreCertified {
            #expect(!name.lowercased().contains("prototype"), """
                Zertifiziert, aber der Pfad heisst weiterhin „\(name)" – der \
                Name trägt einen Vorbehalt, den der Gate-Stand nicht mehr hat.
                """)
        } else {
            #expect(name.lowercased().contains("prototype"), """
                Nicht zertifiziert, aber der Pfad heisst „\(name)" – der Name \
                verspricht mehr, als der Gate-Stand hergibt.
                """)
        }
    }

    // MARK: - Helfer

    // MARK: - Zugriff auf die geprüften Quellen

    /// Verzeichnis mit dem Quellabzug, den die Build-Phase „Quellabzug für
    /// Gate-Tests" bei jedem Bau neu anlegt.
    ///
    /// Die Tests lesen NICHT aus dem Projektverzeichnis. Der Test-Host ist
    /// eine sandboxed App; liegt das Projekt unter ~/Desktop, ist es
    /// TCC-geschützt und jeder Lesezugriff des Testprozesses BLOCKIERT dort,
    /// statt zu scheitern. Gemessen: Lesen aus `$TMPDIR` 0.001 s, Lesen
    /// derselben Datei unter ~/Desktop lief ins Zeitlimit. Ohne Zeitlimit
    /// hielt das die gesamte Suite an – ohne Meldung, ohne Ergebnis für alles
    /// Nachfolgende.
    ///
    /// Der Abzug liegt in `BUILT_PRODUCTS_DIR` (DerivedData, nicht
    /// TCC-geschützt) und entsteht bei jedem Bau neu – er ist damit exakt der
    /// Stand, der auch kompiliert wurde, und kann nicht veralten.
    static func sourceSnapshot() throws -> URL {
        // Das Testbundle liegt je nach Konfiguration direkt in
        // BUILT_PRODUCTS_DIR oder eingebettet in der Host-App
        // (…/PDFTools.app/Contents/PlugIns/PDFToolsTests.xctest). Statt eine
        // feste Ebenenzahl anzunehmen, wird nach oben gesucht.
        var directory = Bundle(for: BundleAnchor.self).bundleURL
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("SourceSnapshot")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        throw SnapshotError.missing(Bundle(for: BundleAnchor.self).bundleURL.path)
    }

    enum SnapshotError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self {
            case .missing(let path):
                return """
                    Quellabzug fehlt: \(path)
                    Die Build-Phase „Quellabzug für Gate-Tests" hat nicht \
                    gelaufen – ohne sie können die Gate-Tests die Quellen \
                    nicht prüfen.
                    """
            }
        }
    }

    /// Ankerklasse, um das Testbundle zu finden.
    final class BundleAnchor {}

    static func projectSource(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceSnapshot().appendingPathComponent(relativePath),
                   encoding: .utf8)
    }
}
