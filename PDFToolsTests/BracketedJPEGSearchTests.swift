import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Masterplan §9.3 – Bracketed Quality Search.
///
/// Festgenagelt:
///   • qHigh hält das Gate nicht → kein lossy Candidate für diese Auflösung.
///   • qLow hält das Gate → Frontier nach genau 2 Evaluierungen.
///   • Bisektion stoppt bei Δq ≤ 0.02 oder nach max. 5 Evaluierungen.
///   • Quality-Metriken sind NICHT garantiert monoton: Die finale Wahl
///     erfolgt IMMER über die tatsächlich gemessenen Kandidaten (kleinste
///     PASS-Datei), nie über die Intervallgrenze der Bisektion.
///   • Determinismus: gleicher Evaluierer → gleicher Suchlauf.
@Suite struct BracketedJPEGSearchTests {

    // MARK: Helfer

    /// Skript-Zelle: Qualität (mit Toleranz gematcht), gemessene Bytes,
    /// Gate-Ergebnis. Die Toleranz ist nötig, weil Bisektions-Midpoints
    /// Floating-Arithmetik sind ((0.80+0.90)/2 ≠ exakt 0.85).
    private struct ScriptedPoint {
        let quality: Double
        let bytes: Int
        let passes: Bool

        func with(bytes: Int? = nil, passes: Bool? = nil) -> ScriptedPoint {
            ScriptedPoint(quality: quality,
                          bytes: bytes ?? self.bytes,
                          passes: passes ?? self.passes)
        }
    }

    /// Eine Qualität auf ein deterministisches (möglichst nicht-monotones)
    /// Ergebnis abbilden.
    private static func scriptedRung(_ quality: Double,
                                     points: [ScriptedPoint]) -> JPEGSearchRung {
        let point = points.first { abs($0.quality - quality) < 1e-9 }
        let bytes = point?.bytes ?? Int(quality * 1000)
        let passes = point?.passes ?? false
        let ssim = passes ? 0.95 : 0.70
        let measurement = QualityGateMeasurement(
            globalSSIM: ssim, p05TileSSIM: ssim,
            edgeWeightedScore: 0.95, textRegionScore: nil,
            meanDeltaE76: nil, psnr: 40, tileSSIMs: [], tileGrid: 8,
            isColor: false)
        return JPEGSearchRung(quality: quality, data: Data(repeating: 1, count: bytes),
                              measurement: measurement, passed: passes,
                              runtimeMs: 1)
    }

    private static let script = [
        ScriptedPoint(quality: 0.90, bytes: 1000, passes: true),
        ScriptedPoint(quality: 0.85, bytes: 900, passes: true),
        // Bewusst nicht-monoton: 0.825 passiert mit MEHR Bytes als 0.85.
        ScriptedPoint(quality: 0.825, bytes: 950, passes: true),
        ScriptedPoint(quality: 0.80, bytes: 500, passes: false),
    ]

    /// Feste Preset-Politik (smart/photo) – Grenzwerte sind hier egal, das
    /// Gate entscheidet der Skript-Evaluierer.
    private static let policy = BracketedJPEGSearch.Policy.bracketed(
        qLow: 0.80, qHigh: 0.90,
        gate: QualityGatePolicy.policy(matching: 0.90, imageClass: .photo),
        imageClass: .photo, minimumSSIM: 0.90)

    // MARK: Konstanten (Masterplan §9.3)

    @Test func suchfensterEntsprichtMasterplan() {
        #expect(BracketedJPEGSearch.minimumInterval == 0.02)
        #expect(BracketedJPEGSearch.maxEvaluations >= 4)
        #expect(BracketedJPEGSearch.maxEvaluations <= 5)
    }

    // MARK: Ungated (Custom/Kleinbild)

    @Test func ungatedFuehrtGenauEineEvaluierungAus() {
        var evaluated: [Double] = []
        let rungs = BracketedJPEGSearch.run(policy: .ungated(quality: 0.72)) { q in
            evaluated.append(q)
            return JPEGSearchRung(quality: q, data: Data([1, 2, 3]),
                                  measurement: nil, passed: true, runtimeMs: 0)
        }
        #expect(evaluated == [0.72])
        #expect(rungs.count == 1)
        #expect(rungs.first?.passed == true)
        #expect(BracketedJPEGSearch.winner(in: rungs)?.quality == 0.72)
    }

