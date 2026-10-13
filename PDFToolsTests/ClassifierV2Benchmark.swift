import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// §8.4/§8.3 – Klassifikationskontext einer Bildressource. Eine Stelle in
/// `PageScanAnalyzer.classificationContext` – Produktion, Benchmark und
/// Diagnose spiegeln dieselbe Semantik.
func makeClassificationContext(
    page: PageAnalysis?, resource: PDFImageResource
) -> ContentClassifier.ClassificationContext {
    PageScanAnalyzer.classificationContext(for: page, resource: resource)
}

/// Phase V2-2 – Pipeline-Integration des V2-Klassifikators (§8).
///
/// Festgenagelt:
///   • `classifierPolicy` ist per Default `.v2` (Aktivierung nach der
///     §8.6-Reparatur): Die V2-11-Zertifizierung hatte den Schalter auf
///     `legacy` zurückgestellt, weil die Bild-Klassifikation ohne
///     Seiten-/Bild-Verknüpfung gescanntes Karten-/Scan-Material in die
///     verlustfreie Graphics-Route drückte. Reparatur: Seitenkontext (§8.4)
///     in die Klassifikation, Scan-Regel mit Priorität und Quell-Signal,
///     Karten-Kacheln auf mapTechnical (edge-sensitive Politik).
///   • Die Klassifikation fließt in jedem Produktionslauf in den Trace
///     (`classification.class` + `confidence`) und zahlt auf
///     `feature_analysis_ms` ein – die Feature-Extraktion ist Teil des
///     Candidate-Pfads, nicht an die Politik gebunden.
@Suite struct ClassifierV2IntegrationTests {

    @Test(.hangGuard) func v2PfadFaelltKlassifikationInTrace() throws {
        try EnvironmentMutex.with {
            setenv("PDFTOOLS_COMPRESSION_TRACE", "1", 1)
            defer { unsetenv("PDFTOOLS_COMPRESSION_TRACE") }
            let url = try PDFFixtures.screenshotLikePDF()
            defer { try? FileManager.default.removeItem(at: url) }

            var options = CompressionOptions.smart
            options.classifierPolicy = .v2
            let timer = StageTimer()
            let result = try Compressor().compress(inputURL: url, options: options,
                                                   stageTimer: timer)
            defer { try? FileManager.default.removeItem(at: result.outputURL) }

            let traceURL = result.outputURL.deletingPathExtension()
                .appendingPathExtension("trace.json")
            let data = try #require(try? Data(contentsOf: traceURL))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let resources = try #require(object["resources"] as? [[String: Any]])
            #expect(!resources.isEmpty)
            let classification = try #require(resources[0]["classification"] as? [String: Any])
            let contentClass = try #require(classification["class"] as? String)
            #expect(ContentClass(rawValue: contentClass) != nil,
                    "Klasse muss ein gültiges ContentClass-RawValue sein: \(contentClass)")
            #expect(classification["confidence"] as? Double != nil)

            // Feature-Extraktion zahlt auf feature_analysis_ms ein (§7.3 –
            // seit V2-11 aus dem Candidate-Pfad heraus gemessen).
            let timings = try #require(object["stage_timings"] as? [String: Double])
            #expect((timings["feature_analysis_ms"] ?? 0) > 0)
        }
    }

    @Test(.hangGuard) func traceTraegtKlassifikationInJedemProduktionslauf() throws {
        try EnvironmentMutex.with {
            setenv("PDFTOOLS_COMPRESSION_TRACE", "1", 1)
            defer { unsetenv("PDFTOOLS_COMPRESSION_TRACE") }
            let url = try PDFFixtures.screenshotLikePDF()
            defer { try? FileManager.default.removeItem(at: url) }

            // V2-11: Es gibt keinen separaten Legacy-Pfad mehr (§4.18). Die
            // Feature-Extraktion des Candidate-Pfads läuft in JEDEM Lauf –
            // der Trace trägt die Klassifikation unabhängig von der Politik.
            let planned = try CompressionPipeline.plan(inputURL: url,
                                                       options: .smart)
            #expect(planned.plan.traceVersion == 2,
                    "Es gibt nur den Candidate-Pfad (traceVersion 2)")
            let result = try Compressor().compress(inputURL: url,
                                                   options: .smart)
            defer { try? FileManager.default.removeItem(at: result.outputURL) }

            let traceURL = result.outputURL.deletingPathExtension()
                .appendingPathExtension("trace.json")
            let data = try #require(try? Data(contentsOf: traceURL))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let resources = try #require(object["resources"] as? [[String: Any]])
            #expect(!resources.isEmpty)
            #expect(resources.allSatisfy { $0["classification"] != nil },
                    "Die V2-Feature-Extraktion läuft in jedem Produktionslauf")
        }
    }
}

