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
}
