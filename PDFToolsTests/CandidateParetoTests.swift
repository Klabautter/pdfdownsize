import Testing
import Foundation
@testable import PDFTools

/// Masterplan §10.5 – Local Pareto Frontier (V2-4).
///
/// B dominiert A genau dann, wenn B in Bytes und Qualität nicht schlechter
/// ist und mindestens eine Bedingung strikt besser. Die Laufzeit ist bewusst
/// KEINE Dominanz-Dimension: `expectedRuntimeMs` ist gemessen und last-
/// abhängig – sie in die Dominanz zu nehmen kippte die Rückstufungsleiter
/// desselben Plans zwischen Läufen (Suitenfund). KEEP ist der Rückstufungs-
/// Sockel (§9.1) und wird niemals dominiert. Die Frontier entfernt alle
/// dominierten Kandidaten und bleibt deterministisch (ich teste: KEEP@0 mit
/// Qualität 1.0 ist UNÜBERTREFFBAR).
///
/// V2-4: Die Qualität der Dominanz ist klassengewichtet skalarisierbar
/// (`frontier(_:contentClass:)` über den DistortionVector, §10.2) – der
/// klassenneutrale Default bleibt `qualityScore` (min über die Metriken).
@Suite struct CandidateParetoTests {

    // MARK: Helfer

    static func candidate(id: String, bytes: Int, quality: Double,
                          runtime: Double, lossless: Bool = false,
                          global: Double? = nil, p05: Double? = nil,
                          edge: Double? = nil, text: Double? = nil,
                          deltaE: Double? = nil)
        -> CompressionCandidate {
        CompressionCandidate(
            id: CandidateID(id),
            objectID: nil,
            kind: lossless ? .keep : .jpeg(target: PixelSize(width: 100, height: 100),
                                           quality: 0.85, backend: .mozjpeg,
                                           grayscale: false),
            metrics: CandidateMetrics(
                encodedBytes: bytes,
                globalSSIM: global ?? quality, p05TileSSIM: p05 ?? quality,
                edgeScore: edge ?? quality, textScore: text ?? quality,
                deltaE76: deltaE, psnr: nil,
                expectedRuntimeMs: runtime, expectedPeakWorkingBytes: 0,
                compatibilityRisk: 0, semanticRisk: 0),
            isLossless: lossless,
            pages: [0],
            reason: "Test")
    }

    // MARK: Dominanz

    @Test func kleinerGleicherQualitaetDominiert() {
        let a = Self.candidate(id: "a", bytes: 900, quality: 0.90, runtime: 10)
        let b = Self.candidate(id: "b", bytes: 800, quality: 0.90, runtime: 10)
        #expect(CandidatePareto.isDominated(a, by: b))
        #expect(!CandidatePareto.isDominated(b, by: a))
    }

    @Test func besserInAllemDominiert() {
        let a = Self.candidate(id: "a", bytes: 900, quality: 0.85, runtime: 20)
        let b = Self.candidate(id: "b", bytes: 800, quality: 0.90, runtime: 10)
        #expect(CandidatePareto.isDominated(a, by: b))
    }

    @Test func gleichstandDominiertNicht() {
        let a = Self.candidate(id: "a", bytes: 800, quality: 0.90, runtime: 10)
        let b = Self.candidate(id: "b", bytes: 800, quality: 0.90, runtime: 10)
        // Keine Bedingung strikt besser → keine Dominanz (beide bleiben).
        #expect(!CandidatePareto.isDominated(a, by: b))
        #expect(CandidatePareto.frontier([a, b]).count == 2)
    }

    @Test func tradeoffDominiertNicht() {
        // Kleinere Datei, aber schlechtere Qualität → kein Pareto-Sieger;
        // die Wahl trifft das Ziel (V2-4/V2-6), nicht das Pruning.
        let a = Self.candidate(id: "a", bytes: 800, quality: 0.88, runtime: 10)
        let b = Self.candidate(id: "b", bytes: 700, quality: 0.84, runtime: 10)
        #expect(!CandidatePareto.isDominated(a, by: b))
        #expect(!CandidatePareto.isDominated(b, by: a))
    }

