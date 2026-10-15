import Foundation
import CoreGraphics
import PDFKit

// MARK: - Masterplan §13 – MRC Scan Engine (V2-7): Integration
//
// Verbindet Segmentierung (§13.5), Layer-Kodierung (§13.6) und
// PDF-Rekonstruktion (§13.7) zu Kandidaten:
//
//   • Voraussetzung (§13.1/§13.4): Page-Klassifikation rasterScan oder
//     rasterScanWithOCR mit Confidence ≥ 0.8, dominantes Vollbild-Raster
//     (Deckung ≥ 0.90) plus höchstens 5 % Sekundär-Raster, nicht geteilt,
//     verlustbehaftet ersetzbarer Farbraum, messbare Scan-DPI.
//   • Ladder (§13.9): konservativ zuerst, dann die preset-gemäße Stufe –
//     max. ZWEI Rendervergleiche je Seite (dokumentiertes Budget).
//   • Page-QA (§13.10): Jede Stufe wird als ECHTE Seite (Scratch-Dokument
//     über die Bridge rekonstruiert) gegen die Quelle gerendert und mit
//     strengen Scan-Grenzen bewertet. Fail → Stufe wird kein Kandidat;
//     scheitert auch die konservativste, bleibt das Original-Raster.
//
// Der MRC-Kandidat lebt im CandidateSet des DOMINANTEN RASTERBILDES und
// konkurriert dort mit dessen normalen Kandidaten (V1-Race auf Bild-/
// Seitenebene, dokumentierte Wahl); die Seiten-QA ersetzt das Bild-Gate
// (RateDistortionOptimizer: mrc-Klasse mit Katastrophen-Floor ohne
// Preset-Floor der Bildmatrix).
//
// §13.2/§13.3: Der OCR-/Text-Layer LEBT in den Text-Operatoren der Seite –
// die bleiben bei der Rekonstruktion unberührt. Keine neue OCR, keine
// Kopplung der Compression an OCR.

// MARK: §13.10 – Page-QA

/// Seitemessung eines MRC-Kandidaten gegen die Quelle.
struct MRCPageQuality {
    let globalSSIM: Double
    let p05TileSSIM: Double
    /// Anteil Pixel mit wahrnehmbarem Unterschied (> 15/255). Berichtsmetrik:
    /// Die schwarze Masken-Tinte zählt jeden Textpixel als „geändert“
    /// (Originalton 30 → 0), ohne ihn strukturell zu beschädigen – CAR ist
    /// deshalb bewusst KEIN Gate (SSIM/p05 tragen die Struktur).
    let changedAreaRatio: Double
    let meanAbsDiff: Double
    /// |Tintenabdeckung(Output) − Tintenabdeckung(Quelle)|.
    let inkDelta: Double

    var meetsScanLimits: Bool {
        globalSSIM >= MRCPageQA.minimumGlobalSSIM
            && p05TileSSIM >= MRCPageQA.minimumP05TileSSIM
            && inkDelta <= MRCPageQA.maximumInkDelta
    }
}

enum MRCPageQA {

    // Dokumentierte Scan-Grenzen (§13.10). Deutlich strenger als die
    // Preset-Floors der Bildmatrix – MRC greift nur in Zeichenqualität:
    // SSIM ≥ 0.97 (Bildmatrix Smart/Photo ≈ 0.87), p05-Kachel ≥ 0.95 und
    // inkDelta ≤ 0.005 (schwarze Masken-Tinte darf die Dunkelabdeckung
    // nicht spürbar verschieben – fehlender Text würde genau das tun).
    static let minimumGlobalSSIM = 0.97
    static let minimumP05TileSSIM = 0.95
    static let maximumInkDelta = 0.005

    /// Render-DPI des Vergleichs (Standard-Regression wie im RenderDifferential),
    /// Kanten Cap gegen Poster-Seiten.
    static let renderDPI = 150
    static let maximumRenderEdge = 1400

