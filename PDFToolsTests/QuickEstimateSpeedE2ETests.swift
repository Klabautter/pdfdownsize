import Testing
import Foundation
@testable import PDFTools

/// Core-235-Befund 2026-09-30: Die Schnellschätzung brauchte auf großen
/// Dokumenten bis zu 213 s (Annual_SRM_Product_List, 10 MB), 35 s
/// (Statistik-Jahrbuch) – „Schätzen soll nur schätzen“.
///
/// Ursachen (Sampling):
///  • Platzierungs-Scan über JEDE Seite, auch reine Textseiten.
///  • Strukturprofil löste über `getAllObjects()` jedes Objekt der Datei
///    auf, nur um Objekt-Streams zu erkennen (Xref-Typ 2 genügt).
///
/// Vorher aufgeschriebene Fehlermöglichkeiten des Fixes:
///  1. Objekt-Streams werden nicht mehr erkannt (Schätzung zu optimistisch).
///  2. Objekt-Streams werden fälschlich erkannt (zu pessimistisch).
///  3. Die Schätzung ändert ihren Wert (sie darf nur schneller werden).
///  4. Große Dokumente bleiben langsam.
@Suite(.serialized) struct QuickEstimateSpeedE2ETests {

    private func rewrite(_ input: URL, objectStreams: String) throws -> URL {
        let qpdf = try #require(Compressor.findQPDF())
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("objstm-\(objectStreams)-\(UUID().uuidString).pdf")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdf)
        process.arguments = ["--object-streams=\(objectStreams)", input.path, out.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0 || process.terminationStatus == 3)
        return out
    }

    /// 1 + 2: Erkennung über die Xref-Tabelle trifft beide Richtungen.
    @Test func objektStreamsWerdenErkannt() throws {
        let base = try PDFFixtures.write(
            PDFFixtures.document(pages: (0..<4).map { PDFFixtures.textPage("Struktur \($0)") }),
            name: "structure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let with = try rewrite(base, objectStreams: "generate")
        let without = try rewrite(base, objectStreams: "disable")
        defer {
            try? FileManager.default.removeItem(at: with)
            try? FileManager.default.removeItem(at: without)
        }
        #expect(try PDFCoreDocument(path: with.path).structureProfile.usesObjectStreams)
        #expect(!(try PDFCoreDocument(path: without.path).structureProfile.usesObjectStreams))
    }

    /// 3 + 4: Großes Textdokument – gleicher Wert, schnell.
    @Test(.timeLimit(.minutes(2)), .needsLocalFiles("tmp/pdfs/core-235")) func grosseDokumenteSchaetzenSchnell() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tmp/pdfs/core-235/01_BornDigital_Text/statab_2012.pdf")
        try #require(FileManager.default.fileExists(atPath: url.path), "Fehlt: \(url.path)")
        let start = Date()
        let estimate = try #require(CompressionEstimator.quickEstimate(url: url, options: .smart))
        let seconds = Date().timeIntervalSince(start)
        // Vor dem Fix (Debug) 35 s; der Wert selbst stand bei 11.223.406 B.
        #expect(estimate.pointBytes == 11_223_406, "Punktwert \(estimate.pointBytes)")
        #expect(seconds < 3, "Schnellschätzung \(seconds) s")
    }
}
