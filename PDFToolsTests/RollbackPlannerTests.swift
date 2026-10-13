import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan §11.3/§11.5/§11.6 – Rollback ist Re-Planning (V2-5).
///
/// Festgenagelt:
///   • Decision Provenance (§11.3): Seite → transformierte Ressource →
///     gewählter Candidate; KEEPs gelten NICHT als impliciert.
///   • Downgrade-Auswahl (§11.5): lossy → konservativ → lossless → KEEP,
///     Union mehrerer Seiten, Leiter-Erschöpfung → kein Eintrag.
///   • Override-Ausführung im Planner: erzwungene CandidateID greift;
///     nicht generierbar → nächste Leiter-Stufe; Kandidaten, die der
///     Optimizer verworfen hat, sind nicht rückstufbar (§11.4).
///   • §11.6-Rung: Findings ohne implicierte Ressourcen → Pass-Abschaltung
///     NUR bei dokumentiertem Verursacher.
///   • End-to-End: Fail-Case → Re-Plan öffnet das ORIGINAL → zweiter Versuch
///     erfolgreich, qaReplanCount == 1.
@Suite struct RollbackPlannerTests {

    // MARK: Plan-Fixtures (§11.3)

    /// Plan mit zwei transformierten Ressourcen (Seiten 4 und 7, 1-basiert
    /// hier über 0-basierte decision.pages=[3] bzw. [6]) und einer KEEP-
    /// Ressource, die NICHT impliciert werden darf.
    static func plan(fontPolicy: FontPolicy = .auto,
                     dedupPolicy: DedupPolicy = .auto) -> CompressionPlan {
        func decision(_ id: String, pages: [Int], selected: String,
                      ladder: [String]) -> ResourceDecision {
            ResourceDecision(
                resourceID: id,
                selectedCandidateID: CandidateID(selected),
                candidateIDsBySafety: ladder.map { CandidateID($0) },
                classification: .photo,
                features: nil,
                pages: pages,
                reason: "Test")
        }
        let jpegKlein = CompressionCandidate(
            id: CandidateID("jpeg-klein"), objectID: nil,
            kind: .jpeg(target: PixelSize(width: 100, height: 100), quality: 0.8,
                        backend: .mozjpeg, grayscale: false),
            metrics: CandidateMetrics(encodedBytes: 700, globalSSIM: 0.93,
                                      p05TileSSIM: 0.88, edgeScore: 0.9,
                                      textScore: nil, deltaE76: 2, psnr: nil,
                                      expectedRuntimeMs: 10,
                                      expectedPeakWorkingBytes: 0,
                                      compatibilityRisk: 0.1, semanticRisk: 0.05),
            isLossless: false, pages: [3], reason: "Test")
        let jpegGross = CompressionCandidate(
            id: CandidateID("jpeg-gross"), objectID: nil,
            kind: .jpeg(target: PixelSize(width: 100, height: 100), quality: 0.92,
                        backend: .mozjpeg, grayscale: false),
            metrics: CandidateMetrics(encodedBytes: 900, globalSSIM: 0.97,
                                      p05TileSSIM: 0.93, edgeScore: 0.94,
                                      textScore: nil, deltaE76: 1, psnr: nil,
                                      expectedRuntimeMs: 10,
                                      expectedPeakWorkingBytes: 0,
                                      compatibilityRisk: 0.1, semanticRisk: 0.05),
            isLossless: false, pages: [3], reason: "Test")
        let flate = CompressionCandidate(
            id: CandidateID("flate"), objectID: nil,
            kind: .flate(target: PixelSize(width: 100, height: 100),
                         grayscale: false, predictor: true),
            metrics: CandidateMetrics(encodedBytes: 1200, globalSSIM: nil,
                                      p05TileSSIM: nil, edgeScore: nil,
                                      textScore: nil, deltaE76: nil, psnr: nil,
                                      expectedRuntimeMs: 5,
                                      expectedPeakWorkingBytes: 0,
                                      compatibilityRisk: 0, semanticRisk: 0),
            isLossless: true, pages: [3], reason: "Test")
        let keep = CompressionCandidate(
            id: CandidateID("keep"), objectID: nil, kind: .keep,
            metrics: CandidateMetrics(encodedBytes: 5000, globalSSIM: nil,
                                      p05TileSSIM: nil, edgeScore: nil,
                                      textScore: nil, deltaE76: nil, psnr: nil,
                                      expectedRuntimeMs: 0,
                                      expectedPeakWorkingBytes: 0,
                                      compatibilityRisk: 0, semanticRisk: 0),
            isLossless: true, pages: [3], reason: "Test")

        let set1 = CandidateSet(resourceID: "1 0",
                                candidates: [keep, jpegGross, flate, jpegKlein])
        let set2 = CandidateSet(resourceID: "2 0", candidates: [keep, jpegKlein])
        let set3 = CandidateSet(resourceID: "3 0", candidates: [keep])

        return CompressionPlan(
            documentID: "test.pdf",
            actions: [],
            metadataPolicy: .preserve,
            linearizationPolicy: .none,
            dedupPolicy: dedupPolicy,
            fontPolicy: fontPolicy,
            fontSubsettingPolicy: .off,
            compatibilityPolicy: .modern,
            originalImageBytes: 0,
            originalDocumentBytes: 0,
            candidateSets: [set1, set2, set3],
            decisions: [
                // Ressource 1: Photo auf Seite 4 (0-basiert 3) und Seite 8
                decision("1 0", pages: [3, 7], selected: "jpeg-klein",
                         ladder: ["jpeg-klein", "jpeg-gross", "flate", "keep"]),
                // Ressource 2: auf Seite 7 (0-basiert 6), nur KEEP wählbar
                decision("2 0", pages: [6], selected: "keep", ladder: ["keep"]),
                // Ressource 3: KEEP-Entscheidung auf Seite 4 – nicht impliciert
                decision("3 0", pages: [3], selected: "keep", ladder: ["keep"]),
            ],
            goal: .balanced,
            traceVersion: 2)
    }

