import Foundation
import CoreGraphics
import ImageIO

/// Masterplan Schritt 5 / §9 – DIE Smart-Compression-Decision-Engine.
///
/// Sie ist bewusst backend-frei: Sie kennt weder PDFKit noch qpdf, sondern nur
/// `PDFImageResource` (was ist das Bild?) und eine `ImagePixelSource` (gib mir
/// die Pixel). Dadurch trifft dieselbe Logik dieselben Entscheidungen,
/// unabhängig davon, welcher PDF-Layer darunter liegt (Finding 10).
///
/// Seit V2-11 ist die Entscheidung ein Kandidatenraum: Pro Ressource
/// entsteht ein CandidateSet (§9), ein Optimizer wählt (§10), die Wahl wird
/// in die bestehenden ImageCompressionActions übersetzt. Der frühere
/// Einzelbild-Entscheidungscode (decide + planJPEG-Leiter) ist nach der
/// V2-Zertifizierung entfernt (§25).
protocol ImagePixelSource {
    /// Dekodierte Pixel eines Bildobjekts. `nil` heißt: nicht dekodierbar –
    /// dann bleibt das Bild unangetastet, es wird KEIN Ersatz erfunden.
    func decodedImage(for resource: PDFImageResource) -> CGImage?

    /// Gepackte 1-bit-Pixel eines Bildobjekts in der Bilevel-Pixelfolge
    /// (Phase 2b, Bit 1 = schwarz). `nil` heißt: nicht lieferbar.
    func bilevelBuffer(for resource: PDFImageResource) -> BilevelBuffer?

    /// Phase 4b – Dekodieren mit Zielgröße. Quellen mit eigenem
    /// Reduktionsweg (JPX cp_reduce) dekodieren dann direkt auf ein
    /// gröberes Raster; der Default liefert die vollen Pixel. Planung und
    /// Ausführung rufen mit DEMSELBEN Ziel an, damit die Pixel deterministisch
    /// bleiben.
    func decodedImage(for resource: PDFImageResource, target: PixelSize) -> CGImage?

    /// Phase 6C – rohe Stream-Bytes eines Bildobjekts (bei DCTDecode also
    /// JPEG). Die CMYK-Race braucht sie, um die Größenbarriere des 6b-
    /// Repacks zu bestimmen. `nil` heißt: keine Rohbytes – die Barriere
    /// fällt dann auf die gemeldete Originalgröße zurück.
    func rawImageData(for resource: PDFImageResource) -> Data?

    /// Dekodierte Stream-Bytes (Flate/LZW aufgelöst, inkl. Predictor) – für
    /// die KEEP-Bewertung: Der finale Writer komprimiert behaltene Flate-
    /// Streams neu. `nil` = nicht lieferbar (Barriere = Originalgröße).
    func decodedStreamData(for resource: PDFImageResource) -> Data?

    /// V2-Maps-Perf – kanonische Dekodier-Ebene für den Raster-Cache
    /// (PixelDecodeCache): Ebene 0 = volle Dekodierung; Quellen mit eigenem
    /// Reduktionsweg (JPX cp_reduce) nennen die Reduktionsstufe. Der Wert
    /// MUSS genau die Dekodierungsvariante bestimmen: Zwei Ziele mit derselben
    /// Ebene liefern dasselbe Raster, unterschiedliche Ebenen unterschiedliche
    /// Raster. Der Cache dedupliziert darüber und bleibt damit byteidentisch.
    ///
    /// BEWUSST Protocol-Requirement (nicht nur Extension-Default): Der
    /// Generator hält die Quelle als `ImagePixelSource` – nur ein Requirement
    /// wird dynamisch an die konkrete Quelle dispatcht; eine bloße
    /// Extension-Methode würde stillschweigend immer den Default liefern.
    func decodeLevel(for resource: PDFImageResource, target: PixelSize) -> Int
}

extension ImagePixelSource {
    func decodedImage(for resource: PDFImageResource, target: PixelSize) -> CGImage? {
        decodedImage(for: resource)
    }

    func rawImageData(for resource: PDFImageResource) -> Data? { nil }

    func decodedStreamData(for resource: PDFImageResource) -> Data? { nil }

    /// V2-Maps-Perf – kanonische Dekodier-Ebene für den Raster-Cache
    /// (PixelDecodeCache): Ebene 0 = volle Dekodierung; Quellen mit eigenem
    /// Reduktionsweg (JPX cp_reduce) nennen die Reduktionsstufe. Der Wert
    /// MUSS genau die Dekodierungsvariante bestimmen: Zwei Ziele mit derselben
    /// Ebene liefern dasselbe Raster, unterschiedliche Ebenen unterschiedliche
    /// Raster. Der Cache dedupliziert darüber und bleibt damit byteidentisch.
    func decodeLevel(for resource: PDFImageResource, target: PixelSize) -> Int { 0 }
}

enum CompressionPlanner {

    /// Kleinste Kantenlänge, ab der sich eine Transformation lohnt.
    /// Darunter dominiert der Container-Overhead den Bildinhalt.
    static let minimumTransformableEdge = 96

    /// Obergrenze gegen Speicherexplosion beim Dekodieren.
    static let maximumDecodablePixels = 36_000_000

    struct Result {
        let plan: CompressionPlan
        let artifacts: CompressionPlanArtifacts
        /// Klassifikation je Bildressource (§8) – im Candidate-Pfad immer
        /// gefüllt; der Trace und die ResourceDecisions lesen sie daraus.
        var classifications: [PDFObjectID: ResourceClassification] = [:]
    }

    /// Erzeugt den Plan. Ein Aufruf, ein Plan – Estimator und Executor
    /// bekommen anschließend denselben.
    ///
    /// Phase V2-1 (§7.3): Mit `stageTimer` trennt die Planung grob Analyse-
    /// (Dekodieren/Klassifizieren) von Kandidatenzeit (Kodierläufe) –
    /// vorläufige Zuschreibung, siehe StageTimings.
    ///
    /// Phase V2-3a (§9, §5.8 Phase A): Erzeugt pro Bildressource ein
    /// CandidateSet, wählt daraus lokal und übersetzt die Wahl in dieselben
    /// ImageCompressionActions. Executor und Estimator laufen unverändert
    /// weiter – der Unterschied liegt allein in der HERLEITUNG der Aktionen.
    ///
    /// Kandidaten-Payloads liegen im CandidateStore (§9.12, RAM/Spill/
    /// metadata-only); die Payload des GEWÄHLTEN Kandidaten wandert in die
    /// bestehenden Planartefakte. Ist sie regenerierbar (metadata-only),
    /// kodiert der Executor deterministisch aus den Planparametern neu.
    ///
    /// Phase V2-5 (§11.5): `overrides` tragen die erzwungenen Entscheidungen
    /// eines Re-Plan-Laufs (QA-Rollback). Sie greifen auf der GEWÄHLTEN
    /// Entscheidung (Rückstufungsleiter, §5.7).
    ///
    /// Phase V2-6 (§12.6): `store` macht die Payloads WIEDERVERWENDBAR über
    /// Läufe innerhalb EINER compress()-Operation (Actual-Size-Feedback);
    /// nil heißt: eigener Store, eigener Lifecycle (Verhalten wie bisher).
    static func plan(resources: [PDFImageResource],
                     options: CompressionOptions,
                     documentID: String,
                     documentBytes: Int,
                     pixels: ImagePixelSource,
                     isCancelled: (() -> Bool)? = nil,
                     stageTimer: StageTimer? = nil,
                     overrides: DecisionOverrides = DecisionOverrides(),
                     store: CandidateStore? = nil,
                     mrc: [MRCProvision] = [],
                     mrcOnDemand: ((Set<Int>) throws -> [MRCProvision])? = nil,
                     fonts: [FontOptimizer.Provision] = [],
                     pageAnalyses: [PageAnalysis] = [],
                     workProgress: WorkProgressLedger? = nil) throws -> Result {
        // V2-11 (§4.18/§25) – Es gibt nur den Candidate-Pfad: Der frühere
        // Legacy-Entscheidungscode (decide + planJPEG-Leiter) ist nach der
        // Zertifizierung entfernt (§25: „alte V1-Branches entfernen“).
        return try planViaCandidates(resources: resources, options: options,
                                     documentID: documentID,
                                     documentBytes: documentBytes,
                                     pixels: pixels,
                                     isCancelled: isCancelled,
                                     stageTimer: stageTimer,
                                     overrides: overrides,
                                     store: store,
                                     mrc: mrc,
                                     mrcOnDemand: mrcOnDemand,
                                     fonts: fonts,
                                     pageAnalyses: pageAnalyses,
                                     workProgress: workProgress)
    }

