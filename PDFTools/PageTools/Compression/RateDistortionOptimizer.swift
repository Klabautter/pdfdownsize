import Foundation

// MARK: - Masterplan §10 – Local Rate-Distortion Optimizer (V2-4)
//
// V1:  class → fixer Pfad
// V2:  class → Candidate Set → kleinste zulässige Repräsentation
//
// Reihenfolge der Entscheidung (§10.1 „harte Gates zuerst“):
//
//   1. §10.5  Pareto-Pruning über die klassengewichtete Qualität.
//   2. §10.1  Harte Gates: never grow, Kompatibilitäts-/Semantik-Risiko.
//   3. §10.3  Katastrophen-Floor – unverhandelbar, ÜBER allen Presets, auch
//             hinter Custom/fixed (Produktsicherheit).
//   4. §10.6  Preset-Floor (QualityGates-Matrix) und Wahl des KLEINSTEN
//             Candidates, der ihn hält – für smallest/balanced/bestQuality
//             identisch zur bisherigen planViaCandidates-Wahl, aber über die
//             Pareto-Menge und mit expliziter Begründung je Ressource.
//
// Verlorene Kandidaten ( Floors) verlassen den Kandidatenraum VOLLSTÄNDIG –
// sie stehen auch nicht in der Rückstufungsleiter (V2-5 rollt nur auf
// zulässige Alternativen zurück).

// MARK: §10.2 – Klassengewichte der Skalarisierung

/// Gewichte, mit denen der DistortionVector (Qualität je Dimension) für eine
/// Inhaltsklasse zu EINEM Vergleichswert skalarisiert wird. Die Gewichte
/// stehen bewusst als Konstanten im Optimizer-Modul und folgen §10.2:
///
///   Photo:      global + color             (Fläche trägt, Farbtreue zählt)
///   Screenshot: edge + text + local worst  (Kanten und Textkacheln tragen)
///   Map:        edge + local worst         (Diagonalgewebe, keine Textzusage)
///   Scan:       text + edge + local worst  (Text ist die teuerste Dimension)
///
/// Klassen, die §10.2 nicht nennt, erben konservativ:
///   lineArt/chart → screenshot-Gewichte (Grafikfamilie),
///   scanBilevel   → scan-Gewichte (verlustfreier Namespace, nur Telemetrie),
///   mixedRaster/unknown → screenshot-Gewichte (konservativste Mischung).
///
/// Skalarisierung = gewichtetes Mittel ÜBER die gemessenen (nicht-nil)
/// Dimensionen; fehlende Dimensionen werden ausgeschlossen und die Gewichte
/// renormalisiert. Alles nil (KEEP/verlustfrei ohne Messung) → Qualität 1.0.
enum DistortionWeights {

    struct Weights: Sendable {
        let global: Double
        let localWorst: Double
        let edge: Double
        let text: Double
        let color: Double
    }

    static func weights(for contentClass: ContentClass) -> Weights {
        switch contentClass {
        case .photo:
            // §10.2 Photo: global + color.
            return Weights(global: 0.60, localWorst: 0, edge: 0, text: 0, color: 0.40)
        case .screenshot, .lineArt, .chart, .mixedRaster, .unknown:
            // §10.2 Screenshot: edge + text + local worst.
            return Weights(global: 0, localWorst: 0.30, edge: 0.40, text: 0.30, color: 0)
        case .mapTechnical:
            // §10.2 Map: edge + local worst.
            return Weights(global: 0, localWorst: 0.50, edge: 0.50, text: 0, color: 0)
        case .scanContinuous, .scanBilevel:
            // §10.2 Scan: text + edge + local worst.
            return Weights(global: 0, localWorst: 0.30, edge: 0.30, text: 0.40, color: 0)
        }
    }
}

extension CandidateMetrics {

    /// §10.2/§10.5 – Qualität des Kandidaten, skalarisiert mit den Gewichten
    /// der Inhaltsklasse. Ohne Messung (KEEP, verlustfrei ohne Gate) gilt 1.0.
    func quality(for contentClass: ContentClass) -> Double {
        let v = distortion
        let w = DistortionWeights.weights(for: contentClass)
        var sum = 0.0
        var total = 0.0
        for (value, weight) in [(v.global, w.global), (v.localWorst, w.localWorst),
                                (v.edgeLoss, w.edge), (v.textLoss, w.text),
                                (v.colorLoss, w.color)] {
            guard let value, weight > 0 else { continue }
            sum += value * weight
            total += weight
        }
        guard total > 0 else { return 1.0 }
        return sum / total
    }
}