    /// Rendert Quelle und MRC-Ausgabe je Seite einmal und misst Seiten-QA.
    /// nil heißt: nicht messbar (Renderfehler) – der Kandidat gilt als
    /// durchgefallen.
    static func measure(sourceURL: URL, outputURL: URL,
                        pageIndex: Int) -> MRCPageQuality? {
        autoreleasepool {
            guard let source = PDFDocument(url: sourceURL),
                  let output = PDFDocument(url: outputURL),
                  let sourcePage = source.page(at: pageIndex),
                  let outputPage = output.page(at: pageIndex) else {
                return nil
            }

            // Anzeige-Größen über die Seitenrotation (PDFKit wendet /Rotate
            // beim Rendern bereits an – derselbe Weg wie im RenderDifferential).
            let sourceRaw = sourcePage.bounds(for: .mediaBox).size
            let sourceDisplay = RotationNormalizer.rotatedSize(
                width: sourceRaw.width, height: sourceRaw.height,
                rotation: sourcePage.rotation)
            let outputRaw = outputPage.bounds(for: .mediaBox).size
            let outputDisplay = RotationNormalizer.rotatedSize(
                width: outputRaw.width, height: outputRaw.height,
                rotation: outputPage.rotation)
            // Geometrie muss identisch sein – MRC verändert keine Boxen.
            guard abs(sourceDisplay.width - outputDisplay.width) < 0.01,
                  abs(sourceDisplay.height - outputDisplay.height) < 0.01 else {
                return nil
            }

            let scale = Double(renderDPI) / 72.0
            var w = Int((outputDisplay.width * scale).rounded())
            var h = Int((outputDisplay.height * scale).rounded())
            let cap = Double(maximumRenderEdge)
                / Double(max(w, h, 1))
            if cap < 1 {
                w = max(1, Int((Double(w) * cap).rounded()))
                h = max(1, Int((Double(h) * cap).rounded()))
            }
            let size = CGSize(width: w, height: h)

            guard let sourceImage = render(sourcePage, size: size),
                  let outputImage = render(outputPage, size: size),
                  let measurement = QualityGates.measure(reference: sourceImage,
                                                         candidate: outputImage)
            else { return nil }

            guard let lumaSource = lumaBuffer(sourceImage),
                  let lumaOutput = lumaBuffer(outputImage),
                  lumaSource.count == lumaOutput.count else { return nil }

            var changed = 0
            var totalDiff = 0
            var inkSource = 0
            var inkOutput = 0
            for i in 0..<lumaSource.count {
                let a = Int(lumaSource[i])
                let b = Int(lumaOutput[i])
                if abs(a - b) > 15 { changed += 1 }   // Anti-Aliasing-Toleranz
                totalDiff += abs(a - b)
                if a < 128 { inkSource += 1 }
                if b < 128 { inkOutput += 1 }
            }
            let total = max(lumaSource.count, 1)
            return MRCPageQuality(
                globalSSIM: measurement.globalSSIM,
                p05TileSSIM: measurement.p05TileSSIM,
                changedAreaRatio: Double(changed) / Double(total),
                meanAbsDiff: Double(totalDiff) / Double(total),
                inkDelta: Double(abs(inkSource - inkOutput)) / Double(total))
        }
    }

    private static func render(_ page: PDFPage, size: CGSize) -> CGImage? {
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Luminanz-Puffer (8 Bit) aus einem beliebigen CGImage – gleiche
    /// Herleitung wie RenderDifferential.grayscaleBuffer.
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
}

// MARK: §13.8 – Vorbereiteter Kandidat + Provision
//
// Scope (§13.1, erweitert): Neben dem klassischen Einzelbild-Fall
// (imageCount == 1) sind Seiten mit dominantem Vollbild-Raster PLUS
// kleinen Sekundärrastern (Summe ≤ 5 %) zugelassen – Buchscan-Klasse.
// Nur der dominante Draw wird ersetzt; Sekundär-Draws bleiben unberührt.
// Die Stufen-QA (§13.10) rendert die GESAMTE Seite und fängt jede
// Fehlentscheidung (auch an Sekundär-Draws) fail-closed ab.

/// Ein QA-bestandener MRC-Kandidat samt Bundle-Payload (alle Layer).
struct PreparedMRCCandidate {
    let candidate: CompressionCandidate
    let bundle: Data
}

/// MRC-Kandidaten für EINE dominante Rasterressource.
struct MRCProvision {
    let resourceID: String
    let pageIndex: Int
    let candidates: [PreparedMRCCandidate]
}

// MARK: Rekonstruktion + Verdrahtung

enum MRCPageRewriter {

    /// Confidence- und Klassifikations-Gate (§13.1): MRC nur bei sicherer
    /// Scan-Erkennung.
    static let minimumScanConfidence = 0.8

