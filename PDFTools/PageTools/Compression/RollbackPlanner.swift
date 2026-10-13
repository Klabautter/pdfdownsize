import Foundation

// MARK: - Masterplan §11 – Structured QA und Reversible Rollback (V2-5)
//
// Drei Bausteine in einer Datei, weil sie eine Kette bilden:
//
//   §11.3 Decision Provenance – aus dem Plan ablesbar, welche transformierte
//        Ressource welche Seite berührt (page → resource → candidate).
//   §11.5 Rollback ist Re-Planning – Findings (error/fatal) erzeugen
//        DecisionOverrides; das ORIGINAL wird erneut geöffnet (PDFObjectID-
//        Regel: kein In-place-Rollback am geschriebenen Output), der Plan
//        entlang der Rückstufungsleiter (§11.4) konservativer gefahren.
//   §11.6 Failure Attribution – Findings mit Pass-Attribution verknüpfen;
//        der dokumentierte Verursacher-Pass steuert das Downgrade-Ziel.

// MARK: - §11.3 Decision Provenance

extension CompressionPlan {

    /// Seiten-Sicht der Entscheidungen: PDF-Seitennummer (1-basiert, wie
    /// `ValidationFinding.pages`) → Ressource → gewählter Candidate. Nur
    /// TRANSFORMIERTE Ressourcen stehen drin – KEEP-Entscheidungen tragen
    /// keine Schuld an einem QA-Fail und sind nicht rückstufbar.
    var decisionsByPage: [Int: [String: CandidateID]] {
        var out: [Int: [String: CandidateID]] = [:]
        for decision in decisions where Self.isTransformed(decision, sets: setsByID) {
            for pageIndex in decision.pages {
                out[pageIndex + 1, default: [:]][decision.resourceID] =
                    decision.selectedCandidateID
            }
        }
        return out
    }

    /// §11.3 – alle transformierten Ressourcen, die die genannten Seiten
    /// berühren. `pages` ist 1-basiert (Konvention der Findings); intern
    /// wird auf die 0-basierten `ResourceDecision.pages` abgebildet.
    func implicatedResources(pages: [Int]) -> [String] {
        guard !pages.isEmpty else { return [] }
        let wanted = Set(pages.map { $0 - 1 })
        return decisions
            .filter { !Set($0.pages).isDisjoint(with: wanted) }
            .filter { Self.isTransformed($0, sets: setsByID) }
            .map(\.resourceID)
    }

    // MARK: Privat

    private var setsByID: [String: CandidateSet] {
        Dictionary(uniqueKeysWithValues: candidateSets.map { ($0.resourceID, $0) })
    }

    /// Eine Entscheidung gilt als transformierend, wenn der gewählte
    /// Candidate NICHT der KEEP-Kandidat ihres Sets ist (§11.3: „implicated
    /// resources = alle transformierten Resources").
    private static func isTransformed(_ decision: ResourceDecision,
                                      sets: [String: CandidateSet]) -> Bool {
        guard let set = sets[decision.resourceID] else { return false }
        return set.keepCandidate?.id != decision.selectedCandidateID
    }
}

// MARK: - §11.5/§11.6 – DecisionOverrides

/// Erzwungene Entscheidungen eines Re-Plan-Laufs. Sie greifen in
/// `CompressionPlanner.planViaCandidates`: Die genannte CandidateID wird
/// FORCIERT (ist sie nicht mehr generierbar, die nächste Leiter-Stufe); die
/// Pass-Politiken dienen der §11.6-Rung für Findings ohne implicierte
/// transformierte Ressourcen.
struct DecisionOverrides: Equatable, Sendable {
    /// resourceID → erzwungene CandidateID (Stufe der Rückstufungsleiter).
    var forcedCandidates: [String: CandidateID] = [:]
    /// §11.6 – Pass-Abschaltungen, NUR wenn der dokumentierte Verursacher-
    /// Pass es nahelegt (siehe `RollbackPlanner.passLevelOverrides`).
    var fontPolicy: FontPolicy?
    var dedupPolicy: DedupPolicy?
    var bilevelPolicy: BilevelPolicy?
    /// Herkunft der Overrides – geht in die ResourceDecision.reason ein
    /// (§4 Prinzip 12). „QA-Rollback (§11.5)“ ist der V2-5-Standard; der
    /// Zielgrößen-Loop (V2-6, §12.6) setzt seine eigene Herkunft.
    var label: String = "QA-Rollback (§11.5)"

    var isEmpty: Bool {
        forcedCandidates.isEmpty && fontPolicy == nil && dedupPolicy == nil
            && bilevelPolicy == nil
    }
}

// MARK: - §11.5 Rollback-Planung

/// Leitet aus maschinenlesbaren Findings die Rückstufungen des nächsten
/// Re-Plan-Laufs her (§11.5) und treibt die §11.6-Rung für Findings, deren
/// Verursacher NICHT in einer Bildressource liegt.
enum RollbackPlanner {

    /// Max 2 Re-Plan-Versuche (§11.5) – danach: safe lossless plan bzw.
    /// Original (fail-closed wie bisher).
    static let maximumReplanAttempts = 2

