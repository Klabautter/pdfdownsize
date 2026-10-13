import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Phase 5a (Roadmap) – Font-Attribution, Font-Dedup, Unused-Font-GC.
///
/// Festgenagelt werden:
///   1. Merge-artige Fixtures (dieselbe Font-Datei als zwei getrennte
///      Font-Objekte) werden auf EIN Objekt zusammengeführt; Text-Extraction
///      und Render bleiben unverändert (RenderDifferential-Muster).
///   2. Ein unbenutzter Font im Resources-Dict einer Seite (kein Tf) wird
///      beräumt, der Output schrumpft.
///   3. Ein genutzter Font bleibt immer stehen.
///   4. `fontPolicy .off` lässt Fonts vollständig unangetastet.
///   5. Unterschiedliche /Widths verhindern den Merge – gleiche
///      Fontprogramme allein reichen nicht (Semantikrisiko).
@Suite struct FontDedupTests {

    // MARK: - Helfer

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("font5-\(label)-\(UUID().uuidString).pdf")
    }

    // MARK: - Bridge-Ebene (C-Kern-Regeln)

    /// Die Fixture muss das Problem überhaupt tragen: je Seite ein EIGENES
    /// Font-Dict, aber dasselbe Fontprogramm (identische Bytes).
    @Test(.hangGuard) func fixtureTrägtGetrennteFontObjekteMitIdentischemProgramm()
        throws {
        let url = try PDFFixtures.dedupFontsPDF(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        try #require(doc.pageCount == 2)

        let stats = try doc.auditFonts()
        #expect(stats.fontObjects == 2,
                Comment(rawValue: "Font-Dicts falsch gezählt: \(stats)"))
        #expect(stats.fontFileStreams == 2,
                Comment(rawValue: "Fontprogramme falsch gezählt: \(stats)"))
        #expect(stats.duplicateFontRefsRemoved == 1,
                Comment(rawValue: "Semantische Duplikate nicht erkannt: \(stats)"))
        #expect(stats.estimatedBytesSaved > 0,
                Comment(rawValue: "Ohne Schätzung ist die Statistik wertlos: \(stats)"))
        #expect(stats.unusedFontsRemoved == 0,
                Comment(rawValue: "Genutzte Fonts dürfen nicht beräumt werden: \(stats)"))
    }

    /// Nach dem Merge zeigt jede Referenz auf EIN Font-Objekt; Seitenzahl,
    /// Text und Render bleiben unverändert.
    @Test(.hangGuard) func mergeReduziertAufEinFontUndErhältSemantik() throws {
        let url = try PDFFixtures.dedupFontsPDF(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)

        let doc = try PDFCoreDocument(path: url.path)
        _ = try doc.auditFonts()
        let out = Self.tempURL("merged")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)

        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pageCount == before.pageCount, "Seiten verloren")
        #expect(after.pages.map(\.textFingerprint) == before.pages.map(\.textFingerprint),
                "Text-Extraction hat sich verändert")
        #expect(after.pages.allSatisfy { $0.textCharacterCount > 0 },
                "Text verschwunden (vorher \(before.pages.map(\.textCharacterCount)))")
        let losses = PDFSemanticSnapshot.differences(before, after)
            .filter { $0.severity <= .high }
        #expect(losses.isEmpty,
                Comment(rawValue: losses.map(\.message).joined(separator: " | ")))

        // Genau EIN Font-Dict bleibt übrig.
        let core = try PDFCoreDocument(path: out.path)
        let stats = try core.auditFonts()
        #expect(stats.fontObjects == 1,
                Comment(rawValue: "Es liegen noch \(stats.fontObjects) Font-Dicts vor"))
        #expect(stats.fontFileStreams == 1,
                "Es liegen noch FontProgramm-Duplikate vor")

        // Und das Ergebnis rendert pixelgleich zur Quelle.
        let render = try RenderDifferential.compare(sourceURL: url,
                                                    outputURL: out, dpi: 150)
        #expect(render.count == 2)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 },
                Comment(rawValue: "Render hat sich verändert: "
                    + "\(render.map(\.changedAreaRatio))"))
    }

    /// Unterschiedliche /Widths: gleiche Fontprogramme, aber semantisch
    /// verschieden – kein Merge.
    @Test(.hangGuard) func unterschiedlicheWidthsVerhindernMerge() throws {
        let url = try PDFFixtures.dedupFontsPDF(pages: 2, widthsVary: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)

        let stats = try doc.auditFonts()
        #expect(stats.fontObjects == 2)
        #expect(stats.duplicateFontRefsRemoved == 0,
                Comment(rawValue: "Verschiedene Widths wurden gemergt: \(stats)"))
        #expect(stats.estimatedBytesSaved == 0)

        let out = Self.tempURL("widths")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let core = try PDFCoreDocument(path: out.path)
        #expect(try core.auditFonts().fontObjects == 2,
                "Nach dem Schreiben fehlt ein Font")
    }

    // MARK: - Unused-Font-GC

    /// Ein Font im Resources-Dict, den kein Tf benutzt, wird beräumt; der
    /// genutzte Font bleibt, der Output schrumpft.
    @Test(.hangGuard) func gcEntferntUnbenutztenFontUndSchrumpft() throws {
        let url = try PDFFixtures.unusedFontPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let input = Compressor.fileSize(of: url)
        let before = try PDFSemanticSnapshot.capture(url)

        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.auditFonts()
        #expect(stats.fontObjects == 2,
                Comment(rawValue: "Fixture trägt nicht zwei Font-Dicts: \(stats)"))
        #expect(stats.unusedFontsRemoved == 1,
                Comment(rawValue: "Unbenutzter Font nicht beräumt: \(stats)"))
        #expect(stats.estimatedBytesSaved > 0,
                "Die GC-Ersparnis (Fontprogramm) ist nicht messbar")

        let out = Self.tempURL("gc")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        #expect(Compressor.fileSize(of: out) < input,
                "Output nicht kleiner: \(input) → \(Compressor.fileSize(of: out))")

        // Der genutzte Font bleibt; das Programm des unbenutzten ist weg.
        let core = try PDFCoreDocument(path: out.path)
        let after = try core.auditFonts()
        #expect(after.fontObjects == 1,
                Comment(rawValue: "Genutzter Font fehlt oder zu viel entfernt: \(after)"))
        #expect(after.fontFileStreams == 0,
                "Das Programm des unbenutzten Fonts lebt noch")

        // Text-Extraction unverändert (der genutzte Font wurde nie angefasst).
        let snapshot = try PDFSemanticSnapshot.capture(out)
        #expect(snapshot.pages.map(\.textFingerprint) == before.pages.map(\.textFingerprint),
                "Text-Extraction hat sich verändert")
        #expect(snapshot.pageCount == 1)
    }

    /// Die Pipeline führt die GC ebenfalls aus und meldet sie.
    @Test(.hangGuard) func pipelineTrägtUnbenutztenFont() throws {
        let url = try PDFFixtures.unusedFontPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let input = Compressor.fileSize(of: url)

        let out = Self.tempURL("gc-pipeline")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url,
                                                  outputURL: out,
                                                  options: .smart)
        #expect(outcome.execution.removedUnusedFonts == 1,
                Comment(rawValue: "Statistik fehlt: \(outcome.execution.removedUnusedFonts)"))
        #expect(outcome.execution.fontEstimatedBytesSaved > 0)
        #expect(Compressor.fileSize(of: out) < input,
                "Output nicht kleiner als das Input")
    }

    // MARK: - V2-5 (§11.7) – Tf-Nutzung über die /Contents-Array-Grenze

    /// statab_2012 als Fixture: Stream 1 endet mit `/F1 `, Stream 2 beginnt
    /// mit `12 Tf` – Name und Operator sind über die Streamgrenze GETEILT.
    /// Der Zusammensetzungs-Scan des Tf-Scanners muss die Nutzung erkennen:
    /// Die GC fasst den Font nicht an (vor dem Fix wurde er fälschlich
    /// beräumt und die Textextraktion drehte), und die Pipeline führt
    /// denselben Fall e2e.
    @Test(.hangGuard) func gcErkenntTfNutzungÜberContentsArrayGrenze() throws {
        let url = try PDFFixtures.splitTfContentsPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)
        #expect(before.pages[0].textCharacterCount > 0,
                "Fixture muss extrahierbaren Text tragen")

        // Bridge-Ebene: auditFonts darf /F1 NICHT beräumen.
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.auditFonts()
        #expect(stats.fontObjects == 1,
                Comment(rawValue: "Fixture trägt nicht genau einen Font: \(stats)"))
        #expect(stats.unusedFontsRemoved == 0,
                Comment(rawValue:
                    "Der geteilte Tf wurde nicht als Nutzung erkannt – der "
                    + "Scanner fasst einen GENUTZTEN Font an: \(stats)"))

        // Nach dem Schreiben: Font bleibt, Text bleibt.
        let out = Self.tempURL("split-tf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pages.map(\.textFingerprint) == before.pages.map(\.textFingerprint),
                "Text-Extraction hat sich verändert")
    }

    /// Derselbe Fall durch die ganze Pipeline: Smart mit Font-Pass darf die
    /// Seite nicht verändern (der permanente §11.7-Exit, klein gehalten).
    @Test(.hangGuard) func pipelineErhältSeiteMitGeteiltemTf() throws {
        let url = try PDFFixtures.splitTfContentsPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)

        let out = Self.tempURL("split-tf-pipeline")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url,
                                                  outputURL: out,
                                                  options: .smart)
        #expect(outcome.execution.removedUnusedFonts == 0,
                "Die Pipeline beräumte einen genutzten Font")
        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pages.map(\.textFingerprint) == before.pages.map(\.textFingerprint),
                "Text-Extraction hat sich verändert")
    }

    // MARK: - Politik

    /// fontPolicy .off → keine Font-Änderung; beide Font-Dicts und das
    /// unbenutzte Programm bleiben im Output.
    @Test(.hangGuard) func fontPolicyOffLässtFontsUnangetastet() throws {
        let url = try PDFFixtures.dedupFontsPDF(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = CompressionOptions.smart
        options.fontPolicy = .off

        let out = Self.tempURL("off")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url,
                                                  outputURL: out,
                                                  options: options)
        #expect(outcome.execution.deduplicatedFontRefs == 0)
        #expect(outcome.execution.removedUnusedFonts == 0)
        #expect(outcome.execution.fontEstimatedBytesSaved == 0)
        #expect(outcome.execution.auditedFontObjects == 0,
                "Ohne Politik läuft nicht mal das Inventar")

        // Beide Font-Dicts und beide Fontprogramme sind noch da (Zählung im
        // Wegwerf-Handle; das Audit verändert nur im Speicher).
        let core = try PDFCoreDocument(path: out.path)
        let stats = try core.auditFonts()
        #expect(stats.fontObjects == 2,
                Comment(rawValue: "Font-Dicts trotz .off verändert: \(stats)"))
        #expect(stats.fontFileStreams == 2)
        #expect(stats.duplicateFontRefsRemoved == 1,
                Comment(rawValue: "Der Output muss weiterhin ZWEI mergebare "
                    + "Dicts tragen – nur so beweist die Zählung, dass .off "
                    + "wirklich stillhielt"))
    }

    /// Smart (Default .auto) führt den Font-Pass über die Pipeline aus; die
    /// Statistik landet im Result, und die Politik fließt in den Plan.
    @Test(.hangGuard) func pipelineFührtFontPassAusUndMeldetStatistik() throws {
        let url = try PDFFixtures.dedupFontsPDF(pages: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: .smart)
        #expect(planned.plan.fontPolicy == .auto)

        let out = Self.tempURL("pipeline")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url,
                                                  outputURL: out,
                                                  options: .smart)
        #expect(outcome.execution.auditedFontObjects == 4,
                Comment(rawValue: "Inventar unvollständig: "
                    + "\(outcome.execution.auditedFontObjects)"))
        #expect(outcome.execution.auditedFontFileStreams == 4)
        #expect(outcome.execution.deduplicatedFontRefs == 3,
                Comment(rawValue: "Merge unvollständig: "
                    + "\(outcome.execution.deduplicatedFontRefs)"))
        #expect(outcome.execution.fontEstimatedBytesSaved == 3 * 512,
                Comment(rawValue: "Schätzung entspricht nicht drei Programmen: "
                    + "\(outcome.execution.fontEstimatedBytesSaved)"))

        let core = try PDFCoreDocument(path: out.path)
        #expect(try core.auditFonts().fontObjects == 1)
    }

    /// .off in den Optionen landet im Plan (Protokoll-Weitergabe).
    @Test(.hangGuard) func politikFließtInDenPlan() throws {
        let url = try PDFFixtures.dedupFontsPDF(pages: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = CompressionOptions.smart
        options.fontPolicy = .off
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: options)
        #expect(planned.plan.fontPolicy == .off)
        #expect(planned.plan.dedupPolicy == .auto,
                "Die Dedup-Politik darf von der Font-Politik nicht mitgezogen werden")
    }
}