    // MARK: Provision (Planung)

    /// Erzeugt MRC-Kandidaten für alle geeigneten Scan-Seiten. Aufrufer:
    /// CompressionPipeline (Dokumentzugriff), NUR bei Flags mrc +
    /// candidateEngine (§25) – Produktion bleibt byteidentisch.
    /// Maximale parallele Provisions-Jobs (Segmentierung + Stufen + QA).
    /// Die Bridge-Sperre serialisiert die Stream-Extraktion von selbst;
    /// parallel läuft reine Pixel-/Renderarbeit – Muster wie der
    /// Pixel-Budget-Scheduler des Planners (dort Cap 8, hier 4: Die
    /// Scratch-QA rendert je Stufe zweimal via PDFKit).
    static let provisionConcurrency = 4
    /// Relative Kosten einer MRC-Seite gegenüber der Kandidatensuche
    /// desselben Rasters (Fortschrittsgewicht, keine Planungsgröße).
    static let mrcWorkFactor = 2.0

    /// Sekundär-Raster dürfen zusammen höchstens diesen Deckungsgrad
    /// tragen, damit der dominante Draw allein über MRC entschieden wird.
    static let maximumSecondaryCoverage = 0.05

    /// Eine MRC-faehige Seite: Scan-Klassifikation, dominantes Raster,
    /// messbare Platzierung. Dieselbe Eignung nutzt der Planner fuer die
    /// Bedarfsentscheidung (2026-10-15), bevor er die teure Provision anstoesst.
    struct EligiblePage {
        let pageIndex: Int
        let resource: PDFImageResource
        let sourceDPI: Double
    }

    /// Phase 1 der Provision ohne Budget: Welche Seiten kaemen fuer MRC
    /// infrage? Deterministisch in Analyse-Reihenfolge.
    static func eligiblePages(resources: [PDFImageResource],
                              pageAnalyses: [PageAnalysis]) -> [EligiblePage] {
        var pages: [EligiblePage] = []
        for analysis in pageAnalyses {
            guard analysis.classification == .rasterScan
                    || analysis.classification == .rasterScanWithOCR,
                  analysis.confidence >= minimumScanConfidence,
                  analysis.largestImageCoverageRatio >= 0.90,
                  // DPI-Ableitung braucht eine messbare Platzierung.
                  let sourceDPI = analysis.scanDPI, sourceDPI >= 100
            else { continue }
            let pageIndex = analysis.pageIndex
            guard let dominant = dominantResource(
                on: pageIndex, resources: resources,
                pageArea: analysis.pageArea),
                  pageEligible(resource: dominant.resource) else { continue }
            pages.append(EligiblePage(pageIndex: pageIndex,
                                      resource: dominant.resource,
                                      sourceDPI: sourceDPI))
        }
        return pages
    }

