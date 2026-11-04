import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import PDFTools

/// Phase V2-7 (Masterplan §13.7) – Seitenrekonstruktion und Erhalt der
/// nicht-raster Semantik.
///
/// Die Seite nach dem MRC-Rewrite muss außerhalb des Raster-Draws
/// identisch sein: OCR-Text-Operatoren, Annotationen, MediaBox – und der
/// zweite Lauf darf die MRC-Ausgabe nicht erneut MRC-fähig sehen.
@Suite(.timeLimit(.minutes(10))) struct MRCPageRewriteTests {

    static func mrcOptions() -> CompressionOptions {
        var options = CompressionOptions.make(mode: .smart, customConfig: nil,
                                              stripMetadata: false, linearize: false)
        // Diese Tests pruefen die MRC-Mechanik (Rekonstruktion, Seiten-QA),
        // nicht die Bedarfsregel: Die synthetische Scan-Seite ist nach der
        // JPEG-Leiter klein, MRC muss hier trotzdem laufen.
        options.mrcProvisionBudget.provisionIfCandidateExceedsBytes = 0
        return options
    }

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mrc-\(label)-\(UUID().uuidString).pdf")
    }

    /// Die Vorprüfung in der Provision muss dieselbe Grenze ziehen wie die
    /// Rekonstruktion: Sonst fiele ein lieferbarer Kandidat weg.
    @Test func ebenenGrenzeStimmtMitRekonstruktionUeberein() throws {
        #expect(MRCPageRewriter.fitsLayerLimit(photoRegionCount: 62))
        #expect(!MRCPageRewriter.fitsLayerLimit(photoRegionCount: 63))

        let input = try PDFFixtures.mrcScanPagePDF(withOCR: false, withLink: false)
        defer { try? FileManager.default.removeItem(at: input) }
        let document = try PDFCoreDocument(path: input.path)
        let resources = try document.imageResources()
        let resource = try #require(resources.first)
        let placement = try #require(resource.placements.first)
        let name = placement.resourceName.hasPrefix("/")
            ? String(placement.resourceName.dropFirst()) : placement.resourceName

        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let black = try #require(context.makeImage())
        let jpeg = try #require(ImageResampler.encodeJPEG(black, quality: 0.8))
        let maskBits = try #require(BilevelBuffer(
            width: 8, height: 8, data: Data(repeating: 0, count: 8)))
        let maskData = try #require(BilevelCodec.encodeG4(maskBits))
        func layers(photos: Int) -> [PDFCoreDocument.MRCLayer] {
            let photo = PDFCoreDocument.MRCLayer(
                kind: .jpeg(components: 1), width: 8, height: 8, data: jpeg,
                rect: CGRect(x: 0, y: 0, width: 8, height: 8))
            let background = PDFCoreDocument.MRCLayer(
                kind: .jpeg(components: 1), width: 8, height: 8, data: jpeg, rect: nil)
            let mask = PDFCoreDocument.MRCLayer(
                kind: .ccittG4Mask, width: 8, height: 8, data: maskData, rect: nil)
            return [background] + Array(repeating: photo, count: photos) + [mask]
        }
        func replace(photos: Int) throws {
            try document.replacePageImageDrawWithLayers(
                pageIndex: placement.pageIndex, imageObjectID: resource.objectID,
                resourceName: name, layers: layers(photos: photos))
        }
        #expect(throws: (any Error).self) { try replace(photos: 63) }
        try replace(photos: 62)
    }

    @Test func rekonstruktionErhaeltOCRTextAnnotationUndBoxen() throws {
        let input = try PDFFixtures.mrcScanPagePDF(withOCR: true, withLink: true)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = Self.tempURL("rewrite")
        defer { try? FileManager.default.removeItem(at: output) }

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: output, options: Self.mrcOptions())

        // Der MRC-Kandidat muss im Plan sichtbar sein und ausgeführt werden.
        let mrcAction = outcome.plan.actions.first { action in
            if case .mrc = action { return true }
            return false
        }
        guard case .mrc(_, let descriptor, let original, let expected) =
                try #require(mrcAction, "Erwartete MRC-Aktion im Plan") else {
            return
        }
        #expect(original > expected, "MRC-Bundle muss kleiner als das Raster sein")
        #expect(outcome.execution.mrcPages == 1)
        #expect(outcome.execution.bytesSavedMRC > 0)
        #expect(descriptor.pageIndex == 0)
        #expect(descriptor.resourceName == "Im0")

        // Datei gewinnt insgesamt (Raster → Bundle).
        let inBytes = Int(Compressor.fileSize(of: input))
        let outBytes = Int(Compressor.fileSize(of: output))
        #expect(outBytes < inBytes,
                "MRC-Ausgabe (\(outBytes)) größer als Eingabe (\(inBytes))")

        // 1. OCR-Textoperatoren bleiben: Der Text der unsichtbaren Ebene
        //    steht unverändert im Seiten-Content (§13.2).
        let core = try PDFCoreDocument(path: output.path)
        let content = try core.pageContentBytes(pageIndex: 0)
        let contentText = String(decoding: content, as: UTF8.self)
        #expect(contentText.contains("Selektierbarer OCR-Text der MRC-Erkennung"),
                "OCR-Textoperator fehlt im rekonstruierten Content")
        #expect(contentText.contains("3 Tr"), "Unsichtbarer Render-Modus bleibt")
        // Der alte Raster-Draw ist weg.
        #expect(!contentText.contains("/Im0 Do"),
                "Original-Raster-Draw muss ersetzt sein")

        // 2. Annotationen bleiben (Anzahl + URL).
        let counts = try core.annotationCounts(page: 0)
        #expect(counts.total == 1, "Link-Annotation verloren")
        #expect(try core.linkURLs().contains("https://example.com/mrc"))

        // 3. Boxen unverändert.
        let info = try core.pageInfo(at: 0)
        #expect(info.mediaBox == [0, 0, 612, 792])
        #expect(info.rotation == 0)

        // 4. Kein MRC-Zweitlauf: Die Ausgabe ist für die Engine keine
        //    Scan-Seite mit dominierendem Vollbild mehr.
        let second = Self.tempURL("second")
        defer { try? FileManager.default.removeItem(at: second) }
        let secondOutcome = try CompressionPipeline.run(
            inputURL: output, outputURL: second, options: Self.mrcOptions())
        #expect(!secondOutcome.plan.actions.contains { action in
            if case .mrc = action { return true }
            return false
        }, "MRC-Output darf nicht erneut MRC-Kandidat werden")
    }
}
