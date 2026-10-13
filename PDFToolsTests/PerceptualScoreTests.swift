import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Perzeptueller Score (SSIMULACRA-Ideen ohne Fremd-Deps): Bündelt die
/// vorhandenen Messungen (SSIM global/p05, ΔE) mit dem neuen Signal
/// Kanten-Einführung (Ringing/Halos, wo das Original glatt ist – sieht der
/// SSIM-Mittelwert nicht, wenn sich Mittelwerte ausgleichen).
///
/// Kalibrierungsanker (dieselben Fixtures wie QualityGatesTests):
/// identisch = 0, leichte JPEG-Artefakte (q0.75) weit unter dem Limit,
/// q0.05-Textgrafik und Text-Katastrophe klar darüber. Das Limit ist ein
/// Katastrophen-AND-Gate (§10.3-Familie, auch hinter Custom/fixed) – es
/// macht nichts strenger, was heute besteht.
@Suite struct PerceptualScoreTests {

    private static func score(reference: CGImage, candidate: CGImage) throws -> Double {
        let evaluator = QualityGates.Evaluator(reference: reference)
        let measurement = try #require(evaluator.measure(candidate: candidate))
        let edgeIntro = evaluator.edgeIntroduction(candidate: candidate)
        return PerceptualScore.score(measurement: measurement,
                                     edgeIntroduction: edgeIntro)
    }

    @Test func identischeBilderMessenNull() throws {
        let photo = try #require(QualityGatesTests.photoImage())
        #expect(try Self.score(reference: photo, candidate: photo) == 0, Comment(rawValue: "Identische Bilder müssen Score 0 tragen"))
    }

    @Test(.hangGuard) func leichteArtefakteBleibenWeitUntermLimit() throws {
        let photo = try #require(QualityGatesTests.photoImage())
        let q75 = try #require(QualityGatesTests.jpegVariant(photo, quality: 0.75))
        let s75 = try Self.score(reference: photo, candidate: q75)
        #expect(s75 < PerceptualScore.catastrophicLimit, Comment(rawValue:
                "q0.75 (Score \(s75)) muss das Katastrophen-Gate passieren – "
                + "sonst wäre der Score strenger als heute"))
        #expect(s75 < PerceptualScore.catastrophicLimit / 2,
                "Leichte Artefakte gehören in die Nähe von 0, war \(s75)")
    }

    @Test(.hangGuard) func textKatastropheReisstDasLimit() throws {
        let text = try #require(QualityGatesTests.textPattern())
        let washed = try #require(QualityGatesTests.washedVariant(text))
        let s = try Self.score(reference: text, candidate: washed)
        #expect(s > PerceptualScore.catastrophicLimit,
                "Text-Katastrophe (Score \(s)) muss über dem Limit liegen")
    }

    @Test(.hangGuard) func kachelKatastropheReisstDasLimit() throws {
        // q0.05 auf Text-Grafik: global 0.945 (blind), p05 0.779.
        let text = try #require(QualityGatesTests.textPattern())
        let shrunk = try #require(QualityGatesTests.downsampled(text, factor: 3))
        let low = try #require(QualityGatesTests.jpegVariant(shrunk, quality: 0.05))
        let s = try Self.score(reference: shrunk, candidate: low)
        #expect(s > PerceptualScore.catastrophicLimit,
                "Kachel-Katastrophe (Score \(s)) muss über dem Limit liegen")
    }

    @Test func gateVerwirftNurUeberDemLimit() throws {
        // Sauber (700, bessere SSIM-Qualität) vs. Katastrophe (500, hält
        // alle SSIM-Gates, ist global „schön", reißt NUR den Score). Keine
        // Pareto-Dominanz (Bytes gegen Qualität) – beide überleben bis zum
        // Gate, dann fällt die Katastrophe.
        let clean = RateDistortionOptimizerTests.candidate(
            id: "jpeg-clean", bytes: 700,
            global: 0.98, p05: 0.95, edge: 0.94, deltaE: 2.0,
            perceptual: 0.02)
        let catastrophe = RateDistortionOptimizerTests.candidate(
            id: "jpeg-cat", bytes: 500,
            global: 0.96, p05: 0.93, edge: 0.92, deltaE: 2.0,
            perceptual: 0.30)
        let set = RateDistortionOptimizerTests.set([clean, catastrophe])
        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .smart)
        #expect(selection.candidate.id == clean.id,
                "Score-Katastrophe darf nicht gewählt werden")
        #expect(selection.catastrophicRejection)
        #expect(selection.reason.contains("perzeptuell"),
                "Begründung muss das Gate nennen: \(selection.reason)")
    }

    @Test func ohneMessungGreiftDasGateNicht() throws {
        // Verlustfreie/Keeper ohne Score bleiben zulässig – das Gate kennt
        // nur gemessene JPEG-Kandidaten (CMYK/MRC haben eigene Gates).
        let keep = RateDistortionOptimizerTests.candidate(
            id: "keep", bytes: 1000, lossless: true, kind: .keep)
        let set = RateDistortionOptimizerTests.set([keep])
        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .smart)
        #expect(selection.candidate.kind.isKeep)
        #expect(!selection.catastrophicRejection)
    }
}
