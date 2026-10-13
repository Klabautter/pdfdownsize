import Foundation

// MARK: - Masterplan §12 – Target File Size / Global Budget Optimizer (V2-6)
//
// Das Problem (§12.2): Je Ressource i existieren Kandidaten j mit Bytes B_ij
// und Verzerrung D_ij. Gesucht ist das Minimum der GESAMTVERZERRUNG unter der
// Nebenbedingung
//
//     Σ gewählte Bytes + fester PDF-Overhead  <=  Zielbytes
//
// und unter ALLEN Safety-/Quality-/Compatibility-Gates (§10.1–§10.6). Der
// Optimizer schneidet deshalb NIE in einen gate-ungeprüften Raum: Er erhält
// den zulässigen Pool aus `RateDistortionOptimizer.eligibility` (V2-4) und
// sucht ausschließlich darin („harte Gates zuerst“, §4 Prinzip 3).
//
// Floor-Kopplung an das Preset (§12.8, bewusste Produktsemantik):
// `CompressionGoal.targetBytes` ist ein Ziel ÜBER einem Preset. Es koppelt an
// die Preset-Politik des gewählten Modus (Klein/Smart/Qualität – erkennbar an
// der SSIM-Zusage der Optionen) und VERSCHÄRFT sie per Budget: Der Optimizer
// wählt aggressiver, aber der Mindest-Floor bleibt exakt der des Presets.
// Nie darunter (§12.8: keine Zahl ist eine Qualität wert).
//
// Fonts und MRC (§12.5): Font-Entscheidungen (subset/keep) werden in V2-6
// bewusst NICHT per λ geschnitten – sie bleiben Preset-Politik (§14 holt
// Font-Kandidaten später nach). MRC existiert erst ab V2-7; die
// `CandidateGroup`-Abstraktion unten bereitet die Schnittstelle vor.

// MARK: - §12.1 TargetSizeResult

/// Das Ergebnis eines Zielgrößen-Laufs (§12.1).
struct TargetSizeResult: Equatable, Sendable {
    let requestedBytes: Int64
    /// Die AUSGELIEFERTE Größe (nach Actual-Size-Feedback, §12.6).
    let achievedBytes: Int64
    /// true = die ausgelieferte Datei hält das Ziel.
    let targetMet: Bool
    /// Kleinste sicher erreichbare Größe (§12.8); nil, wenn nie berechnet
    /// (Lauf ohne Zielgrößen-Ziel).
    let minimumSafeBytes: Int64?
}

// MARK: - §12.5 CandidateGroup

/// Dependency Group (§12.5): Kandidatenmengen, die GEMEINSAM entschieden
/// werden, weil sie voneinander abhängen.
///
///   • Shared Image – ein Bildobjekt, mehrere Seiten: bereits durch seine
///     Objektidentität EINE Ressource (ein Set), keine eigene Gruppe nötig.
///   • MRC (V2-7) – Maske + Hintergrund + Foto-Overlays einer Scan-Seite:
///     mehrere Sets, EINE Entscheidung (Bundle).
///   • Fonts (§14) – FontFile + FontDict + Widths: EIN Bundle. In V2-6
///     bewusst KEIN λ-Gruppenmitglied: Font-Entscheidungen bleiben
///     Preset-Politik (dokumentierte V2-6-Vereinfachung).
///
/// V2-6 kennt nur Ein-Set-Gruppen (unabhängige Bildressourcen). Mehrere Sets
/// je Gruppe werden solange je-Set entschieden; das Bundle-argmin folgt
/// mit V2-7.
struct CandidateGroup: Sendable {
    let sets: [CandidateSet]

    static func single(_ set: CandidateSet) -> CandidateGroup {
        CandidateGroup(sets: [set])
    }
}

// MARK: - Optimizer

/// Globaler Budget-Optimizer (§12.3–§12.5).
enum TargetSizeOptimizer {

    // MARK: §12.3 – Fixed Bytes

