import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// OCR-Workspace: Routing + Engine-Writer-Pfad (deterministisch, ohne
/// Vision-Genauigkeitsannahmen: leere Seiten liefern null Wörter, der
/// durchsuchbare Output muss trotzdem seitenzahl- und strukturvalide sein).
@MainActor
struct OCRTests {

    @Test func busyImportAndResetPreserveSource() {
        let vm = OCRViewModel()
        let original = URL(fileURLWithPath: "/tmp/source-a.pdf")
        vm.accept([original])
        vm.isWorking = true
        vm.accept([URL(fileURLWithPath: "/tmp/source-b.pdf")])
        vm.reset()
        #expect(vm.pdfURL == original)
        #expect(vm.isWorking)
    }

    /// OCR v2 legt nur eine Textebene ins Original – keine gerasterte Kopie,
    /// also auch keine Zustimmung mehr (früher: Schalter „Gerasterte Kopie ist
    /// in Ordnung“). Der Lauf startet direkt.
    @Test func ocrStartetOhneZustimmung() async throws {
        let vm = OCRViewModel()
        vm.accept([try TestFactory.makeTempPDF(pageCount: 1)])
        vm.runOCR()
        #expect(vm.isWorking)
        vm.cancelWork()
    }

    /// Ergebnis-Suche im Fließtext (Nutzerbefund 2026-10-01, Neugestaltung
    /// 2026-10-12). Fehlermöglichkeiten: Groß/Klein und Umlaute verfehlt,
    /// mehrere Treffer je Seite verschluckt, leere Suche liefert Treffer,
    /// riesige Dokumente fluten die Liste, ein Treffer über einen
    /// OCR-Zeilenumbruch hinweg wird nicht gefunden, der Bereich zeigt nicht
    /// auf die Fundstelle im Seitentext, Treffer in der Seitenüberschrift
    /// („Seite 4") werden mitgezählt, ein Suchwechsel lässt den gewählten
    /// Treffer außerhalb der neuen Liste stehen.
    @Test func sucheFindetTrefferMitSeiteUndAusschnitt() {
        let vm = OCRViewModel()
        vm.pageResults = [
            OCREngine.PageResult(pageIndex: 0, lines: [line("Rechnung Nummer 4711", row: 0),
                                                       line("Zweite rechnung unten", row: 1)]),
            OCREngine.PageResult(pageIndex: 1, lines: [], skippedExistingText: true),
            OCREngine.PageResult(pageIndex: 2, lines: [line("Größe der Lieferung", row: 0)]),
        ]
        vm.searchQuery = ""
        #expect(vm.searchHits.isEmpty)
        vm.searchQuery = "RECHNUNG"
        #expect(vm.searchHits.map(\.pageIndex) == [0, 0])
        #expect(vm.searchHits.first?.snippet.contains("Rechnung Nummer") == true)
        let body = vm.textSections[0].body
        #expect(vm.searchHits.map(\.range) == [NSRange(location: 0, length: 8),
                                              NSRange(location: body.utf16.count - "rechnung unten".utf16.count,
                                                      length: 8)])
        vm.searchQuery = "größe"
        #expect(vm.searchHits.map(\.pageIndex) == [2])
        vm.searchQuery = "Seite"
        #expect(vm.searchHits.isEmpty)

        // Zwei OCR-Zeilen bilden einen Absatz – die Suche findet über den Umbruch.
        vm.searchQuery = "4711 Zweite"
        #expect(vm.searchHits.map(\.pageIndex) == [0])

        vm.selectedHit = 1
        vm.searchQuery = "rechnung"
        #expect(vm.selectedHit == 0)

        vm.pageResults = (0..<2000).map {
            OCREngine.PageResult(pageIndex: $0, lines: [line("Treffer \($0)", row: 0)])
        }
        vm.searchQuery = "treffer"
        #expect(vm.searchHits.count == OCRViewModel.maximumSearchHits)
        #expect(vm.searchHitTotal == 2000)
    }

    /// Textspalte: je Seite ein Abschnitt in Seitenreihenfolge; übersprungene
    /// und leere Seiten bekommen einen Hinweis statt Text. Fehlermöglichkeiten:
    /// Abschnitte in Ergebnisreihenfolge statt Seitenreihenfolge, Hinweise
    /// landen im kopierten Gesamttext, der Gesamttext trennt Seiten nicht,
    /// ein Ergebniswechsel lässt alte Abschnitte stehen.
    @Test func textabschnitteFolgenDenSeiten() {
        let vm = OCRViewModel()
        vm.pageResults = [
            OCREngine.PageResult(pageIndex: 2, lines: [line("Dritte Seite", row: 0)]),
            OCREngine.PageResult(pageIndex: 0, lines: [line("Erste Seite", row: 0)]),
            OCREngine.PageResult(pageIndex: 1, lines: [], skippedExistingText: true),
            OCREngine.PageResult(pageIndex: 3, lines: []),
        ]
        #expect(vm.textSections.map(\.pageIndex) == [0, 1, 2, 3])
        #expect(vm.textSections.map(\.title) == ["Seite 1", "Seite 2", "Seite 3", "Seite 4"])
        #expect(vm.textSections[1].note != nil && vm.textSections[1].body.isEmpty)
        #expect(vm.textSections[3].note != nil && vm.textSections[3].body.isEmpty)
        #expect(vm.fullText == "Erste Seite\n\nDritte Seite")
        vm.pageResults = []
        #expect(vm.textSections.isEmpty)
        #expect(vm.fullText.isEmpty)
    }

    /// Absatzbildung aus OCR-Zeilen (reine Funktion). Fehlermöglichkeiten:
    /// (1) Satzende mitten im Blocksatz zerreißt den Absatz, (2) kurze letzte
    /// Zeile mit Satzende wird nicht als Absatzende erkannt, (3) Leerzeile
    /// trennt nicht, (4) großer vertikaler Abstand trennt nicht, (5) normaler
    /// Zeilenabstand trennt fälschlich, (6) Trennstrich am Zeilenende bleibt
    /// als „Zusam- menhang" stehen, (7) echter Bindestrich („Nord-Süd") wird
    /// entfernt, (8) Aufzählungszeichen werden in den Vorabsatz gezogen,
    /// (9) Zellen derselben Zeile werden umgebrochen oder Tabellenzeilen
    /// fließen in den Text davor,
    /// (10) ohne Geometrie (Nullrechtecke) kommt gar kein Absatz zustande,
    /// (11) Leerzeichen-Zeilen erzeugen leere Absätze, (12) leere Eingabe.
    @Test func absaetzeAusOCRZeilen() {
        func para(_ lines: [OCREngine.Line]) -> [String] { OCRTextLayout.paragraphs(from: lines) }

        // (1)+(2)+(5): Blocksatz – Satzende in voller Zeile bleibt im Absatz,
        // kurze letzte Zeile mit Punkt beendet ihn.
        #expect(para([
            line("Der Vertrag beginnt am ersten Tag.", row: 0),
            line("Er endet nach zwölf Monaten und verlängert", row: 1),
            line("sich stillschweigend.", row: 2, width: 0.4),
            line("Die Kündigung ist schriftlich zu erklären", row: 3),
            line("und muss rechtzeitig eingehen.", row: 4, width: 0.5),
        ]) == [
            "Der Vertrag beginnt am ersten Tag. Er endet nach zwölf Monaten und verlängert sich stillschweigend.",
            "Die Kündigung ist schriftlich zu erklären und muss rechtzeitig eingehen.",
        ])

        // (3) Leerzeile, (11) Leerzeichen-Zeile.
        #expect(para([line("Eins", row: 0), line("   ", row: 1), line("Zwei", row: 2)]) == ["Eins", "Zwei"])

        // (4) großer Abstand trennt, auch ohne Satzzeichen.
        #expect(para([
            line("Betreff Rechnung", row: 0),
            line("Sehr geehrte Frau Muster", row: 2.5),
            line("wir bedanken uns für", row: 3.5),
        ]) == ["Betreff Rechnung", "Sehr geehrte Frau Muster wir bedanken uns für"])

        // (6) Silbentrennung, (7) echter Bindestrich vor Großbuchstabe.
        #expect(para([line("Der Zusam-", row: 0), line("menhang der Nord-", row: 1), line("Süd-Achse", row: 2)])
                == ["Der Zusammenhang der Nord-Süd-Achse"])

        // (8) Aufzählungen beginnen je einen Absatz.
        #expect(para([
            line("Mitbringen:", row: 0, width: 0.3),
            line("• Ausweis", row: 1, width: 0.3),
            line("- Vollmacht", row: 2, width: 0.3),
            line("1. Formular", row: 3, width: 0.3),
        ]) == ["Mitbringen:", "• Ausweis", "- Vollmacht", "1. Formular"])

        // (9) Zellen derselben Zeile bleiben eine Zeile; Tabellenzeilen
        // hängen sich nicht an den Text davor.
        #expect(para([
            line("Anbei die Einzelheiten", row: -1, width: 0.5),
            line("Rechnungsnummer", row: 0, x: 0.1, width: 0.3),
            line("4711", row: 0, x: 0.6, width: 0.2),
            line("Datum", row: 1, x: 0.1, width: 0.3),
            line("1.1.2026", row: 1, x: 0.6, width: 0.2),
        ]) == ["Anbei die Einzelheiten", "Rechnungsnummer 4711", "Datum 1.1.2026"])

        // (10) ohne Geometrie gelten nur die Textregeln.
        func flat(_ t: String) -> OCREngine.Line { OCREngine.Line(text: t, boundingBox: .zero, confidence: 1) }
        #expect(para([flat("Erster Satz. Zweiter"), flat("Satz geht weiter."), flat("Neuer Absatz beginnt"), flat("hier.")])
                == ["Erster Satz. Zweiter Satz geht weiter.", "Neuer Absatz beginnt hier."])

        // (12)
        #expect(para([]).isEmpty)
    }

    /// Regel 7 (Sichtabnahme 2026-10-12, M5): Gleich breite Zeilen, die jede
    /// ein ganzer Satz sind, bleiben Einzelzeilen – vorher flossen sie zu
    /// einem Absatz zusammen, weil keine Zeile „kurz" endete. Zwei solche
    /// Zeilen in Folge reichen nicht (Blocksatz), und eine Satzzeilenfolge
    /// zieht den Fließtext davor und danach nicht auseinander.
    @Test func satzzeilenBleibenEinzelneAbsaetze() {
        func para(_ lines: [OCREngine.Line]) -> [String] { OCRTextLayout.paragraphs(from: lines) }

        #expect(para([
            line("Line 01 - compression benchmark text, figures and tables.", row: 0),
            line("Line 02 - compression benchmark text, figures and tables.", row: 1),
            line("Line 03 - compression benchmark text, figures and tables.", row: 2),
            line("Line 04 - compression benchmark text, figures and tables.", row: 3),
        ]) == [
            "Line 01 - compression benchmark text, figures and tables.",
            "Line 02 - compression benchmark text, figures and tables.",
            "Line 03 - compression benchmark text, figures and tables.",
            "Line 04 - compression benchmark text, figures and tables.",
        ])

        // Nur zwei ganze Sätze in Folge: bleibt Fließtext.
        #expect(para([
            line("Der Vertrag beginnt am ersten Tag des Monats.", row: 0),
            line("Er endet nach zwölf Monaten ohne Kündigung.", row: 1),
            line("Die Verlängerung erfolgt stillschweigend um", row: 2),
            line("jeweils ein weiteres Jahr.", row: 3, width: 0.4),
        ]) == [
            "Der Vertrag beginnt am ersten Tag des Monats. Er endet nach zwölf Monaten ohne Kündigung. Die Verlängerung erfolgt stillschweigend um jeweils ein weiteres Jahr.",
        ])

        // Fließtext um eine Satzzeilenfolge bleibt zusammen.
        #expect(para([
            line("Bitte beachten Sie die folgenden Punkte und", row: 0),
            line("halten Sie die Unterlagen bereit.", row: 1),
            line("Der Ausweis muss gültig sein.", row: 2),
            line("Die Vollmacht muss unterschrieben sein.", row: 3),
            line("Das Formular muss vollständig sein.", row: 4),
        ]) == [
            "Bitte beachten Sie die folgenden Punkte und halten Sie die Unterlagen bereit.",
            "Der Ausweis muss gültig sein.",
            "Die Vollmacht muss unterschrieben sein.",
            "Das Formular muss vollständig sein.",
        ])
    }

    /// Zeile in einem Textblock: `row` zählt Zeilen von oben (Zeilenabstand
    /// 0,03 Seitenhöhen, Boxhöhe 0,022), `width` den Anteil der Blockbreite 0,8.
    private func line(_ text: String, row: Double, x: Double = 0.1, width: Double = 0.8) -> OCREngine.Line {
        let pitch = 0.03, height = 0.022
        return OCREngine.Line(text: text,
                              boundingBox: CGRect(x: x, y: 0.9 - row * pitch, width: width, height: height),
                              confidence: 1)
    }

    @Test func pdfInputRoutesToReady() async throws {
        let vm = OCRViewModel()
        let url = try TestFactory.makeTempPDF(pageCount: 2)

        vm.accept([url])
        #expect(vm.stage == .ready)
        #expect(vm.pdfURL == url)
        #expect(vm.hasSource)
    }

    @Test func imageInputPointsToConvert() throws {
        let vm = OCRViewModel()
        let png = try TestFactory.makeTempPNG()

        vm.accept([png])
        #expect(vm.stage == .choose)
        #expect(!vm.hasSource)
        #expect(vm.errorMessage?.contains("Konvertieren") == true)
    }

    @Test func mixedInputPointsToOrganize() async throws {
        let vm = OCRViewModel()
        let pdf = try TestFactory.makeTempPDF(pageCount: 1)
        let png = try TestFactory.makeTempPNG()

        vm.accept([png, pdf])
        #expect(vm.stage == .choose)
        #expect(!vm.hasSource)
        #expect(vm.errorMessage?.contains("Organisieren") == true)
    }

    @Test func unsupportedFilesShowError() {
        let vm = OCRViewModel()
        let txt = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-x-\(UUID().uuidString).txt")
        try? "hi".write(to: txt, atomically: true, encoding: .utf8)

        vm.accept([txt])
        #expect(vm.stage == .choose)
        #expect(vm.errorMessage != nil)
    }

    @Test func resetClearsEverything() async throws {
        let vm = OCRViewModel()
        vm.accept([try TestFactory.makeTempPDF(pageCount: 1)])
        #expect(vm.hasSource)

        vm.reset()
        #expect(!vm.hasSource)
        #expect(vm.stage == .choose)
        #expect(vm.errorMessage == nil)
    }

    @Test func languagePresetsMapCorrectly() {
        #expect(OCREngine.OCRLanguagePreset.germanEnglish.recognitionLanguages
            == ["de-DE", "en-US"])
        #expect(OCREngine.OCRLanguagePreset.german.recognitionLanguages == ["de-DE"])
        #expect(OCREngine.OCRLanguagePreset.english.recognitionLanguages == ["en-US"])
    }

    /// Leere Seiten: keine Wörter, aber valider Output mit gleicher Seitenzahl
    /// (Writer-Pfad + qpdf-Strukturprüfung, unabhängig von Vision-Treffern).
    @Test func blankPDFProducesValidSearchableOutput() async throws {
        let url = try TestFactory.makeTempPDF(pageCount: 2)
        let output = try await OCREngine.run(
            sourceURL: url, languages: ["de-DE", "en-US"]) { _ in }
        defer { try? FileManager.default.removeItem(at: output.outputURL) }

        #expect(output.pages.count == 2)
        #expect(output.totalWords == 0)
        #expect(output.meanConfidence == nil)

        let doc = try #require(PDFDocument(url: output.outputURL))
        #expect(doc.pageCount == 2)

        let report = PDFValidator.validate(
            outputURL: output.outputURL,
            policy: .pageOperation(expectedPageCount: 2))
        #expect(report.isValid)
    }
}
