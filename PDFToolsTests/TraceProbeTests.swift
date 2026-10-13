import Testing
import Foundation
@testable import PDFTools

/// Phase V2-1 (§7.4) – Resource Trace.
///
/// Festgenagelt: Bei aktivierter Umgebung (`PDFTOOLS_COMPRESSION_TRACE=1`)
/// entsteht neben dem Output ein `<name>.trace.json` mit Schema-Kopf,
/// Pass-Attribution und mindestens einem Resource-Eintrag; ohne Umgebung
/// wird keine Tracedatei geschrieben (Produktionslauf bleibt spurlos).
/// Die Aktivierung setzt das Flag testintern – der `defer` räumt die
/// Umgebung wieder auf, damit kein Paralleltest den Trace erbt.
@Suite struct TraceProbeTests {
    @Test(.hangGuard) func traceWirdBeiEnvGeschrieben() throws {
        try EnvironmentMutex.with {
            setenv("PDFTOOLS_COMPRESSION_TRACE", "1", 1)
            defer { unsetenv("PDFTOOLS_COMPRESSION_TRACE") }
            #expect(CompressionTraceWriter.isEnabled)
            let url = try PDFFixtures.dedupStreamsPDF(pages: 2)
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try Compressor().compress(inputURL: url, mode: .smart)
            let traceURL = result.outputURL.deletingPathExtension()
                .appendingPathExtension("trace.json")
            defer { try? FileManager.default.removeItem(at: traceURL) }
            let data = try #require(try? Data(contentsOf: traceURL),
                                    "Trace-JSON fehlt neben dem Output")
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(object?["schema"] as? Int == 1)
            let resources = object?["resources"] as? [[String: Any]] ?? []
            #expect(!resources.isEmpty, "Trace braucht Resource-Einträge")
            #expect(object?["pass_attribution"] != nil)
        }
    }

    @Test(.hangGuard) func ohnehEnvKeinTrace() throws {
        try EnvironmentMutex.with {
            unsetenv("PDFTOOLS_COMPRESSION_TRACE")
            unsetenv("TEST_RUNNER_PDFTOOLS_COMPRESSION_TRACE")
            #expect(!CompressionTraceWriter.isEnabled)
            let url = try PDFFixtures.dedupStreamsPDF(pages: 2)
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try Compressor().compress(inputURL: url, mode: .smart)
            let traceURL = result.outputURL.deletingPathExtension()
                .appendingPathExtension("trace.json")
            #expect(!FileManager.default.fileExists(atPath: traceURL.path),
                    "Ohne Umgebung darf kein Trace entstehen")
        }
    }
}
