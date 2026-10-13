import Foundation
import PDFKit

// MARK: - Masterplan §14 – Born-Digital Resource Optimizer V2 (V2-8)
//
// Font-Subsetting als Candidate, nicht globaler Spezialpass (§14.1):
//
//   • Provision (Planungszeit, NUR im candidateEngine-Pfad, §25): Die
//     Bridge plant je Font TROCKEN (Whitelist + Benutzung + hb-subset,
//     keine Mutation) und meldet die ehrliche Ersparnis. Daraus entstehen
//     CandidateSets {fontKeep, fontSubset} mit der Activation Policy
//     (§14.3) – ohne messbare Ersparnis kein Eingriff („keine 2-KB-
//     Ersparnis gegen erhöhtes Risiko“).
//   • Ausführung (Executor): subsettet NUR die gewählten Fonts
//     (pdfcore_font_subset_selected) und prüft je Font (§14.4): Text-
//     Fingerprints dokumentweit, Never-Grow und Render-Stichprobe der
//     betroffenen Seiten. Ein scheiternder Font rollt ALLEIN auf keep
//     zurück – der frühere globale Snapshot-Rollback-Pass ist seit dem
//     V2-Cutover (V2-11) entfernt, dieser Pfad ist der EINZIGE.

enum FontOptimizer {

    // MARK: §14.3 – Activation Policy
    //
    // Subsetting nur, wenn die geschätzte Ersparnis BEIDE Schwellen hält
    // („max(64 KB absolut, 30 % relativ)“):
    //
    //   • 64 KB absolut: Darunter ist der Eingriff das Risiko nicht wert –
    //     ein 30-KB-Gewinn rechtfertigt keinen neu geschriebenen Font.
    //     (Die historische Schwelle „keine 2-KB-Ersparnis“ aus §14.3 wird
    //     bewusst nach oben gezogen: 2 KB sind im Korpus Rauschen, und der
    //     selektive Pfad ersetzt das globale Gate durch einen je-Font-
    //     Test – die Anforderung an den Einzelgewinn wächst.)
    //   • 30 % relativ: Gegenüber dem dekodierten Programm des Fonts. Ein
    //     Subset, das nur 5 % eines riesigen Programms streicht, kauft
    //     nichts, was die PDF-Struktur nicht auch ohne den Eingriff
    //     hergäbe – und es bleibt mehr Glyphenabdeckung für Seiten übrig,
    //     deren Nutzung der Scanner nicht gesehen hat.
    static let minimumAbsoluteSavingBytes = 64 * 1024
    static let minimumRelativeSavingFraction = 0.30

    /// §14.4 – Umfang der Render-Stichprobe je Font: höchstens drei Seiten,
    /// deterministisch (erste, mittlere, letzte der betroffenen Seiten).
    /// Mehr Seiten kosten Ausführungszeit pro Font; der Text-Fingerprint-
    /// Vergleich läuft OHNE diese Kappe dokumentweit.
    static let renderSampleMaximumPages = 3

    // MARK: Provision (Planung)

    /// Ein Font-Kandidat für die Planung – Ergebnis der Trockenplanung der
    /// Bridge, gefiltert auf subsetting-sichere Fonts (§14.1-Klassifikation).
    struct Provision: Sendable {
        let resourceID: String
        let objectID: PDFObjectID
        /// Seiten (0-basiert), von denen aus der Font erreichbar ist.
        let pages: [Int]
        /// Ehrliche Schätzung der Trockenplanung (hb-subset gelaufen).
        let estimatedSaving: Int
        /// Dekodierte FontFile2-Größe – Basis der relativen Schwelle.
        let originalProgramBytes: Int
        /// false = subsettable, aber Aktivierungspolitik (§14.3) verfehlt.
        /// Der Planner zeichnet die Entscheidung trotzdem nach (Trace).
        let activationPassed: Bool
    }

    /// Aktivierungspolitik §14.3: Ersparnis ≥ max(64 KB absolut, 30 % relativ).
    static func passesActivation(estimatedSaving: Int,
                                 originalProgramBytes: Int) -> Bool {
        guard estimatedSaving >= minimumAbsoluteSavingBytes else { return false }
        let relativeThreshold = Double(originalProgramBytes)
            * minimumRelativeSavingFraction
        return Double(estimatedSaving) >= relativeThreshold
    }