/// Phase V2-11-Nachbereitung (§8.6-Reparatur) – Klassifikations-Diagnose.
///
/// Env-gated (nicht Teil der normalen Suite):
///
///     TEST_RUNNER_PDFTOOLS_CLASSIFIER_DIAG=1 \
///     xcodebuild test -project PDFTools.xcodeproj -scheme PDFTools \
///       -only-testing:PDFToolsTests/ClassifierV2Diagnostic \
///       -parallel-testing-enabled NO
///
/// xcodebuild schluckt print-Ausgaben – deshalb schreibt der Lauf direkt
/// nach /tmp/opencode/cls-diag-*.txt:
///
///     cls-diag-images.txt    je Bild: Features + Verdict OHNE Kontext
///                            (Produktionspfad vor V2-2-Verknüpfung) und
///                            MIT Seitenkontext (PageScanAnalyzer)
///     cls-diag-summary.txt   Kategorie-Aggregate (byte-gewichtete
///                            Dominanz je Modus) + Regelstatistik
///
/// Hintergrund: Die V2-11-Zertifizierung hat die §8.6-Acceptance auf
/// Kartenmaterial verletzt gemessen (Vorablauf 20260902-215250: Maps
/// −69 pp Ersparnis). Diese Diagnose belegt, WELCHE Regel WELCHE Klasse
/// auf den Karten-Kacheln auslöst und wie sich der Seitenkontext (§8.4)
/// auf das Ergebnis auswirkt.
@Suite struct ClassifierV2Diagnostic {

    private static let diagDir = "/tmp/opencode"

