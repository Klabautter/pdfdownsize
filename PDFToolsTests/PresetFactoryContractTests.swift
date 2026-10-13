import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Final Core Hardening, Phase 2 – UI und CorpusRunner müssen dieselbe
/// Produktions-Factory benutzen.
///
/// Zuvor bauten beide ihre Konfigurationen getrennt: Das ViewModel setzte
/// `ssimThreshold: 1.1`, der Runner Werte wie `0.98` – jeweils mit
/// einstufiger Leiter. Ein Korpuslauf konnte damit grün sein, während der
/// echte UI-Pfad anders konfiguriert war. Was dort geprüft wird, hätte über
/// die App nichts ausgesagt.
@Suite struct PresetFactoryContractTests {

    // MARK: - Eine Quelle

    /// Der CorpusRunner darf keine eigenen Konfigurationen mehr bauen.
    @Test(.hangGuard) func runnerUsesProductionFactory() throws {
        let source = try CompressionEngineStateTests
            .projectSource("PDFToolsTests/CorpusRunnerCore.swift")
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        // Geprüft wird die Anforderung, nicht eine bestimmte Schreibweise:
        // Der Runner holt seine Konfigurationen aus der Produktions-Factory.
        // Ob er dabei `custom(…)` aufruft oder eine benannte Voreinstellung
        // nimmt, ist gleichgültig – beides ist dieselbe Quelle.
        #expect(code.contains("CompressionPresetFactory."),
                "Der Runner benutzt die Produktions-Factory nicht")
        #expect(!code.contains("ImageEngineConfig(targetDPI:"), """
            Der Runner baut wieder eigene Konfigurationen – damit prüft der \
            Korpus etwas anderes als die App tut.
            """)
    }

    /// Auch die UI baut nicht selbst.
    @Test(.hangGuard) func viewModelUsesProductionFactory() throws {
        let source = try CompressionEngineStateTests
            .projectSource("PDFTools/CompressionViewModel.swift")
        #expect(source.contains("CompressionPresetFactory.custom"),
                "Das ViewModel benutzt die Produktions-Factory nicht")
    }

    // MARK: - Propagation: jede sichtbare Einstellung

    /// Was der Nutzer einstellt, muss in den Optionen ankommen.
    ///
    /// Geprüft wird die Kette UI-Wert → `CompressionOptions`; dass die
    /// Optionen dann auch im Plan wirken, prüfen `QualityPolicyTests` und
    /// `CompressionPlannerGateTests`.
    @Test(.hangGuard) @MainActor
    func everyVisibleSettingReachesTheOptions() {
        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        viewModel.customDPI = 137
        viewModel.customQuality = 0.63
        viewModel.customForceGray = true
        viewModel.customGraphicsJPEG = true
        viewModel.customMaxPixels = 1234
        viewModel.customCapEnabled = true
        viewModel.customStripMetadata = true

        let options = viewModel.customOptions

        #expect(options.image.targetDPI == 137, "DPI kommt nicht an")
        #expect(options.image.forceGrayscale, "Graustufen kommen nicht an")
        #expect(options.image.aggressiveGraphics, "Grafik-Politik kommt nicht an")
        #expect(options.image.maxPixelEdge == 1234, "Pixelgrenze kommt nicht an")
        #expect(options.image.hardPixelCap, "Harte Grenze kommt nicht an")
        #expect(options.metadataPolicy == .strip, "Metadaten-Politik kommt nicht an")

        guard case .fixed(let quality) = options.image.qualityPolicy else {
            Issue.record("Custom nutzt keine feste Qualität")
            return
        }
        #expect(abs(quality - 0.63) < 0.001, "Qualität kommt als \(quality) an")
    }

    /// Smart bleibt adaptiv – und die Werte stehen zentral, nicht im ViewModel.
    @Test(.hangGuard) func smartPresetIsAdaptive() {
        let options = CompressionPresetFactory.smart()
        guard case .adaptive(let ladder, let minimumSSIM) = options.image.qualityPolicy
        else {
            Issue.record("Smart nutzt keine adaptive Leiter")
            return
        }
        #expect(ladder.count > 1, "Smart hat keine mehrstufige Leiter: \(ladder)")
        #expect(ladder.min() == 0.60)
        #expect(ladder.max() == 0.90)
        #expect(minimumSSIM == 0.90)
        #expect(minimumSSIM > 0 && minimumSSIM <= 1.0,
                "Qualitätszusage ausserhalb des möglichen Bereichs: \(minimumSSIM)")
    }

    /// Die vier Korpus-Presets müssen sich tatsächlich unterscheiden.
    ///
    /// Ohne diese Probe könnten vier Operationen dieselbe Konfiguration
    /// fahren, und der Korpus prüfte viermal dasselbe.
    @Test(.hangGuard) func corpusPresetsDiffer() {
        let balanced = CompressionPresetFactory.custom(
            dpi: 150, quality: 0.85, maxPixelEdge: 2200)
        let high = CompressionPresetFactory.custom(
            dpi: 300, quality: 0.92, maxPixelEdge: 3300)
        let aggressive = CompressionPresetFactory.custom(
            dpi: 96, quality: 0.72, aggressiveGraphics: true, maxPixelEdge: 1400)
        let grayscale = CompressionPresetFactory.custom(
            dpi: 200, quality: 0.85, grayscale: true, maxPixelEdge: 2200)

        let all = [balanced, high, aggressive, grayscale]
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] {
                #expect(a != b, "Zwei Korpus-Presets sind identisch")
            }
        }
        #expect(aggressive.image.aggressiveGraphics)
        #expect(grayscale.image.forceGrayscale)
        #expect(!balanced.image.forceGrayscale)
    }
}
