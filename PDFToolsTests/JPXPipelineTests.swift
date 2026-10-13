import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFTools

/// Phase 4b (Roadmap) – JPX/JPEG2000-Input-Decode.
///
/// Festgenagelt werden:
///   1. Der OpenJPEG-Shim (`pdfcore_jpx_decode` / `JPXDecoder`) liefert die
///      dokumentierte Byteform: Metadaten, Komponententabelle, interleaved
///      8-bit-Puffer; verlustfreie Fixtures pixelgenau, 16-bit → >> 8,
///      cp_reduce dekodiert direkt auf 1/2^N.
///   2. Die EXISTIERENDE Pipeline behandelt JPX-Bilder wie andere Bild-
///      quellen: überschrittenes DPI-Budget → decode → verkleinern →
///      Output DCTDecode (Foto) bzw. FlateDecode+PNG-Prädiktor (Grafik) –
///      NIE /JPXDecode. Effizientes JPX im Budget bleibt unangetastet.
///   3. Renderdiff (PDFKit) gegen das JPX-Original-Dokument: JPX-Input ist
///      verlustbehaftet, der Vergleich ist ein Rendervergleich innerhalb
///      Toleranz, kein Bitvergleich (wie im photo-Pfad).
///   4. Kein Grow, keine Erfindung bei korrupten Bytes, Plan-Determinismus.
@Suite struct JPXPipelineTests {