    @Test(.measurementRun) func diagnoseCorpusClasses() async throws {
        let env = ProcessInfo.processInfo.environment
        let flag = env["PDFTOOLS_CLASSIFIER_DIAG"]
            ?? env["TEST_RUNNER_PDFTOOLS_CLASSIFIER_DIAG"]
        guard flag == "1" else { return }

        let fm = FileManager.default
        let corpusPath = env["PDFTOOLS_CLASSIFIER_CORPUS"]
            ?? env["TEST_RUNNER_PDFTOOLS_CLASSIFIER_CORPUS"]
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(
                "Desktop/PDF_small/PDF_Corpus_System/Compression_Benchmark/Smoke_30").path
        let corpus = URL(fileURLWithPath: corpusPath)
        guard fm.fileExists(atPath: corpus.path) else {
            Issue.record("Classifier-Korpus fehlt: \(corpus.path)")
            return
        }

        var imageLines: [String] = []
        var summaryLines: [String] = []
        imageLines.append("category,file,page,bytes,width,height,pageClass,"
            + "entropy,edge,flat,texture,colors,grayscale,chroma,diag,h,v,textLike,"
            + "bareClass,bareRule,bareConf,ctxClass,ctxRule,ctxConf")

        // Aggregate: Kategorie × Modus → Klasse → (items, bytes).
        struct Tally { var items = 0; var bytes = 0 }
        var bareVotes: [String: [String: Tally]] = [:]
        var ctxVotes: [String: [String: Tally]] = [:]
        var ruleVotes: [String: [String: Int]] = [:]
        var pageVotes: [String: [String: Int]] = [:]

        let categories = ((try? fm.contentsOfDirectory(
            at: corpus, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for categoryURL in categories {
            let category = categoryURL.lastPathComponent
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: categoryURL.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let files = ((try? fm.contentsOfDirectory(
                at: categoryURL, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "pdf"
                          && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for fileURL in files {
                let resolved = fileURL.resolvingSymlinksInPath()
                guard let document = try? PDFCoreDocument(path: resolved.path) else {
                    summaryLines.append("UNREADABLE\t\(category)\t\(fileURL.lastPathComponent)")
                    continue
                }
                let pages = (try? PageScanAnalyzer.analyze(document: document)) ?? []
                for analysis in pages {
                    pageVotes[category, default: [:]][analysis.classification.rawValue,
                                                      default: 0] += 1
                }
                let resources = (try? document.imageResources()) ?? []
                let pixels = LibQPDFPixelSource(document: document)
                for resource in resources {
                    guard let image = pixels.decodedImage(for: resource),
                          let f = ContentFeatureExtractor.extract(from: image) else {
                        imageLines.append("\(category),\(fileURL.lastPathComponent),-1,"
                            + "\(resource.encodedByteCount),\(resource.width),"
                            + "\(resource.height),-,-,-,-,-,-,-,-,-,-,-,-,undecodable,-,0,-,-,0")
                        continue
                    }
                    // Modus A – OHNE Seitenkontext (Produktionspfad vor der
                    // V2-2-Verknüpfung: leerer ClassificationContext).
                    let bare = ContentClassifier.classify(
                        features: f, context: ContentClassifier.ClassificationContext())
                    // Modus B – MIT Seitenkontext aus PageScanAnalyzer (§8.4)
                    // und Quellkodierung – dieselbe Semantik wie Produktion.
                    let placementPage = resource.placements.first?.pageIndex ?? 0
                    let pageClass = pages.first { $0.pageIndex == placementPage }?
                        .classification.rawValue ?? "-"
                    let context = makeClassificationContext(
                        page: pages.first { $0.pageIndex == placementPage },
                        resource: resource)
                    let withContext = ContentClassifier.classify(
                        features: f, context: context)

                    let row = [category, fileURL.lastPathComponent,
                               String(placementPage),
                               String(resource.encodedByteCount),
                               String(resource.width), String(resource.height),
                               pageClass,
                               String(format: "%.3f", f.entropy),
                               String(format: "%.4f", f.edgeDensity),
                               String(format: "%.3f", f.flatAreaRatio),
                               String(format: "%.3f", f.textureRatio),
                               String(format: "%.4f", f.uniqueColorRatio),
                               String(format: "%.3f", f.grayscaleScore),
                               String(format: "%.1f", f.chromaMean),
                               String(format: "%.3f", f.diagonalEdgeRatio),
                               String(format: "%.3f", f.horizontalEdgeRatio),
                               String(format: "%.3f", f.verticalEdgeRatio),
                               String(format: "%.3f", f.textLikeTileRatio),
                               bare.contentClass.rawValue, bare.rule,
                               String(format: "%.2f", bare.confidence),
                               withContext.contentClass.rawValue, withContext.rule,
                               String(format: "%.2f", withContext.confidence)]
                    imageLines.append(row.joined(separator: ","))

                    let bytes = max(0, resource.encodedByteCount)
                    func tally(_ votes: inout [String: [String: Tally]],
                               _ verdict: ContentClassifier.Verdict) {
                        var cell = votes[category]?[verdict.contentClass.rawValue]
                            ?? Tally()
                        cell.items += 1
                        cell.bytes += bytes
                        votes[category, default: [:]][verdict.contentClass.rawValue] = cell
                    }
                    tally(&bareVotes, bare)
                    tally(&ctxVotes, withContext)
                    ruleVotes[category, default: [:]][bare.rule, default: 0] += 1
                }
            }
        }

        summaryLines.append("=== Seitenklassen je Kategorie ===")
        for category in pageVotes.keys.sorted() {
            let votes = pageVotes[category]!
            summaryLines.append(category + "\t"
                + votes.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: "\t"))
        }
        summaryLines.append("")
        summaryLines.append("=== Bild-Klassen OHNE Kontext (Produktionspfad) ===")
        for category in bareVotes.keys.sorted() {
            let votes = bareVotes[category]!
            summaryLines.append(category + "\t"
                + votes.sorted { $0.value.bytes > $1.value.bytes }
                    .map { "\($0.key): items=\($0.value.items) bytes=\($0.value.bytes)" }
                    .joined(separator: "\t"))
        }
        summaryLines.append("")
        summaryLines.append("=== Bild-Klassen MIT Seitenkontext (V2-2-Verknüpfung) ===")
        for category in ctxVotes.keys.sorted() {
            let votes = ctxVotes[category]!
            summaryLines.append(category + "\t"
                + votes.sorted { $0.value.bytes > $1.value.bytes }
                    .map { "\($0.key): items=\($0.value.items) bytes=\($0.value.bytes)" }
                    .joined(separator: "\t"))
        }
        summaryLines.append("")
        summaryLines.append("=== Ausgelöste Regeln je Kategorie (ohne Kontext) ===")
        for category in ruleVotes.keys.sorted() {
            let votes = ruleVotes[category]!
            summaryLines.append(category + "\t"
                + votes.sorted { $0.value > $1.value }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: "\t"))
        }

        try imageLines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: Self.diagDir + "/cls-diag-images.txt"),
            atomically: true, encoding: .utf8)
        try summaryLines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: Self.diagDir + "/cls-diag-summary.txt"),
            atomically: true, encoding: .utf8)
    }
}

