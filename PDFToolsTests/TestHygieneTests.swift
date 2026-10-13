import Testing
import Foundation

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

    /// Die Bridge-Bibliothek muss NEUER sein als ihr Quelltext.
    ///
    /// `Vendor/pdfcore/src/pdfcore.cc` wird nicht vom Xcode-Build übersetzt –
    /// gelinkt wird `Vendor/pdfcore/lib/libpdfcore_universal.a`, die
    /// `Scripts/build-pdfcore.sh` erzeugt. Wer den Quelltext ändert und den
    /// Rebuild vergisst, testet gegen die ALTE Bridge: Der Build ist grün,
    /// die Tests laufen, und die Änderung ist einfach nicht da. Kein Fehler
    /// weist darauf hin.
    @Test func bridgeBibliothekIstNichtVeraltet() {
        let root = Self.testDirectory().deletingLastPathComponent()
        let source = root.appendingPathComponent("Vendor/pdfcore/src/pdfcore.cc")
        let library = root.appendingPathComponent(
            "Vendor/pdfcore/lib/libpdfcore_universal.a")
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path),
              fm.fileExists(atPath: library.path) else { return }

        func modified(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        }
        guard let sourceDate = modified(source), let libraryDate = modified(library)
        else { return }

        // Eine Sekunde Spielraum: Beide entstehen im selben Arbeitsgang, und
        // Dateisystem-Zeitstempel sind nicht feiner aufgelöst als nötig.
        #expect(libraryDate.timeIntervalSince(sourceDate) >= -1, """
            libpdfcore_universal.a ist älter als pdfcore.cc \
            (\(libraryDate) gegenüber \(sourceDate)). Die Tests laufen gegen \
            eine veraltete Bridge. Abhilfe: Scripts/build-pdfcore.sh
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
