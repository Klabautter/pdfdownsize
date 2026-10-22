import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// P0.1 – Messraster der Qualitätsprüfung.
///
/// Isolierter Test, weil der E2E-Fall (`PhotoDPIRegressionE2ETests`) nur die
/// Richtung „erlaubte Verkleinerung wird angenommen" belegt. Die Gegen-
/// richtung – das Raster darf keine echten Verluste verstecken – sieht kein
/// Korpus-E2E zuverlässig. Vorher festgehaltene Fehlermöglichkeiten:
///  A. Das Raster wird größer als die Ziel-Auflösung → erlaubte
///     Verkleinerung fällt weiter durch (der Bug).
///  B. Das Raster wird kleiner als die Ziel-Auflösung → Verluste unterhalb
///     des Ziels werden unsichtbar.
///  C. Farbverfälschung auf Zielgröße besteht, weil nur noch die Größe zählt.
///  D. Verkleinerung UNTER das Ziel besteht wie eine erlaubte Verkleinerung.
///  E. Ohne bekannte Ziel-Auflösung (keine Platzierung) ändert sich das
///     bisherige 320-px-Raster.
///  F. (P0.3) Auch auf dem vollen 320-px-Raster verkleinern Referenz und
///     Kandidat mit verschiedenen Filtern – ein UNVERÄNDERTES, körniges Bild
///     misst dann deutlich unter 1 (gemessen 0,90–0,93 an echten Scans/Fotos).
///  G. (2026-10-22) Klein misst auf dem feinen Raster (≤ 1024 px). Auf 320 px
///     bestand bei großen Bildern jede Stufe, auch halbierte Auflösung.
@Suite struct QualityGateGridTests {

