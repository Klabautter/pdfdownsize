import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Final Core Hardening, Phase 1 – getrennte Qualitätspolitik für Smart und
/// Custom.
///
/// Ausgangslage: Der UI-Pfad erzeugte `ssimThreshold: 1.1` bei einstufiger
/// Leiter `[customQuality]`. Der Planner prüft `ssim >= threshold`, und SSIM
/// erreicht höchstens 1.0 – die Bedingung ist also NIE erfüllt. Jedes Bild
/// landete bei `qualityRejected`, die vom Nutzer gewählte Qualität wurde nie
/// ausgeführt.
///
/// Zwei Semantiken stecken in einem Feld: Smart soll die beste Stufe suchen,
/// die eine Qualitätsschwelle hält; Custom soll genau das nehmen, was der
/// Nutzer gewählt hat. Ein Schwellwert von 1.1 war der Versuch, das zweite
/// über das erste zu erzwingen.
@Suite struct QualityPolicyTests {

    static func resource(width: Int, height: Int,
                         placedPoints: Double = 400) -> PDFImageResource {
        PDFImageResource(
            objectID: PDFObjectID(objectNumber: 7, generation: 0),
            width: width, height: height, bitsPerComponent: 8,
            colorSpace: .deviceRGB, filters: [.dct], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            decodeArray: [], encodedByteCount: 900_000,
            placements: [PDFImagePlacement(pageIndex: 0, resourceName: "/Im0",
                                           placedWidthPoints: placedPoints,
                                           placedHeightPoints: placedPoints * 0.75)])
    }