// MARK: §10.1/§10.6 – Gate-Zelle zur Inhaltsklasse

extension QualityGateClass {

    /// Gate-Zelle zur V2-Klasse – SPIEGELT die Generator-Route
    /// (`ContentClass.derivedImageClass`): Verlustbehaftete Kandidaten
    /// entstehen nur auf der Foto-Route (Matrix .photo) und der aggressiven
    /// Grafik-Route (Matrix .graphics). Die Optimizer-Nachprüfung darf die
    /// Erzeugungsprüfung nie strenger nachfahren, nur spiegeln:
    ///
    ///   photo / mapTechnical / mixedRaster → .photo (Foto-Route)
    ///   scanContinuous / scanBilevel → .scan (dedizierte Scan-Zelle)
    ///   screenshot / lineArt / chart → .graphics (Grafik-Route)
    ///   unknown → .photo: die Route ist nicht rekonstruierbar; die Nach-
    ///       prüfung spiegelt die WEITERE Matrix. Konservativität für
    ///       unbekannten Inhalt liefern der Klassifikator (unknown führt auf
    ///       Verlustfrei-Pfade) und der klassenübergreifende Katastrophen-
    ///       Floor (§10.3).
    init(contentClass: ContentClass) {
        switch contentClass {
        case .photo, .mapTechnical, .mixedRaster, .unknown:
            self = .photo
        case .scanContinuous, .scanBilevel:
            self = .scan
        case .screenshot, .lineArt, .chart:
            self = .graphics
        }
    }
}

// MARK: - Optimizer

/// Wählt aus einem CandidateSet (§5.6) die kleinste zulässige Repräsentation.
enum RateDistortionOptimizer {

    /// Ein verworfener Kandidat mit knapper, nachlesbarer Begründung.
    struct Rejection: Equatable, Sendable {
        let candidateID: CandidateID
        let reason: String
    }

    /// Das Ergebnis der lokalen Wahl einer Ressource.
    struct Selection: Sendable {
        /// Der gewählte Kandidat – mindestens KEEP (§9.1), niemals nil.
        let candidate: CompressionCandidate
        /// Explizite Qualitäts-/Größenbegründung (§4 Prinzip 12) für
        /// `ResourceDecision.reason`.
        let reason: String
        /// Verworfene Kandidaten (Pareto-Ausfälle sind keine Verwerfungen).
        let rejections: [Rejection]
        /// true = mindestens ein verlustbehafteter Kandidat ist am
        /// Katastrophen-Floor (§10.3) gescheitert und die Wahl fiel auf
        /// KEEP zurück – der Plan führt das als `KeepReason.
        /// catastrophicFloorFailed`.
        let catastrophicRejection: Bool
        /// Rückstufungsleiter (§5.7) – NUR aus zulässigen Kandidaten,
        /// aufsteigend konservativ: verlustbehaftet (aufsteigend nach Bytes),
        /// verlustfrei, KEEP als letzte Stufe (V2-5 rollt hierauf zurück).
        let candidateIDsBySafety: [CandidateID]
    }

    /// Obergrenzen der heuristischen §10.1-Risiken. Die heutigen Kinds liegen
    /// deutlich darunter (JPEG 0.1/0.05–0.3, CMYK 0.2, JBIG2 0.2); die Caps
    /// sind das strukturale Gate für künftige Kandidatenarten.
    static let maximumCompatibilityRisk = 0.5
    static let maximumSemanticRisk = 0.5