    static func provision(document: PDFCoreDocument,
                          inputURL: URL,
                          resources: [PDFImageResource],
                          pixels: ImagePixelSource,
                          options: CompressionOptions,
                          pageAnalyses: [PageAnalysis],
                          onlyPages: Set<Int>? = nil,
                          isCancelled: (() -> Bool)? = nil,
                          workProgress: WorkProgressLedger? = nil) throws -> [MRCProvision] {
        guard options.featureFlags.mrc, options.featureFlags.candidateEngine else {
            return []
        }
        let preset = QualityGatePreset(ssimThreshold: options.image.ssimThreshold)
        let rungs = MRCEncoder.ladder(for: preset)
        // Die Seitenanalyse kommt vom Aufrufer – dieselbe, die der Planner
        // erhält. Früher lief hier eine zweite Analyse samt zweitem
        // Inventar-Durchlauf (`analyze(document:)` inventarisiert neu).
        let analyses = pageAnalyses
        let budget = options.mrcProvisionBudget
        let provisionStarted = Date()
        var attemptedPages = 0
        var attemptedPixels: Int64 = 0

        // Phase 1 (seriell, billig): Eignung + Budget – deterministisch.
        // `onlyPages` (MRC nur bei Bedarf): Der Planner nennt die Seiten,
        // deren bester Kandidat noch zu gross ist; alle anderen bleiben aus.
        struct Job {
            let pageIndex: Int
            let resource: PDFImageResource
            let sourceDPI: Double
        }
        var jobs: [Job] = []
        for page in eligiblePages(resources: resources, pageAnalyses: analyses) {
            if let isCancelled, isCancelled() { throw CancellationError() }
            if let onlyPages, !onlyPages.contains(page.pageIndex) { continue }
            let pageIndex = page.pageIndex
            let sourceDPI = page.sourceDPI

            let nextPixels = Int64(page.resource.pixelCount)
            let elapsed = Date().timeIntervalSince(provisionStarted)
            guard budget.permitsNextPage(
                attemptedPages: attemptedPages,
                attemptedPixels: attemptedPixels,
                elapsedSeconds: elapsed,
                nextPagePixels: nextPixels) else {
                // Seiten-/Zeitlimit beendet die Provision fail-closed. Ein
                // zu grosses Einzelraster verbraucht das Dokumentbudget
                // nicht; spaetere kleinere Seiten duerfen noch antreten.
                if attemptedPages >= budget.maximumPages
                    || elapsed >= budget.maximumElapsedSeconds {
                    break
                }
                continue
            }
            attemptedPages += 1
            attemptedPixels += nextPixels
            jobs.append(Job(pageIndex: pageIndex,
                            resource: page.resource,
                            sourceDPI: sourceDPI))
        }

        // Fortschritt: Segmentierung, zwei Stufen und je zwei Seitenrender
        // kosten grob das Doppelte der Kandidatensuche desselben Rasters.
        let jobWeights = jobs.map {
            WorkProgressLedger.weight(pixels: $0.resource.pixelCount,
                                      factor: mrcWorkFactor)
        }
        workProgress?.addWork(jobWeights.reduce(0, +))
        var startedWeight = 0.0

        // Phase 2 (parallel, teuer): Segmentierung + Stufen + Scratch-QA je
        // Seite. Jeder Job schreibt NUR seinen Slot; die Zusammenführung
        // unten läuft in Analyse-Reihenfolge – deterministisch.
        let slots = DispatchSemaphore(value: provisionConcurrency)
        let group = DispatchGroup()
        let lock = NSLock()
        var results = [MRCProvision?](repeating: nil, count: jobs.count)
        var caught: Error?
        for (index, job) in jobs.enumerated() {
            if let isCancelled, isCancelled() { throw CancellationError() }
            slots.wait()
            // Weiches Zeitbudget (MRCProvisionBudget): Laufende Seiten werden
            // fertig geprüft, nach Ablauf startet keine weitere. Früher lag
            // diese Prüfung nur in Phase 1 (Auswahl, praktisch ohne Zeit-
            // verbrauch) – die teure Phase 2 lief unbegrenzt (NASA-Scan:
            // 8 Seiten, 158 s Provision bei 60 s Budget).
            if Date().timeIntervalSince(provisionStarted) >= budget.maximumElapsedSeconds {
                slots.signal()
                break
            }
            group.enter()
            startedWeight += jobWeights[index]
            let jobWeight = jobWeights[index]
            // Serielle Queue = Overcommit-Pool (siehe
            // CompressionPlanner.generateCandidateEntries – Deadlock-Befund).
            DispatchQueue(label: "pdftools.mrc.\(index)", qos: .userInitiated).async {
                defer {
                    workProgress?.complete(jobWeight)
                    slots.signal()
                    group.leave()
                }
                do {
                    if let isCancelled, isCancelled() { throw CancellationError() }
                    let provision = try autoreleasepool { () -> MRCProvision? in
                        try buildProvision(pageIndex: job.pageIndex,
                                           resource: job.resource,
                                           sourceDPI: job.sourceDPI,
                                           inputURL: inputURL,
                                           pixels: pixels, rungs: rungs,
                                           options: options, preset: preset,
                                           isCancelled: isCancelled)
                    }
                    lock.lock()
                    results[index] = provision
                    lock.unlock()
                } catch {
                    lock.lock()
                    if caught == nil { caught = error }
                    lock.unlock()
                }
            }
        }
        group.wait()
        // Nach Budgetende nicht gestartete Seiten gelten als erledigt.
        workProgress?.complete(jobWeights.reduce(0, +) - startedWeight)
        if let caught { throw caught }
        return results.compactMap { $0 }.filter { !$0.candidates.isEmpty }
    }

