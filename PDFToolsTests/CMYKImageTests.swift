import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// CMYK-Bilder werden verkleinert – aber nie umgerechnet.
///
/// Sie waren pauschal ausgeschlossen, weil der Ersatzweg nur grau und RGB
/// kannte: 42,4 MB im Korpus, durchweg Druckmaterial. Nach RGB zu wandeln
/// wäre dort eine Farbveränderung; als JPEG zu speichern erforderte die
/// Adobe-Konvention mit invertierten Werten, und ein Fehler darin
/// verfälscht Druckfarben.
///
/// Deshalb: verlustfrei verkleinern im eigenen Farbraum. Die Ersparnis kommt
/// ohnehin aus der Auflösung – gemessen liegen zwischen Qualität 0,85 und
/// 1,00 nur 0,0002 SSIM, aber zwischen 300 und 150 dpi sechs Prozentpunkte.
@Suite struct CMYKImageTests {

    @Test(.hangGuard) func fixtureIsReallyCMYK() throws {
        let url = try PDFFixtures.cmykPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try #require(try PDFCoreDocument(path: url.path).imageResources().first)
        #expect(r.colorSpace == .deviceCMYK, "Farbraum: \(r.colorSpace)")
        #expect(r.colorSpace.componentCount == 4)
    }

    @Test(.hangGuard) func cmykIsTransformable() throws {
        let url = try PDFFixtures.cmykPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try #require(try PDFCoreDocument(path: url.path).imageResources().first)
        #expect(r.transformCapability.isSafe, """
            CMYK gilt weiterhin als untransformierbar: \
            \(r.transformCapability.reason)
            """)
    }

    /// Der Kern: Es wird kleiner UND bleibt CMYK.
    @Test(.hangGuard) func cmykShrinksAndStaysCMYK() throws {
        let url = try PDFFixtures.cmykPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let inBytes = Compressor.fileSize(of: url)

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.outputBytes < inBytes, """
            Nicht kleiner: \(inBytes) → \(result.outputBytes)
            """)

        let out = try PDFCoreDocument(path: result.outputURL.path)
        let r = try #require(try out.imageResources().first)
        #expect(r.colorSpace == .deviceCMYK, """
            Der Farbraum wurde geändert: \(r.colorSpace). Bei Druckdaten ist \
            das eine Farbveränderung, keine Kompression.
            """)
        #expect(r.width < 2000, "Nicht verkleinert: \(r.width)")
    }

    /// Und es bleibt verlustfrei kodiert – kein JPEG.
    ///
    /// Ein CMYK-JPEG müsste die Adobe-Konvention treffen. Solange wir das
    /// nicht nachweislich beherrschen, ist der verlustfreie Weg der richtige.
    @Test(.hangGuard) func cmykIsNeverStoredAsJPEG() throws {
        let url = try PDFFixtures.cmykPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let out = try PDFCoreDocument(path: result.outputURL.path)
        let r = try #require(try out.imageResources().first)
        #expect(r.terminalFilter != .dct, """
            CMYK wurde als JPEG gespeichert – die Adobe-Konvention mit \
            invertierten Werten ist dabei nicht abgesichert.
            """)
    }

    /// Die Seite sieht danach aus wie vorher.
    @Test(.hangGuard) func coloursAreUnchanged() throws {
        let url = try PDFFixtures.cmykPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try #require(PDFDocument(url: url)?.page(at: 0)?
            .thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox))

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let after = try #require(PDFDocument(url: result.outputURL)?.page(at: 0)?
            .thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox))

        let a = try #require(before.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let b = try #require(after.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let ssim = QualityMetrics.ssim(original: a, candidate: b)
        #expect(ssim > 0.95, """
            Die Seite sieht anders aus (SSIM \(String(format: "%.4f", ssim))) – \
            vermutlich wurde der Farbraum falsch behandelt.
            """)
    }
}