    /// Die gate-geprüfte Auswahlmenge einer Ressource (V2-4). Bewusst
    /// herausgezogen: Der Zielgrößen-Optimizer (V2-6, §12.2–12.4) sucht über
    /// DENSELBEN Pool – harte Gates, Katastrophen-Floor und Preset-Floor
    /// fallen VOR der Lagrangian-Suche, nie darunter (§4 Prinzip 3, §12.2).
    struct Eligibility: Sendable {
        /// Zulässige Kandidaten in Generatorreihenfolge; KEEP ist garantiert
        /// enthalten (§9.1, auch wenn ein verlustfreier Kandidat ihn aus der
        /// Wahl drängt).
        let pool: [CompressionCandidate]
        /// Der kleinste zulässige Candidate – die Wahl ohne Budgetdruck
        /// (identisch zur §10.6-Wahl).
        let winner: CompressionCandidate
        /// true = mindestens ein verlustbehafteter Kandidat scheiterte am
        /// Katastrophen-Floor (§10.3).
        let catastrophicRejection: Bool
        /// Verworfene Kandidaten mit Begründung (§4 Prinzip 12).
        let rejections: [Rejection]
        /// Rückstufungsleiter über den Pool (§5.7).
        var candidateIDsBySafety: [CandidateID] {
            ResourceDecision.safetyLadder(of: pool)
        }
    }

