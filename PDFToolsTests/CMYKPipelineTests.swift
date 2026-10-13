import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFTools

/// Roadmap Phase 6a/6b – CMYK stufenweise.
///
/// **6a** verifiziert den bestehenden verlustfreien Pfad: CMYK-Input →
/// Downsample IM EIGENEN Farbraum → Flate + PNG-Prädiktor. Geprüft wird
/// streamgenau, nicht nur am Seitenbild.
///
/// **6b** schaltet den verlustfreien Koeffizienten-Repack für CMYK-JPEG-
/// Inputs frei. Vorarbeit war eine Messung, kein Glaube: `pdfcore_jpeg_repack`
/// transkodiert über jpeg_read/write_coefficients farbraumunabhängig, und
/// mozjpeg schreibt den Adobe-APP14-Marker (inkl. Transform-Byte) für
/// JCS_CMYK/JCS_YCCK automatisch (jcparam.c, jpeg_set_colorspace). Nachgeprüft
/// wird hier an einem echten CMYK-JPEG-Fixture: Marker erhalten, Koeffizienten
/// bitidentisch (dekodierte CMYK-Pixel bytegleich), Never-Grow am Dokument.
///
/// Phase 6C (kontrollierter CMYK-Re-Encode mit YCCK/ICC und ΔE-Gate) ist
/// separat verdrahtet und getestet: CMYKLossyTests. Diese Suite hier bleibt
/// auf die verlustfreien Stufen 6a/6b beschränkt.
@Suite struct CMYKPipelineTests {

    // MARK: - Helfer

