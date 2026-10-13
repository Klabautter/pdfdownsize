import Testing
import Foundation
@testable import PDFTools

/// Die aggressive Custom-Einstellung darf sichtbar verändern – aber nur sie,
/// und nur beim Rendern.
///
/// HERKUNFT DER REGEL
///
/// Der Korpuslauf vom 29.08.2026 meldete am IPCC-Bericht (404 MB, 2409
/// Seiten) für `compress-custom-aggressive` SSIM 0,497 bei 45,9 % veränderter
/// Fläche – Schweregrad HIGH, gate-blockierend. Die vier anderen Stufen
/// lieferten am selben Dokument SSIM 1,000 bei 0,0 %.
///
/// Die Einstellung fährt 96 DPI bei Qualität 0,72 mit `aggressiveGraphics`.
/// Der Planer beschreibt genau das an anderer Stelle so: „JPEG würde Text-
/// und Linienkanten sichtbar zerstören." Auf einem Bericht voller
/// Liniendiagramme tut es das dann auch.
///
/// Entscheidung des Projektinhabers: Der Custom-Reiter ist die Stelle, an der
/// der Nutzer die Parameter selbst setzt. Was er dort bestellt, bekommt er –
/// eine starke Veränderung ist dann das Ergebnis, nicht der Mangel.
///
/// Diese Tests halten die Grenzen dieser Ausnahme fest. Sie darf NICHT zu
/// „Custom wird nicht geprüft" ausufern.
@Suite struct AggressivePresetPolicyTests {

    /// Die App bietet vier Stufen. `CustomPreset` gehört NICHT dazu – es sind
    /// Stichproben aus dem Parameterraum, den der Custom-Reiter öffnet.
    /// Tauchte eine davon in der Oberfläche auf, wäre die Begründung der
    /// Ausnahme hinfällig: Dann hätte der Nutzer sie nicht selbst eingestellt,
    /// sondern nur einen Knopf gedrückt.
    /// Die aggressive Einstellung muss aggressiv bleiben – sonst prüft der
    /// Korpus mit ihr etwas anderes, als der Name sagt.
    @Test func dieAggressiveEinstellungIstTatsaechlichAggressiv() {
        let o = CompressionPresetFactory.CustomPreset.aggressive.options.image
        #expect(o.targetDPI <= 100, "Zielauflösung \(o.targetDPI) ist nicht aggressiv")
        #expect(o.aggressiveGraphics, "aggressiveGraphics ist aus")
    }

    /// Die drei anderen Custom-Stichproben bekommen KEINE Ausnahme. Sie
    /// stehen für gewöhnliche Nutzereinstellungen, und dort ist sichtbarer
    /// Verlust weiterhin ein Befund.
    @Test(arguments: [
        CompressionPresetFactory.CustomPreset.high,
        CompressionPresetFactory.CustomPreset.balanced,
        CompressionPresetFactory.CustomPreset.grayscale,
    ])
    func nurDieAggressiveEinstellungHatEineAusnahme(
        _ preset: CompressionPresetFactory.CustomPreset) {
        let operation = CorpusRunnerCore.Operation(rawValue: {
            switch preset {
            case .high:      return "compress-custom-high"
            case .balanced:  return "compress-custom-balanced"
            case .grayscale: return "compress-custom-grayscale"
            case .aggressive: return "compress-custom-aggressive"
            }
        }())
        #expect(operation != nil)
        #expect(operation != .compressCustomAggressive, """
            \(preset.rawValue) darf nicht als aggressive Einstellung gelten – \
            sonst gilt die Ausnahme für mehr als beabsichtigt.
            """)
    }

    /// Die Ausnahme betrifft NUR die Renderabweichung. Ein beschädigter
    /// Ausgang bleibt ein Fehler – auch ein Experte hat keinen kaputten
    /// Ausgang bestellt.
    @Test func strukturverlustBleibtBlockierend() {
        // Die Gate-Politik entscheidet anhand von Klasse und Schweregrad.
        // Ein CRITICAL auf einem echten Dokument blockiert, unabhängig davon,
        // welche Stufe es erzeugt hat.
        let kritisch = CorpusRunnerCore.OperationRow(
            fixture: "RealWorld/x.pdf", fixtureClass: "realWorld",
            operation: "compress-custom-aggressive", status: "FAIL",
            severity: CorpusRunnerCore.Severity.critical.rawValue,
            durationMs: 1, pagesIn: 1, pagesOut: 1,
            inputBytes: 1, outputBytes: 1, qpdfCheck: "FAIL",
            renderChangedAreaRatio: nil, renderMeanAbsDiff: nil,
            renderSSIM: nil, renderInkDelta: nil,
            messages: ["Strukturprüfung fehlgeschlagen"])
        #expect(CorpusRunnerCore.blocks(gate: kritisch, fixtureClass: .realWorld),
                "Ein kaputter Ausgang muss auch bei der aggressiven Einstellung blockieren")
    }

    /// Eine Beobachtung (`.low`) lässt die Zeile auf PASS – sie steht aber im
    /// Report. Verschwinden darf sie nicht.
    @Test func beobachtungBlockiertNichtBleibtAberSichtbar() {
        let beobachtung = CorpusRunnerCore.OperationRow(
            fixture: "RealWorld/x.pdf", fixtureClass: "realWorld",
            operation: "compress-custom-aggressive", status: "PASS",
            severity: CorpusRunnerCore.Severity.low.rawValue,
            durationMs: 1, pagesIn: 1, pagesOut: 1,
            inputBytes: 1, outputBytes: 1, qpdfCheck: "PASS",
            renderChangedAreaRatio: 0.459, renderMeanAbsDiff: nil,
            renderSSIM: 0.497, renderInkDelta: nil,
            messages: ["Render stark verändert (SSIM 0.497, CAR 0.459) – "
                       + "erwartet bei der aggressiven Custom-Einstellung"])
        #expect(!CorpusRunnerCore.blocks(gate: beobachtung, fixtureClass: .realWorld))
        #expect(beobachtung.renderSSIM != nil, "Der Messwert muss im Report stehen")
        #expect(beobachtung.messages.contains { $0.contains("SSIM") },
                "Die Begründung muss im Report stehen")
    }
}
