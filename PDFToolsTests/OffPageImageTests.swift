import AppKit
import ImageIO
import Testing
import Foundation
import PDFKit
import UniformTypeIdentifiers
@testable import PDFTools

/// Bilder außerhalb des XObject-Baums der Seite: tiling Patterns, Annotations-
/// Appearances, Soft-Mask-Gruppen. Bis hierher sah die Engine sie nicht, sie
/// blieben in allen Stufen bei 0 %.
///
/// Wie es schiefgehen kann – dagegen laufen die Tests:
///  1. Falsche Geometrie: Die CTM beim Füllen fließt ins Muster ein, /Matrix
///     oder /Rect fehlen. Zu kleine Platzierung = zu hohe DPI = verschwommen.
///  2. Geratene Geometrie: Kaputte Matrix, /XStep 0, kein `Do` im Content – das
///     muss „unbekannt“ werden, nicht 1:1.
///  3. Eine bekannte Platzierung überstimmt eine unbekannte desselben Bildes.
///  4. Namenskollision: `Im0` im Muster ist nicht `Im0` im Seiten-Content.
///  5. Der Rendervergleich zeichnet das Muster oder die Annotation gar nicht –
///     dann prüfen die Gates nichts.
///  6. Ein Stempel über die ganze Seite macht sie zum „Scan“ (MRC, OCR).
///  7. Der Ressourcen-GC wirft etwas weg, das nur eine Appearance benutzt.
///  8. Zykel im Graphen hängen die Inventur auf.
///  9. Der zweite Lauf erodiert das Bild weiter.
@Suite(.serialized) struct OffPageImageTests {

    // MARK: - Fixtures

    private static let imageWidth = 1000

    /// Bild nur fürs Inventar: Die Geometrie-Tests dekodieren es nie.
    private static func addImage(_ b: inout RawPDFBuilder, width: Int = imageWidth) -> Int {
        b.addStream(dictionary: "/Type/XObject/Subtype/Image/Width \(width)/Height 1000/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode",
                    data: Data([0xFF, 0xD8, 0xFF, 0xD9]))
    }

    /// Eine Seite; `build` liefert Einträge des Seiten-Dictionaries und den Content.
    private static func page(_ name: String, media: (Double, Double) = (600, 800),
                             build: (inout RawPDFBuilder) -> (dict: String, content: String)) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let (dict, content) = build(&b)
        let stream = b.addStream(dictionary: "", content: content)
        let p = b.addObject("<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 \(media.0) \(media.1)]\(dict)/Contents \(stream) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(p) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = PDFFixtures.fixtureURL(prefix: "offpage-\(name)")
        try b.build(rootObject: root).write(to: url)
        return url
    }

    private static func pattern(_ b: inout RawPDFBuilder, image: Int, matrix: String = "",
                                step: (Double, Double) = (300, 400), drawn: String = "q 300 0 0 400 0 0 cm /Im0 Do Q") -> Int {
        b.addStream(dictionary: "/Type/Pattern/PatternType 1/PaintType 1/TilingType 1/BBox[0 0 300 400]/XStep \(step.0)/YStep \(step.1)\(matrix)/Resources<</XObject<</Im0 \(image) 0 R>>>>",
                    content: drawn)
    }

    private static func stamp(_ b: inout RawPDFBuilder, image: Int, form: String = "/BBox[0 0 300 400]") -> Int {
        b.addStream(dictionary: "/Type/XObject/Subtype/Form\(form)/Resources<</XObject<</Im0 \(image) 0 R>>>>",
                    content: "q 300 0 0 400 0 0 cm /Im0 Do Q")
    }

    private static let fill = "/Pattern cs /P0 scn 0 0 300 400 re f"

