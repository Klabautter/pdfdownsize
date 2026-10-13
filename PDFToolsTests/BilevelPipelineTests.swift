import Testing
import Foundation
import CoreGraphics
import AppKit
import PDFKit
@testable import PDFTools

/// Phase 2b (Roadmap) – Bilevel-Pfad: CCITT G4 + lossless JBIG2.
///
/// Festgenagelt werden:
///   1. Die Kodierer erzeugen bitidentisch dekodierbare Kandidaten (Gate:
///      G4 über libtiff-Rückweg, JBIG2 über PDFKit-Render).
///   2. Der Race gewinnt mit dem KLEINSTEN bitidenten Kandidaten; Nie-
///      wächst-Gewinner und Inkompressibles bleiben unangetastet.
///   3. Die DecodeParms-Konvention (/BlackIs1 true) rendert in PDFKit
///      pixelgleich zur Quelle – der Pixelfolge-Vertrag ist empirisch
///      gegen den echten Dekodierer geprüft, nicht gegen den Kodierer.
@Suite struct BilevelPipelineTests {

    // MARK: - Helfer

    /// Textartiges Muster als Bilevel-Puffer (Bit 1 = schwarz).
    static func patternBuffer(width: Int = 900, height: Int = 1200) throws -> BilevelBuffer {
        guard let buffer = BilevelBuffer(width: width, height: height,
                                         data: PDFFixtures.bilevelPattern(width: width,
                                                                          height: height)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return buffer
    }

    /// Rohgröße des Bilevel-Puffers in Bytes.
    static func rawBytes(_ buffer: BilevelBuffer) -> Int {
        BilevelBuffer.rowBytes(width: buffer.width) * buffer.height
    }

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bilevel-\(label)-\(UUID().uuidString).pdf")
    }

    // MARK: - Kodierer + Gate (Codecebene)