    /// Holt die subsetting-sicheren Font-Kandidaten. NUR bei Flags
    /// candidateEngine + selectiveFontSubset (§25) und aktiver Font-Politik
    /// – die Produktion bleibt byteidentisch.
    static func provision(document: PDFCoreDocument,
                          options: CompressionOptions,
                          isCancelled: (() -> Bool)? = nil) throws -> [Provision] {
        guard options.featureFlags.candidateEngine,
              options.featureFlags.selectiveFontSubset,
              options.fontPolicy != .off else { return [] }
        let candidates = (try? document.fontSubsetCandidates()) ?? []
        var provisions: [Provision] = []
        for candidate in candidates {
            if let isCancelled, isCancelled() { throw CancellationError() }
            guard candidate.subsettable else { continue }
            let passed = passesActivation(
                estimatedSaving: candidate.estimatedBytesSaved,
                originalProgramBytes: candidate.originalProgramBytes)
            provisions.append(Provision(
                resourceID: CandidateSet.resourceID(for: candidate.objectID),
                objectID: candidate.objectID,
                pages: candidate.pages,
                estimatedSaving: candidate.estimatedBytesSaved,
                originalProgramBytes: candidate.originalProgramBytes,
                activationPassed: passed))
        }
        return provisions
    }

    // MARK: CandidateSet {fontKeep, fontSubset}

    /// Baut den Kandidatenraum EINES Fonts (§14.1): fontKeep immer
    /// (KEEP@0-Analogon), fontSubset nur bei bestandener Aktivierungspolitik.
    /// Verlustfreie Kandidaten ohne Messung – die Qualitätssicherung ist die
    /// je-Font-QA der Ausführung (§14.4), nicht ein Bildgate.
    static func candidateSet(for provision: Provision) -> CandidateSet {
        let keepID = CandidateID("fontKeep-\(provision.objectID.objectNumber)"
                                 + "-\(provision.objectID.generation)")
        let keep = CompressionCandidate(
            id: keepID,
            objectID: provision.objectID,
            kind: .fontKeep,
            metrics: CandidateMetrics(
                encodedBytes: max(0, provision.originalProgramBytes),
                globalSSIM: nil, p05TileSSIM: nil, edgeScore: nil,
                textScore: nil, deltaE76: nil, psnr: nil,
                expectedRuntimeMs: 0, expectedPeakWorkingBytes: 0,
                compatibilityRisk: 0, semanticRisk: 0),
            isLossless: true,
            pages: provision.pages,
            reason: provision.activationPassed
                ? "Font bleibt unangetastet (Rückstufungsstufe des Subsets)"
                : "Font bleibt stehen: Aktivierungspolitik §14.3 verfehlt "
                    + "(Ersparnis \(provision.estimatedSaving) Bytes "
                    + "< max(\(minimumAbsoluteSavingBytes) absolut, "
                    + "\(Int(minimumRelativeSavingFraction * 100)) % relativ))")

        var candidates = [keep]
        if provision.activationPassed {
            let subsetID = CandidateID(
                "fontSubset-\(provision.objectID.objectNumber)"
                + "-\(provision.objectID.generation)")
            let subsetBytes = max(0, provision.originalProgramBytes
                                      - provision.estimatedSaving)
            candidates.append(CompressionCandidate(
                id: subsetID,
                objectID: provision.objectID,
                kind: .fontSubset,
                metrics: CandidateMetrics(
                    encodedBytes: subsetBytes,
                    globalSSIM: nil, p05TileSSIM: nil, edgeScore: nil,
                    textScore: nil, deltaE76: nil, psnr: nil,
                    expectedRuntimeMs: 0, expectedPeakWorkingBytes: 0,
                    // Heuristik (§10.1-Caps): Fontprogramme werden neu
                    // geschrieben – Restrisiko, das die je-Font-QA abfängt.
                    compatibilityRisk: 0.1, semanticRisk: 0.05),
                isLossless: true,
                pages: provision.pages,
                reason: "selektives Font-Subsetting: Aktivierungspolitik "
                    + "§14.3 erfüllt (Ersparnis \(provision.estimatedSaving) "
                    + "Bytes, Trockenplanung = Ausführung)"))
        }
        return CandidateSet(
            resourceID: provision.resourceID, candidates: candidates)
    }

