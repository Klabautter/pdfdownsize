import Testing
import Foundation
@testable import PDFTools

/// Schnellschätzung, Scan-Seiten (2026-10-01): Eine Vollseiten-Bildregel
/// allein traf auch Vollseitenfotos (Fotoklasse im Band 96 % → 24 %). Das
/// unterscheidende Signal: Eine Scan-Seite zeigt keinen EIGENEN sichtbaren
/// Text (höchstens unsichtbaren OCR-Text, Render-Modus 3). Isoliert getestet,
/// weil die Parser-Randfälle im E2E-Korpus nicht gezielt vorkommen.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Unsichtbarer OCR-Text (3 Tr) gilt als sichtbar – Scans werden verfehlt.
///  2. Sichtbarer Text wird übersehen – Fotoseiten gelten als Scan.
///  3. „Tj“ INNERHALB eines Strings oder Namens täuscht Text vor.
///  4. Binärdaten eines Inline-Bildes (BI … ID … EI) täuschen Text vor.
///  5. Render-Modus wird über q/Q bzw. BT/ET falsch weitergetragen.
@Suite struct VisibleTextScannerTests {

    private func visible(_ content: String) -> Bool {
        VisibleTextScanner.hasVisibleText(Array(content.utf8))
    }

    @Test func reinesBildOhneText() {
        #expect(!visible("q 612 0 0 792 0 0 cm /Im0 Do Q"))
    }

    @Test func unsichtbarerOCRText() {   // 1
        #expect(!visible("q 612 0 0 792 0 0 cm /Im0 Do Q BT 3 Tr /F1 10 Tf 72 700 Td (Hallo) Tj ET"))
        #expect(!visible("BT 3 Tr [(Hal) 20 (lo)] TJ ET"))
    }

    @Test func sichtbarerText() {   // 2
        #expect(visible("BT /F1 10 Tf 72 700 Td (Bildunterschrift) Tj ET"))
        #expect(visible("BT 0 Tr [(A) -20 (B)] TJ ET"))
        #expect(visible("BT /F1 10 Tf (x) ' ET"))
        #expect(visible("BT /F1 10 Tf 1 2 (x) \" ET"))
    }

    @Test func operatorenInStringsUndNamenZaehlenNicht() {   // 3
        #expect(!visible("q /Tj Do Q"))
        #expect(!visible("BT 3 Tr (Text mit Tj und \\) Klammer \\( TJ) Tj ET"))
        #expect(!visible("BT 3 Tr <54 6a> Tj ET"))
    }

    @Test func inlineBildBinaerdaten() {   // 4
        #expect(!visible("BI /W 4 /H 1 /BPC 8 /CS /G ID (Tj) Tj EI Q"))
    }

    @Test func renderModusFolgtDemZustand() {   // 5
        // Tr gilt bis zur nächsten Änderung bzw. bis Q den Zustand zurücksetzt.
        #expect(visible("q BT 3 Tr ET Q BT (sichtbar) Tj ET"))
        #expect(!visible("BT 3 Tr (a) Tj ET BT (b) Tj ET"),
                "Tr gehört zum Grafikzustand und überdauert ET")
        #expect(visible("BT 3 Tr (a) Tj 0 Tr (b) Tj ET"))
    }
}