    // MARK: - Candidate-Pfad (§9, §5.8 Phase A) – seit V2-11 DER Pfad
    /// Erzeugt pro Bildressource ein CandidateSet, wählt daraus lokal den
    /// kleinsten Candidate (alle im Set sind gate-geprüft; KEEP gewinnt
    /// Gleichstände) und übersetzt die Wahl in die bestehenden
    /// ImageCompressionActions. Executor und Estimator laufen unverändert
    /// weiter – der Unterschied liegt allein in der HERLEITUNG der Aktionen.
    ///
    /// Kandidaten-Payloads liegen im CandidateStore (§9.12, RAM/Spill/
    /// metadata-only); die Payload des GEWÄHLTEN Kandidaten wandert in die
    /// bestehenden Planartefakte. Ist sie regenerierbar (metadata-only),
    /// kodiert der Executor deterministisch aus den Planparametern neu.
    private static func planViaCandidates(resources: [PDFImageResource],
                                          options: CompressionOptions,
                                          documentID: String,
                                          documentBytes: Int,
                                          pixels: ImagePixelSource,
                                          isCancelled: (() -> Bool)?,
                                          stageTimer: StageTimer?,
                                          overrides: DecisionOverrides,
                                          store externalStore: CandidateStore? = nil,
                                          mrc: [MRCProvision] = [],
                                          mrcOnDemand: ((Set<Int>) throws -> [MRCProvision])? = nil,
                                          fonts: [FontOptimizer.Provision] = [],
                                          pageAnalyses: [PageAnalysis] = [],
                                          workProgress: WorkProgressLedger? = nil) throws -> Result {
        // V2-5 (§11.6-Rung) – Pass-Abschaltungen des Rollbacks gelten für
        // Planung UND Plan (der Executor liest die Politiken aus dem Plan).
        var effectiveOptions = options
        if effectiveOptions.compatibilityPolicy == .maximum {
            effectiveOptions.image.jpegBackend = .imageIO
        }
        if let fontPolicy = overrides.fontPolicy { effectiveOptions.fontPolicy = fontPolicy }
        if let dedupPolicy = overrides.dedupPolicy { effectiveOptions.dedupPolicy = dedupPolicy }
        if let bilevelPolicy = overrides.bilevelPolicy {
            effectiveOptions.image.bilevelPolicy = bilevelPolicy
        }

        var actions: [ImageCompressionAction] = []
        var artifacts = CompressionPlanArtifacts()
        var originalImageBytes = 0
        var classifications: [PDFObjectID: ResourceClassification] = [:]
        var candidateSets: [CandidateSet] = []
        var decisions: [ResourceDecision] = []
        var overriddenDecisions = 0

        // V2-6 (§12.6) – übergebener Store = Payloads bleiben über Läufe
        // EINER compress()-Operation bevölkert (Actual-Size-Feedback); ein
        // eigener Store wird wie bisher am Ende freigegeben (RAII).
        let ownedStore = externalStore == nil
        let store = externalStore ?? CandidateStore()
        // RAII: Nach der Wahl lebt nur der gewählte Payload in den
        // Planartefakten weiter – alles andere (Spill-Dateien inklusive)
        // wird hier freigegeben (eigener Store) bzw. vom Besitzer
        // (Compressor-Lauf) verwaltet.
        defer { if ownedStore { store.cancel() } }

        // Phase 1 (Erzeugen): alle CandidateSets in Dokumentreihenfolge –
        // seit V2-6 VOR der Wahl, damit der globale Budget-Optimizer
        // (§12.4) über den GESAMTEN Kandidatenraum sucht. Mit dem V2-9-Flag
        // (§15.2/§15.4) laufen die Jobs unter dem Pixel-Budget-Scheduler
        // PARALLEL; ohne Flag bleibt es die serielle Schleife (byteidentisch).
        // V2-7 (§13) – MRC-Bundles je Ressource (QA-geprüft, vom Aufrufer
        // über die Pipeline bereitgestellt, weil nur dort Dokumentzugriff
        // besteht).
        var mrcByResource: [String: [PreparedMRCCandidate]] = [:]
        for provision in mrc {
            mrcByResource[provision.resourceID] = provision.candidates
        }
        // Quantisierte Palette NUR für Small/Target-Size (§4: keine
        // Farbreduktion in Smart/Qualität/Custom). Das Ziel koppelt an den
        // Modus (V2-6), verschärft aber nie unter dessen Floor – die
        // Preset-Floors des Optimizers bleiben die Untergrenze.
        // Feste Nutzerparameter (Custom) werden auch durch ein Ziel nicht
        // umgedeutet – vorher schaltete das Ziel die Farbreduktion in
        // „Eigene" frei (Befund B4, Review 2026-10-09).
        let allowsQuantizedPalette: Bool = {
            let preset = QualityGatePreset(ssimThreshold: effectiveOptions.image.ssimThreshold)
            if preset == .custom { return false }
            if case .targetBytes = effectiveOptions.goal { return true }
            return preset == .small
        }()
        var entries = try StageTimer.run(stageTimer, .candidateGenerationMs) {
            try Self.generateCandidateEntries(
                resources: resources,
                options: effectiveOptions,
                pixels: pixels,
                store: store,
                mrcByResource: mrcByResource,
                pageContext: Dictionary(uniqueKeysWithValues:
                    pageAnalyses.map { ($0.pageIndex, $0) }),
                isCancelled: isCancelled,
                stageTimer: stageTimer,
                allowsQuantizedPalette: allowsQuantizedPalette,
                workProgress: workProgress)
        }

        // Phase 1b (2026-10-15) – MRC nur bei Bedarf: Erst wenn der beste
        // bereits gefundene Kandidat des dominanten Rasters einer Scan-Seite
        // noch ueber der Budget-Schwelle liegt, laeuft die teure Provision –
        // und nur fuer diese Seiten. Ihre Buendel kommen in das fertige Set,
        // die JPEG-Suche wird nicht wiederholt. Vorher lief die Provision
        // fuer jede Scan-Seite vor der Planung (10 s je einseitigem Scan,
        // fast immer vergebens).
        if let mrcOnDemand, effectiveOptions.featureFlags.mrc {
            let threshold = effectiveOptions.mrcProvisionBudget.provisionIfCandidateExceedsBytes
            var indexByResource: [String: Int] = [:]
            for (index, entry) in entries.enumerated() {
                indexByResource[entry.generated.set.resourceID] = index
            }
            var needed = Set<Int>()
            for page in MRCPageRewriter.eligiblePages(resources: resources,
                                                      pageAnalyses: pageAnalyses) {
                let resourceID = CandidateSet.resourceID(for: page.resource.objectID)
                guard let index = indexByResource[resourceID] else { continue }
                var best = entries[index].generated.set.candidates
                    .map(\.metrics.encodedBytes).min() ?? Int.max
                // Ein Scan im DPI-Budget hat nur KEEP – dessen Bytes sind
                // hier das Original, im Dokument aber der verlustfreie
                // JPEG-Repack (`finalize` rechnet ihn nur bei Konkurrenz).
                // Der Vergleich gilt dem, was wirklich herauskäme.
                if entries[index].generated.set.candidates.count == 1,
                   page.resource.terminalFilter == .dct {
                    best = min(best, Self.repackBarrier(resource: page.resource,
                                                        pixels: pixels))
                }
                if best > threshold { needed.insert(page.pageIndex) }
            }
            if !needed.isEmpty {
                for provision in try mrcOnDemand(needed) {
                    guard let index = indexByResource[provision.resourceID] else { continue }
                    entries[index].generated = CandidateGenerator.merging(
                        mrc: provision.candidates,
                        into: entries[index].generated, store: store)
                }
            }
        }
        for entry in entries {
            candidateSets.append(entry.generated.set)
            if entry.resource.encodedByteCount > 0 {
                originalImageBytes += entry.resource.encodedByteCount
            }
        }

        // Phase 2: Wahl. Ohne Zielgrößen-Ziel lokal (§10, V2-4) –
        // pareto → Gates → Katastrophen-Floor → Preset-Floor → kleinster;
        // mit `.targetBytes` der globale Optimizer (V2-6, §12.4) über den
        // gate-bestandenen Pool. Die Preset-Floors des gewählten Modus
        // bleiben in beiden Fällen die Untergrenze (§12.8).
        enum Choice {
            case local(RateDistortionOptimizer.Selection)
            case target(TargetSizeOptimizer.Selection)
        }
        var choices: [String: Choice] = [:]
        if case .targetBytes(let requested) = effectiveOptions.goal {
            let preset = QualityGatePreset(
                ssimThreshold: effectiveOptions.image.ssimThreshold)
            let sources = entries.map { entry in
                TargetSizeOptimizer.Source(
                    group: .single(entry.generated.set),
                    contentClass: entry.generated.classification?
                        .contentClass ?? .unknown)
            }
            // §12.3 – Fixed Bytes: Dokumentgröße − KEEP-Bytes aller
            // Candidate-Set-Ressourcen, mal dem Struktur-Faktor (V2-1-
            // Messwerte). Die Drift korrigiert das Actual-Size-Feedback.
            let optimizable = entries.reduce(0) { sum, entry in
                sum + max(0, entry.generated.set.keepCandidate?
                    .metrics.encodedBytes ?? 0)
            }
            let optimization = TargetSizeOptimizer.optimize(
                sources: sources, targetBytes: Int64(requested),
                fixedBytes: TargetSizeOptimizer.fixedBytes(
                    documentBytes: documentBytes, optimizableBytes: optimizable),
                preset: preset)
            for selection in optimization.selections {
                choices[selection.resourceID] = .target(selection)
            }
        } else {
            for entry in entries {
                let preset = QualityGatePreset(
                    ssimThreshold: effectiveOptions.image.ssimThreshold)
                let contentClass = entry.generated.classification?
                    .contentClass ?? .unknown
                let selection = RateDistortionOptimizer.select(
                    from: entry.generated.set, contentClass: contentClass,
                    preset: preset)
                choices[entry.generated.set.resourceID] = .local(selection)
            }
        }

        // Phase 3: Übersetzung in Aktionen/Artefakte – identische Logik
        // für beide Wahlwege; die Overrides (V2-5/V2-6) greifen auf der
        // GEWÄHLTEN Entscheidung.
        for entry in entries {
            let generated = entry.generated
            let resource = entry.resource
            var selected: CompressionCandidate
            var ladder: [CandidateID]
            var selectionReason: String
            var catastrophicRejection = false
            switch choices[generated.set.resourceID] {
            case .local(let selection):
                selected = selection.candidate
                ladder = selection.candidateIDsBySafety
                selectionReason = selection.reason
                catastrophicRejection = selection.catastrophicRejection
            case .target(let selection):
                selected = selection.candidate
                ladder = selection.candidateIDsBySafety
                selectionReason = selection.reason
            case nil:
                continue
            }

            // V2-5 (§11.5)/V2-6 (§12.6) – Override auflösen: die erzwungene
            // CandidateID gilt, wenn sie generierbar ist; sonst die nächste
            // Leiter-Stufe, ganz am Ende KEEP (nie ein unlieferbarer
            // Kandidat).
            if let forcedID = overrides.forcedCandidates[generated.set.resourceID],
               let forced = Self.resolveOverride(forcedID, in: generated.set,
                                                 ladder: ladder) {
                selected = forced
                overriddenDecisions += 1
                selectionReason = "\(overrides.label): "
                    + "\(forcedID.rawValue) erzwungen (\(selectionReason))"
            }

            guard var action = generated.actionsByCandidate[selected.id] else {
                // Sollte unerreicht sein (KEEP ist immer vorhanden und
                // übersetzt); zur Sicherheit: KEEP ohne Eingriff.
                actions.append(.keep(objectID: resource.objectID,
                                     reason: .decodeFailed,
                                     originalEncodedBytes: resource.encodedByteCount))
                continue
            }
            // §10.3 – Die Wahl fiel wegen des Katastrophen-Floors auf KEEP
            // zurück: Der Plan führt das als eigenen Grund (Produkt-
            // sicherheit, kein „innerhalb der Zielauflösung“).
            if selected.kind.isKeep, catastrophicRejection,
               overrides.forcedCandidates[generated.set.resourceID] == nil,
               case .keep(let keepID, _, let bytes) = action {
                action = .keep(objectID: keepID, reason: .catastrophicFloorFailed,
                               originalEncodedBytes: bytes)
            }
            actions.append(action)

            if let payload = generated.payloadByCandidate[selected.id],
               let data = store.data(for: payload) {
                artifacts.store(data, for: resource.objectID)
            }
            if let globals = generated.globalsByCandidate[selected.id] {
                artifacts.storeGlobals(globals, for: resource.objectID)
            }
            if let classification = generated.classification {
                classifications[resource.objectID] = classification
            }
            decisions.append(ResourceDecision(
                resourceID: generated.set.resourceID,
                selectedCandidateID: selected.id,
                // Rückstufungsleiter aus den ZULÄSSIGEN Kandidaten (verworfene
                // sind niemals lieferbar, auch nicht als Rollback-Stufe).
                candidateIDsBySafety: ladder,
                classification: generated.classification?.contentClass ?? .unknown,
                features: generated.classification?.features,
                pages: Array(Set(resource.placements.map(\.pageIndex))).sorted(),
                reason: selectionReason))
        }

        // Phase 4 (V2-8, §14.1) – selektive Font-Entscheidungen. Die Font-
        // Sets leben wie die Bild-Sets in candidateSets/decisions (Estimator,
        // Re-Plan und Trace sehen denselben Kandidatenraum); die
        // AUSFÜHRBAREN Subset-Wahlen wandern zusätzlich in plan.fontSubsets,
        // wo der Executor sie einzeln mit je-Font-QA (§14.4) anwendet.
        // Pass-Abschaltung: fontPolicy .off ODER fontSubsettingPolicy .off
        // (auch als Override) trägt keine Font-Subsets – der Font-Pass ist
        // komplett aus. Die Politik steuert seit V2-11 den SELEKTIVEN Pfad
        // (der frühere globale Snapshot-Pass ist entfernt, §4.18).
        var fontSubsets: [FontOptimizer.Decision] = []
        let fontProvisions = (effectiveOptions.fontPolicy == .off
                              || effectiveOptions.fontSubsettingPolicy == .off)
            ? [] : fonts
        for provision in fontProvisions {
            let set = FontOptimizer.candidateSet(for: provision)
            candidateSets.append(set)
            let keepID = FontOptimizer.keepCandidateID(of: set)
            let subsetID = FontOptimizer.subsetCandidateID(of: set)
            // Rückstufungsleiter (§5.7): subset (aggressiv) → keep.
            var ladder: [CandidateID] = []
            if let subsetID { ladder.append(subsetID) }
            if let keepID { ladder.append(keepID) }

            var selected: CompressionCandidate
            var selectionReason: String
            if let forcedID = overrides.forcedCandidates[provision.resourceID],
               let forced = set.candidates.first(where: { $0.id == forcedID }) {
                // V2-5 (§11.5)/V2-6 (§12.6) – Override: erzwungener fontKeep
                // rollt den Subset zurück, erzwungener fontSubset setzt ihn
                // durch (sofern lieferbar).
                selected = forced
                selectionReason = "\(overrides.label): "
                    + "\(forcedID.rawValue) erzwungen"
            } else if let subsetID,
                      let subset = set.candidates.first(where: {
                          $0.id == subsetID
                      }) {
                selected = subset
                selectionReason = subset.reason
            } else {
                selected = set.candidates[0]
                selectionReason = selected.reason
            }

            if case .fontSubset = selected.kind {
                fontSubsets.append(FontOptimizer.Decision(
                    objectID: provision.objectID,
                    pages: Array(Set(provision.pages)).sorted(),
                    estimatedSaving: provision.estimatedSaving))
            }

            decisions.append(ResourceDecision(
                resourceID: provision.resourceID,
                selectedCandidateID: selected.id,
                candidateIDsBySafety: ladder,
                classification: .unknown,
                features: nil,
                pages: Array(Set(provision.pages)).sorted(),
                reason: selectionReason))
        }

        return Result(
            plan: CompressionPlan(
                documentID: documentID,
                actions: actions,
                metadataPolicy: effectiveOptions.metadataPolicy,
                linearizationPolicy: effectiveOptions.linearizationPolicy,
                dedupPolicy: effectiveOptions.dedupPolicy,
                fontPolicy: effectiveOptions.fontPolicy,
                fontSubsettingPolicy: effectiveOptions.fontSubsettingPolicy,
                compatibilityPolicy: effectiveOptions.compatibilityPolicy,
                jpegBackend: effectiveOptions.image.jpegBackend,
                originalImageBytes: originalImageBytes,
                originalDocumentBytes: documentBytes,
                flatePolicy: effectiveOptions.flatePolicy,
                candidateSets: candidateSets,
                decisions: decisions,
                goal: effectiveOptions.goal
                    ?? CompressionGoal(imageOptions: effectiveOptions.image),
                traceVersion: 2,
                fontSubsets: fontSubsets,
                resourceGCPolicy: effectiveOptions.resourceGCPolicy),
            artifacts: artifacts,
            classifications: classifications)
    }