    @Test func keepIstNiemalsDominiert() {
        // KEEP ist der Rückstufungs-Sockel (§9.1) und wird bewusst nie
        // dominiert – auch nicht durch einen kleineren, verlustfreien
        // Kandidaten (dessen Bevorzugung ist Sache der Optimizer-Wahl, nicht
        // des Prunings).
        let keep = Self.candidate(id: "keep", bytes: 1000, quality: 1.0,
                                  runtime: 0, lossless: true)
        let flate = Self.candidate(id: "flate", bytes: 800, quality: 1.0, runtime: 5)
        let jpeg = Self.candidate(id: "jpeg", bytes: 500, quality: 0.90, runtime: 5)
        #expect(!CandidatePareto.isDominated(keep, by: flate))
        #expect(!CandidatePareto.isDominated(keep, by: jpeg))
        // Dafür dominiert KEEP nichts zurück – es ist nur unerschlagbar.
        #expect(CandidatePareto.isDominated(flate, by: keep) == false)
    }

    // MARK: Frontier

    @Test func frontierEntferntGenauDieDominierten() {
        let keep = Self.candidate(id: "keep", bytes: 1000, quality: 1.0,
                                  runtime: 0, lossless: true)
        let q90 = Self.candidate(id: "q90", bytes: 900, quality: 0.90, runtime: 10)
        let q85 = Self.candidate(id: "q85", bytes: 700, quality: 0.86, runtime: 10)
        let q80 = Self.candidate(id: "q80", bytes: 600, quality: 0.80, runtime: 10)
        let q85Duplicate = Self.candidate(id: "q85-dup", bytes: 701,
                                          quality: 0.86, runtime: 12)
        // q85Duplicate verliert gegen q85 (gleiche Qualität, mehr Bytes);
        // q90/q85/q80 liegen auf der Frontier (Klassiker: kleiner = schlechter).
        let frontier = CandidatePareto.frontier([keep, q90, q85, q80, q85Duplicate])
        #expect(frontier.map(\.id.rawValue) == ["keep", "q90", "q85", "q80"])
    }

    @Test func frontierIstDeterministischUndStabil() {
        let keep = Self.candidate(id: "keep", bytes: 1000, quality: 1.0,
                                  runtime: 0, lossless: true)
        let a = Self.candidate(id: "a", bytes: 900, quality: 0.90, runtime: 10)
        let b = Self.candidate(id: "b", bytes: 950, quality: 0.90, runtime: 10)
        // b wird von a dominiert – egal in welcher Reihenfolge er eingeht.
        let first = CandidatePareto.frontier([keep, a, b])
        let second = CandidatePareto.frontier([b, keep, a])
        #expect(first.map(\.id.rawValue) == ["keep", "a"])
        #expect(second.map(\.id.rawValue) == ["keep", "a"])
    }

    /// Last-Unabhängigkeit: Gemessene Laufzeit-Schwankungen dürfen die
    /// Frontier NICHT verändern (Suitenfund: die Rückstufungsleiter kippte
    /// mit der Last – r1-Rungen fielen zwischen zwei Plänen desselben
    /// Fixtures aus).
    @Test func laufzeitKipptDieFrontierNicht() {
        let a = Self.candidate(id: "a", bytes: 900, quality: 0.90, runtime: 10)
        let b = Self.candidate(id: "b", bytes: 900, quality: 0.90, runtime: 2000)
        // B ist nominal 200× „langsamer“ – ohne Laufzeit-Dimension identische
        // Frontier wie im entlasteten Fall.
        #expect(CandidatePareto.frontier([a, b]).map(\.id.rawValue) == ["a", "b"])
        #expect(!CandidatePareto.isDominated(b, by: a))
        #expect(!CandidatePareto.isDominated(a, by: b))
    }

    // MARK: Klassengewichtete Frontier (§10.2)

