import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Phase V2-8 (Masterplan §14.1/§14.3) – Font-Subsetting als Candidate.
///
/// Festgenagelt werden:
///   1. Die Trockenplanung der Bridge (mutate=false) liefert je
///      whitelist-geeignetem Font ObjGen, ehrliche Ersparnis und Seiten –
///      OHNE das Dokument zu verändern.
///   2. Nicht geeignete Fonts tragen ihre 安全-Klassifikation (Type3,
///      korruptes Programm).
///   3. Die Activation Policy (§14.3): Ersparnis ≥ max(64 KB absolut,
///      30 % relativ) – darunter kein Subset-Kandidat.
///   4. Provision und Planner respektieren Flags (§25) und zeichnen die
///      Entscheidungen in CandidateSets/decisions nach.
@Suite struct FontCandidateTests {

    // MARK: - Helfer

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fontcand-\(label)-\(UUID().uuidString).pdf")
    }

    static func requireFixture(_ make: () throws -> URL?) throws -> URL {
        guard let url = try make() else {
            throw TestSkip("Kein TrueType-Systemfont verfügbar (CI-fremd)")
        }
        return url
    }

    static func candidateOptions() -> CompressionOptions {
        var options = CompressionOptions.smart
        options.featureFlags.candidateEngine = true
        options.featureFlags.selectiveFontSubset = true
        return options
    }

    // MARK: 1 – Trockenplanung

    @Test(.hangGuard) func trockenplanungLiefertKandidatenOhneMutation()
        throws {
        let url = try Self.requireFixture { try PDFFixtures.subsetFontPDF() }
        defer { try? FileManager.default.removeItem(at: url) }

        // Zwei identische Handles: nur A wird trockengeplant.
        let docA = try PDFCoreDocument(path: url.path)
        let docB = try PDFCoreDocument(path: url.path)
        let candidates = try docA.fontSubsetCandidates()

        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.subsettable,
                "Arial-Fixture muss subsetting-safe sein")
        #expect(candidate.reason == .safe)
        #expect(candidate.estimatedBytesSaved > 0,
                "Ohne messbare Ersparnis ist die Trockenplanung wertlos")
        #expect(candidate.originalProgramBytes
                    > candidate.estimatedBytesSaved,
                "Die Ersparnis kann nie größer sein als das Programm")
        #expect(candidate.pages == [0],
                "Der Font wird exakt auf Seite 1 benutzt")

        // NICHTS mutiert: Der trockengeplante Stand schreibt bytegleich
        // wie der unberührte (gleicher Writer, gleicher Inhalt).
        let outA = Self.tempURL("dry")
        let outB = Self.tempURL("untouched")
        defer {
            try? FileManager.default.removeItem(at: outA)
            try? FileManager.default.removeItem(at: outB)
        }
        try docA.save(to: outA)
        try docB.save(to: outB)
        #expect(Compressor.fileSize(of: outA) == Compressor.fileSize(of: outB),
                "Trockenplanung darf das Dokument nicht verändern")
        let snapA = try PDFSemanticSnapshot.capture(outA)
        let snapB = try PDFSemanticSnapshot.capture(outB)
        #expect(snapA.pages.map(\.textFingerprint)
            == snapB.pages.map(\.textFingerprint))
    }

    @Test(.hangGuard) func konservativeFontsTragenIhreKlassifikation()
        throws {
        // Type3 wird nie subsettet.
        let type3 = try PDFFixtures.type3FontPDF()
        defer { try? FileManager.default.removeItem(at: type3) }
        let type3Doc = try PDFCoreDocument(path: type3.path)
        let type3Candidates = try type3Doc.fontSubsetCandidates()
        #expect(type3Candidates.count == 1)
        #expect(type3Candidates.first?.subsettable == false)
        #expect(type3Candidates.first?.reason == .type3)

        // Pseudo-Fontprogramm (kein sfnt): Trockenplanung verweigert.
        let pseudo = try PDFFixtures.dedupFontsPDF(pages: 1)
        defer { try? FileManager.default.removeItem(at: pseudo) }
        let pseudoDoc = try PDFCoreDocument(path: pseudo.path)
        let pseudoCandidates = try pseudoDoc.fontSubsetCandidates()
        #expect(pseudoCandidates.count == 1)
        #expect(pseudoCandidates.first?.subsettable == false)
        #expect(pseudoCandidates.first?.reason == .dryPlanRefused)
    }

    // MARK: 2 – Activation Policy (§14.3)

    @Test func aktivierungspolitikBrauchtAbsolutUndRelativ() {
        // Konstanten dokumentiert: 64 KB absolut, 30 % relativ.
        #expect(FontOptimizer.minimumAbsoluteSavingBytes == 64 * 1024)
        #expect(FontOptimizer.minimumRelativeSavingFraction == 0.30)

        // Beide Schwellen müssen halten (max-Formel).
        #expect(FontOptimizer.passesActivation(estimatedSaving: 70_000,
                                               originalProgramBytes: 100_000))
        #expect(!FontOptimizer.passesActivation(estimatedSaving: 10_000,
                                                originalProgramBytes: 100_000),
                "Unter 64 KB absolut: keine 2-KB-Ersparnis gegen Risiko")
        #expect(!FontOptimizer.passesActivation(estimatedSaving: 65_536,
                                                originalProgramBytes: 1_000_000),
                "6,5 % eines großen Programms kaufen nichts")
        #expect(FontOptimizer.passesActivation(estimatedSaving: 400_000,
                                               originalProgramBytes: 500_000),
                "Arial-Klasse: weit über beiden Schwellen")
    }

    // MARK: 3 – Provision (Planungszeit)

    @Test(.hangGuard) func provisionRespektiertFlagsUndPolitik() throws {
        let url = try Self.requireFixture { try PDFFixtures.subsetFontPDF() }
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try PDFCoreDocument(path: url.path)

        // Ohne Flags (Not-Aus-Schalter): keine Provision.
        var flagsOff = CompressionOptions.smart
        flagsOff.featureFlags.candidateEngine = false
        flagsOff.featureFlags.selectiveFontSubset = false
        #expect(try FontOptimizer.provision(document: document,
                                            options: flagsOff).isEmpty)

        // Font-Politik aus: keine Provision (Font-Pass komplett aus).
        var fontOff = Self.candidateOptions()
        fontOff.fontPolicy = .off
        #expect(try FontOptimizer.provision(document: document,
                                            options: fontOff).isEmpty)

        // Mit Flags: EIN Provision mit bestandener Aktivierung.
        let provisions = try FontOptimizer.provision(document: document,
                                                     options: Self.candidateOptions())
        #expect(provisions.count == 1)
        let provision = try #require(provisions.first)
        #expect(provision.activationPassed,
                "Arial-Programm weit über beiden Schwellen")
        #expect(provision.estimatedSaving > 0)
        #expect(provision.pages == [0])
    }

    // MARK: 4 – Planner-Integration

    @Test(.hangGuard) func planZeichnetFontEntscheidungenNach() throws {
        let url = try Self.requireFixture { try PDFFixtures.subsetFontPDF() }
        defer { try? FileManager.default.removeItem(at: url) }

        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.candidateOptions())
        #expect(planned.plan.traceVersion == 2)
        #expect(planned.plan.fontSubsets.count == 1,
                "Aktivierung bestanden → ausführbare Subset-Entscheidung")
        let decision = try #require(planned.plan.fontSubsets.first)
        #expect(decision.pages == [0])
        #expect(decision.estimatedSaving > 0)

        // Das Font-Set lebt in candidateSets mit {fontKeep, fontSubset} –
        // und die ResourceDecision trägt die Rückstufungsleiter.
        let fontSet = try #require(planned.plan.candidateSets.first { set in
            set.candidates.contains { $0.kind == .fontSubset }
        })
        #expect(fontSet.candidates.first?.kind == .fontKeep,
                "fontKeep ist immer vorne (§9.1-Analogon)")
        let fontDecision = try #require(planned.plan.decisions.first {
            $0.resourceID == fontSet.resourceID
        })
        #expect(fontDecision.selectedCandidateID.rawValue.hasPrefix("fontSubset-"))
        #expect(fontDecision.candidateIDsBySafety.count == 2,
                "Leiter: fontSubset → fontKeep")
        #expect(fontDecision.candidateIDsBySafety.last?
            .rawValue.hasPrefix("fontKeep-") == true)

        // V2-11 – der Plan auf Default-Optionen IST der Candidate-Plan:
        // die Font-Entscheidungen sind im selben Plan konsistent nachgezeichnet.
        let defaults = try CompressionPipeline.plan(inputURL: url,
                                                    options: .smart)
        #expect(defaults.plan.traceVersion == 2)
        #expect(!defaults.plan.fontSubsets.isEmpty,
                "Selektives Subsetting (Default ON, V2-11) zeichnet fontSubsets")
        #expect(defaults.plan.fontSubsets.map(\.objectID)
                == planned.plan.fontSubsets.map(\.objectID),
                "Default- und Candidate-Plan tragen dieselben Font-Entscheidungen")
    }
}