    /// V2-5 (§11.5) – Override-Auflösung: Existiert der erzwungene Kandidat
    /// im Set, gilt er. Ist er NICHT mehr generierbar (andere Kandidaten-
    /// Erzeugung im Re-Plan), die nächste Stufe der Leiter, die lieferbar
    /// ist; führt keine hinaus, KEEP. internal für RollbackPlannerTests.
    static func resolveOverride(_ forcedID: CandidateID,
                                in set: CandidateSet,
                                ladder: [CandidateID]) -> CompressionCandidate? {
        if let forced = set.candidates.first(where: { $0.id == forcedID }) {
            return forced
        }
        if let index = ladder.firstIndex(of: forcedID) {
            for step in ladder[(index + 1)...] {
                if let candidate = set.candidates.first(where: { $0.id == step }) {
                    return candidate
                }
            }
        }
        return set.keepCandidate
    }

    // MARK: - Phase V2-9 (§15.2/§15.4) – Candidate-Jobs unter dem Scheduler

    /// Erzeugt alle CandidateSets – seriell (Default, byteidentisch zum
    /// Bestand) oder parallel unter dem Pixel-Budget-Scheduler (Flag
    /// `pixelBudgetScheduler`, §15.2).
    ///
    /// §15.1-Grenzen: QPDF-Handle bleibt SERIELL mutiert – die Jobs greifen
    /// über die Pixelquelle am Dokument, dessen Bridge-Sperre die
    /// Stream-Extraktion intern serialisiert. Parallel läuft ausschließlich
    /// pure Pixelarbeit (decode/resize/encode/measure).
    ///
    /// §15.2/§15.4-Grenzen: höchstens `min(activeProcessors, 8)` aktive
    /// Jobs UND Σ estimatedWorkingBytes ≤ Budget (Leases, §15.3).
    ///
    /// Determinismus (§15.4): Jeder Job schreibt NUR seinen eigenen
    /// Ergebnis-Slot (Index in der Dokumentreihenfolge); die Sets landen
    /// NACH Abschluss in Dokumentreihenfolge in candidateSets/entries –
    /// nichts wandert während der Konkurrenz in geteilte Strukturen. Der
    /// CandidateStore ist selbst gesperrt, seine Schlüssel sind je
    /// (Ressource, Kandidat) eindeutig – Payload-Ablage und Spill bleiben
    /// ergebnisdeterministisch.
    private static func generateCandidateEntries(resources: [PDFImageResource],
                                                 options: CompressionOptions,
                                                 pixels: ImagePixelSource,
                                                 store: CandidateStore,
                                                 mrcByResource: [String: [PreparedMRCCandidate]],
                                                 pageContext: [Int: PageAnalysis],
                                                 isCancelled: (() -> Bool)?,
                                                 stageTimer: StageTimer?,
                                                 allowsQuantizedPalette: Bool = false,
                                                 workProgress: WorkProgressLedger? = nil)
        throws -> [(resource: PDFImageResource, generated: CandidateGenerator.Generated)] {

        struct Entry {
            let resource: PDFImageResource
            let generated: CandidateGenerator.Generated
        }

        let imageOptions = options.image
        let classifierPolicy = options.classifierPolicy

        func generate(_ resource: PDFImageResource,
                      mrcCandidates: [PreparedMRCCandidate])
            -> CandidateGenerator.Generated {
            CandidateGenerator.generate(resource: resource,
                                        options: imageOptions,
                                        classifierPolicy: classifierPolicy,
                                        pixels: pixels, store: store,
                                        mrc: mrcCandidates,
                                        pageContext: pageContext,
                                        stageTimer: stageTimer,
                                        allowsQuantizedPalette: allowsQuantizedPalette)
        }

        // Seriell – exakt die bisherige Schleife.
        guard options.featureFlags.pixelBudgetScheduler else {
            var entries: [(resource: PDFImageResource,
                           generated: CandidateGenerator.Generated)] = []
            for resource in resources {
                if let isCancelled, isCancelled() { throw CancellationError() }
                let mrcCandidates = mrcByResource[
                    CandidateSet.resourceID(for: resource.objectID)] ?? []
                let generated: CandidateGenerator.Generated = autoreleasepool {
                    generate(resource, mrcCandidates: mrcCandidates)
                }
                workProgress?.complete(WorkProgressLedger.weight(pixels: resource.pixelCount))
                entries.append((resource, generated))
            }
            return entries
        }

        // Parallel unter dem Scheduler (§15.2/§15.4). Dispatch statt
        // TaskGroup: Die Jobs blockieren bewusst auf der Bridge-Sperre und
        // im Budget – Cooperative Threads wären dort fehl am Platz.
        let scheduler = PixelWorkScheduler(
            budgetBytes: PixelWorkScheduler.resolvedBudget(
                optionsBytes: options.pixelBudgetBytes))
        let slots = DispatchSemaphore(value: PixelWorkScheduler.maximumActiveJobs)
        let group = DispatchGroup()
        let lock = NSLock()
        var caught: Error?
        var results = [(resource: PDFImageResource,
                        generated: CandidateGenerator.Generated)?](
            repeating: nil, count: resources.count)

        for (index, resource) in resources.enumerated() {
            if let isCancelled, isCancelled() { throw CancellationError() }
            let mrcCandidates = mrcByResource[
                CandidateSet.resourceID(for: resource.objectID)] ?? []
            // Schätzung §15.2: Dekodierte Quelle + Zielraster + Encode-
            // Scratch + Qualitätsstichprobe (Formel im Scheduler).
            let estimate = PixelWorkScheduler.estimatedWorkingBytes(
                source: PixelSize(width: resource.width, height: resource.height),
                target: CompressionPlanner.plannedSize(for: resource,
                                                        options: imageOptions)
                    ?? PixelSize(width: resource.width, height: resource.height))
            group.enter()
            slots.wait()
            let lease = scheduler.acquireBlocking(bytes: estimate)
            // Eigene serielle Queue je Job: Serielle Queues laufen auf dem
            // Overcommit-Pool. `DispatchQueue.global()` ist non-overcommit und
            // teilt sich die Breite mit dem Swift-Concurrency-Pool – blockieren
            // dort genug Aufrufer in `group.wait()`, bekommt kein Worker mehr
            // einen Thread (Deadlock, reproduziert mit ≥ 10 parallelen
            // Planner-Tests: alle Pool-Threads in group.wait, kein Worker).
            DispatchQueue(label: "pdftools.candidates.\(index)",
                          qos: .userInitiated).async {
                defer { slots.signal(); group.leave(); lease.release() }
                ParallelWork.Slots.enter()
                defer { ParallelWork.Slots.leave() }
                do {
                    if let isCancelled, isCancelled() { throw CancellationError() }
                    let generated: CandidateGenerator.Generated = autoreleasepool {
                        generate(resource, mrcCandidates: mrcCandidates)
                    }
                    lock.lock()
                    results[index] = (resource, generated)
                    lock.unlock()
                    workProgress?.complete(
                        WorkProgressLedger.weight(pixels: resource.pixelCount))
                } catch {
                    lock.lock()
                    if caught == nil { caught = error }
                    lock.unlock()
                }
            }
        }
        group.wait()
        if let caught { throw caught }
        return results.compactMap { $0 }
    }

