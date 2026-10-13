import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import PDFTools

/// Phase V2-3c (§9.10) – CCITT-EINGANGS-Decode.
///
/// Festgenagelt werden:
///   1. G3- wie G4-Eingänge dekodieren auf die Bilevel-Pixelfolge (Bit 1 =
///      Tinte) – NUR mit vollständig abgedeckten DecodeParms (Katalog in
///      `CCITTDecodeParms.acceptanceIssue`); alles andere deterministisch
///      KEEP, bevor irgendein Decode läuft.
///   2. Die Pixelquelle liefert Pixel (8-bit Grau), der Bilevel-Race läuft
///      über die bestehende Architektur (CandidateSet KEEP/G4/JBIG2).
///   3. BlackIs1 ist für die Pixel-Extraktion wirkungslos: Der Fax-Strom
///      codiert weisse/schwarze Läufe intrinsisch; der Flag kehrt nur die
///      Abtastwert-Deutung im Leser um. PDFKit-Render beider Varianten ist
///      identisch – der empirische Gegenbeweis zu einer falschen Konvention.
///   4. Zweitlauf-Schutz: Ein eigener G4-Output (byteidentischer Re-Encode)
///      bleibt im Zweitlauf KEEP – kein Ping-Pong, kein iteratives Schrumpfen.
///
/// Die Produktion nimmt CCITT-Eingänge über die bestehende BilevelPolicy
/// (.auto) an der Bilevel-Race teil – KEIN stiller Verhaltenswechsel:
/// Mit BilevelPolicy .keep bleiben sie unangetastet (Capability-Sperre der
/// regulären Pfade bleibt bestehen).
@Suite struct CCITTInputDecodeTests {

