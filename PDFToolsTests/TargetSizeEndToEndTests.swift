import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan §12.1/§12.7/§12.8 (V2-6) – Ende-zu-Ende über den Produktions-
/// Einstieg (Compressor): gemischte Fixture (Foto + Grafik), erreichbares
/// und unerreichbares Ziel.
@Suite(.serialized) struct TargetSizeEndToEndTests {

    /// Gemischte Fixture: Foto-Seite + Grafik-Seite in EINEM Dokument.
    static func mixedFixture() throws -> URL {
        let photo = try PDFFixtures.photoHeavyPDF(pixels: 1600)
        let graphics = try PDFFixtures.screenshotLikePDF(pixels: 1200)
        defer { try? FileManager.default.removeItem(at: photo) }
        defer { try? FileManager.default.removeItem(at: graphics) }

        guard let photoDoc = PDFDocument(url: photo),
              let graphicsDoc = PDFDocument(url: graphics),
              let graphicsPage = graphicsDoc.page(at: 0) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        photoDoc.insert(graphicsPage.copy() as! PDFPage, at: 1)
        let out = PDFFixtures.fixtureURL(prefix: "target-size-mixed")
        guard photoDoc.write(to: out) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return out
    }

    /// Ziel ≥ Erreichbares → targetMet, achieved ≤ Ziel (+ Toleranz von
    /// 2 % Planreserve), Result-Felder gefüllt.
    @Test func erreichbaresZielWirdGehalten() throws {
        let input = try Self.mixedFixture()
        defer { try? FileManager.default.removeItem(at: input) }

        // Erst der Referenzlauf ohne Ziel: liefert die erreichbare Größe.
        let baseline = try Compressor().compress(inputURL: input, mode: .smart)
        defer { try? FileManager.default.removeItem(at: baseline.outputURL) }
        #expect(baseline.targetRequestedBytes == nil,
                "ohne Ziel bleibt die Telemetrie neutral")

        // Ziel 30 % über der Baseline-Ausgabe – sicher erreichbar.
        let target = Int64(Double(baseline.outputBytes) * 1.3)
        var options = CompressionOptions.smart
        options.goal = .targetBytes(target)
        let result = try Compressor().compress(inputURL: input, options: options)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.targetRequestedBytes == target)
        #expect(result.targetMet == true,
                "Ziel \(target) ≥ erreichbar \(baseline.outputBytes), ist aber \(result.outputBytes)")
        #expect(result.outputBytes <= target)
        #expect(result.outputBytes <= result.inputBytes,
                "Never-Grow bleibt unangetastet")
        #expect(result.selectedCandidateCount >= 1)
        #expect(result.warningSummary.isEmpty || !result.targetMet!)
    }

    /// Absurd kleines Ziel → nicht erreichbar: targetMet = false, die Datei
    /// bleibt sicher (kein Floor-Bruch, Original-Sicherheit), Meldung nennt
    /// das Sicher-Erreichbare.
    @Test func absurdesKleinesZielIstEhrlich() throws {
        let input = try Self.mixedFixture()
        defer { try? FileManager.default.removeItem(at: input) }

        var options = CompressionOptions.smart
        options.goal = .targetBytes(1_000)
        let result = try Compressor().compress(inputURL: input, options: options)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.targetRequestedBytes == 1_000)
        #expect(result.targetMet == false)
        #expect(result.warningSummary.contains { $0.contains("sicher erreichbar") },
                "§12.8-Meldung fehlt: \(result.warningSummary)")
        // Kein Floor-Bruch: Das Dokument bleibt ein gültiges Dokument, das
        // die Validierung besteht (sonst hätte compress geworfen).
        #expect(result.outputBytes > 0)
    }

    /// §12.1 API – mode-basiert MIT goal: das Ziel koppelt an die Preset-
    /// Politik des Modus und verschärft per Budget.
    @Test func modeMitGoalTrägtZiel() throws {
        let input = try Self.mixedFixture()
        defer { try? FileManager.default.removeItem(at: input) }

        let target = Int64(Compressor.fileSize(of: input))
        let result = try Compressor().compress(
            inputURL: input, mode: .smart, goal: .targetBytes(target))
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.targetRequestedBytes == target)
        #expect(result.targetMet == true,
                "Ziel = Eingabegröße ist trivial erreichbar")
    }

    /// Plan-Ebene: mit Ziel entscheidet der Budget-Optimizer (Begründung
    /// im ResourceDecision), ohne Ziel die lokale Wahl – derselbe Plan-
    /// Mechanismus, keine zweite Engine.
    @Test func plannerWähltMitZielDenBudgetOptimizer() throws {
        let input = try Self.mixedFixture()
        defer { try? FileManager.default.removeItem(at: input) }

        var options = CompressionOptions.smart
        options.featureFlags.candidateEngine = true
        let withoutGoal = try CompressionPipeline.plan(inputURL: input,
                                                       options: options)
        #expect(withoutGoal.plan.goal == .balanced)

        options.goal = .targetBytes(200_000)
        let withGoal = try CompressionPipeline.plan(inputURL: input,
                                                    options: options)
        #expect(withGoal.plan.goal == .targetBytes(200_000))
        #expect(withGoal.plan.traceVersion == 2)
        for decision in withGoal.plan.decisions {
            #expect(decision.reason.contains("Zielgrößen-Optimizer")
                    || decision.reason.contains("§12.8"),
                    "Begründung fehlt: \(decision.reason)")
        }
    }
}