    /// G4: nackter T6-Stream, deutlich kleiner als die Rohpixel und
    /// bitidentisch dekodierbar über denselben Codec.
    @Test func g4KandidatIstBitidentischUndKleiner() throws {
        let buffer = try Self.patternBuffer()
        let g4 = try #require(BilevelCodec.encodeG4(buffer),
                              "G4-Encode fehlgeschlagen")
        #expect(g4.count < Self.rawBytes(buffer) / 10,
                "G4 sollte auf Textmuster massiv gewinnen: \(g4.count) Bytes")

        let back = try #require(
            BilevelCodec.decodeG4(g4, width: buffer.width, height: buffer.height))
        #expect(back.bitIdentical(to: buffer),
                "G4-Rückweg hat Pixel verändert")
    }

    /// JBIG2 (generische Region): das Render-Gate (PDFKit = der echte
    /// Dekodierer) bestätigt Bitidentität.
    @Test func jbig2GenericBestehtDasPDFKitGate() throws {
        let buffer = try Self.patternBuffer()
        let page = try #require(BilevelCodec.encodeJBIG2Generic(buffer),
                                "JBIG2-Generic-Encode fehlgeschlagen")

        let rendered = try #require(
            BilevelRenderGate.decodedBuffer(page: page, globals: nil,
                                            width: buffer.width,
                                            height: buffer.height),
            "PDFKit konnte den JBIG2-Kandidaten nicht dekodieren")
        #expect(rendered.bitIdentical(to: buffer),
                "PDFKit-Render des JBIG2-Kandidaten ist nicht bitidentisch")
    }

    /// Der Symbolpfad mit Globals wird versucht, aber NUR ein bitidentischer
    /// Kandidat gewinnt den Race. Auf dem Textmuster gewinnt die generische
    /// Region (ohne Globals); das Dokument rendert pixelgleich zur Quelle.
    @Test(.hangGuard) func raceWähltDenKleinstenKandidaten() throws {
        let buffer = try Self.patternBuffer()
        let g4 = try #require(BilevelCodec.encodeG4(buffer))
        let generic = try #require(BilevelCodec.encodeJBIG2Generic(buffer))
        #expect(generic.count < g4.count,
                "Annahme trägt nicht: generisches JBIG2 (\(generic.count)) schlägt G4 (\(g4.count)) nicht")

        let input = try PDFFixtures.bilevelScanPDF(pixels: buffer.width,
                                                   rows: buffer.height,
                                                   placedPoints: 144)
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("race")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: .smart)
        guard case .jbig2(let id, let original, let expected) =
                try #require(outcome.plan.transformedActions.first) else {
            Issue.record("Erwartete JBIG2-Aktion, war: \(outcome.plan.actions)")
            return
        }
        #expect(expected < original, "Race-Ergebnis ist nicht kleiner")
        #expect(outcome.execution.replacedImages == 1)
        #expect(outcome.resources.first?.objectID == id,
                "Plan-Identität gehört nicht zum Eingangsbild")

        let core = try PDFCoreDocument(path: out.path)
        let resource = try #require(try core.imageResources().first)
        // Objektnummern vergibt der Writer neu – die Identität prüfen wir
        // über die Eingangsressource, die dem Plan zugrunde lag.
        #expect(resource.terminalFilter == .jbig2)
        #expect(resource.bitsPerComponent == 1)
        #expect(resource.width == buffer.width && resource.height == buffer.height)

        let page = try #require(core.imageStreamData(objectID: resource.objectID,
                                                     decoded: false))
        #expect(page == generic, "Seitenstrom weicht vom Kandidaten ab")

        // PDFKit rendert das Endergebnis pixelgleich zur Quellseite.
        let comparison = try #require(
            RenderDifferential.compare(sourceURL: input, outputURL: out,
                                       dpi: 150).first)
        #expect(comparison.changedAreaRatio == 0,
                "Render unterscheidet sich: CAR \(comparison.changedAreaRatio)")
        #expect(comparison.inkDelta == 0)
    }

    /// Globals-Mechanik: Die Bridge legt einen vorhandenen /JBIG2Globals-
    /// Strom als EIGENES indirektes Objekt an und verdrahtet /DecodeParms.
    /// (Der Symbolpfad liefert Globals nur, wenn sein Kandidat das Gate
    /// passiert; hier wird die Verdrahtung direkt an der Bridge geprüft.)
    @Test func bridgeLegtGlobalsAlsEigenesObjektAn() throws {
        let input = try PDFFixtures.bilevelScanPDF(pixels: 400, rows: 300,
                                                   placedPoints: 96)
        defer { try? FileManager.default.removeItem(at: input) }
        let core = try PDFCoreDocument(path: input.path)
        let resource = try #require(try core.imageResources().first)

        let fakePage = Data([0x00, 0x01, 0x02])
        let fakeGlobals = Data([0x03, 0x04])
        try core.replaceImageJBIG2(objectID: resource.objectID,
                                   pageData: fakePage,
                                   globalsData: fakeGlobals,
                                   width: 400, height: 300)
        let out = Self.tempURL("globals")
        defer { try? FileManager.default.removeItem(at: out) }
        try core.save(to: out)

        // qpdf --check muss grün bleiben (DecodeParms-Verweis aufgelöst).
        if let qpdf = Compressor.findQPDF() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: qpdf)
            process.arguments = ["--check", out.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0,
                    "qpdf --check nach JBIG2-Ersetzung nicht grün")
        }

        let raw = try String(decoding: Data(contentsOf: out), as: UTF8.self)
        #expect(raw.contains("/JBIG2Globals"))
        #expect(raw.contains("/JBIG2Decode"))
    }

    // MARK: - G4 am Dokument (Render-Verifikation)

    /// G4-Output am Dokument: Auf dem sparsamen Muster ist G4 gegen den
    /// Symbolpfad deterministisch im Vorteil; Filter, DecodeParms-Konvention
    /// und PDFKit-Rendervergleich gegen die Originaldatei.
    @Test(.hangGuard) func g4OutputRendertPixelgleichInPDFKit() throws {
        let input = try PDFFixtures.bilevelSparsePDF(placedPoints: 128)
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("g4")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: .smart)
        guard case .ccittG4 = try #require(outcome.plan.transformedActions.first) else {
            Issue.record("Erwartete G4-Aktion, war: \(outcome.plan.actions)")
            return
        }

        let core = try PDFCoreDocument(path: out.path)
        let resource = try #require(try core.imageResources().first)
        #expect(resource.terminalFilter == .ccitt)
        #expect(resource.bitsPerComponent == 1)
        #expect(resource.colorSpace == .deviceGray)

        // DecodeParms-Konvention: K -1, Columns, Rows, BlackIs1 true.
        let raw = try Data(contentsOf: out)
        let text = String(decoding: raw.prefix(4096), as: UTF8.self)
        #expect(text.contains("/CCITTFaxDecode"))
        #expect(text.contains("/BlackIs1 true"))
        #expect(text.contains("/K -1"))
        #expect(text.contains("/Columns 256"))
        #expect(text.contains("/Rows 256"))

        // Stream-Never-Grow: G4 ist kleiner als der Rohstrom (800×1000/8).
        let stream = try #require(core.imageStreamData(objectID: resource.objectID,
                                                       decoded: false))
        #expect(stream.count < 256 * 256 / 8)

        // PDFKit rendert Output und Original pixelgleich (Tintenabdeckung
        // gleich, kein sichtbarer Unterschied).
        let comparison = try #require(
            RenderDifferential.compare(sourceURL: input, outputURL: out,
                                       dpi: 150).first)
        #expect(comparison.changedAreaRatio == 0,
                "Render unterscheidet sich: CAR \(comparison.changedAreaRatio)")
        #expect(comparison.inkDelta == 0,
                "Tintenabdeckung verschoben: \(comparison.inkDelta)")
        #expect(comparison.ssim > 0.995)
    }

    // MARK: - Eingangsfälle

    /// Bereits G4-kodiertes Eingangsbild bleibt byte-identisch bestehen.
    ///
    /// Phase V2-3c (§9.10): Der GRUND hat sich geändert. Früher hielt hier
    /// die Capability-Sperre für CCITTFaxDecode; seit CCITT-Eingängen
    /// dekodierbar sind, läuft die Fixture in den Bilevel-Race – und der
    /// Zweitlauf-Schutz erkennt sie als EIGENEN Output (der Strom der
    /// Fixture IST der deterministische Re-Encode des decodierten Puffers):
    /// G4(G4(x)) wäre byteidentisch ohne Vorteil, also KEEP. Byte-Ergebnis
    /// identisch geblieben; der Strom wird im Zweitlauf nie angefasst.
    @Test(.hangGuard) func bereitsG4KodiertesBildBleibtBestehen() throws {
        let input = try PDFFixtures.ccittG4InputPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let originalCore = try PDFCoreDocument(path: input.path)
        let originalResource = try #require(try originalCore.imageResources().first)
        let originalBytes = try #require(originalCore.imageStreamData(
            objectID: originalResource.objectID, decoded: false))

        let out = Self.tempURL("ccitt-keep")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: .smart)
        #expect(outcome.replacedImages == 0)
        guard case .keep(_, let reason, _) = outcome.plan.actions[0] else {
            Issue.record("Erwartete Keep-Aktion, war: \(outcome.plan.actions)")
            return
        }
        guard case .noSizeBenefit = reason else {
            Issue.record("Erwartete Zweitlauf-KEEP (.noSizeBenefit), war: \(reason)")
            return
        }

        let core = try PDFCoreDocument(path: out.path)
        let resource = try #require(try core.imageResources().first)
        #expect(resource.terminalFilter == .ccitt)
        #expect(core.imageStreamData(objectID: resource.objectID,
                                     decoded: false) == originalBytes)
    }

    /// Inkompressibles 1-bit-Rauschen: kein Kandidat ist kleiner als die
    /// Rohbytes → Keep (Never-Grow auf Stream-Ebene).
    @Test(.hangGuard) func inkompressiblesBilevelWirdNichtAngefasst() throws {
        let input = try PDFFixtures.bilevelNoisePDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("noise")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: .smart)
        let action = outcome.plan.actions[0]
        guard case .keep(_, let reason, _) = action else {
            Issue.record("Erwartete Keep-Aktion, war: \(action)")
            return
        }
        #expect(reason == .noSizeBenefit || reason == .bilevelGateFailed)
        if reason != .noSizeBenefit && reason != .bilevelGateFailed {
            Issue.record("Unerwarteter Grund: \(reason.explanation)")
        }

        let core = try PDFCoreDocument(path: out.path)
        let resource = try #require(try core.imageResources().first)
        #expect(resource.terminalFilter != .ccitt && resource.terminalFilter != .jbig2)
        #expect(resource.bitsPerComponent == 1)
    }

    /// bilevelPolicy .keep: der Bilevel-Pfad läuft gar nicht erst – der
    /// Naiv-Scan bleibt exakt so im Stream stehen.
    @Test(.hangGuard) func bilevelPolicyKeepFasstNichtsAn() throws {
        let input = try PDFFixtures.bilevelScanPDF(pixels: 800, rows: 1000,
                                                   placedPoints: 96)
        defer { try? FileManager.default.removeItem(at: input) }
        let originalCore = try PDFCoreDocument(path: input.path)
        let originalResource = try #require(try originalCore.imageResources().first)
        let originalBytes = try #require(originalCore.imageStreamData(
            objectID: originalResource.objectID, decoded: false))

        let out = Self.tempURL("policy-keep")
        defer { try? FileManager.default.removeItem(at: out) }
        var options = CompressionOptions.smart
        options.image.bilevelPolicy = .keep
        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: options)
        #expect(outcome.replacedImages == 0)

        let core = try PDFCoreDocument(path: out.path)
        let resource = try #require(try core.imageResources().first)
        // Der Struktur-Pass darf den unkomprimierten Stream nachpacken
        // (FlateDecode); angetastet als BILEVEL darf er nicht sein.
        #expect(resource.terminalFilter == nil || resource.terminalFilter == .flate)
        // Die Bytes vergleichen DEKODIERT: Nachpacken ändert die Pixel nicht.
        #expect(core.imageStreamData(objectID: resource.objectID,
                                     decoded: true) == originalBytes)
    }

    /// Zweiter Durchlauf über einen bereits komprimierten Output: die
    /// Bilevel-Ergebnisse (CCITT/JBIG2) bleiben unangetastet.
    @Test(.hangGuard) func zweiterDurchlaufFasstBilevelOutputNichtAn() throws {
        let input = try PDFFixtures.bilevelScanPDF(pixels: 800, rows: 1000,
                                                   placedPoints: 96)
        defer { try? FileManager.default.removeItem(at: input) }
        let first = Self.tempURL("pass1")
        defer { try? FileManager.default.removeItem(at: first) }
        _ = try CompressionPipeline.run(inputURL: input, outputURL: first,
                                        options: .smart)

        let core1 = try PDFCoreDocument(path: first.path)
        let resource1 = try #require(try core1.imageResources().first)
        let bytes1 = try #require(core1.imageStreamData(objectID: resource1.objectID,
                                                        decoded: false))

        let second = Self.tempURL("pass2")
        defer { try? FileManager.default.removeItem(at: second) }
        let outcome = try CompressionPipeline.run(inputURL: first, outputURL: second,
                                                  options: .smart)
        #expect(outcome.replacedImages == 0)

        let core2 = try PDFCoreDocument(path: second.path)
        let resource2 = try #require(try core2.imageResources().first)
        #expect(resource2.terminalFilter == resource1.terminalFilter)
        #expect(core2.imageStreamData(objectID: resource2.objectID,
                                      decoded: false) == bytes1)
    }

    // MARK: - „Nahezu bilevel" (8-bit)

    /// Exakt zweiwertiges 8-bit-Grau: verlustfreie Abbildung auf 1-bit mit
    /// bitgleichem PDFKit-Render gegen die Quelle.
    @Test(.hangGuard) func nahezuBilevelWirdVerlustfreiErsetzt() throws {
        let input = try PDFFixtures.nearBilevelGrayPDF(pixels: 800, rows: 600)
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("near")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: .smart)
        let action = try #require(outcome.plan.transformedActions.first)
        // Welcher Kodierer den Race gewinnt, ist dem Muster überlassen –
        // beide sind verlustfreie Bilevel-Ergebnisse.
        switch action {
        case .ccittG4, .jbig2:
            break
        default:
            Issue.record("Erwartete Bilevel-Aktion, war: \(action)")
            return
        }

        let core = try PDFCoreDocument(path: out.path)
        let resource = try #require(try core.imageResources().first)
        #expect(resource.bitsPerComponent == 1)
        #expect(resource.colorSpace == .deviceGray)

        let comparison = try #require(
            RenderDifferential.compare(sourceURL: input, outputURL: out,
                                       dpi: 150).first)
        // Der Inhalt ist bitidentisch (Race-Gate); im Raster kann PDFKit an
        // Einzelkanten minimal anders resampeln – Tinte muss trotzdem
        // deckungsgleich sein.
        #expect(comparison.changedAreaRatio < 0.001,
                "8-bit → 1-bit hat sichtbar verändert: \(comparison.changedAreaRatio)")
        #expect(comparison.inkDelta == 0,
                "Tintenabdeckung verschoben: \(comparison.inkDelta)")
    }

    /// Anti-Aliasing-Grauabstufungen: die exakte Zweiwert-Prüfung scheitert,
    /// das Bild bleibt in der photo/graphics-Klasse (kein blindes
    /// Thresholding) und wird höchstens verlustfrei verkleinert.
    @Test(.hangGuard) func antiAliasingVerhindertBilevel() throws {
        let input = try PDFFixtures.antiAliasedScanPDF(pixels: 700, rows: 500)
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("aa")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: .smart)
        for action in outcome.plan.transformedActions {
            guard case .ccittG4 = action else { continue }
            Issue.record("AA-Bild wurde bilevel ersetzt: \(action)")
            return
        }

        let core = try PDFCoreDocument(path: out.path)
        let resource = try #require(try core.imageResources().first)
        #expect(resource.bitsPerComponent == 8,
                "Bittiefe wurde reduziert – das wäre Thresholding")
    }
}
