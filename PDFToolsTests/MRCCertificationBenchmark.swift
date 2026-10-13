import Testing
import Foundation
import CryptoKit
import PDFKit
@testable import PDFTools

/// V2-Advanced (Masterplan §26/§27) – MRC-Zertifizierung auf Scan-Material.
///
/// Je Scan-Datei der Smoke-30-Kategorien 06_Scans_Color / 07_Scans_Grayscale /
/// 08_Scans_Monochrome / 09_Scans_PhoneCamera × 2 Läufe:
///
///   • V2-Basis: Candidate-Engine ON (Produktionsstand seit V2-11),
///     `mrc` AUS – der Vergleichsarm.
///   • V2-MRC:   dieselben Optionen, `mrc` AN – der MRC-Kandidat läuft
///     als Candidate im Race gegen KEEP/Neukodierung (§13).
///
/// Gemessen wird (§13.10):
///   • Bytes produktionsgetreu über den `Compressor` (Struktur-Pass,
///     Validator, Never-Grow-Politik) – nicht über die Roh-Pipeline.
///   • Seiten-QA der FERTIGEN Ausgabe gegen die Quelle (PDFKit-Render:
///     SSIM global/p05, CAR, inkDelta) gegen den §13.10-Schranken – das
///     ist zugleich die Render-Verifikation der MRC-Layer (Masken-
///     Reihenfolge/Farben: Eine invertierte oder falsch platzierte Maske
///     crasht SSIM und die Papier-Luminanz).
///   • Laufzeiten über StageTimings (produktionsgetreue Zuschreibung).
///   • OCR-Erhalt (§13.2) über PDFSemanticSnapshot – je Seite, die der
///     Page-Classifier als `rasterScanWithOCR` sieht.
///   • Fallback-Gründe (Warum KEEP statt MRC?): Klassifikations-Gate,
///     Segmentierungs-Verweigerung, Masken-Kodierung, Size-Gate,
///     Seiten-QA, verlorene Race.
///
/// Zusätzlich pro Datei: Byteidentität der Ausgaben beider Arme, wenn kein
/// MRC ausgeführt wurde (der Fallback muss die Basis reproduzieren).
///
/// Aufruf (nicht Teil der normalen Suite, env-gated wie V2Certification):
///
///     TEST_RUNNER_PDFTOOLS_MRC_CERT=1 \
///     TEST_RUNNER_PDFTOOLS_MRC_CERT_OUT=<dir> \
///     TEST_RUNNER_PDFTOOLS_MRC_CERT_CORPUS=<resolved smoke30> \
///     xcodebuild ... -only-testing:PDFToolsTests/MRCCertificationBenchmark
///
/// Die Kennzahlen (Bytes, QA-Messwerte, Timings) sind deterministisch –
/// dieselben Eingaben erzeugen dieselben Werte; nur das Run-Meta trägt
/// eine Zeitmarke. `PDFTOOLS_MRC_CERT_EXTRA` akzeptiert eine kommasepa-
/// rierte Liste zusätzlicher Dateipfade (Robustheit, großer Korpus,
/// NUR LESEN).
@Suite struct MRCCertificationBenchmark {

    private static let modes: [CompressionMode] = [.smart]
    private static let operationTimeout: TimeInterval = 600
    private static let hardTimeout: TimeInterval = 660

    // MARK: - Aufzeichnungen

    struct PageClassRecord: Codable {
        var pageIndex: Int
        var classification: String
        var confidence: Double
        var imageCount: Int
        var largestCoverage: Double
        var scanDPI: Double?
    }

    struct PageQualityRecord: Codable {
        var pageIndex: Int
        /// true = Auf dieser Seite wurde ein MRC-Bündel ausgeführt; nur
        /// solche Seiten unterliegen der §13.10-Bewertung. Seiten ohne MRC
        /// sind Referenz (Basis-/Normalpfad-Qualität, Bildmatrix-Gates).
        var mrcPage: Bool
        /// End-to-End-Seiten-QA der FERTIGEN Ausgabe (§13.10).
        var globalSSIM: Double
        var p05TileSSIM: Double
        var changedAreaRatio: Double
        var meanAbsDiff: Double
        var inkDelta: Double
        var meetsScanLimits: Bool
        /// Farb-/Masken-Verifikation: Median-Luminanz Quelle vs. Ausgabe.
        var paperLumaSource: Double
        var paperLumaOutput: Double
        /// OCR-Erhalt (§13.2) – nur auf `rasterScanWithOCR`-Seiten befüllt.
        var ocrChecked: Bool
        var ocrPreserved: Bool
        var ocrCharsBefore: Int
        var ocrCharsAfter: Int
    }

    struct MRCDecisionRecord: Codable {
        var pageIndex: Int
        var rung: String
        var candidateID: String
        var chosen: Bool
        var bundleBytes: Int
        var originalRasterBytes: Int
        /// Kandidatenmetriken – gemessen an der Scratch-Rekonstruktion
        /// (§13.10-QA der Planung).
        var globalSSIM: Double
        var p05TileSSIM: Double
        var changedAreaRatio: Double
        var reason: String
    }

    struct FallbackRecord: Codable {
        var pageIndex: Int
        var classifiedAsScan: Bool
        var reason: String
    }

    struct RunRecord: Codable {
        var engine: String          // "V2-Basis" | "V2-MRC"
        var category: String
        var fileName: String
        var inputBytes: Int64
        var outputBytes: Int64
        var savedPercent: Double
        var runtimeSeconds: Double
        var stageTimings: StageTimings
        var returnedOriginal: Bool
        var success: Bool
        var error: String
        var qpdfCheck: String
        var pdfkitOpen: Bool
        var pagesBefore: Int
        var pagesAfter: Int
        var outputSHA256: String
        // MRC-Arm:
        var mrcPagesExecuted: Int
        var mrcCandidateCount: Int
        /// Plan-Parität: Alle NICHT-MRC-Ressourcenentscheidungen identisch
        /// zur Basis-Planung (der Fallback darf die Wahl nicht verschieben).
        var planParity: Bool
        var mrcDecisions: [MRCDecisionRecord]
        var fallbacks: [FallbackRecord]
        var pageClasses: [PageClassRecord]
        var pageQualities: [PageQualityRecord]
        /// true, wenn die MRC-Ausgabe byteidentisch zur Basis-Ausgabe ist
        /// (erwartet genau dann, wenn kein MRC ausgeführt wurde – der
        /// Fallback muss die Basis reproduzieren).
        var outputEqualsBasis: Bool
    }

    struct CategoryAggregate: Codable {
        var category: String
        var engine: String
        var files: Int
        var successful: Int
        var totalInputBytes: Int64
        var totalOutputBytes: Int64
        var weightedSavingPercent: Double
        var medianRuntimeSeconds: Double
        var mrcPagesExecuted: Int
    }