    /// Die Klassengewichte können die Dominanzrichtung DREHEN: Nach
    /// `qualityScore` (min) dominiert der kachelbeständigere Kandidat; in
    /// der Screenshot-Sicht (edge + text + localWorst) trägt die hoch-
    ///wertige Kante mehr und der Kleine bleibt auf der Frontier.
    @Test func screenshotGewichteDrehenDieDominanz() {
        // x: hervorragende Kanten, eine kollabierte Kachelgruppe (min = p05)
        let x = Self.candidate(id: "x", bytes: 900, quality: 0.55, runtime: 10,
                               global: 0.99, p05: 0.55, edge: 0.99, text: 0.99)
        // y: kleiner, überall solide, aber keine Spitzenwerte
        let y = Self.candidate(id: "y", bytes: 800, quality: 0.70, runtime: 10,
                               global: 0.90, p05: 0.70, edge: 0.80, text: 0.80)
        // Klassenneutral (min): y dominiert x (weniger Bytes, besseres min).
        #expect(CandidatePareto.isDominated(x, by: y))
        #expect(CandidatePareto.frontier([x, y]).map(\.id.rawValue) == ["y"])
        // Screenshot-Gewichte: x (0.4·0.99+0.3·0.99+0.3·0.55 = 0.858) schlägt
        // y (0.4·0.80+0.3·0.80+0.3·0.70 = 0.77) → keine Dominanz, beide bleiben.
        #expect(!CandidatePareto.isDominated(x, by: y, contentClass: .screenshot))
        #expect(!CandidatePareto.isDominated(y, by: x, contentClass: .screenshot))
        #expect(CandidatePareto.frontier([x, y],
                                         contentClass: .screenshot).map(\.id.rawValue)
                == ["x", "y"])
    }

    /// Photo-Gewichte (global + color): Farbtreue zählt – ein graustufen-
    /// verlustfreier Kandidat ohne ΔE renormalisiert auf global.
    @Test func photoGewichteWertenFarbtreueMit() {
        // a: struktur top, Farbe kippt (ΔE 4 → colorLoss 0.5)
        let a = Self.candidate(id: "a", bytes: 900, quality: 0.90, runtime: 10,
                               global: 0.95, p05: 0.95, edge: 0.95, deltaE: 4.0)
        // b: minimal schlechter in der Struktur, Farbe sauber (ΔE 1 → 0.875)
        let b = Self.candidate(id: "b", bytes: 900, quality: 0.94, runtime: 10,
                               global: 0.94, p05: 0.94, edge: 0.94, deltaE: 1.0)
        // Klassenneutral: b dominiert a (gleiche Bytes, höheres min).
        #expect(CandidatePareto.isDominated(a, by: b))
        // Photo-Skalarisierung: a = 0.6·0.95+0.4·0.50 = 0.77,
        // b = 0.6·0.94+0.4·0.875 = 0.914 → b dominiert weiterhin.
        #expect(CandidatePareto.isDominated(a, by: b, contentClass: .photo))
        // Graustufen (kein ΔE): Photo-Gewichte renormalisieren auf global –
        // die Skalarisierung fällt mit der Struktur zusammen.
        let aGrau = Self.candidate(id: "a-grau", bytes: 900, quality: 0.95,
                                   runtime: 10, global: 0.95, p05: 0.95,
                                   edge: 0.95)
        let bGrau = Self.candidate(id: "b-grau", bytes: 800, quality: 0.94,
                                   runtime: 10, global: 0.94, p05: 0.94,
                                   edge: 0.94)
        #expect(abs(aGrau.metrics.quality(for: .photo) - 0.95) < 1e-9)
        #expect(abs(bGrau.metrics.quality(for: .photo) - 0.94) < 1e-9)
        // Besser UND kleiner zugleich wäre Dominanz – hier ein Trade-off.
        #expect(!CandidatePareto.isDominated(aGrau, by: bGrau, contentClass: .photo))
        #expect(!CandidatePareto.isDominated(bGrau, by: aGrau, contentClass: .photo))
    }

    /// KEEP (alle Dimensionen nil) hat klassenunabhängig Qualität 1.0 und
    /// bleibt in jeder Klassensicht unerschlagbar.
    @Test func keepQualitaetIstKlassenunabhaengigEins() {
        let keep = Self.candidate(id: "keep", bytes: 1000, quality: 1.0,
                                  runtime: 0, lossless: true)
        for klasse in ContentClass.allCases {
            #expect(keep.metrics.quality(for: klasse) == 1.0, "\(klasse)")
        }
        let jpeg = Self.candidate(id: "jpeg", bytes: 500, quality: 0.90, runtime: 5)
        #expect(!CandidatePareto.isDominated(keep, by: jpeg, contentClass: .scanContinuous))
    }

    /// Die klassengewichtete Frontier ist ebenso deterministisch und
    /// erhält die Generatorreihenfolge.
    @Test func klassenFrontierIstDeterministisch() {
        let keep = Self.candidate(id: "keep", bytes: 1000, quality: 1.0,
                                  runtime: 0, lossless: true)
        let a = Self.candidate(id: "a", bytes: 900, quality: 0.90, runtime: 10,
                               global: 0.90, p05: 0.90, edge: 0.90, text: 0.90)
        let b = Self.candidate(id: "b", bytes: 950, quality: 0.90, runtime: 10,
                               global: 0.90, p05: 0.90, edge: 0.90, text: 0.90)
        let first = CandidatePareto.frontier([keep, a, b], contentClass: .mapTechnical)
        let second = CandidatePareto.frontier([b, keep, a], contentClass: .mapTechnical)
        #expect(first.map(\.id.rawValue) == ["keep", "a"])
        #expect(second.map(\.id.rawValue) == ["keep", "a"])
    }
}
