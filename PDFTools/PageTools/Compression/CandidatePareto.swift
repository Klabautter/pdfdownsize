import Foundation

// MARK: - Masterplan §10.5 – Local Pareto Frontier (V2-4)
//
// Ein Candidate B dominiert A, wenn B in Bytes, Qualität und Laufzeit nicht
// schlechter ist und mindestens eine Bedingung strikt besser. Dominierte
// Kandidaten werden entfernt, BEVOR der Optimizer (§10.6) und später der
// globale Budget-Optimizer (V2-6) über den Rest suchen – das reduziert den
// Suchraum massiv. Die Qualität je Dimension liefert der DistortionVector
// (§10.2); ihre Skalarisierung folgt den Klassengewichten
// (`DistortionWeights` im RateDistortionOptimizer).
//
// Determinismus: Die Frontier erhält die Eingabereihenfolge (Generator-
// reihenfolge) – Kandidaten ohne Dominanzverhältnis bleiben in der Reihenfolge
// stehen, in der der Generator sie erzeugt hat. Die Optimizer-Wahl löst
// Gleichstände damit über die Generatorreihenfolge (KEEP@0 zuerst).
//
// Laufzeit ist KEINE Dominanz-Dimension: `expectedRuntimeMs` ist die
// GEMESSENE Encode-Zeit und schwankt mit der Maschinenlast (gemessen ±50 %
// unter Suitenlast). Übernimmt man sie in die Dominanz (§10.5-Formel), kippt
// die Frontier mit der Last – die Rückstufungsleiter desselben Plans wurde
// zwischen zwei Läufen desselben Fixtures instabil (Suitenfund: r1-Rungen
// fielen aus). Die Plan-Determinismus-Zusage (gleiche Datei + gleicher Build
// → gleicher Plan/Leiter, §8.6-Geist) wiegt schwerer als die §10.5-Formel:
// Laufzeit bleibt in den Metriken (Telemetrie, §12-Budget) und fließt NICHT
// ins Pruning. KEEP (§9.1) ist der Rückstufungs-Sockel und wird niemals
// dominiert – seine frühere Unerschlagbarkeit hing an der Laufzeit-0-Arm.

enum CandidatePareto {

    /// Qualität der Dominanz. Der klassenneutrale Default ist
    /// `qualityScore` (min über die gemessenen Metriken) – dieselbe Formel
    /// wie im V2-3a-Grundgerüst; der Optimizer rechnet klassengewichtet.
    typealias Quality = (CompressionCandidate) -> Double

    static func isDominated(_ candidate: CompressionCandidate,
                            by other: CompressionCandidate,
                            quality: Quality) -> Bool {
        guard !candidate.kind.isKeep else { return false }
        let a = candidate.metrics
        let b = other.metrics
        guard b.encodedBytes <= a.encodedBytes else { return false }
        let qa = quality(candidate)
        let qb = quality(other)
        guard qb >= qa else { return false }
        return b.encodedBytes < a.encodedBytes || qb > qa
    }

    /// Klassenneutrale Dominanz über `qualityScore` (V2-3a-Semantik).
    static func isDominated(_ candidate: CompressionCandidate,
                            by other: CompressionCandidate) -> Bool {
        isDominated(candidate, by: other) { $0.metrics.qualityScore }
    }

    /// Klassengewichtete Dominanz (§10.2/§10.5): Qualität ist die gewichtete
    /// Skalarisierung des DistortionVectors für die Inhaltsklasse.
    static func isDominated(_ candidate: CompressionCandidate,
                            by other: CompressionCandidate,
                            contentClass: ContentClass) -> Bool {
        isDominated(candidate, by: other) {
            $0.metrics.quality(for: contentClass)
        }
    }

    /// Entfernt alle dominierten Kandidaten. Die Qualität wird PRO Kandidat
    /// genau einmal berechnet; die Eingabereihenfolge bleibt für Gleiche
    /// erhalten – deterministisch.
    static func frontier(_ candidates: [CompressionCandidate],
                         quality: Quality) -> [CompressionCandidate] {
        let qualities = candidates.map(quality)
        return candidates.enumerated().filter { index, candidate in
            !candidates.enumerated().contains { otherIndex, other in
                otherIndex != index
                    && isComparable(candidate, other)
                    && isDominatedRaw(candidate, qualities[index],
                                      other, qualities[otherIndex])
            }
        }.map(\.element)
    }

    /// Klassenneutrale Frontier über `qualityScore`.
    static func frontier(_ candidates: [CompressionCandidate]) -> [CompressionCandidate] {
        frontier(candidates) { $0.metrics.qualityScore }
    }

    /// Klassengewichtete Frontier (§10.2/§10.5): Die Qualität je Kandidat
    /// ist die gewichtete Skalarisierung seines DistortionVectors für die
    /// Inhaltsklasse (Gewichte: `DistortionWeights`).
    static func frontier(_ candidates: [CompressionCandidate],
                         contentClass: ContentClass) -> [CompressionCandidate] {
        frontier(candidates) { $0.metrics.quality(for: contentClass) }
    }

    /// Dominanz auf vorberechneten Qualitäten (Performance: O(n²) Vergleiche
    /// ohne erneute Skalarisierung).
    private static func isDominatedRaw(_ a: CompressionCandidate, _ qa: Double,
                                       _ b: CompressionCandidate, _ qb: Double) -> Bool {
        guard !a.kind.isKeep else { return false }
        let am = a.metrics, bm = b.metrics
        guard bm.encodedBytes <= am.encodedBytes, qb >= qa else { return false }
        return bm.encodedBytes < am.encodedBytes || qb > qa
    }

    /// Vergleichbarkeit der Qualitäten: Verlustbehaftete Kandidaten OHNE
    /// strukturelle Messung (CMYK-YCCK – das Codec-eigene ΔE-Gate trägt die
    /// Schranke) dürfen nicht mit Schein-Qualität 1.0 in die Dominanz gehen,
    /// sonst verdrängen sie KEEP und verlustfreie Kandidaten. Solche Paare
    /// gelten als unvergleichbar und bleiben alle im Raum.
    private static func isComparable(_ a: CompressionCandidate,
                                     _ b: CompressionCandidate) -> Bool {
        func unmeasuredLossy(_ c: CompressionCandidate) -> Bool {
            !c.isLossless && c.metrics.gateMeasurement == nil
        }
        return !unmeasuredLossy(a) && !unmeasuredLossy(b)
    }
}
