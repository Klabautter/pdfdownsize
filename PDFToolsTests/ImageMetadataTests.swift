import Testing
import Foundation
@testable import PDFTools

/// Ein Bild mit eigenem `/Metadata`-Stream muss ersetzbar sein.
///
/// Die Ersetzung übernahm die begleitenden Wörterbuch-Einträge mit
/// `shallowCopy()`. Das wirft in qpdf, sobald ein Eintrag ein Stream ist –
/// und `/Metadata` IST einer. Jedes Bild mit XMP-Metadaten liess sich damit
/// gar nicht komprimieren; der Fehler verschwand im Auffang-catch der
/// Bridge und kam als nichtssagendes „internalError" heraus.
///
/// Unentdeckt blieb er, weil kein Korpusdokument ihn traf. Sichtbar wurde er
/// erst durch einen 12-MB-Bundesregister-Auszug: neun Fehlschläge auf zwei
/// Dokumenten im Korpuslauf.
@Suite struct ImageMetadataTests {

    @Test(.hangGuard) func fixtureCarriesImageMetadata() throws {
        let url = try PDFFixtures.imageWithMetadataPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        #expect(try doc.imageResources().count == 1)
        #expect(throws: Never.self) { try doc.check() }
    }

    /// Der eigentliche Test: Es wird ersetzt, statt an der Kopie zu scheitern.
    @Test(.hangGuard) func imageWithMetadataIsReplaceable() throws {
        let url = try PDFFixtures.imageWithMetadataPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let inBytes = Compressor.fileSize(of: url)

        let options = CompressionPresetFactory.custom(dpi: 96, quality: 0.65)
        let result = try Compressor().compress(inputURL: url, options: options)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.outputBytes < inBytes, """
            Nicht kleiner: \(inBytes) → \(result.outputBytes). Vermutlich \
            scheitert die Ersetzung wieder an einem Stream im Wörterbuch. \
            Gewählte Kandidaten: \(result.selectedCandidateCount)
            """)

        let out = try PDFCoreDocument(path: result.outputURL.path)
        let r = try #require(try out.imageResources().first)
        #expect(r.width < 1600, "Bild wurde nicht verkleinert: \(r.width)")
    }

    /// Und das Dokument bleibt gültig.
    @Test(.hangGuard) func outputStaysValid() throws {
        let url = try PDFFixtures.imageWithMetadataPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let after = try PDFSemanticSnapshot.capture(result.outputURL)

        let losses = PDFSemanticSnapshot.differences(before, after)
            .filter { $0.severity <= .high }
        #expect(losses.isEmpty, "\(losses.map(\.message).joined(separator: " | "))")
        #expect(throws: Never.self) {
            try PDFCoreDocument(path: result.outputURL.path).check()
        }
    }
}
