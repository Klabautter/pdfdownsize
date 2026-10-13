import Testing
import Foundation
import AppKit
import PDFKit
@testable import PDFTools

/// Phase 3b (Roadmap) – Content-Hash-Dedup über alle indirekten Objekte.
///
/// Festgenagelt werden:
///   1. Merge-artige Fixtures (getrennte Objekte mit identischen Bytes)
///      schrumpfen auf je EIN Objekt; Seitenzahl, Text und Render bleiben
///      unverändert (RenderDifferential-Muster).
///   2. JBIG2Globals-Kandidaten werden NIE gemergt – Globals sind
///      kontextabhängig, ein naiver Byte-Hash würde hier korruptieren.
///   3. `dedupPolicy .off` lässt den Pass vollständig weg.
@Suite struct DedupPipelineTests {

    // MARK: - Helfer

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dedup-\(label)-\(UUID().uuidString).pdf")
    }

    // MARK: - Bridge-Ebene (C-Kern-Regeln)

    /// Die Fixture muss das Problem überhaupt tragen: je Seite EIGENE
    /// Objekte mit denselben Bytes für Bild, Content-Stream und Font-Dict.
    @Test(.hangGuard) func fixtureTrägtGetrennteObjekteMitIdentischenBytes() throws {
        let url = try PDFFixtures.dedupStreamsPDF(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        try #require(doc.pageCount == 2)
        #expect(try doc.imageResources().count == 2,
                "Fixture braucht zwei getrennte Bildobjekte")

        let stats = try doc.deduplicate()
        // Je Duplikat ein Content-Stream und ein Bild.
        #expect(stats.mergedStreams == 2,
                Comment(rawValue: "Streams falsch zusammengeführt: \(stats)"))
        // Das Font-Dict-Duplikat – kanonisch gleiche Nicht-Stream-Objekte.
        #expect(stats.mergedObjects == 1,
                Comment(rawValue: "Dict-Duplikate falsch zusammengeführt: \(stats)"))
        #expect(stats.estimatedBytesSaved > 0,
                Comment(rawValue: "Ohne Schätzung ist die Statistik wertlos: \(stats)"))
    }

    /// Nach dem Dedup zeigen alle Referenzen auf je ein Objekt; Seitenzahl,
    /// Text und Render bleiben unverändert.
    @Test(.hangGuard) func referenzenZeigenAufEinObjektUndInhaltBleibtGleich() throws {
        let url = try PDFFixtures.dedupStreamsPDF(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)

        let doc = try PDFCoreDocument(path: url.path)
        _ = try doc.deduplicate()
        let out = Self.tempURL("merged")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)

        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pageCount == before.pageCount, "Seiten verloren")
        let losses = PDFSemanticSnapshot.differences(before, after)
            .filter { $0.severity <= .high }
        #expect(losses.isEmpty,
                Comment(rawValue: losses.map(\.message).joined(separator: " | ")))

        // Alle Platzierungen verweisen auf EIN Bildobjekt.
        let core = try PDFCoreDocument(path: out.path)
        #expect(try core.imageResources().count == 1,
                "Es liegen noch mehrere Bildobjekte vor")
        // Und das Ergebnis rendert pixelgleich zur Quelle.
        let render = try RenderDifferential.compare(sourceURL: url,
                                                    outputURL: out, dpi: 150)
        #expect(render.count == 2)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 },
                Comment(rawValue: "Render hat sich verändert: "
                    + "\(render.map(\.changedAreaRatio))"))
    }

    /// Gegenprobe zum Stream-Merge: VERSCHIEDENE Streams werden nicht
    /// zusammengeführt.
    @Test(.hangGuard) func verschiedeneStreamsBleibenGetrennt() throws {
        // Zwei Seiten, deren Bilder und Content-Streams sich unterscheiden.
        let url = try PDFFixtures.manyImagesPDF(count: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.deduplicate()
        #expect(stats.mergedStreams == 0,
                "\(stats.mergedStreams) Streams gemergt, obwohl verschieden")
        #expect(stats.mergedObjects == 0)
    }

    /// JBIG2Globals: identischer Seitenstrom, verschiedene Globals – genau
    /// der Fall, in dem ein naiver Hash korruptieren würde.
    @Test(.hangGuard) func jbig2GlobalsKandidatenBleibenGetrennt() throws {
        let url = try PDFFixtures.jbig2GlobalsPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        try #require(doc.pageCount == 2)
        #expect(try doc.imageResources().count == 2)

        let stats = try doc.deduplicate()
        #expect(stats.mergedStreams == 0,
                Comment(rawValue: "JBIG2Globals-Kandidat wurde gemergt: \(stats)"))

        // Auch nach dem Schreiben sind beide Bilder getrennt vorhanden.
        let out = Self.tempURL("jbig2")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let core = try PDFCoreDocument(path: out.path)
        #expect(try core.imageResources().count == 2,
                "Nach dem Schreiben fehlt ein JBIG2-Bild")
        #expect(core.pageCount == 2)
    }

    // MARK: - V2-8 (§14.7) – Duplicate Form XObjects
    //
    // Statusprüfung + Festnagelung: Der bestehende Whitelist-Pass mergt
    // Form-XObjects bereits GENAU dann, wenn Content-Hash und die
    // kanonische Dict-Form (inkl. /Resources) identisch sind. Mehr wird
    // bewusst NICHT geöffnet: Schlüssel außerhalb der Whitelist (/Matrix,
    // /Group, /OC) bleiben getrennt, weil Placement-/Transparenz-/State-
    // Semantik dort nicht nachweislich gleich ist.

    @Test(.hangGuard) func identischeFormenMergenBeiGleichemContentUndResources()
        throws {
        let url = try PDFFixtures.identicalFormXObjectsPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)

        let stats = try doc.deduplicate()
        #expect(stats.mergedStreams == 1,
                "Die zweite identische Form muss absorbiert werden: \(stats)")

        let out = Self.tempURL("forms-merged")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        try PDFCoreDocument(path: out.path).check()
        let render = try RenderDifferential.compare(sourceURL: url,
                                                    outputURL: out)
        #expect(render.count == 2)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 },
                "Form-Render verändert: \(render.map(\.changedAreaRatio))")
    }

    @Test(.hangGuard) func formenMitMatrixBleibenBewusstGetrennt() throws {
        // Beide Formen tragen DENSELBEN /Matrix-Eintrag – trotzdem kein
        // Merge: /Matrix liegt außerhalb der Vergleichs-Whitelist, weil
        // Placement-Semantik nicht nachweislich gleich ist (§14.7).
        let url = try PDFFixtures.identicalFormXObjectsPDF(withMatrix: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.deduplicate()
        #expect(stats.mergedStreams == 0,
                "Form mit /Matrix wurde gemergt: \(stats)")
    }

    // MARK: - Pipeline-Ebene

    /// Über die Pipeline: Der Pass läuft nach den Bildtransformationen, vor
    /// dem Write-Pass; die Statistik landet im Ergebnis.
    @Test(.hangGuard) func pipelineMergeErhältSemantikUndSchrumpft() throws {
        let url = try PDFFixtures.dedupStreamsPDF(pages: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)

        let out = Self.tempURL("pipeline")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url,
                                                  outputURL: out,
                                                  options: .smart)

        #expect(outcome.execution.deduplicatedStreams >= 5,
                Comment(rawValue: "Content-Stream-Duplikate fehlen in der "
                    + "Statistik: \(outcome.execution.deduplicatedStreams)"))
        #expect(outcome.execution.deduplicatedObjects >= 5,
                Comment(rawValue: "Font-Dict-Duplikate fehlen in der "
                    + "Statistik: \(outcome.execution.deduplicatedObjects)"))

        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pageCount == before.pageCount, "Seiten verloren")
        let losses = PDFSemanticSnapshot.differences(before, after)
            .filter { $0.severity <= .high }
        #expect(losses.isEmpty,
                Comment(rawValue: losses.map(\.message).joined(separator: " | ")))

        // Alle sechs Seiten verweisen auf dasselbe Bildobjekt.
        let core = try PDFCoreDocument(path: out.path)
        #expect(try core.imageResources().count == 1)
        let render = try RenderDifferential.compare(sourceURL: url,
                                                    outputURL: out, dpi: 150)
        #expect(render.count == 6)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 },
                "Render hat sich verändert")
    }

    /// dedupPolicy .off → der Dedup läuft nicht, nichts wird verändert.
    @Test(.hangGuard) func dedupPolicyOffLässtAllesUnangetastet() throws {
        let url = try PDFFixtures.dedupStreamsPDF(pages: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = CompressionOptions.smart
        options.dedupPolicy = .off

        let out = Self.tempURL("off")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url,
                                                  outputURL: out,
                                                  options: options)

        #expect(outcome.execution.deduplicatedStreams == 0)
        #expect(outcome.execution.deduplicatedObjects == 0)
        #expect(outcome.execution.dedupEstimatedBytesSaved == 0)
        #expect(outcome.execution.mergedDuplicateImages == 0,
                "Auch die Bild-Dedup ist von der Politik ausgeschlossen")

        let core = try PDFCoreDocument(path: out.path)
        #expect(try core.imageResources().count == 4,
                "Ohne Dedup müssen vier Bildobjekte bleiben")
    }

    // MARK: - Messzahl (10 identische Bildseiten)

    /// Merge-artiges Dokument mit zehn identischen Bildseiten: Mit Dedup
    /// bleibt je EIN Bild-, Content- und Font-Objekt übrig. Die Messzahl
    /// steht im Laufprotokoll („Dedup-Messung“).
    @Test(.hangGuard) func zehnIdentischeBildseitenSchrumpfenMerkbar() throws {
        let url = try PDFFixtures.dedupStreamsPDF(pages: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let input = Compressor.fileSize(of: url)

        let outAuto = Self.tempURL("messung-auto")
        let outOff = Self.tempURL("messung-off")
        defer {
            try? FileManager.default.removeItem(at: outAuto)
            try? FileManager.default.removeItem(at: outOff)
        }
        var offOptions = CompressionOptions.smart
        offOptions.dedupPolicy = .off
        _ = try CompressionPipeline.run(inputURL: url, outputURL: outAuto,
                                        options: .smart)
        _ = try CompressionPipeline.run(inputURL: url, outputURL: outOff,
                                        options: offOptions)

        let auto = Compressor.fileSize(of: outAuto)
        let off = Compressor.fileSize(of: outOff)
        let ratio = Double(auto) / Double(off)
        print("Dedup-Messung 10 identische Bildseiten: input=\(input) "
            + "auto=\(auto) off=\(off) verhältnis=\(String(format: "%.3f", ratio))")

        #expect(auto < off, "Mit Dedup nicht kleiner: \(auto) vs \(off)")
        #expect(ratio < 0.75,
                "Auf zehn identischen Seiten bleibt zu viel übrig: \(ratio)")
    }
}