    /// §11.5 Kostenkontrolle – das Gesamtzeitbudget für die Kette: das
    /// Vielfache der bisherigen Laufzeit, mit Untergrenze für schnelle
    /// Dokumente (deren zweiter Lauf sonst nie ins Budget passte).
    static let timeBudgetMultiplier = 3.0
    static let timeBudgetFloorSeconds: Double = 30

    /// Ist das Gesamtzeitbudget gerissen?
    /// `baseline` ist die Dauer des ersten Laufs (inkl. Validierung),
    /// `elapsed` die bisherige Gesamtzeit.
    static func timeBudgetExceeded(elapsed: Double, baseline: Double) -> Bool {
        elapsed > max(baseline * timeBudgetMultiplier, timeBudgetFloorSeconds)
    }

    // MARK: Downgrades aus Findings

    /// §11.5 – resourceID → erzwungene CandidateID für den nächsten Lauf.
    ///
    /// Für jede error/fatal-Finding-Seite werden die implicierten
    /// transformierten Ressourcen ermittelt; je Ressource die NÄCHSTE
    /// KONSERVATIVERE Stufe aus `candidateIDsBySafety` gewählt (lossy →
    /// konservativ → lossless → KEEP). Mehrere Findings → Union, wobei die
    /// KONSERVATIVSTE Stufe gewinnt. Nicht rückstufbar (Leiter erschöpft)
    /// heißt: kein Eintrag – der Aufrufer setzt dann keine Override.
    ///
    /// Kein Blind-Replan: Ohne Findings mit Seiten und ohne implicierte
    /// transformierte Ressourcen bleibt das Ergebnis leer.
    static func downgrades(for findings: [ValidationFinding],
                           plan: CompressionPlan) -> [String: CandidateID] {
        let blocking = findings.filter { $0.severity.triggersRollback }
        guard !blocking.isEmpty else { return [:] }
        let pages = Array(Set(blocking.flatMap(\.pages))).sorted()
        let resources = plan.implicatedResources(pages: pages)
        guard !resources.isEmpty else { return [:] }

        var result: [String: CandidateID] = [:]
        for resourceID in resources {
            guard let decision = plan.decisions.first(where: {
                $0.resourceID == resourceID
            }) else { continue }
            if let step = nextConservativeStep(of: decision) {
                result[resourceID] = step
            }
        }
        return result
    }

    /// Die nächste konservativere Stufe einer Entscheidung. Union-Regel:
    /// Ist bereits eine (aus einem anderen Finding stammende) Stufe
    /// eingetragen, gewinnt die konservativere.
    static func nextConservativeStep(of decision: ResourceDecision) -> CandidateID? {
        guard let index = decision.candidateIDsBySafety.firstIndex(
            of: decision.selectedCandidateID) else {
            // Unbekannter Stand (z. B. Override-Lauf): ganz konservativ
            // zurückstufen heißt KEEP – die letzte Stufe der Leiter.
            return decision.candidateIDsBySafety.last
        }
        guard index + 1 < decision.candidateIDsBySafety.count else {
            return nil   // Leiter erschöpft: selected IST bereits KEEP
        }
        return decision.candidateIDsBySafety[index + 1]
    }

    /// §11.5 Endstufe – safe lossless plan: JEDE transformierte Ressource
    /// wird auf ihre konservativste VERLUSTFREIE Stufe gesetzt (oder KEEP,
    /// wenn die Leiter keine lossless Stufe zwischen selected und KEEP hat).
    static func forcedLosslessOverrides(plan: CompressionPlan) -> DecisionOverrides {
        var overrides = DecisionOverrides()
        let sets = Dictionary(uniqueKeysWithValues:
            plan.candidateSets.map { ($0.resourceID, $0) })
        for decision in plan.decisions {
            guard let set = sets[decision.resourceID],
                  set.keepCandidate?.id != decision.selectedCandidateID else {
                continue   // KEEP-Entscheidungen bleiben unangetastet
            }
            let byID = Dictionary(uniqueKeysWithValues:
                set.candidates.map { ($0.id, $0) })
            var best: CandidateID?
            if let index = decision.candidateIDsBySafety.firstIndex(
                of: decision.selectedCandidateID) {
                for step in decision.candidateIDsBySafety[(index + 1)...] {
                    guard let candidate = byID[step] else { continue }
                    if candidate.kind.isKeep { break }
                    if candidate.isLossless { best = step }
                }
            }
            // Ohne lossless Stufe bleibt nur KEEP.
            overrides.forcedCandidates[decision.resourceID] =
                best ?? set.keepCandidate?.id ?? decision.selectedCandidateID
        }
        return overrides
    }

    // MARK: §11.6 – Pass-Level-Downgrade (Rung der Leiter)