    struct CertMeta: Codable {
        var schema: Int
        var runID: String
        var corpus: String
        var categories: [String]
        var preset: String
        var engineBasis: String
        var engineMRC: String
        var scanLimits: [String: Double]
    }

    @Test(.measurementRun) func certifyScanMaterialBasisAgainstMRC() async throws {
        let env = ProcessInfo.processInfo.environment
        let on = env["PDFTOOLS_MRC_CERT"] ?? env["TEST_RUNNER_PDFTOOLS_MRC_CERT"]
        guard on == "1" else { return }

        let fm = FileManager.default
        let corpus = URL(fileURLWithPath: env["PDFTOOLS_MRC_CERT_CORPUS"]
            ?? env["TEST_RUNNER_PDFTOOLS_MRC_CERT_CORPUS"]
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("PDFToolsCertCorpus/smoke30-resolved").path)
        guard fm.fileExists(atPath: corpus.path) else {
            Issue.record("Zertifizierungskorpus fehlt: \(corpus.path)")
            return
        }

        let runID = Self.utcTimestamp()
        let outRoot = URL(fileURLWithPath: env["PDFTOOLS_MRC_CERT_OUT"]
            ?? env["TEST_RUNNER_PDFTOOLS_MRC_CERT_OUT"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("mrc-cert-\(runID)").path)
        let outputsBasis = outRoot.appendingPathComponent("outputs_basis")
        let outputsMRC = outRoot.appendingPathComponent("outputs_mrc")
        let errorsDir = outRoot.appendingPathComponent("errors")
        for dir in [outputsBasis, outputsMRC, errorsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Jobs: die vier Scan-Kategorien des resolved Smoke-30 plus
        // optionale Zusatzdateien (Robustheit, großer Korpus – NUR LESEN).
        var jobs: [(category: String, file: URL)] = []
        for category in Self.scanCategories(corpus: corpus, fm: fm) {
            let dir = corpus.appendingPathComponent(category)
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".pdf") && !$0.hasPrefix(".") }
                .sorted()
            for f in files { jobs.append((category, dir.appendingPathComponent(f))) }
        }
        for extra in Self.extraFiles(env: env) {
            jobs.append(("Extra", extra))
        }
        guard !jobs.isEmpty else {
            Issue.record("Keine Scan-PDFs im Zertifizierungskorpus.")
            return
        }

        let compressor = Compressor()
        let qpdf = Self.repoRoot.appendingPathComponent("Vendor/qpdf/qpdf").path
        var records: [RunRecord] = []

        for mode in Self.modes {
            for job in jobs {
                let inputBytes = (try? fm.attributesOfItem(
                    atPath: job.file.path))?[.size] as? Int64 ?? 0
                let pagesBefore = Self.pageCount(qpdfPath: qpdf, url: job.file)

                // ── Arm 1: V2-Basis (mrc AUS) ────────────────────────────
                var basisOptions = CompressionOptions.make(
                    mode: mode, customConfig: nil, stripMetadata: false,
                    linearize: false)
                basisOptions.featureFlags.candidateEngine = true
                // basisOptions.featureFlags.mrc bleibt false (Produktion).
                let basis = try Self.runOne(
                    compressor: compressor, qpdfPath: qpdf, input: job.file,
                    category: job.category, mode: mode, engine: "V2-Basis",
                    options: basisOptions,
                    outputsDir: outputsBasis, errorsDir: errorsDir,
                    inputBytes: inputBytes, pagesBefore: pagesBefore,
                    fm: fm)

                // ── Arm 2: V2-MRC (mrc AN) ───────────────────────────────
                var mrcOptions = basisOptions
                mrcOptions.featureFlags.mrc = true
                var mrc = try Self.runOne(
                    compressor: compressor, qpdfPath: qpdf, input: job.file,
                    category: job.category, mode: mode, engine: "V2-MRC",
                    options: mrcOptions,
                    outputsDir: outputsMRC, errorsDir: errorsDir,
                    inputBytes: inputBytes, pagesBefore: pagesBefore,
                    fm: fm)
                mrc.outputEqualsBasis = basis.outputSHA256 == mrc.outputSHA256

                // Planung + Seiten-QA + OCR nur im MRC-Arm.
                if basis.success, mrc.success {
                    let planned = try CompressionPipeline.plan(
                        inputURL: job.file, options: mrcOptions)
                    let plan = planned.plan
                    mrc.mrcPagesExecuted = plan.actions.filter {
                        if case .mrc = $0 { return true }
                        return false
                    }.count
                    mrc.mrcCandidateCount = plan.candidateSets.reduce(0) {
                        $0 + $1.candidates.filter { candidate in
                            if case .mrc = candidate.kind { return true }
                            return false
                        }.count
                    }
                    mrc.mrcDecisions = Self.mrcDecisions(plan: plan)
                    mrc.fallbacks = Self.fallbackReasons(
                        input: job.file, plan: plan)
                    mrc.pageClasses = Self.pageClasses(input: job.file)
                    // Plan-Parität: Die Basis-Planung (ohne MRC-Kandidaten)
                    // muss in allen NICHT-MRC-Entscheidungen denselben
                    // Kandidaten wählen wie die MRC-Planung.
                    let basisPlanned = try CompressionPipeline.plan(
                        inputURL: job.file, options: basisOptions)
                    mrc.planParity = Self.planParity(basis: basisPlanned.plan,
                                                     mrc: plan)
                    if let mrcOutput = Self.copiedOutput(
                        record: mrc, outputsDir: outputsMRC, fm: fm) {
                        let executedPages = Set(plan.actions.compactMap {
                            action -> Int? in
                            if case .mrc(_, let descriptor, _, _) = action {
                                return descriptor.pageIndex
                            }
                            return nil
                        })
                        mrc.pageQualities = Self.pageQualities(
                            source: job.file, output: mrcOutput,
                            classes: mrc.pageClasses,
                            mrcPages: executedPages)
                    }
                }

                records.append(basis)
                records.append(mrc)
                print("MRC CERT: \(job.category)/\(job.file.lastPathComponent) "
                      + "Basis=\(basis.outputBytes)B MRC=\(mrc.outputBytes)B "
                      + "mrcSeiten=\(mrc.mrcPagesExecuted)")
            }
        }

        let aggregates = Self.aggregate(records)
        let fallbackCounts = Self.fallbackCounts(records)
        let meta = Self.meta(runID: runID, corpus: corpus.path, jobs: jobs)
        try Self.writeJSON(meta: meta, aggregates: aggregates,
                           fallbacks: fallbackCounts, records: records,
                           to: outRoot)
        try Self.writeReport(meta: meta, aggregates: aggregates,
                             fallbacks: fallbackCounts, records: records,
                             to: outRoot)
        print("MRC CERT DONE: \(records.count) Läufe → \(outRoot.path)")
    }

