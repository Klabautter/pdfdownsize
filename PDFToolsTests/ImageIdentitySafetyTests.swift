import Testing
import Foundation
import CoreGraphics
import AppKit
import PDFKit
@testable import PDFTools

/// Masterplan Findings 13–15 / Schritte 1–4 – Quality Gates der
/// Compression-Sicherheit.
///
/// Gate 1: same-name/different-object ✓ shared-object ✓ SMask ✓
///         unsupported Filter ✓ no corruption ✓
/// Gate 2: ObjGen ✓ Shared XObject ✓ repeated resource names ✓ save/reopen/check ✓
/// Gate 3: keine Maskenregression, kein Alphaverlust
/// Gate 4: kein Page-Thumbnail-Fallback, Filter-Capability, echte Decoder
@Suite struct ImageIdentitySafetyTests {

    // MARK: - Der P0-Fall aus Finding 13

    /// Zwei verschiedene Bilder unter demselben Resource-Namen `/Im0`.
    /// Nach der Kompression muss jede Seite noch IHR eigenes Bild zeigen.
    @Test func sameResourceNameOnDifferentPagesKeepsOwnImages() throws {
        let fixture = try PDFFixtures.sameResourceNameDifferentObjectsPDF(pixels: 700)
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        // Vorher: die beiden Seiten sehen unterschiedlich aus.
        let beforeA = try #require(Self.pageFingerprint(fixture.url, page: 0))
        let beforeB = try #require(Self.pageFingerprint(fixture.url, page: 1))
        try #require(Self.colorDistance(beforeA, beforeB) > 0.15,
                     "Fixture untauglich: Seiten sind schon vorher ähnlich")