    // MARK: qHigh-Gate (§9.3 Schritt 1/2)

    @Test func qHighOhneGateKeinLossyKandidat() {
        var evaluated: [Double] = []
        let rungs = BracketedJPEGSearch.run(policy: Self.policy) { q in
            evaluated.append(q)
            return Self.scriptedRung(q, points: [Self.script[0].with(passes: false)])
        }
        // Nur qHigh wurde angetastet – mehr Evaluationen wären Verschwendung.
        #expect(evaluated.count == 1)
        #expect(abs(evaluated[0] - 0.90) < 1e-9)
        #expect(rungs.allSatisfy { !$0.passed })
        #expect(BracketedJPEGSearch.winner(in: rungs) == nil)
    }

    // MARK: qLow-Frontier (§9.3 Schritt 3/4)

    @Test func qLowPassHieltIstFrontierNachZweiEvaluierungen() {
        var evaluated: [Double] = []
        let rungs = BracketedJPEGSearch.run(policy: Self.policy) { q in
            evaluated.append(q)
            return Self.scriptedRung(q, points: [
                Self.script[0].with(bytes: 900, passes: true),
                Self.script[3].with(passes: true),
            ])
        }
        #expect(evaluated.count == 2)
        #expect(abs(evaluated[0] - 0.90) < 1e-9)
        #expect(abs(evaluated[1] - 0.80) < 1e-9)
        let winner = BracketedJPEGSearch.winner(in: rungs)
        #expect(abs((winner?.quality ?? 0) - 0.80) < 1e-9)
        #expect(winner?.data.count == 500)
    }

    // MARK: Bisektion + Evaluierungsbudget (§9.3 Schritt 5–7)

    @Test func bisektionRespektiertEvaluierungsbudget() {
        var evaluated: [Double] = []
        let rungs = BracketedJPEGSearch.run(policy: Self.policy) { q in
            evaluated.append(q)
            // Nur qHigh hält das Gate – jede Mitte fällt durch.
            return Self.scriptedRung(q, points: [Self.script[0]])
        }
        #expect(evaluated.count == BracketedJPEGSearch.maxEvaluations)
        #expect(abs(evaluated[0] - 0.90) < 1e-9)
        // Erste zwei = qHigh/qLow; nur die Mids liegen strikt im Innern.
        #expect(evaluated.dropFirst(2).allSatisfy { $0 > 0.80 && $0 < 0.90 })
        // Trotz Budget-Stop bleibt der einzige PASS-Kandidat wählbar.
        #expect(abs((BracketedJPEGSearch.winner(in: rungs)?.quality ?? 0) - 0.90) < 1e-9)
    }

    @Test func bisektionStopptBeiDeltaQ() {
        var evaluated: [Double] = []
        let rungs = BracketedJPEGSearch.run(policy: Self.policy) { q in
            evaluated.append(q)
            // qHigh und 0.85 passieren, qLow und alles darunter fällt durch.
            return Self.scriptedRung(q, points: [
                Self.script[0], Self.script[1], Self.script[3],
            ])
        }
        // 0.90 → 0.80 → 0.85 → 0.825 (fällt) → Intervall [0.825, 0.85],
        // Δq = 0.025 > 0.02 → 0.8375 (fällt) → Δq = 0.0125 ≤ 0.02 Stopp.
        let expected = [0.90, 0.80, 0.85, 0.825, 0.8375]
        #expect(evaluated.count == expected.count)
        for (measured, wanted) in zip(evaluated, expected) {
            #expect(abs(measured - wanted) < 1e-9)
        }
        #expect(abs((BracketedJPEGSearch.winner(in: rungs)?.quality ?? 0) - 0.85) < 1e-9)
    }

    // MARK: Finale Wahl über Messwerte (§9.3 Schritt 8/9)