    // MARK: - Kategorien

    /// Die vier Scan-Kategorien des Smoke-30-Korpus (06–09); fehlende
    /// Kategorien werden still übersprungen.
    private static func scanCategories(corpus: URL,
                                       fm: FileManager) -> [String] {
        let wanted = ["06_Scans_Color", "07_Scans_Grayscale",
                      "08_Scans_Monochrome", "09_Scans_PhoneCamera"]
        return wanted.filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: corpus.appendingPathComponent($0).path,
                                 isDirectory: &isDir) && isDir.boolValue
        }
    }

    private static func extraFiles(env: [String: String]) -> [URL] {
        guard let list = env["PDFTOOLS_MRC_CERT_EXTRA"]
            ?? env["TEST_RUNNER_PDFTOOLS_MRC_CERT_EXTRA"], !list.isEmpty
        else { return [] }
        return list.split(separator: ",").map(String.init)
            .map { URL(fileURLWithPath: $0.trimmingCharacters(
                in: .whitespaces)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Einzellauf

    private static func runOne(compressor: Compressor,
                               qpdfPath: String,
                               input: URL,
                               category: String,
                               mode: CompressionMode,
                               engine: String,
                               options: CompressionOptions,
                               outputsDir: URL,
                               errorsDir: URL,
                               inputBytes: Int64? = nil,
                               pagesBefore: Int? = nil,
                               fm: FileManager) throws -> RunRecord {
        let inBytes = inputBytes ?? ((try? fm.attributesOfItem(
            atPath: input.path))?[.size] as? Int64 ?? 0)
        let pageCountBefore = pagesBefore
            ?? pageCount(qpdfPath: qpdfPath, url: input)
        let timer = StageTimer()
        let started = Date()
        let deadline = Date().addingTimeInterval(operationTimeout)

        var result: CompressionResult?
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                result = try compressor.compress(
                    inputURL: input, options: options, isCancelled: {
                        Date() > deadline
                    }, stageTimer: timer)
            } catch {
                failure = error
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + hardTimeout)
        if semaphore.wait(timeout: .now() + .zero) == .timedOut {
            task.cancel()
        }
        let runtime = Date().timeIntervalSince(started)

        var rec = RunRecord(
            engine: engine, category: category,
            fileName: input.lastPathComponent,
            inputBytes: inBytes, outputBytes: 0, savedPercent: 0,
            runtimeSeconds: runtime, stageTimings: timer.timings,
            returnedOriginal: false, success: false, error: "",
            qpdfCheck: "not-run", pdfkitOpen: false,
            pagesBefore: pageCountBefore, pagesAfter: -1,
            outputSHA256: "", mrcPagesExecuted: -1, mrcCandidateCount: -1,
            planParity: true,
            mrcDecisions: [], fallbacks: [], pageClasses: [],
            pageQualities: [], outputEqualsBasis: false)

        guard let r = result, failure == nil else {
            rec.error = Self.errorText(failure)
                + (result == nil && failure == nil
                    ? "TIMEOUT nach \(Int(hardTimeout))s" : "")
            rec.outputBytes = inBytes
            try? rec.error.data(using: .utf8)?.write(to: errorsDir
                .appendingPathComponent("\(engine)__\(category)__"
                    + "\(input.lastPathComponent)__\(mode.rawValue).txt"))
            return rec
        }

        let deliveredURL = r.returnedOriginal ? input : r.outputURL
        let deliveredBytes = (try? fm.attributesOfItem(
            atPath: deliveredURL.path))?[.size] as? Int64 ?? 0
        rec.outputBytes = r.outputBytes > 0 ? r.outputBytes : deliveredBytes
        rec.savedPercent = inBytes > 0
            ? (1.0 - Double(rec.outputBytes) / Double(inBytes)) * 100 : 0
        rec.returnedOriginal = r.returnedOriginal
        rec.pagesAfter = pageCount(qpdfPath: qpdfPath, url: deliveredURL)
        rec.pdfkitOpen = PDFDocument(url: deliveredURL) != nil
        rec.qpdfCheck = qpdfCheck(qpdfPath: qpdfPath, url: deliveredURL)
        rec.outputSHA256 = normalizedPDFHash(url: deliveredURL,
                                             qpdfPath: qpdfPath)

        rec.success = deliveredBytes > 0 && rec.pdfkitOpen
            && (pageCountBefore > 0
                ? rec.pagesAfter == pageCountBefore : rec.pagesAfter > 0)
            && !rec.qpdfCheck.hasPrefix("fatal")

        // Output behalten – Namensschema wie der Smoke-Runner.
        let stem = input.deletingPathExtension().lastPathComponent
        let target = outputsDir.appendingPathComponent(
            "\(category)__\(stem)__\(mode.rawValue).pdf")
        try? fm.removeItem(at: target)
        _ = try? fm.copyItem(at: deliveredURL, to: target)

        if !rec.success {
            try? "success=false pages \(rec.pagesBefore)->\(rec.pagesAfter)"
                .data(using: .utf8)?.write(to: errorsDir
                    .appendingPathComponent("\(engine)__\(category)__"
                        + "\(input.lastPathComponent)__\(mode.rawValue).txt"))
        }
        return rec
    }

    /// Die behaltene Ausgabe-Einzelkopie eines MRC-Laufs (Namensschema
    /// wie oben) – Quelle der End-to-End-Seiten-QA.
    private static func copiedOutput(record: RunRecord,
                                     outputsDir: URL,
                                     fm: FileManager) -> URL? {
        let stem = (record.fileName as NSString).deletingPathExtension
        let name = "\(record.category)__\(stem)__smart.pdf"
        let url = outputsDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - MRC-Entscheidungen (Plan)

    /// QA-bestandene MRC-Stufen je Seite und ob die Race-Wahl sie nahm.
    private static func mrcDecisions(plan: CompressionPlan)
        -> [MRCDecisionRecord] {
        var decisionsByResource: [String: ResourceDecision] = [:]
        for decision in plan.decisions {
            decisionsByResource[decision.resourceID] = decision
        }
        var records: [MRCDecisionRecord] = []
        for set in plan.candidateSets {
            for candidate in set.candidates {
                guard case .mrc(let descriptor) = candidate.kind else { continue }
                let chosen = decisionsByResource[set.resourceID]?
                    .selectedCandidateID == candidate.id
                records.append(MRCDecisionRecord(
                    pageIndex: descriptor.pageIndex,
                    rung: rungName(of: candidate),
                    candidateID: candidate.id.rawValue,
                    chosen: chosen,
                    bundleBytes: candidate.metrics.encodedBytes,
                    originalRasterBytes: originalRasterBytes(
                        plan: plan, objectID: candidate.objectID),
                    globalSSIM: candidate.metrics.globalSSIM ?? 0,
                    p05TileSSIM: candidate.metrics.p05TileSSIM ?? 0,
                    changedAreaRatio: 1 - (candidate.metrics.edgeScore ?? 0),
                    reason: candidate.reason))
            }
        }
        return records
    }

    private static func rungName(of candidate: CompressionCandidate) -> String {
        // CandidateID "mrc-<obj>-<gen>-<rung>" – der letzte Bindestrich-
        // Bestandteil ist die Stufe (MRCPageRewriter.candidate).
        let parts = candidate.id.rawValue.split(separator: "-")
        return parts.count >= 4 ? String(parts[3]) : parts.last.map(String.init)
            ?? "?"
    }

    private static func originalRasterBytes(plan: CompressionPlan,
                                            objectID: PDFObjectID?) -> Int {
        guard let objectID else { return -1 }
        for action in plan.actions where action.objectID == objectID {
            if case .mrc(_, _, let original, _) = action { return original }
        }
        return -1
    }

    // MARK: - Fallback-Gründe

    /// Warum wurde eine Seite nicht MRC-optimiert? Kette der dokumentierten
    /// Gates (§13.1/§13.4/§13.5/§13.10) – Attribution durch Nachvollziehen:
    ///   1. Klassifikations-/Platzierungs-Gate (§13.1)
    ///   2. QA-bestandene Stufe da, Wahl fiel auf einen anderen Kandidaten
    ///      (Race verloren – dokumentierte Wahl)
    ///   3. Segmentierungs-Verweigerung (§13.5)
    ///   4. Masken-Kodierung verworfen (Bitidentitäts-Gate)
    ///   5. Kein Byte-Gewinn (Bundle ≥ Original-Raster)
    ///   6. Seiten-QA verworfen (§13.10) – Ausschlussverfahren
    private static func fallbackReasons(input: URL,
                                        plan: CompressionPlan)
        -> [FallbackRecord] {
        var records: [FallbackRecord] = []
        guard let document = try? PDFCoreDocument(path: input.path),
              let analyses = try? PageScanAnalyzer.analyze(document: document)
        else { return records }
        let executedPages = Set(plan.actions.compactMap { action -> Int? in
            if case .mrc(_, let descriptor, _, _) = action {
                return descriptor.pageIndex
            }
            return nil
        })
        let candidatePages = Set(plan.candidateSets.flatMap { set in
            set.candidates.flatMap { candidate -> [Int] in
                if case .mrc = candidate.kind { return candidate.pages }
                return []
            }
        })

        for page in analyses {
            guard executedPages.contains(page.pageIndex) == false else { continue }
            let eligible = Self.eligible(page)
            if !eligible {
                records.append(FallbackRecord(
                    pageIndex: page.pageIndex, classifiedAsScan: false,
                    reason: "Klassifikations-/Platzierungs-Gate (§13.1): "
                        + "\(page.classification.rawValue) conf "
                        + String(format: "%.2f", page.confidence)
                        + " coverage "
                        + String(format: "%.2f", page.largestImageCoverageRatio)
                        + " images \(page.imageCount)"))
                continue
            }
            if candidatePages.contains(page.pageIndex) {
                records.append(FallbackRecord(
                    pageIndex: page.pageIndex, classifiedAsScan: true,
                    reason: "Race verloren: MRC-Stufe QA-bestanden, die Wahl "
                        + "nahm einen kleineren/günstigeren Kandidaten"))
                continue
            }
            records.append(FallbackRecord(
                pageIndex: page.pageIndex, classifiedAsScan: true,
                reason: noCandidateReason(input: input,
                                          pageIndex: page.pageIndex)))
        }
        return records
    }

    /// §13.1-Gate an der PageAnalysis – dieselben Schranken wie
    /// MRCPageRewriter.provision.
    private static func eligible(_ page: PageAnalysis) -> Bool {
        (page.classification == .rasterScan
            || page.classification == .rasterScanWithOCR)
            && page.confidence >= MRCPageRewriter.minimumScanConfidence
            && page.imageCount == 1
            && page.largestImageCoverageRatio >= 0.90
            && (page.scanDPI ?? 0) >= 100
    }

    /// Plan-Parität: Je Ressource derselbe gewählte Kandidat wie in der
    /// Basis-Planung – ausgenommen Ressourcen, deren MRC-Kandidat die Wahl
    /// gewonnen hat (dort ist die Abweichung der SINN der Option).
    private static func planParity(basis: CompressionPlan,
                                   mrc: CompressionPlan) -> Bool {
        let mrcWonObjects = Set(mrc.actions.compactMap { action -> PDFObjectID? in
            if case .mrc(let objectID, _, _, _) = action { return objectID }
            return nil
        })
        var basisByID: [String: CandidateID] = [:]
        for decision in basis.decisions {
            basisByID[decision.resourceID] = decision.selectedCandidateID
        }
        for decision in mrc.decisions {
            guard let expected = basisByID[decision.resourceID] else {
                return false
            }
            let isMRCWinner = mrcWonObjects.contains { objectID in
                CandidateSet.resourceID(for: objectID) == decision.resourceID
            }
            if !isMRCWinner, decision.selectedCandidateID != expected {
                return false
            }
        }
        return true
    }

    /// Ressourcen-Gates aus MRCPageRewriter.pageEligible – VOR der
    /// Segmentierung greifende Gründe (billig zu prüfen, deterministisch).
    /// nil = kein Ressourcen-Grund, weiter zur Segmentierungs-Attribution.
    private static func resourceGateReason(input: URL,
                                           pageIndex: Int) -> String? {
        autoreleasepool {
            guard let document = try? PDFCoreDocument(path: input.path),
                  let resources = try? document.imageResources()
            else { return "Dokument nicht lesbar" }
            guard let resource = resources.first(where: {
                $0.placements.count == 1
                    && $0.placements.first?.pageIndex == pageIndex
            }) else {
                return "Ressourcen-Gate: kein Einzel-Vollbild-Raster "
                    + "(mehrere Platzierungen oder geteilt)"
            }
            if !resource.transformCapability.isSafe {
                return "Transform-Gate: \(resource.transformCapability.reason)"
            }
            if resource.bitsPerComponent != 8 {
                return "Bittiefen-Gate: \(resource.bitsPerComponent) bit – "
                    + "1-bit-Raster gehören dem verlustfreien Bilevel-Race "
                    + "(§9.7), nicht MRC"
            }
            if !resource.colorSpace.allowsLossyReplacement {
                return "Farbraum-Gate: Druckfarbe (CMYK) bleibt erhalten "
                    + "(V1-Grenze §13.4)"
            }
            if resource.maxEdge < CompressionPlanner.minimumTransformableEdge
                || resource.pixelCount > CompressionPlanner
                    .maximumDecodablePixels {
                return "Größen-Gate: \(resource.maxEdge) px Kante / "
                    + "\(resource.pixelCount) px Fläche"
            }
            return nil
        }
    }

    /// Ausschlussverfahren für „kein Kandidat": Ressourcen-Gates →
    /// Segmentierung → Masken-Kodierung → Byte-Gewinn. Was übrig bleibt,
    /// hat die Seiten-QA verworfen (dieselbe Reihenfolge wie in
    /// MRCPageRewriter.buildProvision).
    private static func noCandidateReason(input: URL,
                                          pageIndex: Int) -> String {
        if let resourceReason = resourceGateReason(input: input,
                                                   pageIndex: pageIndex) {
            return resourceReason
        }
        return autoreleasepool {
            guard let document = try? PDFCoreDocument(path: input.path),
                  let resources = try? document.imageResources(),
                  let resource = resources.first(where: {
                      $0.placements.count == 1
                          && $0.placements.first?.pageIndex == pageIndex
                  })
            else { return "Ressource nicht auffindbar" }
            let pixels = LibQPDFPixelSource(document: document)
            guard let raster = pixels.decodedImage(for: resource) else {
                return "Raster nicht dekodierbar"
            }
            guard let segmentation = MRCSegmenter.segment(raster) else {
                return "Segmentierung verweigert (§13.5): nicht segmentierbar"
            }
            guard let mask = MRCEncoder.encodeMask(segmentation.mask) else {
                return "Masken-Kodierung verworfen (Bitidentitäts-Gate)"
            }
            let sourceDPI = scanDPI(input: input, pageIndex: pageIndex)
            guard sourceDPI >= 100 else {
                return "Scan-DPI nicht messbar (< 100)"
            }
            for rung in MRCEncoder.ladder(for: .smart) {
                if let layers = MRCEncoder.encodeLayers(
                    segmentation: segmentation, mask: mask, rung: rung,
                    sourceDPI: sourceDPI),
                   layers.totalBytes < resource.encodedByteCount {
                    // Eine Stufe hätte Bytes gewonnen → die Seiten-QA muss
                    // verworfen haben (Reihenfolge in buildProvision).
                    return "Seiten-QA verworfen (§13.10): alle Stufen unter "
                        + "der SSIM/p05/inkDelta-Grenze"
                }
            }
            return "Kein Byte-Gewinn: Bundle ≥ Original-Raster (§13.9)"
        }
    }

    private static func scanDPI(input: URL, pageIndex: Int) -> Double {
        guard let document = try? PDFCoreDocument(path: input.path),
              let analyses = try? PageScanAnalyzer.analyze(document: document),
              pageIndex < analyses.count else { return 0 }
        return analyses[pageIndex].scanDPI ?? 0
    }

    // MARK: - Seiten-Klassifikation + End-to-End-Seiten-QA

    /// Seitenklassifikation des Page-Scanners (§5.4/§8.4) – Grundlage der
    /// OCR-Prüfung und der Fallback-Attribution.
    private static func pageClasses(input: URL) -> [PageClassRecord] {
        guard let document = try? PDFCoreDocument(path: input.path),
              let analyses = try? PageScanAnalyzer.analyze(document: document)
        else { return [] }
        return analyses.map {
            PageClassRecord(
                pageIndex: $0.pageIndex,
                classification: $0.classification.rawValue,
                confidence: $0.confidence,
                imageCount: $0.imageCount,
                largestCoverage: $0.largestImageCoverageRatio,
                scanDPI: $0.scanDPI)
        }
    }

    /// MRCPageQA auf der FERTIGEN Ausgabe (nicht der Scratch-Rekonstruktion)
    /// plus Farb- und OCR-Verifikation. Aufgerufen für den MRC-Arm; die
    /// MRC-Ausgabe muss die §13.10-Grenzen an der echten Datei halten.
    private static func pageQualities(source: URL,
                                      output: URL,
                                      classes: [PageClassRecord],
                                      mrcPages: Set<Int>)
        -> [PageQualityRecord] {
        var records: [PageQualityRecord] = []
        guard let sourceDoc = PDFDocument(url: source),
              let outputDoc = PDFDocument(url: output) else { return records }
        let sourceSnapshot = try? PDFSemanticSnapshot.capture(source)
        let outputSnapshot = try? PDFSemanticSnapshot.capture(output)

        for index in 0..<min(sourceDoc.pageCount, outputDoc.pageCount) {
            autoreleasepool {
                var rec = PageQualityRecord(
                    pageIndex: index, mrcPage: mrcPages.contains(index),
                    globalSSIM: 0, p05TileSSIM: 0,
                    changedAreaRatio: 0, meanAbsDiff: 0, inkDelta: 0,
                    meetsScanLimits: false, paperLumaSource: 0,
                    paperLumaOutput: 0, ocrChecked: false,
                    ocrPreserved: false, ocrCharsBefore: 0, ocrCharsAfter: 0)

                if let quality = MRCPageQA.measure(sourceURL: source,
                                                   outputURL: output,
                                                   pageIndex: index) {
                    rec.globalSSIM = quality.globalSSIM
                    rec.p05TileSSIM = quality.p05TileSSIM
                    rec.changedAreaRatio = quality.changedAreaRatio
                    rec.meanAbsDiff = quality.meanAbsDiff
                    rec.inkDelta = quality.inkDelta
                    rec.meetsScanLimits = quality.meetsScanLimits
                }
                let luma = Self.paperLuma(sourcePage: sourceDoc.page(at: index),
                                          outputPage: outputDoc.page(at: index))
                rec.paperLumaSource = luma.source
                rec.paperLumaOutput = luma.output

                let isOCRPage = classes.first {
                    $0.pageIndex == index
                }?.classification == PageContentClass.rasterScanWithOCR.rawValue
                if isOCRPage,
                   sourceSnapshot?.pages.count ?? 0 > index,
                   outputSnapshot?.pages.count ?? 0 > index {
                    let before = sourceSnapshot!.pages[index]
                    let after = outputSnapshot!.pages[index]
                    rec.ocrChecked = true
                    rec.ocrPreserved = before.textFingerprint
                        == after.textFingerprint
                        && before.textCharacterCount == after.textCharacterCount
                    rec.ocrCharsBefore = before.textCharacterCount
                    rec.ocrCharsAfter = after.textCharacterCount
                }
                records.append(rec)
            }
        }
        return records
    }

    /// Median-Luminanz beider Seiten je 150-DPI-Render (gleiche Herleitung
    /// wie MRCPageQA.lumaBuffer). Eine invertierte/falsch farbige Maske
    /// würde die Papier-Helligkeit der Ausgabe zerstören.
    private static func paperLuma(sourcePage: PDFPage?,
                                  outputPage: PDFPage?) -> (source: Double,
                                                            output: Double) {
        (medianLuma(sourcePage), medianLuma(outputPage))
    }

    private static func medianLuma(_ page: PDFPage?) -> Double {
        guard let page else { return -1 }
        return autoreleasepool {
            let scale = Double(MRCPageQA.renderDPI) / 72.0
            var w = Int((page.bounds(for: .mediaBox).width * scale).rounded())
            var h = Int((page.bounds(for: .mediaBox).height * scale).rounded())
            let cap = Double(MRCPageQA.maximumRenderEdge)
                / Double(max(w, h, 1))
            if cap < 1 {
                w = max(1, Int((Double(w) * cap).rounded()))
                h = max(1, Int((Double(h) * cap).rounded()))
            }
            let thumbnail = page.thumbnail(
                of: CGSize(width: w, height: h), for: .mediaBox)
            guard let image = thumbnail.cgImage(forProposedRect: nil,
                                                context: nil, hints: nil),
                  let luma = Self.lumaBuffer(image) else { return -1 }
            var histogram = [Int](repeating: 0, count: 256)
            for value in luma { histogram[Int(value)] += 1 }
            var seen = 0
            let half = luma.count / 2
            for value in 0..<256 {
                seen += histogram[value]
                if seen > half { return Double(value) }
            }
            return -1
        }
    }

    /// Luminanz-Puffer (8 Bit) – gleiche Herleitung wie MRCPageQA.
    private static func lumaBuffer(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo
                                      .premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var luma = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            luma[i] = UInt8(clamping: (299 * Int(px[o]) + 587 * Int(px[o + 1])
                                       + 114 * Int(px[o + 2])) / 1000)
        }
        return luma
    }

    // MARK: - Aggregation

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = Double(sorted.count - 1) * p
        let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - Double(lo))
    }

    private static func aggregate(_ records: [RunRecord]) -> [CategoryAggregate] {
        var out: [CategoryAggregate] = []
        let categories = Set(records.map(\.category)).sorted()
        for category in categories {
            for engine in ["V2-Basis", "V2-MRC"] {
                let group = records.filter {
                    $0.engine == engine && $0.category == category
                }
                guard !group.isEmpty else { continue }
                let ok = group.filter(\.success)
                let inTotal = group.reduce(Int64(0)) { $0 + $1.inputBytes }
                let outTotal = group.reduce(Int64(0)) { $0 + $1.outputBytes }
                let runtimes = ok.map(\.runtimeSeconds)
                out.append(CategoryAggregate(
                    category: category, engine: engine, files: group.count,
                    successful: ok.count, totalInputBytes: inTotal,
                    totalOutputBytes: outTotal,
                    weightedSavingPercent: inTotal > 0
                        ? (1.0 - Double(outTotal) / Double(inTotal)) * 100 : 0,
                    medianRuntimeSeconds: percentile(runtimes, 0.5),
                    mrcPagesExecuted: group.reduce(0) {
                        $0 + max(0, $1.mrcPagesExecuted)
                    }))
            }
        }
        return out
    }

    private static func fallbackCounts(_ records: [RunRecord])
        -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in records where record.engine == "V2-MRC" {
            for fallback in record.fallbacks {
                counts[fallbackKey(fallback.reason), default: 0] += 1
            }
        }
        return counts
    }

    /// Kurzer, stabiler Schlüssel je Grundklasse (deterministisch).
    private static func fallbackKey(_ reason: String) -> String {
        if reason.hasPrefix("Klassifikations") { return "Klassifikations-Gate" }
        if reason.hasPrefix("Race verloren") { return "Race verloren" }
        if reason.hasPrefix("Segmentierung") {
            return "Segmentierung verweigert"
        }
        if reason.hasPrefix("Masken") { return "Masken-Kodierung verworfen" }
        if reason.hasPrefix("Seiten-QA") { return "Seiten-QA verworfen" }
        if reason.hasPrefix("Kein Byte-Gewinn") { return "Kein Byte-Gewinn" }
        if reason.hasPrefix("Scan-DPI") { return "Scan-DPI nicht messbar" }
        if reason.hasPrefix("Bittiefen-Gate") { return "Bittiefen-Gate (1-bit → Bilevel-Race)" }
        if reason.hasPrefix("Transform-Gate") { return "Transform-Gate" }
        if reason.hasPrefix("Farbraum-Gate") { return "Farbraum-Gate (CMYK)" }
        if reason.hasPrefix("Ressourcen-Gate") { return "Ressourcen-Gate (kein Einzel-Vollbild)" }
        if reason.hasPrefix("Größen-Gate") { return "Größen-Gate" }
        if reason.hasPrefix("Raster nicht dekodierbar") {
            return "Raster nicht dekodierbar"
        }
        return reason
    }

    private static func meta(runID: String, corpus: String,
                             jobs: [(category: String, file: URL)]) -> CertMeta {
        CertMeta(
            schema: 1, runID: runID, corpus: corpus,
            categories: Set(jobs.map { $0.category }).sorted(),
            preset: Self.modes.map(\.rawValue).joined(separator: ","),
            engineBasis: "candidateEngine ON, mrc AUS (Produktionsstand)",
            engineMRC: "candidateEngine ON, mrc ON",
            scanLimits: ["minimumGlobalSSIM": MRCPageQA.minimumGlobalSSIM,
                         "minimumP05TileSSIM": MRCPageQA.minimumP05TileSSIM,
                         "maximumInkDelta": MRCPageQA.maximumInkDelta])
    }

    // MARK: - Artefakte

    private static func writeJSON(meta: CertMeta,
                                  aggregates: [CategoryAggregate],
                                  fallbacks: [String: Int],
                                  records: [RunRecord],
                                  to outRoot: URL) throws {
        struct Top: Codable {
            var meta: CertMeta
            var categoryByEngine: [CategoryAggregate]
            var fallbackReasons: [String: Int]
            var records: [RunRecord]
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(Top(meta: meta, categoryByEngine: aggregates,
                           fallbackReasons: fallbacks, records: records))
            .write(to: outRoot.appendingPathComponent("summary.json"),
                   options: [.atomic])
    }

    private static func writeReport(meta: CertMeta,
                                    aggregates: [CategoryAggregate],
                                    fallbacks: [String: Int],
                                    records: [RunRecord],
                                    to outRoot: URL) throws {
        func bytes(_ b: Int64) -> String {
            b >= 1_048_576
                ? String(format: "%.2f MB", Double(b) / 1_048_576)
                : String(format: "%.1f KB", Double(b) / 1024)
        }
        var md = "# MRC-Zertifizierung (V2-Advanced §26/§27) – \(meta.runID)\n\n"
        md += "Korpus: `\(meta.corpus)` · Kategorien: "
        md += meta.categories.joined(separator: ", ")
        md += " · Preset: \(meta.preset)\n\n"
        md += "Arme: V2-Basis (\(meta.engineBasis)) vs "
        md += "V2-MRC (\(meta.engineMRC))\n\n"

        md += "### Mess-Tabelle je Datei (V2-Basis vs V2-MRC)\n\n"
        md += "| Kategorie | Datei | in | out Basis | out MRC | Δ (MRC−Basis) "
        md += "| MRC-Seiten | Stufen | Fallback | SSIM min/mean | p05 min | "
        md += "CAR max | inkDelta max | OCR ok | t Basis | t MRC |\n"
        md += "|---|---|--:|--:|--:|--:|--:|--:|---|---|--:|--:|--:|---|--:|--:|\n"

        var basisByFile: [String: RunRecord] = [:]
        for record in records where record.engine == "V2-Basis" {
            basisByFile["\(record.category)/\(record.fileName)"] = record
        }
        for record in records where record.engine == "V2-MRC" {
            let key = "\(record.category)/\(record.fileName)"
            guard let basis = basisByFile[key] else { continue }
            let deltaBytes = record.outputBytes - basis.outputBytes
            let delta = deltaBytes <= 0
                ? String(format: "%.1f KB", Double(deltaBytes) / 1024)
                : String(format: "+%.1f KB", Double(deltaBytes) / 1024)
            let qualities = record.pageQualities.filter { $0.globalSSIM > 0 }
            func minStr(_ values: [Double]) -> String {
                values.min().map { String(format: "%.4f", $0) } ?? "–"
            }
            func meanStr(_ values: [Double]) -> String {
                values.isEmpty ? "–" : String(format: "%.4f",
                    values.reduce(0, +) / Double(values.count))
            }
            let ocr = record.pageQualities.filter(\.ocrChecked)
            let ocrText = ocr.isEmpty
                ? "–"
                : "\(ocr.filter(\.ocrPreserved).count)/\(ocr.count)"
            let fallback = record.fallbacks.isEmpty
                ? (record.mrcPagesExecuted > 0 ? "MRC ausgeführt" : "–")
                : record.fallbacks.map { fallbackKey($0.reason) }
                    .joined(separator: "; ")
            md += "| \(record.category) | \(record.fileName) | "
            md += "\(bytes(record.inputBytes)) | \(bytes(basis.outputBytes)) | "
            md += "\(bytes(record.outputBytes)) | \(delta) | "
            md += "\(record.mrcPagesExecuted >= 0 ? String(record.mrcPagesExecuted) : "–") | "
            md += "\(record.mrcCandidateCount >= 0 ? String(record.mrcCandidateCount) : "–") | "
            md += "\(fallback) | "
            md += "\(minStr(qualities.map(\.globalSSIM)))/"
            md += "\(meanStr(qualities.map(\.globalSSIM))) | "
            md += "\(minStr(qualities.map(\.p05TileSSIM))) | "
            md += "\(carMaxStr(qualities)) | "
            md += "\(inkMaxStr(qualities)) | \(ocrText) | "
            md += String(format: "%.1fs | %.1fs |\n",
                         basis.runtimeSeconds, record.runtimeSeconds)
        }

        md += "\n### Kategorie-Aggregate\n\n"
        md += "| Kategorie | Engine | ok | in | out | gewichtet | Med-Laufzeit | MRC-Seiten |\n"
        md += "|---|---|--:|--:|--:|--:|--:|--:|\n"
        for a in aggregates {
            md += "| \(a.category) | \(a.engine) | \(a.successful)/\(a.files) | "
            md += "\(bytes(a.totalInputBytes)) | \(bytes(a.totalOutputBytes)) | "
            md += String(format: "%.1f%% | %.1fs | %d |\n",
                         a.weightedSavingPercent, a.medianRuntimeSeconds,
                         a.mrcPagesExecuted)
        }

        md += "\n### Fallback-Analyse (Warum KEEP statt MRC?)\n\n"
        md += "| Grund | Seiten |\n|---|--:|\n"
        if fallbacks.isEmpty {
            md += "| (keine – jede geeignete Seite bekam ein MRC-Bündel) | 0 |\n"
        }
        for key in fallbacks.keys.sorted() {
            md += "| \(key) | \(fallbacks[key] ?? 0) |\n"
        }

        // §13.10-Prüfung der MRC-Ausgaben (End-to-End an der fertigen Datei).
        // Bewertung NUR für Seiten mit ausgeführtem MRC – Seiten ohne MRC
        // sind Basis-Pfad (deren Qualität tragen die Bildmatrix-Gates, nicht
        // der §13.10-Scan-Schranken).
        let mrcRecords = records.filter { $0.engine == "V2-MRC" }
        let allQualities = mrcRecords.flatMap(\.pageQualities).filter {
            $0.globalSSIM > 0
        }
        let measured = allQualities.filter(\.mrcPage)
        let reference = allQualities.filter { !$0.mrcPage }
        let violations = measured.filter { !$0.meetsScanLimits }
        md += "\n### Qualitätsprüfung der MRC-Ausgaben (§13.10)\n\n"
        md += "- MRC-Seiten gemessen (End-to-End, fertige Ausgabe): "
        md += "\(measured.count)\n"
        md += "- Referenz-Seiten ohne MRC (Normalpfad): \(reference.count)\n"
        md += "- SSIM global: min "
        md += measured.map(\.globalSSIM).min().map {
            String(format: "%.4f", $0)
        } ?? "–"
        md += ", mean "
        md += measured.isEmpty ? "–" : String(
            format: "%.4f",
            measured.map(\.globalSSIM).reduce(0, +) / Double(measured.count))
        md += " (Grenze ≥ \(MRCPageQA.minimumGlobalSSIM))\n"
        md += "- p05-Kachel: min "
        md += measured.map(\.p05TileSSIM).min().map {
            String(format: "%.4f", $0)
        } ?? "–"
        md += " (Grenze ≥ \(MRCPageQA.minimumP05TileSSIM))\n"
        md += "- CAR: max "
        md += measured.map(\.changedAreaRatio).max().map {
            String(format: "%.4f", $0)
        } ?? "–"
        md += " (Berichtsmetrik, kein Gate)\n"
        md += "- inkDelta: max "
        md += measured.map(\.inkDelta).max().map {
            String(format: "%.5f", $0)
        } ?? "–"
        md += " (Grenze ≤ \(MRCPageQA.maximumInkDelta))\n"
        md += "- §13.10-Verletzungen: \(violations.count)\n"
        let colorShifts = measured.filter {
            $0.paperLumaOutput >= 0
                && abs($0.paperLumaSource - $0.paperLumaOutput) > 10
        }
        md += "- Farb-/Masken-Verifikation (Median-Luminanz Δ > 10): "
        md += "\(colorShifts.count)\n"
        // OCR-Erhalt (§13.2) zählt für ALLE Seiten – der Text-Layer muss
        // die MRC-Rekonstruktion wie jede andere Transformation überstehen.
        let ocrPages = allQualities.filter(\.ocrChecked)
        md += "- OCR-Erhalt (§13.2): \(ocrPages.filter(\.ocrPreserved).count)/"
        md += "\(ocrPages.count) OCR-Seiten unverändert\n"
        if !reference.isEmpty {
            md += "- Referenz ohne MRC: SSIM min "
            md += reference.map(\.globalSSIM).min().map {
                String(format: "%.4f", $0)
            } ?? "–"
            md += ", mean "
            md += String(format: "%.4f",
                         reference.map(\.globalSSIM).reduce(0, +)
                             / Double(reference.count))
            md += " (Normalpfad, Bildmatrix-Gates – NICHT §13.10)\n"
        }

        // Fallback-Parität: Ohne ausgeführtes MRC müssen beide Arme
        // strukturell identisch sein (der Fallback reproduziert die Basis).
        // Der Ausgabenvergleich läuft über die NORMALISIERTE Struktur
        // (qpdf --qdf, /ID ausmaskiert) – die schreib-laufzeitspezifische
        // Datei-ID ist keine Inhaltsdifferenz.
        let fallbackRuns = mrcRecords.filter {
            $0.mrcPagesExecuted == 0 && $0.success
        }
        let parityOK = fallbackRuns.filter(\.outputEqualsBasis)
        let parityPlans = mrcRecords.filter {
            $0.mrcPagesExecuted == 0 && $0.success && !$0.planParity
        }
        md += "\n### Fallback-Parität\n\n"
        md += "- Dateien ohne ausgeführtes MRC: \(fallbackRuns.count), davon "
        md += "inhaltsgleich zur Basis (normalisierter Hash): "
        md += "\(parityOK.count)\n"
        md += "- Plan-Parität verletzt (Wahl verschoben): \(parityPlans.count)\n"

        var failRows = 0
        for r in records where !r.success {
            if failRows == 0 {
                md += "\n### Fehlgeschlagene Läufe\n\n"
                md += "| Engine | Kategorie | Datei | Fehler |\n|---|---|---|---|\n"
            }
            failRows += 1
            md += "| \(r.engine) | \(r.category) | \(r.fileName) | "
            md += "\(r.error.isEmpty ? r.qpdfCheck : r.error) |\n"
        }
        if failRows == 0 {
            md += "\nKeine fehlgeschlagenen Läufe.\n"
        }
        try md.write(to: outRoot.appendingPathComponent("report.md"),
                     atomically: true, encoding: .utf8)
    }

    private static func carMaxStr(_ qualities: [PageQualityRecord]) -> String {
        qualities.map(\.changedAreaRatio).max().map {
            String(format: "%.4f", $0)
        } ?? "–"
    }

    private static func inkMaxStr(_ qualities: [PageQualityRecord]) -> String {
        qualities.map(\.inkDelta).max().map {
            String(format: "%.5f", $0)
        } ?? "–"
    }

    // MARK: - Hilfsfunktionen

    private static func errorText(_ error: Error?) -> String {
        guard let error else { return "" }
        if let e = error as? LocalizedError, let msg = e.errorDescription {
            return msg + " "
        }
        return String(describing: error) + " "
    }

    private static func utcTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date())
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func sha256(url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// SHA-256 über die NORMALISIERTE PDF-Struktur: qpdf --qdf glättet das
    /// Objektlayout; die schreib-laufzeitspezifische Datei-/ID wird
    /// ausmaskiert. Damit vergleicht der Paritätsvergleich die INHALTE
    /// zweier Ausgaben, nicht die Zufalls-ID des Writers (gemessen: Ohne
    /// Normalisierung unterscheiden sich sonst ZWILLINGSAusgaben nur in
    /// den 64 /ID-Hexzeichen).
    private static func normalizedPDFHash(url: URL, qpdfPath: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qpdfPath)
        p.arguments = ["--qdf", "--object-streams=disable", url.path, "-"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 || p.terminationStatus == 3 else {
            return ""
        }
        var bytes = [UInt8](data)
        let marker = Array("/ID [".utf8)
        var i = 0
        while i + marker.count <= bytes.count {
            if bytes[i] == marker[0] {
                var match = true
                for (offset, m) in marker.enumerated()
                where bytes[i + offset] != m {
                    match = false
                    break
                }
                if match {
                    // Bis zum ZEILENENDE maskieren: Die /ID trägt ZWEI
                    // Hexwerte (erster = Inhalts-Hash, zweiter =
                    // schreib-laufzeitspezifisch) – am ersten „>" zu stoppen
                    // ließe genau den zweiten stehen.
                    var j = i + marker.count
                    while j < bytes.count, bytes[j] != 0x0A {
                        bytes[j] = UInt8(ascii: "x")
                        j += 1
                    }
                    i = j
                    continue
                }
            }
            i += 1
        }
        return SHA256.hash(data: Data(bytes)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func pageCount(qpdfPath: String, url: URL) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qpdfPath)
        p.arguments = ["--show-npages", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return -1 }
        guard p.terminationStatus == 0,
              let data = String(data: pipe.fileHandleForReading
                  .readDataToEndOfFile(), encoding: .utf8),
              let n = Int(data.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return -1 }
        return n
    }

    private static func qpdfCheck(qpdfPath: String, url: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qpdfPath)
        p.arguments = ["--check", url.path]
        let errPipe = Pipe(); p.standardOutput = Pipe(); p.standardError = errPipe
        do { try p.run(); p.waitUntilExit() } catch { return "fatal:spawn" }
        switch p.terminationStatus {
        case 0: return "ok"
        case 3: return "warnings"
        default:
            let err = String(data: errPipe.fileHandleForReading
                .readDataToEndOfFile(), encoding: .utf8) ?? ""
            let first = err.split(separator: "\n").first.map(String.init) ?? ""
            return "fatal:exit\(p.terminationStatus)"
                + (first.isEmpty ? "" : ": \(first)")
        }
    }
}