    /// Dominantes Raster einer Seite: die einzige Single-Placement-Ressource
    /// mit der größten Deckung (≥ 0.90 durch den Aufrufer gesichert).
    /// Sekundär-Raster (alle übrigen Platzierungen der Seite) dürfen zusammen
    /// höchstens `maximumSecondaryCoverage` tragen; eine Platzierung ohne
    /// bekannte Geometrie ist unbeweisbar klein → Seite fällt raus
    /// (konservativ). Geteilte Ressourcen können nie dominant sein (sonst
    /// hinge die MRC-Entscheidung an seitenfremden Platzierungen).
    private static func dominantResource(
        on pageIndex: Int,
        resources: [PDFImageResource],
        pageArea: Double)
        -> (resource: PDFImageResource, secondaryCoverage: Double)? {
        guard pageArea > 0 else { return nil }
        // Dominante: Single-Placement-Ressource mit größter Deckung.
        var best: PDFImageResource?
        var bestCoverage = 0.0
        for resource in resources {
            guard resource.placements.count == 1,
                  let placement = resource.placements.first,
                  placement.pageIndex == pageIndex,
                  placement.placedWidthPoints > 0,
                  placement.placedHeightPoints > 0 else { continue }
            let coverage = min(1.0,
                placement.placedWidthPoints * placement.placedHeightPoints
                    / pageArea)
            if coverage > bestCoverage {
                best = resource
                bestCoverage = coverage
            }
        }
        guard let dominant = best, bestCoverage >= 0.90 else { return nil }
        // Sekundär-Raster: alles Übrige auf der Seite. Unbekannte Geometrie
        // ist unbeweisbar klein → Seite fällt raus (konservativ).
        var secondarySum = 0.0
        for resource in resources {
            if resource.objectID == dominant.objectID { continue }
            for placement in resource.placements where placement.pageIndex == pageIndex {
                guard placement.placedWidthPoints > 0,
                      placement.placedHeightPoints > 0 else { return nil }
                secondarySum += min(1.0,
                    placement.placedWidthPoints * placement.placedHeightPoints
                        / pageArea)
                if secondarySum > maximumSecondaryCoverage { return nil }
            }
        }
        return (dominant, secondarySum)
    }

    /// Bild-Voraussetzungen jenseits der Seitenklassifikation.
    private static func pageEligible(resource: PDFImageResource) -> Bool {
        guard resource.transformCapability.isSafe else { return false }
        // CMYK-Scans bleiben in der Druckfarbe (V1-Grenze); 1-bit-Raster
        // gehören dem Bilevel-Race (verlustfrei, §9.7).
        guard resource.colorSpace.allowsLossyReplacement,
              resource.bitsPerComponent == 8 else { return false }
        guard resource.maxEdge >= CompressionPlanner.minimumTransformableEdge,
              resource.pixelCount <= CompressionPlanner.maximumDecodablePixels
        else { return false }
        return true
    }

