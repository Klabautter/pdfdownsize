import Testing
import Foundation
@testable import PDFTools

/// Gate für den Quellabzug, aus dem die statischen Prüfungen lesen.
///
/// Vorgeschichte: Der Test-Host ist eine sandboxed App, und die Tests laufen
/// in ihr. Liegt das Projekt unter ~/Desktop, ist es TCC-geschützt – und ein
/// Lesezugriff des Testprozesses darauf BLOCKIERT, statt zu scheitern.
/// Gemessen: Lesen aus `$TMPDIR` 0.001 s, Lesen derselben Datei unter
/// ~/Desktop lief in das Zeitlimit von 60 s. Ohne Zeitlimit hielt ein
/// einzelner solcher Test die gesamte Suite an – ohne Meldung, ohne Ergebnis
/// für alles Nachfolgende. Zwei Läufe endeten so.
///
/// Seither kopiert die Build-Phase „Quellabzug für Gate-Tests" die geprüften
/// Quellen nach `BUILT_PRODUCTS_DIR/SourceSnapshot` (DerivedData, nicht
/// TCC-geschützt). Diese Suite stellt sicher, dass der Abzug existiert, den
/// gebauten Stand enthält und dass niemand versehentlich zum direkten
/// Projektzugriff zurückkehrt.
@Suite struct SourceSnapshotGateTests {

    @Test(.hangGuard) func snapshotExistsAndIsReadable() throws {
        let snapshot = try CompressionEngineStateTests.sourceSnapshot()
        let expected = ["PDFTools/CompressionEngineState.swift",
                        "PDFTools/Compressor.swift",
                        "PDFTools/CompressionEstimator.swift",
                        "PDFTools/PageTools/PageAssemblyService.swift",
                        "Scripts/release-check.sh"]
        for relative in expected {
            let url = snapshot.appendingPathComponent(relative)
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "Quellabzug unvollständig: \(relative) fehlt")
        }
    }

    /// Der Abzug muss den GEBAUTEN Stand zeigen. Eine veraltete Kopie wäre
    /// schlimmer als keine: Die Gate-Tests würden dann Code prüfen, der so
    /// nicht mehr existiert.
    @Test(.hangGuard) func snapshotMatchesCompiledState() throws {
        let source = try CompressionEngineStateTests
            .projectSource("PDFTools/CompressionEngineState.swift")

        // Was der Abzug behauptet, muss zu dem passen, was einkompiliert ist.
        let certifiedInSource = source.contains(
            "static let compressionCoreCertified = true")
        #expect(certifiedInSource == CompressionEngineState.compressionCoreCertified,
                """
                Der Quellabzug ist nicht der gebaute Stand: Abzug sagt \
                certified=\(certifiedInSource), einkompiliert ist \
                \(CompressionEngineState.compressionCoreCertified).
                """)

        for blocker in CompressionEngineState.certificationBlockers {
            #expect(source.contains(blocker),
                    "Blocker fehlt im Abzug: \(blocker)")
        }
    }

    /// Schreiben in das eigene Temp-Verzeichnis muss funktionieren – daran
    /// hängt jede Fixture. Ohne diese Gegenprobe wüsste man bei einem
    /// Fehlschlag oben nicht, ob der Abzug fehlt oder der Testprozess
    /// generell keine Dateien lesen kann.
    @Test(.hangGuard) func temporaryDirectoryIsUsable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).txt")
        try "hallo".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "hallo")
    }
}
