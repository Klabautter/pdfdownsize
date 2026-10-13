import Testing
import Foundation
@testable import PDFTools

/// Masterplan §5.1 – CompressionGoal: Preset-Mapping und Codierbarkeit.
///
/// Festgenagelt:
///   • Klein/Smart/Qualität → smallest/balanced/bestQuality (§5.1), Custom
///     bleibt Parameter-Override und läuft als balanced (Safety Floor
///     unverhandelbar, Prinzip 12).
///   • Die Ableitung aus den Bildoptionen folgt derselben Preset-Kennung
///     wie `QualityGatePreset` – ein fremder SSIM-Wert (Custom) → balanced.
///   • `targetBytes` ist voll codierbar (V2-6-Verdrahtung vorbereitet).
@Suite struct CompressionGoalTests {

    // MARK: UI-Modus (§5.1)

    @Test func uiModiMappenAufZiele() {
        #expect(CompressionGoal(mode: .small) == .smallest)
        #expect(CompressionGoal(mode: .smart) == .balanced)
        #expect(CompressionGoal(mode: .quality) == .bestQuality)
        #expect(CompressionGoal(mode: .custom) == .balanced)
    }

    // MARK: Bildoptionen (Planner-Eingang)

    @Test func bildoptionenMappenUeberPresetKennung() {
        #expect(CompressionGoal(imageOptions: .small) == .smallest)
        #expect(CompressionGoal(imageOptions: .smart) == .balanced)
        #expect(CompressionGoal(imageOptions: .quality) == .bestQuality)
        // Custom (feste Qualität, fremde Schwelle) bleibt balanced.
        var custom = ImageCompressionOptions.smart
        custom.ssimThreshold = 0.93
        #expect(CompressionGoal(imageOptions: custom) == .balanced)
    }

    // MARK: Codierbarkeit

    @Test func zielIstCodierbar() throws {
        let goals: [CompressionGoal] = [.smallest, .balanced, .bestQuality,
                                        .targetBytes(6_197_130)]
        for goal in goals {
            let data = try JSONEncoder().encode(goal)
            let back = try JSONDecoder().decode(CompressionGoal.self, from: data)
            #expect(back == goal)
        }
    }

    @Test func targetBytesTraegtDieZahl() throws {
        let data = try JSONEncoder().encode(CompressionGoal.targetBytes(10_485_760))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("10485760"), "Zielzahl muss im JSON sichtbar sein: \(text)")
        let back = try JSONDecoder().decode(CompressionGoal.self, from: data)
        #expect(back == .targetBytes(10_485_760))
    }
}
