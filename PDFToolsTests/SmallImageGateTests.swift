import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Masterplan §10.4 (V2-4) – Small-Image-Bypass ENTFERNT + §10.3
/// Katastrophen-Floor am kleinen Bild.
///
/// FRÜHER (Bestandsverhalten, hier bewusst fortgeschrieben): Bilder mit
/// Kante < 200 px wurden in der entfernten `planJPEG`-Leiter, in
/// `ImageProcessor.adaptiveJPEG` (ebenfalls entfernt, V2-11) und in der
/// Candidate Engine (`jpegPolicy`) unkontrolliert kodiert – SSIM wurde mit
/// 1.0 gemeldet, das Multi-Gate sprang übersprungen. Ein kleines Diagramm
/// galt als „zu klein zum Prüfen“.
///
/// SEIT §10.4: Kleine Bilder laufen durch DASSELBE Gate;
/// `QualityGates.sample` vergleicht sie VOLLSTÄNDIG (Kanten ≤ 320 werden
/// nicht heruntersampelt → vollständiger Pixelvergleich auf Original-
/// auflösung, Edge-/Text-Gate ohne Downsampling-Artefakte). Ein kleines
/// Diagramm mit zerstörendem Kandidat wird jetzt VERWORFEN statt durch-
/// gelassen – und der §10.3-Katastrophen-Floor greift auch hinter
/// Custom/fixed (Produktsicherheit). Seit V2-11 gibt es nur den
/// Candidate-Pfad – die früheren Legacy-Zwillingsfälle prüfen denselben
/// Produktionspfad.
@Suite struct SmallImageGateTests {

    // MARK: Hilfen

    /// Liefert für JEDE Anfrage dasselbe Bild (Muster
    /// plannerIsIndependentOfPDFBackend, wie CompressionPlannerMultiGateTests).
    private struct FixedPixelSource: ImagePixelSource {
        let image: CGImage
        func decodedImage(for resource: PDFImageResource) -> CGImage? { image }
    }

    private static func dctResource(_ image: CGImage, objectNumber: Int,
                                    placedWidthPoints: Double) -> PDFImageResource {
        let heightFactor = Double(image.height) / Double(image.width)
        return PDFImageResource(
            objectID: PDFObjectID(objectNumber: objectNumber, generation: 0),
            width: image.width, height: image.height, bitsPerComponent: 8,
            colorSpace: .deviceRGB, filters: [.dct], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            decodeArray: [], encodedByteCount: 900_000,
            placements: [PDFImagePlacement(pageIndex: 0, resourceName: "/Im0",
                                           placedWidthPoints: placedWidthPoints,
                                           placedHeightPoints: placedWidthPoints * heightFactor)])
    }

    private static func adaptiveOptions(targetDPI: Double, maxPixelEdge: Int,
                                        hardPixelCap: Bool, aggressiveGraphics: Bool,
                                        ladder: [Double], threshold: Double)
        -> CompressionOptions {
        CompressionOptions(image: ImageCompressionOptions(
            targetDPI: targetDPI, tolerance: 1.15, maxPixelEdge: maxPixelEdge,
            hardPixelCap: hardPixelCap, forceGrayscale: false,
            aggressiveGraphics: aggressiveGraphics,
            qualityPolicy: .adaptive(ladder: ladder, minimumSSIM: threshold)))
    }

    private static func fixedOptions(targetDPI: Double, maxPixelEdge: Int,
                                     hardPixelCap: Bool, quality: Double)
        -> CompressionOptions {
        CompressionOptions(image: ImageCompressionOptions(
            targetDPI: targetDPI, tolerance: 1.15, maxPixelEdge: maxPixelEdge,
            hardPixelCap: hardPixelCap, forceGrayscale: false,
            aggressiveGraphics: false,
            qualityPolicy: .fixed(quality: quality)))
    }