    /// Struktur-Pass-Faktor aus den V2-1-Messwerten (Estimator-Kooperation,
    /// §16): Der Anteil des NICHT-Bild-Anteils (Seitenbäume, Content-Streams,
    /// Fonts, Annotationen, Anhänge), der nach `--recompress-flate` übrig
    /// bleibt. Derselbe Wert wie der Estimator-Punktwert ohne Dedup-Vorschau.
    static let structureFactor = 0.93

    /// §12.7 Target Tolerance – geplant wird 2 % UNTER dem Ziel, um die
    /// Overhead-Schwankung des finalen Schreibens (Objekt-Streams, xref,
    /// Dictionaries) abzufangen. Produktziel bleibt strikt: output <= target.
    static let planMargin = 0.02

    /// Feste Bytes (§12.3): Dokumentgröße − optimierbare Ressourcen-Bytes
    /// (KEEP-Bytes je Ressource mit CandidateSet), mal dem Struktur-Faktor.
    ///
    /// Bewusst GROB modelliert: Behaltene Flate-/DCT-Streams bekommen ihren
    /// Repack-/Recompress-Bonus hier nicht einzeln zugerechnet (der Estimator
    /// tut das mit `keptFlateRetention`/`keptDCTRepackSaving`); die Drift
    /// korrigiert das Actual-Size-Feedback (§12.6) mit GEMESSENEN Größen.
    /// Die Erstschätzung muss die λ-Suche nur in die richtige Richtung
    /// lenken, nicht bytegenau sein.
    static func fixedBytes(documentBytes: Int,
                           optimizableBytes: Int) -> Int64 {
        let base = max(0, documentBytes - max(0, optimizableBytes))
        return Int64((Double(base) * structureFactor).rounded())
    }

    /// §12.6 – Nachkalibrierung: Die Kandidaten-Bytes sind gemessen (jeder
    /// gewählte Payload wurde produziert); die gesamte Drift zwischen
    /// Erwartung und tatsächlicher Dateigröße stammt aus dem festen Anteil.
    static func recalibratedFixedBytes(actualTotalBytes: Int64,
                                       selectedCandidateBytes: Int64) -> Int64 {
        max(0, actualTotalBytes - max(0, selectedCandidateBytes))
    }

    // MARK: Ergebnisse

    /// Die Wahl des Optimizers für EINE Ressource.
    struct Selection: Sendable {
        let resourceID: String
        let candidate: CompressionCandidate
        /// Gate-bestandener Pool – Quelle der Rückstufungsleiter (§5.7).
        let pool: [CompressionCandidate]
        /// Begründung mit messbaren Zahlen (§4 Prinzip 12).
        let reason: String
        var candidateIDsBySafety: [CandidateID] {
            ResourceDecision.safetyLadder(of: pool)
        }
    }

    /// Das Ergebnis der Optimierung (Plan-Ebene, vor Ausführung).
    struct Optimization: Sendable {
        let selections: [Selection]
        let requestedBytes: Int64
        /// Erwartete Gesamtgröße: Fixed-Bytes + Σ gewählte Kandidaten.
        let expectedBytes: Int64
        /// Alle Ressourcen auf ihren kleinsten GATE-BESTEHENDEN Kandidaten
        /// (§12.8) – die Untergrenze des sicher Erreichbaren.
        let minimumSafeBytes: Int64
        /// false = Ziel liegt unter dem Sicher-Erreichbaren (§12.8): Ausgabe
        /// ist die kleinste sichere Datei, KEIN Floor-Bruch, KEIN stiller
        /// Fallback.
        let reachable: Bool
        /// λ der Lagrangian-Suche (Telemetrie; .infinity im §12.8-Fall).
        let lambda: Double
        /// true = die Feinkorrektur hat Qualität nachgekauft (§12.4).
        let fineTuned: Bool
    }