    /// Körniges Testbild (deterministisches Rauschen auf Verlauf) – das
    /// Material, an dem Filterunterschiede SSIM kosten.
    static func grainy(_ edge: Int) -> CGImage {
        var state: UInt64 = 0x9E3779B97F4A7C15
        var bytes = [UInt8](repeating: 0, count: edge * edge * 4)
        for y in 0..<edge {
            for x in 0..<edge {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = Int((state >> 33) % 90) - 45
                let base = 60 + (x * 120) / edge + (y * 40) / edge
                let v = UInt8(clamping: base + noise)
                let i = (y * edge + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = UInt8(clamping: Int(v) - 10); bytes[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: edge, height: edge, bitsPerComponent: 8,
                            bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    // F
    @Test func unveraendertesKoernigesBildMisstAuchAufVollemRasterNahe1() throws {
        let original = Self.grainy(1600)
        let native = PixelSize(width: 1600, height: 1600)
        let reference = try #require(CandidateGenerator.referenceSample(original: original, target: native))
        #expect(reference.width == 320)
        let unchanged = try #require(ImageResampler.resize(original, to: native, components: 3))
        let onGrid = try #require(ImageResampler.resize(unchanged,
            to: PixelSize(width: reference.width, height: reference.height), components: 3))
        let m = try #require(QualityGates.Evaluator(reference: reference).measure(candidate: onGrid))
        #expect(m.globalSSIM > 0.99, "SSIM \(m.globalSSIM)")
        #expect(m.p05TileSSIM > 0.98, "p05 \(m.p05TileSSIM)")
    }

    /// Detailreiches Testbild: Schachbrett plus Farbverlauf. Die Felder
    /// (24 px auf 1000 px) sind auf dem 160-px-Zielraster noch aufgelöst
    /// (≈ 3,8 px) und gehen erst unterhalb verloren – nur so ist Fall D
    /// überhaupt messbar.
    static func detailed(_ edge: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<edge {
            for x in 0..<edge {
                let check = ((x / 24) + (y / 24)) % 2 == 0 ? 0.25 : 0.0
                ctx.setFillColor(red: Double(x) / Double(edge) * 0.7 + check,
                                 green: Double(y) / Double(edge) * 0.7 + check,
                                 blue: 0.4 + check, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    static func tinted(_ image: CGImage) -> CGImage {
        let ctx = CGContext(data: nil, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: rect)
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.35)
        ctx.fill(rect)
        return ctx.makeImage()!
    }

    // A + E
    @Test func rasterFolgtDerZielgroesseUndBleibtSonstBei320() {
        #expect(CandidateGenerator.measurementEdge(target: PixelSize(width: 163, height: 163)) == 163)
        #expect(CandidateGenerator.measurementEdge(target: PixelSize(width: 1200, height: 800)) == 320)
        #expect(CandidateGenerator.measurementEdge(target: nil) == 320)
        let original = Self.detailed(1000)
        let sample = QualityGates.sample(original, maxEdge: 160)
        #expect(sample?.width == 160)
        #expect(QualityGates.sample(original)?.width == 320)
    }

    // A: Verkleinerung auf das Ziel, auf dem Zielraster gemessen, ist nahezu verlustfrei.
    @Test func erlaubteVerkleinerungBestehtAufZielraster() throws {
        let original = Self.detailed(1000)
        let target = PixelSize(width: 160, height: 160)
        let reduced = try #require(ImageResampler.resize(original, to: target, components: 3))
        let edge = CandidateGenerator.measurementEdge(target: target)
        let reference = try #require(CandidateGenerator.referenceSample(original: original, target: target))
        let reducedSample = try #require(QualityGates.sample(reduced, maxEdge: edge))
        let m = try #require(QualityGates.Evaluator(reference: reference)
            .measure(candidate: reducedSample))
        #expect(m.globalSSIM > 0.97, "SSIM \(m.globalSSIM)")

        // Gegenprobe: Auf dem alten 320-px-Raster fällt dieselbe Verkleinerung ab.
        let upscaled = try #require(ImageResampler.resize(reduced,
            to: PixelSize(width: 320, height: 320), components: 3))
        let old = try #require(QualityGates.measure(reference: original, candidate: upscaled))
        #expect(old.globalSSIM < m.globalSSIM)
    }

    // C: Farbverfälschung bleibt sichtbar.
    @Test func farbverfaelschungFaelltAufZielrasterAuf() throws {
        let original = Self.detailed(1000)
        let target = PixelSize(width: 160, height: 160)
        let reduced = try #require(ImageResampler.resize(original, to: target, components: 3))
        let edge = CandidateGenerator.measurementEdge(target: target)
        let reference = try #require(CandidateGenerator.referenceSample(original: original, target: target))
        let evaluator = QualityGates.Evaluator(reference: reference)
        let faithfulSample = try #require(QualityGates.sample(reduced, maxEdge: edge))
        let shiftedSample = try #require(QualityGates.sample(Self.tinted(reduced), maxEdge: edge))
        let faithful = try #require(evaluator.measure(candidate: faithfulSample))
        let shifted = try #require(evaluator.measure(candidate: shiftedSample))
        let faithfulDE = try #require(faithful.meanDeltaE76)
        let shiftedDE = try #require(shifted.meanDeltaE76)
        #expect(shiftedDE > faithfulDE + 5, "ΔE \(shiftedDE) vs \(faithfulDE)")
    }

    // B + D: Verkleinerung unter das Ziel bleibt messbar schlechter.
    @Test func verkleinerungUnterDasZielBleibtMessbar() throws {
        let original = Self.detailed(1000)
        let target = PixelSize(width: 160, height: 160)
        let edge = CandidateGenerator.measurementEdge(target: target)
        let reference = try #require(CandidateGenerator.referenceSample(original: original, target: target))
        let evaluator = QualityGates.Evaluator(reference: reference)
        let atTarget = try #require(ImageResampler.resize(original, to: target, components: 3))
        let below = try #require(ImageResampler.resize(original,
            to: PixelSize(width: 60, height: 60), components: 3))
        let atTargetSample = try #require(QualityGates.sample(atTarget, maxEdge: edge))
        let belowOnGrid = try #require(ImageResampler.resize(below,
            to: PixelSize(width: reference.width, height: reference.height), components: 3))
        let ok = try #require(evaluator.measure(candidate: atTargetSample))
        let bad = try #require(evaluator.measure(candidate: belowOnGrid))
        #expect(bad.globalSSIM < ok.globalSSIM - 0.1,
                "unter Ziel \(bad.globalSSIM) vs Ziel \(ok.globalSSIM)")
    }

    // G
    @Test func kleinMisstAufFeinemRaster() {
        let big = PixelSize(width: 1600, height: 1200)
        #expect(CandidateGenerator.measurementEdge(target: big, fine: true) == 1024)
        #expect(CandidateGenerator.measurementEdge(target: big) == 320)
        #expect(CandidateGenerator.measurementEdge(target: PixelSize(width: 600, height: 400),
                                                   fine: true) == 600)
        #expect(CandidateGenerator.measuresFine(.small))
        #expect(!CandidateGenerator.measuresFine(.smart))
        #expect(!CandidateGenerator.measuresFine(.quality))
    }

    // G: Halbierte Auflösung besteht auf 320 px, fällt auf dem feinen Raster durch.
    @Test func halbierteAufloesungFaelltAufFeinemRasterDurch() throws {
        let original = Self.grainy(1600)
        let target = PixelSize(width: 1600, height: 1600)
        let half = try #require(ImageResampler.resize(original,
            to: PixelSize(width: 800, height: 800), components: 3))
        let softened = try #require(ImageResampler.resize(half, to: target, components: 3))
        let gate = QualityGatePolicy.policy(preset: .small, imageClass: .photo)

        func verdict(fine: Bool) throws -> (QualityGateMeasurement, Bool) {
            let reference = try #require(CandidateGenerator.referenceSample(
                original: original, target: target, fine: fine))
            let onGrid = try #require(ImageResampler.resize(softened,
                to: PixelSize(width: reference.width, height: reference.height), components: 3))
            // Der Evaluator tastet den Kandidaten auf dem Raster der Referenz ab.
            let m = try #require(QualityGates.Evaluator(reference: reference).measure(candidate: onGrid))
            if case .pass = QualityGates.qualityVerdict(policy: gate, measurement: m) {
                return (m, true)
            }
            return (m, false)
        }
        let (coarse, coarsePass) = try verdict(fine: false)
        let (fine, finePass) = try verdict(fine: true)
        #expect(coarsePass, "320 px: SSIM \(coarse.globalSSIM) p05 \(coarse.p05TileSSIM)")
        #expect(!finePass, "1024 px: SSIM \(fine.globalSSIM) p05 \(fine.p05TileSSIM)")
    }
}