    // MARK: - Helfer

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ccitt-input-\(label)-\(UUID().uuidString).pdf")
    }

    /// Der dem Fixtures-Strom zugrunde liegende Bilevel-Puffer.
    static func expectedPattern(width: Int, height: Int) throws -> BilevelBuffer {
        guard let buffer = BilevelBuffer(
            width: width, height: height,
            data: PDFFixtures.bilevelPattern(width: width, height: height, seed: 4242)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return buffer
    }

    /// Das SPARSAME Muster der G4-Eingangs-Fixtures als Bilevel-Puffer.
    static func expectedSparsePattern(width: Int, height: Int) throws -> BilevelBuffer {
        guard let buffer = BilevelBuffer(
            width: width, height: height,
            data: PDFFixtures.bilevelSparsePattern(width: width, height: height)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return buffer
    }

    static func firstResource(_ url: URL) throws -> (PDFCoreDocument, PDFImageResource) {
        let core = try PDFCoreDocument(path: url.path)
        let resource = try #require(try core.imageResources().first)
        return (core, resource)
    }

    // MARK: - DecodeParm-Katalog (Verweigerungen)

    /// Alle Katalog-Verweigerungen: KEEP mit decodeFailed, Output-Stream
    /// byteidentisch, kein Decode versucht (der Strom wäre sonst für
    /// K/Columns-Fälle ohnehin gescheitert – aber die Verweigerung greift
    /// VOR dem Codec, auch für plausibel klingende Ströme).
    @Test(.hangGuard, arguments: [
        PDFFixtures.CCITTRefusalCase.encodedByteAlign,
        PDFFixtures.CCITTRefusalCase.damagedRows,
        PDFFixtures.CCITTRefusalCase.missingK,
        PDFFixtures.CCITTRefusalCase.columnsMismatch,
        PDFFixtures.CCITTRefusalCase.foreignKey,
        PDFFixtures.CCITTRefusalCase.kOutOfRange,
        PDFFixtures.CCITTRefusalCase.endOfLineOnG4,
        PDFFixtures.CCITTRefusalCase.twoDWithoutEOL,
    ]) func verweigerungsfaelleBleibenKeep(_ refusal: PDFFixtures.CCITTRefusalCase) throws {
        let input = try PDFFixtures.ccittRefusalPDF(refusal)
        defer { try? FileManager.default.removeItem(at: input) }
        let originalCore = try PDFCoreDocument(path: input.path)
        let originalResource = try #require(try originalCore.imageResources().first)
        let originalBytes = try #require(originalCore.imageStreamData(
            objectID: originalResource.objectID, decoded: false))

        let out = Self.tempURL(refusal.rawValue)
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: .smart)
        #expect(outcome.replacedImages == 0)
        guard case .keep(_, let reason, _) = try #require(outcome.plan.actions.first) else {
            Issue.record("Erwartete Keep-Aktion, war: \(outcome.plan.actions)")
            return
        }
        // Die Verweigerung sitzt in der Pixelquelle (nil → decodeFailed),
        // NICHT als Capability – der echte Decode wäre erst danach dran.
        #expect(reason == .decodeFailed,
                "Unerwarteter Grund bei \(refusal.rawValue): \(reason.explanation)")

        let (core, resource) = try Self.firstResource(out)
        #expect(resource.terminalFilter == .ccitt)
        #expect(core.imageStreamData(objectID: resource.objectID,
                                     decoded: false) == originalBytes,
                "Verweigerter Stream wurde verändert (\(refusal.rawValue))")
    }

    /// BilevelPolicy .keep: CCITT-Eingänge bleiben unangetastet – kein
    /// stiller Verhaltenswechsel (die Race-Teilnahme ist an .auto gebunden).
    @Test(.hangGuard) func bilevelPolicyKeepFasstCCITTNichtAn() throws {
        let input = try PDFFixtures.ccittG4ExternalPDF()
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
        guard case .keep(_, let reason, _) = try #require(outcome.plan.actions.first) else {
            Issue.record("Erwartete Keep-Aktion, war: \(outcome.plan.actions)")
            return
        }
        // Seit Befund B7 (2026-10-09) nennt `.keep` seinen eigenen Grund
        // (`bilevelKept`) statt der generischen Capability-Sperre; das
        // Verhalten – Stream byteidentisch, nichts ersetzt – ist dasselbe
        // und wird unten weiter geprüft.
        guard reason == .bilevelKept else {
            Issue.record("Erwartete Bilevel-Keep-Grund, war: \(reason)")
            return
        }
        let (core, resource) = try Self.firstResource(out)
        #expect(core.imageStreamData(objectID: resource.objectID,
                                     decoded: false) == originalBytes)
    }

    // MARK: - Dekoder-Ebene (G3/G4)

    /// G3 1D ohne EOL-Codes (PDF-Default): Dekodierung auf dieselbe
    /// Tinten-1-Folge wie der Quellpuffer der Fixture.
    @Test(.hangGuard) func g3OhneEOLRundlauf() throws {
        let input = try PDFFixtures.ccittG3InputPDF(k: 0, endOfLine: false)
        defer { try? FileManager.default.removeItem(at: input) }
        let (core, resource) = try Self.firstResource(input)
        #expect(resource.terminalFilter == .ccitt)
        #expect(resource.bitsPerComponent == 1)

        let source = LibQPDFPixelSource(document: core)
        let buffer = try #require(source.bilevelBuffer(for: resource),
                                  "G3-Eingang dekodierte nicht")
        #expect(buffer.bitIdentical(to: try Self.expectedPattern(
            width: resource.width, height: resource.height)))
    }

    /// G3 1D mit EOL-Codes (T.4-Stil, /EndOfLine true).
    @Test(.hangGuard) func g3MitEOLRundlauf() throws {
        let input = try PDFFixtures.ccittG3InputPDF(k: 0, endOfLine: true)
        defer { try? FileManager.default.removeItem(at: input) }
        let (core, resource) = try Self.firstResource(input)
        let source = LibQPDFPixelSource(document: core)
        let buffer = try #require(source.bilevelBuffer(for: resource),
                                  "G3+EOL-Eingang dekodierte nicht")
        #expect(buffer.bitIdentical(to: try Self.expectedPattern(
            width: resource.width, height: resource.height)))
    }

    /// G3 2D (K > 0, gemischt 1D/2D mit EOL-Synchronisation).
    @Test(.hangGuard) func g3TwoDMitEOLRundlauf() throws {
        let input = try PDFFixtures.ccittG3InputPDF(k: 2, endOfLine: true)
        defer { try? FileManager.default.removeItem(at: input) }
        let (core, resource) = try Self.firstResource(input)
        let source = LibQPDFPixelSource(document: core)
        let buffer = try #require(source.bilevelBuffer(for: resource),
                                  "G3-2D-Eingang dekodierte nicht")
        #expect(buffer.bitIdentical(to: try Self.expectedPattern(
            width: resource.width, height: resource.height)))
    }

    /// G4-Eingang mit EOFB-Suffix (/EndOfBlock true): Der angehängte
    /// End-of-Block stört das zeilenzahlgesteuerte Lesen nicht.
    @Test(.hangGuard) func g4MitEOFBStartetDecodierbar() throws {
        let input = try PDFFixtures.ccittG4ExternalPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let (core, resource) = try Self.firstResource(input)
        let source = LibQPDFPixelSource(document: core)
        let buffer = try #require(source.bilevelBuffer(for: resource),
                                  "G4+EOFB-Eingang dekodierte nicht")
        #expect(buffer.bitIdentical(to: try Self.expectedSparsePattern(
            width: resource.width, height: resource.height)))
    }

    /// BlackIs1-Stromkonventionen: Dieselben Pixel aus einem fax-nativen
    /// Strom (PDF-Default, Abtastwert 1 = schwarz) und aus der invertierten
    /// Konvention (/BlackIs1 true – unsere eigene Output-Form). Beide
    /// extrahieren zur selben Tinten-Folge UND rendern identisch.
    @Test(.hangGuard) func blackIs1StromkonventionenLiefertGleichePixel() throws {
        let native = try PDFFixtures.ccittG4ExternalPDF(
            inverted: false, endOfBlock: false, name: "ccitt-b1-native")
        let inverted = try PDFFixtures.ccittG4ExternalPDF(
            inverted: true, endOfBlock: false, name: "ccitt-b1-inverted")
        defer {
            for url in [native, inverted] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var buffers: [BilevelBuffer] = []
        for url in [native, inverted] {
            let (core, resource) = try Self.firstResource(url)
            let source = LibQPDFPixelSource(document: core)
            let buffer = try #require(source.bilevelBuffer(for: resource))
            #expect(buffer.bitIdentical(to: try Self.expectedSparsePattern(
                width: resource.width, height: resource.height)),
                "\(url.lastPathComponent): Tinten-Bits falsch")
            buffers.append(buffer)
        }
        #expect(buffers[0] == buffers[1],
                "Fax-nativ und BlackIs1-invertiert liefern verschiedene Pixel")

        // Und der Render bleibt identisch – beide Strom-/Flag-Paare
        // deklarieren denselben physischen Inhalt.
        let comparison = try #require(
            RenderDifferential.compare(sourceURL: native, outputURL: inverted,
                                       dpi: 150).first)
        #expect(comparison.changedAreaRatio == 0,
                "Stromkonventionen rendern unterschiedlich: \(comparison.changedAreaRatio)")
        #expect(comparison.inkDelta == 0)
    }

    // MARK: - Pixelquelle (8-bit Grau)

    /// decodedImage liefert ein 8-bit DeviceGray-Bild, dessen Grauwerte die
    /// Tinten-Bits exakt abbilden (Tinte = 0, Papier = 255).
    @Test(.hangGuard) func pixelquelleLiefertGraubild() throws {
        let input = try PDFFixtures.ccittG4ExternalPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let (core, resource) = try Self.firstResource(input)
        let source = LibQPDFPixelSource(document: core)
        let image = try #require(source.decodedImage(for: resource))
        #expect(image.width == resource.width)
        #expect(image.height == resource.height)
        #expect(image.bitsPerComponent == 8)
        #expect(image.bitsPerPixel == 8)

        let pattern = try Self.expectedSparsePattern(width: resource.width,
                                                     height: resource.height)
        let rowBytes = BilevelBuffer.rowBytes(width: resource.width)
        let raw = try #require(ImageResampler.rawBitmap(image, components: 1))
        #expect(raw.count == resource.width * resource.height)
        // Kein 480k-#expect-Loop: ein Scan, ein Issue beim ersten Abweicher.
        let bytes = [UInt8](raw)
        var firstMismatch: (Int, Int, UInt8)?
        scan: for y in 0..<resource.height {
            for x in 0..<resource.width {
                let ink = (pattern.data[y * rowBytes + (x >> 3)]
                    >> UInt8(7 - (x & 7))) & 1
                let expected: UInt8 = ink == 1 ? 0 : 255
                if bytes[y * resource.width + x] != expected {
                    firstMismatch = (x, y, bytes[y * resource.width + x])
                    break scan
                }
            }
        }
        #expect(firstMismatch == nil,
                "Grauwert widerspricht der Tinte bei \(String(describing: firstMismatch))")
    }

    // MARK: - Pipeline (Race §9.10)

    /// Externer G4-Eingang (fax-nativ, mit EOFB, /EndOfBlock true):
    /// Bilevel-Race läuft, der kleinste bitidente Kandidat gewinnt (auf dem
    /// sparsamen Muster deterministisch G4), der Output rendert pixelgleich
    /// zur Quelle – und ist byteidentisch zum deterministischen Re-Encode,
    /// damit der Zweitlauf-Schutz greifen kann.
    @Test(.hangGuard) func externerG4EingangNimmtAmRaceTeil() throws {
        let input = try PDFFixtures.ccittG4ExternalPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let originalCore = try PDFCoreDocument(path: input.path)
        let originalResource = try #require(try originalCore.imageResources().first)
        let originalBytes = try #require(originalCore.imageStreamData(
            objectID: originalResource.objectID, decoded: false))

        let out = Self.tempURL("external-race")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: .smart)
        guard case .ccittG4(_, let original, let expected) =
                try #require(outcome.plan.transformedActions.first) else {
            Issue.record("Erwartete G4-Aktion (sparsames Muster), war: \(outcome.plan.actions)")
            return
        }
        #expect(original == originalBytes.count)
        #expect(expected < original,
                "Race-Ergebnis nicht kleiner: \(original) → \(expected)")
        #expect(outcome.execution.replacedImages == 1)

        let (core, resource) = try Self.firstResource(out)
        #expect(resource.terminalFilter == .ccitt)
        #expect(resource.bitsPerComponent == 1)
        let pattern = try Self.expectedSparsePattern(
            width: resource.width, height: resource.height)
        let g4 = try #require(BilevelCodec.encodeG4(pattern))
        #expect(core.imageStreamData(objectID: resource.objectID,
                                     decoded: false) == g4,
                "Output-Strom ist nicht der deterministische Re-Encode")

        // RenderDifferential bitidentisch-Gate wie BilevelPipelineTests:
        // Quelle (fax-nativ, BlackIs1-Default) und Output (unsere
        // invertierte Konvention mit BlackIs1 true) müssen pixelgleich
        // rendern – der empirische Konventionsnachweis.
        let comparison = try #require(
            RenderDifferential.compare(sourceURL: input, outputURL: out,
                                       dpi: 150).first)
        #expect(comparison.changedAreaRatio == 0,
                "Render unterscheidet sich: CAR \(comparison.changedAreaRatio)")
        #expect(comparison.inkDelta == 0)
    }

    /// G3-Eingang (K = 0, ohne EOLs): Race verwandelt ihn in den kleinsten
    /// bitidenten Kandidaten (§9.10: KEEP / G4 / JBIG2), Output rendert
    /// pixelgleich.
    @Test(.hangGuard) func g3EingangNimmtAmRaceTeil() throws {
        let input = try PDFFixtures.ccittG3InputPDF(k: 0, endOfLine: false)
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("g3-race")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: .smart)
        let action = try #require(outcome.plan.transformedActions.first)
        // Auf dem Textmuster schlägt einer der Fax/JBIG2-Kodierer den
        // G3-1D-Strom; welcher, entscheidet der Race (deterministisch).
        switch action {
        case .ccittG4, .jbig2:
            break
        default:
            Issue.record("Erwartete Bilevel-Aktion, war: \(action)")
            return
        }
        #expect((action.expectedEncodedBytes ?? 0) < action.originalEncodedBytes,
                "Race-Ergebnis ist nicht kleiner")
        #expect(outcome.execution.replacedImages == 1)

        let comparison = try #require(
            RenderDifferential.compare(sourceURL: input, outputURL: out,
                                       dpi: 150).first)
        #expect(comparison.changedAreaRatio == 0,
                "Render unterscheidet sich: CAR \(comparison.changedAreaRatio)")
        #expect(comparison.inkDelta == 0)
    }

    /// Never-Grow auf Stream-Ebene: Jede transformierte Aktion ist kleiner
    /// als der Originalstrom, und kein Bildstrom wächst. (Die Dateigrösse
    /// ganzer Mini-Fixtures unterliegt dem Struktur-Pass und ist kein
    /// Never-Grow-Vertrag.)
    @Test(.hangGuard) func neverGrow() throws {
        for fixture in [try PDFFixtures.ccittG4ExternalPDF(),
                        try PDFFixtures.ccittG3InputPDF(k: 0, endOfLine: false)] {
            defer { try? FileManager.default.removeItem(at: fixture) }
            let out = Self.tempURL("never-grow")
            defer { try? FileManager.default.removeItem(at: out) }
            let outcome = try CompressionPipeline.run(inputURL: fixture,
                                                      outputURL: out,
                                                      options: .smart)
            for action in outcome.plan.actions {
                switch action {
                case .keep:
                    continue
                default:
                    #expect((action.expectedEncodedBytes ?? 0)
                                < action.originalEncodedBytes,
                            "Aktion wäre nicht kleiner: \(action)")
                }
            }
            // Die Bildströme im Ergebnis sind nie größer als im Eingang.
            let inCore = try PDFCoreDocument(path: fixture.path)
            let outCore = try PDFCoreDocument(path: out.path)
            for resource in try outCore.imageResources() {
                guard let outBytes = outCore.imageStreamData(
                    objectID: resource.objectID, decoded: false) else { continue }
                if let inResource = try inCore.imageResources().first,
                   let inBytes = inCore.imageStreamData(
                       objectID: inResource.objectID, decoded: false),
                   inResource.width == resource.width {
                    #expect(outBytes.count <= inBytes.count,
                            "Bildstrom gewachsen: \(inBytes.count) → \(outBytes.count)")
                }
            }
        }
    }

    // MARK: - Zweitlauf-Schutz

    /// Ein eigener G4-Output (ccittG4InputPDF = exakt unsere Konvention)
    /// bleibt in einem V2-Lauf KEEP: Der byteidentische Re-Encode erkennt
    /// den eigenen Output; G4(G4(x)) wäre ohne Vorteil, und ein
    /// JBIG2-Nachschub würde den Zweitlauf iterativ machen.
    @Test(.hangGuard) func eigenerG4OutputBleibtImZweitlaufKeep() throws {
        let input = try PDFFixtures.ccittG4InputPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let originalCore = try PDFCoreDocument(path: input.path)
        let originalResource = try #require(try originalCore.imageResources().first)
        let originalBytes = try #require(originalCore.imageStreamData(
            objectID: originalResource.objectID, decoded: false))

        let out = Self.tempURL("second-pass")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: .smart)
        #expect(outcome.replacedImages == 0)
        guard case .keep(_, let reason, _) = try #require(outcome.plan.actions.first) else {
            Issue.record("Erwartete Keep-Aktion, war: \(outcome.plan.actions)")
            return
        }
        #expect(reason == .noSizeBenefit,
                "Zweitlauf-Schutz griff nicht: \(reason.explanation)")

        let (core, resource) = try Self.firstResource(out)
        #expect(resource.terminalFilter == .ccitt)
        #expect(core.imageStreamData(objectID: resource.objectID,
                                     decoded: false) == originalBytes,
                "Zweitlauf veränderte den G4-Output")
    }

    /// Echter Zweitlauf: Erstlauf über einen Naiv-Scan → G4-Output;
    /// Zweitlauf über DIESEN Output → KEEP, byteidentisch, kein
    /// iteratives Schrumpfen (kein Ping-Pong G4 ↔ JBIG2).
    @Test(.hangGuard) func zweiterDurchlaufBleibtKeep() throws {
        let input = try PDFFixtures.bilevelSparsePDF(placedPoints: 128)
        defer { try? FileManager.default.removeItem(at: input) }
        let first = Self.tempURL("pass1")
        defer { try? FileManager.default.removeItem(at: first) }
        let firstOutcome = try CompressionPipeline.run(inputURL: input,
                                                       outputURL: first,
                                                       options: .smart)
        guard case .ccittG4 = try #require(firstOutcome.plan.transformedActions.first) else {
            Issue.record("Erstlauf erwartete G4-Aktion (sparse Muster), war: \(firstOutcome.plan.actions)")
            return
        }

        let firstCore = try PDFCoreDocument(path: first.path)
        let firstResource = try #require(try firstCore.imageResources().first)
        let firstBytes = try #require(firstCore.imageStreamData(
            objectID: firstResource.objectID, decoded: false))

        let second = Self.tempURL("pass2")
        defer { try? FileManager.default.removeItem(at: second) }
        let outcome = try CompressionPipeline.run(inputURL: first, outputURL: second,
                                                  options: .smart)
        #expect(outcome.replacedImages == 0)
        guard case .keep(_, let reason, _) = try #require(outcome.plan.actions.first) else {
            Issue.record("Zweitlauf: Erwartete Keep-Aktion, war: \(outcome.plan.actions)")
            return
        }
        #expect(reason == .noSizeBenefit)

        let secondCore = try PDFCoreDocument(path: second.path)
        let secondResource = try #require(try secondCore.imageResources().first)
        #expect(secondResource.terminalFilter == .ccitt)
        #expect(secondCore.imageStreamData(objectID: secondResource.objectID,
                                           decoded: false) == firstBytes,
                "Zweitlauf schrumpfte den G4-Output iterativ")
    }
}