    static func textFinding(pages: [Int],
                            severity: ValidationFinding.Severity = .error)
        -> ValidationFinding {
        ValidationFinding(kind: .text, severity: severity, pages: pages,
                          message: "Seite \(pages) Textinhalt geändert")
    }

    // MARK: §11.3 Decision Provenance

    @Test func provenanceLieftTransformierteRessourcenJeSeite() {
        let plan = Self.plan()
        // Seite 4 (1-basiert): Ressource 1 (transformiert) + Ressource 3 (KEEP).
        #expect(plan.implicatedResources(pages: [4]) == ["1 0"])
        // Seite 8: ebenfalls Ressource 1.
        #expect(plan.implicatedResources(pages: [8]) == ["1 0"])
        // Seite 7: nur die KEEP-Ressource 2 → KEINE implicierten Ressourcen.
        #expect(plan.implicatedResources(pages: [7]).isEmpty)
        // Union über mehrere Seiten.
        #expect(plan.implicatedResources(pages: [4, 7, 8]) == ["1 0"])
    }

    @Test func decisionsByPageFührtKeineKeeps() {
        let byPage = Self.plan().decisionsByPage
        #expect(byPage[4]?["1 0"] == CandidateID("jpeg-klein"))
        #expect(byPage[8]?["1 0"] == CandidateID("jpeg-klein"))
        #expect(byPage[4]?["3 0"] == nil, "KEEP-Ressource gehört nicht in die Provenance")
        #expect(byPage[7]?["2 0"] == nil)
    }

    // MARK: §11.5 Downgrade-Auswahl

    @Test func downgradeWähltNächsteKonservativereStufe() {
        let plan = Self.plan()
        let downgrades = RollbackPlanner.downgrades(
            for: [Self.textFinding(pages: [4])], plan: plan)
        // Ressource 1: jpeg-klein → jpeg-gross (eine Stufe konservativer).
        #expect(downgrades == ["1 0": CandidateID("jpeg-gross")])
    }

    @Test func mehrereFindingsWerdenZurUnion() {
        let plan = Self.plan()
        let downgrades = RollbackPlanner.downgrades(
            for: [Self.textFinding(pages: [4]), Self.textFinding(pages: [8])],
            plan: plan)
        // Beide Findings implicieren dieselbe Ressource – die Union ist
        // EIN Eintrag mit derselben (konservativsten) Stufe.
        #expect(downgrades == ["1 0": CandidateID("jpeg-gross")])
    }

    @Test func leiterErschöpftErzeugtKeinenEintrag() {
        let plan = Self.plan()
        // Seite 7: Ressource 2 IST bereits KEEP – nicht rückstufbar.
        let downgrades = RollbackPlanner.downgrades(
            for: [Self.textFinding(pages: [7])], plan: plan)
        #expect(downgrades.isEmpty)
    }

