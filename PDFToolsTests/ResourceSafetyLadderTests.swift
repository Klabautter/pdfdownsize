import Testing
import Foundation
@testable import PDFTools

/// Masterplan §5.7/§10.3/§11.4 – Rückstufungsleiter (Safety Ladder).
///
/// Die Leiter ist die Rollback-Ordnung für V2-5: Sie beginnt beim
/// aggressivsten zulässigen Kandidaten (kleinster verlustbehafteter) und
/// endet bei KEEP. Festgenagelt:
///   • Ordnung: verlustbehaftet aufsteigend nach Bytes → verlustfrei
///     aufsteigend nach Bytes → KEEP als letzte Stufe – je Inhaltsklasse.
///   • V2-4: Kandidaten, die der Rate-Distortion-Optimizer verwirft
///     (Katastrophen-Floor, Preset-Floor, harte Gates), tauchen in der
///     Leiter NIEMALS auf – Rollback liefert nur zulässige Alternativen.
@Suite struct ResourceSafetyLadderTests {

    // MARK: Helfer

    private static func jpeg(_ id: String, bytes: Int, quality: Double = 0.85,
                             global: Double = 0.93, p05: Double = 0.88,
                             edge: Double = 0.90, deltaE: Double = 2.0)
        -> CompressionCandidate {
        CompressionCandidate(
            id: CandidateID(id), objectID: nil,
            kind: .jpeg(target: PixelSize(width: 100, height: 100), quality: quality,
                        backend: .mozjpeg, grayscale: false),
            metrics: CandidateMetrics(
                encodedBytes: bytes, globalSSIM: global, p05TileSSIM: p05,
                edgeScore: edge, textScore: nil, deltaE76: deltaE, psnr: nil,
                expectedRuntimeMs: 10, expectedPeakWorkingBytes: 0,
                compatibilityRisk: 0.1, semanticRisk: 0.05),
            isLossless: false, pages: [0], reason: "Test")
    }

    private static func lossless(_ id: String, bytes: Int,
                                 kind: CandidateKind) -> CompressionCandidate {
        CompressionCandidate(
            id: CandidateID(id), objectID: nil, kind: kind,
            metrics: CandidateMetrics(
                encodedBytes: bytes, globalSSIM: nil, p05TileSSIM: nil,
                edgeScore: nil, textScore: nil, deltaE76: nil, psnr: nil,
                expectedRuntimeMs: 5, expectedPeakWorkingBytes: 0,
                compatibilityRisk: 0, semanticRisk: 0),
            isLossless: true, pages: [0], reason: "Test")
    }

    private static func keep(_ bytes: Int) -> CompressionCandidate {
        CompressionCandidate(
            id: CandidateID("keep"), objectID: nil, kind: .keep,
            metrics: CandidateMetrics(
                encodedBytes: bytes, globalSSIM: nil, p05TileSSIM: nil,
                edgeScore: nil, textScore: nil, deltaE76: nil, psnr: nil,
                expectedRuntimeMs: 0, expectedPeakWorkingBytes: 0,
                compatibilityRisk: 0, semanticRisk: 0),
            isLossless: true, pages: [0], reason: "Test")
    }

    // MARK: Leiter-Ordnung je Klasse

