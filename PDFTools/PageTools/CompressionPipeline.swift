import Foundation

/// Masterplan Schritt 5–8 – die eine Verdrahtung von Analyzer, Planner,
/// Executor und Validator.
///
/// Produktion und Tests benutzen denselben Einstiegspunkt. Es gibt bewusst
/// keine zweite, vereinfachte Testvariante der Pipeline (Masterplan §1).
enum CompressionPipeline {

    struct Outcome {
        let plan: CompressionPlan
        let execution: CompressionExecutor.Result
        /// Die analysierten Bildressourcen – für Reports und Gate-Tests.
        let resources: [PDFImageResource]
        /// Phase V2-2 – Klassifikation je Ressource (nur im `.v2`-Pfad
        /// gefüllt, sonst leer).
        let classifications: [PDFObjectID: ResourceClassification]

        var replacedImages: Int { execution.replacedImages }
        var outputURL: URL { execution.outputURL }

        init(plan: CompressionPlan,
             execution: CompressionExecutor.Result,
             resources: [PDFImageResource],
             classifications: [PDFObjectID: ResourceClassification] = [:]) {
            self.plan = plan
            self.execution = execution
            self.resources = resources
            self.classifications = classifications
        }
    }

    /// Analysiert, plant und führt aus. Validierung passiert bewusst NICHT
    /// hier, sondern beim Aufrufer mit der zur Operation passenden Policy –
    /// sonst gäbe es zwei Stellen, die über Gültigkeit entscheiden.
    ///
    /// Phase 8 – autoreleasepool-Prinzip auf Dokumentebene: Der Executor
    /// gibt Bilddaten je Aktion frei (eigener Pool je Bild); dieser
    /// Dokument-Pool fängt die verbleibenden Transienten der Framework-Aufrufe
    /// (ImageIO, PDFKit, Bridge), die sonst bis zum nächsten Pool-Leeren
    /// liegen blieben.
    ///
    /// Phase V2-1: `stageTimer` (§7.3) und `isolation` (§7.7) sind optionale
    /// Telemetrie – nil im Produktionslauf, Verhalten unverändert.
    ///
    /// Phase V2-5 (§11.5): `overrides` tragen die erzwungenen Entscheidungen
    /// eines Re-Plan-Laufs. JEDER Aufruf öffnet das Originaldokument frisch
    /// (PDFObjectID-Regel) – ein Re-Plan ist deshalb ein Aufruf DIESER
    /// Funktion mit der Original-URL, niemals eine Mutation eines Outputs.
    ///
    /// Phase V2-6 (§12.6): `store` hält die Kandidaten-Payloads über Läufe
    /// EINER compress()-Operation bevölkert (Actual-Size-Feedback); nil
    /// heißt: eigener Store pro Aufruf (Verhalten wie bisher).
    /// §8.4 – Seitenanalysen für die Bild-Klassifikation (V2-2 offen, hier
    /// geschlossen): Dieselben Platzierungen, die der Planner erhält, gehen
    /// in `PageScanAnalyzer` – kein zweiter Inventory-Durchlauf. Scheitert
    /// die Analyse, bleibt der Kontext leer: Alle Seitenregeln des
    /// Klassifikators überspringen sich dann selbst (Konservativität).
    private static func pageAnalyses(document: PDFCoreDocument,
                                     resources: [PDFImageResource]) -> [PageAnalysis] {
        (try? PageScanAnalyzer.analyze(document: document, resources: resources)) ?? []
    }

    /// Identische Bildstreams VOR der Planung zusammenführen (2026-10-01).
    /// Getrennt gespeicherte, aber byte-gleiche Bilder wurden sonst je
    /// Platzierung verschieden verkleinert – drei verschiedene Ergebnisse,
    /// die der spätere Dedup nicht mehr zusammenlegen kann (`scan-like.pdf`
    /// in Klein: 49 KB statt 24 KB). Zusammengeführt plant der Planner EIN
    /// Objekt für die größte Platzierung. Der Dedup im Executor bleibt für
    /// Bilder, die erst durch die Transformation identisch werden. Scheitert
    /// das Zusammenführen, plant der Lauf wie bisher je Objekt – das
    /// Ergebnis bleibt korrekt, nur ohne diese Ersparnis.
    private static func mergeIdenticalImages(document: PDFCoreDocument,
                                             options: CompressionOptions) {
        guard options.dedupPolicy != .off else { return }
        do {
            _ = try document.deduplicateImages()
        } catch {
            NSLog("PDFTools: Bild-Dedup vor der Planung übersprungen: %@",
                  String(describing: error))
        }
    }

