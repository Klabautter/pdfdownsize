import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFTools

/// Roadmap Phase 6C – kontrollierter CMYK-JPEG-Re-Encode.
///
/// Der Pfad ist die erste verlustbehaftete CMYK-Verarbeitung und deshalb in
/// drei Richtungen abgeschlossen:
///
///  1. **Freischaltung**: Nur der Quality-Preset (Custom hinter der
///     Aggressive-Ausnahme) öffnet den YCCK-Kandidaten aus dem eigenen
///     mozjpeg-Shim; Smart/Klein bleiben bei 6a/6b.
///  2. **Farbraum**: /DeviceCMYK wird neu geschrieben, ICCBased-4 bleibt
///     stehen – die YCCK-Daten tragen die Werte des ursprünglichen
///     CMYK-Farbraums, das Profil beschreibt sie weiterhin richtig.
///  3. **Gates**: Größen-Race gegen den 6b-Repack des Originals (der im
///     Executor zuerst läuft) plus ΔE76-Gate auf der RGB-Renderstichprobe
///     (Mittel und Kachel) plus Adobe-APP14-Erhalt. Fail → 6b-Repack.
@Suite struct CMYKLossyTests {

    // MARK: - Fixtures

    /// Druckartiges CMYK-Foto: weiche Verläufe, milde Körnung. Harte Raster
    /// (XOR-Muster wie in CMYKPipelineTests) sind der Worst Case des
    /// ΔE-Gates; Druckfotos sind weicher.
    static func smoothCmykImage(_ width: Int, _ height: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 20260831
        func grain() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % 7) - 3
        }
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let u = Double(x) / Double(max(width - 1, 1))
                let v = Double(y) / Double(max(height - 1, 1))
                let ripple = 12.0 * sin(u * 21.0) * sin(v * 17.0)
                px[i]     = UInt8(max(0, min(255, Int(30 + u * 150 + ripple) + grain())))
                px[i + 1] = UInt8(max(0, min(255, Int(50 + v * 130 + 0.5 * ripple) + grain())))
                px[i + 2] = UInt8(max(0, min(255, Int(20 + (u + v) * 90) + grain())))
                px[i + 3] = UInt8(max(0, min(255, Int(10 + 40 * v) + grain())))
            }
        }
        var samples = px
        guard let space = CGColorSpace(name: CGColorSpace.genericCMYK),
              let ctx = CGContext(data: &samples, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    /// CMYK-JPEG über ImageIO (transform 0) – die Kodier-Variante, die
    /// Druckmaterial im Feld trägt.
    static func smoothCmykJpeg(_ edge: Int, quality: Double) throws -> Data {
        let image = try #require(smoothCmykImage(edge, edge))
        return try #require(JPEGEncoder.encode(image, quality: quality,
                                               backend: .imageIO))
    }

    /// CMYK-JPEG-PDF mit wählbarem /ColorSpace: DeviceCMYK oder, mit
    /// `iccProfile`, [/ICCBased n 0 R] über ein N-4-Profil.
    static func cmykJpegPDF(jpeg: Data, pixels: Int, placedPoints: Int,
                            iccProfile: Data? = nil) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let colorspace: String
        if let iccProfile {
            let profile = b.addStream(dictionary: "/N 4", data: iccProfile)
            colorspace = "[/ICCBased \(profile) 0 R]"
        } else {
            colorspace = "/DeviceCMYK"
        }
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace\(colorspace)"
                + "/Filter/DCTDecode", data: jpeg)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(dictionary: "",
                                  content: "q \(placedPoints) 0 0 \(placedPoints) 0 0 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "cmyk-lossy")
    }

    static func qualityOptions() -> CompressionOptions {
        CompressionOptions(image: .quality)
    }

    // MARK: - 1) End-to-End im Quality-Preset

    /// Oversized CMYK-JPEG im Quality-Preset: der YCCK-Re-Encode gewinnt die
    /// Race, bleibt unter der 6b-Barriere, trägt den Adobe-Marker mit
    /// transform 2, hält das ΔE-Gate am ENDGÜLTIGEN Dokument-Bytes und
    /// verändert das Seitenbild nicht messbar.
    @Test(.hangGuard) func qualityPresetReencodedCmykJpegEndToEnd() throws {
        let jpeg = try Self.smoothCmykJpeg(2000, quality: 0.95)
        let url = try Self.cmykJpegPDF(jpeg: jpeg, pixels: 2000, placedPoints: 150)
        defer { try? FileManager.default.removeItem(at: url) }

        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.qualityOptions())
        guard case .cmykJpegReencode(_, let target, let quality, _, _) =
                planned.plan.actions[0] else {
            Issue.record("Quality-Preset plant keinen CMYK-Re-Encode: \(planned.plan.actions[0])")
            return
        }
        #expect(target.width < 2000, "Zielgröße verkleinert nicht")
        #expect([0.85, 0.90, 0.92].contains(quality),
                "Qualität \(quality) liegt außerhalb der Preset-Leiter")

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmyk-lossy-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: Self.qualityOptions())
        #expect(outcome.execution.cmykReencodedImages == 1,
                "Der Executor hat den CMYK-Re-Encode nicht ausgeführt")

        let core = try PDFCoreDocument(path: out.path)
        let r = try #require(try core.imageResources().first)
        #expect(r.terminalFilter == .dct,
                "Kein JPEG im Dokument: \(String(describing: r.terminalFilter))")
        #expect(r.colorSpace == .deviceCMYK, "Farbraum geändert: \(r.colorSpace)")
        #expect(r.width == target.width, "Zielgröße nicht ausgeführt")

        let bytes = try #require(core.imageStreamData(objectID: r.objectID,
                                                      decoded: false))
        #expect(bytes.count < jpeg.count,
                "Re-Encode brachte nichts: \(jpeg.count) → \(bytes.count)")
        #expect(bytes.range(of: Data("Adobe".utf8)) != nil,
                "Adobe-APP14-Marker ging verloren")
        #expect(CMYKReencode.adobeTransformByte(bytes) == 2,
                "Kandidat ist nicht als YCCK (transform 2) markiert")

        // Pixel-Delta am Endprodukt: Referenz = Original-Dekodierung auf
        // Zielgröße, beide Seiten durch dieselbe RGB-Renderstichprobe.
        let original = try #require(ImageResampler.decodeJPEG(jpeg))
        let reference = try #require(ImageResampler.resize(
            original, to: PixelSize(width: r.width, height: r.height),
            components: 4))
        #expect(CMYKReencode.passesGate(reference: reference,
                                        candidateJPEG: bytes,
                                        limits: CMYKReencode.limits(preset: .quality)),
                "Der endgültige Kandidat hält das ΔE-Gate nicht")

        // Renderdiff: die Seite sieht danach aus wie vorher.
        let before = try #require(PDFDocument(url: url)?.page(at: 0)?
            .thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox))
        let after = try #require(PDFDocument(url: out)?.page(at: 0)?
            .thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox))
        let a = try #require(before.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let b = try #require(after.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(QualityMetrics.ssim(original: a, candidate: b) > 0.95,
                "Seitenbild hat sich messbar verändert")
    }

    // MARK: - 2) Smart bleibt verlustfrei

    /// Im Smart-Preset gibt es keinen lossy CMYK-Pfad: Das Bild läuft in den
    /// 6a-verlustfreien Resample (Flate im eigenen Farbraum).
    @Test(.hangGuard) func smartPresetBleibtVerlustfrei() throws {
        let jpeg = try Self.smoothCmykJpeg(2000, quality: 0.95)
        let url = try Self.cmykJpegPDF(jpeg: jpeg, pixels: 2000, placedPoints: 150)
        defer { try? FileManager.default.removeItem(at: url) }

        let planned = try CompressionPipeline.plan(inputURL: url, options: .smart)
        guard case .losslessResize = planned.plan.actions[0] else {
            Issue.record("Smart verlässt den verlustfreien CMYK-Pfad: \(planned.plan.actions[0])")
            return
        }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmyk-smart-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                        options: .smart)

        let core = try PDFCoreDocument(path: out.path)
        let r = try #require(try core.imageResources().first)
        #expect(r.terminalFilter == .flate,
                "Smart hat CMYK als JPEG neu kodiert: \(String(describing: r.terminalFilter))")
        #expect(r.colorSpace == .deviceCMYK, "Farbraum geändert: \(r.colorSpace)")
        #expect(r.width < 2000, "Nicht verkleinert")
    }

    // MARK: - 3) ICCBased-4 bleibt erhalten

    /// ICC-Farbraum: Die Input-Pixel SIND die ICC-Werte; der JPEG speichert
    /// rohe 4-Kanal-Werte, und der YCCK-Umlauf gibt sie zurück. Das N-4-
    /// Profil muss die Ersetzung also unverändert überstehen.
    @Test(.hangGuard) func iccBasedFarbraumBleibtErhalten() throws {
        let jpeg = try Self.smoothCmykJpeg(2000, quality: 0.95)
        let profile = try #require(
            CGColorSpace(name: CGColorSpace.genericCMYK)?.copyICCData() as Data?)
        let url = try Self.cmykJpegPDF(jpeg: jpeg, pixels: 2000, placedPoints: 150,
                                       iccProfile: profile)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try PDFCoreDocument(path: url.path)
        let src = try #require(try source.imageResources().first)
        #expect(src.colorSpace == .iccBased(components: 4),
                "Fixture liest nicht als ICCBased-4: \(src.colorSpace)")

        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.qualityOptions())
        guard case .cmykJpegReencode = planned.plan.actions[0] else {
            Issue.record("ICCBased-4 läuft nicht in den kontrollierten Re-Encode: \(planned.plan.actions[0])")
            return
        }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmyk-icc-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: Self.qualityOptions())
        #expect(outcome.execution.cmykReencodedImages == 1)

        let core = try PDFCoreDocument(path: out.path)
        let r = try #require(try core.imageResources().first)
        #expect(r.colorSpace == .iccBased(components: 4),
                "ICC-/ColorSpace ging bei der Ersetzung verloren: \(r.colorSpace)")
        #expect(r.terminalFilter == .dct)

        let bytes = try #require(core.imageStreamData(objectID: r.objectID,
                                                      decoded: false))
        #expect(bytes.count < jpeg.count)
        #expect(CMYKReencode.adobeTransformByte(bytes) == 2)
    }

    // MARK: - 4) Gate-Verletzung → Fallback auf 6b

    /// Ein Kandidat, der das ΔE-Gate reißt (katastrophal niedrige Stufe auf
    /// der Leiter, SSIM-Zusage bleibt 0,95 → Quality-Zelle), wird verworfen.
    /// Das Bild bleibt stehen, und der 6b-Repack des Originals übernimmt:
    /// gleiche Masse, transform 0 des Originals, pixelidentisch.
    @Test(.hangGuard) func gateVerletzungFaelltAufSechsBZurueck() throws {
        let jpeg = try Self.smoothCmykJpeg(2000, quality: 0.95)
        let url = try Self.cmykJpegPDF(jpeg: jpeg, pixels: 2000, placedPoints: 150)
        defer { try? FileManager.default.removeItem(at: url) }

        let imageOptions = ImageCompressionOptions(
            targetDPI: 300, tolerance: 1.15, maxPixelEdge: 4000,
            hardPixelCap: false, forceGrayscale: false, aggressiveGraphics: false,
            qualityPolicy: .adaptive(ladder: [0.02], minimumSSIM: 0.95))
        let options = CompressionOptions(image: imageOptions)

        let planned = try CompressionPipeline.plan(inputURL: url, options: options)
        guard case .keep(_, let reason, _) = planned.plan.actions[0] else {
            Issue.record("Der Gate-Verletzer wurde nicht behalten: \(planned.plan.actions[0])")
            return
        }
        // V2-11 – der 6b-Repack ist als eigener Kandidat im Set (§9.8);
        // scheitert der YCCK-Kandidat am Gate, gewinnt der Repack-KEEP und
        // der Grund ist noSizeBenefit (der Repack IST kleiner). Der frühere
        // .cmykGateFailed-Text beschrieb denselben Ausgang ohne Kandidaten.
        #expect(reason == .noSizeBenefit,
                "Falscher Keep-Grund: \(reason.explanation)")

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmyk-gate-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: options)
        #expect(outcome.execution.cmykReencodedImages == 0)

        let core = try PDFCoreDocument(path: out.path)
        let r = try #require(try core.imageResources().first)
        #expect(r.width == 2000, "Der Fallback darf die Masse nicht ändern")
        #expect(r.terminalFilter == .dct)
        #expect(outcome.execution.repackedImages == 1,
                "Der 6b-Repack hat das behaltene CMYK-JPEG nicht übernommen")

        let bytes = try #require(core.imageStreamData(objectID: r.objectID,
                                                      decoded: false))
        #expect(bytes.count < jpeg.count)
        #expect(CMYKReencode.adobeTransformByte(bytes) == 0,
                "Der Fallback trägt nicht mehr die CMYK-Markierung des Originals")
        #expect(CMYKPipelineTests.cmykPixels(
                    try #require(ImageResampler.decodeJPEG(bytes)))
                == CMYKPipelineTests.cmykPixels(
                    try #require(ImageResampler.decodeJPEG(jpeg))),
                "Der Fallback ist nicht koeffiziententreu")

        // Never-Grow am Gesamtdokument.
        #expect(Compressor.fileSize(of: out) <= Compressor.fileSize(of: url))
    }

    // MARK: - 5) Never-Grow

    /// Der gewinnende Kandidat liegt STRENG unter der 6b-Barriere (dem
    /// Repack des Originals) und unter dem Original; das Dokument wächst
    /// nie. Sanfter Überhang: 2000 px auf 400 pt ≈ 360 DPI.
    @Test(.hangGuard) func neverGrowGegenRaceUndDokument() throws {
        let jpeg = try Self.smoothCmykJpeg(2000, quality: 0.95)
        let url = try Self.cmykJpegPDF(jpeg: jpeg, pixels: 2000, placedPoints: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        let barrier: Int
        if case .repacked(let repacked) = JPEGEncoder.repack(jpeg) {
            barrier = repacked.count
        } else {
            barrier = jpeg.count
        }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmyk-nevergrow-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: Self.qualityOptions())
        #expect(outcome.execution.cmykReencodedImages == 1,
                "Der sanfte Überhang muss in den Re-Encode laufen: \(outcome.plan.actions[0])")

        let core = try PDFCoreDocument(path: out.path)
        let r = try #require(try core.imageResources().first)
        let bytes = try #require(core.imageStreamData(objectID: r.objectID,
                                                      decoded: false))
        #expect(bytes.count < barrier,
                "Kandidat (\(bytes.count)) schlug die 6b-Barriere (\(barrier)) nicht")
        #expect(bytes.count < jpeg.count,
                "Kandidat (\(bytes.count)) schlug das Original (\(jpeg.count)) nicht")
        #expect(Compressor.fileSize(of: out) <= Compressor.fileSize(of: url),
                "Dokument gewachsen")
    }
}