    /// FALL „Findings ohne implicierte transformierte Ressourcen“: Der
    /// Verursacher ist kein Bildkandidat, sondern ein Struktur-Pass. Die
    /// Leiter dieser Rung folgt der dokumentierten Attribution (V2-1:
    /// Font-GC-Scanner; Dedup; Bilevel) – ein Pass wird nur abgewählt, wenn
    /// seine Pass-Attribution im Lauf tatsächlich aktiv war UND die Politik
    /// ihn nicht schon aus hatte. Für statab_2012 ist diese Rung seit dem
    /// Scanner-Fix überflüssig; sie bleibt als letzte Stufe bestehen.
    ///
    /// `execution` ist das Executor-Result des GESCHEITERTEN Laufs (Quelle
    /// der Pass-Statistik); nil heißt: keine Attribution verfügbar → keine
    /// Pass-Abschaltung aus dem Bauch heraus.
    static func passLevelOverrides(for findings: [ValidationFinding],
                                   plan: CompressionPlan,
                                   execution: CompressionExecutor.Result?)
        -> DecisionOverrides {
        var overrides = DecisionOverrides()
        guard let execution,
              !findings.filter({ $0.severity.triggersRollback }).isEmpty else {
            return overrides
        }
        let pages = Array(Set(findings.flatMap(\.pages)))
        guard plan.implicatedResources(pages: pages).isEmpty else {
            return overrides   // implicierte Ressourcen → Ressourcen-Downgrade
        }

        // 1. Font-Pass – der dokumentierte Verursacher des statab-Falls.
        if plan.fontPolicy != .off,
           execution.removedUnusedFonts > 0 || execution.deduplicatedFontRefs > 0 {
            overrides.fontPolicy = .off
            return overrides
        }
        // 2. Content-Dedup.
        if plan.dedupPolicy != .off,
           execution.deduplicatedStreams > 0 || execution.deduplicatedObjects > 0 {
            overrides.dedupPolicy = .off
            return overrides
        }
        // 3. Bilevel-Race (verlustfrei, aber eingreifend).
        if plan.actions.contains(where: {
            if case .ccittG4 = $0 { return true }
            if case .jbig2 = $0 { return true }
            return false
        }) || execution.bytesSavedBilevel > 0 {
            overrides.bilevelPolicy = .keep
        }
        return overrides
    }
}

// MARK: - §11.6 Failure Attribution

/// Verknüpft maschinenlesbare Findings mit Pass-Attribution und Plan-Kontext
/// – Zeilen fürs Log/Report (§11.6). Reine Ableitung aus bestehenden Daten:
/// Plan (Decision Provenance §11.3) und Executor-Result (bytesSaved*).
enum CompressionQA {

    static func explain(findings: [ValidationFinding],
                        plan: CompressionPlan,
                        result: CompressionExecutor.Result) -> [String] {
        var lines: [String] = []
        let blocking = findings.filter { $0.severity.triggersRollback }
        if blocking.isEmpty { return lines }

        lines.append("Failure-Attribution (§11.6): \(blocking.count) blockierende "
            + "Findings")
        let pages = Array(Set(blocking.flatMap(\.pages))).sorted()
        let implicated = plan.implicatedResources(pages: pages)

        for finding in blocking {
            let pageText = finding.pages.isEmpty
                ? "Dokumentebene" : "Seiten \(finding.pages.map(String.init).joined(separator: ", "))"
            lines.append("  FINDING \(finding.kind.rawValue)/\(finding.severity.rawValue) "
                + "\(pageText): \(finding.message)")
        }

        if implicated.isEmpty {
            lines.append("  implicierte transformierte Ressourcen: keine – "
                + "Pass-level-Ursache wahrscheinlich (§11.6-Rung)")
        } else {
            let byPage = plan.decisionsByPage
            for resourceID in implicated {
                let affectedPages = byPage
                    .filter { $0.value[resourceID] != nil }
                    .map(\.key)
                    .sorted()
                let candidate = byPage
                    .compactMap { $0.value[resourceID] }
                    .first?.rawValue ?? "?"
                lines.append("  impliciert: \(resourceID) → \(candidate) "
                    + "(Seiten \(affectedPages.map(String.init).joined(separator: ", ")))")
            }
        }

        // Pass-Attribution (§7.6) – welche lossy Pässe liefen, und die
        // Struktur-Pass-Statistik des Laufs.
        lines.append("  lossy Pässe (estimated bytes): jpeg=\(result.bytesSavedJPEG) "
            + "cmyk=\(result.bytesSavedCMYK) bilevel=\(result.bytesSavedBilevel)")
        lines.append("  verlustfreie Pässe: repack=\(result.bytesSavedJPEGRepack) "
            + "lossless=\(result.bytesSavedLosslessResize) indexed=\(result.bytesSavedIndexed)")
        lines.append("  Struktur-Pässe: dedup=\(result.bytesSavedDedup) "
            + "(streams=\(result.deduplicatedStreams), objs=\(result.deduplicatedObjects)) "
            + "fonts=\(result.bytesSavedFonts) "
            + "(dedup=\(result.deduplicatedFontRefs), gc=\(result.removedUnusedFonts)) "
            + "subset=\(result.bytesSavedSelectiveFontSubset) "
            + "structure=\(result.bytesSavedStructure)")
        return lines
    }
}
