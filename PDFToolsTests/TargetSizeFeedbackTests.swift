import Testing
import Foundation
@testable import PDFTools

/// Masterplan §12.6 (V2-6) – Actual-Size Feedback.
///
/// Expected Bytes ≠ finale PDF-Größe. Der Loop plan → select → execute →
/// final write → ACTUAL size re-optimiert mit GEMESSENEN Größen, wenn die
/// tatsächliche Datei über dem Ziel liegt und ein sicherer kleinerer Stand
/// existiert (max 2 Iterationen; Candidate-Payloads werden wiederverwendet).
///
/// Die Entscheidung ist eine reine Funktion (`reoptimization`) und damit
/// ohne Pipeline testbar; die Overrides laufen über die V2-5-Mechanik.
@Suite struct TargetSizeFeedbackTests {

    static func candidate(id: String, bytes: Int,
                          global: Double? = nil, p05: Double? = nil,
                          edge: Double? = nil, deltaE: Double? = nil,
                          lossless: Bool = false, kind: CandidateKind? = nil)
        -> CompressionCandidate {
        CompressionCandidate(
            id: CandidateID(id),
            objectID: nil,
            kind: kind ?? (lossless ? .keep
                : .jpeg(target: PixelSize(width: 100, height: 100), quality: 0.85,
                        backend: .mozjpeg, grayscale: false)),
            metrics: CandidateMetrics(
                encodedBytes: bytes,
                globalSSIM: global, p05TileSSIM: p05,
                edgeScore: edge, textScore: nil,
                deltaE76: deltaE, psnr: nil,
                expectedRuntimeMs: 10, expectedPeakWorkingBytes: 0,
                compatibilityRisk: 0, semanticRisk: 0),
            isLossless: lossless,
            pages: [0],
            reason: "Test")
    }

    static func jpeg(_ id: String, bytes: Int, distortion: Double)
        -> CompressionCandidate {
        // Nur die GLOBAL-Dimension gemessen (ΔE nil) → d = 1 − global exakt.
        candidate(id: id, bytes: bytes, global: 1.0 - distortion,
                  p05: 0.95, edge: 0.95, deltaE: nil)
    }

    /// Plan mit Kandidatenraum + Entscheidung (traceVersion 2) – die Form,
    /// die planViaCandidates nach dem Erstlauf liefert. Große Leitersprünge
    /// (≥ 15 KB), damit der ~1 %-Mindestgewinn des Re-Laufs greift.
    static func plan(selected: String, goal: CompressionGoal) -> CompressionPlan {
        let set = CandidateSet(resourceID: "80 0", candidates: [
            Self.candidate(id: "80-keep", bytes: 60_000,
                           lossless: true, kind: .keep),
            Self.jpeg("80-jpeg-b", bytes: 20_000, distortion: 0.06),
            // d 0.10 → global 0.90 hält den smart/photo-Floor (strikt <).
            Self.jpeg("80-jpeg-s", bytes: 5_000, distortion: 0.10),
        ])
        var plan = CompressionPlan(
            documentID: "feedback-test",
            actions: [],
            metadataPolicy: .preserve,
            linearizationPolicy: .none,
            dedupPolicy: .auto,
            fontPolicy: .auto,
            fontSubsettingPolicy: .off,
            compatibilityPolicy: .modern,
            jpegBackend: .mozjpeg,
            originalImageBytes: 20_000,
            originalDocumentBytes: 30_000,
            flatePolicy: .standard)
        plan.candidateSets = [set]
        plan.decisions = [ResourceDecision(
            resourceID: "80 0",
            selectedCandidateID: CandidateID(selected),
            candidateIDsBySafety: [CandidateID("80-jpeg-s"),
                                   CandidateID("80-jpeg-b"),
                                   CandidateID("80-keep")],
            classification: .photo,
            features: nil,
            pages: [0],
            reason: "Test")]
        plan.goal = goal
        plan.traceVersion = 2
        return plan
    }

    // MARK: §12.6 – Drift löst die zweite Iteration aus