    /// Eingabequelle: Gruppe + Inhaltsklasse (für die §10.2-Skalarisierung).
    struct Source: Sendable {
        let group: CandidateGroup
        let contentClass: ContentClass
    }

    // MARK: Optimierung

    /// Fährt §12.2–§12.5. Deterministisch: Gleichstände (Score, Bytes) gehen
    /// an die Generatorreihenfolge, KEEP@0 gewinnt jeden Gleichstand.
    static func optimize(sources: [Source],
                         targetBytes: Int64,
                         fixedBytes: Int64,
                         preset: QualityGatePreset) -> Optimization {
        // 1. Gate-bestandene Pools je Ressource (V2-4-Gates fallen VOR der
        //    Suche; §12.2). Shared Image ist bereits eine Ressource; V2-6
        //    entscheidet je Set (CandidateGroup-Kommentar, §12.5).
        var pools: [ResourcePool] = []
        for source in sources {
            for set in source.group.sets {
                pools.append(ResourcePool(set: set,
                                          contentClass: source.contentClass,
                                          preset: preset))
            }
        }

        let requested = max(0, targetBytes)
        let planningTarget = Int64((Double(requested) * (1.0 - planMargin))
            .rounded(.down))
        let minimumSafeBytes = fixedBytes + pools.reduce(Int64(0)) {
            $0 + $1.smallestBytes
        }

        // 2.–4.
        var chosenIndices: [Int]
        var lambda = Double.infinity
        var fineTuned = false
        let reachable = minimumSafeBytes <= planningTarget
        if reachable, !pools.isEmpty {
            // Die Suche läuft über die BILDBYTES: das Fixed-Budget (§12.3)
            // ist von der Schranke abgezogen, bevor λ gefunden wird.
            let imageBudget = max(0, planningTarget - fixedBytes)
            lambda = Self.searchLambda(pools: pools,
                                       planningTarget: imageBudget)
            chosenIndices = pools.map { $0.argminIndex(lambda: lambda) }
            // 3. Feinkorrektur: das Restbudget in Qualität ausgeben.
            let spent = fixedBytes + pools.reduce(Int64(0)) { sum, pool in
                let index = chosenIndices[Self.indexOf(pool, in: pools)]
                return sum + pool.ranked[index].bytes
            }
            let result = Self.fineCorrect(pools: pools,
                                          indices: chosenIndices,
                                          budget: planningTarget - spent)
            chosenIndices = result.indices
            fineTuned = result.changed
        } else {
            // §12.8 – Unerreichbares Ziel: kleinste SICHERE Wahl (Pool-
            // Minimum, identisch zur lokalen §10.6-Wahl). Kein Floor-Bruch,
            // kein stiller Fallback – die Meldung erklärt die Lücke.
            chosenIndices = pools.map(\.smallestIndex)
        }

        var expectedBytes = fixedBytes
        var selections: [Selection] = []
        for (index, pool) in pools.enumerated() {
            let chosen = pool.ranked[chosenIndices[index]]
            expectedBytes += chosen.bytes
            let reason: String
            if reachable {
                var text = String(format: "Zielgrößen-Optimizer (§12.4): "
                    + "λ=%.3e, B=%lld, D=%.4f", lambda, chosen.bytes,
                    chosen.distortion)
                if fineTuned { text += " (inkl. Feinkorrektur)" }
                reason = text
            } else {
                reason = "Unerreichbares Ziel (§12.8): kleinster "
                    + "\(preset.rawValue)-gate-bestehender Candidate "
                    + "(B=\(chosen.bytes), sicher erreichbar ca. "
                    + "\(minimumSafeBytes) bei Ziel \(requested))"
            }
            selections.append(Selection(
                resourceID: pool.set.resourceID,
                candidate: chosen.candidate,
                pool: pool.pool,
                reason: reason))
        }
        return Optimization(selections: selections,
                            requestedBytes: requested,
                            expectedBytes: expectedBytes,
                            minimumSafeBytes: minimumSafeBytes,
                            reachable: reachable,
                            lambda: lambda,
                            fineTuned: fineTuned)
    }