    /// Pareto-Pruning (§10.5) + harte Gates (§10.1) + Katastrophen-Floor
    /// (§10.3) + Preset-Floor (§10.6). Liefert die ZULÄSSIGE Menge; die
    /// Wahl aus ihr trifft `select` (lokal, kleinster) bzw. der
    /// TargetSizeOptimizer (global, §12.4).
    static func eligibility(from set: CandidateSet,
                            contentClass: ContentClass,
                            preset: QualityGatePreset) -> Eligibility {
        let gateClass = QualityGateClass(contentClass: contentClass)
        let keep = set.keepCandidate ?? set.candidates.first { $0.kind.isKeep }
            ?? set.candidates.first!

        // 1.–3. Harte Gates, Katastrophen-Floor, Preset-Floor – VOR dem
        // Pareto-Pruning. Umgekehrt dominierte ein unsicherer Kandidat
        // (kleiner, nominell bessere SSIM, aber über dem perzeptuellen Gate)
        // den sicheren und entfernte ihn; danach fiel der unsichere am Gate,
        // und das Original gewann (USGS-Karte in Klein: 59 Kacheln in voller
        // Größe, Core-235 2026-09-30). Gepruned wird nur noch unter
        // zulässigen Kandidaten.
        var rejections: [Rejection] = []
        var catastrophicRejection = false
        var survivors: [(order: Int, candidate: CompressionCandidate)] = []

        for (order, candidate) in set.candidates.enumerated() {
            if candidate.kind.isKeep {
                survivors.append((order, candidate))
                continue
            }

            // §10.1 never grow – gegen KEEP (bei unbekannter Originalgröße
            // ist die Barriere offen; der Generator hat sie bereits
            // erzwungen, hier wird sie nur nachgeprüft).
            if keep.metrics.encodedBytes > 0,
               candidate.metrics.encodedBytes >= keep.metrics.encodedBytes {
                rejections.append(Rejection(
                    candidateID: candidate.id,
                    reason: "never grow (\(candidate.metrics.encodedBytes) ≥ "
                            + "\(keep.metrics.encodedBytes))"))
                continue
            }

            // §10.1 Kompatibilität/Semantik (heuristische Risiken).
            if candidate.metrics.compatibilityRisk > maximumCompatibilityRisk {
                rejections.append(Rejection(
                    candidateID: candidate.id,
                    reason: String(format: "compatibility risk %.2f > %.2f",
                                   candidate.metrics.compatibilityRisk,
                                   maximumCompatibilityRisk)))
                continue
            }
            if candidate.metrics.semanticRisk > maximumSemanticRisk {
                rejections.append(Rejection(
                    candidateID: candidate.id,
                    reason: String(format: "semantic risk %.2f > %.2f",
                                   candidate.metrics.semanticRisk,
                                   maximumSemanticRisk)))
                continue
            }

            // V2-7 (§13.10) – MRC-Seitenbündel: Die SEITEN-QA hat das Bild-
            // Gate bereits ERSETZT (der Kandidat liegt nur vor, wenn SSIM ≥
            // 0.97, p05 ≥ 0.95, CAR ≤ 0.05, inkDelta ≤ 0.005 an echter
            // Seiten render bestanden). Die Preset-Floors der Bildmatrix
            // (Foto-/Grafik-Zellen) sind für Scan-Seiten nicht maßgeblich
            // und würden die strengere Seiten-QA nur nachfahren. Der
            // unverhandelbare Katastrophen-Floor (§10.3) bleibt als zweite
            // Verteidigungslinie bestehen.
            if case .mrc = candidate.kind {
                if let measurement = candidate.metrics.gateMeasurement,
                   case .fail(let violated) = QualityGates.qualityVerdict(
                        policy: .catastrophicFloors(for: gateClass),
                        measurement: measurement) {
                    catastrophicRejection = true
                    rejections.append(Rejection(
                        candidateID: candidate.id,
                        reason: "Katastrophen-Floor "
                                + Self.describe(violated: violated, policy:
                                    .catastrophicFloors(for: gateClass),
                                    measurement: measurement)))
                    continue
                }
                survivors.append((order, candidate))
                continue
            }

            // Verlustfreie Kandidaten unterliegen keinen Qualitätsgates.
            guard !candidate.isLossless else {
                survivors.append((order, candidate))
                continue
            }

            // Verlustbehaftet OHNE strukturelle Messung (CMYK-YCCK): Das
            // Codec-eigene ΔE-Gate (§9.8) ist hier die Qualitätsschranke;
            // der Katastrophen-Floor bewertet Strukturmetriken und kann ohne
            // Messung nicht greifen. Der Kandidat bleibt zulässig.
            guard let measurement = candidate.metrics.gateMeasurement else {
                survivors.append((order, candidate))
                continue
            }

            // §10.3 – Katastrophen-Floor ZUERST (unverhandelbar, auch Custom).
            if case .fail(let violated) = QualityGates.qualityVerdict(
                policy: .catastrophicFloors(for: gateClass),
                measurement: measurement) {
                catastrophicRejection = true
                rejections.append(Rejection(
                    candidateID: candidate.id,
                    reason: "Katastrophen-Floor "
                            + Self.describe(violated: violated, policy:
                                .catastrophicFloors(for: gateClass),
                                measurement: measurement)))
                continue
            }

            // Perzeptueller AND-Gate (§10.3-Familie): Der SSIM-Vektor sieht
            // eingeführte Kanten (Ringing/Halos) nicht, wenn sich Mittelwerte
            // ausgleichen – der Score fängt sie über die Kanten-Einführung.
            // Unverhandelbar wie der Floor, auch hinter Custom/fixed. Ohne
            // Messung (CMYK mit eigenem ΔE-Gate, MRC mit Seiten-QA) greift er
            // nicht – deren Gates sind bereits strenger bzw. zuständig.
            if let perceptual = candidate.metrics.perceptualScore,
               perceptual > PerceptualScore.catastrophicLimit {
                catastrophicRejection = true
                rejections.append(Rejection(
                    candidateID: candidate.id,
                    reason: String(format: "perzeptueller Katastrophen-Gate "
                        + "%.4f>%.2f", perceptual,
                        PerceptualScore.catastrophicLimit)))
                continue
            }

            // §10.6 – Preset-Floor (QualityGates-Matrix der Klasse).
            if case .fail(let violated) = QualityGates.qualityVerdict(
                policy: .policy(preset: preset, imageClass: gateClass),
                measurement: measurement) {
                rejections.append(Rejection(
                    candidateID: candidate.id,
                    reason: "floor "
                            + Self.describe(violated: violated, policy:
                                .policy(preset: preset, imageClass: gateClass),
                                measurement: measurement)))
                continue
            }

            survivors.append((order, candidate))
        }

        // 4. §10.5 – Pareto-Pruning über die ZULÄSSIGEN Kandidaten (vor der
        // Optimierung; KEEP wird nie dominiert).
        let frontierIDs = Set(CandidatePareto.frontier(survivors.map(\.candidate),
                                                       contentClass: contentClass).map(\.id))
        survivors = survivors.filter { frontierIDs.contains($0.candidate.id) }

        // §10.6 – kleinster zulässiger Candidate; Gleichstand → Generator-
        // reihenfolge (KEEP@0 zuerst).
        let winner = survivors.min { a, b in
            let ab = a.candidate.metrics.encodedBytes
            let bb = b.candidate.metrics.encodedBytes
            if ab != bb { return ab < bb }
            return a.order < b.order
        }?.candidate ?? keep

        var pool = survivors.map(\.candidate)
        if !pool.contains(where: \.kind.isKeep) {
            pool.append(keep)
        }
        return Eligibility(pool: pool, winner: winner,
                           catastrophicRejection: catastrophicRejection,
                           rejections: rejections)
    }

