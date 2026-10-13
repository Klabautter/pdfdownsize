import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Mehrfach identisch gespeicherte Bilder gehören auf ein Objekt.
///
/// Dokumente tragen dasselbe Bild oft mehrfach – ein Logo auf jeder Seite,
/// ein wiederholter Hintergrund. Jede Kopie liegt als eigenes Objekt mit
/// denselben Bytes im Dokument. Über den Korpus gemessen sind das 30 MB,
/// also 8 % aller Bilddaten, und das Zusammenführen ist verlustfrei: Es
/// wird kein Byte neu kodiert, nur ein Verweis umgehängt.
@Suite struct DuplicateImageTests {

    /// Die Fixture muss das Problem überhaupt haben, sonst prüft der Test
    /// nichts.
    @Test(.hangGuard) func fixtureReallyStoresCopies() throws {
        let url = try PDFFixtures.duplicateImagePDF(copies: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let res = try doc.imageResources()
        #expect(res.count == 4, """
            Fixture speichert \(res.count) Bildobjekte statt 4 – dann ist \
            nichts zusammenzuführen.
            """)
        // Alle gleich gross: dieselben Bytes.
        let sizes = Set(res.map(\.encodedByteCount))
        #expect(sizes.count == 1, "Die Kopien unterscheiden sich: \(sizes)")
    }

    /// Nach dem Zusammenführen bleibt ein Objekt übrig – und alle vier
    /// Seiten zeigen weiterhin ein Bild.
    @Test(.hangGuard) func duplicatesAreMergedIntoOne() throws {
        let url = try PDFFixtures.duplicateImagePDF(copies: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = Compressor.fileSize(of: url)

        let doc = try PDFCoreDocument(path: url.path)
        let merged = try doc.deduplicateImages()
        #expect(merged == 3, "Es wurden \(merged) statt 3 Verweise umgehängt")

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("dedup-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)

        let after = try PDFCoreDocument(path: out.path)
        #expect(after.pageCount == 4, "Seiten verloren")
        let res = try after.imageResources()
        #expect(res.count == 1, """
            Nach dem Zusammenführen liegen noch \(res.count) Bildobjekte vor.
            """)
        let outBytes = Compressor.fileSize(of: out)
        #expect(outBytes < before, """
            Nicht kleiner geworden: \(before) → \(outBytes) Bytes
            """)
    }

    /// Gegenprobe: VERSCHIEDENE Bilder werden nicht zusammengelegt.
    ///
    /// Ohne diese Probe wäre ein Zusammenführen, das alles auf ein Bild
    /// reduziert, ebenfalls „erfolgreich".
    @Test(.hangGuard) func differentImagesAreNotMerged() throws {
        let url = try PDFFixtures.manyImagesPDF(count: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let countBefore = try doc.imageResources().count
        try #require(countBefore >= 2, "Fixture trägt zu wenige Bilder")

        let merged = try doc.deduplicateImages()
        #expect(merged == 0, """
            \(merged) Verweise umgehängt, obwohl die Bilder verschieden sind.
            """)
    }

    /// Und über den echten Kompressionsweg: Das Ergebnis bleibt gültig.
    @Test(.hangGuard) func compressionMergesAndStaysValid() throws {
        let url = try PDFFixtures.duplicateImagePDF(copies: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let after = try PDFSemanticSnapshot.capture(result.outputURL)

        #expect(after.pageCount == before.pageCount)
        let losses = PDFSemanticSnapshot.differences(before, after)
            .filter { $0.severity <= .high }
        #expect(losses.isEmpty, "\(losses.map(\.message).joined(separator: " | "))")

        let doc = try PDFCoreDocument(path: result.outputURL.path)
        #expect(try doc.imageResources().count == 1, """
            Sechs identische Bilder wurden nicht zusammengeführt.
            """)
    }
}
