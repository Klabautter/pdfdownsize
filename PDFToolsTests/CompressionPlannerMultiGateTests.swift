import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Phase 7 am Produktionspfad: planJPEG – die Quality-Ladder des
/// CompressionPlanner – entscheidet jetzt über das QualityGates-Verdict
/// statt über den globalen SSIM-Mittelwert. Die Bild-Fixtures stammen aus
/// QualityGatesTests (dort als Multi-Gate-Fälle verankert).
///
/// Der Planner ist bewusst backend-frei getestet: Stub-Pixelquelle, kein PDF
/// im Spiel (Muster plannerIsIndependentOfPDFBackend).
@Suite struct CompressionPlannerMultiGateTests {

    // MARK: - Hilfen

    /// Liefert für JEDE Anfrage dasselbe Bild – der Planner resampelt und
    /// klassifiziert selbst.
    private struct FixedPixelSource: ImagePixelSource {
        let image: CGImage
        func decodedImage(for resource: PDFImageResource) -> CGImage? { image }
    }

    /// DCT-Ressource mit steuerbarer Platzierung (bestimmt Effective DPI
    /// und damit Zielgröße und Pfad).
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

    /// Textmuster auf sanftem Hell-Verlauf (multipliziert): Die Kachel-
    /// Geometrie der QualityGatesTests-Katastrophe bleibt erhalten, das Bild
    /// ist aber nicht zweiwertig (kein Bilevel-Pfad) und nicht grau-skaliert
    /// zweifrei – der alreadyGrayscale-Frühabsprung greift nicht.
    static func textOnGradient(width: Int = 800, height: Int = 600) -> CGImage? {
        guard let text = QualityGatesTests.textPattern(width: width, height: height),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [
                                            CGColor(gray: 0.90, alpha: 1),
                                            CGColor(gray: 1.0, alpha: 1)
                                        ] as CFArray,
                                        locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: CGFloat(height)),
                               options: [])
        ctx.setBlendMode(.multiply)
        ctx.draw(text, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Optionsrahmen mit expliziter Leiterpolitik (der Rohwert-Initialisierer
    /// würde eine einstufige Leiter nach fixed falten).
    private static func adaptiveOptions(targetDPI: Double, maxPixelEdge: Int,
                                        hardPixelCap: Bool, aggressiveGraphics: Bool,
                                        ladder: [Double], threshold: Double)
        -> CompressionOptions {
        CompressionOptions(image: ImageCompressionOptions(
            targetDPI: targetDPI, tolerance: 1.0, maxPixelEdge: maxPixelEdge,
            hardPixelCap: hardPixelCap, forceGrayscale: false,
            aggressiveGraphics: aggressiveGraphics,
            qualityPolicy: .adaptive(ladder: ladder, minimumSSIM: threshold)))
    }

    // MARK: - 1) Gate-Pass: die Leiter kodiert wie bisher

    /// Foto, Leiter [0.6, 0.8], Zusage 0.85: Die erste Stufe hält das
    /// Multi-Gate (globale Grenze 0.85 aus der Zusage abgeleitet, Foto-Floors
    /// der Custom-Zelle liegen weit darunter) → JPEG-Plan mit dieser Stufe.
    @Test(.hangGuard) func gatePassFuehrtZurJPEGEntscheidung() throws {
        let image = try #require(QualityGatesTests.photoImage())
        let resource = Self.dctResource(image, objectNumber: 5, placedWidthPoints: 300)
        let options = Self.adaptiveOptions(targetDPI: 96, maxPixelEdge: 4000,
                                           hardPixelCap: true, aggressiveGraphics: false,
                                           ladder: [0.6, 0.8], threshold: 0.85)

        let planned = try CompressionPlanner.plan(
            resources: [resource], options: options,
            documentID: "multigate-pass", documentBytes: 900_000,
            pixels: FixedPixelSource(image: image))

        let action = try #require(planned.plan.transformedActions.first,
                                  "Foto wurde gar nicht transformiert")
        guard case .jpeg(_, _, let quality, _, let ssim, _, _) = action else {
            Issue.record("Kein JPEG-Plan: \(action)")
            return
        }
        #expect(quality == 0.6, "Erste haltende Stufe: \(quality)")
        #expect((ssim ?? 0) >= 0.85, "Gemeldetes SSIM \(String(describing: ssim)) unter der Zusage")
    }

    // MARK: - 2) Gate-Fail: die Katastrophen-Stufe wird abgelehnt

    /// Der dokumentierte blinde Fleck des ALTEN Gates, am Planner
    /// nachgebaut: q0.15 auf stark verkleinerter Text-Grafik misst global
    /// 0.928 – über der smart-Schwelle 0.90 (das globale SSIM-Gate hätte die
    /// Stufe NOMMEN) – aber p05-Kachel 0.740 und Text-Score 0.693 reißen
    /// unter die smart-Graphics-Floors (0.86). Das Multi-Gate lehnt die
    /// Stufe ab – bei einstufiger Leiter bleibt das Bild unangetastet.
    @Test(.hangGuard) func kachelKatastropheFaelltAmPlannerDurchsMultiGate() throws {
        let image = try #require(Self.textOnGradient())
        // 800 px auf 180 pt = 320 DPI → auf 240×180 verkleinert; Kantenlimit
        // 360 (hard cap) macht den aggressiven Graphics-Pfad „clearly
        // oversized". Erst die starke Verkleinerung + niedrige Stufe lässt
        // die Kachel-Metriken kollabieren, während der globale Mittelwert
        // freundlich bleibt.
        let resource = Self.dctResource(image, objectNumber: 3, placedWidthPoints: 180)
        let options = Self.adaptiveOptions(targetDPI: 96, maxPixelEdge: 360,
                                           hardPixelCap: true, aggressiveGraphics: true,
                                           ladder: [0.05], threshold: 0.90)

        // Voraussetzung – der blinde Fleck, direkt nachgemessen: Der Planner
        // resampelt auf die geplante Zielgröße; die Politik hebt die Stufe
        // für Grafiken auf 0.15 an. GEGEN DIESELBE Stichprobe messend liegt
        // der globale Wert über der smart-Schwelle, während das Verdict an
        // den Kachel-Metriken scheitert.
        let target = try #require(CompressionPlanner.plannedSize(for: resource,
                                                                 options: options.image))
        let resized = try #require(ImageResampler.resize(image, to: target,
                                                         grayscale: true))
        let candidate = try #require(QualityGatesTests.jpegVariant(resized, quality: 0.15))
        let blindSpot = try #require(QualityGates.measure(reference: resized,
                                                          candidate: candidate))
        #expect(blindSpot.globalSSIM >= 0.90,
                """
                Szenario soll den blinden Fleck zeigen: global \(blindSpot.globalSSIM) \
                müsste über 0.90 liegen (das alte Gate hätte genommen)
                """)
        guard case .fail(let violated) = QualityGates.qualityVerdict(
            policy: .policy(matching: 0.90, imageClass: .graphics),
            measurement: blindSpot) else {
            Issue.record("Szenario fiel nicht durchs Multi-Gate: \(blindSpot)")
            return
        }
        #expect(violated.contains { $0 != .globalSSIM },
                "Nur die Kachel-Metriken sollen reißen: \(violated)")

        // Die Entscheidung des Planners:
        let planned = try CompressionPlanner.plan(
            resources: [resource], options: options,
            documentID: "multigate-fail", documentBytes: 900_000,
            pixels: FixedPixelSource(image: image))

        #expect(planned.plan.transformedActions.isEmpty,
                "Katastrophen-Stufe wurde akzeptiert: \(planned.plan.actions)")
        let reason = try #require(planned.plan.keepReasons.first?.reason)
        #expect(reason.contains("Qualität"), "Falscher Grund: \(reason)")
    }

    // MARK: - 3) Determinismus: dieselben Pixel auf beiden Seiten

    /// Zwei Planungsläufe über dieselbe Quelle und Optionen ergeben
    /// denselben Plan – der Multi-Gate-Vergleich (Stichprobe + Verdict)
    /// ist deterministisch (Finding-11-Parität: Estimator und Executor
    /// teilen genau diesen Plan).
    @Test(.hangGuard) func multiGatePlanungIstDeterministisch() throws {
        let image = try #require(QualityGatesTests.photoImage())
        let resource = Self.dctResource(image, objectNumber: 9, placedWidthPoints: 300)
        let options = Self.adaptiveOptions(targetDPI: 96, maxPixelEdge: 4000,
                                           hardPixelCap: true, aggressiveGraphics: false,
                                           ladder: [0.55, 0.75, 0.9], threshold: 0.86)

        let first = try CompressionPlanner.plan(
            resources: [resource], options: options,
            documentID: "multigate-det", documentBytes: 900_000,
            pixels: FixedPixelSource(image: image))
        let second = try CompressionPlanner.plan(
            resources: [resource], options: options,
            documentID: "multigate-det", documentBytes: 900_000,
            pixels: FixedPixelSource(image: image))

        // V2-11 – Ganze Plan-Equality trägt die GEMESSENEN Kandidaten-
        // Laufzeiten (expectedRuntimeMs) mit; die streuen im Millisekunden-
        // Bereich. Deterministisch ist die SEMANTIK: Aktionen, Wahl und
        // Kandidatenraum (IDs + Bytes), nicht die Stoppuhr.
        #expect(first.plan.actions == second.plan.actions,
                "Multi-Gate-Planung ist nicht deterministisch (Aktionen)")
        #expect(first.plan.decisions.map(\.selectedCandidateID)
                == second.plan.decisions.map(\.selectedCandidateID),
                "Multi-Gate-Planung ist nicht deterministisch (Wahl)")
        func candidateFingerprint(_ plan: CompressionPlan) -> [String] {
            plan.candidateSets.flatMap { set in
                set.candidates.map { candidate in
                    "\(candidate.id.rawValue):\(candidate.metrics.encodedBytes)"
                }
            }
        }
        #expect(candidateFingerprint(first.plan)
                == candidateFingerprint(second.plan),
                Comment(rawValue: "Multi-Gate-Planung ist nicht "
                    + "deterministisch (Kandidatenraum)"))
    }
}
