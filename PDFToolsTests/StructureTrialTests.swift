import Foundation
import Testing
@testable import PDFTools

/// Sofort-Schätzung für textlastige PDFs (2026-10-13).
///
/// Auslöser: Ein Kontoauszug ohne Bilder zeigte „bis zu 44 % kleiner" und
/// schrumpfte um 2 %. Fehlermöglichkeiten, die diese Tests festhalten:
/// (1) Der Nicht-Bild-Anteil wird geraten statt gemessen – Punktwert weit vom
///     Ergebnis.
/// (2) Das breite Bild-Band liegt auch über dem Strukturanteil – die Anzeige
///     verspricht eine Ersparnis, die ein Textdokument nicht hergibt.
/// (3) Der Struktur-Prozess bekommt keine Dateien übergeben und tut nichts.
/// (4) Der Probelauf läuft auch für bildlastige oder große Dateien und macht
///     die Vorschau langsam.
@Suite(.serialized) struct StructureTrialTests {

    @Test(.hangGuard) func textdokumentWirdNichtUeberschaetzt() throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 60, name: "structure-trial-text")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Compressor.fileSize(of: url)
        let estimate = try #require(CompressionEstimator.quickEstimate(url: url, options: .smart))
        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let actual = Double(result.outputBytes) / Double(original)
        let point = Double(estimate.pointBytes) / Double(original)
        let best = Double(estimate.lowBytes) / Double(original)
        #expect(abs(point - actual) <= 0.10,
                "Punktwert \(point) liegt weit vom Ergebnis \(actual)")
        #expect(actual - best <= 0.15,
                "Anzeige verspricht bis \(1 - best), erreicht wurden \(1 - actual); Punkt \(point), Original \(original) B, Ergebnis \(result.outputBytes) B")
    }

    @Test(.hangGuard) func strukturProzessBekommtEinUndAusgabe() throws {
        let input = try PDFFixtures.textPDF(lines: 20, name: "structure-trial-args")
        defer { try? FileManager.default.removeItem(at: input) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("structure-trial-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let qpdf = try #require(Compressor.findQPDF(), "qpdf fehlt")

        let process = Compressor.makeStructureProcess(
            qpdfPath: qpdf, input: input, output: output, linearize: false,
            compatibility: .maximum, flate: .standard)
        #expect(process.arguments?.suffix(2) == [input.path, output.path])
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0 || process.terminationStatus == 3)
        #expect(Compressor.fileSize(of: output) > 0, "Struktur-Pass hat nichts geschrieben")
    }

    @Test func probelaufNurFuerTextlastigeKleineDateien() throws {
        let url = try PDFFixtures.textPDF(lines: 20, name: "structure-trial-gate")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = Compressor.fileSize(of: url)
        // Bildlastig: Bilder tragen mehr als die Hälfte.
        #expect(StructureTrial.retention(url: url, original: size,
                                         imageBytes: size * 6 / 10,
                                         compatibility: .modern) == nil)
        // Zu groß für eine Sofort-Vorschau.
        #expect(StructureTrial.retention(url: url,
                                         original: StructureTrial.maximumFileBytes + 1,
                                         imageBytes: 0, compatibility: .modern) == nil)
        // Textlastig und klein: gemessen, nie über 1 (Never-Grow).
        let measured = try #require(StructureTrial.retention(
            url: url, original: size, imageBytes: 0, compatibility: .modern))
        #expect(measured > 0 && measured <= 1)
    }

    /// Ein winziges Deckblatt ohne Filter macht kein unkomprimiertes Dokument:
    /// Das Statistik-Jahrbuch versprach deshalb 65 % und lieferte 7 %.
    @Test func kleinerUngefilterterStreamZaehltNichtAlsUnkomprimiert() throws {
        func document(coverBytes: Int, bodyFiltered: Bool, name: String) throws -> PDFCoreDocument {
            var b = RawPDFBuilder()
            let pagesRef = b.reserveNumber()
            let cover = b.addStream(dictionary: "", data: Data(repeating: 0x20, count: coverBytes))
            let body = b.addStream(dictionary: bodyFiltered ? "/Filter/FlateDecode" : "",
                                   data: Data(repeating: 0x20, count: 8000))
            let pages = [cover, body].map {
                b.addObject("<</Type/Page/Parent \(pagesRef) 0 R/MediaBox[0 0 200 200]/Contents \($0) 0 R>>")
            }
            let kids = pages.map { "\($0) 0 R" }.joined(separator: " ")
            b.fill(pagesRef, "<</Type/Pages/Kids[\(kids)]/Count 2>>")
            let root = b.addObject("<</Type/Catalog/Pages \(pagesRef) 0 R>>")
            let url = PDFFixtures.fixtureURL(prefix: name)
            try b.build(rootObject: root).write(to: url)
            return try PDFCoreDocument(path: url.path)
        }
        #expect(try !document(coverBytes: 31, bodyFiltered: true, name: "cover-small")
            .structureProfile.hasUncompressedContent)
        #expect(try document(coverBytes: 31, bodyFiltered: false, name: "cover-plain")
            .structureProfile.hasUncompressedContent)
    }

    /// Die Vorschau rechnet das Font-Subsetting ein, aber nur, wenn es läuft.
    @Test(.hangGuard) func schriftErsparnisFolgtDerPolitik() throws {
        let url = try #require(try PDFFixtures.subsetFontPDF())
        defer { try? FileManager.default.removeItem(at: url) }
        let size = Compressor.fileSize(of: url)
        let document = try PDFCoreDocument(path: url.path)
        var options = CompressionOptions.make(mode: .smart, customConfig: nil,
                                              stripMetadata: true, linearize: false)
        options.featureFlags.candidateEngine = true
        options.featureFlags.selectiveFontSubset = true
        func savings(original: Int64, imageBytes: Int64 = 0) -> Int64 {
            StructureTrial.fontSavings(url: url, document: document, original: original,
                                       imageBytes: imageBytes, options: options)
        }
        let saved = savings(original: size)
        #expect(saved > 0)
        #expect(saved <= (try document.spaceInventory(documentBytes: size).fontProgramBytes))
        #expect(savings(original: size, imageBytes: size) == 0, "bildlastig: nicht gemessen")
        #expect(savings(original: StructureTrial.maximumFileBytes + 1) == 0, "zu groß")
        options.fontPolicy = .off
        #expect(savings(original: size) == 0, "Font-Pass aus")
    }

    /// „Eigene" muss wirken (Sorge aus der Nutzung, 2026-10-13):
    /// (5) Auflösung/Qualität ändern die Ausgabegröße eines Foto-PDFs nicht.
    /// (6) Kompatibilität „Maximal" lässt den Struktur-Schritt aus – ein
    ///     Textdokument kommt unverändert groß zurück.
    @Test(.hangGuard) func eigeneEinstellungenAendernDieGroesse() throws {
        let photo = try PDFFixtures.placedTexturedPhotoPDF(pixels: 3000)
        defer { try? FileManager.default.removeItem(at: photo) }
        let small = try Compressor().compress(
            inputURL: photo, options: CompressionPresetFactory.custom(dpi: 72, quality: 0.5))
        let large = try Compressor().compress(
            inputURL: photo, options: CompressionPresetFactory.custom(dpi: 300, quality: 0.9))
        defer {
            try? FileManager.default.removeItem(at: small.outputURL)
            try? FileManager.default.removeItem(at: large.outputURL)
        }
        #expect(small.outputBytes < large.outputBytes,
                "72 DPI/50 % (\(small.outputBytes) B) ist nicht kleiner als 300 DPI/90 % (\(large.outputBytes) B); Original \(Compressor.fileSize(of: photo)) B, unverändert zurück: \(small.returnedOriginal)/\(large.returnedOriginal)")

        let text = try PDFFixtures.vectorTextPDF(lines: 60, name: "structure-trial-compat")
        defer { try? FileManager.default.removeItem(at: text) }
        var maximal = CompressionPresetFactory.custom(dpi: 150, quality: 0.8)
        maximal.compatibilityPolicy = .maximum
        let result = try Compressor().compress(inputURL: text, options: maximal)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.outputBytes < Compressor.fileSize(of: text),
                "Kompatibilität „Maximal“ hat das Textdokument nicht verkleinert")
    }
}
