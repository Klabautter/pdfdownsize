import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Phase V2-8 (Masterplan §14.6) – Resource GC: unbenutzte Einträge aus
/// Resource-Maps (XObject/ExtGState/ColorSpace/Pattern/Shading/Properties).
///
/// Festgenagelt werden:
///   1. Entfernt wird NUR, was kein Operator je benutzt; benutzte Einträge
///      (auch das tiling Pattern über scn) bleiben.
///   2. /AcroForm/DR bleibt grundsätzlich stehen.
///   3. StructTreeRoot schützt Properties vollständig.
///   4. Unscanbarer Content schützt die ganze Map (Whitelist-Muster
///      Font-GC).
///   5. Pipeline-Integration: `.auto` nur im candidateEngine-Pfad, Legacy
///      unverändert, Default `.off`.
@Suite struct ResourceGCTests {

    // MARK: - Helfer

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rgc-\(label)-\(UUID().uuidString).pdf")
    }

    static func candidateOptions(resourceGC: Bool) -> CompressionOptions {
        var options = CompressionOptions.smart
        options.featureFlags.candidateEngine = true
        options.resourceGCPolicy = resourceGC ? .auto : .off
        return options
    }

    // MARK: 1 – Kernverhalten

    @Test(.hangGuard) func entferntNurUnbenutzteEintraege() throws {
        let url = try PDFFixtures.unusedResourcesPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)

        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.removeUnusedResources()

        #expect(stats.xobjectsRemoved == 1, "Nur /Im1 ist unbenutzt")
        #expect(stats.extGStatesRemoved == 1, "Nur /GS1 ist unbenutzt")
        #expect(stats.shadingsRemoved == 1, "SH0 wird nie per sh benutzt")
        #expect(stats.colorSpacesRemoved == 1,
                "CS1 wird nie per cs/CS benutzt; CS0 (scn-Kontext) bleibt")
        #expect(stats.patternsRemoved == 0,
                "P0 wird per scn benutzt und bleibt")
        #expect(stats.propertiesRemoved == 1,
                "MC0 wird nie per BDC/DP benutzt")
        #expect(stats.estimatedBytesSaved > 0,
                "Das unbenutzte Bild trägt messbare Rohbytes")
        #expect(stats.totalEntriesRemoved == 5)

        // Verlustfrei: Struktur grün, Render und Text unverändert, und
        // nur EIN Bild-XObject liegt danach noch im Dokument.
        let out = Self.tempURL("cleaned")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        try PDFCoreDocument(path: out.path).check()
        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pages.map(\.textFingerprint)
            == before.pages.map(\.textFingerprint))
        let render = try RenderDifferential.compare(sourceURL: url,
                                                    outputURL: out)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 })
        let core = try PDFCoreDocument(path: out.path)
        #expect(try core.imageResources().count == 1,
                "Nur das benutzte /Im0 darf übrig bleiben")
    }

    // MARK: 2 – Schutzregeln

    @Test(.hangGuard) func acroFormDRBleibtImmerStehen() throws {
        let url = try PDFFixtures.unusedResourcesPDF(acroFormDR: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.removeUnusedResources()
        // /Im1 (Seite) wird getragen; /ImDR aus /AcroForm/DR niemals.
        #expect(stats.xobjectsRemoved == 1)
        let out = Self.tempURL("dr")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        try PDFCoreDocument(path: out.path).check()
    }

    @Test(.hangGuard) func structTreeSchuetztProperties() throws {
        let url = try PDFFixtures.unusedResourcesPDF(structTree: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.removeUnusedResources()
        #expect(stats.propertiesRemoved == 0,
                "StructTreeRoot: der MCID-/OC-Vertrag geht vor")
        // Die übrigen Kategorien beräumen weiter normal.
        #expect(stats.xobjectsRemoved == 1)
        #expect(stats.extGStatesRemoved == 1)
    }

    @Test(.hangGuard) func unscanbarerContentSchuetztDieGanzeMap() throws {
        let url = try PDFFixtures.unusedResourcesPDF(brokenContent: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.removeUnusedResources()
        #expect(stats.totalEntriesRemoved == 0,
                "Ohne vollständigen Scan wird nichts beräumt: \(stats)")
        let out = Self.tempURL("broken")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let core = try PDFCoreDocument(path: out.path)
        #expect(try core.imageResources().count == 2,
                "Beide XObjects müssen stehen bleiben")
    }

    // A dense shared map previously expanded exponentially: every Form
    // revisited all names already used by its parent and siblings.
    @Test(.hangGuard) func sharedFormsRemainBoundedAndKeepInheritedContexts() throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let images = (0..<2).map { index -> Int in
            return b.addStream(dictionary: "/Type/XObject/Subtype/Image/Width 1/Height 1/ColorSpace/DeviceRGB/BitsPerComponent 8",
                               data: Data([UInt8(index * 200), 40, 80]))
        }
        let forms = (0..<12).map { _ in
            b.addStream(dictionary: "/Type/XObject/Subtype/Form/BBox[0 0 10 10]",
                        content: "q 10 0 0 10 0 0 cm /Im Do Q")
        }
        let content = b.addStream(dictionary: "", content:
            forms.indices.map { "/F\($0) Do" }.joined(separator: " "))
        let formMap = forms.enumerated().map { "/F\($0.offset) \($0.element) 0 R" }
            .joined(separator: " ")
        let pageNumbers = images.map { image in
            b.addPage(parent: pages,
                resources: "<</XObject<<\(formMap) /Im \(image) 0 R>>>>",
                contents: content)
        }
        b.fill(pages, "<</Type/Pages/Kids[\(pageNumbers.map { "\($0) 0 R" }.joined(separator: " "))]/Count 2>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let input = Self.tempURL("shared-contexts")
        let output = Self.tempURL("shared-contexts-cleaned")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try b.build(rootObject: root).write(to: input)
        let doc = try PDFCoreDocument(path: input.path)
        let start = Date()
        let stats = try doc.removeUnusedResources()
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(stats.xobjectsRemoved == 0)
        try doc.save(to: output)
        try PDFCoreDocument(path: output.path).check()
        #expect(try PDFCoreDocument(path: output.path).imageResources().count == 2)
        let render = try RenderDifferential.compare(sourceURL: input, outputURL: output)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 })
    }

    // MARK: 3 – Pipeline-Integration

    @Test(.hangGuard) func politikGiltImProduktionspfad() throws {
        let url = try PDFFixtures.unusedResourcesPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        // .off (Not-Aus): keine GC, auch nicht mit Flags.
        let offOut = Self.tempURL("policy-off")
        defer { try? FileManager.default.removeItem(at: offOut) }
        let offOutcome = try CompressionPipeline.run(inputURL: url,
                                                     outputURL: offOut,
                                                     options: Self.candidateOptions(resourceGC: false))
        #expect(offOutcome.execution.resourceGCEntriesRemoved == 0)
        let coreOff = try PDFCoreDocument(path: offOut.path)
        #expect(try coreOff.imageResources().count == 2)

        // .auto im candidateEngine-Pfad: GC läuft.
        let autoOut = Self.tempURL("policy-auto")
        defer { try? FileManager.default.removeItem(at: autoOut) }
        let autoOutcome = try CompressionPipeline.run(inputURL: url,
                                                      outputURL: autoOut,
                                                      options: Self.candidateOptions(resourceGC: true))
        #expect(autoOutcome.execution.resourceGCEntriesRemoved == 5)
        #expect(autoOutcome.execution.resourceGCEstimatedBytesSaved > 0)
        let coreAuto = try PDFCoreDocument(path: autoOut.path)
        #expect(try coreAuto.imageResources().count == 1)

        // V2-11 – .auto ist Default: dieselbe Wirkung ohne explizites Setzen.
        let defaultOut = Self.tempURL("policy-default")
        defer { try? FileManager.default.removeItem(at: defaultOut) }
        let defaultOutcome = try CompressionPipeline.run(inputURL: url,
                                                         outputURL: defaultOut,
                                                         options: CompressionOptions.smart)
        #expect(defaultOutcome.execution.resourceGCEntriesRemoved == 5,
                "Resource GC (.auto) ist seit V2-11 Teil der Produktion")
    }
}