    /// Index eines Pools in der Pools-Liste (Gleichstand ausgeschlossen:
    /// resourceIDs sind eindeutig).
    private static func indexOf(_ pool: ResourcePool,
                                in pools: [ResourcePool]) -> Int {
        pools.firstIndex { $0.set.resourceID == pool.set.resourceID } ?? 0
    }

    // MARK: Ressourcen-Pool

    /// Gate-bestandene Kandidaten EINER Ressource mit vorberechneter
    /// Verzerrung d = 1 − Q (§10.2-Skalarisierung, Q = gewichtetes Mittel der
    /// DistortionVector-Dimensionen; nil-Messung = KEEP/verlustfrei = Q 1.0).
    struct ResourcePool: Sendable {
        let set: CandidateSet
        /// Zulässige Kandidaten in Generatorreihenfolge (V2-4-Pool) – Quelle
        /// der Rückstufungsleiter.
        let pool: [CompressionCandidate]
        /// Bytes-AUFSTEIGEND sortiert; Gleichstände behalten die Generator-
        /// reihenfolge (KEEP@0 zuerst).
        let ranked: [(candidate: CompressionCandidate,
                      distortion: Double, bytes: Int64)]
        /// Der kleinste zulässige Candidate (§10.6-Semantik).
        let smallest: CompressionCandidate

        init(set: CandidateSet, contentClass: ContentClass,
             preset: QualityGatePreset) {
            let eligibility = RateDistortionOptimizer.eligibility(
                from: set, contentClass: contentClass, preset: preset)
            self.pool = eligibility.pool
            // Bytes-AUFSTEIGEND sortiert (stabil: Gleichstände behalten die
            // Generatorreihenfolge, KEEP@0 gewinnt) – so liegt der nächste
            // Frontier-Nachbar (mehr Bytes, weniger Verzerrung) beim Folge-
            // index, und smallestIndex zeigt auf Position 0.
            let ranked = eligibility.pool.enumerated().sorted { a, b in
                let ab = a.element.metrics.encodedBytes
                let bb = b.element.metrics.encodedBytes
                if ab != bb { return ab < bb }
                return a.offset < b.offset
            }
            self.ranked = ranked.map { entry in
                (candidate: entry.element,
                 distortion: 1.0 - entry.element.metrics.quality(for: contentClass),
                 bytes: Int64(entry.element.metrics.encodedBytes))
            }
            // min(by:) mit strikt-kleiner-Ordnung; Gleichstände behalten die
            // Generatorreihenfolge (KEEP@0 gewinnt).
            self.smallest = eligibility.pool.min {
                $0.metrics.encodedBytes < $1.metrics.encodedBytes
            } ?? eligibility.pool[0]
            self.set = set
        }

        /// Index des argmin über score(c) = d + λ·b (§12.4). Gleichstände:
        /// kleinere Bytes, dann Generatorreihenfolge – deterministisch.
        func argminIndex(lambda: Double) -> Int {
            var best = 0
            var bestScore = ranked[0].distortion
                + lambda * Double(ranked[0].bytes)
            for index in ranked.indices.dropFirst() {
                let score = ranked[index].distortion
                    + lambda * Double(ranked[index].bytes)
                if score < bestScore
                    || (score == bestScore
                        && ranked[index].bytes < ranked[best].bytes) {
                    bestScore = score
                    best = index
                }
            }
            return best
        }

        /// Index des kleinsten zulässigen Kandidaten (§12.8-Wahl).
        var smallestIndex: Int {
            var best = 0
            for index in ranked.indices where ranked[index].bytes
                < ranked[best].bytes {
                best = index
            }
            return best
        }

        var smallestBytes: Int64 {
            Int64(smallest.metrics.encodedBytes)
        }

