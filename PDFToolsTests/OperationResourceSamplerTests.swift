import Testing
import Foundation
@testable import PDFTools

/// Phase 8.6 – der Abtaster muss messen, nicht bloss Zahlen liefern.
///
/// Ein Messwerkzeug, das immer null meldet, besteht jeden Test, der nur
/// prüft, DASS ein Wert da ist. Diese Tests belegen deshalb, dass sich der
/// gemeldete Wert ÄNDERT, wenn sich das Gemessene ändert.
@Suite struct OperationResourceSamplerTests {

    @Test(.hangGuard) func meldetPlattenplatzDesArbeitsverzeichnisses() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampler = OperationResourceSampler(workspace: dir)
        let payload = Data(repeating: 0x41, count: 4 * 1_048_576)   // 4 MB
        try payload.write(to: dir.appendingPathComponent("zwischen.bin"))
        let usage = sampler.finish()

        #expect(usage.peakWorkspaceBytes >= 4 * 1_048_576, """
            Zwischendateien nicht erfasst: \(usage.peakWorkspaceBytes) Bytes \
            bei 4 MB geschriebener Datei.
            """)
    }

    /// Auch eine Operation, die kürzer dauert als ein Abtastintervall, muss
    /// ihren Plattenverbrauch melden – deshalb misst `finish()` noch einmal.
    @Test(.hangGuard) func kurzeOperationVerliertDenPlattenwertNicht() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampler-kurz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampler = OperationResourceSampler(workspace: dir)
        try Data(repeating: 0x42, count: 1_048_576).write(
            to: dir.appendingPathComponent("kurz.bin"))
        let usage = sampler.finish()          // sofort, ohne Wartezeit
        #expect(usage.peakWorkspaceBytes >= 1_048_576,
                "Schlussmessung fehlt: \(usage.peakWorkspaceBytes) Bytes")
    }

    @Test func ohneArbeitsverzeichnisKeinPlattenwert() {
        let usage = OperationResourceSampler(workspace: nil).finish()
        #expect(usage.peakWorkspaceBytes == -1)
    }

    /// Ein fehlendes Verzeichnis ist kein Fehler – es entsteht erst, wenn
    /// die Operation etwas schreibt.
    @Test func fehlendesVerzeichnisErgibtNull() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gibt-es-nicht-\(UUID().uuidString)", isDirectory: true)
        #expect(OperationResourceSampler.directoryBytes(missing) == 0)
    }

    @Test(.hangGuard) func speicherwertIstPlausibel() {
        let sampler = OperationResourceSampler(workspace: nil)
        // Etwas Arbeit, damit die Abtastung mindestens einmal zum Zug kommt.
        var sink = 0
        for i in 0..<2_000_000 { sink &+= i }
        _ = sink
        let usage = sampler.finish()
        // Der Testprozess selbst belegt zweistellige MB – ein Wert von 0
        // hiesse, dass gar nicht gemessen wurde.
        #expect(usage.peakFootprintMB > 0,
                "Speicher nicht gemessen: \(usage.peakFootprintMB) MB")
        #expect(usage.peakFootprintMB < 100_000, "unglaubwürdig hoch")
    }

    /// Alte Journalzeilen kennen die beiden Felder nicht. Sie müssen sich
    /// weiterhin lesen lassen, sonst wäre jeder Teilbericht aus einem
    /// früheren Lauf verloren.
    @Test func alteJournalzeileBleibtLesbar() throws {
        let json = """
            {"fixture":"a.pdf","fixtureClass":"synthetic","operation":"compress",\
            "status":"PASS","durationMs":12.5,"pagesIn":1,"pagesOut":1,\
            "inputBytes":100,"outputBytes":80,"qpdfCheck":"PASS","messages":[]}
            """
        let row = try JSONDecoder().decode(
            CorpusRunnerCore.OperationRow.self, from: Data(json.utf8))
        #expect(row.fixture == "a.pdf")
        #expect(row.peakFootprintMB == nil)
        #expect(row.peakWorkspaceBytes == nil)
    }
}