    @Test func warningsLösenKeinenReplanAus() {
        let plan = Self.plan()
        let downgrades = RollbackPlanner.downgrades(
            for: [Self.textFinding(pages: [4], severity: .warning),
                  Self.textFinding(pages: [8], severity: .info)],
            plan: plan)
        #expect(downgrades.isEmpty,
                "Nur error/fatal sind blockierend (§11.5)")
    }

    @Test func konservativsteStufeGewinntDieUnion() {
        // Zwei Ressourcen auf derselben Seite, eine schon auf Stufe 2 der
        // Leiter → der nächste Schritt für beide ist deren jeweilige
        // nächste Stufe (keine Überspringen, §11.4).
        var plan = Self.plan()
        plan.decisions[0] = ResourceDecision(
            resourceID: "1 0",
            selectedCandidateID: CandidateID("jpeg-gross"),
            candidateIDsBySafety: [CandidateID("jpeg-klein"),
                                   CandidateID("jpeg-gross"),
                                   CandidateID("flate"),
                                   CandidateID("keep")],
            classification: .photo, features: nil, pages: [3, 7],
            reason: "Test")
        let downgrades = RollbackPlanner.downgrades(
            for: [Self.textFinding(pages: [4, 8])], plan: plan)
        #expect(downgrades == ["1 0": CandidateID("flate")])
    }

    @Test func safeLosslessEndstufeErzwingtVerlustfrei() {
        let plan = Self.plan()
        let overrides = RollbackPlanner.forcedLosslessOverrides(plan: plan)
        // Ressource 1: konservativste lossless Stufe VOR keep = flate.
        #expect(overrides.forcedCandidates["1 0"] == CandidateID("flate"))
        // KEEP-Entscheidungen sitzen bereits auf dem Leiter-Ende – sie
        // brauchen keinen Override und erhalten keinen.
        #expect(overrides.forcedCandidates["2 0"] == nil)
        #expect(overrides.forcedCandidates["3 0"] == nil)
    }

    // MARK: Zeitbudget (§11.5 Kostenkontrolle)

    @Test func zeitbudgetGrenztReplankette() {
        // Unter der Baseline×3: weitermachen.
        #expect(!RollbackPlanner.timeBudgetExceeded(elapsed: 10, baseline: 10))
        // Über Baseline×3: Schluss.
        #expect(RollbackPlanner.timeBudgetExceeded(elapsed: 31, baseline: 10))
        // Untergrenze 30 s: auch ein superschneller erster Lauf gibt dem
        // zweiten eine reale Chance.
        #expect(!RollbackPlanner.timeBudgetExceeded(elapsed: 29, baseline: 1))
        #expect(RollbackPlanner.timeBudgetExceeded(elapsed: 45, baseline: 1))
    }

    // MARK: §11.6 – Pass-Level-Rung

    @Test func passLevelRungWähltDokumentiertenVerursacher() {
        // Findings auf Seiten OHNE implicierte transformierte Ressourcen.
        let findings = [Self.textFinding(pages: [2])]
        var execution = CompressionExecutor.Result(
            outputURL: URL(fileURLWithPath: "/dev/null"), replacedImages: 0,
            skippedImages: 0, rejectedByBridge: [])
        execution.removedUnusedFonts = 1

        let overrides = RollbackPlanner.passLevelOverrides(
            for: findings, plan: Self.plan(), execution: execution)
        // Der Font-Pass lief und ist der dokumentierte Verursacher-Typ.
        #expect(overrides.fontPolicy == .off)
        #expect(overrides.forcedCandidates.isEmpty)
        #expect(overrides.dedupPolicy == nil)

        // Font-Pass stand schon aus → Dedup-Rung.
        execution.deduplicatedStreams = 4
        let second = RollbackPlanner.passLevelOverrides(
            for: findings, plan: Self.plan(fontPolicy: .off), execution: execution)
        #expect(second.dedupPolicy == .off)
        #expect(second.fontPolicy == nil)
    }

    @Test func passLevelRungOhneBelegGreiftNicht() {
        let plan = Self.plan()
        let execution = CompressionExecutor.Result(
            outputURL: URL(fileURLWithPath: "/dev/null"), replacedImages: 0,
            skippedImages: 0, rejectedByBridge: [])
        // Kein Pass lief → keine Bauch-Attribution.
        let overrides = RollbackPlanner.passLevelOverrides(
            for: [Self.textFinding(pages: [2])], plan: plan, execution: execution)
        #expect(overrides.isEmpty)
        // Findings MIT implicierten Ressourcen gehören in die
        // Ressourcen-Leiter, nicht in die Pass-Rung.
        let wrongRung = RollbackPlanner.passLevelOverrides(
            for: [Self.textFinding(pages: [4])], plan: plan, execution: execution)
        #expect(wrongRung.isEmpty)
    }

    // MARK: Override-Ausführung im Planner (§11.5)

    @Test func overrideErzwingtKeepImReplanLauf() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = CompressionOptions.smart
        options.featureFlags.candidateEngine = true

        let base = try CompressionPipeline.plan(inputURL: url, options: options)
        #expect(base.plan.traceVersion == 2)
        let decision = try #require(base.plan.decisions.first)
        let set = try #require(
            base.plan.candidateSets.first { $0.resourceID == decision.resourceID })
        let keepID = try #require(set.keepCandidate?.id)

        var overrides = DecisionOverrides()
        overrides.forcedCandidates[decision.resourceID] = keepID
        let replanned = try CompressionPipeline.plan(inputURL: url,
                                                     options: options,
                                                     overrides: overrides)
        let replanDecision = try #require(replanned.plan.decisions.first {
            $0.resourceID == decision.resourceID
        })
        #expect(replanDecision.selectedCandidateID == keepID,
                "Der Override griff nicht: \(replanDecision.selectedCandidateID)")
        #expect(replanDecision.candidateIDsBySafety == decision.candidateIDsBySafety,
                "Die Leiter bleibt unverändert erhalten")
        #expect(replanDecision.reason.contains("QA-Rollback"))
        // Die erzwungene Wahl ist im Plan als KEEP-Aktion sichtbar.
        let objectID = PDFObjectID(
            objectNumber: Int(decision.resourceID.split(separator: " ")[0]) ?? -1,
            generation: Int(decision.resourceID.split(separator: " ")[1]) ?? -1)
        #expect(replanned.plan.action(for: objectID)?.transformsImage == false)
    }

    @Test func overrideFälltZurNächstenLeiterStufe() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = CompressionOptions.smart
        options.featureFlags.candidateEngine = true

        let base = try CompressionPipeline.plan(inputURL: url, options: options)
        let decision = try #require(base.plan.decisions.first)
        let set = try #require(
            base.plan.candidateSets.first { $0.resourceID == decision.resourceID })
        let ladder = decision.candidateIDsBySafety
        let keepID = try #require(set.keepCandidate?.id)

        // (a) Erzwungener Kandidat, der im SET fehlt, aber in der Leiter
        //     steht → die nächste LIEFERBARE Stufe Richtung KEEP.
        //     Konstruktion: künstliche CandidateID vor der KEEP-Stufe.
        var customLadder = ladder
        if let keepIndex = ladder.firstIndex(of: keepID) {
            customLadder.insert(CandidateID("verworfen"), at: keepIndex)
        }
        let resolved = CompressionPlanner.resolveOverride(
            CandidateID("verworfen"), in: set, ladder: customLadder)
        // „verworfen" ist nirgends lieferbar → ganz konservativ: KEEP.
        #expect(resolved?.id == keepID)

        // (b) Normale Auflösung: ein echter Leiter-Eintrag gilt exakt.
        if ladder.count > 1 {
            let target = ladder[min(1, ladder.count - 1)]
            let direct = CompressionPlanner.resolveOverride(
                target, in: set, ladder: ladder)
            #expect(direct?.id == target)
        }
    }

    // MARK: End-to-End (§11.5): Fail → Re-Plan → Erfolg

    /// Künstlicher Fail-Case über den Validation-Seam (analog subsetGate):
    /// Lauf 1 scheitert an einem .text-Finding auf der Bildseite, Lauf 2
    /// (Re-Plan mit Override auf die nächste Leiter-Stufe) validiert
    /// regulär grün. Festgenagelt: qaReplanCount == 1, und der Re-Plan hat
    /// das ORIGINAL erneut geöffnet – der Output des zweiten Laufs trägt
    /// NICHT die aggressive JPEG-Ausgabe des ersten (PDFObjectID-Regel:
    /// kein In-place-Rollback).
    @Test(.hangGuard) func rollbackEndeZuEndeReplanErfolgreich() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = CompressionOptions.smart
        options.featureFlags.candidateEngine = true
        options.qaRollbackPolicy = .auto

        let compressor = Compressor()
        let fm = FileManager.default
        var validationRuns = 0
        var firstOutputBytes: Int64 = -1
        let firstCopy = fm.temporaryDirectory
            .appendingPathComponent("qa-rollback-first-\(UUID().uuidString).pdf")
        defer { try? fm.removeItem(at: firstCopy) }

        let result = try compressor.compress(
            inputURL: url,
            options: options,
            qaValidationHook: { output in
                validationRuns += 1
                if validationRuns == 1 {
                    // Ersten Output für den Vergleich sichern, dann Fail
                    // mit blockierendem .text-Finding auf der Bildseite.
                    try? fm.copyItem(at: output, to: firstCopy)
                    firstOutputBytes = Compressor.fileSize(of: output)
                    var report = PDFValidator.Report()
                    report.failures.append("Seite 1: Textinhalt geändert")
                    report.findings.append(ValidationFinding(
                        kind: .text, severity: .error, pages: [1],
                        message: "Seite 1: Textinhalt geändert"))
                    return report
                }
                // Re-Plan-Lauf: regulär validieren.
                return nil
            })

        #expect(validationRuns == 2,
                "Genau ein Re-Plan-Lauf erwartet, gemessen \(validationRuns)")
        #expect(result.qaReplanCount == 1)
        #expect(result.qaFallbackCount == 0)

        // PDFObjectID-Regel: Der zweite Lauf öffnete das Original und
        // fuhr die konservativere Stufe – sein Output ist NICHT der
        // aggressive Output des ersten Laufs (der erste war kleiner).
        let secondBytes = Compressor.fileSize(of: result.outputURL)
        #expect(firstOutputBytes > 0)
        #expect(secondBytes >= firstOutputBytes,
                "Re-Plan lief nicht konservativer: \(firstOutputBytes) → \(secondBytes)")
    }

    /// Ohne .auto (oder Legacy-Pfad) bleibt alles beim fail-closed-Verhalten:
    /// Der Hook-Fail wirft, kein Re-Plan läuft.
    @Test(.hangGuard) func ohneAutoPolitikKeinReplan() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = CompressionOptions.smart
        options.featureFlags.candidateEngine = true
        options.qaRollbackPolicy = .off   // Default: fail-closed

        let compressor = Compressor()
        var validationRuns = 0
        do {
            _ = try compressor.compress(
                inputURL: url,
                options: options,
                qaValidationHook: { _ in
                    validationRuns += 1
                    var report = PDFValidator.Report()
                    report.failures.append("Seite 1: Textinhalt geändert")
                    report.findings.append(ValidationFinding(
                        kind: .text, severity: .error, pages: [1],
                        message: "Seite 1: Textinhalt geändert"))
                    return report
                })
            Issue.record("Der Fail-Case musste werfen")
        } catch let error as PDFValidator.ValidationError {
            #expect(validationRuns == 1, "Kein Re-Plan bei .off")
            guard case .invalid(let failures) = error else {
                Issue.record("Falscher Fehlertyp")
                return
            }
            #expect(failures.contains { $0.contains("Seite 1") })
        }
    }

    /// V2-11 – der frühere „Legacy-Pfad ignoriert .auto“-Fall hat seinen
    /// Gegenstand verloren: Es gibt nur den Candidate-Pfad (§25). Fort-
    /// geschrieben: Die Kette hängt allein an `qaRollbackPolicy` – mit
    /// `.auto` fährt sie am Produktionspfad (Re-Plans sichtbar in den
    /// Validierungsläufen) und endet fail-closed, wenn der Fail nicht
    /// reparierbar ist.
    @Test(.hangGuard) func autoPolitikFährtDieKetteAmProduktionspfad() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = CompressionOptions.smart
        options.qaRollbackPolicy = .auto

        let compressor = Compressor()
        var validationRuns = 0
        do {
            _ = try compressor.compress(
                inputURL: url,
                options: options,
                qaValidationHook: { _ in
                    validationRuns += 1
                    var report = PDFValidator.Report()
                    report.failures.append("Seite 1: Textinhalt geändert")
                    report.findings.append(ValidationFinding(
                        kind: .text, severity: .error, pages: [1],
                        message: "Seite 1: Textinhalt geändert"))
                    return report
                })
            Issue.record("Der Fail-Case musste werfen")
        } catch {
            #expect(validationRuns > 1,
                    Comment(rawValue: "Mit .auto muss die Re-Plan-Kette "
                        + "laufen (Läufe: \(validationRuns))"))
        }
    }
}
