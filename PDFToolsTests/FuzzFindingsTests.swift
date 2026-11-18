import Testing
import Foundation
@testable import PDFTools

/// Masterplan D5: Funde des Fuzz-Laufs (Scripts/fuzz-corpus.sh) als
/// Regressionstests. Die Dateien liegen unter tmp/fuzz-findings/ (nicht im
/// Repo – sie sind Mutationen urheberrechtlich geschützter Korpusdateien).
///
/// hang-2156: Eine mutierte Seite lässt PDFKits Textextraktion
/// (`PDFPage.string`, Textlayout in CoreGraphics) nicht mehr zurückkehren –
/// der Lauf hing > 300 s in der Validierung.
///
/// Fehlermöglichkeiten: (1) der Lauf hängt; (2) eine nicht prüfbare Ausgabe
/// wird ausgeliefert statt des Originals.
@Suite(.serialized) struct FuzzFindingsTests {

    @Test(.timeLimit(.minutes(3)), .needsLocalFiles("tmp/fuzz-findings/hang-2156.pdf"))
    func textlayoutHaengerEndetMitDemOriginal() throws {
        let url = LocalTestData.repoRoot.appendingPathComponent("tmp/fuzz-findings/hang-2156.pdf")
        let start = Date()
        // Erwartet: der Lauf endet zügig – mit dem Original oder mit der
        // benannten Ablehnung („Text von Seite … nicht lesbar“), nie mit einer
        // ungeprüften Ausgabe.
        do {
            let result = try Compressor().compress(inputURL: url, mode: .smart)
            defer { if result.outputURL != url { try? FileManager.default.removeItem(at: result.outputURL) } }
            #expect(result.returnedOriginal, "nicht prüfbare Ausgabe ausgeliefert")
        } catch {
            #expect("\(error)".contains("in angemessener Zeit"), "\(error)")
        }
        // Release: 20 s (gemessen 18.11., --bench). Der Test läuft im
        // Debug-Build, der hier rund fünfmal langsamer rechnet; vorher hing
        // derselbe Lauf auch im Release über 300 s.
        #expect(Date().timeIntervalSince(start) < 150, "Dauer \(Date().timeIntervalSince(start)) s")
    }
}
