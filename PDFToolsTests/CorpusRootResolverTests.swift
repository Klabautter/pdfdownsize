import Testing
import Foundation
@testable import PDFTools

/// Phase 9.3 – die Auflösungsreihenfolge und ihre Fehlerfälle.
///
/// Alle Fälle laufen gegen EINGESPEISTE Umgebungen, nicht gegen die echte:
/// Ein Test, der von `ProcessInfo` abhängt, misst die Maschine des
/// Ausführenden statt den Code.
@Suite struct CorpusRootResolverTests {

    @Test func argumentSchlaegtUmgebung() {
        let r = CorpusRootResolver.resolve(
            argument: "/tmp/aus-argument",
            env: ["PDFTOOLS_CORPUS_ROOT": "/tmp/aus-umgebung"])
        #expect(r.root.path == "/tmp/aus-argument")
        #expect(r.source == "argument")
    }

    @Test func umgebungSchlaegtVorgabe() {
        let r = CorpusRootResolver.resolve(
            env: ["PDFTOOLS_CORPUS_ROOT": "/tmp/aus-umgebung"])
        #expect(r.root.path == "/tmp/aus-umgebung")
        #expect(r.source == "env:PDFTOOLS_CORPUS_ROOT")
    }

    @Test func vorgabeWennNichtsGesetzt() {
        let r = CorpusRootResolver.resolve(env: [:])
        #expect(r.root.path == CorpusRootResolver.fallbackPath)
        #expect(r.source.hasPrefix("default:"))
    }

    /// Eine leer gesetzte Variable ist keine Angabe. Ohne diese Regel würde
    /// `PDFTOOLS_CORPUS_ROOT=` als Pfad "" gelesen und zum Wurzelverzeichnis
    /// aufgelöst – der Lauf liefe dann über die ganze Platte.
    @Test(arguments: ["", "   ", "\n"])
    func leereAngabenWerdenUebersprungen(_ blank: String) {
        let viaEnv = CorpusRootResolver.resolve(
            env: ["PDFTOOLS_CORPUS_ROOT": blank])
        #expect(viaEnv.source.hasPrefix("default:"))
        let viaArg = CorpusRootResolver.resolve(argument: blank, env: [:])
        #expect(viaArg.source.hasPrefix("default:"))
    }

    @Test func tildeWirdAufgeloest() {
        let r = CorpusRootResolver.resolve(argument: "~/Korpus", env: [:])
        #expect(!r.root.path.contains("~"))
        #expect(r.root.path.hasSuffix("/Korpus"))
    }

    @Test func fehlendeWurzelMeldetKlarenFehler() {
        #expect(throws: CorpusRootResolver.Failure.self) {
            try CorpusRootResolver.resolveValidated(
                argument: "/tmp/gibt-es-nicht-\(UUID().uuidString)", env: [:])
        }
    }

    /// Die Meldung muss den Pfad UND seine Herkunft nennen. Ohne die
    /// Herkunft steht der Leser vor der Frage, welche der drei Ebenen den
    /// falschen Wert geliefert hat.
    @Test func fehlermeldungNenntPfadUndHerkunft() {
        let path = "/tmp/gibt-es-nicht-\(UUID().uuidString)"
        do {
            _ = try CorpusRootResolver.resolveValidated(
                env: ["PDFTOOLS_CORPUS_ROOT": path])
            Issue.record("hätte werfen müssen")
        } catch let failure as CorpusRootResolver.Failure {
            #expect(failure.description.contains(path))
            #expect(failure.description.contains("PDFTOOLS_CORPUS_ROOT"))
        } catch {
            Issue.record("falscher Fehlertyp: \(error)")
        }
    }

    /// Eine DATEI als Wurzel ist ein anderer Fehler als eine fehlende – und
    /// muss anders heissen, sonst sucht der Leser am falschen Ort.
    @Test func dateiStattVerzeichnisMeldetEigenenFehler() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("wurzel-\(UUID().uuidString).txt")
        try Data("kein Verzeichnis".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try CorpusRootResolver.resolveValidated(
                argument: file.path, env: [:])
            Issue.record("hätte werfen müssen")
        } catch let failure as CorpusRootResolver.Failure {
            guard case .notADirectory = failure else {
                Issue.record("falscher Fall: \(failure)")
                return
            }
        }
    }

    @Test func vorhandeneWurzelGehtDurch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wurzel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CorpusRootResolver.resolveValidated(argument: dir.path, env: [:])
        #expect(r.root.path == dir.path)
    }

    /// Der Runner darf keine ZWEITE Auflösung mitbringen – sonst laufen
    /// Skripte und Tests auseinander, ohne dass es jemandem auffällt.
    @Test func runnerBenutztDenselbenResolver() {
        let env = ["PDFTOOLS_CORPUS_ROOT": "/tmp/geteilte-wurzel"]
        let viaRunner = CorpusRunnerCore.Config.resolveEnvironment(env)
        let viaResolver = CorpusRootResolver.resolve(env: env)
        #expect(viaRunner.root == viaResolver.root)
        #expect(viaRunner.source == viaResolver.source)
    }
}
