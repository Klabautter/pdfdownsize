import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Bilder mit Maske dürfen komprimiert werden – ihre Transparenz nicht
/// verlieren.
///
/// Sie waren pauschal ausgeschlossen, mit der Begründung, Bild und Maske
/// müssten gemeinsam umgerechnet werden. Die Norm verlangt das nicht: Nach
/// PDF 32000-1 §8.9.6.4 muss eine weiche Maske nicht dieselben Masse haben
/// wie ihr Basisbild, sie wird darauf skaliert.
///
/// Die Annahme kostete 143,5 MB im Korpus – 40 % aller Bilddaten und damit
/// der grösste einzelne Posten.
@Suite struct MaskedImageTests {

    /// Vorbedingung: Die Fixture trägt wirklich eine Maske, und die Maske
    /// hat andere Masse als das Bild.
    @Test(.hangGuard) func fixtureCarriesASoftMask() throws {
        let url = try PDFFixtures.softMaskedPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let res = try doc.imageResources()
        let base = try #require(res.first { $0.hasSoftMask },
                                "Kein Bild mit weicher Maske: \(res.count) Bilder")
        #expect(base.width == 2400)
        // Die Maske selbst erscheint NICHT in dieser Liste: Sie hängt am
        // Wörterbuch des Bildes, nicht an den Seitenressourcen. Gemeldet
        // wird sie über `hasSoftMask` am Basisbild – und genau das ist die
        // Beziehung, die eine Neukodierung überleben muss.
        #expect(res.count == 1,
                "Unerwartet \(res.count) Bildressourcen")
    }

    /// Ein maskiertes Bild ist transformierbar.
    @Test(.hangGuard) func maskedImageIsTransformable() throws {
        let url = try PDFFixtures.softMaskedPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let res = try doc.imageResources()
        let base = try #require(res.first { $0.hasSoftMask })
        #expect(base.transformCapability.isSafe, """
            Maskiertes Bild gilt weiterhin als untransformierbar: \
            \(base.transformCapability.reason)
            """)
    }

    /// Und die Kompression fasst es an, ohne die Transparenz zu verlieren.
    @Test(.hangGuard) func compressionKeepsTheMaskRelation() throws {
        let url = try PDFFixtures.softMaskedPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let inBytes = Compressor.fileSize(of: url)

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.outputBytes < inBytes, """
            Nicht kleiner geworden: \(inBytes) → \(result.outputBytes)
            """)

        let out = try PDFCoreDocument(path: result.outputURL.path)
        let res = try out.imageResources()
        let base = try #require(res.first { $0.width > 200 && $0.hasSoftMask }, """
            Nach der Kompression trägt kein Bild mehr eine weiche Maske – \
            die Transparenz ist verloren. Bilder: \
            \(res.map { "\($0.width)×\($0.height) smask=\($0.hasSoftMask)" })
            """)
        #expect(base.width < 2400, "Das Bild wurde nicht verkleinert")
    }

    /// Farbschlüssel-Maskierung bleibt ausgeschlossen.
    ///
    /// `/Mask` als Array benennt Farbwerte im Original. Eine verlustbehaftete
    /// Neukodierung verschiebt genau diese Werte – die Maskierung träfe
    /// danach andere Bildpunkte. Ohne diese Gegenprobe wäre die Lockerung
    /// zu weit gegangen.
    @Test(.hangGuard) func colorKeyMaskingStaysExcluded() throws {
        let url = try PDFFixtures.colorKeyMaskedPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let res = try doc.imageResources()
        let base = try #require(res.first, "Kein Bild in der Fixture")
        #expect(base.hasColorKeyMask, "Farbschlüssel-Maske nicht erkannt")
        #expect(!base.transformCapability.isSafe, """
            Farbschlüssel-Maskierung gilt als transformierbar – eine \
            verlustbehaftete Neukodierung würde die Maskierung verschieben.
            """)
    }
}