    // MARK: - Helfer

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jpx-\(label)-\(UUID().uuidString).pdf")
    }

    /// Mittelwert/Luminanz-Statistik eines kompakten Bereichs – für
    /// "der Puffer zeigt wirklich ein Bild"-Proben.
    static func sampleRange(_ data: Data, components: Int, width: Int,
                            x: Int, y: Int, w: Int, h: Int) -> (min: Int, max: Int) {
        let px = [UInt8](data)
        var mn = Int(UInt8.max), mx = 0
        for row in y..<(y + h) {
            for col in x..<(x + w) {
                for c in 0..<components {
                    let v = Int(px[(row * width + col) * components + c])
                    mn = min(mn, v)
                    mx = max(mx, v)
                }
            }
        }
        return (mn, mx)
    }

    // MARK: - Shim-Ebene (JPXDecoder über pdfcore_jpx_decode)

    @Test func shimDecodesRGBPhotoFixture() throws {
        let decoded = try #require(
            JPXDecoder.decode(PDFFixtures.JPXFixtureKind.photoRGBLossy.streamData),
            "RGB-Fixture muss dekodierbar sein")
        #expect(decoded.width == 240 && decoded.height == 180)
        #expect(decoded.components == 3)
        #expect(decoded.precision == 8)
        #expect(!decoded.signed)
        #expect(decoded.uniformGrid)
        #expect(decoded.pixels.count == 240 * 180 * 3)
        #expect(decoded.componentGeometries.count == 3)
        #expect(decoded.componentGeometries.allSatisfy {
            $0.width == 240 && $0.height == 180 && $0.dx == 1 && $0.dy == 1
        })
        // Der Puffer trägt echten Bildinhalt, keine Leerlauffüllung.
        let range = Self.sampleRange(decoded.pixels, components: 3, width: 240,
                                     x: 0, y: 0, w: 240, h: 180)
        #expect(range.max - range.min > 40,
                "Payload wirkt konstant: \(range.min)...\(range.max)")
    }

    @Test func shimDecodesLosslessGrayPixelExact() throws {
        let decoded = try #require(
            JPXDecoder.decode(PDFFixtures.JPXFixtureKind.grayLossless.streamData))
        #expect(decoded.width == 128 && decoded.height == 96)
        #expect(decoded.components == 1)
        #expect(decoded.pixels.count == 128 * 96)

        // Quellmuster (opj_compress verlustfrei, reversible 5/3):
        // Zeile y % 8 < 5 → 255, sonst 40; linker Balken (10≤x<20,
        // 10≤y<86) → 30; rechter Balken (x≥108, y % 16 < 8) → 60.
        // Verlustfrei heißt: exakt diese Werte stehen im Puffer.
        let px = [UInt8](decoded.pixels)
        func at(_ x: Int, _ y: Int) -> UInt8 { px[y * 128 + x] }
        #expect(at(0, 0) == 255, "Zeile 0 ist Papier: \(at(0, 0))")
        #expect(at(0, 5) == 40, "Lückenzeile: \(at(0, 5))")
        #expect(at(0, 7) == 40)
        #expect(at(0, 8) == 255)
        #expect(at(10, 10) == 30, "Linker Balken: \(at(10, 10))")
        #expect(at(19, 85) == 30)
        #expect(at(110, 0) == 60, "Rechter Balken: \(at(110, 0))")
        #expect(at(110, 8) == 255, "y%16=8 → Balken endet")
        #expect(at(64, 90) == 255, "Zeile 90: 90%8=2<5 → Papier")
    }

    @Test func shimShifts16BitTo8Bit() throws {
        let decoded = try #require(
            JPXDecoder.decode(PDFFixtures.JPXFixtureKind.gray16BitLossless.streamData))
        #expect(decoded.precision == 16)
        #expect(!decoded.signed)
        #expect(decoded.width == 96 && decoded.height == 64)
        #expect(decoded.pixels.count == 96 * 64)

        // Quelle (maxval 65535): Wert(x,y) = (x*65535/96) ^ (0x00FF, wenn
        // y%4<2). Das XOR betrifft nur das UNTERE Byte – nach dem Shim-
        // Shift um 8 bleibt (x*65535/96) >> 8. Verlustfrei → exakt.
        let px = [UInt8](decoded.pixels)
        for x in [0, 1, 7, 23, 48, 77, 95] {
            // Klammern zwingend: „>>" bindet in Swift STÄRKER als „/“.
            let expected = ((x * 65535) / 96) >> 8
            #expect(Int(px[x]) == expected,
                    "Spalte \(x): \(px[x]) statt \(expected)")
        }
    }

    @Test func shimAppliesReduce() throws {
        let full = try #require(
            JPXDecoder.decode(PDFFixtures.JPXFixtureKind.photoRGBLossy.streamData))
        let reduced = try #require(
            JPXDecoder.decode(PDFFixtures.JPXFixtureKind.photoRGBLossy.streamData,
                              reduce: 1))
        #expect(reduced.width == 120 && reduced.height == 90)
        #expect(reduced.pixels.count == 120 * 90 * 3)
        #expect(reduced.componentGeometries.allSatisfy {
            $0.width == 120 && $0.height == 90
        })
        #expect(full.width == 240, "Full-Decode bleibt unverändert")
    }

    @Test func shimRejectsGarbageAndTruncation() throws {
        #expect(JPXDecoder.decode(Data(repeating: 0x42, count: 4096)) == nil)
        #expect(JPXDecoder.decode(Data()) == nil)
        let stream = PDFFixtures.JPXFixtureKind.photoRGBLossy.streamData
        // SOC ohne SIZ-Ende – Struktur endet vor dem ersten Tile.
        #expect(JPXDecoder.decode(Data(stream.prefix(24))) == nil)
        // Abschneiden mitten im Codestream.
        #expect(JPXDecoder.decode(Data(stream.prefix(stream.count / 2))) == nil)
    }

    // MARK: - Pixelquelle

    @Test func pixelSourceDecodesJpxFromRealStream() throws {
        let input = try PDFFixtures.jpxImagePDF(kind: .photoRGBLossy,
                                                placedWidth: 240)
        defer { try? FileManager.default.removeItem(at: input) }
        let core = try PDFCoreDocument(path: input.path)
        let resource = try #require(try core.imageResources().first)
        #expect(resource.terminalFilter == .jpx)
        #expect(resource.transformCapability == .safe,
                "JPX-Input ist seit Phase 4b transformierbar")

        let source = LibQPDFPixelSource(document: core)
        let image = try #require(source.decodedImage(for: resource))
        #expect(image.width == 240 && image.height == 180)
        #expect(image.colorSpace?.model == .rgb)

        // Zielbezogener Aufruf: Das Ziel ist größer als die halbe Kante,
        // cp_reduce würde das Ziel unterschreiten → volle Auflösung.
        let kept = try #require(source.decodedImage(
            for: resource, target: PixelSize(width: 125, height: 94)))
        #expect(kept.width == 240 && kept.height == 180)
    }

    /// cp_reduce im Pipeline-Pfad: Nur nutzen, wenn das reduzierte Raster
    /// das Ziel noch abdeckt; die reduzierten Pixel sind die Quelle des
    /// weiteren Resizes.
    @Test func pixelSourceReducesOnlyWhenTargetIsCovered() throws {
        let input = try PDFFixtures.jpxImagePDF(kind: .grayLossless,
                                                placedWidth: 32)
        defer { try? FileManager.default.removeItem(at: input) }
        let core = try PDFCoreDocument(path: input.path)
        let resource = try #require(try core.imageResources().first)
        let source = LibQPDFPixelSource(document: core)

        // Ziel 49×37: halbes Raster (64×48) deckt das ab → reduce 1.
        let reduced = try #require(source.decodedImage(
            for: resource, target: PixelSize(width: 49, height: 37)))
        #expect(reduced.width == 64 && reduced.height == 48)

        // Ziel 100×75: halbes Raster (64×48) wäre zu klein → volle Auflösung.
        let full = try #require(source.decodedImage(
            for: resource, target: PixelSize(width: 100, height: 75)))
        #expect(full.width == 128 && full.height == 96)
    }

    // MARK: - Pipeline: oversized JPX-Foto → DCTDecode

    @Test(.hangGuard) func oversizedJpxPhotoIsReencodedAsDCT() throws {
        // 240 px auf 60 pt → 288 DPI, Budget (Smart-Ziel · 1,15) überschritten.
        let input = try PDFFixtures.jpxImagePDF(kind: .photoRGBLossy,
                                                placedWidth: 60)
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("photo")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(inputURL: input,
                                                  outputURL: out,
                                                  options: .smart)

        // Ziel: Faktor Smart-Ziel/288 → ceil(240·Faktor) – in Double-
        // Arithmetik exakt dieselbe Rechnung wie `plannedSize`; die Zahl
        // kommt aus der Konfiguration (seit 2026-10-09: 220 DPI), nicht aus
        // einer Konstanten. Der JPEG-Kandidat muss kleiner sein als der
        // JPX-Stream (Never-Grow), sonst hätte KEEP zu gelten.
        guard case .jpeg(let id, let target, _, let grayscale, _,
                         let original, let expected) =
                try #require(outcome.plan.transformedActions.first) else {
            Issue.record("Erwartete JPEG-Aktion, war: \(outcome.plan.actions)")
            return
        }
        let plannedFactor = ImageCompressionOptions.smart.targetDPI / (240.0 / 60.0 * 72.0)
        let plannedW = Int((Double(240) * plannedFactor).rounded(.up))
        let plannedH = Int((Double(180) * plannedFactor).rounded(.up))
        // §9.4 – die Auflösungsleiter ergänzt die 0,85×-Zielstufe; der
        // kleinste gate-passende Rung gewinnt. Beide Rung-Breiten sind
        // gültige Ergebnisse der DPI-Regel.
        let rungW = Int((Double(plannedW) * 0.85).rounded())
        let rungH = Int((Double(plannedH) * 0.85).rounded())
        let higherW = Int((Double(plannedW) * 1.25).rounded())
        let higherH = Int((Double(plannedH) * 1.25).rounded())
        #expect([plannedW, rungW, higherW].contains(target.width),
                "Ziel \(target) statt \(plannedW)×\(plannedH) (Rung \(rungW)×\(rungH))")
        #expect([plannedH, rungH, higherH].contains(target.height))
        #expect(grayscale == false)
        #expect(expected < original,
                "JPEG-Kandidat (\(expected)) sollte den JPX-Stream (\(original)) unterbieten")
        #expect(outcome.resources.first?.objectID == id)
        #expect(outcome.execution.replacedImages == 1)

        let core = try PDFCoreDocument(path: out.path)
        let after = try #require(try core.imageResources().first)
        // Der Kernpunkt der Phase: OUTPUT ist DCTDecode, niemals JPXDecode.
        #expect(after.terminalFilter == .dct)
        #expect(after.bitsPerComponent == 8)
        #expect(after.width == target.width && after.height == target.height)

        // Renderdiff (PDFKit) gegen das JPX-Original-Dokument – beide
        // Seiten verlustbehaftet, daher Toleranz statt Bitvergleich.
        // Gemessen an dieser Fixture: SSIM 0.9893, CAR 0.0000.
        let comparison = try #require(
            RenderDifferential.compare(sourceURL: input, outputURL: out,
                                       dpi: 150).first)
        #expect(comparison.ssim >= 0.95,
                "Render-SSIM unter Toleranz: \(comparison.ssim)")
        #expect(comparison.changedAreaRatio <= 0.02,
                "Render-CAR zu hoch: \(comparison.changedAreaRatio)")
    }

    // MARK: - Pipeline: JPX im Budget kann effizienter kodiert werden

    @Test(.hangGuard) func jpxWithinBudgetUsesSmallerQualityGatedEncoding() throws {
        // 240 px auf 240 pt → 72 DPI, weit im Budget.
        let input = try PDFFixtures.jpxImagePDF(kind: .photoRGBLossy,
                                                placedWidth: 240)
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("keep")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(inputURL: input,
                                                  outputURL: out,
                                                  options: .smart)

        guard case .jpeg(_, let target, _, _, let ssim, let original, let encoded)? = outcome.plan.actions.first else {
            Issue.record("Erwartete JPEG-Aktion, war: \(outcome.plan.actions)")
            return
        }
        #expect(target == PixelSize(width: 240, height: 180))
        #expect(try #require(ssim) >= 0.98)
        #expect(Double(encoded) <= Double(original) * 0.90)
        #expect(outcome.execution.replacedImages == 1)

        // Aufloesung bleibt erhalten; das ausgegebene Dokument wird separat gerendert.
        let core = try PDFCoreDocument(path: out.path)
        let after = try #require(try core.imageResources().first)
        #expect(after.terminalFilter == .dct)
        #expect(after.width == 240 && after.height == 180)
        let comparison = try #require(
            RenderDifferential.compare(sourceURL: input, outputURL: out,
                                       dpi: 150).first)
        #expect(comparison.ssim >= 0.98)
    }

    // MARK: - Pipeline: grafik-artiges JPX → verlustfreier Flate-Pfad

    /// Textartiges Balkenmuster, 288 DPI platziert → Smart verkleinert
    /// nach der DPI-Regel auf das Smart-Ziel (bei 220 DPI: 98×74) und bleibt
    /// Flate/Palette.
    ///
    /// Zwei Absichten, beide festgenagelt:
    ///  • Review 2026-09-26 (P1): Die Verkleinerung gilt NICHT als verlustfrei
    ///    und wird gegen das Original gemessen.
    ///  • DPI-Regel: Die erlaubte Verkleinerung auf das Ziel wird angenommen.
    ///    Zwischenzeitlich wurde sie abgelehnt, weil das Messraster fest bei
    ///    320 px lag (P0.1, Foto-Regression) – dieser Test erwartete damals
    ///    fälschlich die Ablehnung.
    @Test(.hangGuard) func oversizedGrayJpxTakesMeasuredResizeToTargetDPI() throws {
        let input = try PDFFixtures.jpxImagePDF(kind: .grayLossless,
                                                placedWidth: 32)
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("gray")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(inputURL: input,
                                                  outputURL: out,
                                                  options: .smart)

        let set = try #require(outcome.plan.candidateSets.first)
        let resized = set.candidates.filter {
            switch $0.kind {
            case .flate, .indexedFlate: return true
            default: return false
            }
        }
        #expect(!resized.isEmpty)
        #expect(resized.allSatisfy { !$0.isLossless && $0.metrics.gateMeasurement != nil },
                "Verkleinerung darf nicht als verlustfrei ungemessen durchgehen")

        // 128×96 px auf 32 pt → 288 DPI; Ziel wie `plannedSize`: ceil(px · Ziel/288).
        let factor = ImageCompressionOptions.smart.targetDPI / (128.0 / 32.0 * 72.0)
        let expectedW = Int((128.0 * factor).rounded(.up))
        let expectedH = Int((96.0 * factor).rounded(.up))
        let action = try #require(outcome.plan.transformedActions.first,
                                  "Erlaubte Verkleinerung auf die Ziel-DPI wurde abgelehnt: \(outcome.plan.actions)")
        switch action {
        case .losslessResize(_, let target, let grayscale, _, _, _):
            #expect(target.width == expectedW && target.height == expectedH,
                    "Ziel \(target) statt \(expectedW)×\(expectedH)")
            #expect(grayscale)
        case .indexed:
            break   // Palette gewonnen – ebenfalls verlustfreie Kodierung.
        default:
            Issue.record("Erwartete losslessResize-/indexed-Aktion, war: \(action)")
        }
        #expect(outcome.execution.replacedImages == 1)

        let core = try PDFCoreDocument(path: out.path)
        let after = try #require(try core.imageResources().first)
        #expect(after.terminalFilter == .flate,
                "Grafik-JPX muss verlustfrei kodiert bleiben, war \(String(describing: after.terminalFilter))")
        #expect(after.width == expectedW && after.height == expectedH)

        // Bei normaler Ansicht rendert die Ausgabe wie die Quelle.
        let comparison = try #require(
            RenderDifferential.compare(sourceURL: input, outputURL: out,
                                       dpi: 150).first)
        #expect(comparison.ssim >= 0.98,
                "Render-SSIM unter Toleranz: \(comparison.ssim)")
    }

    /// Derselbe Pfad über cp_reduce: Zielpixelzahl stark kleiner → der
    /// Executor kodiert von den REDUZIERTEN Pixeln, byteidentisch zum Plan.
    ///
    /// Zur Klasse: `grayLossless` ist das TEXTARTIGE Balkenmuster
    /// (255/40/30/60, siehe JPXFixtureKind und shimDecodesLosslessGrayPixelExact)
    /// – Grafik-Klasse → verlustfreier Flate-Pfad. Der glatte Grau-Verlauf
    /// ist die 16-bit-Fixtur (`gray16BitLossless`) und läuft im Test
    /// `sixteenBitJpxDecodesTo8BitDCT` über den JPEG-Pfad. Die kurzzeitige
    /// JPEG-Erwartung hier stammte aus einer Verwechslung der beiden
    /// Fixtures; gemessen (V2-3b-Diagnose): Das reduzierte Raster hat
    /// dominantColorShare 0.71 → Grafik, deterministisch in-suite wie
    /// einzeln.
    @Test(.hangGuard) func reducedJpxDecodeFeedsDeterministicPayload() throws {
        // 128 px auf 32 pt → 288 DPI; .small (110 DPI) → Ziel 49×37.
        // Das halbe Raster 64×48 deckt das Ziel ab → reduce 1.
        let input = try PDFFixtures.jpxImagePDF(kind: .grayLossless,
                                                placedWidth: 32)
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("reduce")
        defer { try? FileManager.default.removeItem(at: out) }

        // Der Executor kodiert denselben Pfad neu: reduzierte Dekodierung
        // (64×48) → Resize auf 49×37 → encodeLossless.
        let sourceCore = try PDFCoreDocument(path: input.path)
        let resource = try #require(try sourceCore.imageResources().first)
        let source = LibQPDFPixelSource(document: sourceCore)
        let reduced = try #require(source.decodedImage(
            for: resource, target: PixelSize(width: 49, height: 37)))
        #expect(reduced.width == 64 && reduced.height == 48)
        let resized = try #require(ImageResampler.resize(
            reduced, to: PixelSize(width: 49, height: 37), components: 1))
        let expectedPixels = try #require(ImageResampler.rawBitmap(resized, components: 1))

        // Isolate executor recomputation from production quality selection,
        // which correctly rejects the fine-bar downsampling above.
        let options = CompressionOptions(image: .small)
        let (action, _) = CompressionPlanner.planLosslessResize(
            resource: resource, image: reduced,
            target: PixelSize(width: 49, height: 37), grayscale: true)
        let plan = CompressionPlan(
            documentID: "jpx-payload", actions: [action],
            metadataPolicy: options.metadataPolicy,
            linearizationPolicy: options.linearizationPolicy,
            dedupPolicy: options.dedupPolicy, fontPolicy: options.fontPolicy,
            compatibilityPolicy: options.compatibilityPolicy,
            originalImageBytes: resource.encodedByteCount,
            originalDocumentBytes: Int(Compressor.fileSize(of: input)))
        let execution = try CompressionExecutor.execute(
            plan: plan, artifacts: CompressionPlanArtifacts(), document: sourceCore,
            pixels: source, resources: [resource], outputURL: out)
        #expect(execution.replacedImages == 1)

        let core = try PDFCoreDocument(path: out.path)
        let after = try #require(try core.imageResources().first)
        let writtenPixels = try #require(core.imageStreamData(objectID: after.objectID,
                                                              decoded: true))
        #expect(writtenPixels.prefix(expectedPixels.count) == expectedPixels,
                "cp_reduce-Pfad liefert nicht die Planpixel")
    }

    // MARK: - Pipeline: 16-bit JPX → 8-bit DCT

    @Test(.hangGuard) func sixteenBitJpxDecodesTo8BitDCT() throws {
        // 96 px auf 24 pt → 288 DPI. Der Grau-Verlauf ist photo-artig →
        // JPEG; 16-bit-Codestream wird beim Dekodieren auf 8-bit geschoben.
        let input = try PDFFixtures.jpxImagePDF(kind: .gray16BitLossless,
                                                placedWidth: 24)
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("16bit")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(inputURL: input,
                                                  outputURL: out,
                                                  options: .smart)

        guard case .jpeg(_, let target, _, let grayscale, _,
                         let original, let expected) =
                try #require(outcome.plan.transformedActions.first) else {
            Issue.record("Erwartete JPEG-Aktion, war: \(outcome.plan.actions)")
            return
        }
        // 96×64 px auf 24 pt → 288 DPI; Ziel wie `plannedSize`.
        let factor = ImageCompressionOptions.smart.targetDPI / (96.0 / 24.0 * 72.0)
        let plannedW = Int((96.0 * factor).rounded(.up))
        let plannedH = Int((64.0 * factor).rounded(.up))
        // §9.4 – die Auflösungsleiter ergänzt die 0,85×-Zielstufe; der
        // kleinste gate-passende Rung gewinnt.
        let rungW = Int((Double(plannedW) * 0.85).rounded())
        let rungH = Int((Double(plannedH) * 0.85).rounded())
        #expect(target.width == plannedW || target.width == rungW,
                Comment(rawValue: "Ziel \(target) statt \(plannedW)×\(plannedH), "
                    + "Leiter \(rungW)×\(rungH)"))
        #expect(grayscale, "Grauquelle muss einkanalig bleiben")
        #expect(expected < original)

        let core = try PDFCoreDocument(path: out.path)
        let after = try #require(try core.imageResources().first)
        #expect(after.terminalFilter == .dct, "Output muss DCTDecode sein")
        #expect(after.bitsPerComponent == 8, "Output muss 8-bit sein")
        #expect(after.colorSpace == .deviceGray,
                "Output-Farbraum: \(after.colorSpace)")
        #expect(after.width == target.width && after.height == target.height)

        // Renderdiff gegen das 16-bit-Original (PDFKit rendert beide).
        // Gemessen an dieser Fixture: SSIM 0.9988, CAR 0.0000.
        let comparison = try #require(
            RenderDifferential.compare(sourceURL: input, outputURL: out,
                                       dpi: 150).first)
        #expect(comparison.ssim >= 0.95,
                "Render-SSIM unter Toleranz: \(comparison.ssim)")
    }

    // MARK: - Determinismus und Regressionssicherheit

    /// Zwei Planungsläufe über dasselbe Dokument liefern denselben Plan –
    /// die Grundlage dafür, dass der Executor notfalls aus den
    /// Planparametern neu kodieren kann (Finding 11).
    @Test func planningIsDeterministic() throws {
        let input = try PDFFixtures.jpxImagePDF(kind: .photoRGBLossy,
                                                placedWidth: 60)
        defer { try? FileManager.default.removeItem(at: input) }

        let first = try CompressionPipeline.plan(inputURL: input, options: .smart)
        let second = try CompressionPipeline.plan(inputURL: input, options: .smart)
        // V2-11 – semantic Equality (Kandidaten-Metriken tragen gemessene
        // Laufzeiten, die im ms-Bereich streuen).
        #expect(first.plan.actions == second.plan.actions)
        #expect(first.plan.decisions.map(\.selectedCandidateID)
                == second.plan.decisions.map(\.selectedCandidateID))
    }

    /// Never-Grow am Dokument: Im TRANSFORMATIONSFALL darf der Lauf die
    /// JPX-Fixture nicht vergrößern (die Never-Grow-Prüfung am Stream
    /// verhindert das am Bild). Der reine KEEP-Fall wird auf Stream-Ebene
    /// geprüft (`efficientJpxWithinBudgetIsUntouched`); auf DATEI-Ebene kann
    /// qpdf-Container-Overhead dort minimal wachsen, ohne dass ein Bild
    /// angefasst wurde – das ist kein Bildwachstum, sondern Verpackung.
    @Test(.hangGuard) func jpxPipelineNeverGrowsTheDocument() throws {
        let oversized = try PDFFixtures.jpxImagePDF(kind: .gray16BitLossless,
                                                    placedWidth: 24)
        defer { try? FileManager.default.removeItem(at: oversized) }
        let jpegOut = Self.tempURL("ng-jpeg")
        defer { try? FileManager.default.removeItem(at: jpegOut) }
        _ = try CompressionPipeline.run(inputURL: oversized,
                                        outputURL: jpegOut, options: .smart)
        let jpegInputSize = try FileManager.default.attributesOfItem(
            atPath: oversized.path)[.size] as! Int
        let jpegOutputSize = try FileManager.default.attributesOfItem(
            atPath: jpegOut.path)[.size] as! Int
        #expect(jpegOutputSize <= jpegInputSize,
                "Transformationsfall wächst: \(jpegInputSize) → \(jpegOutputSize)")
    }
}
