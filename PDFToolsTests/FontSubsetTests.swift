import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Phase 5b (Roadmap) – Font-Subsetting über hb-subset.
///
/// Festgenagelt werden:
///   1. Ein Text-PDF mit echtem TrueType-Systemfont + ToUnicode wird
///      subsettet: qpdf-Check grün, Render bitgleich, Text-Extraction
///      identisch, Fontprogramm messbar kleiner.
///   2. `fontSubsettingPolicy .off` (Default) lässt Fontprogramme bytegleich.
///   3. Type3-Fonts werden nie subsettet.
///   4. Korrupte Fontprogramme werden behalten, ohne zu crashen.
///   5. Simulierte Snapshot-Abweichung verwirft das Subset; der Stand davor
///      wird unverändert ausgegeben.
///   6. Identity-H-CIDFonts laufen mit GID-treuer Nummerierung
///      (RETAIN_GIDS), /W bleibt konsistent; /CIDToGIDMap-Ströme verhindern
///      das Subsetting vollständig.
///
/// Fixtures lesen macOS-Systemfonts zur Laufzeit (kein Font im Repo); auf
/// Systemen ohne die Referenz-Fonts skippen die Tests graceful.
@Suite struct FontSubsetTests {

    // MARK: - Helfer

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("font5b-\(label)-\(UUID().uuidString).pdf")
    }

    /// Fixture mit echtem Font oder Skip-Begründung.
    static func requireFixture(_ make: () throws -> URL?) throws -> URL {
        guard let url = try make() else {
            throw TestSkip("Kein TrueType-Systemfont verfügbar (CI-fremd)")
        }
        return url
    }

    // MARK: 1 – Simple-TrueType-Pfad

    @Test(.hangGuard) func echtesTrueTypeWirdSubsettettUndBleibtKonsistent() throws {
        let url = try Self.requireFixture { try PDFFixtures.subsetFontPDF() }
        defer { try? FileManager.default.removeItem(at: url) }
        let inputBytes = Compressor.fileSize(of: url)
        let before = try PDFSemanticSnapshot.capture(url)

        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.subsetFonts()
        #expect(stats.subsettedFonts == 1,
                Comment(rawValue: "Fixture-Font nicht subsettet: \(stats)"))
        #expect(stats.keptFonts == 0)
        #expect(stats.estimatedBytesSaved > 0,
                "Ohne messbare Ersparnis wäre der Pass nicht fürs Bytesparen da")

        let out = Self.tempURL("simple")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)

        // NEVER-BREAK: qpdf-Check-Äquivalent grün, Text unverändert.
        try PDFCoreDocument(path: out.path).check()
        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pageCount == before.pageCount)
        #expect(after.pages.map(\.textFingerprint) == before.pages.map(\.textFingerprint),
                "Text-Extraction hat sich verändert")
        #expect(after.pages.allSatisfy { $0.textCharacterCount > 0 })

        // Render bitgleich (Gate: SSIM/Renderdiff == 1).
        let render = try RenderDifferential.compare(sourceURL: url, outputURL: out)
        #expect(render.count == 1)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 },
                Comment(rawValue: "Render hat sich verändert: "
                    + "\(render.map(\.changedAreaRatio))"))

        // Fontprogramm messbar kleiner: Arial trägt weit über tausend
        // Glyphen, die Ausgabe drei – die Datei besteht hier fast nur aus
        // dem Programm, deshalb taugt die Gesamtgröße als Fontmaß.
        let outputBytes = Compressor.fileSize(of: out)
        #expect(outputBytes < inputBytes,
                "Output nicht kleiner: \(inputBytes) → \(outputBytes)")
        #expect(outputBytes < inputBytes / 2,
                Comment(rawValue: "Subset sollte das Programm drastisch "
                    + "verkleinern: \(inputBytes) → \(outputBytes)"))
    }

    /// Ohne /ToUnicode: volle Code-Raum-Abdeckung über WinAnsiEncoding.
    /// Sicherer, kleinerer Gewinn – aber Render und Extraction bleiben.
    @Test(.hangGuard) func ohneToUnicodeDecktWinAnsiDenCodeRaum() throws {
        let url = try Self.requireFixture {
            try PDFFixtures.subsetFontPDF(toUnicode: false)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)

        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.subsetFonts()
        #expect(stats.subsettedFonts == 1,
                Comment(rawValue: "WinAnsi-Pfad nicht gegriffen: \(stats)"))
        #expect(stats.keptFonts == 0)

        let out = Self.tempURL("no-tounicode")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        try PDFCoreDocument(path: out.path).check()

        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pages.map(\.textFingerprint) == before.pages.map(\.textFingerprint),
                "Extraction ohne ToUnicode hat sich verändert")
        let render = try RenderDifferential.compare(sourceURL: url, outputURL: out)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 },
                Comment(rawValue: "Render hat sich verändert: "
                    + "\(render.map(\.changedAreaRatio))"))
    }

    // MARK: 2 – Politik (V2-11: selektiver Pfad, Default AN)

    @Test(.hangGuard) func politikFließtInDenPlan() throws {
        let url = try PDFFixtures.dedupFontsPDF(pages: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = CompressionOptions.smart
        options.fontSubsettingPolicy = .on
        let planned = try CompressionPipeline.plan(inputURL: url, options: options)
        #expect(planned.plan.fontSubsettingPolicy == .on)
        #expect(planned.plan.fontPolicy == .auto,
                "Die Font-5a-Politik darf von 5b nicht mitgezogen werden")

        var offOptions = CompressionOptions.smart
        offOptions.fontSubsettingPolicy = .off
        let offPlan = try CompressionPipeline.plan(inputURL: url, options: offOptions)
        #expect(offPlan.plan.fontSubsettingPolicy == .off)
    }

    @Test(.hangGuard) func offLässtFontprogrammUnangetastet() throws {
        let url = try Self.requireFixture { try PDFFixtures.subsetFontPDF() }
        defer { try? FileManager.default.removeItem(at: url) }
        let inputBytes = Compressor.fileSize(of: url)

        var options = CompressionOptions.smart
        options.fontSubsettingPolicy = .off
        let out = Self.tempURL("policy-off")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url,
                                                  outputURL: out,
                                                  options: options)
        #expect(outcome.execution.selectiveSubsettedFonts == 0)
        #expect(outcome.execution.selectiveRefusedFonts == 0,
                "Ohne Politik gibt es keine Font-Entscheidung, keine Zählung")
        #expect(outcome.execution.selectiveFontSubsetEstimatedBytesSaved == 0)

        // Zum Kontrast derselbe Lauf mit .on (Default): Der Font schrumpft
        // messbar – hinter der je-Font-QA.
        var onOptions = CompressionOptions.smart
        onOptions.fontSubsettingPolicy = .on
        let onOut = Self.tempURL("policy-on")
        defer { try? FileManager.default.removeItem(at: onOut) }
        let onOutcome = try CompressionPipeline.run(inputURL: url,
                                                    outputURL: onOut,
                                                    options: onOptions)
        #expect(onOutcome.execution.selectiveSubsettedFonts == 1)
        #expect(onOutcome.execution.selectiveRolledBackFonts == 0)
        #expect(onOutcome.execution.selectiveFontSubsetEstimatedBytesSaved > 0)
        #expect(Compressor.fileSize(of: onOut) < inputBytes)
        #expect(Compressor.fileSize(of: onOut) < Compressor.fileSize(of: out),
                Comment(rawValue: ".off muss das Programm behalten – kleiner "
                    + "als .off kann .on nicht werden"))
    }

    // MARK: 3/4 – Konservative Behalte-Pfade

    @Test(.hangGuard) func type3BleibtImmerStehen() throws {
        let url = try PDFFixtures.type3FontPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.subsetFonts()
        #expect(stats.subsettedFonts == 0,
                Comment(rawValue: "Type3 wurde angefasst: \(stats)"))
        #expect(stats.keptFonts == 1)

        // Und der Durchlauf bleibt völlig folgenlos.
        let out = Self.tempURL("type3")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        try PDFCoreDocument(path: out.path).check()
        let before = try PDFSemanticSnapshot.capture(url)
        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pages.map(\.textFingerprint) == before.pages.map(\.textFingerprint))
    }

    @Test(.hangGuard) func korruptesFontprogrammWirdBehalten() throws {
        // dedupFontsPDF trägt synthetische Pseudo-Bytes – kein sfnt.
        let url = try PDFFixtures.dedupFontsPDF(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.subsetFonts()
        #expect(stats.subsettedFonts == 0,
                Comment(rawValue: "Pseudo-Fontprogramm subsettet: \(stats)"))
        #expect(stats.keptFonts == 2)
        try doc.check()
    }

    @Test(.hangGuard) func cidToGIDMapStromVerhindertSubsetting() throws {
        let url = try Self.requireFixture {
            try PDFFixtures.cidSubsetFontPDF(gidMapStream: true)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.subsetFonts()
        #expect(stats.subsettedFonts == 0,
                Comment(rawValue: "Nicht-Identity-Map wurde subsettet: \(stats)"))
        #expect(stats.keptFonts == 2,
                "Type0-Dict und CIDFontType2-Nachfolger zählen als behalten")
        try doc.check()
    }

    // MARK: 5 – Identity-H mit GID-Treue

    @Test(.hangGuard) func identityHWirdGidTreueSubsettett() throws {
        let url = try Self.requireFixture { try PDFFixtures.cidSubsetFontPDF() }
        defer { try? FileManager.default.removeItem(at: url) }
        let inputBytes = Compressor.fileSize(of: url)
        let before = try PDFSemanticSnapshot.capture(url)

        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.subsetFonts()
        #expect(stats.subsettedFonts == 1,
                Comment(rawValue: "Identity-H-Font nicht subsettet: \(stats)"))
        // Der CIDFontType2-Nachfolger ist ein eigenes /Font-Dict und zählt
        // als behalten – er wird über den Type0-Dict mit-subsettett.
        #expect(stats.keptFonts == 1)
        #expect(stats.estimatedBytesSaved > 0)

        let out = Self.tempURL("identity-h")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        try PDFCoreDocument(path: out.path).check()

        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pages.map(\.textFingerprint) == before.pages.map(\.textFingerprint),
                "Text-Extraction (ToUnicode) hat sich verändert")
        let render = try RenderDifferential.compare(sourceURL: url, outputURL: out)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 },
                Comment(rawValue: "GIDs nicht treu erhalten: "
                    + "\(render.map(\.changedAreaRatio))"))
        #expect(Compressor.fileSize(of: out) < inputBytes)
    }

    // MARK: 6 – Je-Font-QA (seit V2-11 der EINZIGE Subsetting-Weg)

    /// Das Gate selbst: gleiche Datei passt, abweichender Text fällt durch.
    /// (Der frühere globale `CompressionExecutor.subsetGatePasses` ist mit
    /// dem V2-Cutover entfernt; die QA lebt je Font in FontOptimizer.)
    @Test(.hangGuard) func gateErkenntTextAbweichung() throws {
        let a = try Self.requireFixture { try PDFFixtures.subsetFontPDF(text: "ABC",
                                                                  name: "gate-a") }
        defer { try? FileManager.default.removeItem(at: a) }
        let b = try Self.requireFixture { try PDFFixtures.subsetFontPDF(text: "XYZ",
                                                                  name: "gate-b") }
        defer { try? FileManager.default.removeItem(at: b) }
        #expect(FontOptimizer.fontQAPasses(a, a, [0]),
                "Identische Datei muss das Gate passieren")
        #expect(!FontOptimizer.fontQAPasses(a, b, [0]),
                "Abweichender Text muss das Gate failen")
    }

    /// End-to-End: Die je-Font-QA verweigert → NUR dieser Font rollt zurück
    /// (keep); der Output trägt den Stand ohne den Font, das Original-
    /// Fontprogramm bleibt vollständig erhalten, Struktur grün.
    @Test(.hangGuard) func qaVerweigerungRolltNurDenFontZurueck() throws {
        let url = try Self.requireFixture { try PDFFixtures.subsetFontPDF() }
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)

        let document = try PDFCoreDocument(path: url.path)
        let out = Self.tempURL("rejected")
        defer { try? FileManager.default.removeItem(at: out) }

        // Eine Font-Entscheidung (wie sie der Planner trägt); die QA wird
        // per Seam hart scheitern lassen.
        let candidate = try #require(
            (try document.fontSubsetCandidates()).first(where: { $0.subsettable }),
            "Fixture-Font sollte subsettable sein")
        let decisions = [
            FontOptimizer.Decision(
                objectID: candidate.objectID,
                pages: candidate.pages,
                estimatedSaving: candidate.estimatedBytesSaved)
        ]
        let outcome = try FontOptimizer.applySelectiveSubsetting(
            document: document, decisions: decisions, verify: { _, _, _ in false })

        #expect(outcome.rolledBack == 1,
                "Verweigerte QA muss den Font zurückrollen")
        #expect(outcome.subsetted == 0,
                "Verworfenen Subset darf es nicht als Gewinn geben")
        #expect(outcome.estimatedBytesSaved == 0)

        try outcome.document.save(to: out)
        try PDFCoreDocument(path: out.path).check()
        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pageCount == before.pageCount)
        #expect(after.pages.map(\.textFingerprint)
                == before.pages.map(\.textFingerprint))
    }
}

/// Skip-Marker für Umgebungen ohne Systemfont – Swift Testing kennt kein
/// natives Skip; der Test scheitert sichtbar an dieser Meldung, wenn die
/// Erwartung (macOS-Referenzfont) nicht erfüllt ist.
struct TestSkip: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