    /// Erzeugt die QA-geprüften Stufen für EINE Seite. `nil` = nicht
    /// segmentierbar / nicht messbar.
    private static func buildProvision(pageIndex: Int,
                                       resource: PDFImageResource,
                                       sourceDPI: Double,
                                       inputURL: URL,
                                       pixels: ImagePixelSource,
                                       rungs: [MRCEncoder.Rung],
                                       options: CompressionOptions,
                                       preset: QualityGatePreset,
                                       isCancelled: (() -> Bool)?) throws -> MRCProvision? {
        guard let raster = pixels.decodedImage(for: resource) else { return nil }
        guard let segmentation = MRCSegmenter.segment(raster) else { return nil }
        guard let mask = MRCEncoder.encodeMask(segmentation.mask) else { return nil }

        let rasterSize = PixelSize(width: raster.width, height: raster.height)
        let originalBytes = resource.encodedByteCount
        let objectID = resource.objectID
        let resourceID = CandidateSet.resourceID(for: objectID)
        // Der Name im Seiten-Namespace OHNE führenden Slash (die Bridge
        // ergänzt ihn beim Suchen selbst).
        guard let placement = resource.placements.first else { return nil }
        var resourceName = placement.resourceName
        if resourceName.hasPrefix("/") {
            resourceName.removeFirst()
        }
        guard !resourceName.isEmpty else { return nil }

        // Die Stufen sind voneinander unabhängig (eigene Ebenen, eigenes
        // Scratch-Dokument für die Seiten-QA) – sie laufen parallel und
        // werden in Leiterreihenfolge eingesammelt (2026-10-13). Vorher
        // nacheinander: Ein einseitiger Scan nutzte hier nur einen Kern.
        let prepared: [PreparedMRCCandidate?] = ParallelWork.map(count: rungs.count) { index in
            if let isCancelled, isCancelled() { return nil }
            let rung = rungs[index]
            let rungStart = ContinuousClock.now
            guard let layers = MRCEncoder.encodeLayers(
                segmentation: segmentation, mask: mask, rung: rung,
                sourceDPI: sourceDPI) else { return nil }
            guard layers.totalBytes < originalBytes else { return nil }

            let descriptor = buildDescriptor(
                pageIndex: pageIndex, objectID: objectID,
                resourceName: resourceName,
                sourceDPI: sourceDPI, rung: rung, rasterSize: rasterSize,
                layers: layers)
            let bundle = bundleData(descriptor: descriptor, layers: layers)

            // §13.10 – Seiten-QA über ein Scratch-Dokument: dieselbe
            // Rekonstruktion, die später der Executor fährt.
            let quality = autoreleasepool { () -> MRCPageQuality? in
                Self.renderQuality(inputURL: inputURL, pageIndex: pageIndex,
                                   objectID: objectID,
                                   resourceName: resourceName,
                                   descriptor: descriptor, bundle: bundle)
            }
            guard let quality, quality.meetsScanLimits else { return nil }
            let runtimeMs = stageMs(since: rungStart)

            return PreparedMRCCandidate(
                candidate: candidate(descriptor: descriptor, rung: rung,
                                     bundleBytes: bundle.count,
                                     originalBytes: originalBytes,
                                     quality: quality, runtimeMs: runtimeMs,
                                     workingBytes: Int64(rasterSize.pixelCount) * 6),
                bundle: bundle)
        }
        if let isCancelled, isCancelled() { throw CancellationError() }
        let candidates = prepared.compactMap { $0 }
        return candidates.isEmpty
            ? nil : MRCProvision(resourceID: resourceID, pageIndex: pageIndex,
                                 candidates: candidates)
    }

    /// Seiten-QA anhand eines temporär rekonstruierten Dokuments.
    static func renderQuality(inputURL: URL,
                                      pageIndex: Int,
                                      objectID: PDFObjectID,
                                      resourceName: String,
                                      descriptor: MRCCandidateDescriptor,
                                      bundle: Data) -> MRCPageQuality? {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("mrc-qa-\(UUID().uuidString).pdf")
        defer { try? fileManager.removeItem(at: outputURL) }
        do {
            let scratch = try PDFCoreDocument(path: inputURL.path)
            try applyBundle(scratch, pageIndex: pageIndex, descriptor: descriptor,
                            bundle: bundle)
            try scratch.save(to: outputURL)
        } catch {
            return nil   // Rekonstruktion verweigert → kein MRC-Kandidat
        }
        return MRCPageQA.measure(sourceURL: inputURL, outputURL: outputURL,
                                 pageIndex: pageIndex)
    }

    /// §13.8-Deskriptor inkl. aller Ausführungsfelder.
    static func buildDescriptor(pageIndex: Int,
                                objectID: PDFObjectID,
                                resourceName: String,
                                sourceDPI: Double,
                                rung: MRCEncoder.Rung,
                                rasterSize: PixelSize,
                                layers: MRCEncoder.EncodedLayers)
        -> MRCCandidateDescriptor {
        var descriptor = MRCCandidateDescriptor(
            pageIndex: pageIndex,
            maskDPI: sourceDPI,          // Maske bleibt auf Scan-Auflösung (§13.6)
            backgroundDPI: rung.backgroundDPI,
            backgroundQuality: rung.backgroundQuality,
            photoDPI: rung.photoDPI,
            photoQuality: rung.photoQuality)
        descriptor.maskCodec = layers.mask.codec
        descriptor.imageObjectNumber = objectID.objectNumber
        descriptor.imageObjectGeneration = objectID.generation
        descriptor.resourceName = resourceName
        descriptor.maskWidth = rasterSize.width
        descriptor.maskHeight = rasterSize.height
        descriptor.backgroundWidth = layers.background.width
        descriptor.backgroundHeight = layers.background.height
        descriptor.backgroundComponents = layers.background.components
        var rects: [Double] = []
        for photo in layers.photos {
            rects.append(photo.rect.minX)
            rects.append(photo.rect.minY)
            rects.append(photo.rect.width)
            rects.append(photo.rect.height)
        }
        descriptor.photoRects = rects
        descriptor.photoWidths = layers.photos.map(\.width)
        descriptor.photoHeights = layers.photos.map(\.height)
        descriptor.photoComponents = layers.photos.map(\.components)
        return descriptor
    }

