import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import PDFTools

/// Phase 1b (Roadmap) – JPEG-Backend mozjpeg.
///
/// Drei Zusagen werden hier festgenagelt:
///   1. Der verlustfreie Repack ändert KEINEN Pixel – nur die Verpackung
///      (optimierte Huffman-Tabellen, progressive Scans).
///   2. Bereits progressive JPEGs liefern das Skip-Signal und bleiben im
///      Stream byte-identisch (Never-Grow).
///   3. Der mozjpeg-Encode erreicht die PDF-Bridge als gültiger DCTDecode-
///      Stream; CMYK bleibt beim ImageIO-Fallback (siehe CMYKJPEGRoundTripTests).
@Suite struct MozjpegBackendTests {

    // MARK: - Helfer

    /// Foto-artiges Rauschen (Muster wie `photoHeavyPDF`): weiche Verläufe
    /// plus XOR-Struktur – genug Inhalt, dass progressive Kodierung gewinnt.
    static func noiseImage(_ width: Int, _ height: Int) -> CGImage? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        if let base = rep.bitmapData {
            let bpr = rep.bytesPerRow
            for y in 0..<height {
                let row = base + y * bpr
                for x in 0..<width {
                    let p = row + x * 4
                    p[0] = UInt8(truncatingIfNeeded: x * 255 / max(1, width))
                    p[1] = UInt8(truncatingIfNeeded: y * 255 / max(1, height))
                    p[2] = UInt8(truncatingIfNeeded: (x ^ y) * 255 / max(1, max(width, 1)))
                    p[3] = 255
                }
            }
        }
        return rep.cgImage
    }

    /// Rohe RGB-Pixelbytes eines dekodierten Bildes – Grundlage für den
    /// Bitidentitätsvergleich.
    static func rawRGB(_ image: CGImage) -> Data? {
        ImageResampler.rawBitmap(image, components: 3)
    }

    /// SOFn-Marker eines JPEG (0xC0 = Baseline, 0xC2 = progressive), nil wenn
    /// kein SOF gefunden wurde.
    static func sofMarker(_ jpeg: Data) -> Int? {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 < bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            let marker = Int(bytes[i + 1])
            if marker == 0xFF || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                i += 2
                continue
            }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if (0xC0...0xCF).contains(marker)
                && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                return marker
            }
            i += 2 + length
        }
        return nil
    }

    /// Mini-PDF mit EINEM DCTDecode-Bild, platziert seitenfüllend (72 dpi).
    static func dctPDF(jpeg: Data, pixels: Int) throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                + "/Filter/DCTDecode", data: jpeg)
        let resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>>>")
        let content = b.addStream(dictionary: "",
                                  content: "q 612 0 0 792 0 0 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "mozjpeg")
    }

    // MARK: - Verlustfreier Repack

    /// Baseline → Repack: progressive Ausgabe, kleinere Bytes, bitidentische
    /// Pixel beim Dekodieren.
    @Test func repackIstVerlustfreiUndKleiner() throws {
        let image = try #require(Self.noiseImage(800, 600))
        let baseline = try #require(
            ImageResampler.encodeJPEG(image, quality: 0.85, backend: .imageIO))
        #expect(Self.sofMarker(baseline) == 0xC0,
                "Fixture ist nicht baseline – Ausgangslage trägt nicht")

        let outcome = JPEGEncoder.repack(baseline)
        guard case .repacked(let repacked) = outcome else {
            Issue.record("Repack sollte liefern, war aber \(outcome)"); return
        }
        #expect(Self.sofMarker(repacked) == 0xC2,
                "Repack lief kein progressives JPEG")
        #expect(repacked.count < baseline.count,
                "Repack wuchs: \(baseline.count) → \(repacked.count)")

        // Koeffizienten bitidentisch → das Dekodat muss bytegleich sein.
        let decodedBaseline = try #require(ImageResampler.decodeJPEG(baseline))
        let decodedRepacked = try #require(ImageResampler.decodeJPEG(repacked))
        #expect(Self.rawRGB(decodedRepacked) == Self.rawRGB(decodedBaseline),
                "Repack hat Pixel verändert")
    }

    /// Skip-Regel: Bereits progressive Quelle → Skip-Signal, kein Repack.
    @Test func progressiveQuelleLiefertSkipSignal() throws {
        let image = try #require(Self.noiseImage(400, 400))
        // mozjpeg kodiert per Default progressive – damit ist die Quelle
        // unabhängig vom Repack progressiv.
        let progressive = try #require(
            ImageResampler.encodeJPEG(image, quality: 0.85, backend: .mozjpeg))
        #expect(Self.sofMarker(progressive) == 0xC2,
                "mozjpeg-Ausgabe ist nicht progressiv – Annahme trägt nicht")

        #expect(JPEGEncoder.repack(progressive) == .skipped,
                "Bereits progressive Quelle muss skippen")
        // Und der optimize-only-Modus ebenso: Der Scan-Entwurf steht schon.
        #expect(JPEGEncoder.repack(progressive, progressive: false) == .skipped)
    }

    /// „Maximale Kompatibilität": optimize-only darf nie progressive Scans
    /// schreiben. Ob er kleiner wird, hängt von der Quelle ab (ImageIO schreibt
    /// meist schon optimierte Tabellen) – Never-Grow erlaubt dann das Behalten.
    @Test func optimizeOnlySchreibtKeinProgressiv() throws {
        let image = try #require(Self.noiseImage(600, 400))
        let baseline = try #require(
            ImageResampler.encodeJPEG(image, quality: 0.85, backend: .imageIO))
        #expect(Self.sofMarker(baseline) == 0xC0)

        switch JPEGEncoder.repack(baseline, progressive: false) {
        case .repacked(let data):
            #expect(Self.sofMarker(data) == 0xC0,
                    "optimize-only darf nicht progressiv kodieren")
        case .keepOriginal:
            break   // Nicht kleiner als das Original – Original behalten.
        case .skipped:
            Issue.record("Baseline darf im optimize-only-Modus nicht skippen")
        }
    }

    // MARK: - Pipeline-Integration

    /// Never-Grow am Dokument: Ein bereits progressiv kodiertes Bild bleibt
    /// im Stream BYTE-IDENTISCH, auch wenn die Pipeline darüber läuft.
    @Test(.hangGuard) func progressivOptimiertesJPEGBleibtImStream() throws {
        let image = try #require(Self.noiseImage(400, 400))
        let jpeg = try #require(
            ImageResampler.encodeJPEG(image, quality: 0.85, backend: .mozjpeg))
        #expect(JPEGEncoder.repack(jpeg) == .skipped)

        let input = try Self.dctPDF(jpeg: jpeg, pixels: 400)
        defer { try? FileManager.default.removeItem(at: input) }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("moz-repack-skip-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(inputURL: input,
                                                  outputURL: out,
                                                  options: .smart)
        #expect(outcome.execution.repackedImages == 0)

        // Das Bild bleibt ein DCTDecode und trägt weiterhin DIESELBEN Bytes.
        let core = try PDFCoreDocument(path: out.path)
        let resources = try core.imageResources()
        #expect(resources.count == 1)
        let bytes = try #require(core.imageStreamData(
            objectID: resources[0].objectID, decoded: false))
        #expect(bytes == jpeg, "Progressiver Stream wurde verändert")
    }

    /// Verlustfreier Pass greift am Dokument: Baseline-DCTStream kommt
    /// progressiv und kleiner heraus, mit bitidentischen Pixeln.
    @Test(.hangGuard) func pipelineRepacktBaselineDCTStream() throws {
        let image = try #require(Self.noiseImage(400, 400))
        let baseline = try #require(
            ImageResampler.encodeJPEG(image, quality: 0.85, backend: .imageIO))
        let input = try Self.dctPDF(jpeg: baseline, pixels: 400)
        defer { try? FileManager.default.removeItem(at: input) }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("moz-repack-hit-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(inputURL: input,
                                                  outputURL: out,
                                                  options: .smart)
        // Das Bild ist in der Platzierung im Budget – der Plan behält es;
        // der Repack-Pass ist die einzige Stelle, die es anfasst.
        #expect(outcome.execution.repackedImages == 1,
                "Repack hat behaltene DCT-Streams nicht angefasst")

        let core = try PDFCoreDocument(path: out.path)
        let resources = try core.imageResources()
        #expect(resources.count == 1)
        #expect(resources[0].filters == [.dct])
        let bytes = try #require(core.imageStreamData(
            objectID: resources[0].objectID, decoded: false))
        #expect(Self.sofMarker(bytes) == 0xC2, "Stream ist nicht progressiv")
        #expect(bytes.count <= baseline.count, "Stream ist gewachsen")

        let decodedBefore = try #require(ImageResampler.decodeJPEG(baseline))
        let decodedAfter = try #require(ImageResampler.decodeJPEG(bytes))
        #expect(Self.rawRGB(decodedAfter) == Self.rawRGB(decodedBefore),
                "Repack hat Pixel verändert")
    }

    // MARK: - Lossy-Encode-Backend

    /// mozjpeg-Encode → DCTDecode-Ersetzung in der Mini-PDF: bestehende
    /// Erwartungen (filters == ["DCTDecode"], dekodierbar) bleiben grün, das
    /// Ergebnis ist progressive verpackt.
    @Test func mozjpegEncodeErsetztDCTDecodeStream() throws {
        let image = try #require(Self.noiseImage(300, 300))
        let jpeg = try #require(
            ImageResampler.encodeJPEG(image, quality: 0.8, backend: .mozjpeg))
        #expect(Self.sofMarker(jpeg) == 0xC2,
                "mozjpeg-Encode lief kein progressives JPEG")

        let url = try PDFFixtures.flateImagePDF(pixels: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let core = try PDFCoreDocument(path: url.path)
        let resource = try #require(try core.imageResources().first)

        try core.replaceImage(objectID: resource.objectID, jpegData: jpeg,
                              newWidth: 300, newHeight: 300, grayscale: false)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("moz-encode-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try core.save(to: out)

        let reopened = try PDFCoreDocument(path: out.path)
        let infos = try reopened.inspectImages()
        #expect(infos.count == 1)
        #expect(infos[0].filters == ["DCTDecode"])
        #expect(infos[0].width == 300 && infos[0].height == 300)
        let after = try #require(try reopened.imageResources().first)
        let bytes = try #require(reopened.imageStreamData(
            objectID: after.objectID, decoded: false))
        // Dekodierbar über ImageIO (der Decode-Pfad bleibt AppKit/ImageIO).
        #expect(ImageResampler.decodeJPEG(bytes) != nil)
    }

    /// Graustufen bleiben einkanalig: mozjpeg kodiert Grau als 1-Kanal-JPEG,
    /// ImageIO dekodiert es als Graustufenbild zurück.
    @Test func mozjpegKodiertGraustufenEinkanalig() throws {
        let image = try #require(Self.noiseImage(200, 200))
        guard let resized = ImageResampler.resize(image, to: PixelSize(width: 200, height: 200),
                                                  grayscale: true) else {
            Issue.record("Resize nach Grau fehlgeschlagen"); return
        }
        let jpeg = try #require(
            ImageResampler.encodeJPEG(resized, quality: 0.8, backend: .mozjpeg))
        let back = try #require(ImageResampler.decodeJPEG(jpeg))
        #expect(back.colorSpace?.model == .monochrome,
                "Graustufen-JPEG wurde nicht einkanalig dekodiert")
    }

    /// CMYK wird vom Shim abgelehnt und fällt auf ImageIO zurück – der
    /// Rundlauf bleibt viersprachig (siehe auch CMYKJPEGRoundTripTests).
    @Test func cmykFaelltAufImageIOZurueck() throws {
        let image = try #require(CMYKJPEGRoundTripTests.cmykImage(255, 0, 0, 0))
        let jpeg = try #require(
            ImageResampler.encodeJPEG(image, quality: 0.9, backend: .mozjpeg))
        let back = try #require(ImageResampler.decodeJPEG(jpeg))
        #expect(back.colorSpace?.numberOfComponents == 4,
                "CMYK-Fallback hat den Farbraum gewechselt")
    }
}
