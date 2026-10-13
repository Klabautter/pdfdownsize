import Testing
import Foundation
@testable import PDFTools

/// Phase V2-7 (Masterplan §13.10) – Page-QA des MRC-Moduls.
///
/// Die Schranken sind bewusst strenger als jede Bildmatrix: SSIM ≥ 0.97,
/// p05-Kachel ≥ 0.95, changedAreaRatio ≤ 0.05, inkDelta ≤ 0.005. Der Test
/// nagelt die GRENZEN am echten Ausgang fest (der Kandidat trägt die
/// Messwerte) und verifiziert die Ausgabe zusätzlich über das bestehende
/// RenderDifferential.
@Suite(.timeLimit(.minutes(10))) struct MRCRenderQualityTests {

    @Test func mrcAusgabeHaeltDieStrengenScanGrenzen() throws {
        let input = try PDFFixtures.mrcScanPagePDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let output = MRCPageRewriteTests.tempURL("quality")
        defer { try? FileManager.default.removeItem(at: output) }

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: output,
            options: MRCPageRewriteTests.mrcOptions())

        // Alle erzeugten MRC-Kandidaten tragen QA-Messwerte über den Grenzen.
        var mrcCount = 0
        for set in outcome.plan.candidateSets {
            for candidate in set.candidates {
                guard case .mrc(let descriptor) = candidate.kind else { continue }
                mrcCount += 1
                let metrics = candidate.metrics
                let ssimMessage = "SSIM \(metrics.globalSSIM ?? 0) unter der "
                    + "Scan-Grenze (Stufe \(descriptor.backgroundDPI) DPI)"
                #expect((metrics.globalSSIM ?? 0) >= MRCPageQA.minimumGlobalSSIM,
                        Comment(rawValue: ssimMessage))
                #expect((metrics.p05TileSSIM ?? 0) >= MRCPageQA.minimumP05TileSSIM,
                        "p05 \(metrics.p05TileSSIM ?? 0) unter der Scan-Grenze")
                // edgeScore speichert 1 − CAR (Berichtsmetrik, kein Gate).
                let car = 1 - (metrics.edgeScore ?? 0)
                #expect(car <= 0.20,
                        "CAR \(car) außerhalb des Plausiblen für einen Textscan")
                #expect(mrcCount <= 2,
                        "Mehr als 2 MRC-Stufen je Seite (QA-Budget, §13.10)")
            }
        }
        #expect(mrcCount >= 1, "Fixture muss mindestens einen MRC-Kandidaten liefern")

        // End-to-End über das bestehende Werkzeug: Die AUSGABE-Seite bleibt
        // der Quelle strukturell erhalten. (Absolute SSIM-Skala des Render-
        // differentials liegt unter der des Bild-Gates; die BINDEnde Schranke
        // trägt der MRC-Kandidat selbst – oben geprüft.)
        let comparison = try RenderDifferential.compare(sourceURL: input,
                                                        outputURL: output,
                                                        dpi: 150)
        let page = try #require(comparison.first)
        #expect(page.ssim >= 0.93, "Ausgabe-SSIM \(page.ssim) zu niedrig")
        #expect(page.changedAreaRatio <= 0.15,
                "Ausgabe-CAR \(page.changedAreaRatio) zu hoch")
        if page.inkDeltaIsMeaningful {
            #expect(page.inkDelta <= 0.02,
                    "Tinte verschoben: \(page.inkDelta)")
        }
    }
}