    /// Für jede Inhaltsklasse dieselbe Ordnung: lossy aufsteigend (kleinster
    /// = aggressivste Stufe zuerst), dann lossless, KEEP zuletzt.
    @Test("Leiter-Ordnung je Inhaltsklasse",
          arguments: ContentClass.allCases)
    func leiterOrdnungJeKlasse(contentClass: ContentClass) {
        let flate = Self.lossless("flate", bytes: 1_200,
                             kind: .flate(target: PixelSize(width: 100, height: 100),
                                          grayscale: false, predictor: true))
        // Der größere lossy Kandidat ist bewusst der BESSERE (keine Pareto-
        // Dominanz, beide bleiben im Raum): klein = aggressiv & grenzwertig,
        // gross = mild & hochwertig; das lossy-Flate ist bewusst GRÖSSER als
        // beide lossy Stufen (sonst dominierte es sie aus dem Feld).
        let candidates = [
            Self.keep(5_000),
            Self.jpeg("jpeg-gross", bytes: 900, quality: 0.92, global: 0.97,
                 p05: 0.93, edge: 0.94, deltaE: 1.0),
            flate,
            Self.jpeg("jpeg-klein", bytes: 700, quality: 0.80, global: 0.93,
                 p05: 0.88, edge: 0.90, deltaE: 2.0),
        ]
        // Optimizer-Wahl über das Set – die Leiter der Auswahl muss der
        // Ordnungsregel folgen.
        let set = CandidateSet(resourceID: "1 0", candidates: candidates)
        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: contentClass,
                                                       preset: .smart)
        #expect(selection.candidateIDsBySafety ==
                [CandidateID("jpeg-klein"), CandidateID("jpeg-gross"),
                 flate.id, CandidateID("keep")],
                "\(contentClass): falsche Leiter-Ordnung \(selection.candidateIDsBySafety)")
        // KEEP ist immer die letzte (konservativste) Stufe.
        #expect(selection.candidateIDsBySafety.last == set.keepCandidate?.id)
        // Der kleinste lossy Kandidat ist die erste (aggressivste) Stufe.
        #expect(selection.candidateIDsBySafety.first == CandidateID("jpeg-klein"))
    }

    /// Die reine Leiter-Herleitung (ohne Optimizer) sortiert ebenso.
    @Test func safetyLadderSortiertVerlustbehaftetZuerst() {
        let candidates = [
            Self.keep(5_000),
            Self.lossless("g4", bytes: 300, kind: .ccittG4),
            Self.jpeg("jpeg-gross", bytes: 900),
            Self.lossless("flate", bytes: 800,
                     kind: .flate(target: PixelSize(width: 100, height: 100),
                                  grayscale: false, predictor: true)),
            Self.jpeg("jpeg-klein", bytes: 700),
        ]
        #expect(ResourceDecision.safetyLadder(of: candidates) ==
                [CandidateID("jpeg-klein"), CandidateID("jpeg-gross"),
                 CandidateID("g4"), CandidateID("flate"), CandidateID("keep")])
    }

    // MARK: §10.3 – Verworfene sind nicht rückstufbar

    /// Ein am Katastrophen-Floor gescheiterter Kandidat ist aus dem
    /// Kandidatenraum entfernt: Die Leiter führt ausschließlich zulässige
    /// Stufen – V2-5 kann nicht in die Katastrophe zurückrollen.
    @Test func katastrophenVerworfeneKandidatenFehlenInDerLeiter() {
        let katastrophe = CompressionCandidate(
            id: CandidateID("jpeg-katastrophe"), objectID: nil,
            kind: .jpeg(target: PixelSize(width: 100, height: 100), quality: 0.05,
                        backend: .mozjpeg, grayscale: false),
            metrics: CandidateMetrics(
                encodedBytes: 300, globalSSIM: 0.75, p05TileSSIM: 0.40,
                edgeScore: 0.62, textScore: 0.30, deltaE76: nil, psnr: nil,
                expectedRuntimeMs: 10, expectedPeakWorkingBytes: 0,
                compatibilityRisk: 0.1, semanticRisk: 0.3),
            isLossless: false, pages: [0], reason: "Test")
        let ok = Self.jpeg("jpeg-ok", bytes: 900)
        let set = CandidateSet(resourceID: "1 0",
                               candidates: [Self.keep(5_000), katastrophe, ok])

        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .custom)
        #expect(selection.catastrophicRejection)
        #expect(selection.candidate.id == ok.id,
                "Trotz Katastrophen-Verwerfung bleibt der zulässige lossy Kandidat wählbar")
        #expect(selection.candidateIDsBySafety == [ok.id, CandidateID("keep")],
                "Die Katastrophen-Stufe (300) darf nicht in die Leiter")
        #expect(!selection.candidateIDsBySafety.contains(katastrophe.id))
    }

    /// Scheitern ALLE lossy Kandidaten am Katastrophen-Floor, ist KEEP die
    /// einzige Stufe – die Auswahl fällt konservativ zurück.
    @Test func nurKatastrophenFuehrtZuKeepAlsEinzigerStufe() {
        let katastrophe = CompressionCandidate(
            id: CandidateID("jpeg-katastrophe"), objectID: nil,
            kind: .jpeg(target: PixelSize(width: 100, height: 100), quality: 0.05,
                        backend: .mozjpeg, grayscale: false),
            metrics: CandidateMetrics(
                encodedBytes: 300, globalSSIM: 0.75, p05TileSSIM: 0.40,
                edgeScore: 0.62, textScore: 0.30, deltaE76: nil, psnr: nil,
                expectedRuntimeMs: 10, expectedPeakWorkingBytes: 0,
                compatibilityRisk: 0.1, semanticRisk: 0.3),
            isLossless: false, pages: [0], reason: "Test")
        let set = CandidateSet(resourceID: "1 0",
                               candidates: [Self.keep(5_000), katastrophe])

        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .custom)
        #expect(selection.candidate.kind.isKeep)
        #expect(selection.catastrophicRejection)
        #expect(selection.candidateIDsBySafety == [CandidateID("keep")])
    }
}
