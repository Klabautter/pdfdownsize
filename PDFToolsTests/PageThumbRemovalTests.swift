import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Seiten-Thumbnails (/Thumb) entfernen – verlustfrei.
///
/// /Thumb sind reine Vorschaubilder in den Page-Dicts; Viewer regenerieren
/// sie aus den Seiteninhalten. Der Pass läuft nach GC, vor Metadaten/Write,
/// ist immer aktiv (keine Politik) und kann nie wachsen lassen: Der Writer
/// verwirft verwaiste Thumb-Streams.
///
/// Rebuild-Toleranz: Das C-Symbol existiert erst nach dem nächsten
/// `build-pdfcore.sh`-Lauf. Bis dahin meldet der Pass 0 (Skip) – der Test
/// hält beide Stände fest (Skip-Konsistenz vs. Entfernung + Render-Parität).
@Suite struct PageThumbRemovalTests {

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pagethumb-\(label)-\(UUID().uuidString).pdf")
    }

    /// Einseitiges PDF mit /Thumb auf ein 4×4-Grau-Bild.
    static func fixtureURL() throws -> URL {
        var builder = RawPDFBuilder()
        let pages = builder.reserveNumber()
        let content = builder.addStream(dictionary: "", content: "q Q")
        let resources = builder.addObject("<</XObject<<>>>>")
        // 4×4 Grau, ein Byte pro Pixel, Flate.
        let gray = Data([0, 64, 128, 255,
                         255, 128, 64, 0,
                         0, 64, 128, 255,
                         255, 128, 64, 0])
        let flate = try #require(ImageProcessor.flate(gray))
        let thumb = builder.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width 4/Height 4"
                + "/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/FlateDecode",
            data: flate)
        let page = builder.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 200 200]"
            + "/Resources \(resources) 0 R/Contents \(content) 0 R"
            + "/Thumb \(thumb) 0 R>>")
        builder.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = builder.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = Self.tempURL("fixture")
        try builder.build(rootObject: root).write(to: url)
        return url
    }

    static var symbolPresent: Bool {
        guard let h = UnsafeMutableRawPointer(bitPattern: -2) else { return false }
        return dlsym(h, "pdfcore_remove_page_thumbs") != nil
    }

    @Test(.hangGuard) func thumbWirdEntferntOderSauberGeskipt() throws {
        let url = try Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("/Thumb".utf8)) != nil,
                "Fixture muss einen /Thumb-Eintrag tragen")

        let doc = try PDFCoreDocument(path: url.path)
        let removed = try doc.removePageThumbs()
        if Self.symbolPresent {
            #expect(removed == 1, "Genau ein /Thumb-Eintrag muss fallen: \(removed)")
        } else {
            #expect(removed == 0, "Ohne C-Symbol ist Skip mit 0 der einzige Zustand")
        }

        let out = Self.tempURL("out")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        try PDFCoreDocument(path: out.path).check()
        let outRaw = try Data(contentsOf: out)
        if Self.symbolPresent {
            #expect(outRaw.range(of: Data("/Thumb".utf8)) == nil,
                    "Kein /Thumb darf den Write überleben")
        }
        let render = try RenderDifferential.compare(sourceURL: url, outputURL: out)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 },
                "Vorschaubilder dürfen das Rendering nicht ändern")
    }

    @Test(.hangGuard) func seiteOhneThumbBleibtUnberuehrt() throws {
        let url = try PDFFixtures.textPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let removed = try doc.removePageThumbs()
        #expect(removed == 0, "Ohne /Thumb gibt es nichts zu entfernen")
        let out = Self.tempURL("nothumb")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        try PDFCoreDocument(path: out.path).check()
    }
}