        // Die Fixture muss wirklich zwei Objekte unter EINEM Namen haben.
        let core = try PDFCoreDocument(path: fixture.url.path)
        let resources = try core.imageResources()
        #expect(resources.count == 2, "Erwartet zwei eigenständige Bildobjekte")
        #expect(Set(resources.flatMap { $0.placements.map(\.resourceName) }) == ["/Im0"],
                "Fixture muss beide Bilder unter /Im0 führen")
        #expect(Set(resources.map { $0.objectID.objectNumber })
            == [fixture.firstObjectNumber, fixture.secondObjectNumber])

        let out = Self.tempURL("samename-out")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(
            inputURL: fixture.url, outputURL: out,
            options: Self.forceTransformOptions)

        #expect(outcome.replacedImages == 2, "Beide Bilder sollten optimiert werden")

        // Kernaussage: A bleibt A-transformiert, B bleibt B-transformiert.
        let afterA = try #require(Self.pageFingerprint(out, page: 0))
        let afterB = try #require(Self.pageFingerprint(out, page: 1))

        #expect(Self.colorDistance(beforeA, afterA) < 0.12,
                "Seite 1 zeigt nicht mehr ihr eigenes Bild")
        #expect(Self.colorDistance(beforeB, afterB) < 0.12,
                "Seite 2 zeigt nicht mehr ihr eigenes Bild – Namenskollision!")
        #expect(Self.colorDistance(afterA, afterB) > 0.15,
                "Beide Seiten zeigen jetzt dasselbe Bild – Datenkorruption")

        // Struktur bleibt intakt.
        let reopened = try PDFCoreDocument(path: out.path)
        try reopened.check()
        #expect(reopened.pageCount == 2)
        #expect(try reopened.imageResources().count == 2)
    }

    /// Gegenprobe zum vorigen Test: Wird gezielt NUR das erste Objekt
    /// ersetzt, darf das zweite unverändert bleiben.
    @Test func replacingOneObjectLeavesTheOtherUntouched() throws {
        let fixture = try PDFFixtures.sameResourceNameDifferentObjectsPDF(pixels: 400)
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let out = Self.tempURL("single-replace")
        defer { try? FileManager.default.removeItem(at: out) }

        let beforeB = try #require(Self.pageFingerprint(fixture.url, page: 1))

        let core = try PDFCoreDocument(path: fixture.url.path)
        let target = PDFObjectID(objectNumber: fixture.firstObjectNumber, generation: 0)
        let jpeg = try #require(Self.solidJPEG(width: 64, height: 64, white: true))
        try core.replaceImage(objectID: target, jpegData: jpeg,
                              newWidth: 64, newHeight: 64, grayscale: false)
        try core.save(to: out)

        // Nach dem Schreiben vergibt qpdf neue Objektnummern – eine
        // PDFObjectID gilt nur für die Lebensdauer eines geöffneten
        // Dokuments. Identifiziert wird deshalb über die Seite.
        let reopened = try PDFCoreDocument(path: out.path)
        let resources = try reopened.imageResources()
        #expect(resources.count == 2, "Objektanzahl verändert")

        let onPage0 = try #require(resources.first {
            $0.placements.contains { $0.pageIndex == 0 } })
        let onPage1 = try #require(resources.first {
            $0.placements.contains { $0.pageIndex == 1 } })

        #expect(onPage0.width == 64, "Zielobjekt wurde nicht ersetzt")
        #expect(onPage1.width == 400, "Fremdes Objekt wurde mit verändert")

        let afterB = try #require(Self.pageFingerprint(out, page: 1))
        #expect(Self.colorDistance(beforeB, afterB) < 0.05,
                "Seite 2 hat sich verändert, obwohl nur Objekt 1 ersetzt wurde")
    }

    // MARK: - Geteiltes XObject

    @Test func sharedObjectIsOneResourceWithTwoPlacements() throws {
        let url = try PDFFixtures.sharedImageObjectPDF(pixels: 700)
        defer { try? FileManager.default.removeItem(at: url) }

        let core = try PDFCoreDocument(path: url.path)
        let resources = try core.imageResources()

        #expect(resources.count == 1, "Geteiltes XObject muss EINE Ressource sein")
        let resource = try #require(resources.first)
        #expect(resource.placements.count == 2)
        #expect(resource.isShared)
        #expect(Set(resource.placements.map(\.pageIndex)) == [0, 1])
    }

    @Test func sharedObjectIsTransformedOnceAndStaysConsistent() throws {
        let url = try PDFFixtures.sharedImageObjectPDF(pixels: 700)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = Self.tempURL("shared-out")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(
            inputURL: url, outputURL: out, options: Self.forceTransformOptions)

        // Eine Ressource = eine Ersetzung, nicht zwei.
        #expect(outcome.replacedImages == 1)

        let reopened = try PDFCoreDocument(path: out.path)
        try reopened.check()
        let after = try reopened.imageResources()
        #expect(after.count == 1, "Aus einem geteilten Objekt wurden mehrere")
        #expect(after.first?.placements.count == 2,
                "Eine Platzierung ist verloren gegangen")

        // Beide Seiten müssen weiterhin dasselbe Bild zeigen.
        let a = try #require(Self.pageFingerprint(out, page: 0))
        let b = try #require(Self.pageFingerprint(out, page: 1))
        #expect(Self.colorDistance(a, b) < 0.05,
                "Geteiltes Bild wird auf den Seiten unterschiedlich dargestellt")
    }

    // MARK: - Masken (Finding 14 / Schritt 3)

    /// Ein maskiertes Bild darf ersetzt werden – seine MASKENBEZIEHUNG nicht
    /// verlieren.
    ///
    /// Dieser Test verlangte früher das Gegenteil: „Maskiertes Bild wurde
    /// ersetzt" war der Fehlschlag. Die Begründung war, Bild und Maske
    /// müssten gemeinsam umgerechnet werden. Die Norm verlangt das nicht –
    /// nach PDF 32000-1 §8.9.6.4 wird eine weiche Maske auf ihr Basisbild
    /// skaliert und muss dessen Masse nicht teilen.
    ///
    /// Die alte Zusage kostete 143,5 MB im Korpus, 40 % aller Bilddaten.
    /// Was bleibt und hier geprüft wird, ist die Zusage, auf die es
    /// ankommt: Die Transparenz überlebt.
    @Test func softMaskedImageKeepsItsMaskWhenReplaced() throws {
        let url = try PDFFixtures.softMaskedImagePDF(pixels: 700)
        defer { try? FileManager.default.removeItem(at: url) }

        let core = try PDFCoreDocument(path: url.path)
        let masked = try #require(try core.imageResources()
            .first { $0.hasSoftMask })
        #expect(masked.transformCapability.isSafe, """
            Maskiertes Bild gilt als untransformierbar: \
            \(masked.transformCapability.reason)
            """)

        let out = Self.tempURL("smask-out")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(
            inputURL: url, outputURL: out, options: Self.forceTransformOptions)
        _ = outcome

        // Die Maskenbeziehung MUSS erhalten bleiben – sonst bekommt ein
        // freigestelltes Bild einen Kasten.
        let afterCore = try PDFCoreDocument(path: out.path)
        let afterImages = try afterCore.imageResources()
        #expect(afterImages.contains { $0.hasSoftMask }, """
            Nach der Bearbeitung trägt kein Bild mehr eine weiche Maske – \
            die Transparenz ist verloren.
            """)

        // Die Maskenbeziehung überlebt unverändert.
        let after = try PDFCoreDocument(path: out.path)
        try after.check()
        #expect(try after.imageResources().contains { $0.hasSoftMask },
                "SMask-Beziehung ist verloren gegangen")
    }

    /// Zweite Verteidigungslinie: Auch ein direkter Ersetzungsversuch am
    /// maskierten Objekt muss von der Bridge abgelehnt werden.
    /// Die Bridge überträgt die Maskenbeziehung beim Ersetzen.
    ///
    /// Sie VERWEIGERTE die Ersetzung früher – zweite Verteidigungslinie
    /// gegen einen Planner, der die Maske übersehen hätte. Da eine Maske
    /// kein Hindernis mehr ist, prüft dieser Test jetzt, dass die Bridge
    /// sie beim Neuaufbau des Wörterbuchs mitnimmt statt sie fallenzulassen.
    @Test func bridgeCarriesTheMaskOverOnReplacement() throws {
        let url = try PDFFixtures.softMaskedImagePDF(pixels: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        let core = try PDFCoreDocument(path: url.path)
        let masked = try #require(try core.imageResources().first { $0.hasSoftMask })
        let jpeg = try #require(Self.solidJPEG(width: 32, height: 32, white: true))

        try core.replaceImage(objectID: masked.objectID, jpegData: jpeg,
                              newWidth: 32, newHeight: 32, grayscale: false)

        let out = Self.tempURL("smask-bridge")
        defer { try? FileManager.default.removeItem(at: out) }
        try core.save(to: out)

        let after = try PDFCoreDocument(path: out.path)
        let images = try after.imageResources()
        #expect(images.contains { $0.hasSoftMask }, """
            Die Bridge hat die Maskenbeziehung beim Ersetzen fallenlassen.
            """)
    }

    /// Und die Gegenprobe: Farbschlüssel-Maskierung wird weiterhin verweigert.
    ///
    /// `/Mask` als Array benennt Farbwerte im Original; eine
    /// verlustbehaftete Neukodierung verschiebt sie. Ohne diese Probe wäre
    /// die Lockerung zu weit gegangen.
    @Test func bridgeStillRefusesColorKeyMasking() throws {
        let url = try PDFFixtures.colorKeyMaskedPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let core = try PDFCoreDocument(path: url.path)
        let image = try #require(try core.imageResources().first)
        let jpeg = try #require(Self.solidJPEG(width: 32, height: 32, white: true))

        #expect(throws: PDFCoreError.checkFailed) {
            try core.replaceImage(objectID: image.objectID, jpegData: jpeg,
                                  newWidth: 32, newHeight: 32, grayscale: false)
        }
    }

    @Test func decodeArrayImageIsNeverReplaced() throws {
        let url = try PDFFixtures.decodeArrayImagePDF(pixels: 700)
        defer { try? FileManager.default.removeItem(at: url) }

        let core = try PDFCoreDocument(path: url.path)
        let image = try #require(try core.imageResources().first)
        #expect(image.hasDecodeArray)
        #expect(image.transformCapability == .decodeArrayUnsupported)

        let out = Self.tempURL("decode-out")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(
            inputURL: url, outputURL: out, options: Self.forceTransformOptions)
        #expect(outcome.replacedImages == 0)
    }

    // MARK: - Filter-Capability (Finding 15 / Schritt 4)

    /// Filter ohne Decoder werden übersprungen, nicht gerendert.
    ///
    /// Phase 4b: JPXDecode zählt NICHT mehr dazu – es gibt seit Phase 4b
    /// einen echten Eingangsdecoder (OpenJPEG). Die Fähigkeits-Sperre trägt
    /// weiterhin CCITTFaxDecode/JBIG2Decode; die Fixture deklariert
    /// deshalb CCITTFaxDecode mit Inhalt, den kein Codec akzeptiert.
    @Test func unsupportedFilterIsSkippedNotRendered() throws {
        let url = try PDFFixtures.unsupportedFilterImagePDF(pixels: 700)
        defer { try? FileManager.default.removeItem(at: url) }

        let core = try PDFCoreDocument(path: url.path)
        let image = try #require(try core.imageResources().first)
        #expect(image.transformCapability == .unsupportedFilter("CCITTFaxDecode"))

        let out = Self.tempURL("ccitt-out")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(
            inputURL: url, outputURL: out, options: Self.forceTransformOptions)

        #expect(outcome.replacedImages == 0)

        // Der entscheidende Punkt: Der Filter bleibt CCITTFaxDecode. Früher
        // wurde hier ein DCT-Render der GESAMTEN SEITE eingesetzt.
        let after = try #require(try PDFCoreDocument(path: out.path).imageResources().first)
        #expect(after.terminalFilter == .ccitt,
                "Bild wurde durch ein anderes Format ersetzt")
        #expect(after.width == 700 && after.height == 700,
                "Bildgeometrie verändert, obwohl der Filter nicht lesbar ist")
    }

    /// Phase 4b – JPX-Eingang ist dekodierbar, aber BYTES ohne Codestream
    /// scheitern deterministisch: KEEP, Filter unverändert, keine Erfindung.
    @Test func corruptJpxStreamIsKeptDeterministically() throws {
        let url = try PDFFixtures.corruptJpxImagePDF(pixels: 700)
        defer { try? FileManager.default.removeItem(at: url) }

        let core = try PDFCoreDocument(path: url.path)
        let image = try #require(try core.imageResources().first)
        // JPX-INPUT ist heute zulässig – die Capability ist es, was die
        // frühere Sperre getragen hat.
        #expect(image.transformCapability == .safe)

        let source = LibQPDFPixelSource(document: core)
        #expect(source.decodedImage(for: image) == nil,
                "0x42-Füllung darf keinen Dekodiererfolg vortäuschen")

        let out = Self.tempURL("jpx-corrupt-out")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(
            inputURL: url, outputURL: out, options: Self.forceTransformOptions)

        #expect(outcome.replacedImages == 0)
        guard case .keep(_, let reason, _)? = outcome.plan.actions.first else {
            Issue.record("Erwartete KEEP-Aktion, war: \(outcome.plan.actions)")
            return
        }
        #expect(reason == .decodeFailed)

        let after = try #require(try PDFCoreDocument(path: out.path).imageResources().first)
        #expect(after.terminalFilter == .jpx,
                "Bild wurde durch ein anderes Format ersetzt")
        #expect(after.width == 700 && after.height == 700,
                "Bildgeometrie verändert, obwohl die Bytes nicht dekodierbar sind")
    }

    /// Flate-Bilder werden über den ECHTEN Stream dekodiert.
    @Test func flateImageIsDecodedFromItsOwnStream() throws {
        let url = try PDFFixtures.flateImagePDF(pixels: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        let core = try PDFCoreDocument(path: url.path)
        let resource = try #require(try core.imageResources().first)
        #expect(resource.terminalFilter == .flate)
        #expect(resource.transformCapability == .safe)

        // Die Pixel kommen aus dem Bildstream – erkennbar am bekannten
        // Verlauf der Fixture (links dunkel → rechts hell im Rotkanal).
        let source = LibQPDFPixelSource(document: core)
        let image = try #require(source.decodedImage(for: resource))
        #expect(image.width == 400 && image.height == 400,
                "Dekodiertes Bild hat nicht die Größe des XObjects")

        let left = try #require(Self.averageColor(image, region: CGRect(
            x: 0, y: 0, width: 40, height: 400)))
        let right = try #require(Self.averageColor(image, region: CGRect(
            x: 360, y: 0, width: 40, height: 400)))
        #expect(right.r > left.r + 0.3,
                "Kein echter Bildstream – Verlauf fehlt (r \(left.r) → \(right.r))")
    }

    @Test func flateImageIsTransformedWithoutPageRendering() throws {
        let url = try PDFFixtures.flateImagePDF(pixels: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = Self.tempURL("flate-out")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(
            inputURL: url, outputURL: out, options: Self.forceTransformOptions)

        #expect(outcome.replacedImages == 1)
        let after = try PDFCoreDocument(path: out.path)
        try after.check()
        let resource = try #require(try after.imageResources().first)
        #expect(resource.width < 400, "Bild wurde nicht verkleinert")
        // Seitengeometrie unverändert – ein Seitenrender hätte die
        // Bildproportionen auf die Seitenmaße gezogen.
        #expect(resource.width == resource.height,
                "Seitenverhältnis verändert – Verdacht auf Seitenrender")
    }

    // MARK: - Kein Datenverlust

    @Test func compressionKeepsStructureAndText() async throws {
        let url = try PDFFixtures.complexCombinationPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try PDFSemanticSnapshot.capture(url)
        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let after = try PDFSemanticSnapshot.capture(result.outputURL)
        let blocking = PDFSemanticSnapshot.differences(before, after)
            .filter { $0.severity <= .high }
        #expect(blocking.isEmpty, "Semantikverlust: \(blocking.map(\.message))")
    }

    // MARK: - Helfer

    static let forceTransformOptions = CompressionOptions(
        image: ImageCompressionOptions(
            targetDPI: 72, tolerance: 1.0, maxPixelEdge: 256, hardPixelCap: true,
            jpegQuality: 0.7, qualityLadder: [0.5, 0.7], ssimThreshold: 0.5,
            forceGrayscale: false, aggressiveGraphics: true))

    static func tempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).pdf")
    }

    struct RGB { let r: Double, g: Double, b: Double }

    /// Mittlere Farbe einer gerenderten Seite – robust gegen Requantisierung,
    /// empfindlich gegenüber „falsches Bild eingesetzt".
    static func pageFingerprint(_ url: URL, page index: Int) -> RGB? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: index) else {
            return nil
        }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let size = CGSize(width: 120, height: 120 * bounds.height / bounds.width)
        let thumb = page.thumbnail(of: size, for: .mediaBox)
        guard let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return averageColor(cg, region: CGRect(x: 0, y: 0,
                                               width: cg.width, height: cg.height))
    }

    static func averageColor(_ image: CGImage, region: CGRect) -> RGB? {
        let width = Int(region.width), height = Int(region.height)
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: -region.minX, y: -region.minY,
                                       width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
            return true
        }
        guard ok else { return nil }

        var totals = (r: 0.0, g: 0.0, b: 0.0)
        for pixel in stride(from: 0, to: buffer.count, by: 4) {
            totals.r += Double(buffer[pixel])
            totals.g += Double(buffer[pixel + 1])
            totals.b += Double(buffer[pixel + 2])
        }
        let count = Double(width * height) * 255
        return RGB(r: totals.r / count, g: totals.g / count, b: totals.b / count)
    }

    static func colorDistance(_ a: RGB, _ b: RGB) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    static func solidJPEG(width: Int, height: Int, white: Bool) -> Data? {
        let image = NSImage(size: CGSize(width: width, height: height))
        image.lockFocus()
        (white ? NSColor.white : NSColor.black).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
