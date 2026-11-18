import Testing
import Foundation
@testable import PDFTools

/// Masterplan B7: Linearisierte Eingabe bleibt linearisiert.
///
/// Befund [G]: Eine für schnelle Webanzeige linearisierte PDF kam nach dem
/// Komprimieren ohne Linearisierung heraus – still, ohne Einstellung dafür.
///
/// Fehlermöglichkeiten: (1) Linearisierung fällt weg; (2) eine nicht
/// linearisierte Eingabe wird ungefragt linearisiert.
@Suite(.serialized) struct LinearizedInputTests {

    static func linearized(_ plain: URL) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lin-\(UUID().uuidString).pdf")
        let process = Process()
        process.executableURL = Compressor.bundledQPDFURL()
        process.arguments = ["--linearize", plain.path, out.path]
        try process.run()
        process.waitUntilExit()
        return out
    }

    @Test func linearisiertBleibtLinearisiert() throws {
        let plain = try ColorInkSurvivesCompressionE2ETests.signedLetterPDF()
        defer { try? FileManager.default.removeItem(at: plain) }
        let input = try Self.linearized(plain)
        defer { try? FileManager.default.removeItem(at: input) }
        #expect(try PDFCoreDocument(path: input.path).structureProfile.isLinearized)

        for (url, expected) in [(input, true), (plain, false)] {
            let result = try Compressor().compress(inputURL: url, mode: .small)
            defer { if result.outputURL != url { try? FileManager.default.removeItem(at: result.outputURL) } }
            #expect(!result.returnedOriginal)
            #expect(try PDFCoreDocument(path: result.outputURL.path).structureProfile.isLinearized == expected,
                    "Eingabe linearisiert: \(expected)")
        }
    }

    /// Linearisieren kostet Objektströme: statab (linearisiert) wurde dadurch
    /// größer als die Quelle (30,1 → 37,3 MB) und kam als Original zurück –
    /// die Ersparnis war weg. Dann wird ohne Linearisierung geschrieben.
    @Test(.needsLocalFiles("tmp/pdfs/core-235/01_BornDigital_Text/statab_2012.pdf"))
    func linearisierungKostetNieDieErsparnis() throws {
        let url = LocalTestData.repoRoot.appendingPathComponent("tmp/pdfs/core-235/01_BornDigital_Text/statab_2012.pdf")
        #expect(try PDFCoreDocument(path: url.path).structureProfile.isLinearized)
        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { if result.outputURL != url { try? FileManager.default.removeItem(at: result.outputURL) } }
        #expect(!result.returnedOriginal, "Original zurückgegeben – Linearisierung hat die Ersparnis gekostet")
        #expect(result.outputBytes < result.inputBytes)
    }
}