    /// ID des Subset-Kandidaten eines Font-Sets (nil = Aktivierung verfehlt).
    static func subsetCandidateID(of set: CandidateSet) -> CandidateID? {
        set.candidates.first {
            if case .fontSubset = $0.kind { return true }
            return false
        }?.id
    }

    /// ID des Keep-Kandidaten eines Font-Sets.
    static func keepCandidateID(of set: CandidateSet) -> CandidateID? {
        set.keepCandidate?.id
    }

    // MARK: §14.4 – Ausführung mit je-Font-QA

    struct Decision: Equatable, Codable, Sendable {
        let objectID: PDFObjectID
        let pages: [Int]
        let estimatedSaving: Int
    }

    /// Verlauf EINES Fonts – Quelle für Trace und Executor-Result.
    enum FontResult: Sendable {
        /// Subset ausgeführt, je-Font-QA bestanden.
        case subsetted
        /// Der C-Kern hat den Font konservativ behalten (kein Eingriff).
        case refused
        /// Die je-Font-QA scheiterte – NUR dieser Font wurde zurückgerollt.
        case rolledBack
    }

    struct FontOutcome: Sendable {
        let objectID: PDFObjectID
        let pages: [Int]
        let result: FontResult
        let estimatedSavedBytes: Int
    }

    struct Outcome {
        /// Das Ergebnis-Handle: nach Rollbacks der Stand des letzten
        /// Checkpoints (ohne die zurückgerollten Fonts).
        var document: PDFCoreDocument
        /// Fonts, die das QA durchlaufen haben und im Ergebnis stecken.
        var subsetted: Int = 0
        /// Fonts, die der C-Kern konservativ behalten hat (kein Eingriff).
        var refused: Int = 0
        /// Fonts, deren QA scheiterte und die NUR SELBST zurückgerollt
        /// wurden – die zuvor akzeptierten Fonts bleiben (§14.4).
        var rolledBack: Int = 0
        var estimatedBytesSaved: Int = 0
        /// Verlauf je Font (Reihenfolge der Entscheidungen).
        var perFont: [FontOutcome] = []
    }

