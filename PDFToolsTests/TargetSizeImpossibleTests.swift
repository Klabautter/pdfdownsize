import Testing
import Foundation
@testable import PDFTools

/// Masterplan §12.8 (V2-6) – Unerreichbares Ziel.
///
/// Ziel < minimumSafeBytes → targetMet = false, kleinste SICHERE Datei,
/// Meldung „Ziel X – sicher erreichbar ca. Y“. KEIN Safety-Floor-Bruch,
/// KEIN stiller Fallback.
@Suite struct TargetSizeImpossibleTests {

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

    static func jpeg(_ id: String, bytes: Int, distortion: Double,
                     global: Double? = nil) -> CompressionCandidate {
        // Nur die GLOBAL-Dimension gemessen (ΔE nil) → d = 1 − global exakt;
        // ohne explizites global folgt es der Verzerrung.
        let g = global ?? (1.0 - distortion)
        return candidate(id: id, bytes: bytes, global: g, p05: 0.95,
                         edge: 0.95, deltaE: nil)
    }

    /// §12.8 – Ziel unter dem Sicher-Erreichbaren: reachable = false,
    /// kleinste gate-bestehende Wahl, KEIN Floor-Bruch.
    @Test func zielUnterMinimumSafeWirdGemeldet() {
        // KEEP 10_000; zulässig: 5_000 (d 0.02). Fixed 3_000.
        // minimumSafe = 3_000 + 5_000 = 8_000 > Ziel 4_000.
        let sources: [TargetSizeOptimizer.Source] = [
            .init(group: .single(CandidateSet(
                resourceID: "50 0",
                candidates: [
                    Self.candidate(id: "50-keep", bytes: 10_000,
                                   lossless: true, kind: .keep),
                    Self.jpeg("50-jpeg", bytes: 5_000, distortion: 0.02),
                ])), contentClass: .photo),
        ]
        let optimization = TargetSizeOptimizer.optimize(
            sources: sources, targetBytes: 4_000, fixedBytes: 3_000,
            preset: .smart)

        #expect(!optimization.reachable)
        #expect(optimization.minimumSafeBytes == 8_000)
        #expect(optimization.expectedBytes == 8_000,
                "§12.8: die kleinste sichere Datei wird berechnet und gemeldet")
        #expect(optimization.selections[0].candidate.id == CandidateID("50-jpeg"),
                "kleinster GATE-BESTEHENDER Kandidat, kein Floor-Bruch")
        #expect(optimization.selections[0].reason.contains("§12.8"))
    }

    /// Floors werden NIE verletzt – auch nicht im §12.8-Fall: Jede Wahl ist
    /// KEEP oder hält Katastrophen-Floor UND Preset-Floor (§12.2, §12.8).
    @Test func floorsWerdenNieVerletzt() {
        let sources: [TargetSizeOptimizer.Source] = [
            .init(group: .single(CandidateSet(
                resourceID: "60 0",
                candidates: [
                    Self.candidate(id: "60-keep", bytes: 50_000,
                                   lossless: true, kind: .keep),
                    // Unter dem smart/photo-Preset (global 0.90), aber über
                    // dem Katastrophen-Floor: verboten.
                    Self.candidate(id: "60-illegal-1", bytes: 400,
                                   global: 0.80, p05: 0.85, edge: 0.90),
                    // Sogar unter dem KATASTROPHEN-Floor (global 0.70).
                    Self.candidate(id: "60-catastrophic", bytes: 100,
                                   global: 0.55, p05: 0.50, edge: 0.40),
                    Self.jpeg("60-legal", bytes: 6_000, distortion: 0.03),
                ])), contentClass: .photo),
            .init(group: .single(CandidateSet(
                resourceID: "61 0",
                candidates: [
                    Self.candidate(id: "61-keep", bytes: 8_000,
                                   lossless: true, kind: .keep),
                    Self.jpeg("61-legal", bytes: 3_000, distortion: 0.02),
                ])), contentClass: .photo),
        ]
        for target in [Int64(1_000), 10_000, 20_000, 1_000_000] {
            let optimization = TargetSizeOptimizer.optimize(
                sources: sources, targetBytes: Int64(target), fixedBytes: 1_000,
                preset: .smart)
            for selection in optimization.selections {
                if selection.candidate.kind.isKeep { continue }
                guard let measurement = selection.candidate.metrics
                    .gateMeasurement else {
                    Issue.record("Verlustbehafteter Kandidat ohne Messung")
                    continue
                }
                let gateClass = QualityGateClass(contentClass: .photo)
                if case .fail(let violated) = QualityGates.qualityVerdict(
                    policy: .catastrophicFloors(for: gateClass),
                    measurement: measurement) {
                    Issue.record("Katastrophen-Floor verletzt: \(violated)")
                }
                if case .fail(let violated) = QualityGates.qualityVerdict(
                    policy: .policy(preset: .smart, imageClass: gateClass),
                    measurement: measurement) {
                    Issue.record("Preset-Floor verletzt: \(violated)")
                }
            }
        }
    }

    /// §12.8 API-Form – minimumSafeBytes ist gesetzt, requested unverändert
    /// durchgereicht, selections liefern die kleinste sichere Datei.
    @Test func kleinsteSichereWahlBleibtErreichbar() {
        let sources: [TargetSizeOptimizer.Source] = [
            .init(group: .single(CandidateSet(
                resourceID: "70 0",
                candidates: [
                    Self.candidate(id: "70-keep", bytes: 20_000,
                                   lossless: true, kind: .keep),
                    Self.jpeg("70-a", bytes: 9_000, distortion: 0.01),
                    Self.jpeg("70-b", bytes: 7_000, distortion: 0.03),
                    Self.jpeg("70-c", bytes: 6_500, distortion: 0.05),
                ])), contentClass: .photo),
        ]
        let optimization = TargetSizeOptimizer.optimize(
            sources: sources, targetBytes: 1_000, fixedBytes: 0,
            preset: .smart)
        #expect(!optimization.reachable)
        #expect(optimization.requestedBytes == 1_000)
        #expect(optimization.minimumSafeBytes == 6_500)
        #expect(optimization.expectedBytes == 6_500)
        #expect(optimization.selections[0].candidate.id == CandidateID("70-c"))
        #expect(optimization.lambda == .infinity)
    }
}