        /// Gesamtbytes (ohne Fixed-Anteil) bei λ.
        func totalBytes(lambda: Double) -> Int64 {
            ranked[argminIndex(lambda: lambda)].bytes
        }
    }

    // MARK: §12.4 – Lagrangian Search

    /// Kleinstes λ, dessen Wahl in das Planziel fällt. totalBytes(λ) ist
    /// non-increasing (pro Ressource beweisbar: Für λ₁ < λ₂ kann der argmin
    /// bei λ₂ nicht MEHR Bytes wählen, sonst widersprechen sich die
    /// argmin-Ungleichungen – Eigenschaft in TargetSizeOptimizerTests
    /// verankert). Die Bisektion auf dem Prädikat „passt in das Planziel“
    /// ist damit korrekt.
    static func searchLambda(pools: [ResourcePool],
                             planningTarget: Int64) -> Double {
        var lo = 0.0            // beste Qualität (KEEP gewinnt die Gleichstände)
        var hi = 1.0
        // Bestes Q (λ = 0) passt bereits → kein Zieldruck.
        if totalBytes(lambda: lo, pools: pools) <= planningTarget {
            return lo
        }
        // Verdoppeln, bis die Wahl ins Ziel fällt oder die kleinste Stufe
        // saturiert (λ-Skala ist Verzerrung/Byte, d ≤ 1).
        while totalBytes(lambda: hi, pools: pools) > planningTarget {
            let next = hi * 2
            if next > 1e18 {
                return hi   // erschöpft: die kleinste Wahl bleibt über Ziel
            }
            if totalBytes(lambda: next, pools: pools)
                == totalBytes(lambda: hi, pools: pools) {
                return hi   // Sättigung – kleinste Wahl erreicht (§12.8-Fall)
            }
            hi = next
        }
        // Bisektion auf dem monotonen Prädikat – AUCH wenn λ = 1 bereits
        // passt: Gesucht ist das KLEINSTE λ (beste Qualität) unter der
        // Schranke, nicht die saturierte Wahl bei λ = 1.
        for _ in 0..<64 {
            let mid = (lo + hi) / 2
            if totalBytes(lambda: mid, pools: pools) <= planningTarget {
                hi = mid
            } else {
                lo = mid
            }
            if hi - lo < 1e-15 { break }
        }
        return hi
    }

    static func totalBytes(lambda: Double, pools: [ResourcePool]) -> Int64 {
        pools.reduce(0) { $0 + $1.totalBytes(lambda: lambda) }
    }

    // MARK: §12.4 – diskrete Feinkorrektur

    /// Gibt das Restbudget in Qualität aus: Je Ressource der NÄCHSTE
    /// Frontier-Nachbar mit QUALITÄTSGEWINN (mehr Bytes, weniger Verzerrung);
    /// der Schritt mit dem besten ΔQualität/ΔByte gewinnt, solange das
    /// Budget reicht. Pro Ressource wandert der Zeiger aufsteigend weiter –
    /// keine neuen Encodes, nur Frontier-Nachbarn (§12.4). Das Ergebnis
    /// bleibt strikt unter dem Planziel (§12.7).
    static func fineCorrect(pools: [ResourcePool],
                            indices: [Int],
                            budget: Int64) -> (indices: [Int], changed: Bool) {
        guard budget > 0, !pools.isEmpty, indices.count == pools.count else {
            return (indices, false)
        }
        var chosen = indices
        var spent = Int64(0)
        var changed = false

        while true {
            var best: (pool: Int, index: Int, gain: Double, cost: Int64)?
            for (poolIndex, pool) in pools.enumerated() {
                var nextIndex = chosen[poolIndex] + 1
                // Nächsten Nachbar MIT Qualitätsgewinn suchen (die Frontier
                // ist bytes-aufsteigend; Zwischenstufen ohne Gewinn werden
                // übersprungen).
                while nextIndex < pool.ranked.count,
                      pool.ranked[chosen[poolIndex]].distortion
                          - pool.ranked[nextIndex].distortion <= 1e-9 {
                    nextIndex += 1
                }
                guard nextIndex < pool.ranked.count else { continue }
                let current = pool.ranked[chosen[poolIndex]]
                let next = pool.ranked[nextIndex]
                let cost = next.bytes - current.bytes
                let gain = current.distortion - next.distortion
                guard cost > 0, spent + cost <= budget else { continue }
                let marginal = gain / Double(cost)
                if let candidate = best,
                   marginal <= candidate.gain / Double(candidate.cost) {
                    continue
                }
                best = (poolIndex, nextIndex, gain, cost)
            }
            guard let step = best else { break }
            chosen[step.pool] = step.index
            spent += step.cost
            changed = true
        }
        return (chosen, changed)
    }

