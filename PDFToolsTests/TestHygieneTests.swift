import Testing
import Foundation
import CryptoKit
import pdfcore

/// Phase 10 – Entwicklersonden dürfen nicht im Testbaum liegenbleiben.
///
/// DER ANLASS
///
/// `IPCCCheck.swift` lag drei Tage im Baum: eine Sonde, die den 404 MB
/// grossen IPCC-Bericht komprimierte, mit fest verdrahtetem Dokumentpfad
/// und einem Ausgabepfad in ein Sitzungsverzeichnis, das es auf keiner
/// anderen Maschine gibt. Sie lief bei JEDER vollen Regression mit und
/// kostete dort neun Minuten – und niemandem fiel auf, warum die Suite
/// plötzlich so lange brauchte, weil die Sonde ja bestand.
///
/// Eine Sonde ist ein legitimes Werkzeug. Sie im Baum zu vergessen ist der
/// Fehler, und genau den findet diese Prüfung.
@Suite struct TestHygieneTests {

    static func testDirectory(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    }

    static func swiftFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: testDirectory(), includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    /// Ein Pfad in ein Sitzungs- oder Ablageverzeichnis gehört nie in eine
    /// eingecheckte Testdatei – er existiert nur auf einer Maschine.
    @Test func keineSitzungspfadeInTests() {
        var offenders: [String] = []
        // Die eigene Datei bleibt aussen vor: Die Suchmuster stehen hier als
        // Zeichenketten und wären sonst ihr eigener erster Fund.
        for file in Self.swiftFiles()
            where file.lastPathComponent != "TestHygieneTests.swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() where line.contains("/private/tmp/claude-")
                                 || line.contains("/var/folders/") {
                offenders.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        #expect(offenders.isEmpty, """
            Sitzungspfade in Testdateien: \(offenders.joined(separator: ", ")).
            Solche Pfade existieren nur auf einer Maschine. Für Ausgaben \
            gehört `FileManager.default.temporaryDirectory` hin.
            """)
    }

    /// Ein Test mit der langen Zeitgrenze darf nicht ungefragt laufen.
    ///
    /// `.measurementRun` erlaubt 60 Minuten. Wer sie braucht, misst etwas
    /// Grosses – und das gehört hinter eine ausdrückliche Anforderung,
    /// sonst zahlt sie jeder Regressionslauf mit.
    @Test func langlaeufigeTestsSindAngefordert() {
        var offenders: [String] = []
        for file in Self.swiftFiles() where file.lastPathComponent != "TestTimeouts.swift"
                                          && file.lastPathComponent != "TestHygieneTests.swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  text.contains(".measurementRun") else { continue }
            // Irgendwo in derselben Datei muss eine Umgebungsabfrage stehen.
            let gated = text.contains("ProcessInfo.processInfo.environment")
            if !gated { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, """
            Langläufige Tests ohne Anforderung: \(offenders.joined(separator: ", ")).
            Sie kosten jeden Regressionslauf Zeit, ohne dass jemand darum \
            gebeten hat. Muster: eine Abfrage auf eine Umgebungsvariable, \
            wie in CompressionAccuracyLab.swift.
            """)
    }

    /// Die gelinkte Bridge muss zum Quelltext passen (Masterplan G4).
    ///
    /// `Vendor/pdfcore/src/pdfcore.cc` wird nicht vom Xcode-Build übersetzt –
    /// gelinkt wird `Vendor/pdfcore/lib/libpdfcore.a`, die
    /// `Scripts/build-pdfcore.sh` erzeugt. Wer den Quelltext ändert und den
    /// Rebuild vergisst, testet gegen die ALTE Bridge: Der Build ist grün,
    /// die Tests laufen, und die Änderung ist einfach nicht da.
    ///
    /// Früher verglich dieser Test Änderungszeiten; ein `git checkout` oder
    /// Kopieren setzt die aber beliebig. Jetzt trägt die Bibliothek den
    /// SHA-256 ihres Quelltexts, und der Test rechnet ihn nach.
    @Test func bridgeBibliothekPasstZumQuelltext() throws {
        let root = Self.testDirectory().deletingLastPathComponent()
        let src = root.appendingPathComponent("Vendor/pdfcore/src")
        var data = try Data(contentsOf: src.appendingPathComponent("pdfcore.cc"))
        data.append(try Data(contentsOf: src.appendingPathComponent("pdfcore.h")))
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let linked = String(cString: pdfcore_source_hash())
        #expect(linked == expected, """
            Die gelinkte libpdfcore.a stammt aus einem anderen Quelltext \
            (gelinkt \(linked.prefix(12)), Quelle \(expected.prefix(12))). \
            Abhilfe: Scripts/build-pdfcore.sh
            """)
    }

    /// Ein fester Dokumentpfad im Korpus ist eine Sonde, kein Test: Auf
    /// einer Maschine ohne dieses Dokument schlägt sie fehl oder – schlimmer
    /// – besteht stillschweigend, ohne etwas geprüft zu haben.
    @Test func keineFestenDokumentpfadeInTests() {
        var offenders: [String] = []
        for file in Self.swiftFiles() where file.lastPathComponent != "TestHygieneTests.swift"
                                          && file.lastPathComponent != "CorpusRootResolver.swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() where line.contains("/Users/") && line.contains(".pdf") {
                offenders.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        #expect(offenders.isEmpty, """
            Feste Dokumentpfade in Testdateien: \(offenders.joined(separator: ", ")).
            Korpusdokumente werden über CorpusRootResolver gefunden.
            """)
    }
}