    /// Fährt die §10.1–§10.6-Wahl. Deterministisch: Pareto-Frontier erhält
    /// die Generatorreihenfolge; Byte-Gleichstände sind durch das Pruning
    /// bereits qualitätsseitig aufgelöst (der messtechnisch bessere Kandidat
    /// dominiert – die lastabhängige Laufzeit ist aus der Dominanz
    /// entfernt, Suitenfund); verbleibende echte Gleichstände (Bytes UND
    /// Qualität) gehen an den früher erzeugten Kandidaten (KEEP@0 gewinnt
    /// damit jeden Gleichstand).
    static func select(from set: CandidateSet,
                       contentClass: ContentClass,
                       preset: QualityGatePreset) -> Selection {
        let eligibility = Self.eligibility(from: set, contentClass: contentClass,
                                           preset: preset)
        let gateClass = QualityGateClass(contentClass: contentClass)
        let keep = set.keepCandidate ?? set.candidates.first { $0.kind.isKeep }
            ?? set.candidates.first!
        let winner = eligibility.winner
        let rejections = eligibility.rejections
        let catastrophicRejection = eligibility.catastrophicRejection

        // Begründung (§4 Prinzip 12): WAS gewählt wurde und WAS abgelehnt ist.
        // Strukturelle KEEP-Gründe („zu klein“, „innerhalb der Zielauflösung“,
        // Capability …) bleiben erhalten – der Optimizer überschreibt sie nur,
        // wo ER entschieden hat.
        var reason: String
        if winner.kind.isKeep {
            if catastrophicRejection {
                reason = "kein lossy Candidate über dem Katastrophen-Floor (§10.3)"
            } else if rejections.isEmpty {
                reason = keep.reason
            } else {
                reason = "kein Candidate unter den Floors – KEEP bleibt"
            }
        } else {
            reason = "kleinster Candidate, der das \(preset.rawValue)/"
                + "\(gateClass.rawValue)-Gate hält"
        }
        if !rejections.isEmpty {
            let listed = rejections.prefix(4)
                .map { "\($0.candidateID.rawValue) (\($0.reason))" }
                .joined(separator: "; ")
            reason += "; verworfen: " + listed
            if rejections.count > listed.count {
                reason += "; +\(rejections.count - listed.count) weitere"
            }
        }

        // Rückstufungsleiter aus den ÜBRIGEN Kandidaten – verworfene sind
        // niemals lieferbar, auch nicht als Rollback-Stufe (V2-5). KEEP bleibt
        // als konservativste Stufe UNABHÄNGIG vom Pareto-Pruning enthalten
        // (§9.1: KEEP ist immer Candidate 0; ein kleinerer verlustfreier
        // Kandidat darf KEEP aus der Wahl drängen, aber nie aus der Leiter).
        return Selection(
            candidate: winner,
            reason: reason,
            rejections: rejections,
            catastrophicRejection: catastrophicRejection,
            candidateIDsBySafety: eligibility.candidateIDsBySafety)
    }

    /// Verletzte Metriken mit gemessenem Wert und Grenze – „floor p05TileSSIM
    /// 0.7400<0.80“ (Beispiel §10.6). ΔE ist eine Obergrenze („…>4.00“).
    private static func describe(violated: [QualityGateMetric],
                                 policy: QualityGatePolicy,
                                 measurement: QualityGateMeasurement) -> String {
        violated.map { metric -> String in
            let value: Double?
            let limit: Double?
            switch metric {
            case .globalSSIM:
                value = measurement.globalSSIM
                limit = policy.globalSSIM
            case .p05TileSSIM:
                value = measurement.p05TileSSIM
                limit = policy.p05TileSSIM
            case .edgeWeightedScore:
                value = measurement.edgeWeightedScore
                limit = policy.edgeWeightedScore
            case .textRegionScore:
                value = measurement.textRegionScore
                limit = policy.textRegionScore
            case .deltaE76:
                value = measurement.meanDeltaE76
                limit = policy.maxDeltaE76
            }
            let valueText = value.map { String(format: "%.4f", $0) } ?? "?"
            let limitText = limit.map { String(format: "%.2f", $0) } ?? "?"
            let comparator = metric == .deltaE76 ? ">" : "<"
            return "\(metric.rawValue) \(valueText)\(comparator)\(limitText)"
        }.joined(separator: ", ")
    }
}
