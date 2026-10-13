import Testing
import Foundation
@testable import PDFTools

/// Masterplan §15.4 – Determinismus der Candidate-Erzeugung unter
/// Parallelität.
///
/// Die Parallelität (Flag `pixelBudgetScheduler`) darf die ERGEBNISSE nicht
/// verändern: CandidateSets sind Source of Truth (§4/§26), ihr Inhalt – IDs,
/// Kinds, Bytes, Messungen, Reihenfolge (KEEP@0 zuerst) – muss zwischen
/// zwei Läufen desselben Dokuments identisch sein, egal wie die Jobs
/// fertig werden. Nur die Laufzeitmessung (`expectedRuntimeMs`) ist von
/// Natur aus nicht reproduzierbar und wird deshalb normalisiert.
@Suite struct CandidateDeterminismTests {

    /// Normalisiert ein Set: Laufzeitmessung auf 0 – die EINZIGE Natur-
    /// nichtdeterministische Metrik. Alles andere (IDs, Bytes, Metriken,
    /// Reihenfolge) ist deterministisch.
    private static func normalized(_ sets: [CandidateSet]) -> [CandidateSet] {
        sets.map { set in
            CandidateSet(resourceID: set.resourceID,
                         candidates: set.candidates.map { candidate in
                CompressionCandidate(
                    id: candidate.id,
                    objectID: candidate.objectID,
                    kind: candidate.kind,
                    metrics: CandidateMetrics(
                        encodedBytes: candidate.metrics.encodedBytes,
                        globalSSIM: candidate.metrics.globalSSIM,
                        p05TileSSIM: candidate.metrics.p05TileSSIM,
                        edgeScore: candidate.metrics.edgeScore,
                        textScore: candidate.metrics.textScore,
                        deltaE76: candidate.metrics.deltaE76,
                        psnr: candidate.metrics.psnr,
                        expectedRuntimeMs: 0,
                        expectedPeakWorkingBytes:
                            candidate.metrics.expectedPeakWorkingBytes,
                        compatibilityRisk: candidate.metrics.compatibilityRisk,
                        semanticRisk: candidate.metrics.semanticRisk),
                    isLossless: candidate.isLossless,
                    pages: candidate.pages,
                    reason: candidate.reason)
            })
        }
    }

    private static func candidateOptions(scheduler: Bool) -> CompressionOptions {
        var options = CompressionOptions.smart
        options.featureFlags.candidateEngine = true
        options.featureFlags.pixelBudgetScheduler = scheduler
        if scheduler { options.pixelBudgetBytes = 128 * 1024 * 1024 }
        return options
    }

    @Test(.hangGuard) func parallelerLaufLiefertIdentischeCandidateSets() throws {
        let url = try PDFFixtures.manyImagesPDF(count: 6)
        defer { try? FileManager.default.removeItem(at: url) }

        // Zwei SERIELLE Läufe: Baselinewahrheit (muss schon ohne Parallelität
        // reproduzierbar sein – Laufzeitfelder ausgenommen).
        let serialA = try CompressionPipeline.plan(
            inputURL: url, options: Self.candidateOptions(scheduler: false))
        let serialB = try CompressionPipeline.plan(
            inputURL: url, options: Self.candidateOptions(scheduler: false))
        #expect(Self.normalized(serialB.plan.candidateSets)
                == Self.normalized(serialA.plan.candidateSets),
                "Zwei serielle Läufe müssen identische Sets liefern")

        // PARALLELLAUF gegen die serielle Wahrheit.
        let parallel = try CompressionPipeline.plan(
            inputURL: url, options: Self.candidateOptions(scheduler: true))
        #expect(Self.normalized(parallel.plan.candidateSets)
                == Self.normalized(serialA.plan.candidateSets),
                "Parallelität darf die CandidateSets nicht verändern")
                        #expect(serialA.plan.decisions == serialB.plan.decisions)
        #expect(serialA.plan.decisions == parallel.plan.decisions,
                "Auch die Wahl (Entscheidungen) bleibt identisch")
    }

    @Test(.hangGuard) func parallelerUndSeriellerLaufWählenDenselbenKandidaten() throws {
        // CMYK- und Bilevel-artige Inhalte im Mix, um mehrere Pfade unter
        // Konkurrenz zu fahren (§15.1 – QPDF-Handle bleibt seriell, die
        // Pixelarbeit parallel).
        let url = try PDFFixtures.cmykPhotoPDF(pixelWidth: 1200)
        defer { try? FileManager.default.removeItem(at: url) }

        let serial = try CompressionPipeline.plan(
            inputURL: url, options: Self.candidateOptions(scheduler: false))
        let parallel = try CompressionPipeline.plan(
            inputURL: url, options: Self.candidateOptions(scheduler: true))

        #expect(serial.plan.decisions == parallel.plan.decisions,
                "Gleiche Eingabe, gleiche Wahl – unabhängig von der Ausführung")
        #expect(Self.normalized(parallel.plan.candidateSets)
                == Self.normalized(serial.plan.candidateSets))
    }
}