    /// Subsettet die genannten Fonts EINZELN und prüft je Font über das
    /// QA-Seam. Checkpoint-Mechanik: Der Stand nach jedem AKZEPTIERTEN Font
    /// wird gesichert; ein scheiternder Font kehrt zum letzten Checkpoint
    /// zurück (nur dieser Font ist weg – §14.4 „nur diesen Font keep“).
    ///
    /// `verify(preURL, candidateURL, samplePages)` ist der Testsam für die
    /// QA; der Default ist `fontQAPasses`.
    static func applySelectiveSubsetting(
        document: PDFCoreDocument,
        decisions: [Decision],
        verify: (URL, URL, [Int]) -> Bool = FontOptimizer.fontQAPasses
    ) throws -> Outcome {
        var outcome = Outcome(document: document)
        guard !decisions.isEmpty else { return outcome }

        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
        // preURL ist zugleich rollender Checkpoint: er trägt nach jedem
        // akzeptierten Font den Stand MIT diesem Font.
        let checkpointURL = temporary.appendingPathComponent(
            "pdfcore-selective-font-checkpoint-\(UUID().uuidString).pdf")
        let candidateURL = temporary.appendingPathComponent(
            "pdfcore-selective-font-candidate-\(UUID().uuidString).pdf")
        defer {
            try? fileManager.removeItem(at: checkpointURL)
            try? fileManager.removeItem(at: candidateURL)
        }

        var active = document
        try active.save(to: checkpointURL)

        for decision in decisions {
            // 1. EIN Font über die Bridge. Refusal (konservativ behalten)
            //    ist kein Fehler – es gab keine Mutation, nichts zu testen.
            var subsetStats = PDFCoreFontSubsetStats(
                subsettedFonts: 0, keptFonts: 0, estimatedBytesSaved: 0)
            do {
                subsetStats = try active.subsetSelectedFonts([decision.objectID])
                guard subsetStats.subsettedFonts > 0 else {
                    outcome.refused += 1
                    outcome.perFont.append(FontOutcome(
                        objectID: decision.objectID, pages: decision.pages,
                        result: .refused, estimatedSavedBytes: 0))
                    continue
                }
            } catch {
                // Strukturprüfung im Kern gescheitert (nach Mutation) –
                // Handle verwerfen, zum Checkpoint zurück.
                active = try PDFCoreDocument(path: checkpointURL.path)
                outcome.document = active
                outcome.rolledBack += 1
                outcome.perFont.append(FontOutcome(
                    objectID: decision.objectID, pages: decision.pages,
                    result: .rolledBack, estimatedSavedBytes: 0))
                continue
            }

            // 2. Kandidat schreiben und je-Font-QA fahren.
            try active.save(to: candidateURL)
            let samplePages = renderSamplePages(decision.pages)
            if verify(checkpointURL, candidateURL, samplePages) {
                // Akzeptiert: Checkpoint rollt vor (beinhaltet diesen Font).
                try active.save(to: checkpointURL)
                outcome.subsetted += 1
                outcome.estimatedBytesSaved
                    += subsetStats.estimatedBytesSaved
                outcome.perFont.append(FontOutcome(
                    objectID: decision.objectID, pages: decision.pages,
                    result: .subsetted,
                    estimatedSavedBytes: subsetStats.estimatedBytesSaved))
            } else {
                // NUR dieser Font rollt zurück – die vorherigen bleiben.
                active = try PDFCoreDocument(path: checkpointURL.path)
                outcome.document = active
                outcome.rolledBack += 1
                outcome.perFont.append(FontOutcome(
                    objectID: decision.objectID, pages: decision.pages,
                    result: .rolledBack, estimatedSavedBytes: 0))
            }
        }
        outcome.document = active
        return outcome
    }

    /// §14.4 – Die je-Font-QA: Text-Fingerprints dokumentweit seitenweise,
    /// Never-Grow gegen den Stand davor, und eine Render-Stichprobe der
    /// betroffenen Seiten (kleinster gemeinsamer Nenner: jede geprüfte
    /// Seite muss pixelgleich bleiben).
    static func fontQAPasses(_ preURL: URL, _ candidateURL: URL,
                             _ samplePages: [Int]) -> Bool {
        guard let before = try? PDFSemanticSnapshot.capture(preURL),
              let after = try? PDFSemanticSnapshot.capture(candidateURL),
              before.pageCount == after.pageCount,
              before.pages.count == after.pages.count else {
            return false
        }
        for (b, a) in zip(before.pages, after.pages) {
            if b.textFingerprint != a.textFingerprint { return false }
            if b.textCharacterCount != a.textCharacterCount { return false }
        }
        let preBytes = Int(Compressor.fileSize(of: preURL))
        let candidateBytes = Int(Compressor.fileSize(of: candidateURL))
        guard candidateBytes > 0, candidateBytes <= preBytes else {
            return false
        }
        guard !samplePages.isEmpty else { return true }
        let mapping = Dictionary(uniqueKeysWithValues:
            samplePages.map { ($0, $0) })
        guard let comparisons = try? RenderDifferential.compare(
            sourceURL: preURL, outputURL: candidateURL,
            pageMapping: mapping),
              comparisons.count == samplePages.count,
              comparisons.allSatisfy({ $0.changedAreaRatio == 0 }) else {
            return false
        }
        return true
    }

    /// Deterministische Stichprobe: erste, mittlere, letzte betroffene
    /// Seite (bis zu `renderSampleMaximumPages`).
    static func renderSamplePages(_ pages: [Int],
                                  cap: Int = renderSampleMaximumPages)
        -> [Int] {
        let sorted = Array(Set(pages)).sorted()
        guard sorted.count > cap else { return sorted }
        let mid = sorted.count / 2
        return Array(Set([sorted[0], sorted[mid], sorted[sorted.count - 1]]))
            .sorted()
    }
}
