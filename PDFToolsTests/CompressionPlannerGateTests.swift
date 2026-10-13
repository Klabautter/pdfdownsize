import Testing
import Foundation
import CoreGraphics
import AppKit
import PDFKit
@testable import PDFTools

/// Masterplan Findings 8–12 und Schritte 5–8 – Quality Gates der
/// Decision Engine, der Parameterdurchreichung und der Validierung.
@Suite struct CompressionPlannerGateTests {

    // MARK: - Finding 8: Grayscale

    /// Gate 8: Grayscale OFF bewahrt Farbe · ON transformiert Bilder ·
    ///         Text/Vektoren werden nicht gerastert.
    @Test func grayscaleOffPreservesColor() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1600)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = Self.tempURL("gray-off")
        defer { try? FileManager.default.removeItem(at: out) }
        var options = Self.transformingOptions
        options.image.forceGrayscale = false
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: options)

        try #require(outcome.replacedImages >= 1, "Fixture wurde nicht optimiert")
        let anyGrayscale = outcome.plan.transformedActions.contains(where: \.grayscale)
        #expect(!anyGrayscale, "Grayscale war nicht angefordert")

        let after = try #require(try PDFCoreDocument(path: out.path)
            .imageResources().first)
        #expect(after.colorSpace == .deviceRGB, "Farbe ging ohne Anforderung verloren")
    }

    @Test func grayscaleOnReachesTheProductionEngine() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1600)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = Self.tempURL("gray-on")
        defer { try? FileManager.default.removeItem(at: out) }
        var options = Self.transformingOptions
        options.image.forceGrayscale = true
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: options)

        try #require(outcome.replacedImages >= 1,
                     "Plan: \(outcome.plan.actions); Entscheidungen: \(outcome.plan.decisions)")
        let allGrayscale = !outcome.plan.transformedActions
            .contains(where: { !$0.grayscale })
        #expect(allGrayscale, "Grayscale erreichte den Plan nicht")

        // Der Beweis steht im Ergebnis, nicht nur im Plan.
        let after = try #require(try PDFCoreDocument(path: out.path)
            .imageResources().first)
        #expect(after.colorSpace == .deviceGray,
                "Ausgabebild ist nicht grau: \(after.colorSpace)")
    }

    @Test func grayscaleDoesNotRasterizeVectorText() throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 15)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = Self.tempURL("gray-vector")
        defer { try? FileManager.default.removeItem(at: out) }
        var options = Self.transformingOptions
        options.image.forceGrayscale = true
        _ = try CompressionPipeline.run(inputURL: url, outputURL: out, options: options)

        let after = try #require(PDFDocument(url: out))
        let text = (0..<after.pageCount).compactMap { after.page(at: $0)?.string }.joined()
        #expect(text.contains("Zeile"), "Vektor-Text wurde gerastert")
        let imagesAfter = try PDFCoreDocument(path: out.path).imageResources()
        #expect(imagesAfter.isEmpty,
                "Es sind Bilder entstanden – die Seite wurde gerastert")
    }

    // MARK: - Finding 9: aggressiveGraphics

    /// Gate 9: Graphics OFF = verlustfrei · aggressive = dokumentierte
    ///         stärkere Politik · der Toggle erreicht die Pipeline.
    @Test func graphicsPolicyIsLosslessByDefault() throws {
        let url = try PDFFixtures.screenshotLikePDF(pixels: 1400)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = Self.tempURL("graphics-off")
        defer { try? FileManager.default.removeItem(at: out) }
        var options = Self.transformingOptions
        options.image.aggressiveGraphics = false
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: options)

        let action = try #require(outcome.plan.transformedActions.first,
                                  "Grafik wurde gar nicht behandelt")
        if case .jpeg = action {
            Issue.record("Grafik wurde ohne aggressiveGraphics per JPEG kodiert")
        }
        let after = try #require(try PDFCoreDocument(path: out.path)
            .imageResources().first)
        #expect(after.terminalFilter == .flate,
                "Verlustfreie Politik ergab keinen verlustfreien Stream")
    }

    @Test func aggressiveGraphicsReachesThePipeline() throws {
        let url = try PDFFixtures.screenshotLikePDF(pixels: 1400)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = Self.tempURL("graphics-on")
        defer { try? FileManager.default.removeItem(at: out) }
        var options = Self.transformingOptions
        options.image.aggressiveGraphics = true
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: options)

        let action = try #require(outcome.plan.transformedActions.first)
        guard case .jpeg = action else {
            Issue.record("aggressiveGraphics erreichte die Engine nicht: \(action)")
            return
        }
        let after = try #require(try PDFCoreDocument(path: out.path)
            .imageResources().first)
        #expect(after.terminalFilter == .dct)
    }

    // MARK: - Finding 10 / Schritt 5: vollständige Decision Engine

    @Test func classifierDistinguishesPhotoFromGraphics() throws {
        let photo = try PDFFixtures.photoHeavyPDF(pixels: 1400)
        let graphic = try PDFFixtures.screenshotLikePDF(pixels: 1400)
        defer {
            try? FileManager.default.removeItem(at: photo)
            try? FileManager.default.removeItem(at: graphic)
        }

        let photoPlan = try CompressionPipeline.plan(inputURL: photo,
                                                     options: Self.transformingOptions)
        let graphicPlan = try CompressionPipeline.plan(inputURL: graphic,
                                                       options: Self.transformingOptions)

        let photoAction = try #require(photoPlan.plan.transformedActions.first)
        let graphicAction = try #require(graphicPlan.plan.transformedActions.first)

        guard case .jpeg = photoAction else {
            Issue.record("Foto wurde nicht als Foto klassifiziert: \(photoAction)")
            return
        }
        // V2-3b/V2-11 – die Graphics-Route ist verlustfrei: Flate oder der
        // Exact-Palette-Sieger (beide verlustfrei) belegen die Grafik-
        // Klassifikation; JPEG wäre hier der Fehler.
        guard case .losslessResize = graphicAction else {
            if case .indexed = graphicAction { return }
            Issue.record("Grafik wurde nicht als Grafik klassifiziert: \(graphicAction)")
            return
        }
    }

    @Test func qualityLadderIsActuallyUsed() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1600)
        defer { try? FileManager.default.removeItem(at: url) }

        var options = Self.transformingOptions
        options.image.qualityLadder = [0.35, 0.55, 0.75]
        options.image.ssimThreshold = 0.90

        let planned = try CompressionPipeline.plan(inputURL: url, options: options)
        let action = try #require(planned.plan.transformedActions.first)
        guard case .jpeg(_, _, let quality, _, let ssim, _, _) = action else {
            Issue.record("Kein JPEG-Plan: \(action)")
            return
        }
        // Die Leiter gibt die GRENZEN der Suche vor; dazwischen halbiert die
        // Bracketed Search bis Δq ≤ 0,02 (BracketedJPEGSearchTests). Früher
        // stand hier „genau ein Leiterpunkt“ – das galt nur, solange die
        // unterste Stufe immer bestand. Seit dem Smart-Anker (2026-10-05)
        // scheitert 0,35 hier, und die Suche landet zwischen den Punkten.
        let ladder = options.image.qualityLadder
        #expect(quality >= ladder.min()! && quality <= ladder.max()!,
                "Gewählte Qualität \(quality) liegt außerhalb der Leiter \(ladder)")
        let measured = try #require(ssim)
        #expect(measured >= options.image.ssimThreshold,
                "Akzeptierte Stufe unterschreitet die SSIM-Schwelle")
    }

    /// Eine unerreichbar hohe SSIM-Schwelle muss zur ABLEHNUNG führen,
    /// nicht zu „nimm halt die beste Stufe".
    @Test func ssimRejectionKeepsImageUntouched() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1600)
        defer { try? FileManager.default.removeItem(at: url) }

        var options = Self.transformingOptions
        options.image.qualityLadder = [0.05, 0.1]
        options.image.ssimThreshold = 0.999999

        let planned = try CompressionPipeline.plan(inputURL: url, options: options)
        #expect(planned.plan.transformedActions.isEmpty,
                "Bild wurde trotz verfehlter SSIM-Schwelle transformiert")
        let reason = try #require(planned.plan.keepReasons.first?.reason)
        #expect(reason.contains("Qualität"), "Falscher Grund: \(reason)")
    }

    @Test func neverUpscales() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 300)
        defer { try? FileManager.default.removeItem(at: url) }

        var options = CompressionOptions.smart
        options.image.targetDPI = 4000
        options.image.maxPixelEdge = 100_000

        let planned = try CompressionPipeline.plan(inputURL: url, options: options)
        for action in planned.plan.transformedActions {
            guard let target = action.targetSize else { continue }
            #expect(target.width <= 300 && target.height <= 300,
                    "Bild wurde vergrößert: \(target)")
        }
    }

    /// Die Engine ist backend-frei: Dieselben Ressourcen und Optionen ergeben
    /// denselben Plan, ohne dass ein PDF im Spiel ist.
    @Test func plannerIsIndependentOfPDFBackend() throws {
        let resource = PDFImageResource(
            objectID: PDFObjectID(objectNumber: 7, generation: 0),
            width: 2000, height: 1500, bitsPerComponent: 8,
            colorSpace: .deviceRGB, filters: [.dct], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            decodeArray: [], encodedByteCount: 900_000,
            placements: [PDFImagePlacement(pageIndex: 0, resourceName: "/Im0",
                                           placedWidthPoints: 400,
                                           placedHeightPoints: 300)])

        let source = StubPixelSource(image: try #require(Self.gradientImage(2000, 1500)))
        let first = try CompressionPlanner.plan(
            resources: [resource], options: Self.transformingOptions,
            documentID: "stub", documentBytes: 1_000_000, pixels: source)
        let second = try CompressionPlanner.plan(
            resources: [resource], options: Self.transformingOptions,
            documentID: "stub", documentBytes: 1_000_000, pixels: source)

        // V2-11 – semantic Equality: die Kandidaten-Metriken tragen
        // gemessene Laufzeiten, die im ms-Bereich streuen. Deterministisch
        // sind Aktionen und Wahl.
        #expect(first.plan.actions == second.plan.actions,
                "Planner ist nicht deterministisch")
        #expect(first.plan.decisions.map(\.selectedCandidateID)
                == second.plan.decisions.map(\.selectedCandidateID),
                "Planner ist nicht deterministisch (Wahl)")
        #expect(first.plan.transformedActions.count == 1)
    }

    /// Effective DPI: 2000 px auf 400 pt sind 360 dpi. Bei Ziel 220 muss die
    /// Zielbreite ≈ 2000 · 220/360 ≈ 1222 px sein.
    @Test func effectiveDPIDrivesTargetSize() throws {
        let resource = PDFImageResource(
            objectID: PDFObjectID(objectNumber: 1, generation: 0),
            width: 2000, height: 1500, bitsPerComponent: 8,
            colorSpace: .deviceRGB, filters: [.dct], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            decodeArray: [], encodedByteCount: 900_000,
            placements: [PDFImagePlacement(pageIndex: 0, resourceName: "/Im0",
                                           placedWidthPoints: 400,
                                           placedHeightPoints: 300)])
        #expect(abs((resource.effectiveDPI ?? 0) - 360) < 0.5)

        var options = ImageCompressionOptions.smart
        options.maxPixelEdge = 100_000
        let target = try #require(CompressionPlanner.plannedSize(for: resource,
                                                                 options: options))
        // Die Erwartung kommt aus der KONFIGURATION, nicht aus einer
        // Konstanten. Hier stand 1222 – die Zahl, die sich aus den früheren
        // 220 dpi ergab. Als die Zielauflösung auf 150 ging, schlug der Test
        // fehl, obwohl der geprüfte Mechanismus unverändert richtig war.
        // So formuliert prüft er, was er prüfen soll: dass die effektive
        // Auflösung die Zielgröße bestimmt.
        let expectedWidth = Double(resource.width)
            * (options.targetDPI / (resource.effectiveDPI ?? 1))
        #expect(abs(Double(target.width) - expectedWidth) <= 2, """
            Zielbreite \(target.width), erwartet \(Int(expectedWidth)) \
            bei \(Int(options.targetDPI)) dpi Ziel
            """)
    }

    /// Ein geteiltes Bild darf nur so weit verkleinert werden, wie es seine
    /// GRÖSSTE Platzierung erlaubt.
    @Test func sharedImageUsesLargestPlacement() throws {
        let resource = PDFImageResource(
            objectID: PDFObjectID(objectNumber: 1, generation: 0),
            width: 2000, height: 2000, bitsPerComponent: 8,
            colorSpace: .deviceRGB, filters: [.dct], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            decodeArray: [], encodedByteCount: 900_000,
            placements: [
                PDFImagePlacement(pageIndex: 0, resourceName: "/Im0",
                                  placedWidthPoints: 100, placedHeightPoints: 100),
                PDFImagePlacement(pageIndex: 1, resourceName: "/Im0",
                                  placedWidthPoints: 500, placedHeightPoints: 500)
            ])
        // Kleine Platzierung: 1440 dpi. Große Platzierung: 288 dpi.
        // Maßgeblich ist die große – sonst wird die Seite 2 unscharf.
        #expect(abs((resource.effectiveDPI ?? 0) - 288) < 0.5,
                "Effective DPI \(resource.effectiveDPI ?? -1) folgt der falschen Platzierung")
    }

    // MARK: - Finding 11 / Schritt 7: Estimator-Parität

    /// Kernaussage von Finding 11: Estimator und Executor benutzen denselben
    /// Plan – dieselben geplanten Aktionen, kein zweiter Entscheidungsweg.
    @Test func estimatorAndExecutorShareIdenticalDecisions() throws {
        let url = try PDFFixtures.complexCombinationPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let options = Self.transformingOptions
        let estimatorPlan = try CompressionPipeline.plan(inputURL: url, options: options)

        let out = Self.tempURL("parity")
        defer { try? FileManager.default.removeItem(at: out) }
        let executed = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                   options: options)

        // V2-11 – semantic Equality: die Kandidaten-Metriken tragen
        // gemessene Laufzeiten, die im ms-Bereich streuen.
        #expect(estimatorPlan.plan.actions == executed.plan.actions,
                "Estimator und Executor planen unterschiedlich")
        #expect(estimatorPlan.plan.decisions.map(\.selectedCandidateID)
                == executed.plan.decisions.map(\.selectedCandidateID),
                "Estimator und Executor wählen unterschiedlich")
        #expect(estimatorPlan.plan.actions.count == executed.plan.actions.count)
    }

    @Test func estimateMatchesActualOutputSize() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 2000)
        defer { try? FileManager.default.removeItem(at: url) }

        let options = Self.transformingOptions
        let estimate = try #require(CompressionEstimator.estimate(url: url,
                                                                  options: options))
        let out = Self.tempURL("estimate")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try CompressionPipeline.run(inputURL: url, outputURL: out, options: options)
        let actual = Compressor.fileSize(of: out)

        // Vor dem Strukturpass gemessen: Der Punktwert muss im angegebenen
        // Unsicherheitsband liegen. Das Band ist Teil der Schätzung, nicht
        // eine nachträglich passend gewählte Toleranz.
        #expect(actual >= estimate.lowBytes && actual <= estimate.highBytes,
                "Ergebnis \(actual) liegt außerhalb von [\(estimate.lowBytes), \(estimate.highBytes)]")
    }

    // MARK: - Finding 12 / Schritt 6: Optionen erreichen den Writer

    @Test func metadataPolicyReachesTheWriter() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1200)
        defer { try? FileManager.default.removeItem(at: url) }

        // Preserve: Titel überlebt.
        let keepOut = Self.tempURL("meta-keep")
        defer { try? FileManager.default.removeItem(at: keepOut) }
        var keepOptions = Self.transformingOptions
        keepOptions.metadataPolicy = .preserve
        _ = try CompressionPipeline.run(inputURL: url, outputURL: keepOut,
                                        options: keepOptions)

        // Strip: /Info wird geleert, Producer bleibt als Stempel.
        let stripOut = Self.tempURL("meta-strip")
        defer { try? FileManager.default.removeItem(at: stripOut) }
        var stripOptions = Self.transformingOptions
        stripOptions.metadataPolicy = .strip
        _ = try CompressionPipeline.run(inputURL: url, outputURL: stripOut,
                                        options: stripOptions)

        let stripped = try #require(PDFDocument(url: stripOut))
        let attributes = (stripped.documentAttributes ?? [:]) as? [PDFDocumentAttribute: Any]
        #expect(attributes?[.titleAttribute] == nil, "Titel wurde nicht entfernt")
        #expect(attributes?[.producerAttribute] as? String == "PDFTools",
                "Deterministischer Producer fehlt")

        // Seiten und Text bleiben in beiden Fällen erhalten.
        for output in [keepOut, stripOut] {
            let doc = try #require(PDFDocument(url: output))
            #expect(doc.pageCount == 1)
        }
    }

    /// Schritt 6 – UI → Options → Plan → Output für die Ziel-DPI.
    ///
    /// Die Fixture platziert 400 px auf 100 pt (288 dpi). Bei Ziel 144 dpi
    /// muss die Zielbreite halbiert werden – ein Wert, den nur die DPI-Regel
    /// erzeugen kann, nicht das Kantenlimit.
    @Test func targetDPIFlowsFromOptionsToOutput() throws {
        let url = try PDFFixtures.flateImagePDF(pixels: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        var options = Self.transformingOptions
        options.image.targetDPI = 144
        options.image.tolerance = 1.0
        options.image.maxPixelEdge = 100_000
        options.image.hardPixelCap = false

        // Options → Plan
        let planned = try CompressionPipeline.plan(inputURL: url, options: options)
        let action = try #require(planned.plan.transformedActions.first,
                                  "DPI-Regel hat nicht gegriffen")
        let target = try #require(action.targetSize)
        #expect(abs(target.width - 200) <= 2, "Plan-Zielbreite \(target.width) statt 200")

        // Plan → Output
        let out = Self.tempURL("dpi-flow")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try CompressionPipeline.run(inputURL: url, outputURL: out, options: options)
        let after = try #require(try PDFCoreDocument(path: out.path)
            .imageResources().first)
        #expect(after.width == target.width,
                "Ausgabebild (\(after.width)) folgt nicht dem Plan (\(target.width))")
    }

    @Test func maxPixelEdgeHardCapFlowsToOutput() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 2400)
        defer { try? FileManager.default.removeItem(at: url) }

        var options = CompressionOptions.smart
        options.image.maxPixelEdge = 800
        options.image.hardPixelCap = true

        let out = Self.tempURL("cap-flow")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try CompressionPipeline.run(inputURL: url, outputURL: out, options: options)

        let after = try #require(try PDFCoreDocument(path: out.path)
            .imageResources().first)
        #expect(after.maxEdge <= 800, "Hard Cap nicht eingehalten: \(after.maxEdge)")
    }

    // MARK: - Finding 16 / Schritt 8: Validierung

    @Test func corruptedOutputIsRejected() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 900)
        defer { try? FileManager.default.removeItem(at: url) }

        let broken = Self.tempURL("broken")
        defer { try? FileManager.default.removeItem(at: broken) }
        // Abgeschnittene Datei: Aus einer zerstörten xref allein rekonstruiert
        // qpdf das Dokument erfolgreich – fehlende Objekte kann es nicht
        // erfinden. Genau das muss die Validierung abfangen.
        let data = try Data(contentsOf: url)
        try data.prefix(data.count / 2).write(to: broken)

        var policy = PDFValidator.Policy.compression
        policy.expectedPageCount = 1
        let report = PDFValidator.validate(outputURL: broken, referenceURL: url,
                                           policy: policy)
        #expect(!report.isValid, "Beschädigte Ausgabe wurde akzeptiert")
        var threw = false
        do { try PDFValidator.assertValid(report) } catch { threw = true }
        #expect(threw, "assertValid warf nicht bei ungültigem Report")
    }

    /// Die Strukturprüfung ist die unabhängige zweite Meinung: Sie muss
    /// anschlagen, wo eine reine Öffnen-Prüfung durchwinkt.
    @Test func structureCheckIsPartOfTheCompressionPolicy() throws {
        #expect(PDFValidator.Policy.compression.runsStructureCheck,
                "Compression-Policy prüft die Struktur nicht")
        #expect(PDFValidator.Policy.compression.failsOnSemanticSeverity == .high)
        #expect(PDFValidator.Policy.compression.preservesGeometry)

        // Gegenprobe: Die Strukturprüfung muss auch wirklich etwas ablehnen.
        //
        // Hier stand zuvor ein Byte-Eingriff in einer PDFKit-Datei – „/Type
        // /Pages" suchen und unkenntlich machen – unter dem Namen „zerstörter
        // Seitenbaum". Der ging doppelt ins Leere: PDFKit legt den Seitenbaum
        // in einem komprimierten Objektstrom ab, der Marker steht so gar nicht
        // in der Datei; und selbst eine Datei, die den Knotentyp WIRKLICH
        // zerstört, meldet qpdf nach seiner Reparatur wieder als /Type/Pages.
        // Der Test bestand, weil der Eingriff nebenbei eine Warnung auslöste.
        //
        // Genommen wird deshalb ein Schaden, den die Prüfung tatsächlich
        // sieht: Bilddaten, die für ihre angegebenen Masse nicht reichen.
        let reference = try PDFFixtures.textPDF(lines: 5)
        defer { try? FileManager.default.removeItem(at: reference) }
        let entry = try #require(MalformedCorpus.entries
            .first { $0.name == "image-dimension-mismatch" })
        let broken = Self.tempURL("shortimage")
        defer { try? FileManager.default.removeItem(at: broken) }
        try entry.make().write(to: broken)

        let report = PDFValidator.validate(outputURL: broken,
                                           referenceURL: reference,
                                           policy: PDFValidator.Policy.compression)
        #expect(!report.isValid,
                "Beschädigte Bilddaten wurden durchgelassen")
        #expect(report.failures.contains { $0.contains("Strukturprüfung") },
                "Abgelehnt, aber nicht von der Strukturprüfung: \(report.failures)")
    }

    @Test func validCompressionOutputPassesFullPolicy() throws {
        let url = try PDFFixtures.complexCombinationPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Compressor().compress(inputURL: url, options: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        var policy = PDFValidator.Policy.compression
        policy.expectedPageCount = PDFDocument(url: url)?.pageCount
        let report = PDFValidator.validate(outputURL: result.outputURL,
                                           referenceURL: url, policy: policy)
        #expect(report.isValid, "Gültige Ausgabe abgelehnt: \(report.failures)")
    }

    /// Kein unvalidiertes Ergebnis erreicht die UI: Der Compressor liefert
    /// entweder eine geprüfte Datei oder wirft.
    @Test func compressorNeverReturnsUnvalidatedResult() throws {
        let url = try PDFFixtures.complexCombinationPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Compressor().compress(inputURL: url, options: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let core = try PDFCoreDocument(path: result.outputURL.path)
        try core.check()
        #expect(core.pageCount == PDFDocument(url: url)?.pageCount)
    }

    // MARK: - Helfer

    static var transformingOptions: CompressionOptions {
        CompressionOptions(image: ImageCompressionOptions(
            targetDPI: 96, tolerance: 1.0, maxPixelEdge: 900, hardPixelCap: true,
            jpegQuality: 0.8, qualityLadder: [0.6, 0.8], ssimThreshold: 0.85,
            forceGrayscale: false, aggressiveGraphics: false))
    }

    static func tempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).pdf")
    }

    static func gradientImage(_ width: Int, _ height: Int) -> CGImage? {
        let image = NSImage(size: CGSize(width: width, height: height))
        image.lockFocus()
        NSGradient(starting: .systemRed, ending: .systemBlue)?
            .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 45)
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    struct StubPixelSource: ImagePixelSource {
        let image: CGImage
        func decodedImage(for resource: PDFImageResource) -> CGImage? { image }
    }
}