    // MARK: - Bilevel-Race (Phase 2b)

    /// Bilevel-Klasse nach Dictionary-Ebene (ohne Dekodierung); `nil`, wenn
    /// der Bilevel-Pfad nicht zuschlagen darf. Alles Unsichere führt zurück
    /// in den regulären Weg – kein Thresholding auf Verdacht. Bilevel wird
    /// nie resampelt, die Größenpolitik (DPI/Kantenlimit) zählt hier bewusst
    /// nicht. (internal für die Candidate-Engine, V2-3a.)
    static func planBilevelKind(resource: PDFImageResource)
        -> BilevelDetection.Kind? {
        guard resource.unknownFilters.isEmpty,
              !resource.hasColorKeyMask,
              !resource.isImageMask,
              !resource.hasEffectiveDecodeArray,
              resource.pixelCount <= maximumDecodablePixels else {
            return nil
        }
        switch resource.terminalFilter {
        case .dct, .flate, .lzw, .runLength, nil:
            break
        case .jpx:
            // Phase 4b: JPX-Eingaben sind regulär dekodierbar, bleiben aber
            // bewusst außerhalb der Bilevel-Analyse – sie laufen über den
            // normalen photo/graphics-Pfad, statt exakt zweiwertig geprüft
            // zu werden (Minimaleingriff; ein JPEG-2000-Scan ist selten
            // zweiwertig genug, als dass sich der Zusatzpfad lohnte).
            return nil
        case .ccitt:
            // V2-3c (§9.10): CCITT-EINGÄNGE sind dekodierbar (eigener
            // Fax-Shim, DecodeParms-Katalog in der Pixelquelle geprüft).
            // Sie nehmen damit am Bilevel-Race teil – genau der §9.10-
            // Kandidatenraum KEEP / G4 / JBIG2 lossless. Die Capability-
            // Sperre für CCITTFaxDecode bleibt trotzdem bestehen: Sie
            // schützt nur die regulären (resamplenden) Pfade; ein
            // trueBilevel-Bild kehrt in Schritt 0 VOR der Capability
            // zurück. Scheitert der Katalog (exotische DecodeParms),
            // liefert die Pixelquelle nil → deterministisch decodeFailed.
            break
        case .jbig2, .ascii85, .asciiHex, .crypt:
            // Eingangsfilter, die wir nicht anfassen (JBIG2-Input bleibt
            // ohne Dekodierer – oversized bleibt unberührt, siehe
            // TODO in PDFImageDomain).
            return nil
        }
        let kind = BilevelDetection.classify(resource: resource)
        return kind == .none ? nil : kind
    }