    // MARK: §12.6 – Actual-Size Feedback

    /// Das Ergebnis einer Nachjustierung: Overrides für den Re-Plan-Lauf
    /// (V2-5-Mechanik) plus die Kennzahlen der Meldung.
    struct Reoptimization: Sendable {
        let overrides: DecisionOverrides
        let expectedBytes: Int64
        let minimumSafeBytes: Int64
        /// true = Ziel liegt unter dem Sicher-Erreichbaren (§12.8).
        let unreachable: Bool
    }

    /// §12.6 – Entscheidung des Actual-Size-Loops: Overrides für einen
    /// kleineren Re-Plan-Lauf – oder nil, wenn kein sicherer kleinerer
    /// Stand existiert (bzw. das Ziel bereits gehalten wird).
    ///
    /// Reine Funktion über Plan + gemessene Größe: testbar ohne Pipeline.
    /// Mindestgewinn für einen Re-Lauf: ~1 % der gemessenen Größe – darunter
    /// lohnt die erneute Ausführung nicht.
    static func reoptimization(plan: CompressionPlan,
                               actualBytes: Int64,
                               requestedBytes: Int64,
                               preset: QualityGatePreset) -> Reoptimization? {
        guard plan.traceVersion >= 2,
              plan.candidateSets.count == plan.decisions.count,
              actualBytes > requestedBytes else { return nil }

        let setsByID = Dictionary(uniqueKeysWithValues:
            plan.candidateSets.map { ($0.resourceID, $0) })
        var sources: [Source] = []
        var selectedBytes = Int64(0)
        for decision in plan.decisions {
            guard let set = setsByID[decision.resourceID] else { continue }
            sources.append(Source(group: .single(set),
                                  contentClass: decision.classification))
            if let candidate = set.candidates.first(where: {
                $0.id == decision.selectedCandidateID
            }) {
                selectedBytes += Int64(candidate.metrics.encodedBytes)
            }
        }
        guard !sources.isEmpty else { return nil }

        let fixed = recalibratedFixedBytes(actualTotalBytes: actualBytes,
                                           selectedCandidateBytes: selectedBytes)
        let optimization = optimize(sources: sources,
                                    targetBytes: requestedBytes,
                                    fixedBytes: fixed,
                                    preset: preset)
        let epsilon = max(4096, actualBytes / 100)
        guard optimization.expectedBytes < actualBytes - epsilon else {
            return nil   // kein sicherer kleinerer Stand von Gewicht
        }

        var overrides = DecisionOverrides()
        // Die Overrides laufen über die V2-5-Mechanik, tragen aber ihre
        // eigene Herkunft in die ResourceDecision.reason (§4 Prinzip 12).
        overrides.label = "Zielgrößen-Re-Optimierung (§12.6)"
        for selection in optimization.selections {
            overrides.forcedCandidates[selection.resourceID] =
                selection.candidate.id
        }
        return Reoptimization(overrides: overrides,
                              expectedBytes: optimization.expectedBytes,
                              minimumSafeBytes: optimization.minimumSafeBytes,
                              unreachable: !optimization.reachable)
    }
}