    private static func resource(_ url: URL, width: Int = imageWidth) throws -> PDFImageResource {
        let all = try PDFCoreDocument(path: url.path).imageResources()
        return try #require(all.first { $0.width == width },
                            "Kein Bild mit Breite \(width) unter \(all.map(\.width))")
    }

    private static func removing<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        defer { try? FileManager.default.removeItem(at: url) }
        return try body()
    }

    /// `placed` Punkte Breite für das 1000-Pixel-Bild.
    private static func expectPlaced(_ r: PDFImageResource, _ placed: Double,
                                     sourceLocation: SourceLocation = #_sourceLocation) throws {
        let dpi = try #require(r.effectiveDPI, sourceLocation: sourceLocation)
        #expect(abs(dpi - Double(imageWidth) / placed * 72) < 0.01,
                "DPI \(dpi), erwartet \(Double(imageWidth) / placed * 72)", sourceLocation: sourceLocation)
    }

    // MARK: - Muster

    @Test(.hangGuard) func musterZähltSeineMatrixAberNichtDieCTMBeimFüllen() throws {
        let url = try Self.page("pattern-matrix") { b in
            let img = Self.addImage(&b)
            let pat = Self.pattern(&b, image: img, matrix: "/Matrix[0.5 0 0 0.5 10 20]")
            return ("/Resources<</Pattern<</P0 \(pat) 0 R>>>>", "3 0 0 3 0 0 cm " + Self.fill)
        }
        try Self.removing(url) {
            let r = try Self.resource(url)
            #expect(r.placements.first?.isOffPage == true)
            #expect(r.placements.first?.transform == nil, "Lage auf der Seite wäre geraten")
            try Self.expectPlaced(r, 150)
        }
    }

    @Test(.hangGuard) func kachelschritteÄndernDieDPINicht() throws {
        for step in [(30.0, 40.0), (3000.0, 4000.0), (-300.0, 400.0)] {
            let url = try Self.page("pattern-step") { b in
                let img = Self.addImage(&b)
                let pat = Self.pattern(&b, image: img, step: step)
                return ("/Resources<</Pattern<</P0 \(pat) 0 R>>>>", Self.fill)
            }
            try Self.removing(url) { try Self.expectPlaced(try Self.resource(url), 300) }
        }
    }

    @Test(.hangGuard) func musterInFormErbtDieFormAbbildung() throws {
        let url = try Self.page("pattern-in-form") { b in
            let img = Self.addImage(&b)
            let pat = Self.pattern(&b, image: img, matrix: "/Matrix[0.5 0 0 0.5 0 0]")
            let form = b.addStream(dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 600 800]/Matrix[2 0 0 2 0 0]/Resources<</Pattern<</P0 \(pat) 0 R>>>>",
                                   content: Self.fill)
            return ("/Resources<</XObject<</F0 \(form) 0 R>>>>", "q 1.5 0 0 1.5 0 0 cm /F0 Do Q")
        }
        // 300 (Content) × 0,5 (Muster) × 2 (Form-Matrix) × 1,5 (cm vor dem Do)
        try Self.removing(url) { try Self.expectPlaced(try Self.resource(url), 450) }
    }

    @Test(.hangGuard) func kaputteMustergeometrieWirdUnbekanntStattGeraten() throws {
        let broken: [(matrix: String, step: (Double, Double))] = [
            ("", (0, 400)),
            ("", (300, 0)),
            ("/Matrix[0 0 0 0 0 0]", (300, 400)),
            ("/Matrix[1 0 0]", (300, 400)),
        ]
        for variant in broken {
            let url = try Self.page("pattern-broken") { b in
                let img = Self.addImage(&b)
                let pat = Self.pattern(&b, image: img, matrix: variant.matrix, step: variant.step)
                return ("/Resources<</Pattern<</P0 \(pat) 0 R>>>>", Self.fill)
            }
            try Self.removing(url) {
                let r = try Self.resource(url)
                #expect(r.effectiveDPI == nil, "\(variant)")
                #expect(r.placements.first?.placedWidthPoints == 0)
            }
        }
    }

    @Test(.hangGuard) func bildOhneDoImMusterIstUnbekannt() throws {
        let url = try Self.page("pattern-nodo") { b in
            let img = Self.addImage(&b)
            let pat = Self.pattern(&b, image: img, drawn: "0 0 10 10 re f")
            return ("/Resources<</Pattern<</P0 \(pat) 0 R>>>>", Self.fill)
        }
        try Self.removing(url) {
            let r = try Self.resource(url)
            #expect(r.effectiveDPI == nil)
        }
    }

    @Test(.hangGuard) func zykelImMusterHängtNicht() throws {
        let url = try Self.page("pattern-cycle") { b in
            let img = Self.addImage(&b)
            let self_ = b.reserveNumber()
            let content = "q 300 0 0 400 0 0 cm /Im0 Do Q"
            let stream = "<</Type/Pattern/PatternType 1/PaintType 1/TilingType 1/BBox[0 0 300 400]/XStep 300/YStep 400/Resources<</XObject<</Im0 \(img) 0 R>>/Pattern<</P0 \(self_) 0 R>>>>/Length \(content.utf8.count)>>\nstream\n\(content)\nendstream"
            b.fill(self_, stream)
            return ("/Resources<</Pattern<</P0 \(self_) 0 R>>>>", Self.fill)
        }
        try Self.removing(url) { try Self.expectPlaced(try Self.resource(url), 300) }
    }

    // MARK: - Mehrere Wege, Namen

    @Test(.hangGuard) func unbekannterWegÜberstimmtBekanntePlatzierung() throws {
        let url = try Self.page("mixed-unknown") { b in
            let img = Self.addImage(&b)
            let pat = Self.pattern(&b, image: img, step: (0, 400))
            return ("/Resources<</XObject<</Im0 \(img) 0 R>>/Pattern<</P0 \(pat) 0 R>>>>",
                    "q 100 0 0 100 0 0 cm /Im0 Do Q " + Self.fill)
        }
        try Self.removing(url) {
            let r = try Self.resource(url)
            #expect(r.effectiveDPI == nil)
        }
    }

    @Test(.hangGuard) func größterWegGiltÜberSeiteUndMusterHinweg() throws {
        let url = try Self.page("mixed-known") { b in
            let img = Self.addImage(&b)
            let pat = Self.pattern(&b, image: img, matrix: "/Matrix[2 0 0 2 0 0]")
            return ("/Resources<</XObject<</Im0 \(img) 0 R>>/Pattern<</P0 \(pat) 0 R>>>>",
                    "q 100 0 0 100 0 0 cm /Im0 Do Q " + Self.fill)
        }
        try Self.removing(url) { try Self.expectPlaced(try Self.resource(url), 600) }
    }

    @Test(.hangGuard) func gleicherNameAufDerSeiteIstEinAnderesBild() throws {
        let url = try Self.page("name-collision") { b in
            let inPattern = Self.addImage(&b)
            let onPage = Self.addImage(&b, width: 2000)
            let pat = Self.pattern(&b, image: inPattern)
            return ("/Resources<</XObject<</Im0 \(onPage) 0 R>>/Pattern<</P0 \(pat) 0 R>>>>",
                    "q 50 0 0 50 0 0 cm /Im0 Do Q " + Self.fill)
        }
        try Self.removing(url) { try Self.expectPlaced(try Self.resource(url), 300) }
    }

    // MARK: - Annotationen

    @Test(.hangGuard) func stempelSkaliertVonBBoxAufRect() throws {
        let url = try Self.page("stamp-scale") { b in
            let img = Self.addImage(&b)
            let ap = Self.stamp(&b, image: img)
            return ("/Annots[<</Type/Annot/Subtype/Stamp/Rect[100 100 250 300]/AP<</N \(ap) 0 R>>>>]", "q Q")
        }
        try Self.removing(url) { try Self.expectPlaced(try Self.resource(url), 150) }
    }

    /// Algorithmus 8.1: Die /BBox wird erst mit /Matrix gedreht, dann eingepasst.
    @Test(.hangGuard) func gedrehteAppearanceRechnetÜberDieTransformierteBBox() throws {
        let url = try Self.page("stamp-rotated") { b in
            let img = Self.addImage(&b)
            let ap = Self.stamp(&b, image: img, form: "/BBox[0 0 300 400]/Matrix[0 1 -1 0 0 0]")
            return ("/Annots[<</Type/Annot/Subtype/Stamp/Rect[0 0 800 600]/AP<</N \(ap) 0 R>>>>]", "q Q")
        }
        // Gedrehte BBox 400 × 300 auf Rect 800 × 600: Faktor 2, Bildbreite 300 → 600.
        try Self.removing(url) { try Self.expectPlaced(try Self.resource(url), 600) }
    }

    @Test(.hangGuard) func unbestimmbareAnnotationIstUnbekannt() throws {
        let cases = [
            "/Rect[100 100 100 300]",            // leeres Rect
            "/Rect[100 100 250 300]/F 8",        // NoZoom: Größe von der Seite entkoppelt
        ]
        for annot in cases {
            let url = try Self.page("stamp-unknown") { b in
                let img = Self.addImage(&b)
                let ap = Self.stamp(&b, image: img)
                return ("/Annots[<</Type/Annot/Subtype/Stamp\(annot)/AP<</N \(ap) 0 R>>>>]", "q Q")
            }
            try Self.removing(url) {
                let r = try Self.resource(url)
                #expect(r.effectiveDPI == nil, "\(annot)")
            }
        }
    }

    /// Was nicht gezeichnet wird, sieht kein Rendervergleich: Es bleibt draußen.
    @Test(.hangGuard) func nurGezeichneteAppearancesKommenInsInventar() throws {
        let url = try Self.page("stamp-visible") { b in
            let hidden = Self.addImage(&b, width: 1001)
            let noView = Self.addImage(&b, width: 1002)
            let rollover = Self.addImage(&b, width: 1003)
            let off = Self.addImage(&b, width: 1004)
            let on = Self.addImage(&b, width: 1005)
            let normal = Self.addImage(&b, width: 1006)
            let a = [hidden, noView, rollover, off, on, normal].map { Self.stamp(&b, image: $0) }
            return ("/Annots["
                    + "<</Subtype/Stamp/Rect[0 0 300 400]/F 2/AP<</N \(a[0]) 0 R>>>>"
                    + "<</Subtype/Stamp/Rect[0 0 300 400]/F 32/AP<</N \(a[1]) 0 R>>>>"
                    + "<</Subtype/Stamp/Rect[0 0 300 400]/AP<</N \(a[5]) 0 R/R \(a[2]) 0 R>>>>"
                    + "<</Subtype/Widget/Rect[0 0 300 400]/AS/Yes/AP<</N<</Off \(a[3]) 0 R/Yes \(a[4]) 0 R>>>>>>"
                    + "]", "q Q")
        }
        try Self.removing(url) {
            let widths = try PDFCoreDocument(path: url.path).imageResources().map(\.width).sorted()
            #expect(widths == [1005, 1006])
        }
    }

    // MARK: - Soft-Mask-Gruppen

    @Test(.hangGuard) func maskengruppeErbtDieCTMBeimGs() throws {
        let url = try Self.page("softmask") { b in
            let img = Self.addImage(&b)
            let group = b.addStream(dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 300 400]/Group<</S/Transparency/CS/DeviceGray>>/Resources<</XObject<</Im0 \(img) 0 R>>>>",
                                    content: "q 100 0 0 100 0 0 cm /Im0 Do Q")
            return ("/Resources<</ExtGState<</GS0<</SMask<</S/Luminosity/G \(group) 0 R>>>>>>>>",
                    "q 2 0 0 2 0 0 cm /GS0 gs 0 0 300 400 re f Q")
        }
        try Self.removing(url) { try Self.expectPlaced(try Self.resource(url), 200) }
    }

    // MARK: - Urteile über die Seite

    @Test(.hangGuard) func stempelÜberDieGanzeSeiteMachtSieNichtZumScan() throws {
        let url = try Self.page("stamp-fullpage") { b in
            let img = Self.addImage(&b)
            let ap = Self.stamp(&b, image: img)
            return ("/Annots[<</Subtype/Stamp/Rect[0 0 600 800]/AP<</N \(ap) 0 R>>>>]", "q Q")
        }
        try Self.removing(url) {
            let doc = try PDFCoreDocument(path: url.path)
            let page = try #require(try PageScanAnalyzer.analyze(document: doc).first)
            #expect(page.imageCount == 0)
            #expect(page.imageCoverageRatio == 0)
            #expect(page.classification != .rasterScan)
        }
    }

    // MARK: - Ressourcen-GC

    /// /N mit Zuständen teilt sich /Resources mit der Seite: Der GC darf den
    /// Eintrag nicht entfernen, den nur ein Zustand benutzt.
    @Test(.hangGuard) func gcBehältWasNurEinAppearanceZustandBenutzt() throws {
        let url = try Self.page("gc-states") { b in
            let used = Self.addImage(&b, width: 1001)
            let onlyOff = Self.addImage(&b, width: 1002)
            let onlyOn = Self.addImage(&b, width: 1003)
            let unused = Self.addImage(&b, width: 1004)
            let res = b.addObject("<</XObject<</A \(used) 0 R/B \(onlyOff) 0 R/C \(onlyOn) 0 R/D \(unused) 0 R>>>>")
            let offState = b.addStream(dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 10 10]/Resources \(res) 0 R", content: "/B Do")
            let onState = b.addStream(dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 10 10]/Resources \(res) 0 R", content: "/C Do")
            return ("/Resources \(res) 0 R/Annots[<</Subtype/Widget/Rect[0 0 10 10]/AS/Yes/AP<</N<</Off \(offState) 0 R/Yes \(onState) 0 R>>>>>>]",
                    "/A Do")
        }
        let out = Self.fixtureOutput("gc-states")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: out) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.removeUnusedResources()
        #expect(stats.totalEntriesRemoved == 1, "Nur /D ist unbenutzt: \(stats)")
        try doc.save(to: out)
        let widths = Set(try PDFCoreDocument(path: out.path).inspectImages().map(\.width))
        #expect(widths.isSuperset(of: [1001, 1002, 1003]), "\(widths)")
        #expect(!widths.contains(1004))
    }

    private static func fixtureOutput(_ name: String) -> URL {
        PDFFixtures.fixtureURL(prefix: "offpage-out-\(name)")
    }

    // MARK: - Ende zu Ende

    private static func photo(_ w: Int, _ h: Int, seed: Double = 0, quality: Double = 0.92, gray: Bool = false) throws -> Data {
        let comps = gray ? 1 : 3
        var px = Data(capacity: w * h * comps)
        var noise: UInt64 = 7
        for y in 0..<h { for x in 0..<w {
            noise = noise &* 6364136223846793005 &+ 1442695040888963407
            let n = Double((noise >> 40) % 40) / 255
            let u = Double(x) / Double(w), v = Double(y) / Double(h)
            let r = min(1, 0.45 + 0.4 * sin(u * 31 + seed) * cos(v * 23) + n)
            let g = min(1, 0.45 + 0.4 * cos(u * 17 + v * 29 + seed) + n)
            let bl = min(1, 0.45 + 0.4 * sin(v * 37 + seed) + n)
            if gray { px.append(UInt8(255 * (r + g + bl) / 3)) } else {
                px.append(UInt8(255 * r)); px.append(UInt8(255 * g)); px.append(UInt8(255 * bl))
            }
        } }
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let image = try #require(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * comps,
                                         bytesPerRow: w * comps, space: space, bitmapInfo: CGBitmapInfo(rawValue: 0),
                                         provider: CGDataProvider(data: px as CFData)!, decode: nil,
                                         shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private enum Route: CaseIterable { case pattern, stamp, softMask }

    private static func document(_ route: Route, jpeg: Data, w: Int = 1667, h: Int = 2222, gray: Bool = false) throws -> URL {
        try page("e2e-\(route)", media: (400, 533)) { b in
            let cs = gray ? "/DeviceGray" : "/DeviceRGB"
            let img = b.addStream(dictionary: "/Type/XObject/Subtype/Image/Width \(w)/Height \(h)/ColorSpace\(cs)/BitsPerComponent 8/Filter/DCTDecode", data: jpeg)
            switch route {
            case .pattern:
                let pat = pattern(&b, image: img)
                return ("/Resources<</Pattern<</P0 \(pat) 0 R>>>>", fill)
            case .stamp:
                let ap = stamp(&b, image: img)
                return ("/Annots[<</Type/Annot/Subtype/Stamp/Rect[0 0 300 400]/AP<</N \(ap) 0 R>>>>]", "q Q")
            case .softMask:
                let group = b.addStream(dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 300 400]/Group<</S/Transparency/CS/DeviceGray>>/Resources<</XObject<</Im0 \(img) 0 R>>>>",
                                        content: "q 300 0 0 400 0 0 cm /Im0 Do Q")
                return ("/Resources<</ExtGState<</GS0<</SMask<</S/Luminosity/G \(group) 0 R>>>>>>>>",
                        "/GS0 gs 0.1 0.3 0.8 rg 0 0 300 400 re f")
            }
        }
    }

    /// Fehlerbild 5: Zeichnet der Vergleich die Stelle nicht, sind beide Seiten
    /// weiß und gleich – dann wäre jedes Gate blind. Zwei Dokumente, die sich NUR
    /// im Bild an dieser Stelle unterscheiden, müssen klar verschieden messen.
    @Test(.hangGuard) func rendervergleichZeichnetMusterAnnotationUndMaskengruppe() throws {
        for route in Route.allCases {
            let gray = route == .softMask
            let a = try Self.document(route, jpeg: try Self.photo(600, 800, seed: 0, gray: gray), w: 600, h: 800, gray: gray)
            let b = try Self.document(route, jpeg: try Self.photo(600, 800, seed: 2.5, gray: gray), w: 600, h: 800, gray: gray)
            defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
            let same = try #require(try RenderDifferential.compare(sourceURL: a, outputURL: a).first)
            #expect(same.ssim > 0.999)
            let differ = try #require(try RenderDifferential.compare(sourceURL: a, outputURL: b).first)
            // Die Maskengruppe moduliert nur eine Füllfarbe, deshalb keine schärfere Schwelle.
            #expect(differ.ssim < 0.95, "\(route): SSIM \(differ.ssim) – die Stelle wird nicht gezeichnet")
            #expect(differ.changedAreaRatio > 0.2, "\(route): CAR \(differ.changedAreaRatio)")
        }
    }

    @Test(.hangGuard) func stufenWirkenAufMusterStempelUndMaskengruppe() throws {
        for route in Route.allCases {
            let gray = route == .softMask
            let jpeg = try Self.photo(1667, 2222, gray: gray)
            let url = try Self.document(route, jpeg: jpeg, gray: gray)
            defer { try? FileManager.default.removeItem(at: url) }
            let input = Compressor.fileSize(of: url)
            // Vergleich: dasselbe Bild in gleicher Größe direkt auf der Seite.
            let direct = try Self.page("e2e-direkt-\(route)", media: (400, 533)) { b in
                let cs = gray ? "/DeviceGray" : "/DeviceRGB"
                let img = b.addStream(dictionary: "/Type/XObject/Subtype/Image/Width 1667/Height 2222/ColorSpace\(cs)/BitsPerComponent 8/Filter/DCTDecode", data: jpeg)
                return ("/Resources<</XObject<</Im0 \(img) 0 R>>>>", "q 300 0 0 400 0 0 cm /Im0 Do Q")
            }
            defer { try? FileManager.default.removeItem(at: direct) }
            var sizes: [Int64] = [], widths: [Int] = []
            for mode in [CompressionMode.small, .smart, .quality] {
                let out = try Compressor().compress(inputURL: url, mode: mode).outputURL
                sizes.append(Int64(Compressor.fileSize(of: out)))
                let image = try #require(try PDFCoreDocument(path: out.path).imageResources().first)
                widths.append(image.width)

                // Dieselbe Entscheidung wie auf der Seite: Die Platzierung ist
                // die einzige Eingabe, die sich unterscheidet.
                let directOut = try Compressor().compress(inputURL: direct, mode: mode).outputURL
                let directImage = try #require(try PDFCoreDocument(path: directOut.path).imageResources().first)
                #expect(image.width == directImage.width, "\(route) \(mode): \(image.width) statt \(directImage.width) wie auf der Seite")
                try? FileManager.default.removeItem(at: directOut)

                let page = try #require(try RenderDifferential.compare(sourceURL: url, outputURL: out).first)
                #expect(page.ssim > 0.85, "\(route) \(mode): SSIM \(page.ssim)")

                // Fehlerbild 9: Der zweite Lauf ändert nichts Wesentliches mehr.
                let again = try Compressor().compress(inputURL: out, mode: mode).outputURL
                let second = try #require(try PDFCoreDocument(path: again.path).imageResources().first)
                #expect(second.width == image.width, "\(route) \(mode): zweiter Lauf \(image.width) → \(second.width)")
                #expect(Int64(Compressor.fileSize(of: again)) <= Int64(Compressor.fileSize(of: out)))
                try? FileManager.default.removeItem(at: again)
                try? FileManager.default.removeItem(at: out)
            }
            print("OFFPAGE \(route) eingabe=\(input) groessen=\(sizes) breiten=\(widths)")
            #expect(sizes[0] < sizes[1] && sizes[1] <= sizes[2], "\(route): \(sizes)")
            #expect(sizes[2] < Int64(input), "\(route): \(sizes) von \(input)")
            #expect(widths[0] < widths[1] && widths[1] <= widths[2], "\(route): \(widths)")
        }
    }
}