/// Phase V2-2 (§8.5) – Classifier-Benchmark über den Smoke-30-Korpus.
///
/// Weak Supervision: Die Kategorie-Ordnernamen sind erwartete Klassen, KEINE
/// geprüfte Ground Truth. Der Lauf schreibt:
///
///     benchmark/classifier-v2/confusion.csv   expected ↔ dominant class
///     benchmark/classifier-v2/uncertain.csv   confidence < 0.60
///     benchmark/classifier-v2/examples/       (leer, für Review-Ablagen)
///
/// Aufruf (nicht Teil der normalen Suite):
///
///     TEST_RUNNER_PDFTOOLS_CLASSIFIER_BENCH=1 \
///     xcodebuild test -project PDFTools.xcodeproj -scheme PDFTools \
///       -only-testing:PDFToolsTests/ClassifierV2Benchmark \
///       -parallel-testing-enabled NO
///
/// Zwei Ebenen (bewusst getrennt, siehe Mapping):
///   • page  – dominante `PageContentClass` je Dokument (Seitenmehrheit)
///   • image – dominante `ContentClass` je Dokument, gewichtet mit den
///     encodierten Bildbytes; nicht dekodierbare Bilder (1-bit-Scans,
///     CCITT/JBIG2) zählen nicht – die deckt die Seitebene ab.
@Suite struct ClassifierV2Benchmark {

    /// Dokumentierte Strukturgrenze: 04_PhotoHeavy-Seiten sind im Korpus
    /// Textseiten MIT Figuren (keine Vollbild-Fotos) → bornDigital; die
    /// Foto-Erwartung trägt die IMAGE-Ebene. 06–09 sind Rasterseiten (ein
    /// OCR-Overlay ändert die Klasse nicht); 03/11 gelten seitenebene als
    /// born-digital, solange kein Vollbild-Raster vorliegt.
    private static let pageExpectations: [String: PageContentClass] = [
        "01_BornDigital_Text": .bornDigital,
        "02_Vector_Charts": .bornDigital,
        "03_Screenshots_UI": .bornDigital,
        "04_PhotoHeavy": .bornDigital,
        "05_Mixed_Content": .mixed,
        "06_Scans_Color": .rasterScan,
        "07_Scans_Grayscale": .rasterScan,
        "08_Scans_Monochrome": .rasterScan,
        "09_Scans_PhoneCamera": .rasterScan,
        "11_Maps_CAD_Technical": .bornDigital,
    ]

    /// expected Kategorie → erwartete ContentClass der Bildressourcen.
    private static let imageExpectations: [String: ContentClass] = [
        "03_Screenshots_UI": .screenshot,
        "04_PhotoHeavy": .photo,
        "06_Scans_Color": .scanContinuous,
        "07_Scans_Grayscale": .scanContinuous,
        "08_Scans_Monochrome": .scanBilevel,
        "09_Scans_PhoneCamera": .scanContinuous,
        "11_Maps_CAD_Technical": .lineArt,
    ]

    private static let confidenceFloor = 0.60

