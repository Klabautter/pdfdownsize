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

    /// Eine weiche Maske mit /Matte geht die Verkleinerung mit.
    ///
    /// Die Farben des Basisbildes sind gegen die Matte-Farbe vorgemischt;
    /// PDF 32000-1 §11.6.5.3 verlangt dann dieselben Masse für Bild und
    /// Maske. Bis 1.0.3 wurde nur das Bild verkleinert – Poppler meldete
    /// „Softmask with matte entry … must have same geometry" (CSWP.04162018,
    /// S. 19, Klein).
    @Test(.hangGuard) func matteSoftMaskFollowsTheResize() throws {
        let url = try PDFFixtures.softMaskedPhotoPDF(matte: true,
                                                     name: "matte-masked")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Compressor().compress(inputURL: url, mode: .small)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let pairs = try Self.imageAndMaskGeometry(of: result.outputURL)
        let pair = try #require(pairs.first { $0.matte }, """
            Kein Bild mit /Matte-Maske mehr im Ergebnis – Transparenz \
            verloren? \(pairs)
            """)
        #expect(pair.image.width < 2400, "Das Bild wurde nicht verkleinert")
        #expect(pair.image == pair.mask, """
            Maske mit /Matte hat \(pair.mask), das Bild \(pair.image) – \
            §11.6.5.3 verlangt gleiche Masse.
            """)
    }

    struct Geometry: Equatable, CustomStringConvertible {
        let width: Int, height: Int
        var description: String { "\(width)×\(height)" }
    }

    /// Masse aller Seitenbilder mit weicher Maske, direkt aus den Wörter-
    /// büchern gelesen – `imageResources()` meldet die Maske nur als Flag.
    static func imageAndMaskGeometry(of url: URL) throws
        -> [(image: Geometry, mask: Geometry, matte: Bool)] {
        let doc = try #require(CGPDFDocument(url as CFURL))
        var found: [(image: Geometry, mask: Geometry, matte: Bool)] = []
        for index in 1...max(doc.numberOfPages, 1) {
            guard let page = doc.page(at: index)?.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(page, "Resources", &resources),
                  let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
                  let xobjects else { continue }
            var streams: [CGPDFStreamRef] = []
            withUnsafeMutablePointer(to: &streams) { ctx in
                CGPDFDictionaryApplyFunction(xobjects, { _, object, info in
                    var stream: CGPDFStreamRef?
                    if CGPDFObjectGetValue(object, .stream, &stream), let stream {
                        info!.assumingMemoryBound(to: [CGPDFStreamRef].self)
                            .pointee.append(stream)
                    }
                }, ctx)
            }
            for stream in streams {
                guard let dict = CGPDFStreamGetDictionary(stream) else { continue }
                var smask: CGPDFStreamRef?
                guard CGPDFDictionaryGetStream(dict, "SMask", &smask), let smask,
                      let maskDict = CGPDFStreamGetDictionary(smask) else { continue }
                var matte: CGPDFArrayRef?
                found.append((image: geometry(dict), mask: geometry(maskDict),
                              matte: CGPDFDictionaryGetArray(maskDict, "Matte", &matte)))
            }
        }
        return found
    }

    private static func geometry(_ dict: CGPDFDictionaryRef) -> Geometry {
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(dict, "Width", &w)
        CGPDFDictionaryGetInteger(dict, "Height", &h)
        return Geometry(width: w, height: h)
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
