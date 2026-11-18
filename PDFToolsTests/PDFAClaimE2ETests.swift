import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan E4: PDF/A-Kennzeichnung.
///
/// Befund: Eine PDF/A-Datei kam nach dem Komprimieren mit unveränderter
/// XMP-Behauptung „PDF/A-2b“ heraus, obwohl Bilder umkodiert und Strukturen
/// entfernt waren – eine Datei, die fälschlich PDF/A behauptet, ist schlechter
/// als eine ohne Kennzeichnung. Vor dem Lauf gab es keinen Hinweis.
///
/// Fehlermöglichkeiten: (1) die Erkennung übersieht die Attribut- oder die
/// Elementform; (2) die Ausgabe behält pdfaid:; (3) das Entfernen zerstört das
/// übrige XMP (Titel weg); (4) der Hinweis fehlt im Pult.
@MainActor
@Suite(.serialized) struct PDFAClaimE2ETests {

    static func xmp(elementForm: Bool) -> String {
        let pdfaid = elementForm
            ? "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"><pdfaid:part>2</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance></rdf:Description>"
            : "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" pdfaid:part=\"2\" pdfaid:conformance=\"B\"/>"
        return """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt><rdf:li xml:lang="x-default">Archivbrief</rdf:li></rdf:Alt></dc:title></rdf:Description>\
        \(pdfaid)</rdf:RDF></x:xmpmeta><?xpacket end="w"?>
        """
    }

    /// Der Brief-Scan aus dem Farbtest, mit PDF/A-XMP.
    static func archiveLetter(elementForm: Bool) throws -> URL {
        let image = try ColorInkSurvivesCompressionE2ETests.signedLetterImage()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdfa-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.featureUnsupported) }
        pdf.addDocumentMetadata(Data(xmp(elementForm: elementForm).utf8) as CFData)
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    @Test(arguments: [false, true])
    func erkennungUndEntfernen(elementForm: Bool) throws {
        let url = try Self.archiveLetter(elementForm: elementForm)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        #expect(doc.pdfaPart == 2)
        #expect(try doc.withdrawPDFAClaim())
        #expect(doc.pdfaPart == 0)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pdfa-out-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let reopened = try PDFCoreDocument(path: out.path)
        #expect(reopened.pdfaPart == 0)
        #expect(!(try reopened.withdrawPDFAClaim()), "zweites Entfernen fand noch etwas")
        let raw = String(decoding: try Data(contentsOf: out), as: UTF8.self)
        #expect(raw.contains("Archivbrief"), "übriges XMP verloren")
        #expect(!raw.contains("pdfaid:part"))
    }

    @Test func komprimierenNimmtDieBehauptungUndDasPultSagtEsVorher() async throws {
        let url = try Self.archiveLetter(elementForm: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.mode = .small
        vm.select(url)
        #expect(await PasswordUnlockE2ETests.within(5) { vm.pdfaPart == 2 }, "kein PDF/A-Hinweis im Pult")

        vm.compress()
        #expect(await PasswordUnlockE2ETests.within(180) { vm.pendingResult != nil || vm.errorMessage != nil })
        let result = try #require(vm.pendingResult, "\(vm.errorMessage ?? "")")
        defer { vm.discardPending() }
        #expect(!result.returnedOriginal)
        #expect(try PDFCoreDocument(path: result.outputURL.path).pdfaPart == 0,
                "Ausgabe behauptet weiter PDF/A")
    }
}