    /// CMYK-Rauschbild (Muster wie `photoHeavyPDF`, vierkanalig) – genug
    /// Inhalt, dass der progressive Repack real gewinnt.
    static func cmykImage(_ width: Int, _ height: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                px[i]     = UInt8(truncatingIfNeeded: x * 255 / max(1, width))
                px[i + 1] = UInt8(truncatingIfNeeded: y * 255 / max(1, height))
                px[i + 2] = UInt8(truncatingIfNeeded: (x ^ y) * 255 / max(1, max(width, height)))
                px[i + 3] = UInt8((x / 8) % 60)
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

    /// CMYK-JPEG über ImageIO – der einzige Kodierer, der die Adobe-APP14-
    /// Konvention trägt (mozjpeg-Shim nimmt CMYK bewusst nicht an,
    /// siehe CMYKJPEGRoundTripTests).
    static func cmykJpeg(_ edge: Int, quality: Double) throws -> Data {
        let image = try #require(Self.cmykImage(edge, edge))
        // Backend .mozjpeg fällt für CMYK automatisch auf ImageIO zurück;
        // explizit .imageIO macht die Absicht sichtbar.
        return try #require(JPEGEncoder.encode(image, quality: quality,
                                               backend: .imageIO))
    }

    /// Transform-Byte des Adobe-APP14-Markers (0 = CMYK, 2 = YCCK); nil ohne
    /// Marker. Der Marker muss den Repack überleben – sonst deuten Leser
    /// die Werte falsch und die Druckfarben kippen.
    static func adobeTransform(_ jpeg: Data) -> Int? {
        let bytes = [UInt8](jpeg)
        var i = 2
        while i + 4 < bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            let marker = Int(bytes[i + 1])
            if marker == 0xFF || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                i += 2
                continue
            }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            // APP14: FF EE, Payload „Adobe" + Version + Flags + Transform.
            if marker == 0xEE, length >= 14,
               jpeg.subdata(in: (i + 4)..<(i + 9)) == Data("Adobe".utf8) {
                return Int(bytes[i + 4 + 11])
            }
            i += 2 + length
        }
        return nil
    }

    /// Rohe vierkanalige Pixel eines dekodierten CMYK-Bildes. Beide Seiten
    /// eines Vergleichs laufen durch denselben Umlauf – der Vergleich prüft
    /// Identität, nicht absolute CMYK-Werte.
    static func cmykPixels(_ image: CGImage) -> Data? {
        ImageResampler.rawBitmap(image, components: 4)
    }

    static func cmykJpegPDF(jpeg: Data, pixels: Int, placedPoints: Int) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceCMYK"
                + "/Filter/DCTDecode", data: jpeg)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(dictionary: "",
                                  content: "q \(placedPoints) 0 0 \(placedPoints) 0 0 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "cmyk-jpeg")
    }

    // MARK: - Phase 6a – CMYK-Flate verifizieren

    /// Der Pfad: CMYK-Input → Downsample in CMYK → Flate + Predictor.
    /// Streamgenau geprüft: gleicher Farbraum, verlustfreier Filter,
    /// Vierkanaligkeit, und die Ausgabepixel sind der RESAMPLETE Eingabe-
    /// Raster (dieselbe Herleitung wie in Planner/Executor).
    @Test(.hangGuard) func flateCmykWirdImEigenenFarbraumVerkleinert() throws {
        let url = try PDFFixtures.cmykPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let planned = try CompressionPipeline.plan(inputURL: url, options: .smart)
        try #require(planned.plan.transformedActions.count == 1)
        guard case .losslessResize(_, let target, let grayscale, _, _, _) =
                planned.plan.actions[0] else {
            Issue.record("CMYK-Flate läuft nicht in den verlustfreien Resize"); return
        }
        #expect(!grayscale, "CMYK darf nicht nach Grau fallen")

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmyk-flate-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                        options: .smart)

        let core = try PDFCoreDocument(path: out.path)
        let r = try #require(try core.imageResources().first)
        #expect(r.colorSpace == .deviceCMYK, "Farbraum wurde geändert: \(r.colorSpace)")
        #expect(r.terminalFilter == .flate, "Nicht verlustfrei kodiert: \(String(describing: r.terminalFilter))")
        #expect(r.width == target.width, "Planziel nicht ausgeführt")
        #expect(r.bitsPerComponent == 8)

        // Vierkanalige Rasterlänge – ein Dreikanal-Ersatz wäre hier längst
        // an der Bytezahl gescheitert, aber die Aussage soll explizit stehen.
        let decoded = try #require(core.imageStreamData(objectID: r.objectID,
                                                        decoded: true))
        #expect(decoded.count == r.width * r.height * 4)

        // Verlustfreiheit: Ausgabe == Eingabe, resampelt auf die geplante
        // Größe im CMYK-Farbraum (exakt der Plannungs-Umlauf).
        let source = try PDFCoreDocument(path: url.path)
        let src = try #require(try source.imageResources().first)
        let srcPixels = try #require(source.imageStreamData(objectID: src.objectID,
                                                            decoded: true))
        let srcImage = try #require(
            LibQPDFPixelSource.bitmap(from: srcPixels, resource: src))
        let expected = try #require(
            ImageResampler.resize(srcImage, to: target, components: 4))
        let expectedBytes = try #require(
            ImageResampler.rawBitmap(expected, components: 4))
        #expect(decoded == expectedBytes,
                "Die CMYK-Pixel stimmen nicht mit dem verlustfreien Resample überein")
    }

    /// Gate-Mechanik: Die Seite sieht danach aus wie vorher (Renderdiff über
    /// PDFKit, SSIM über die bestehende Metrik).
    @Test(.hangGuard) func flateCmykRenderdiffBleibtSauber() throws {
        let url = try PDFFixtures.cmykPhotoPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try #require(PDFDocument(url: url)?.page(at: 0)?
            .thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox))

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let after = try #require(PDFDocument(url: result.outputURL)?.page(at: 0)?
            .thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox))

        let a = try #require(before.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let b = try #require(after.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(QualityMetrics.ssim(original: a, candidate: b) > 0.95)
    }

    // MARK: - Phase 6b – Koeffizienten-Repack an CMYK-JPEG

    /// Der Repack verarbeitet 4-Komponenten-JPEGs koeffiziententreu:
    /// kleiner, progressiv, Adobe-APP14 (transform 0) erhalten, Pixel
    /// bitidentisch. ImageIO schreibt CMYK-JPEGs mit transform 0 – der
    /// Kodierer ist also die JFIF/Adobe-Variante, die Druckmaterial trägt.
    @Test(.hangGuard) func repackTranskodiertCmykKoeffiziententreu() throws {
        let jpeg = try Self.cmykJpeg(600, quality: 0.85)
        #expect(jpeg.range(of: Data("Adobe".utf8)) != nil,
                "Fixture trägt keinen Adobe-APP14-Marker – Ausgangslage trägt nicht")
        #expect(Self.adobeTransform(jpeg) == 0, "Fixture ist nicht als CMYK markiert")

        guard case .repacked(let repacked) = JPEGEncoder.repack(jpeg) else {
            Issue.record("Der Repack verweigert CMYK – Phase 6b müsste als Blockade dokumentiert werden")
            return
        }
        #expect(repacked.count < jpeg.count,
                "Repack wuchs: \(jpeg.count) → \(repacked.count)")
        #expect(repacked.range(of: Data("Adobe".utf8)) != nil,
                "Adobe-Marker ging beim Repack verloren")
        #expect(Self.adobeTransform(repacked) == Self.adobeTransform(jpeg),
                "Transform-Byte wurde geändert")
        #expect(Self.cmykPixels(try #require(ImageResampler.decodeJPEG(repacked)))
                == Self.cmykPixels(try #require(ImageResampler.decodeJPEG(jpeg))),
                "Koeffizienten nicht bitidentisch – der Repack hat CMYK verändert")
    }

    /// optimize-only (Kompatibilitätsmodus) bleibt Baseline – kein
    /// progressive Scan-Entwurf, Adobe-Marker weiterhin erhalten.
    @Test(.hangGuard) func repackOptimizeOnlyBleibtBaseline() throws {
        let jpeg = try Self.cmykJpeg(600, quality: 0.85)
        guard case .repacked(let repacked) = JPEGEncoder.repack(jpeg, progressive: false)
        else {
            Issue.record("optimize-only verweigert CMYK"); return
        }
        #expect(repacked.count < jpeg.count)
        #expect(repacked.range(of: Data("Adobe".utf8)) != nil)
        // Baseline: direkt nach SOI folgt DQT (FFDB), kein SOF2 (FFC2).
        #expect(repacked.range(of: Data([0xFF, 0xC2])) == nil,
                "optimize-only hat progressive Scans geschrieben")
        #expect(Self.cmykPixels(try #require(ImageResampler.decodeJPEG(repacked)))
                == Self.cmykPixels(try #require(ImageResampler.decodeJPEG(jpeg))))
    }

    /// Freischaltung Ende-zu-Ende: Ein CMYK-JPEG innerhalb des DPI-Budgets
    /// wird behalten und im Executor neu verpackt. Wörterbuch unverändert
    /// (/DeviceCMYK, /DCTDecode), Adobe-Marker erhalten, Pixel bitidentisch,
    /// Dokument nie größer (Never-Grow).
    @Test(.hangGuard) func executorRepacktBehaltenesCmykJpeg() throws {
        // 600 px auf 612 pt → ~71 DPI, weit unter dem Smart-Budget.
        let jpeg = try Self.cmykJpeg(600, quality: 0.85)
        let url = try Self.cmykJpegPDF(jpeg: jpeg, pixels: 600, placedPoints: 612)
        defer { try? FileManager.default.removeItem(at: url) }

        let planned = try CompressionPipeline.plan(inputURL: url, options: .smart)
        #expect(planned.plan.keptActions.count == 1,
                "Das Bild sollte im DPI-Budget behalten werden")

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmyk-repack-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                  options: .smart)
        #expect(outcome.execution.repackedImages == 1,
                "Der Repack-Pass hat das behaltene CMYK-JPEG nicht angefasst")

        let core = try PDFCoreDocument(path: out.path)
        let r = try #require(try core.imageResources().first)
        #expect(r.colorSpace == .deviceCMYK,
                "Wörterbuch wurde verändert: \(r.colorSpace)")
        #expect(r.terminalFilter == .dct)

        let bytes = try #require(core.imageStreamData(objectID: r.objectID,
                                                      decoded: false))
        #expect(bytes.count < jpeg.count,
                "Repack brachte nichts: \(jpeg.count) → \(bytes.count)")
        #expect(bytes.range(of: Data("Adobe".utf8)) != nil,
                "Adobe-Marker im Dokument verloren")
        #expect(Self.adobeTransform(bytes) == Self.adobeTransform(jpeg))
        #expect(Self.cmykPixels(try #require(ImageResampler.decodeJPEG(bytes)))
                == Self.cmykPixels(try #require(ImageResampler.decodeJPEG(jpeg))),
                "Das Bild im Dokument ist nicht koeffiziententreu")

        // Never-Grow am Gesamtdokument.
        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.outputBytes <= result.inputBytes,
                "Dokument gewachsen: \(result.inputBytes) → \(result.outputBytes)")
    }

    /// Skip-Regel: Bereits progressives CMYK-JPEG ist die Zielverpackung –
    /// die Stream-Bytes bleiben BYTEIDENTISCH im Dokument stehen.
    @Test(.hangGuard) func progressivesCmykBleibtByteidentisch() throws {
        let baseline = try Self.cmykJpeg(600, quality: 0.85)
        guard case .repacked(let progressive) = JPEGEncoder.repack(baseline) else {
            Issue.record("Fixture-Erzeugung scheiterte"); return
        }
        #expect(Self.adobeTransform(progressive) == 0)

        let url = try Self.cmykJpegPDF(jpeg: progressive, pixels: 600, placedPoints: 612)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let core = try PDFCoreDocument(path: result.outputURL.path)
        let r = try #require(try core.imageResources().first)
        let bytes = try #require(core.imageStreamData(objectID: r.objectID,
                                                      decoded: false))
        #expect(bytes == progressive,
                "Bereits progressives CMYK wurde neu verpackt – die Skip-Regel greift nicht")
        #expect(r.terminalFilter == .dct)
    }

    /// Und der verlustfreie Pfad bleibt auch für ÜBERSIZED CMYK-JPEGs
    /// zuständig, solange das Preset ihn verlangt (Smart): verkleinern im
    /// eigenen Farbraum, nie als JPEG neu kodieren. Die lossy-Ausnahme ist
    /// an das Quality-Preset gebunden (CMYKLossyTests).
    @Test(.hangGuard) func oversizedCmykJpegWirdVerlustfreiVerkleinert() throws {
        // 2000 px auf 150 pt → ~960 DPI, weit über dem Smart-Budget; das
        // verlustfreie Resample fällt dadurch so klein, dass es das JPEG
        // sicher unterbietet (Never-Grow des Plans).
        let jpeg = try Self.cmykJpeg(2000, quality: 0.95)
        let url = try Self.cmykJpegPDF(jpeg: jpeg, pixels: 2000, placedPoints: 150)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.outputBytes < result.inputBytes, "Nicht kleiner")

        let core = try PDFCoreDocument(path: result.outputURL.path)
        let r = try #require(try core.imageResources().first)
        #expect(r.colorSpace == .deviceCMYK, "Farbraum geändert: \(r.colorSpace)")
        #expect(r.terminalFilter != .dct,
                "CMYK wurde als JPEG neu kodiert – Phase 6C ist dafür nicht freigegeben")
        #expect(r.width < 2000, "Nicht verkleinert")
    }
}