    /// Text auf Foto-Grund – klassifiziert als photo, nicht two-valued
    /// (kein Bilevel-Pfad).
    static func noisyText(width: Int = 800, height: Int = 600) -> CGImage? {
        guard let base = QualityGatesTests.photoImage(width: width, height: height),
              let text = QualityGatesTests.textPattern(width: width, height: height),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setBlendMode(.multiply)
        ctx.draw(text, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Text auf Grau-Verlauf – Grafik-Klasse, nicht two-valued.
    static func textOnGradient(width: Int = 800, height: Int = 600) -> CGImage? {
        guard let text = QualityGatesTests.textPattern(width: width, height: height),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [CGColor(gray: 0.90, alpha: 1),
                                                 CGColor(gray: 1.0, alpha: 1)] as CFArray,
                                        locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: CGFloat(height)), options: [])
        ctx.setBlendMode(.multiply)
        ctx.draw(text, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: §10.4 – vollständiger Pixelvergleich bei kleinen Bildern

    /// Die Stichprobe kleiner Bilder ist das VOLLständige Raster (nur an
    /// das 8er-SSIM-Fenster ausgerichtet) – der Gate-Vergleich erfolgt auf
    /// Originalauflösung; große Bilder werden wie bisher auf 320 px
    /// heruntersampelt.
    @Test func kleineBilderWerdenVollstaendigVerglichen() throws {
        let small = try #require(QualityGatesTests.textPattern(width: 176, height: 132))
        let smallSample = try #require(QualityGates.sample(small))
        #expect(smallSample.width == 176 && smallSample.height == 128,
                "Kleines Bild darf nicht heruntersampelt werden: \(smallSample.width)x\(smallSample.height)")

        let large = try #require(QualityGatesTests.textPattern(width: 800, height: 600))
        let largeSample = try #require(QualityGates.sample(large))
        #expect(largeSample.width == 320 && largeSample.height == 240,
                "Großes Bild sampelt wie bisher auf die Gate-Kante")
    }

    // MARK: §10.4 – kleines Diagramm wird GEPRÜFT (Legacy-Planner)