    /// KEEP vs. CCITT G4 vs. lossless JBIG2 – kleinster bitidenter Kandidat
    /// gewinnt, Gleichstand geht an den früher geprüften (G4 vor JBIG2,
    /// Interop-Vorzug). Jeder Kandidat wird DEKODIERT und bitidentisch gegen
    /// den Ausgangspuffer geprüft; wer auch nur ein Bit verliert, fliegt
    /// raus (Roadmap: „choose smallest candidate satisfying policy",
    /// Never-Grow auf Stream-Ebene). (internal für die Candidate-Engine, V2-3a.)
    ///
    /// Zweitlauf-Schutz (V2-3c, §9.10): Seit CCITT-Eingängen dekodierbar
    /// sind, würde ein eigener G4-Output im Zweitlauf wieder dekodiert und
    /// neu raced. Der deterministische Kodierer macht ihn erkennbar:
    /// Re-kodiert der dekodierte Strom byteidentisch zum Original, war es
    /// unser eigener Output – G4(G4(x)) wäre
    /// byteidentisch ohne Vorteil, und ein JBIG2-Nachschub würde den
    /// Zweitlauf iterativ machen. Solche Ströme bleiben daher GANZ KEEP.
    /// Ein externer G4-Strom (andere Encoder-Entscheidungen) unterscheidet
    /// sich fast immer und bleibt normal im Race.
    static func bilevelRace(buffer: BilevelBuffer,
                            resource: PDFImageResource,
                            pixels: ImagePixelSource)
        -> (ImageCompressionAction, Data?, Data?) {
        let objectID = resource.objectID
        let original = resource.encodedByteCount
        var best: (action: ImageCompressionAction, payload: Data,
                   globals: Data?, size: Int)?
        var gateRejected = false

        // Kandidat 1: CCITT G4. Verlustfrei-Nachweis über den Rückweg durch
        // denselben Codec (libtiff liest den nackten T6-Strom zurück).
        if let g4 = BilevelCodec.encodeG4(buffer) {
            if let originalStream = pixels.rawImageData(for: resource),
               originalStream == g4 {
                // Zweitlauf-Schutz: byteidentischer Re-Encode = eigener
                // Output. KEEP ohne Kandidaten (dokumentiert oben).
                return (.keep(objectID: objectID, reason: .noSizeBenefit,
                              originalEncodedBytes: original),
                        nil, nil)
            }
            if original < 0 || g4.count < original {
                if let back = BilevelCodec.decodeG4(g4,
                                                    width: buffer.width,
                                                    height: buffer.height),
                   back.bitIdentical(to: buffer) {
                    best = (.ccittG4(objectID: objectID,
                                     originalEncodedBytes: original,
                                     expectedEncodedBytes: g4.count),
                            g4, nil, g4.count)
                } else {
                    gateRejected = true
                }
            }
        }

        // Kandidat 2: lossless JBIG2, zwei Kodierer, beide hinter dem
        // PDFKit-Render-Gate (der Dekodierer – nicht der Kodierer – muss
        // die Pixel zurückgeben):
        //   a) Symbolpfad mit Globals – auf Text deutlich kleiner, aber der
        //      Symbolklassifizierer führt ÄHNLICHE Glyphen zusammen
        //      (Schwellwertbereich 0.4–0.98, exakte Klassen sind nicht
        //      einstellbar) und ist deshalb nicht bitidentisch garantiert.
        //      Er bestreitet den Race nur, wenn das Gate ihn durchlässt.
        //   b) Generische Region – reine Entropiekodierung des exakten
        //      Bitmaps, konstruktiv verlustfrei, ohne Globals.
        if let jbig2 = BilevelCodec.encodeJBIG2(buffer) {
            let size = jbig2.page.count + jbig2.globals.count
            if tryJBIG2(page: jbig2.page, globals: jbig2.globals, size: size,
                        buffer: buffer, objectID: objectID, original: original,
                        best: &best) {
                gateRejected = true
            }
        }
        if let generic = BilevelCodec.encodeJBIG2Generic(buffer) {
            _ = tryJBIG2(page: generic, globals: Data(), size: generic.count,
                         buffer: buffer, objectID: objectID, original: original,
                         best: &best)
        }

        guard let winner = best else {
            // Den Grund behält der Plan: kein bitidenter Kandidat war
            // kleiner als das Original (Never-Grow), oder das Gate hat
            // einen kleineren verworfen.
            let reason: KeepReason = gateRejected ? .bilevelGateFailed : .noSizeBenefit
            return (.keep(objectID: objectID, reason: reason,
                          originalEncodedBytes: original), nil, nil)
        }
        return (winner.action, winner.payload, winner.globals)
    }

    /// Nimmt einen JBIG2-Kandidaten in den Race auf, wenn er kleiner ist als
    /// das Original und der bisher beste Kandidat (Gleichstand gewinnt der
    /// frühere – G4 bzw. der zuerst geprüfte JBIG2-Pfad). Liefert `true`,
    /// wenn ein größerer Kandidat am Gate gescheitert ist (für KeepReason).
    private static func tryJBIG2(page: Data, globals: Data, size: Int,
                                 buffer: BilevelBuffer, objectID: PDFObjectID,
                                 original: Int,
                                 best: inout (action: ImageCompressionAction,
                                              payload: Data, globals: Data?,
                                              size: Int)?) -> Bool {
        let originalLimit = original < 0 ? Int.max : original
        let limit = best.map { min($0.size, originalLimit) } ?? originalLimit
        guard size < limit else { return false }
        guard let rendered = BilevelRenderGate.decodedBuffer(
                page: page,
                globals: globals.isEmpty ? nil : globals,
                width: buffer.width, height: buffer.height),
              rendered.bitIdentical(to: buffer) else {
            return true
        }
        best = (.jbig2(objectID: objectID,
                       originalEncodedBytes: original,
                       expectedEncodedBytes: size),
                page, globals.isEmpty ? nil : globals, size)
        return false
    }

    // MARK: - Zielgröße