    /// Bild mit Struktur – ein Verlauf allein ist zu leicht komprimierbar,
    /// um Qualitätsunterschiede sichtbar zu machen.
    ///
    /// Foto-typische Signatur (V2-Klassifikator, §8.3): weiches Gefälle mit
    /// sanfter Mehrfrequenz-Modulation – breite Luminanzverteilung und
    /// Textur-Kacheln (Varianz > 25) ohne Sobel-Kanten. Der frühere
    /// 4×4-Blockteppich war kantendominant (edge 0.82, diag 0.69) und lief
    /// unter `.v2` in die Flachfamilie (dense_lines → lineArt) – die Tests
    /// der JPEG-Qualitätspolitik brauchen aber echtes Fotomaterial.
    static func texturedImage(_ width: Int, _ height: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data
        else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            let v = Double(y) / Double(height)
            for x in 0..<width {
                let u = Double(x) / Double(width)
                let luma = 0.06 + 0.86 * (0.6 * u + 0.4 * v)
                    + 0.10 * sin(2 * .pi * (3 * u + 2 * v))
                let chroma = 0.12 * sin(2 * .pi * (2 * u - 1.5 * v) + 0.6)
                let o = (y * width + x) * 4
                px[o] = UInt8(max(0, min(255, (luma + chroma) * 255).rounded()))
                px[o + 1] = UInt8(max(0, min(255, (luma + 0.3 * chroma) * 255).rounded()))
                px[o + 2] = UInt8(max(0, min(255, (luma - chroma) * 255).rounded()))
                px[o + 3] = 255
            }
        }
        return ctx.makeImage()
    }

    struct StubPixelSource: ImagePixelSource {
        let image: CGImage
        func decodedImage(for resource: PDFImageResource) -> CGImage? { image }
    }

    /// Die Konfiguration des Custom-Pfads.
    ///
    /// `threshold` ist parametrisiert, weil beide Formen abgedeckt sein
    /// müssen: die heutige (`0`) und die frühere (`1.1`). Die alte darf nicht
    /// stillschweigend wieder wirksam werden – deshalb prüft der Test sie
    /// weiterhin mit.
    static func customOptions(quality: Double, threshold: Double,
                              dpi: Double = 150) -> CompressionOptions {
        CompressionOptions(image: ImageCompressionOptions(
            ImageEngineConfig(targetDPI: dpi, maxPixelEdge: 4000,
                              jpegQuality: quality,
                              ssimThreshold: threshold,
                              qualityLadder: [quality],
                              tolerance: 1.15,
                              aggressiveGraphics: false,
                              forceGrayscale: false,
                              hardPixelCap: false)))
    }

    /// Der Nachweis des Fehlers: Mit der UI-Konfiguration wird KEIN Bild
    /// umkodiert, obwohl der Nutzer eine Qualität gewählt hat.
    @Test(.hangGuard,
          arguments: [0.70, 0.85, 0.95], [0.0, 1.1])
    func customQualityIsActuallyApplied(quality: Double, threshold: Double) throws {
        let resource = Self.resource(width: 2000, height: 1500)
        let source = StubPixelSource(
            image: try #require(Self.texturedImage(2000, 1500)))

        let result = try CompressionPlanner.plan(
            resources: [resource],
            options: Self.customOptions(quality: quality, threshold: threshold),
            documentID: "custom", documentBytes: 1_000_000, pixels: source)

        let transformed = result.plan.transformedActions
        #expect(!transformed.isEmpty, """
            Custom mit Qualität \(quality) hat KEIN Bild umkodiert. \
            Behalten wurde: \(result.plan.keptActions.count) Bild(er)
            """)

        // Und zwar mit GENAU der gewählten Qualität.
        if case .jpeg(_, _, let used, _, _, _, _) = transformed.first {
            #expect(abs(used - quality) < 0.001, """
                Custom \(quality) wurde als \(used) ausgeführt
                """)
        }
    }

    /// Gegenprobe: Smart darf weiterhin die Leiter durchlaufen und bei zu
    /// schlechter Qualität ablehnen – das ist der Sinn der Schwelle.
    @Test(.hangGuard) func smartStillRejectsBelowThreshold() throws {
        let resource = Self.resource(width: 2000, height: 1500)
        let source = StubPixelSource(
            image: try #require(Self.texturedImage(2000, 1500)))

        // Unerreichbar hohe Schwelle bei echter Leiter → Ablehnung.
        var options = CompressionOptions(image: ImageCompressionOptions(
            targetDPI: 96, tolerance: 1.0, maxPixelEdge: 900, hardPixelCap: true,
            jpegQuality: 0.8, qualityLadder: [0.6, 0.8], ssimThreshold: 0.9999,
            forceGrayscale: false, aggressiveGraphics: false))
        options.image.ssimThreshold = 0.9999

        let result = try CompressionPlanner.plan(
            resources: [resource], options: options,
            documentID: "smart", documentBytes: 1_000_000, pixels: source)

        #expect(result.plan.transformedActions.isEmpty, """
            Smart hat trotz unerreichbarer Schwelle umkodiert – die Schwelle \
            wäre damit bedeutungslos.
            """)
    }

    /// Der echte UI-Pfad darf keine unerreichbare Schwelle mehr erzeugen.
    ///
    /// Der Test liest die Konfiguration, die `CompressionViewModel` für
    /// Custom baut – nicht eine nachgebaute Kopie. Eine Schwelle über 1.0 ist
    /// per Konstruktion unerfüllbar; stünde sie wieder dort, komprimierte
    /// Custom erneut überhaupt nicht.
    @Test(.hangGuard) @MainActor
    func uiCustomPathHasNoUnreachableThreshold() {
        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        viewModel.customQuality = 0.75
        let config = viewModel.customConfig

        #expect(config.ssimThreshold <= 1.0, """
            Der UI-Pfad setzt eine Schwelle von \(config.ssimThreshold) – \
            SSIM erreicht höchstens 1.0, die Bedingung wäre nie erfüllt.
            """)

        let options = ImageCompressionOptions(config)
        guard case .fixed(let quality) = options.qualityPolicy else {
            Issue.record("Custom nutzt keine feste Qualität: \(options.qualityPolicy)")
            return
        }
        #expect(abs(quality - 0.75) < 0.001,
                "Die gewählte Qualität 0.75 kommt als \(quality) an")
    }

    // MARK: - Integration: unterschiedliche Qualität, unterschiedliches Ergebnis

    /// Q70 und Q95 dürfen nicht dasselbe Ergebnis liefern.
    ///
    /// Das ist die Probe darauf, dass die Wahl des Nutzers wirklich bis in
    /// die Bytes durchschlägt – nicht nur bis in den Plan. Solange Custom am
    /// unerreichbaren Qualitätsgate scheiterte, waren beide Ergebnisse
    /// identisch: nämlich unverändert.
    @Test(.hangGuard) func customQualityChangesTheOutput() throws {
        let resource = Self.resource(width: 2000, height: 1500)
        let source = StubPixelSource(
            image: try #require(Self.texturedImage(2000, 1500)))

        func bytes(forQuality quality: Double) throws -> Int {
            let result = try CompressionPlanner.plan(
                resources: [resource],
                options: Self.customOptions(quality: quality, threshold: 0),
                documentID: "cmp", documentBytes: 1_000_000, pixels: source)
            let action = try #require(result.plan.transformedActions.first,
                                      "Qualität \(quality) hat nichts umkodiert")
            return try #require(action.expectedEncodedBytes)
        }

        let low = try bytes(forQuality: 0.70)
        let high = try bytes(forQuality: 0.95)

        #expect(low < high, """
            Q70 ergibt \(low) Bytes, Q95 ergibt \(high) – eine höhere \
            Qualität muss mehr Bytes brauchen, sonst wirkt die Einstellung nicht.
            """)
    }

    /// Custom durchläuft KEINE Qualitätsleiter.
    ///
    /// Auch wenn eine mehrstufige Leiter mitgegeben wird, gilt die feste
    /// Wahl. Andernfalls entschiede der Planner erneut über etwas, das der
    /// Nutzer bereits entschieden hat.
    @Test(.hangGuard) func customIgnoresLadder() throws {
        let options = CompressionOptions(image: ImageCompressionOptions(
            targetDPI: 150, tolerance: 1.15, maxPixelEdge: 4000,
            hardPixelCap: false, forceGrayscale: false,
            aggressiveGraphics: false,
            qualityPolicy: .fixed(quality: 0.70)))

        guard case .fixed(let quality) = options.image.qualityPolicy else {
            Issue.record("Politik ist nicht fixed"); return
        }
        #expect(abs(quality - 0.70) < 0.001)
        #expect(options.image.qualityLadder == [0.70], """
            Die Leiter enthält mehr als die gewählte Stufe: \
            \(options.image.qualityLadder)
            """)
    }
}