    /// Bundle-Bytes in Zeichnungsreihenfolge [BG, Photos…, Maske].
    static func bundleData(descriptor: MRCCandidateDescriptor,
                           layers: MRCEncoder.EncodedLayers) -> Data {
        var entries: [MRCEncoder.Bundle.Entry] = [
            MRCEncoder.Bundle.Entry(
                kind: 0, isMask: false,
                components: layers.background.components,
                width: layers.background.width,
                height: layers.background.height,
                rect: nil, globals: Data(),
                data: layers.background.data)
        ]
        for photo in layers.photos {
            entries.append(MRCEncoder.Bundle.Entry(
                kind: 0, isMask: false, components: photo.components,
                width: photo.width, height: photo.height,
                rect: photo.rect, globals: Data(), data: photo.data))
        }
        entries.append(MRCEncoder.Bundle.Entry(
            kind: layers.mask.codec == .jbig2 ? 1 : 2,
            isMask: true, components: 1,
            width: descriptor.maskWidth, height: descriptor.maskHeight,
            rect: nil, globals: layers.mask.globals,
            data: layers.mask.data))
        return MRCEncoder.Bundle.encode(entries)
    }

    /// Layer aus Deskriptor + Bundle (Ausführung). Reihenfolge wie oben;
    /// zählt die Struktur nicht zum Deskriptor, wird verweigert.
    static func layers(from descriptor: MRCCandidateDescriptor,
                       bundle: Data) throws -> [PDFCoreDocument.MRCLayer] {
        guard let entries = MRCEncoder.Bundle.decode(bundle),
              entries.count == descriptor.photoRegionCount + 2 else {
            throw PDFCoreError.checkFailed
        }

        var layers: [PDFCoreDocument.MRCLayer] = []
        let background = entries[0]
        guard background.kind == 0, !background.isMask,
              background.width == descriptor.backgroundWidth,
              background.height == descriptor.backgroundHeight else {
            throw PDFCoreError.checkFailed
        }
        layers.append(PDFCoreDocument.MRCLayer(
            kind: .jpeg(components: descriptor.backgroundComponents),
            width: background.width, height: background.height,
            data: background.data, rect: nil))

        for index in 0..<descriptor.photoRegionCount {
            let entry = entries[1 + index]
            let rectX = descriptor.photoRects[index * 4]
            let rectY = descriptor.photoRects[index * 4 + 1]
            let rectW = descriptor.photoRects[index * 4 + 2]
            let rectH = descriptor.photoRects[index * 4 + 3]
            guard entry.kind == 0, !entry.isMask,
                  entry.width == descriptor.photoWidths[index],
                  entry.height == descriptor.photoHeights[index] else {
                throw PDFCoreError.checkFailed
            }
            layers.append(PDFCoreDocument.MRCLayer(
                kind: .jpeg(components: descriptor.photoComponents[index]),
                width: entry.width, height: entry.height,
                data: entry.data,
                rect: CGRect(x: rectX, y: rectY, width: rectW, height: rectH)))
        }

        let mask = entries[entries.count - 1]
        guard mask.isMask,
              mask.width == descriptor.maskWidth,
              mask.height == descriptor.maskHeight else {
            throw PDFCoreError.checkFailed
        }
        switch descriptor.maskCodec {
        case .jbig2:
            layers.append(PDFCoreDocument.MRCLayer(
                kind: .jbig2Mask(globals: mask.globals.isEmpty ? nil : mask.globals),
                width: mask.width, height: mask.height,
                data: mask.data, rect: nil))
        case .ccittG4:
            layers.append(PDFCoreDocument.MRCLayer(
                kind: .ccittG4Mask,
                width: mask.width, height: mask.height,
                data: mask.data, rect: nil))
        }
        return layers
    }