    static func run(inputURL: URL,
                    outputURL: URL,
                    options: CompressionOptions,
                    isCancelled: (() -> Bool)? = nil,
                    progress: ((Double) -> Void)? = nil,
                    stageTimer: StageTimer? = nil,
                    isolation: CompressionIsolation? = nil,
                    overrides: DecisionOverrides = DecisionOverrides(),
                    store: CandidateStore? = nil) throws -> Outcome {
        return try autoreleasepool {
            let document = try StageTimer.run(stageTimer, .openDocumentMs) {
                try PDFCoreDocument(path: inputURL.path)
            }
            StageTimer.run(stageTimer, .dedupMs) {
                mergeIdenticalImages(document: document, options: options)
            }
            let resources = try StageTimer.run(stageTimer, .inventoryMs) {
                try document.imageResources()
            }
            let pixels = LibQPDFPixelSource(document: document)
            // EINE Seitenanalyse je Lauf – MRC-Provision und Planner teilen sie.
            let analyses = pageAnalyses(document: document, resources: resources)

            // Fortschritt: Pixelarbeit (MRC + Kandidatensuche) bis 90 %, der
            // Executor füllt den Rest. Die Planung ist der teure Teil – ohne
            // Meldung stand der Balken fast die ganze Laufzeit am Anfang.
            let ledger = progress.map { report in
                WorkProgressLedger { report($0 * 0.9) }
            }
            ledger?.addWork(resources.reduce(0) {
                $0 + WorkProgressLedger.weight(pixels: $1.pixelCount)
            })

            // Phase V2-7 (§13) – MRC-Kandidaten für Scan-Seiten. Nur bei
            // Flag `mrc` (§25 – V2-Advanced, Default AUS); die Provision ist
            // reine Planung (Scratch-Rekonstruktionen).
            let mrc = try StageTimer.run(stageTimer, .candidateGenerationMs) {
                try MRCPageRewriter.provision(document: document,
                                              inputURL: inputURL,
                                              resources: resources,
                                              pixels: pixels,
                                              options: options,
                                              pageAnalyses: analyses,
                                              isCancelled: isCancelled,
                                              workProgress: ledger)
            }

            // Phase V2-8 (§14.1) – Font-Kandidaten über die Trockenplanung
            // der Bridge. Die Aktivierung steckt in FontOptimizer.provision
            // (Flags + Font-Politik, §25); ohne sie bleibt die Liste leer.
            let fonts = try StageTimer.run(stageTimer, .candidateGenerationMs) {
                try FontOptimizer.provision(document: document,
                                            options: options,
                                            isCancelled: isCancelled)
            }

            let planned = try CompressionPlanner.plan(
                resources: resources,
                options: options,
                documentID: inputURL.lastPathComponent,
                documentBytes: Int(Compressor.fileSize(of: inputURL)),
                pixels: pixels,
                isCancelled: isCancelled,
                stageTimer: stageTimer,
                overrides: overrides,
                store: store,
                mrc: mrc,
                fonts: fonts,
                pageAnalyses: analyses,
                workProgress: ledger)

            let execution = try CompressionExecutor.execute(
                plan: planned.plan,
                artifacts: planned.artifacts,
                document: document,
                pixels: pixels,
                resources: resources,
                outputURL: outputURL,
                isCancelled: isCancelled,
                progress: progress.map { report in { report(0.9 + $0 * 0.1) } },
                stageTimer: stageTimer,
                isolation: isolation,
                singleWrite: Self.singleWriteRequested(options: options))

            return Outcome(plan: planned.plan, execution: execution,
                           resources: resources,
                           classifications: planned.classifications)
        }
    }

    /// Ein Write nur, wo der CLI-Pass ohne Never-Grow-Interaktion abbildbar
    /// ist (V2-9, §15.6; seit V2-11 Default über die Flags):
    ///   • FlatePolicy .standard – Zopfli (Maximum, §15.7) bleibt Zwei-Write.
    ///   • CompatibilityPolicy .modern – im Kompatibilitätsmodus wird
    ///     Objekt-Streams DEAKTIVIERT; bei ObjStm-Eingängen expandiert das
    ///     und der Never-Grow-Vergleich des Struktur-Passes behielt images.pdf
    ///     (gemessen +2,7 %) – diese Interaktion bleibt im Zwei-Write-Pfad.
    /// Single-Write deckt den modernen Pfad (ObjStm generate) vollständig ab.
    /// Die beiden Ausnahmen sind die dokumentierten Zwei-Write-Fälle (§4.18).
    static func singleWriteRequested(options: CompressionOptions) -> Bool {
        options.candidateEngineActive
            && options.featureFlags.singleWrite
            && options.flatePolicy == .standard
            && options.compatibilityPolicy == .modern
    }

    /// Nur planen, ohne zu schreiben – für den Estimator und für Gate-Tests,
    /// die Entscheidungen prüfen statt Ergebnisse. Gleicher Dokument-Pool
    /// wie `run` (Phase 8). Overrides wie in `run` (V2-5, §11.5); `store`
    /// wie in `run` (V2-6, §12.6).
    static func plan(inputURL: URL,
                     options: CompressionOptions,
                     isCancelled: (() -> Bool)? = nil,
                     overrides: DecisionOverrides = DecisionOverrides(),
                     store: CandidateStore? = nil) throws -> CompressionPlanner.Result {
        return try autoreleasepool {
            let document = try PDFCoreDocument(path: inputURL.path)
            mergeIdenticalImages(document: document, options: options)
            let resources = try document.imageResources()
            let pixels = LibQPDFPixelSource(document: document)
            let analyses = pageAnalyses(document: document, resources: resources)
            // Phase V2-7/V2-8 – MRC- und Font-Provision exakt wie in `run`:
            // gleiche Aufrufe, gleiche Fehlerbehandlung (früher schluckte
            // `try?` hier Fehler, die `run` weiterwirft – zwei Pfade mit
            // unterschiedlichem Ausgang für dieselbe Eingabe).
            let mrc = try MRCPageRewriter.provision(document: document,
                                                    inputURL: inputURL,
                                                    resources: resources,
                                                    pixels: pixels,
                                                    options: options,
                                                    pageAnalyses: analyses,
                                                    isCancelled: isCancelled)
            let fonts = try FontOptimizer.provision(document: document,
                                                    options: options,
                                                    isCancelled: isCancelled)
            return try CompressionPlanner.plan(
                resources: resources,
                options: options,
                documentID: inputURL.lastPathComponent,
                documentBytes: Int(Compressor.fileSize(of: inputURL)),
                pixels: pixels,
                isCancelled: isCancelled,
                overrides: overrides,
                store: store,
                mrc: mrc,
                fonts: fonts,
                pageAnalyses: analyses)
        }
    }
}