    /// Gemessene Größe über dem Ziel UND ein sicherer kleinerer Stand:
    /// Overrides erzwungen, Fixed-Bytes aus der Drift nachkalibriert.
    @Test func driftUeberZielErzeugtReoptimierung() throws {
        // Erstwahl 20_000 (B); gemessen 30_000 → Fixed-Kalibrierung 10_000.
        // Ziel 24_000 → Planziel 23_520, Bildbudget 13_520 → kleinste Wahl
        // 5_000 (S) → expected 15_000 (Gewinn 15_000 ≫ ε 4_096).
        let plan = Self.plan(selected: "80-jpeg-b", goal: .targetBytes(24_000))
        let reopt = try #require(TargetSizeOptimizer.reoptimization(
            plan: plan, actualBytes: 30_000, requestedBytes: 24_000,
            preset: .smart))
        #expect(!reopt.unreachable)
        #expect(reopt.expectedBytes == 15_000)
        #expect(reopt.overrides.forcedCandidates["80 0"]?
            .rawValue == "80-jpeg-s")
        #expect(reopt.overrides.label.contains("§12.6"),
                "Overrides tragen die Zielgrößen-Herkunft, nicht QA-Rollback")
    }

    /// Kein Re-Plan ohne Drift: die gemessene Größe hält das Ziel bereits.
    @Test func zielGehaltenLoestKeinenReplanAus() {
        let plan = Self.plan(selected: "80-jpeg-b", goal: .targetBytes(24_000))
        #expect(TargetSizeOptimizer.reoptimization(
            plan: plan, actualBytes: 23_000, requestedBytes: 24_000,
            preset: .smart) == nil)
    }

    /// Kein Re-Plan ohne echten Gewinn: Die Erstwahl ist bereits der
    /// kleinste Candidate – die Nachkalibrierung liefert denselben Stand,
    /// die erneute Ausführung brächte nichts.
    @Test func gewinnloserReplanWirdVerweigert() {
        let plan = Self.plan(selected: "80-jpeg-s", goal: .targetBytes(24_000))
        #expect(TargetSizeOptimizer.reoptimization(
            plan: plan, actualBytes: 30_000, requestedBytes: 24_000,
            preset: .smart) == nil)
    }

    /// §12.8 im Feedback-Loop: Ziel unter dem neu berechneten Minimum →
    /// trotzdem Re-Plan AUF die kleinste sichere Wahl (kein stiller
    /// Fallback), unreachable = true.
    @Test func unerreichbaresZielImFeedbackLiefertKleinsteSichereWahl() throws {
        // Erstwahl 20_000 (B), gemessen 30_000 → Fixed-Kalibrierung 10_000.
        // Ziel 10_000 → Planziel 9_800, minimumSafe = 15_000 > Planziel →
        // unreachable; Overrides setzen dennoch die kleinste Wahl durch
        // (Gewinn 15_000 ≫ ε).
        let plan = Self.plan(selected: "80-jpeg-b", goal: .targetBytes(10_000))
        let reopt = try #require(TargetSizeOptimizer.reoptimization(
            plan: plan, actualBytes: 30_000, requestedBytes: 10_000,
            preset: .smart))
        #expect(reopt.unreachable)
        #expect(reopt.minimumSafeBytes == 15_000)
        #expect(reopt.expectedBytes == 15_000)
        #expect(reopt.overrides.forcedCandidates["80 0"]?
            .rawValue == "80-jpeg-s")
    }

    /// Legacy-Plan (traceVersion 1) oder fehlender Kandidatenraum: kein
    /// Feedback-Loop (kein zweiter Engine-Pfad, §4).
    @Test func legacyPlanBleibtUnberuehrt() {
        var plan = Self.plan(selected: "80-jpeg-b", goal: .targetBytes(12_000))
        plan.traceVersion = 1
        #expect(TargetSizeOptimizer.reoptimization(
            plan: plan, actualBytes: 15_000, requestedBytes: 12_000,
            preset: .smart) == nil)
    }

    // MARK: §17 – Result-Verdrahtung (ohne Ziel unverändert)

    @Test func ergebnisOhneZielBleibtNeutral() {
        // Die additiven Defaults: ohne Zielgrößen-Ziel sind die Felder
        // nil/0/leer – mode-basierte Aufrufe verhalten sich exakt wie bisher.
        let result = CompressionResult(outputURL: URL(fileURLWithPath: "/tmp/x.pdf"),
                                       inputBytes: 100, outputBytes: 50)
        #expect(result.targetRequestedBytes == nil)
        #expect(result.targetMet == nil)
        #expect(result.selectedCandidateCount == 0)
        #expect(result.warningSummary.isEmpty)
        #expect(result.qaReplanCount == 0)
        #expect(result.qaFallbackCount == 0)
    }
}
