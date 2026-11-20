import XCTest
import AppKit
import PDFKit

/// Masterplan G3 – die Oberfläche automatisch testen.
///
/// Sechs Abläufe durch die echte App. Dateien kommen über `--open <pfad>`
/// (und `--tool <werkzeug>`) hinein, damit kein Dateidialog nötig ist. Jeder
/// Ablauf legt Bildschirmfotos als Anhang ins Testergebnis (.xcresult) –
/// das prüfbare Artefakt (AGENTS.md).
///
/// Die App läuft deutsch (`-AppleLanguages (de)`), die Abläufe suchen
/// Bedienelemente über ihre sichtbaren Titel.
///
/// Fehlermöglichkeiten je Ablauf stehen am Test.
final class PDFdownsizeFlowsUITests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Hilfen

    private func launch(tool: String? = nil, open files: [URL]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        if let tool { app.launchArguments += ["--tool", tool] }
        if !files.isEmpty { app.launchArguments += ["--open"] + files.map(\.path) }
        app.launch()
        return app
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Eine Seite als Bild (Scan-artig) mit Text – komprimierbar und für OCR.
    private func scanPDF(_ name: String, text: String = "Rechnung Nummer 4711") throws -> URL {
        let w = 1700, h = 2200
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        for line in 0..<12 {
            let attributed = NSAttributedString(string: "\(text) – Zeile \(line + 1)",
                                                attributes: [.font: font, .foregroundColor: NSColor.black])
            ctx.textPosition = CGPoint(x: 120, y: h - 220 - line * 140)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        let url = workDir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        pdf.draw(ctx.makeImage()!, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    private func textPDF(_ name: String, pages: Int) throws -> URL {
        let doc = PDFDocument()
        for n in 0..<pages {
            let page = PDFPage()
            let annotation = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 400, height: 60),
                                           forType: .freeText, withProperties: nil)
            annotation.contents = "\(name) Seite \(n + 1)"
            page.addAnnotation(annotation)
            doc.insert(page, at: doc.pageCount)
        }
        let url = workDir.appendingPathComponent(name)
        XCTAssertTrue(doc.write(to: url))
        return url
    }

    private func lockedPDF(_ name: String) throws -> URL {
        let plain = try scanPDF("plain-\(name)")
        let url = workDir.appendingPathComponent(name)
        let doc = try XCTUnwrap(PDFDocument(url: plain))
        XCTAssertTrue(doc.write(to: url, withOptions: [.userPasswordOption: "geheim", .ownerPasswordOption: "besitzer"]))
        return url
    }

    private func saveThroughPanel(_ app: XCUIApplication, in folder: URL? = nil) {
        let panel = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "kein Sichern-Dialog")
        if let folder {
            app.typeKey("g", modifierFlags: [.command, .shift])
            app.typeText(folder.path + "\n")
        }
        app.typeKey(.return, modifierFlags: [])
    }

    // MARK: - 1. PDF öffnen → Smart → Ergebnis → Sichern
    //
    // Fehler: (1) kein Ergebnis; (2) Sichern legt keine Datei an.
    func testEinzeldateiKomprimierenUndSichern() throws {
        let input = try scanPDF("brief.pdf")
        let app = launch(tool: "compress", open: [input])
        let compress = app.buttons["Komprimieren"]
        XCTAssertTrue(compress.waitForExistence(timeout: 20))
        snapshot(app, "1-geladen")
        compress.click()
        let save = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sichern'")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 180), "kein Ergebnis")
        snapshot(app, "1-ergebnis")
        app.typeKey("s", modifierFlags: .command)
        saveThroughPanel(app)
        let saved = workDir.appendingPathComponent("brief_smart.pdf")
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: saved.path), Date() < deadline { usleep(200_000) }
        snapshot(app, "1-gesichert")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? []
        XCTAssertTrue(names.contains { $0.hasPrefix("brief_") && $0 != "brief.pdf" }, "nicht gesichert: \(names)")
    }

    // MARK: - 2. Kaputte, leere, gesperrte Datei → benannter Zustand (B1)
    //
    // Fehler: Endlos-Spinner oder roher Fehlertext statt des benannten Zustands.
    func testAbgelehnteDateienZeigenIhrenGrund() throws {
        let broken = workDir.appendingPathComponent("kaputt.pdf")
        try Data("%PDF-1.7 kein PDF".utf8).write(to: broken)
        let empty = workDir.appendingPathComponent("leer.pdf")
        try Data().write(to: empty)
        let locked = try lockedPDF("gesperrt.pdf")
        for (file, title) in [(broken, "Diese Datei ist keine lesbare PDF."),
                              (empty, "Diese PDF ist leer."),
                              (locked, "Diese PDF ist passwortgeschützt.")] {
            let app = launch(tool: "compress", open: [file])
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 20), "\(file.lastPathComponent): \(title) fehlt")
            snapshot(app, "2-\(file.lastPathComponent)")
            app.terminate()
        }
    }

    // MARK: - 3. Stapel mit 6 Dateien, 2 kaputt → Alle sichern (B4)
    //
    // Fehler: (1) der Stapel bricht an der kaputten Datei ab; (2) „Alle
    // sichern“ legt nicht vier Dateien an; (3) N14/B4-Abnahme: Eine vorher
    // einzeln gesicherte Datei wird nicht noch einmal als „_2“ geschrieben.
    func testStapelMitKaputtenDateienSichertDieGuten() throws {
        var files = try (1...4).map { try scanPDF("gut-\($0).pdf") }
        let broken = workDir.appendingPathComponent("kaputt.pdf")
        try Data("kein pdf".utf8).write(to: broken)
        let empty = workDir.appendingPathComponent("leer.pdf")
        try Data().write(to: empty)
        files += [broken, empty]
        let out = workDir.appendingPathComponent("ausgabe", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let app = launch(tool: "compress", open: files)
        let all = app.buttons["Alle komprimieren"]
        XCTAssertTrue(all.waitForExistence(timeout: 20))
        snapshot(app, "3-stapel")
        all.click()
        let saveAll = app.buttons["Alle sichern …"]
        XCTAssertTrue(saveAll.waitForExistence(timeout: 300), "Stapel nicht fertig")
        snapshot(app, "3-fertig")

        // Eine Datei einzeln sichern (Zeilenknopf), in denselben Ordner.
        let single = app.buttons.matching(NSPredicate(format: "label == 'Sichern …'")).firstMatch
        XCTAssertTrue(single.waitForExistence(timeout: 10), "kein Zeilen-Sichern")
        single.click()
        saveThroughPanel(app, in: out)
        XCTAssertTrue(waitFor(20) {
            ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).count == 1
        }, "Einzel-Sichern legte keine Datei an")
        snapshot(app, "3-einzeln-gesichert")

        saveAll.click()
        let panel = app.dialogs.firstMatch.exists ? app.dialogs.firstMatch : app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(out.path + "\n")
        app.buttons["Hier sichern"].click()
        let deadline = Date().addingTimeInterval(20)
        var saved: [String] = []
        repeat {
            saved = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).filter { $0.hasSuffix(".pdf") }
            if saved.count >= 4 { break }
            usleep(300_000)
        } while Date() < deadline
        snapshot(app, "3-gesichert")
        XCTAssertEqual(saved.count, 4, "\(saved)")
        XCTAssertFalse(saved.contains { $0.contains("_2") }, "Schon Gesichertes doppelt geschrieben: \(saved)")
    }

    // MARK: - 4. Organisieren: zwei Quellen, Seite löschen, drehen, Undo, PDF erstellen
    //
    // Fehler: (1) Löschen/Drehen wirkt nicht; (2) ⌘Z nimmt mehr oder weniger
    // zurück; (3) „PDF erstellen“ liefert kein Ergebnis; (4) N14/G3: das
    // gesicherte Ergebnis hat nicht die Seiten und Drehung der Ansicht.
    func testOrganisierenBearbeitenUndErstellen() throws {
        let a = try textPDF("a.pdf", pages: 2)
        let b = try textPDF("b.pdf", pages: 2)
        let app = launch(tool: "organize", open: [a, b])
        let create = app.buttons["PDF erstellen"]
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Seite '"))
        XCTAssertTrue(tiles.element(boundBy: 3).waitForExistence(timeout: 10))
        XCTAssertEqual(tiles.count, 4)
        snapshot(app, "4-zwei-quellen")

        tiles.element(boundBy: 1).click()
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitFor { tiles.count == 3 }, "Löschen wirkte nicht")
        tiles.element(boundBy: 0).click()
        app.typeKey("r", modifierFlags: .command)
        snapshot(app, "4-geloescht-gedreht")
        app.typeKey("z", modifierFlags: .command)   // Drehen zurück
        app.typeKey("z", modifierFlags: .command)   // Löschen zurück
        XCTAssertTrue(waitFor { tiles.count == 4 }, "Undo stellte die Seite nicht wieder her")
        snapshot(app, "4-undo")

        // Jetzt endgültig: Seite 2 löschen, Seite 1 drehen, nur das Drehen
        // einmal zurück und erneut – ⌘Z darf genau einen Schritt nehmen.
        tiles.element(boundBy: 1).click()
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitFor { tiles.count == 3 })
        tiles.element(boundBy: 0).click()
        app.typeKey("r", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)   // nur das Drehen zurück
        XCTAssertTrue(waitFor { tiles.count == 3 }, "⌘Z nahm auch das Löschen zurück")
        app.typeKey("r", modifierFlags: .command)

        create.click()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sichern'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 60), "kein Ergebnis")
        snapshot(app, "4-ergebnis")
        let out = workDir.appendingPathComponent("organisiert", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        result.click()
        saveThroughPanel(app, in: out)
        var saved: URL?
        XCTAssertTrue(waitFor(20) {
            saved = ((try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [])
                .first { $0.pathExtension == "pdf" }
            return saved != nil
        }, "Ergebnis nicht gesichert")
        let doc = try XCTUnwrap(saved.flatMap { PDFDocument(url: $0) })
        XCTAssertEqual(doc.pageCount, 3, "Seitenzahl des Ergebnisses")
        XCTAssertEqual(doc.page(at: 0)?.rotation, 90, "Drehung fehlt im Ergebnis")
        XCTAssertEqual(doc.page(at: 1)?.rotation, 0)
        XCTAssertEqual(doc.page(at: 1)?.annotations.first?.contents, "b.pdf Seite 1",
                       "Falsche Seite gelöscht")
    }

    // MARK: - 5. OCR auf Scan → durchsuchbare PDF sichern
    //
    // Fehler: (1) keine Erkennung; (2) die gesicherte PDF hat keinen Text.
    func testOCRMachtDenScanDurchsuchbar() throws {
        let scan = try scanPDF("scan.pdf")
        let app = launch(tool: "ocr", open: [scan])
        let run = app.buttons["Text erkennen"]
        XCTAssertTrue(run.waitForExistence(timeout: 30))
        snapshot(app, "5-scan")
        run.click()
        let save = app.buttons["Durchsuchbare PDF sichern …"]
        XCTAssertTrue(save.waitForExistence(timeout: 240), "keine Erkennung")
        snapshot(app, "5-erkannt")
        save.click()
        saveThroughPanel(app)
        let deadline = Date().addingTimeInterval(15)
        var saved: URL?
        repeat {
            saved = ((try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? [])
                .first { $0.lastPathComponent.contains("durchsuchbar") }
            if saved != nil { break }
            usleep(300_000)
        } while Date() < deadline
        let url = try XCTUnwrap(saved, "nicht gesichert")
        XCTAssertTrue((PDFDocument(url: url)?.page(at: 0)?.string ?? "").contains("4711"), "keine Textebene")
    }

    // MARK: - 6. Ungesichertes Ergebnis → ⌘Q → Rückfrage (B3)
    //
    // Fehler: Die App beendet sich ohne Rückfrage und das Ergebnis ist weg.
    func testBeendenMitUngesichertemErgebnisFragtNach() throws {
        let input = try scanPDF("brief.pdf")
        let app = launch(tool: "compress", open: [input])
        let compress = app.buttons["Komprimieren"]
        XCTAssertTrue(compress.waitForExistence(timeout: 20))
        compress.click()
        let save = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sichern'")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 180))
        app.typeKey("q", modifierFlags: .command)
        let question = app.staticTexts["Nicht gesichertes Ergebnis verwerfen und beenden?"]
        XCTAssertTrue(question.waitForExistence(timeout: 10), "keine Rückfrage")
        snapshot(app, "6-rueckfrage")
        app.buttons["Abbrechen"].click()
        XCTAssertEqual(app.state, .runningForeground, "App hat sich trotzdem beendet")
    }

    private func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }
}