    @Test func nichtMonotoneMetrikWaehltUeberMesswerte() {
        let rungs = BracketedJPEGSearch.run(policy: Self.policy) { q in
            // Bewusst nicht-monoton: 0.825 passiert mit MEHR Bytes als 0.85
            // – wer die Bisektions-Intervallgrenze nehmen würde, läge falsch.
            Self.scriptedRung(q, points: Self.script)
        }
        let winner = BracketedJPEGSearch.winner(in: rungs)
        #expect(abs((winner?.quality ?? 0) - 0.85) < 1e-9,
                "Kleinste gemessene PASS-Datei muss gewinnen")
        #expect(winner?.data.count == 900)
    }

    @Test func gleichstandGehtAnBessereMessung() {
        let a = JPEGSearchRung(quality: 0.85,
                               data: Data(repeating: 1, count: 500),
                               measurement: Self.scriptedRung(0.85, points: [])
                                   .measurement,
                               passed: true, runtimeMs: 0)
        // Gleiche Bytes, aber die Messung von b ist besser → b gewinnt,
        // nicht die tiefere Qualität.
        let betterMeasurement = QualityGateMeasurement(
            globalSSIM: 0.97, p05TileSSIM: 0.97, edgeWeightedScore: 0.97,
            textRegionScore: nil, meanDeltaE76: nil, psnr: 40,
            tileSSIMs: [], tileGrid: 8, isColor: false)
        let b = JPEGSearchRung(quality: 0.82,
                               data: Data(repeating: 1, count: 500),
                               measurement: betterMeasurement,
                               passed: true, runtimeMs: 0)
        // Gleiche Bytes → die bessere Messung gewinnt, nicht die tiefere q.
        let winner = BracketedJPEGSearch.winner(in: [a, b])
        #expect(winner?.quality == 0.82)
    }

    // MARK: Determinismus

    @Test func suchlaufIstDeterministisch() {
        func search() -> (qualities: [Double], winnerBytes: Int?) {
            let rungs = BracketedJPEGSearch.run(policy: Self.policy) { q in
                Self.scriptedRung(q, points: Self.script)
            }
            return (rungs.map(\.quality),
                    BracketedJPEGSearch.winner(in: rungs)?.data.count)
        }
        let first = search()
        let second = search()
        #expect(first.qualities.count == second.qualities.count)
        for (a, b) in zip(first.qualities, second.qualities) {
            #expect(abs(a - b) < 1e-12)
        }
        #expect(first.winnerBytes == second.winnerBytes)
    }

    // MARK: Echte Kette (ImageResampler + QualityGates)

    /// Weicher Verlauf: q0.80 hält das smart/photo-Gate problemlos → die
    /// Suche muss nach genau zwei Evaluierungen auf der Frontier enden.
    @Test func echteKetteEndetAufDerFrontier() throws {
        let reference = try #require(Self.gradientImage(width: 320, height: 240))
        let rungs = BracketedJPEGSearch.run(reference: reference,
                                            grayscale: false,
                                            backend: .mozjpeg,
                                            policy: Self.policy)
        #expect(rungs.count == 2, "Frontier-Fall: genau qHigh + qLow messen")
        #expect(rungs.allSatisfy({ $0.passed }))
        let winner = try #require(BracketedJPEGSearch.winner(in: rungs))
        #expect(abs(winner.quality - 0.80) < 0.0001)
        let high = try #require(rungs.first { $0.quality == 0.90 })
        #expect(winner.data.count < high.data.count)

        // Determinismus der Kette: gleicher Eingang → gleiche Bytes.
        let again = BracketedJPEGSearch.run(reference: reference,
                                            grayscale: false, backend: .mozjpeg,
                                            policy: Self.policy)
        #expect(again.map({ $0.data.count }) == rungs.map({ $0.data.count }))
    }

    /// Echte Kette am Gate: Mit der QUALITY-Politik (SSIM 0.95, strengere
    /// Grenzwertmatrix) muss der Gewinner das Gate nachweislich halten.
    @Test func echteKetteRespektiertDasGate() throws {
        let reference = try #require(Self.gradientImage(width: 320, height: 240))
        let qualityPolicy = BracketedJPEGSearch.Policy.bracketed(
            qLow: 0.85, qHigh: 0.92,
            gate: QualityGatePolicy.policy(matching: 0.95, imageClass: .photo),
            imageClass: .photo, minimumSSIM: 0.95)
        let rungs = BracketedJPEGSearch.run(reference: reference,
                                            grayscale: false, backend: .mozjpeg,
                                            policy: qualityPolicy)
        let winner = try #require(BracketedJPEGSearch.winner(in: rungs))
        // Der Gewinner hält DIESELBE Politik, gegen die er gesucht wurde.
        let verdict = QualityGates.qualityVerdict(
            policy: QualityGatePolicy.policy(matching: 0.95, imageClass: .photo),
            measurement: try #require(winner.measurement))
        guard case .pass = verdict else {
            Issue.record("Gewinner hält sein Gate nicht: \(verdict)")
            return
        }
    }

    @Test func originalReferenceDetectsResolutionLoss() throws {
        let context = try #require(CGContext(data: nil, width: 256, height: 256,
            bitsPerComponent: 8, bytesPerRow: 256 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<256 {
            for x in 0..<256 {
                let value: CGFloat = (x / 2 + y / 2) % 2 == 0 ? 0 : 1
                context.setFillColor(CGColor(gray: value, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let original = try #require(context.makeImage())
        let reduced = try #require(ImageResampler.resize(original,
            to: PixelSize(width: 32, height: 32), grayscale: false))
        let sample = try #require(QualityGates.sample(original))
        let selfCompared = BracketedJPEGSearch.run(reference: reduced,
            grayscale: false, backend: .mozjpeg, policy: Self.policy)
        #expect(BracketedJPEGSearch.winner(in: selfCompared) != nil)
        let checked = BracketedJPEGSearch.run(reference: reduced,
            grayscale: false, backend: .mozjpeg, policy: Self.policy,
            sourceSample: sample)
        #expect(BracketedJPEGSearch.winner(in: checked) == nil)
        #expect(try #require(checked.first?.measurement).globalSSIM < 0.5)
        let manual = BracketedJPEGSearch.run(reference: reduced,
            grayscale: false, backend: .mozjpeg, policy: .ungated(quality: 0.8),
            sourceSample: sample)
        #expect(BracketedJPEGSearch.winner(in: manual) != nil)
    }

    @Test func smartExploresLowerQualityWithoutRelaxingGates() throws {
        let reference = try #require(Self.gradientImage(width: 320, height: 240))
        guard case .adaptive(let ladder, let threshold) = ImageCompressionOptions.smart.qualityPolicy else {
            Issue.record("Smart must remain adaptive")
            return
        }
        let gate = QualityGatePolicy.policy(matching: threshold, imageClass: .photo)
        let policy = BracketedJPEGSearch.Policy.bracketed(
            qLow: try #require(ladder.min()), qHigh: try #require(ladder.max()),
            gate: gate, imageClass: .photo, minimumSSIM: threshold)
        let rungs = BracketedJPEGSearch.run(reference: reference,
            grayscale: false, backend: .mozjpeg, policy: policy)
        let winner = try #require(BracketedJPEGSearch.winner(in: rungs))
        let oldRungs = BracketedJPEGSearch.run(reference: reference,
            grayscale: false, backend: .mozjpeg, policy: Self.policy)
        let oldWinner = try #require(BracketedJPEGSearch.winner(in: oldRungs))
        #expect(winner.quality < 0.80)
        #expect(winner.data.count < oldWinner.data.count)
        #expect(rungs.count <= BracketedJPEGSearch.maxEvaluations)
        guard case .pass = QualityGates.qualityVerdict(
            policy: gate, measurement: try #require(winner.measurement)) else {
            Issue.record("Lower-quality winner failed the unchanged gate")
            return
        }
    }

    private static func gradientImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)
                                    ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context else { return nil }
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(CGColor(
                    red: Double(x) / Double(width),
                    green: Double(y) / Double(height),
                    blue: Double((x + y) % width) / Double(width), alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()
    }
}