    /// Wendet das MRC-Bundle auf ein geöffnetes Dokument an (§13.7).
    static func applyBundle(_ document: PDFCoreDocument,
                            pageIndex: Int,
                            descriptor: MRCCandidateDescriptor,
                            bundle: Data) throws {
        let layers = try Self.layers(from: descriptor, bundle: bundle)
        try document.replacePageImageDrawWithLayers(
            pageIndex: pageIndex,
            imageObjectID: PDFObjectID(
                objectNumber: descriptor.imageObjectNumber,
                generation: descriptor.imageObjectGeneration),
            resourceName: descriptor.resourceName,
            layers: layers)
    }

    // MARK: Kandidat

    private static func candidate(descriptor: MRCCandidateDescriptor,
                                  rung: MRCEncoder.Rung,
                                  bundleBytes: Int,
                                  originalBytes: Int,
                                  quality: MRCPageQuality,
                                  runtimeMs: Double,
                                  workingBytes: Int64) -> CompressionCandidate {
        let objectID = PDFObjectID(
            objectNumber: descriptor.imageObjectNumber,
            generation: descriptor.imageObjectGeneration)
        let id = CandidateID("mrc-\(objectID.objectNumber)-\(objectID.generation)"
                             + "-\(rung.name)")
        let kind = CandidateKind.mrc(descriptor)
        // Seiten-QA (§13.10) in Kandidatenmetriken: CAR als Kantengewicht
        // (1 − Fläche mit wahrnehmbarem Unterschied); ΔE entfällt (die
        // Schranken tragen die Messwerte bereits).
        return CompressionCandidate(
            id: id,
            objectID: objectID,
            kind: kind,
            metrics: CandidateMetrics(
                encodedBytes: bundleBytes,
                globalSSIM: quality.globalSSIM,
                p05TileSSIM: quality.p05TileSSIM,
                edgeScore: max(0, 1 - quality.changedAreaRatio),
                textScore: nil,
                deltaE76: nil,
                psnr: nil,
                expectedRuntimeMs: runtimeMs,
                expectedPeakWorkingBytes: workingBytes,
                compatibilityRisk: descriptor.maskCodec == .jbig2 ? 0.2 : 0.1,
                semanticRisk: 0.1),
            isLossless: false,
            pages: [descriptor.pageIndex],
            reason: "MRC-Seitenbündel (§13), Stufe \(rung.name): "
                + String(format: "BG %.0f DPI/Q%.0f, QA SSIM %.4f, p05 %.4f, "
                            + "CAR %.4f, inkDelta %.5f",
                         rung.backgroundDPI, rung.backgroundQuality * 100,
                         quality.globalSSIM, quality.p05TileSSIM,
                         quality.changedAreaRatio, quality.inkDelta))
    }

    // MARK: Executor-Regeneration

    /// Deterministische Regeneration des Bundles aus dem Deskriptor –
    /// derselbe Weg wie in der Planung (dieselben Konstanten, dieselbe
    /// Pixelquelle), damit verlorene Payloads (Budget/Metadata-only) den
    /// Executor nicht scheitern lassen.
    static func regenerateBundle(descriptor: MRCCandidateDescriptor,
                                 resource: PDFImageResource,
                                 pixels: ImagePixelSource) -> Data? {
        guard let raster = pixels.decodedImage(for: resource),
              let segmentation = MRCSegmenter.segment(raster) else { return nil }
        let maskData: Data
        let globals: Data
        switch descriptor.maskCodec {
        case .jbig2:
            guard let encoded = BilevelCodec.encodeJBIG2(segmentation.mask) else {
                return nil
            }
            maskData = encoded.page
            globals = encoded.globals
        case .ccittG4:
            guard let encoded = BilevelCodec.encodeG4(segmentation.mask) else {
                return nil
            }
            maskData = encoded
            globals = Data()
        }
        let mask = MRCEncoder.maskEncoding(codec: descriptor.maskCodec,
                                           data: maskData, globals: globals)
        let rung = MRCEncoder.Rung(
            name: "regen",
            backgroundDPI: descriptor.backgroundDPI,
            backgroundQuality: descriptor.backgroundQuality,
            photoDPI: descriptor.photoDPI,
            photoQuality: descriptor.photoQuality)
        guard let layers = MRCEncoder.encodeLayers(
            segmentation: segmentation, mask: mask, rung: rung,
            sourceDPI: descriptor.maskDPI) else { return nil }
        return bundleData(descriptor: descriptor, layers: layers)
    }
}