    /// Konstruierbarer Fall: 800×600-Textgrafik, Zielraster 176×132 (das
    /// alte Bypass-Fenster!), Leiter mit der Katastrophen-Stufe q0.15
    /// (raised der [0.05]-Leiter). FRÜHER: Bypass → JPEG q0.15 ungeprüft
    /// ausgeliefert (SSIM = 1.0 gemeldet). HEUTE: Das kleine Diagramm wird
    /// gemessen – die Stufe reißt die smart-Graphics-Kachel-Floors und das
    /// Bild bleibt stehen.
    @Test(.hangGuard) func kleinesDiagrammWirdGeprueftStattZuBypassen() throws {
        let image = try #require(Self.textOnGradient())
        let resource = Self.dctResource(image, objectNumber: 3, placedWidthPoints: 180)
        // DPI 320 → DPI-Shrink auf 240×180, hartes Kantenlimit 176 → Zielraster
        // 176×132 – bewusst UNTER der alten 200-px-Bypass-Grenze.
        let options = Self.adaptiveOptions(targetDPI: 96, maxPixelEdge: 176,
                                           hardPixelCap: true, aggressiveGraphics: true,
                                           ladder: [0.05], threshold: 0.90)

        let target = try #require(CompressionPlanner.plannedSize(for: resource,
                                                                 options: options.image))
        #expect(target == PixelSize(width: 176, height: 132),
                "Fixture muss das alte Bypass-Fenster (< 200) treffen: \(target)")

        // Selbstbeweis: DIESELBE Messung, die der Planner anstellt, reißt das
        // smart-Gate der Grafikklasse (p05/edge/text) – der Bypass hätte sie
        // nie gesehen.
        let resized = try #require(ImageResampler.resize(image, to: target,
                                                         grayscale: true))
        let candidate = try #require(QualityGatesTests.jpegVariant(resized, quality: 0.15))
        let measurement = try #require(QualityGates.measure(reference: resized,
                                                            candidate: candidate))
        guard case .fail(let violated) = QualityGates.qualityVerdict(
            policy: .policy(preset: .smart, imageClass: .graphics),
            measurement: measurement) else {
            Issue.record("Fixture soll das smart-Gate reißen: \(measurement)")
            return
        }
        #expect(violated.contains { $0 != .globalSSIM },
                "Kachel-Metriken sollen reißen: \(violated)")

        let planned = try CompressionPlanner.plan(
            resources: [resource], options: options,
            documentID: "smallgate-legacy", documentBytes: 900_000,
            pixels: FixedPixelSource(image: image))
        #expect(planned.plan.transformedActions.isEmpty,
                "Der zerstörende Kleinkandidat wurde ausgeliefert: \(planned.plan.actions)")
        let reason = try #require(planned.plan.keepReasons.first?.reason)
        #expect(reason.contains("Qualität"), "Falscher Grund: \(reason)")
    }

    /// Derselbe Fall im Candidate-Pfad: die entfernte Kleinbild-Ausnahme in
    /// `CandidateGenerator.jpegPolicy` hätte den Rung UNGATED als Kandidaten
    /// aufgenommen – heute scheitert er am Bracketed-Gate, es entsteht kein
    /// lossy Kandidat, die Wahl fällt auf KEEP zurück.
    @Test(.hangGuard) func kleinesDiagrammWirdAuchImCandidatePfadGeprueft() throws {
        let image = try #require(Self.textOnGradient())
        let resource = Self.dctResource(image, objectNumber: 4, placedWidthPoints: 180)
        var options = Self.adaptiveOptions(targetDPI: 96, maxPixelEdge: 176,
                                           hardPixelCap: true, aggressiveGraphics: true,
                                           ladder: [0.05], threshold: 0.90)
        options.featureFlags.candidateEngine = true

        let planned = try CompressionPlanner.plan(
            resources: [resource], options: options,
            documentID: "smallgate-candidate", documentBytes: 900_000,
            pixels: FixedPixelSource(image: image))
        let set = try #require(planned.plan.candidateSets.first)
        #expect(!set.candidates.contains { candidate in
            if case .jpeg = candidate.kind { return true }
            return false
        }, "Ungated-Kleinbild-Kandidat entstanden: \(set.candidates.map(\.kind))")
        let action = try #require(planned.plan.actions.first)
        guard case .keep(_, let reason, _) = action else {
            Issue.record("Erwartet KEEP, war: \(action)")
            return
        }
        if case .qualityRejected = reason {} else {
            Issue.record("Falscher KEEP-Grund: \(reason)")
        }
    }

    // MARK: §10.3 – Katastrophen-Floor am kleinen Bild (Custom/fixed)

    /// Custom mit fester Qualität q0.05 auf Text-artigem Bild: Der Kandidat
    /// reißt die Katastrophen-Matrix (p05 0.430 < 0.60) und wird NICHT
    /// ausgeliefert – KeepReason `.catastrophicFloorFailed`. (Früher als
    /// „Legacy-Pfad“ geführt; seit V2-11 prüft der Fall denselben
    /// Produktionspfad wie der Candidate-Zwillig unten.)
    @Test(.hangGuard) func katastrophenFloorVerwirftFixedKandidatImLegacyPfad() throws {
        let image = try #require(Self.noisyText())
        let resource = Self.dctResource(image, objectNumber: 5, placedWidthPoints: 180)
        let options = Self.fixedOptions(targetDPI: 96, maxPixelEdge: 176,
                                        hardPixelCap: true, quality: 0.05)

        // Fixture-Nachweis: q0.05 auf dem Zielraster 176×132 reißt den
        // Katastrophen-Floor der Foto-Klasse.
        let target = try #require(CompressionPlanner.plannedSize(for: resource,
                                                                 options: options.image))
        let resized = try #require(ImageResampler.resize(image, to: target,
                                                         grayscale: false))
        let candidate = try #require(QualityGatesTests.jpegVariant(resized, quality: 0.05))
        let measurement = try #require(QualityGates.measure(reference: resized,
                                                            candidate: candidate))
        guard case .fail = QualityGates.qualityVerdict(
            policy: .catastrophicFloors(for: .photo), measurement: measurement) else {
            Issue.record("Fixture soll den Katastrophen-Floor reißen: \(measurement)")
            return
        }

        let planned = try CompressionPlanner.plan(
            resources: [resource], options: options,
            documentID: "catfloor-legacy", documentBytes: 900_000,
            pixels: FixedPixelSource(image: image))
        let action = try #require(planned.plan.actions.first)
        guard case .keep(_, .catastrophicFloorFailed, _) = action else {
            Issue.record("Katastrophen-Kandidat wurde ausgeliefert: \(action)")
            return
        }
    }

    /// Derselbe Fall im Candidate-Pfad: der fixed-Rung trägt seine Messung,
    /// der Optimizer verwirft ihn am Katastrophen-Floor (§10.3 gilt AUCH
    /// hinter Custom), die Wahl fällt katastrophenbegründet auf KEEP.
    @Test(.hangGuard) func katastrophenFloorVerwirftFixedKandidatImCandidatePfad() throws {
        let image = try #require(Self.noisyText())
        let resource = Self.dctResource(image, objectNumber: 6, placedWidthPoints: 180)
        var options = Self.fixedOptions(targetDPI: 96, maxPixelEdge: 176,
                                        hardPixelCap: true, quality: 0.05)
        options.featureFlags.candidateEngine = true

        let planned = try CompressionPlanner.plan(
            resources: [resource], options: options,
            documentID: "catfloor-candidate", documentBytes: 900_000,
            pixels: FixedPixelSource(image: image))
        let action = try #require(planned.plan.actions.first)
        guard case .keep(_, .catastrophicFloorFailed, _) = action else {
            Issue.record("Katastrophen-Kandidat wurde ausgeliefert: \(action)")
            return
        }
        let decision = try #require(planned.plan.decisions.first)
        #expect(decision.reason.contains("Katastrophen-Floor"),
                "Begründung soll den Floor nennen: \(decision.reason)")
        // Nur noch KEEP ist rückstufbar.
        #expect(decision.candidateIDsBySafety.count == 1)
        #expect(decision.selectedCandidateID == decision.candidateIDsBySafety.first)
    }

    // MARK: Floor nicht über-streng – harmlose Custom-Wahl bleibt zugelassen

    /// Custom q0.60 auf harmlosem Foto (192 DPI platziert, Ziel 96 DPI →
    /// Verkleinerung auf 200×150): gemessen weit über den Katastrophen-
    /// Floors → der Kandidat wird regulär ausgeliefert (beide Pfade). Der
    /// Floor ist Katastrophenschutz, kein Geschmacksrichter.
    ///
    /// Zwischenzeitlich (vor P0.1) erwartete dieser Test unter falschem
    /// Namen („ohne Resize") ein KEEP: Das feste 320-px-Messraster ließ die
    /// erlaubte Verkleinerung am Floor scheitern.
    @Test(.hangGuard) func harmloseFesteQualitaetBleibtZugelassen() throws {
        let image = try #require(QualityGatesTests.photoImage(width: 400, height: 300))
        let resource = Self.dctResource(image, objectNumber: 7, placedWidthPoints: 150)
        let options = Self.fixedOptions(targetDPI: 96, maxPixelEdge: 4000,
                                        hardPixelCap: false, quality: 0.60)

        let legacy = try CompressionPlanner.plan(
            resources: [resource], options: options,
            documentID: "catfloor-harmless-legacy", documentBytes: 900_000,
            pixels: FixedPixelSource(image: image))
        guard case .jpeg(_, let target, let quality, _, _, _, _) = try #require(
            legacy.plan.transformedActions.first) else {
            Issue.record("Harmloser Custom-Kandidat wurde verworfen: \(legacy.plan.actions)")
            return
        }
        #expect(abs(quality - 0.60) < 1e-9, "Feste Qualität verändert: \(quality)")
        #expect(target == PixelSize(width: 200, height: 150))

        var candidateOptions = options
        candidateOptions.featureFlags.candidateEngine = true
        let candidate = try CompressionPlanner.plan(
            resources: [resource], options: candidateOptions,
            documentID: "catfloor-harmless-candidate", documentBytes: 900_000,
            pixels: FixedPixelSource(image: image))
        guard case .jpeg(_, _, let candidateQuality, _, _, _, _) = try #require(
            candidate.plan.transformedActions.first) else {
            Issue.record("Harmloser Custom-Kandidat im Candidate-Pfad verworfen: \(candidate.plan.actions)")
            return
        }
        #expect(abs(candidateQuality - 0.60) < 1e-9)
    }

    // MARK: Native JPEG-Quelle ohne nötige Verkleinerung bleibt erhalten

    /// Liegt die Platzierung schon auf der Ziel-DPI (400 px auf 300 pt =
    /// 96 DPI), rechtfertigt auch eine harmlose Custom-Qualität keinen
    /// zusätzlichen verlustbehafteten JPEG-Durchlauf.
    @Test(.hangGuard) func nativesJPEGOhneResizeBleibtErhalten() throws {
        let image = try #require(QualityGatesTests.photoImage(width: 400, height: 300))
        let resource = Self.dctResource(image, objectNumber: 7, placedWidthPoints: 300)
        var options = Self.fixedOptions(targetDPI: 96, maxPixelEdge: 4000,
                                        hardPixelCap: false, quality: 0.60)
        options.featureFlags.candidateEngine = true
        let planned = try CompressionPlanner.plan(
            resources: [resource], options: options,
            documentID: "native-jpeg-within-budget", documentBytes: 900_000,
            pixels: FixedPixelSource(image: image))
        #expect(planned.plan.transformedActions.isEmpty,
                "Nativer JPEG-Stream wurde ohne Resize neu kodiert: \(planned.plan.actions)")
    }
}
