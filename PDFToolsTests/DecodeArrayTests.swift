import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Bilder mit `/Decode`-Array dürfen komprimiert werden – ohne dass sich
/// ihre Farben umkehren.
///
/// Ein Decode-Array bildet die Abtastwerte auf den Farbbereich ab;
/// `[1 0 1 0 1 0]` invertiert. Wer es beim Neukodieren ignoriert, liefert
/// ein umgekehrtes Bild aus – deshalb war der Fall pauschal gesperrt. Über
/// den Korpus gemessen betraf das 38 300 Bilder mit zusammen 55,7 MB, also
/// die Mehrzahl aller Bilder überhaupt.
///
/// Jetzt wird die Abbildung beim Dekodieren angewendet und im neuen
/// Wörterbuch weggelassen.
@Suite struct DecodeArrayTests {

    @Test(.hangGuard) func fixtureCarriesADecodeArray() throws {
        let url = try PDFFixtures.decodeArrayPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let r = try #require(try doc.imageResources().first)
        #expect(r.hasDecodeArray, "Kein /Decode erkannt")
        #expect(r.decodeArray == [1, 0, 1, 0, 1, 0],
                "Unerwartete Werte: \(r.decodeArray)")
    }

    @Test(.hangGuard) func decodeArrayNoLongerBlocks() throws {
        let url = try PDFFixtures.decodeArrayPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let r = try #require(try doc.imageResources().first)
        #expect(r.transformCapability.isSafe, """
            Bild mit /Decode gilt weiterhin als untransformierbar: \
            \(r.transformCapability.reason)
            """)
    }

    /// Der entscheidende Test: Die Farben bleiben, wie sie ANGEZEIGT wurden.
    ///
    /// Ohne diesen Test wäre eine Lockerung, die das Array ignoriert,
    /// ebenfalls „erfolgreich" – und lieferte invertierte Bilder aus.
    @Test(.hangGuard) func coloursSurviveTheRoundTrip() throws {
        let url = try PDFFixtures.decodeArrayPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let renderedBefore = try #require(PDFDocument(url: url)?.page(at: 0)?
            .thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox))

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let renderedAfter = try #require(PDFDocument(url: result.outputURL)?
            .page(at: 0)?.thumbnail(of: CGSize(width: 300, height: 400),
                                    for: .mediaBox))

        let before = try #require(renderedBefore.cgImage(forProposedRect: nil,
                                                         context: nil, hints: nil))
        let after = try #require(renderedAfter.cgImage(forProposedRect: nil,
                                                       context: nil, hints: nil))
        let ssim = QualityMetrics.ssim(original: before, candidate: after)
        #expect(ssim > 0.95, """
            Die Seite sieht nach der Kompression anders aus (SSIM \
            \(String(format: "%.4f", ssim))) – vermutlich wurde das \
            /Decode-Array nicht angewendet und das Bild ist invertiert.
            """)
    }

    /// Und das neue Bild trägt kein /Decode mehr – es steckt in den Pixeln.
    @Test(.hangGuard) func decodeArrayIsGoneAfterwards() throws {
        let url = try PDFFixtures.decodeArrayPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let out = try PDFCoreDocument(path: result.outputURL.path)
        let images = try out.imageResources()
        for image in images {
            #expect(!image.hasDecodeArray, """
                Das neue Bild trägt weiterhin ein /Decode \
                (\(image.decodeArray)) – dann wird es doppelt angewendet.
                """)
        }
    }
}