    /// Niedrigste Qualitätsstufe, die ein Plan mit diesen Optionen für eine
    /// verlustbehaftete Neukodierung wählen darf (feste Qualität: genau
    /// diese). Die Schnellschätzung liest sie für ihre Byte-Kurven – wie
    /// `plannedSize` für die Pixelzahl. Sie entscheidet damit nichts; welche
    /// Stufe ein Bild bekommt, bestimmen weiter allein die Gates im Lauf.
    static func qualityFloor(for options: ImageCompressionOptions) -> Double {
        options.qualityLadder.min() ?? options.jpegQuality
    }

    /// Effective DPI + Toleranz + Kantenlimit. Gibt `nil` zurück, wenn nicht
    /// verkleinert werden soll. `dpi` überschreibt die Zielauflösung der
    /// Optionen – die Auflösungsleiter der Candidate-Engine (§9.4) nutzt das,
    /// um die Stufen 240/144/110/96 DPI aus derselben Politik herzuleiten.
    static func plannedSize(for resource: PDFImageResource,
                            options: ImageCompressionOptions,
                            dpi overrideDPI: Double? = nil) -> PixelSize? {
        let targetDPI = overrideDPI ?? options.targetDPI
        let width = resource.width, height = resource.height
        let maxEdge = max(width, height)
        guard maxEdge > 0 else { return nil }

        var targetW = width
        var targetH = height
        var shrink = false

        let capFactor = Double(options.maxPixelEdge) / Double(maxEdge)

        if let dpi = resource.effectiveDPI, dpi > 0 {
            if dpi > targetDPI * options.tolerance {
                let factor = targetDPI / dpi
                targetW = Int((Double(width) * factor).rounded(.up))
                targetH = Int((Double(height) * factor).rounded(.up))
                shrink = true
            }
            if options.hardPixelCap && capFactor < 1 {
                targetW = min(targetW, Int((Double(width) * capFactor).rounded()))
                targetH = min(targetH, Int((Double(height) * capFactor).rounded()))
                shrink = true
            }
        } else if capFactor < 1 {
            // Ohne bekannte Platzierung bleibt nur das Kantenlimit. Erst
            // deutlich über der Grenze wird eingegriffen, damit ein Bild
            // knapp über `maxPixelEdge` nicht ohne Nutzen neu kodiert wird.
            targetW = min(targetW, Int((Double(width) * capFactor).rounded()))
            targetH = min(targetH, Int((Double(height) * capFactor).rounded()))
            if capFactor < 1 / options.tolerance { shrink = true }
        }

        targetW = max(1, min(width, targetW))
        targetH = max(1, min(height, targetH))

        guard shrink, targetW < width || targetH < height else { return nil }
        return PixelSize(width: targetW, height: targetH)
    }

    // MARK: - Kodierpfade

    /// Verlustfreies Verkleinern + PNG-Prädiktor – der bestehende Pfad, von
    /// der Candidate-Engine (V2-3a) als Flate-Kandidat wiederverwendet.
    static func planLosslessResize(resource: PDFImageResource,
                                   image: CGImage,
                                   target: PixelSize,
                                   grayscale: Bool)
        -> (ImageCompressionAction, Data?) {
        func keep(_ reason: KeepReason) -> (ImageCompressionAction, Data?) {
            (.keep(objectID: resource.objectID, reason: reason,
                   originalEncodedBytes: resource.encodedByteCount), nil)
        }
        // Die Komponentenzahl folgt dem Farbraum der QUELLE – so bleibt ein
        // CMYK-Bild vierkanalig.
        let components = grayscale ? 1 : (resource.colorSpace.componentCount ?? 3)
        guard let resized = ImageResampler.resize(image, to: target,
                                                  components: components),
              let best = ImageResampler.encodeLosslessBest(resized,
                                                           components: components) else {
            return keep(.decodeFailed)
        }
        let data = best.data
        guard resource.encodedByteCount < 0 || data.count < resource.encodedByteCount else {
            return keep(.noSizeBenefit)
        }
        return (.losslessResize(objectID: resource.objectID,
                                target: target,
                                grayscale: grayscale,
                                originalEncodedBytes: resource.encodedByteCount,
                                expectedEncodedBytes: data.count,
                                predictor: best.predictor), data)
    }

    // MARK: - Phase 6C – CMYK-Race

    /// Kontrollierter CMYK-JPEG-Re-Encode: Leiter über die Preset-Qualitäten,
    /// jeder Kandidat hinter zwei Sperren:
    ///
    ///  1. Größen-Race gegen den 6b-Repack des ORIGINALS (nicht gegen das
    ///     Original selbst): Der Repack läuft im Executor für jedes behaltene
    ///     DCT-Bild und ist damit der am Ende stehende Gegner. Ist der Repack
    ///     nicht kleiner (oder bereits progressiv), gilt die Originalgröße.
    ///  2. ΔE-Gate auf der RGB-Renderstichprobe (CMYKReencode.passesGate):
    ///     Marker-Erhalt, ΔE-Mittel, Kachel-Obergrenze, SSIM-Zellen.
    ///
    /// Scheitert alles, bleibt das Bild stehen – der Executor-Repack übernimmt
    /// das Feld (Fallback auf 6b). Aufsteigende Leiter: die erste Stufe, die
    /// beide Sperren hält, ist der kleinste akzeptierte Kandidat.
    /// (internal für die Candidate-Engine, V2-3a.)
    static func planCMYKReencode(resource: PDFImageResource,
                                 image: CGImage,
                                 target: PixelSize,
                                 pixels: ImagePixelSource,
                                 options: ImageCompressionOptions)
        -> (ImageCompressionAction, Data?, Data?) {

        func keep(_ reason: KeepReason) -> (ImageCompressionAction, Data?, Data?) {
            (.keep(objectID: resource.objectID, reason: reason,
                   originalEncodedBytes: resource.encodedByteCount), nil, nil)
        }

        // Größenbarriere: was der 6b-Repack aus den Originalbytes macht.
        // encodedByteCount < 0 (unbekannt) zählt als offen, die Barriere
        // entscheidet dann der Kandidat allein gegen den Repack.
        let barrier = repackBarrier(resource: resource, pixels: pixels)

        guard let resized = ImageResampler.resize(image, to: target,
                                                  components: 4) else {
            return keep(.decodeFailed)
        }

        let preset = QualityGatePreset(ssimThreshold: options.ssimThreshold)
        let limits = CMYKReencode.limits(preset: preset)

        for quality in options.qualityLadder.sorted() {
            guard let candidate = JPEGEncoder.encodeCMYK(resized, quality: quality),
                  candidate.count < barrier else { continue }
            guard CMYKReencode.passesGate(reference: resized,
                                          candidateJPEG: candidate,
                                          limits: limits) else { continue }
            return (.cmykJpegReencode(objectID: resource.objectID,
                                      target: target,
                                      selectedQuality: quality,
                                      originalEncodedBytes: resource.encodedByteCount,
                                      expectedEncodedBytes: candidate.count),
                    candidate, nil)
        }

        // Kein Kandidat hielt Race oder Gate – das Bild bleibt, der 6b-Repack
        // des Originals übernimmt im Executor.
        return keep(.cmykGateFailed)
    }

    /// Was ein BEHALTENES Bild im fertigen Dokument kostet (min(Original,
    /// verlustfreie Neuverpackung); Int.max, wenn beides unbekannt ist):
    ///   • reiner DCT-Stream → verlustfreier Repack (jpegtran-Semantik), den
    ///     der Executor auf jedes behaltene DCT-Bild anwendet (6b);
    ///   • reiner Flate-Stream → Neukompression der dekodierten Bytes, wie
    ///     der finale Writer sie fährt (`--recompress-flate`). Schwach
    ///     komprimierte Vorlagen schrumpfen dabei stark (`scan-like.pdf`:
    ///     34 → 7,7 KB); mit den Rohbytes bewertet schlug ein schlechterer
    ///     Kandidat das Original (2026-10-01).
    /// EINE Herleitung für die CMYK-Race und die KEEP-Bewertung.
    static func repackBarrier(resource: PDFImageResource,
                              pixels: ImagePixelSource) -> Int {
        let originalLimit = resource.encodedByteCount < 0
            ? Int.max : resource.encodedByteCount
        guard resource.unknownFilters.isEmpty else { return originalLimit }
        if resource.filters == [.dct], let raw = pixels.rawImageData(for: resource) {
            switch JPEGEncoder.repack(raw) {
            case .repacked(let repacked): return min(originalLimit, repacked.count)
            case .skipped, .keepOriginal: return originalLimit
            }
        }
        if resource.filters == [.flate],
           let decoded = pixels.decodedStreamData(for: resource),
           let recompressed = ImageProcessor.flateBest(decoded) {
            return min(originalLimit, recompressed.count)
        }
        return originalLimit
    }

}
// MARK: - Pixelwerkzeuge

