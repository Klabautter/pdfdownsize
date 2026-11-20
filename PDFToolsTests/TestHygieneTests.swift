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

    /// Masterplan N8: Jeder Eintrag der Gate-Liste muss eine Suite sein.
    /// `HardeningTests` war ein Dateiname; `-only-testing` fuhr dafür null
    /// Tests, und das Gate meldete trotzdem grün.
    @Test func gateListeNenntNurSuiten() throws {
        let root = Self.testDirectory().deletingLastPathComponent()
        let list = try String(contentsOf: root.appendingPathComponent("Scripts/release-gate-suites.txt"),
                              encoding: .utf8)
        let names = list.split(separator: "\n").compactMap { line -> String? in
            let name = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        #expect(!names.isEmpty)
        var declared = Set<String>()
        let pattern = try NSRegularExpression(pattern: #"(?:struct|class|final class|enum)\s+([A-Za-z0-9_]+)"#)
        for file in Self.swiftFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) { declared.insert(String(text[r])) }
            }
        }
        let missing = names.filter { !declared.contains($0) }
        #expect(missing.isEmpty, "Keine Suite dieses Namens: \(missing.joined(separator: ", "))")
    }

    /// Masterplan D4: Keine C++-Ausnahme verlässt die C-Grenze. Jede im
    /// Header deklarierte Funktion beginnt mit PDFCORE_GUARD_BEGIN – eine neue
    /// Funktion ohne Hülle fällt hier auf, nicht erst als Absturz.
    @Test func jederExportIstEingehuellt() throws {
        let src = Self.testDirectory().deletingLastPathComponent()
            .appendingPathComponent("Vendor/pdfcore/src")
        let header = try String(contentsOf: src.appendingPathComponent("pdfcore.h"), encoding: .utf8)
        let source = try String(contentsOf: src.appendingPathComponent("pdfcore.cc"), encoding: .utf8)
        let result = Self.unguardedExports(header: header, source: source)
        #expect(result.declared > 50, "Header-Analyse fand nur \(result.declared) Funktionen")
        #expect(result.unguarded.isEmpty, "Ohne PDFCORE_GUARD: \(result.unguarded)")
    }

    /// N14 (D4): Das alte Muster `name\([\s\S]*?\)\s*\{\s*PDFCORE_GUARD_BEGIN`
    /// lief über das Ende der Definition hinaus bis zur nächsten eingehüllten
    /// Funktion – eine fehlende Hülle fiel nie auf. Jetzt: die Definition
    /// (Parameterliste ohne `;`, `{`, `}`, danach `{`) muss DIREKT mit der
    /// Hülle beginnen; fehlt die Definition, zählt das ebenfalls.
    static func unguardedExports(header rawHeader: String, source: String)
        -> (declared: Int, unguarded: [String]) {
        let header = rawHeader.replacingOccurrences(of: #"/\*[\s\S]*?\*/|//[^\n]*"#, with: "",
                                                    options: .regularExpression)
        let declared = Set(header.matches(of: /\b(pdfcore_[a-z0-9_]+)\(/).map { String($0.1) })
        var unguarded: [String] = []
        for name in declared.sorted() {
            // Definitionen beginnen am Zeilenanfang mit dem Rückgabetyp;
            // eingerückte Aufrufe (`if (pdfcore_x(a)) {`) zählen nicht.
            let definition = "(?m)^[A-Za-z_][^(\\n;=]*\\b" + name + "\\([^;{}]*\\)\\s*\\{"
            guard let range = source.range(of: definition, options: .regularExpression) else {
                unguarded.append(name)
                continue
            }
            let rest = source[range.upperBound...].drop { $0.isWhitespace }
            if !rest.hasPrefix("PDFCORE_GUARD_BEGIN") { unguarded.append(name) }
        }
        return (declared.count, unguarded)
    }

    /// Die Prüfung selbst erkennt eine fehlende Hülle (vorher nicht).
    @Test func huellenPruefungErkenntFehlendeHuelle() {
        let header = "int pdfcore_a(int x);\nint pdfcore_b(int y);\n"
        let source = """
            int pdfcore_a(int x)
            {
                return x;
            }
            int pdfcore_b(int y)
            {
                PDFCORE_GUARD_BEGIN
                return y;
                PDFCORE_GUARD_END(0)
            }
            """
        #expect(Self.unguardedExports(header: header, source: source).unguarded == ["pdfcore_a"])
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
