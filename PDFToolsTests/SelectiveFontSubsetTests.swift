import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Phase V2-8 (Masterplan §14.1/§14.4) – Selektives Font-Subsetting mit
/// je-Font-QA.
///
/// Festgenagelt werden:
///   1. End-to-End im Produktionspfad: Der gewählte Font wird subsettett,
///      Text/Render bleiben. (Seit V2-11 ist der Candidate-Pfad der EINZIGE
///      Pfad – der globale Snapshot-Pass ist entfernt, §4.18.)
///   2. §14.4-Kernmechanik: Scheitert die QA eines Fonts, rollt NUR dieser
///      Font zurück (keep) – die zuvor akzeptierten Fonts bleiben.
///   3. Die je-Font-QA erkennt Textabweichungen.
///   4. `fontSubsettingPolicy .off` schaltet den selektiven Pfad ab
///      (Fontprogramme byteidentisch); `.on` (Default) erlaubt ihn.
@Suite struct SelectiveFontSubsetTests {

    // MARK: - Helfer

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("selfont-\(label)-\(UUID().uuidString).pdf")
    }

    static func requireFixture(_ make: () throws -> URL?) throws -> URL {
        guard let url = try make() else {
            throw TestSkip("Kein TrueType-Systemfont verfügbar (CI-fremd)")
        }
        return url
    }

    static func candidateOptions(resourceGC: Bool = false) -> CompressionOptions {
        var options = CompressionOptions.smart
        options.featureFlags.candidateEngine = true
        options.featureFlags.selectiveFontSubset = true
        if resourceGC { options.resourceGCPolicy = .auto }
        return options
    }

    // MARK: 1 – End-to-End

    @Test(.hangGuard) func selektivesSubsettingLaeuftEndToEnd() throws {
        let url = try Self.requireFixture { try PDFFixtures.subsetFontPDF() }
        defer { try? FileManager.default.removeItem(at: url) }
        let inputBytes = Compressor.fileSize(of: url)
        let before = try PDFSemanticSnapshot.capture(url)

        let out = Self.tempURL("e2e")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url,
                                                  outputURL: out,
                                                  options: Self.candidateOptions())

        #expect(outcome.execution.selectiveSubsettedFonts == 1)
        #expect(outcome.execution.selectiveRefusedFonts == 0)
        #expect(outcome.execution.selectiveRolledBackFonts == 0)
        #expect(outcome.execution.selectiveFontSubsetEstimatedBytesSaved > 0)

        // NEVER-BREAK: Struktur grün, Text identisch, Render bitgleich.
        try PDFCoreDocument(path: out.path).check()
        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pages.map(\.textFingerprint)
            == before.pages.map(\.textFingerprint))
        let render = try RenderDifferential.compare(sourceURL: url,
                                                    outputURL: out)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 })
        #expect(Compressor.fileSize(of: out) < inputBytes)
    }

    // MARK: 2 – §14.4: Nur der schuldige Font rollt zurück

    @Test(.hangGuard) func qaFailRolltNurDiesenFontZurueck() throws {
        let url = try Self.requireFixture {
            try PDFFixtures.twoSubsetFontsPDF()
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let inputBytes = Compressor.fileSize(of: url)

        // Referenz: vollständiges Subsetting BEIDER Fonts (C-Kern direkt).
        let fullDoc = try PDFCoreDocument(path: url.path)
        _ = try fullDoc.subsetFonts()
        let fullOut = Self.tempURL("full")
        defer { try? FileManager.default.removeItem(at: fullOut) }
        try fullDoc.save(to: fullOut)

        // Selektiv mit injiziertem QA-Fail für den ZWEITEN Font.
        let doc = try PDFCoreDocument(path: url.path)
        let candidates = try doc.fontSubsetCandidates()
            .filter(\.subsettable)
            .sorted { $0.objectID.objectNumber < $1.objectID.objectNumber }
        #expect(candidates.count == 2,
                "Fixture braucht zwei subsetting-sichere Fonts")
        var calls = 0
        let outcome = try FontOptimizer.applySelectiveSubsetting(
            document: doc,
            decisions: candidates.map {
                FontOptimizer.Decision(objectID: $0.objectID,
                                       pages: $0.pages,
                                       estimatedSaving: $0.estimatedBytesSaved)
            },
            verify: { _, _, _ in
                calls += 1
                // Aufruf 1 ist der Schnellweg (beide Fonts auf einmal) und
                // scheitert; danach der Einzelweg: Font 1 besteht, Font 2
                // scheitert (2026-10-15).
                return calls == 2
            })

        #expect(outcome.subsetted == 1)
        #expect(outcome.rolledBack == 1)
        #expect(calls == 3)

        let rolledOut = Self.tempURL("rolled")
        defer { try? FileManager.default.removeItem(at: rolledOut) }
        try outcome.document.save(to: rolledOut)
        try PDFCoreDocument(path: rolledOut.path).check()

        // Semantik: beide Seiten extrahieren unverändert.
        let before = try PDFSemanticSnapshot.capture(url)
        let after = try PDFSemanticSnapshot.capture(rolledOut)
        #expect(after.pages.map(\.textFingerprint)
            == before.pages.map(\.textFingerprint))
        #expect(after.pageCount == before.pageCount)

        // Die Bytes liegen ZWISCHEN: Font 1 geschmaler als das Original,
        // Font 2 komplett behalten (deshalb größer als das Voll-Subset).
        let rolledBytes = Compressor.fileSize(of: rolledOut)
        #expect(rolledBytes < inputBytes,
                "Font 1 wurde subsettett: \(inputBytes) → \(rolledBytes)")
        #expect(rolledBytes > Compressor.fileSize(of: fullOut),
                "Der zurückgerollte Font 2 muss im Programm bleiben")
    }

    // MARK: 3 – Die je-Font-QA selbst

    @Test(.hangGuard) func jeFontQAErkenntTextAbweichung() throws {
        let a = try Self.requireFixture {
            try PDFFixtures.subsetFontPDF(text: "ABC", name: "selfont-qa-a")
        }
        defer { try? FileManager.default.removeItem(at: a) }
        let b = try Self.requireFixture {
            try PDFFixtures.subsetFontPDF(text: "XYZ", name: "selfont-qa-b")
        }
        defer { try? FileManager.default.removeItem(at: b) }

        // Identische Datei: alle Seiten gleich → QA besteht.
        #expect(FontOptimizer.fontQAPasses(a, a, [0]))
        // Abweichender Text: QA scheitert.
        #expect(!FontOptimizer.fontQAPasses(a, b, [0]))
        // Fehlende/leere Stichprobe ändert die Textpflicht nicht.
        #expect(!FontOptimizer.fontQAPasses(a, b, []))
    }

    @Test func stichprobeIstDeterministischUndGekappt() {
        // Wenige Seiten: vollständig.
        #expect(FontOptimizer.renderSamplePages([2, 0, 1]) == [0, 1, 2])
        // Viele Seiten: erste, mittlere, letzte – dedupliziert, sortiert.
        let wide = FontOptimizer.renderSamplePages(Array(0..<100))
        #expect(wide == [0, 50, 99])
        #expect(wide.count <= FontOptimizer.renderSampleMaximumPages)
    }

    // MARK: 4 – Politik steuert den selektiven Pfad (V2-11)

    /// V2-11: Der globale Snapshot-Pass (`fontSubsettingPolicy .on` →
    /// `CompressionExecutor.applyFontSubsetting`) ist entfernt. Die Politik
    /// steuert heute die fontSubsets-ENTSCHEIDUNG im Planner: `.off` lässt
    /// Fontprogramme byteidentisch, `.on` (Default) erlaubt den selektiven
    /// Pfad. Kein Doppel-Mutation-Fall mehr – es gibt nur einen Weg.
    @Test(.hangGuard) func politikOffSchaltetSelektivenPassAb() throws {
        let url = try Self.requireFixture { try PDFFixtures.subsetFontPDF() }
        defer { try? FileManager.default.removeItem(at: url) }

        // .off: keine Font-Entscheidung, Programm bleibt.
        var off = CompressionOptions.smart
        off.fontSubsettingPolicy = .off
        let offOut = Self.tempURL("policy-off")
        defer { try? FileManager.default.removeItem(at: offOut) }
        let offOutcome = try CompressionPipeline.run(inputURL: url,
                                                     outputURL: offOut,
                                                     options: off)
        #expect(offOutcome.execution.selectiveSubsettedFonts == 0)
        #expect(offOutcome.execution.selectiveRefusedFonts == 0)
        #expect(offOutcome.execution.selectiveRolledBackFonts == 0)
        #expect(offOutcome.plan.fontSubsets.isEmpty)

        // .on (Default): selektives Subsetting läuft, EIN Font.
        let bothOut = Self.tempURL("policy-on")
        defer { try? FileManager.default.removeItem(at: bothOut) }
        let bothOutcome = try CompressionPipeline.run(inputURL: url,
                                                      outputURL: bothOut,
                                                      options: .smart)
        #expect(bothOutcome.execution.selectiveSubsettedFonts == 1)
        #expect(bothOutcome.execution.selectiveRolledBackFonts == 0)
        #expect(!bothOutcome.plan.fontSubsets.isEmpty,
                "Der Plan trägt die ausführbaren Subset-Entscheidungen")
    }

    // MARK: 5 – E2E: font-lastig + ungenutzte Ressourcen

    /// E2E-Zahlen (Laufprotokoll): Arial-Klasse-Fonts + ungenutzte
    /// Resource-Einträge, candidateEngine + selektives Subsetting +
    /// Resource GC. Die gedruckten Zahlen sind der Rapport-Beweis.
    @Test(.hangGuard) func fontLastigesFixtureMitUngenutztenRessourcen()
        throws {
        let url = try Self.requireFixture {
            try PDFFixtures.twoSubsetFontsPDF(withUnusedResources: true)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let inputBytes = Compressor.fileSize(of: url)
        let before = try PDFSemanticSnapshot.capture(url)

        let out = Self.tempURL("born-digital")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(
            inputURL: url, outputURL: out,
            options: Self.candidateOptions(resourceGC: true))

        let outputBytes = Compressor.fileSize(of: out)
        let e = outcome.execution
        print("E2E Born-Digital V2: input=\(inputBytes) output=\(outputBytes) "
            + "gespart=\(inputBytes - outputBytes) "
            + "(\(String(format: "%.1f", 100.0 * Double(inputBytes - outputBytes) / Double(inputBytes))) %) "
            + "selektiveFonts=\(e.selectiveSubsettedFonts) "
            + "(refused=\(e.selectiveRefusedFonts) rolledBack=\(e.selectiveRolledBackFonts)) "
            + "fontBytes=\(e.selectiveFontSubsetEstimatedBytesSaved) "
            + "gcEntries=\(e.resourceGCEntriesRemoved) "
            + "gcBytes=\(e.resourceGCEstimatedBytesSaved)")

        #expect(e.selectiveSubsettedFonts == 2)
        #expect(e.resourceGCEntriesRemoved == 3,
                "ImUnused, GSUnused, SHUnused müssen getragen werden")
        try PDFCoreDocument(path: out.path).check()
        let after = try PDFSemanticSnapshot.capture(out)
        #expect(after.pages.map(\.textFingerprint)
            == before.pages.map(\.textFingerprint))
        let render = try RenderDifferential.compare(sourceURL: url,
                                                    outputURL: out)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 })
        #expect(outputBytes < inputBytes)
    }
}