    /// Dominante Klasse: Meiste Stimmen (Bytes bzw. Seiten), Gleichstand
    /// alphabetisch – deterministisch.
    private static func dominant(_ counts: [String: Int]) -> String? {
        counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }?.key
    }

    private static func isHit(level: String, expected: String, predicted: String) -> Bool {
        if expected == predicted { return true }
        // Normalisierung schwacher Unterschiede (dokumentiert): OCR-Overlay
        // ist ein Scan; mapTechnical ist ein lineArt-Fallback-Treffer.
        if level == "page", expected == PageContentClass.rasterScan.rawValue,
           predicted == PageContentClass.rasterScanWithOCR.rawValue { return true }
        if level == "image", expected == ContentClass.lineArt.rawValue,
           predicted == ContentClass.mapTechnical.rawValue { return true }
        return false
    }

    @Test(.measurementRun) func corpusConfusion() async throws {
        let env = ProcessInfo.processInfo.environment
        let flag = env["PDFTOOLS_CLASSIFIER_BENCH"]
            ?? env["TEST_RUNNER_PDFTOOLS_CLASSIFIER_BENCH"]
        guard flag == "1" else { return }

        let fm = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let corpusPath = env["PDFTOOLS_CLASSIFIER_CORPUS"]
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(
                "Desktop/PDF_small/PDF_Corpus_System/Compression_Benchmark/Smoke_30").path
        let corpus = URL(fileURLWithPath: corpusPath)
        guard fm.fileExists(atPath: corpus.path) else {
            Issue.record("Classifier-Korpus fehlt: \(corpus.path)")
            return
        }
        let outRoot = repoRoot.appendingPathComponent("benchmark/classifier-v2")
        try fm.createDirectory(at: outRoot.appendingPathComponent("examples"),
                               withIntermediateDirectories: true)

        // Aggregierte Konfusionszellen je Ebene: expected × predicted.
        struct Key: Hashable, Comparable {
            var level: String
            var expected: String
            var predicted: String
            var sortKey: String { level + "|" + expected + "|" + predicted }
            static func < (a: Key, b: Key) -> Bool { a.sortKey < b.sortKey }
        }
        struct Cell {
            var documents = 0
            var items = 0
            var imageBytes = 0
            var lowConfidence = 0
        }
        var cells: [Key: Cell] = [:]
        var uncertainLines: [String] = []
        var pageLines: [String] = []

        func noteUncertain(_ line: String) {
            uncertainLines.append(line)
        }

        let categories = ((try? fm.contentsOfDirectory(
            at: corpus, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for categoryURL in categories {
            let category = categoryURL.lastPathComponent
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: categoryURL.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let files = ((try? fm.contentsOfDirectory(
                at: categoryURL, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "pdf"
                          && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            var pageCounts: [String: Int] = [:]
            var pageTotal = 0
            var pageLow = 0
            var imageCounts: [String: Int] = [:]
            var imageBytes: [String: Int] = [:]
            var imageTotal = 0
            var imageLow = 0

            for fileURL in files {
                let resolved = fileURL.resolvingSymlinksInPath()
                guard let document = try? PDFCoreDocument(path: resolved.path) else {
                    noteUncertain(fileURL.lastPathComponent
                        + ",page,-1,unreadable,0.00,-,-,,,,")
                    continue
                }
                let pages = (try? PageScanAnalyzer.analyze(document: document)) ?? []
                for analysis in pages {
                    pageLines.append("\(fileURL.lastPathComponent),\(category),"
                        + "\(analysis.pageIndex),\(analysis.classification.rawValue),"
                        + String(format: "%.2f", analysis.confidence)
                        + String(format: ",%.2f,%.2f,%d,%d,%d",
                                 analysis.imageCoverageRatio,
                                 analysis.largestImageCoverageRatio,
                                 analysis.textCharacterEstimate,
                                 analysis.vectorOperatorEstimate,
                                 analysis.imageCount))
                    pageCounts[analysis.classification.rawValue, default: 0] += 1
                    pageTotal += 1
                    if analysis.confidence < Self.confidenceFloor {
                        pageLow += 1
                        let confidenceText = String(format: "%.2f", analysis.confidence)
                        let coverage = String(format: "%.2f", analysis.imageCoverageRatio)
                        let largest = String(format: "%.2f", analysis.largestImageCoverageRatio)
                        let parts = [fileURL.lastPathComponent, "page",
                                     String(analysis.pageIndex), category,
                                     confidenceText, analysis.classification.rawValue,
                                     "coverage=\(coverage)", "largest=\(largest)",
                                     "text=\(analysis.textCharacterEstimate)",
                                     "vector=\(analysis.vectorOperatorEstimate)",
                                     "images=\(analysis.imageCount)"]
                        noteUncertain(parts.joined(separator: ","))
                    }
                }

                // Image-Ebene: Kontext aus der Seite der ersten Platzierung.
                let resources = (try? document.imageResources()) ?? []
                let pixels = LibQPDFPixelSource(document: document)
                for resource in resources {
                    guard let image = pixels.decodedImage(for: resource),
                          let features = ContentFeatureExtractor.extract(from: image) else {
                        continue
                    }
                    var context = ContentClassifier.ClassificationContext()
                    let placementPage = resource.placements.first?.pageIndex ?? 0
                    let benchmarkPage = pages.first { $0.pageIndex == placementPage }
                    context.pageLooksScanned = benchmarkPage.map {
                        $0.pageArea >= PageScanAnalyzer.minimumDocumentPageArea
                            && $0.largestImageCoverageRatio >= 0.90
                    } ?? false
                    context.largestImageCoverageRatio = benchmarkPage?
                        .largestImageCoverageRatio
                    context.scanDPI = benchmarkPage?.scanDPI
                    context.sourceIsLossy = makeClassificationContext(
                        page: nil, resource: resource).sourceIsLossy
                    let verdict = ContentClassifier.classify(features: features,
                                                             context: context)
                    imageCounts[verdict.contentClass.rawValue, default: 0] += 1
                    imageBytes[verdict.contentClass.rawValue, default: 0] += max(0, resource.encodedByteCount)
                    imageTotal += 1
                    if verdict.confidence < Self.confidenceFloor {
                        imageLow += 1
                        let confidenceText = String(format: "%.2f", verdict.confidence)
                        let entropy = String(format: "%.2f", features.entropy)
                        let edge = String(format: "%.2f", features.edgeDensity)
                        let flat = String(format: "%.2f", features.flatAreaRatio)
                        let texture = String(format: "%.2f", features.textureRatio)
                        let colors = String(format: "%.3f", features.uniqueColorRatio)
                        let parts = [fileURL.lastPathComponent, "image",
                                     String(placementPage), category, confidenceText,
                                     verdict.contentClass.rawValue,
                                     "entropy=\(entropy)", "edge=\(edge)",
                                     "flat=\(flat)", "texture=\(texture)",
                                     "colors=\(colors)"]
                        noteUncertain(parts.joined(separator: ","))
                    }
                }
            }

            if let expected = Self.pageExpectations[category],
               let predicted = Self.dominant(pageCounts) {
                let key = Key(level: "page", expected: expected.rawValue, predicted: predicted)
                var cell = cells[key] ?? Cell()
                cell.documents += files.count
                cell.items += pageTotal
                cell.lowConfidence += pageLow
                cells[key] = cell
            }
            if let expected = Self.imageExpectations[category],
               let predicted = Self.dominant(imageBytes) {
                let key = Key(level: "image", expected: expected.rawValue, predicted: predicted)
                var cell = cells[key] ?? Cell()
                cell.documents += files.count
                cell.items += imageTotal
                cell.imageBytes += imageBytes.values.reduce(0, +)
                cell.lowConfidence += imageLow
                cells[key] = cell
            }
        }

        var lines = ["level,expected,predicted,documents,items,image_bytes,low_confidence,hit"]
        for key in cells.keys.sorted() {
            let cell = cells[key]!
            let hit = Self.isHit(level: key.level, expected: key.expected,
                                 predicted: key.predicted) ? "true" : "false"
            lines.append("\(key.level),\(key.expected),\(key.predicted),"
                + "\(cell.documents),\(cell.items),\(cell.imageBytes),"
                + "\(cell.lowConfidence),\(hit)")
        }
        try lines.joined(separator: "\n").write(
            to: outRoot.appendingPathComponent("confusion.csv"),
            atomically: true, encoding: .utf8)
        var uncertainOutput = ["file,level,page,expected,confidence,class,extra1,extra2,extra3,extra4,extra5"]
        uncertainOutput.append(contentsOf: uncertainLines)
        try uncertainOutput.joined(separator: "\n").write(
            to: outRoot.appendingPathComponent("uncertain.csv"),
            atomically: true, encoding: .utf8)
        var pageOutput = ["file,category,page,class,confidence,coverage,largest,text_chars,vector_ops,image_count"]
        pageOutput.append(contentsOf: pageLines.sorted())
        try pageOutput.joined(separator: "\n").write(
            to: outRoot.appendingPathComponent("pages.csv"),
            atomically: true, encoding: .utf8)

        let hitCount = lines.dropFirst().filter { $0.hasSuffix("true") }.count
        print("CLASSIFIER V2 BENCH: \(cells.count) Konfusionszellen, "
              + "\(hitCount) Trefferzellen, \(uncertainLines.count) unsichere Zeilen "
              + "→ \(outRoot.path)")
    }
}