/// Resampling und Kodierung. Bewusst über ImageIO/CoreGraphics – das ist
/// Bildverarbeitung, nicht PDF-Struktur, und gehört deshalb nicht in die
/// C++-Bridge (Masterplan Schritt 2: „Bridge soll klein bleiben").
enum ImageResampler {

    static func resize(_ image: CGImage, to size: PixelSize,
                       grayscale: Bool) -> CGImage? {
        resize(image, to: size, components: grayscale ? 1 : 3)
    }

    /// Verkleinert im Farbraum der Komponentenzahl: 1 grau, 3 RGB, 4 CMYK.
    ///
    /// CMYK bleibt dabei CMYK. Es nach RGB zu rechnen wäre bei Druckdaten
    /// eine Farbveränderung – und genau deshalb blieben 42,4 MB im Korpus
    /// bisher unangetastet.
    static func resize(_ image: CGImage, to size: PixelSize,
                       components: Int) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        // Verkleinerung über einen Flächenfilter (P0.3): CoreGraphics filtert
        // bei großen Faktoren nicht ausreichend vor – 2000 → 163 px erzeugte
        // Aliasing, das bei normaler Ansicht sichtbar war. Vorher wirkte
        // ImageIOs reduziert dekodierte Fassung zufällig als Vorfilter.
        // Lanczos (vImage) wurde gemessen und verworfen: Überschwinger hoben
        // die Kanten-Einführung eines Sonarfotos über die Katastrophen-
        // Grenze, machten verlustfrei gespeicherte Bilder bis 19 % größer und
        // sprengten exakte Paletten von Flächengrafiken (> 256 Farben).
        // Für JEDE Verkleinerung derselbe Filter – eine Schwelle teilte
        // Referenz und Kandidat sonst auf zwei Filter auf.
        let shrinks = size.width < image.width || size.height < image.height
        if shrinks,
           let flattened = flatBitmap(image, components: components),
           let scaled = areaDownscale(flattened, to: size, components: components) {
            return scaled
        }
        return drawResize(image, to: size, components: components)
    }

    // MARK: Flache Bitmaps (Herkunftsmarke)

    /// Marke an Bildern, die `drawResize` selbst erzeugt hat: ein
    /// eigenständiges 8-Bit-Bitmap im Arbeitsfarbraum der Komponentenzahl.
    ///
    /// Vor dem Flächenfilter wird die Quelle in voller Größe „flach"
    /// gezeichnet (weg von ImageIO, hinein in den Arbeitsfarbraum). Kam die
    /// Quelle bereits aus `drawResize` – jedes über `decodeJPEG`/
    /// `materialized` dekodierte Bild –, war dieser Schritt eine zweite
    /// Vollkopie derselben Pixel: bei einem 12-Megapixel-Foto ein kompletter
    /// Zeichen- und Kopierdurchgang ohne Wirkung (Profil 2026-10-13: Verkleinern,
    /// Umwandeln und Kopieren zusammen 58 % der Kandidatensuche).
    ///
    /// Die Marke hängt am Bildobjekt und lebt genau so lange wie dieses. Ein
    /// von ImageIO stammendes Bild trägt sie nie – dort bleibt das Flachzeichnen
    /// Pflicht (P0.3: reduziert dekodierte Fassung beim Zeichnen).
    private final class FlatBitmapTag {
        let components: Int
        init(components: Int) { self.components = components }
    }

    private static let flatBitmapKey = UnsafeRawPointer(
        UnsafeMutablePointer<UInt8>.allocate(capacity: 1))

    /// Ist `image` ein von `drawResize` erzeugtes Bitmap dieser Komponentenzahl?
    static func isFlatBitmap(_ image: CGImage, components: Int) -> Bool {
        (objc_getAssociatedObject(image, flatBitmapKey) as? FlatBitmapTag)?.components == components
    }

    /// Die Quelle als flaches Bitmap in voller Größe – sie selbst, wenn sie
    /// es schon ist, sonst frisch gezeichnet.
    private static func flatBitmap(_ image: CGImage, components: Int) -> CGImage? {
        if isFlatBitmap(image, components: components) { return image }
        return drawResize(image, to: PixelSize(width: image.width, height: image.height),
                          components: components)
    }

    /// Flächenfilter: halbiert schrittweise (2×2-Mittelung über CoreGraphics
    /// bei exakt halber Größe), der letzte Schritt ist kleiner als Faktor 2.
    /// Box-Vorfilterung ohne Aliasing und ohne Überschwinger.
    private static func areaDownscale(_ image: CGImage, to size: PixelSize,
                                      components: Int) -> CGImage? {
        var current = image
        while current.width >= size.width * 2, current.height >= size.height * 2 {
            let half = PixelSize(width: (current.width + 1) / 2,
                                 height: (current.height + 1) / 2)
            guard let next = drawResize(current, to: half, components: components) else { return nil }
            current = next
        }
        return drawResize(current, to: size, components: components)
    }

    /// Zeichnet per CoreGraphics in einen frischen Kontext (weißer Grund).
    private static func drawResize(_ image: CGImage, to size: PixelSize,
                                   components: Int) -> CGImage? {
        let colorSpace: CGColorSpace
        let bitmapInfo: UInt32
        switch components {
        case 1:
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmapInfo = CGImageAlphaInfo.none.rawValue
        case 4:
            colorSpace = CGColorSpaceCreateDeviceCMYK()
            bitmapInfo = CGImageAlphaInfo.none.rawValue
        default:
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        }

        guard let ctx = CGContext(data: nil,
                                  width: size.width, height: size.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        // Weißer Grund: Bilder ohne Alpha bleiben unverändert, Bilder mit
        // Alpha bekommen einen definierten Hintergrund statt Schwarz.
        // Bei CMYK ist Weiss (0,0,0,0) – der Kontext ist bereits genullt,
        // ein Grau-Füllbefehl würde dort den falschen Farbraum ansprechen.
        if components != 4 { ctx.setFillColor(gray: 1, alpha: 1) }
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let result = ctx.makeImage() else { return nil }
        objc_setAssociatedObject(result, flatBitmapKey, FlatBitmapTag(components: components),
                                 .OBJC_ASSOCIATION_RETAIN)
        return result
    }

    /// Kodiert über das JPEG-Backend (Roadmap Phase 1: mozjpeg, Fallback
    /// ImageIO). DEKODIEREN bleibt unten bei ImageIO – bewusst.
    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        JPEGEncoder.encode(image, quality: quality, backend: .mozjpeg)
    }

    /// Explizites Backend – für Presets und Tests, die ImageIO erzwingen.
    static func encodeJPEG(_ image: CGImage, quality: Double,
                           backend: JPEGBackend) -> Data? {
        JPEGEncoder.encode(image, quality: quality, backend: backend)
    }

    /// Variante mit vorbereitetem Pixelbuffer (V2-Maps-Perf): Die Bracketed
    /// Search encodiert dieselbe Referenz mit mehreren Qualitäten – der
    /// Pixelbuffer wird je Stufe EINMAL bestimmt (`JPEGEncoder.preparePixels`)
    /// und je Rung wiederverwendet. Deterministisch identisch zum Pfad ohne
    /// Vorbereitung (gleiche Pixel in denselben Shim).
    static func encodeJPEG(_ image: CGImage, quality: Double,
                           backend: JPEGBackend,
                           prepared: JPEGEncoder.PreparedPixels?) -> Data? {
        JPEGEncoder.encode(image, quality: quality, backend: backend,
                           prepared: prepared)
    }

    /// Dekodiert und löst das Ergebnis von ImageIO (P0.3): Ein direkt von
    /// ImageIO stammendes CGImage verkleinert CoreGraphics beim Zeichnen über
    /// eine eigene, reduziert dekodierte Fassung der Quelle – nicht über die
    /// vollen Pixel. Referenz (Original-JPEG) und Kandidat (neues JPEG) liefen
    /// dadurch durch verschiedene Fehlerbilder: pixelgleiche Bilder maßen
    /// SSIM 0,93, ein q-0,9-Kandidat 0,74, und die Qualitätsprüfung verwarf
    /// gute Kandidaten. Das Bitmap-Abbild hat dieselben Pixel ohne diese
    /// Abkürzung.
    static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0 else { return nil }
        guard let decoded = CGImageSourceCreateImageAtIndex(src, 0, [
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }
        return materialized(decoded)
    }

    /// Dieselben Pixel als eigenständiges Bitmap (Grau oder RGB). CMYK
    /// bleibt unangetastet: Das Zeichnen in einen DeviceCMYK-Kontext rechnet
    /// die Druckfarben um (CMYK-Rundlauf-Abweichung > 8, CMYKJPEGRoundTrip-
    /// Tests) – CMYK hat ohnehin ein eigenes ΔE-Gate.
    static func materialized(_ image: CGImage) -> CGImage {
        let components: Int
        switch image.colorSpace?.model {
        case .monochrome: components = 1
        case .rgb: components = 3
        default: return image
        }
        // Schon ein eigenes Bitmap dieser Art: dieselben Pixel, keine Kopie.
        if isFlatBitmap(image, components: components) { return image }
        return resize(image, to: PixelSize(width: image.width, height: image.height),
                      components: components) ?? image
    }

    /// Verlustfreie Kodierung für Grafiken: PNG-Zeilenprädiktor plus Flate.
    ///
    /// Der Prädiktor ist Teil des PDF-Standards (`/Predictor 15`) und ändert
    /// keinen Pixel. Er bildet nur die Differenz zum linken/oberen Pixel;
    /// dadurch sieht Deflate lange, gut komprimierbare Folgen statt absoluter
    /// Farbwerte. Gerade Screenshots, Diagramme und gescannte Textflächen
    /// werden damit deutlich kleiner, ohne auf JPEG auszuweichen.
    static func encodeLossless(_ image: CGImage, grayscale: Bool) -> Data? {
        encodeLossless(image, components: grayscale ? 1 : 3)
    }

    static func encodeLossless(_ image: CGImage, components: Int) -> Data? {
        guard let raw = rawBitmap(image, components: components),
              let predicted = pngPredictor(raw, width: image.width,
                                           height: image.height,
                                           components: components) else {
            return nil
        }
        return ImageProcessor.flateBest(predicted)
    }

    /// Echte verlustfreie Optimierung ohne Qualitätsänderung: Race zwischen
    /// rohem Flate und adaptivem PNG-Prädiktor + Flate. Beide dekodieren zum
    /// bitidentischen Zielraster (der Predictor-Flag steuert nur die
    /// /DecodeParms der Bridge); der kleinere gewinnt. Bisher lief immer nur
    /// der Predictor-Pfad – bei Rauschen/Verläufen bläht der Filter-Byte-Overhead
    /// plus schlechtere Entropie die Datei auf. Never-larger als bisher.
    static func encodeLosslessBest(_ image: CGImage, components: Int)
        -> (data: Data, predictor: Bool)? {
        guard let raw = rawBitmap(image, components: components) else {
            return nil
        }
        let rawFlate = ImageProcessor.flateBest(raw)
        guard let predicted = pngPredictor(raw, width: image.width,
                                           height: image.height,
                                           components: components),
              let predictedFlate = ImageProcessor.flateBest(predicted) else {
            guard let rawFlate else { return nil }
            return (rawFlate, false)
        }
        guard let rawFlate else { return (predictedFlate, true) }
        // Gleichstand → Predictor (bessere Dekompressions-Lokalität, Status quo).
        if predictedFlate.count <= rawFlate.count {
            return (predictedFlate, true)
        }
        return (rawFlate, false)
    }

    /// Adaptiver PNG-Prädiktor: pro Zeile wird die kleinste der fünf
    /// standardisierten Filterdarstellungen gewählt. Das erste Byte jeder
    /// Zeile signalisiert den Filter (0...4); die PDF-Bridge schreibt dazu
    /// `/DecodeParms << /Predictor 15 ... >>`.
    static func pngPredictor(_ raw: Data, width: Int, height: Int,
                             components: Int) -> Data? {
        guard width > 0, height > 0, (1...4).contains(components) else {
            return nil
        }
        let rowBytes = width * components
        guard raw.count == rowBytes * height else { return nil }

        let source = [UInt8](raw)
        var output = [UInt8](repeating: 0,
                             count: (rowBytes + 1) * height)
        // Einmal allozieren und für jede Zeile wiederverwenden. Die frühere
        // Fassung erzeugte vier Arrays plus Slices PRO ZEILE; bei grossen
        // Scans war der Prädiktor dadurch unnötig teuer.
        var candidates = [UInt8](repeating: 0, count: rowBytes * 5)

        for row in 0..<height {
            let start = row * rowBytes
            let previousStart = start - rowBytes
            var scores = [Int](repeating: 0, count: 5)

            for index in 0..<rowBytes {
                let current = source[start + index]
                let left = index >= components
                    ? source[start + index - components] : 0
                let up = row > 0 ? source[previousStart + index] : 0
                let upperLeft = row > 0 && index >= components
                    ? source[previousStart + index - components] : 0

                let values = (
                    current,
                    current &- left,
                    current &- up,
                    current &- UInt8((Int(left) + Int(up)) / 2),
                    current &- paeth(left: left, up: up,
                                    upperLeft: upperLeft)
                )
                candidates[index] = values.0
                candidates[rowBytes + index] = values.1
                candidates[rowBytes * 2 + index] = values.2
                candidates[rowBytes * 3 + index] = values.3
                candidates[rowBytes * 4 + index] = values.4
                scores[0] += predictorScore(values.0)
                scores[1] += predictorScore(values.1)
                scores[2] += predictorScore(values.2)
                scores[3] += predictorScore(values.3)
                scores[4] += predictorScore(values.4)
            }

            let bestType = scores.indices.min(by: {
                scores[$0] < scores[$1]
            }) ?? 0
            let outputStart = row * (rowBytes + 1)
            output[outputStart] = UInt8(bestType)
            let candidateStart = bestType * rowBytes
            for index in 0..<rowBytes {
                output[outputStart + 1 + index] = candidates[candidateStart + index]
            }
        }
        return Data(output)
    }

    @inline(__always)
    private static func predictorScore(_ byte: UInt8) -> Int {
        min(Int(byte), 256 - Int(byte))
    }

    private static func paeth(left: UInt8, up: UInt8,
                              upperLeft: UInt8) -> UInt8 {
        let a = Int(left), b = Int(up), c = Int(upperLeft)
        let estimate = a + b - c
        let da = abs(estimate - a)
        let db = abs(estimate - b)
        let dc = abs(estimate - c)
        if da <= db && da <= dc { return left }
        if db <= dc { return up }
        return upperLeft
    }

    /// Rohe Pixelbytes ohne Zeilenpadding – exakt das Layout, das ein
    /// PDF-Bildstream erwartet.
    static func rawBitmap(_ image: CGImage, grayscale: Bool) -> Data? {
        rawBitmap(image, components: grayscale ? 1 : 3)
    }

    static func rawBitmap(_ image: CGImage, components: Int) -> Data? {
        let width = image.width, height = image.height
        let bytesPerRow = width * components
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        let colorSpace: CGColorSpace = components == 1
            ? CGColorSpaceCreateDeviceGray()
            : (components == 4 ? CGColorSpaceCreateDeviceCMYK()
                               : CGColorSpaceCreateDeviceRGB())
        // Grau und CMYK schreibt CoreGraphics direkt in der gewünschten
        // Bytebreite; nur 3-Byte-RGB kann es nicht, deshalb dort der Umweg
        // über RGBX mit anschliessendem Entfernen der Alphaspalte.
        if components != 3 {
            let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress,
                                          width: width, height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return ok ? Data(buffer) : nil
        }

        var padded = [UInt8](repeating: 0, count: width * 4 * height)
        let ok = padded.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        for row in 0..<height {
            for column in 0..<width {
                let source = row * width * 4 + column * 4
                let destination = row * bytesPerRow + column * 3
                buffer[destination] = padded[source]
                buffer[destination + 1] = padded[source + 1]
                buffer[destination + 2] = padded[source + 2]
            }
        }
        return Data(buffer)
    }
}
