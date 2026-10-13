import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Quantisierte Palette (Median-Cut, lossy – NUR Small/Target-Size, §4:
/// keine Farbreduktion in Smart/Qualität/Custom).
///
/// Belegt: Median-Cut hält ≤ 256 Einträge + Fehler-Gates, Dithering ist
/// deterministisch, das Preset-Gate trennt Small (quantisiert möglich) von
/// Smart (nie quantisiert), die Executor-Rekodierung ist deterministisch.
@Suite struct QuantizedPaletteTests {

    // MARK: - Helfer

    /// Verlauf + Flachanteil als CGImage (> 256 Farben, Grafik-Charakter).
    static func gradientImage(width: Int = 400, height: Int = 300) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let buf = ctx.data else { return nil }
        let px = buf.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                if y < height / 2 {
                    px[o] = UInt8(x * 255 / max(width - 1, 1))
                    px[o + 1] = UInt8(y * 64 / max(height / 2 - 1, 1))
                    px[o + 2] = 128
                } else if x % 96 < 60 {
                    px[o] = 20; px[o + 1] = 20; px[o + 2] = 20
                } else {
                    px[o] = 250; px[o + 1] = 250; px[o + 2] = 250
                }
            }
        }
        return ctx.makeImage()
    }

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quantpal-\(label)-\(UUID().uuidString).pdf")
    }

    // MARK: - Kodierung

    @Test func medianCutHaeltEintraegeUndFehlerGates() throws {
        let image = try #require(Self.gradientImage())
        for dither in [false, true] {
            guard case .success(let encoded) =
                    PaletteOptimizer.encodeQuantized(image, dither: dither) else {
                Issue.record("Quantisierung (dither=\(dither)) lieferte keinen Kandidaten")
                return
            }
            #expect(encoded.isQuantized)
            #expect(encoded.paletteEntries <= 256,
                    "Palette überläuft: \(encoded.paletteEntries)")
            #expect(encoded.components == 3)
            #expect(encoded.quality != nil,
                    "Quantisiert braucht eine Messung für Floors/Pareto")
        }
    }

    @Test func quantisierungIstDeterministisch() throws {
        let image = try #require(Self.gradientImage())
        func bytes(dither: Bool) throws -> Data {
            guard case .success(let encoded) =
                    PaletteOptimizer.encodeQuantized(image, dither: dither) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return encoded.indexStream
        }
        #expect(try bytes(dither: false) == bytes(dither: false))
        #expect(try bytes(dither: true) == bytes(dither: true))
    }

    // MARK: - Preset-Schranke (Small vs. Smart)

    /// Gegenrichtung der Größengrenze: Ein großer Verlauf (1200 px) läuft in
    /// Klein NICHT durch die Quantisierung – dort entscheiden Flate/JPEG.
    @Test(.hangGuard) func smallUeberspringtQuantisierungBeiGrossenBildern() throws {
        let url = try PDFFixtures.gradientScreenshotPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        var small = CompressionOptions(image: .small)
        small.featureFlags.candidateEngine = true
        let planned = try CompressionPipeline.plan(inputURL: url, options: small)
        let quantizedCandidates = planned.plan.candidateSets.flatMap(\.candidates)
            .filter { $0.id.rawValue.hasPrefix("indexed-q-") }
        #expect(quantizedCandidates.isEmpty,
                "große Bilder ohne Quantisierung: \(quantizedCandidates.map(\.id))")
    }

    /// Befund B4 (Review 2026-10-09): Ein Zielwert schaltete die
    /// Farbreduktion auch in „Eigene" frei – feste Nutzerparameter dürfen
    /// durch ein Ziel nicht umgedeutet werden. Fehlermöglichkeiten:
    /// (1) Custom + Ziel erzeugt `indexed-q-`-Kandidaten; (2) die Korrektur
    /// nimmt auch Klein + Ziel die Quantisierung (Positivkontrolle).
    @Test(.hangGuard) func zielSchaltetInEigeneKeineFarbreduktionFrei() throws {
        // 128 px: klein genug für die Quantisierung (`maximumQuantizedPalettePixels`).
        let url = try PDFFixtures.gradientScreenshotPDF(pixels: 128)
        defer { try? FileManager.default.removeItem(at: url) }
        func quantized(_ options: CompressionOptions) throws -> [String] {
            var o = options
            o.featureFlags.candidateEngine = true
            o.goal = .targetBytes(1_000)
            let planned = try CompressionPipeline.plan(inputURL: url, options: o)
            return planned.plan.candidateSets.flatMap(\.candidates)
                .map(\.id.rawValue).filter { $0.hasPrefix("indexed-q-") }
        }
        #expect(try quantized(CompressionPresetFactory.custom(dpi: 150, quality: 0.85)).isEmpty,
                "Eigene + Ziel plant Farbreduktion")
        #expect(try !quantized(CompressionOptions(image: .small)).isEmpty,
                "Klein + Ziel hat die Quantisierung verloren")
    }

    @Test(.hangGuard) func smartPlantNieQuantisiert() throws {
        let url = try PDFFixtures.gradientScreenshotPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: .smart)
        let quantized = planned.plan.actions.filter {
            if case .indexed(_, _, _, _, _, _, _, let q, _) = $0 { return q }
            return false
        }
        #expect(quantized.isEmpty,
                "Smart darf keine Farbreduktion fahren: \(quantized)")
    }

    /// Seit 2026-10-01 nur für kleine Bilder (≤ 128 × 128 px am Ziel,
    /// `maximumQuantizedPalettePixels`): Gemessen gewann die Palette nur dort
    /// (6 von 486 Bildern, alle ≤ 66 px); auf großen Kacheln kostete sie
    /// ~40 % der Klein-Suche. Der 128-px-Verlauf hat weiter > 256 Farben
    /// (128 Rotstufen × ~15 Grünstufen) – die exakte Palette bleibt unmöglich.
    @Test(.hangGuard) func smallDarfQuantisiertPlanen() throws {
        let url = try PDFFixtures.gradientScreenshotPDF(pixels: 128)
        defer { try? FileManager.default.removeItem(at: url) }
        var small = CompressionOptions(image: .small)
        small.featureFlags.candidateEngine = true
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: small)
        // Robust, ohne interne Strukturen: Die exakte Palette ist auf dem
        // Verlauf unmöglich (> 256 Farben) – jede Indexed-Aktion ist damit
        // per Konstruktion quantisiert.
        let indexed = planned.plan.actions.filter {
            if case .indexed = $0 { return true }
            return false
        }
        #expect(!indexed.isEmpty, Comment(rawValue:
                "Small muss den quantisierten Pfad erreichen (Sets: "
                + "\(planned.plan.candidateSets.count))"))
        for action in indexed {
            guard case .indexed(_, _, _, _, _, _, _, let q, _) = action else {
                continue
            }
            #expect(q, "Verlaufs-Indexed muss quantisiert sein (exakt unmöglich)")
        }
    }

    @Test(.hangGuard) func kleinerLaufBleibtValideUndDeterministisch() throws {
        let url = try PDFFixtures.gradientScreenshotPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        var small = CompressionOptions(image: .small)
        small.featureFlags.candidateEngine = true
        func run() throws -> CompressionPlan {
            let out = Self.tempURL("smallrun")
            defer { try? FileManager.default.removeItem(at: out) }
            let outcome = try CompressionPipeline.run(inputURL: url,
                                                      outputURL: out,
                                                      options: small)
            try PDFCoreDocument(path: out.path).check()
            return outcome.plan
        }
        let first = try run()
        let second = try run()
        #expect(first.decisions.map(\.selectedCandidateID)
                == second.decisions.map(\.selectedCandidateID),
                "Quantisierte Wahl muss deterministisch sein")
    }
}
