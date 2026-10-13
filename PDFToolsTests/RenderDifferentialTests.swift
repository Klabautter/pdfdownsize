import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Regressionstests des Render-Diffs – des zentralen Regressionswerkzeugs.
///
/// Anlass waren zwei Fehler, die der Golden-Korpus aufgedeckt hat:
///
/// 1. `renderTransformed` drehte die Quelle um `srcPage.rotation +
///    sourceRotationDegrees`. PDFKit wendet `/Rotate` beim Rendern aber
///    bereits an – jede Seite mit Eigenrotation wurde also 90° zu weit
///    gedreht und meldete eine Regression, die es nicht gab.
///
/// 2. Der Tinten-Delta wurde überall gewertet. Er ist auf Textseiten ein
///    guter Inhaltsindikator, auf vollflächig bebilderten Seiten dagegen
///    Farbrauschen: Dort liegt viel Fläche nahe der Dunkelschwelle.
///
/// Ein Werkzeug, das Fehlalarme produziert, verdeckt echte Fehler – deshalb
/// stehen hier zu jeder Korrektur die Gegenproben.
@Suite struct RenderDifferentialTests {

    // MARK: - Eigenrotation der Seite

    /// Eine Seite mit `/Rotate 90` ist mit sich selbst identisch.
    @Test(arguments: [0, 90, 180, 270])
    func pageWithOwnRotationComparesEqualToItself(rotation: Int) throws {
        let url = try PDFFixtures.rotatedContentPDF(rotation: rotation)
        defer { try? FileManager.default.removeItem(at: url) }

        let diffs = try RenderDifferential.compare(sourceURL: url, outputURL: url)
        let page = try #require(diffs.first)

        let message = "Seite mit /Rotate \(rotation) ist nicht mit sich selbst "
            + "identisch (SSIM \(page.ssim))"
        #expect(page.ssim > 0.99, "\(message)")
        #expect(page.changedAreaRatio < 0.02,
                "CAR \(page.changedAreaRatio) bei identischer Datei")
    }

    /// Gegenprobe: Eine tatsächlich falsch gedrehte Ausgabe MUSS auffallen.
    /// Sonst hätte die Korrektur die Rotationsprüfung stillgelegt.
    ///
    /// Geprüft wird gegen die Schwellen, die der Corpus-Gate WIRKLICH benutzt
    /// (SSIM < 0.95 oder CAR > 0.30 bei unrotierter Erwartung) – nicht gegen
    /// selbst gewählte Zahlen. Ein Test, der strenger misst als das Gate,
    /// sagt nichts darüber aus, ob das Gate greift.
    @Test(arguments: [90, 180, 270])
    func actuallyWrongRotationIsStillDetected(rotation: Int) throws {
        let source = try PDFFixtures.rotatedContentPDF(rotation: 0)
        let rotated = try PDFFixtures.rotatedContentPDF(rotation: rotation)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: rotated)
        }

        let diffs = try RenderDifferential.compare(sourceURL: source, outputURL: rotated)
        let page = try #require(diffs.first)
        let caughtByGate = page.ssim < 0.95 || page.changedAreaRatio > 0.30
        let message = "\(rotation)°-Fehldrehung fällt nicht unter die Gate-Schwellen "
            + "(CAR \(page.changedAreaRatio), SSIM \(page.ssim))"
        #expect(caughtByGate, "\(message)")
    }

    /// Je mehr Inhalt eine Seite trägt, desto deutlicher schlägt eine
    /// Fehldrehung aus. Dieser Fall dokumentiert die Empfindlichkeit an
    /// einer dicht gefüllten Seite.
    @Test func wrongRotationOnDensePageIsUnmistakable() throws {
        let source = try PDFFixtures.densePagePDF(rotation: 0)
        let rotated = try PDFFixtures.densePagePDF(rotation: 90)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: rotated)
        }

        let diffs = try RenderDifferential.compare(sourceURL: source, outputURL: rotated)
        let page = try #require(diffs.first)
        let message = "Fehldrehung auf dichter Seite zu schwach "
            + "(CAR \(page.changedAreaRatio), SSIM \(page.ssim))"
        #expect(page.changedAreaRatio > 0.30, "\(message)")
    }

    /// Die Operations-Drehung wird weiterhin korrekt verrechnet: Quelle 0°,
    /// Ausgabe 90°, erwartete Drehung 90° → kein Unterschied.
    @Test func expectedOperationRotationIsAccountedFor() throws {
        let source = try PDFFixtures.rotatedContentPDF(rotation: 0)
        let rotated = try PDFFixtures.rotatedContentPDF(rotation: 90)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: rotated)
        }

        let diffs = try RenderDifferential.compare(
            sourceURL: source, outputURL: rotated, sourceRotationDegrees: 90)
        let page = try #require(diffs.first)
        #expect(page.ssim > 0.95,
                "Erwartete 90°-Drehung wurde nicht verrechnet (SSIM \(page.ssim))")
    }

    // MARK: - Tinten-Delta

    /// Eine vollflächig bebilderte Seite ist nicht text-artig – dort trägt
    /// der Tinten-Delta keine Aussage.
    @Test func imageHeavyPageIsNotTreatedAsTextLike() throws {
        let url = try PDFFixtures.sharedImageObjectPDF(pixels: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        let diffs = try RenderDifferential.compare(sourceURL: url, outputURL: url)
        let page = try #require(diffs.first)
        let message = "Vollflächiges Bild wurde als text-artig eingestuft "
            + "(Abdeckung \(page.sourceInkCoverage))"
        #expect(!page.inkDeltaIsMeaningful, "\(message)")
    }

    /// Gegenprobe: Eine Textseite IST text-artig – dort muss der Delta zählen.
    @Test func textPageIsTreatedAsTextLike() throws {
        let url = try PDFFixtures.rawMultiParagraphPDF(pages: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let diffs = try RenderDifferential.compare(sourceURL: url, outputURL: url)
        let page = try #require(diffs.first)
        let message = "Textseite gilt nicht als text-artig "
            + "(Abdeckung \(page.sourceInkCoverage))"
        #expect(page.inkDeltaIsMeaningful, "\(message)")
        #expect(page.sourceInkCoverage < RenderDifferential.textLikeInkCoverage)
    }

    /// Der eigentliche Zweck des Tinten-Deltas: Textverlust auf einer
    /// Textseite muss ihn deutlich bewegen.
    @Test func lostTextMovesTheInkDelta() throws {
        let full = try PDFFixtures.rawMultiParagraphPDF(pages: 1)
        let empty = try PDFFixtures.blankPagePDF()
        defer {
            try? FileManager.default.removeItem(at: full)
            try? FileManager.default.removeItem(at: empty)
        }

        let diffs = try RenderDifferential.compare(sourceURL: full, outputURL: empty)
        let page = try #require(diffs.first)
        #expect(page.inkDeltaIsMeaningful, "Quelle nicht als text-artig erkannt")
        let message = "Kompletter Textverlust bewegt den Tinten-Delta nicht "
            + "(\(page.inkDelta))"
        #expect(page.inkDelta > 0.02, "\(message)")
    }

    // MARK: - Grundfälle

    @Test func identicalDocumentsShowNoDifference() throws {
        let url = try PDFFixtures.rawMultiParagraphPDF(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let diffs = try RenderDifferential.compare(sourceURL: url, outputURL: url)
        #expect(diffs.count == 2)
        for page in diffs {
            #expect(page.ssim > 0.999)
            #expect(page.changedAreaRatio < 0.001)
            #expect(page.inkDelta < 0.001)
        }
    }

    /// Fehlender Bildinhalt muss auffallen – der ursprüngliche Zweck der Metrik.
    @Test func missingImageIsDetected() throws {
        let withImage = try PDFFixtures.placedPhotoPDF(pixels: 600, placedPoints: 400)
        let blank = try PDFFixtures.blankPagePDF()
        defer {
            try? FileManager.default.removeItem(at: withImage)
            try? FileManager.default.removeItem(at: blank)
        }

        let diffs = try RenderDifferential.compare(sourceURL: withImage, outputURL: blank)
        let page = try #require(diffs.first)
        #expect(page.changedAreaRatio > 0.15,
                "Fehlendes Bild blieb unbemerkt (CAR \(page.changedAreaRatio))")
        #expect(page.ssim < 0.95)
    }

    // MARK: - Gemischte Seitenformate (NIST-Regression)

    /// Ein Dokument, dessen Seiten unterschiedliche Formate haben – A4
    /// zwischen Letter-Seiten, wie es in echten Handbüchern vorkommt.
    static func makeMixedFormatDocument() throws -> URL {
        var builder = RawPDFBuilder()
        let catalog = builder.reserveNumber()
        let pagesNode = builder.reserveNumber()
        let font = builder.addObject(
            "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        var pageIDs: [Int] = []

        // Textzeilen – ein Subpixel-Versatz schlägt auf Text am stärksten
        // durch; genau daran ist der Fehler im Korpuslauf aufgetreten.
        for index in 0..<3 {
            let mediaBox = index == 1 ? "[0 0 595.56 842.04]" : "[0 0 612 792]"
            var text = "BT /F1 11 Tf "
            for line in 0..<40 {
                text += "1 0 0 1 60 \(700 - line * 16) Tm "
                    + "(Zeile \(line) auf Seite \(index) – Messtext) Tj "
            }
            text += "ET"
            let stream = builder.addObject(
                "<</Length \(text.utf8.count)>>\nstream\n\(text)\nendstream")
            pageIDs.append(builder.addPage(
                parent: pagesNode, mediaBox: mediaBox,
                resources: "<</Font<</F1 \(font) 0 R>>>>", contents: stream))
        }

        builder.fill(pagesNode, "<</Type/Pages/Count \(pageIDs.count)/Kids ["
            + pageIDs.map { "\($0) 0 R" }.joined(separator: " ") + "]>>")
        builder.fill(catalog, "<</Type/Catalog/Pages \(pagesNode) 0 R>>")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-mixed-\(UUID().uuidString).pdf")
        try builder.build(rootObject: catalog).write(to: url)
        return url
    }

    /// Eine unveränderte Seite muss deckungsgleich messen – auch wenn sie ein
    /// anderes Format hat als ihre Nachbarn und an einer anderen Position
    /// steht.
    ///
    /// Vorher schlug genau das fehl: Die Rückrechnung der Quellgröße aus den
    /// gerundeten Pixelmaßen fiel um ein Pixel kleiner aus, die Quelle nahm
    /// dadurch einen zweiten Resampling-Schritt mit Zentrierungsversatz, und
    /// der Vergleich meldete CAR 0.0965 / SSIM 0.9012 an einem Dokument, das
    /// korrekt assembliert war.
    @Test func mixedPageFormatsCompareAsIdentical() throws {
        let source = try Self.makeMixedFormatDocument()
        defer { try? FileManager.default.removeItem(at: source) }

        // Seitenreihenfolge umkehren: [0,1,2] → [2,1,0]. Die A4-Seite bleibt
        // in der Mitte, die Letter-Seiten tauschen die Plätze – so wird jede
        // Seite an einer anderen Position als in der Quelle verglichen.
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-mixed-out-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        let document = try #require(PDFDocument(url: source))
        let reordered = PDFDocument()
        for index in (0..<document.pageCount).reversed() {
            let page = try #require(document.page(at: index)?.copy() as? PDFPage)
            reordered.insert(page, at: reordered.pageCount)
        }
        #expect(reordered.write(to: output))

        let mapping = Dictionary(uniqueKeysWithValues:
            (0..<document.pageCount).map { ($0, document.pageCount - 1 - $0) })
        let diffs = try RenderDifferential.compare(
            sourceURL: source, outputURL: output, pageMapping: mapping)

        #expect(diffs.count == document.pageCount)
        for diff in diffs {
            #expect(diff.changedAreaRatio < 0.01, """
                Seite \(diff.outputPageIndex) ← \(diff.sourcePageIndex): \
                CAR \(String(format: "%.4f", diff.changedAreaRatio)) – eine \
                unveränderte Seite darf nicht als geändert gemessen werden.
                """)
            #expect(diff.ssim > 0.99, """
                Seite \(diff.outputPageIndex) ← \(diff.sourcePageIndex): \
                SSIM \(String(format: "%.4f", diff.ssim))
                """)
        }
    }

    /// Gegenprobe: Ein ECHTER Formatunterschied muss weiterhin auffallen.
    /// Ohne diesen Nachweis könnte der Fix oben schlicht die Empfindlichkeit
    /// beseitigt haben, statt die Rundung zu korrigieren.
    @Test func genuineFormatMismatchIsStillDetected() throws {
        let source = try Self.makeMixedFormatDocument()
        defer { try? FileManager.default.removeItem(at: source) }

        // A4-Seite (Index 1) gegen Letter-Seite (Index 0) vergleichen –
        // verschiedene Seiten UND verschiedene Formate.
        let diffs = try RenderDifferential.compare(
            sourceURL: source, outputURL: source, pageMapping: [0: 1])
        let diff = try #require(diffs.first)
        #expect(diff.changedAreaRatio > 0.02, """
            Ein echter Seiten-/Formatunterschied wird nicht mehr erkannt \
            (CAR \(String(format: "%.4f", diff.changedAreaRatio))).
            """)
    }

    // MARK: - Drehung bei gemischter Ausrichtung (f3800-Regression)

    /// Dokument mit gemischter Ausrichtung: Hoch- und Querformat gemischt,
    /// wie in mehrseitigen Formularen üblich – und mit Text, weil sich
    /// Rasterungsunterschiede dort am stärksten zeigen.
    static func makeMixedOrientationDocument() throws -> URL {
        var builder = RawPDFBuilder()
        let catalog = builder.reserveNumber()
        let pagesNode = builder.reserveNumber()
        let font = builder.addObject(
            "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        var pageIDs: [Int] = []

        for index in 0..<4 {
            let landscape = index >= 2
            let mediaBox = landscape ? "[0 0 792 612]" : "[0 0 612 792]"
            var text = "BT /F1 10 Tf "
            for line in 0..<30 {
                text += "1 0 0 1 50 \(540 - line * 17) Tm "
                    + "(Seite \(index) Zeile \(line) – Drehungsmesstext) Tj "
            }
            text += "ET"
            let stream = builder.addObject(
                "<</Length \(text.utf8.count)>>\nstream\n\(text)\nendstream")
            pageIDs.append(builder.addPage(
                parent: pagesNode, mediaBox: mediaBox,
                resources: "<</Font<</F1 \(font) 0 R>>>>", contents: stream))
        }

        builder.fill(pagesNode, "<</Type/Pages/Count \(pageIDs.count)/Kids ["
            + pageIDs.map { "\($0) 0 R" }.joined(separator: " ") + "]>>")
        builder.fill(catalog, "<</Type/Catalog/Pages \(pagesNode) 0 R>>")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-orient-\(UUID().uuidString).pdf")
        try builder.build(rootObject: catalog).write(to: url)
        return url
    }

    /// Eine korrekt um 90° gedrehte Seite muss deckungsgleich messen – auf
    /// Hoch- WIE Querformat.
    ///
    /// Vorher wurde die Quelle ungedreht gerastert und das Rasterbild
    /// nachgedreht, während die Ausgabe von PDFKit direkt aus `/Rotate`
    /// gerendert wurde. Die beiden Rasterungswege wichen bei Text um
    /// Subpixel ab: An f3800 meldete jede der neun Seiten CAR 0.06–0.11,
    /// obwohl die Drehung stimmte.
    @Test func rotationOnMixedOrientationComparesAsIdentical() throws {
        let source = try Self.makeMixedOrientationDocument()
        defer { try? FileManager.default.removeItem(at: source) }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-orient-out-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        let document = try #require(PDFDocument(url: source))
        let rotated = PDFDocument()
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index)?.copy() as? PDFPage)
            page.rotation = page.rotation + 90
            rotated.insert(page, at: rotated.pageCount)
        }
        #expect(rotated.write(to: output))

        // 72 statt 150 DPI: Gemessen wird, ob eine korrekt gedrehte Seite als
        // unverändert durchgeht – dafür braucht es keine Druckauflösung. Bei
        // 150 DPI kostet dieser eine Test im Debug-Build über eine Minute und
        // verzögert die halbe Suite. Dass die Empfindlichkeit erhalten bleibt,
        // sichert `wrongRotationOnMixedOrientationIsDetected` ab: Der Test
        // schlägt bei falscher Drehung weiterhin an.
        let diffs = try RenderDifferential.compare(
            sourceURL: source, outputURL: output, dpi: 72,
            sourceRotationDegrees: 90)

        #expect(diffs.count == document.pageCount)
        for diff in diffs {
            #expect(diff.changedAreaRatio < 0.01, """
                Seite \(diff.sourcePageIndex): CAR \
                \(String(format: "%.4f", diff.changedAreaRatio)) – eine korrekt \
                gedrehte Seite darf nicht als geändert gemessen werden.
                """)
            #expect(diff.ssim > 0.99, """
                Seite \(diff.sourcePageIndex): SSIM \
                \(String(format: "%.4f", diff.ssim))
                """)
        }
    }

    /// Gegenprobe auf demselben Dokument: Wird die Ausgabe FALSCH gedreht,
    /// muss der Vergleich das melden. Sonst hätte der Fix oben nur die
    /// Empfindlichkeit beseitigt.
    @Test(arguments: [90, 180, 270])
    func wrongRotationOnMixedOrientationIsDetected(actual: Int) throws {
        let source = try Self.makeMixedOrientationDocument()
        defer { try? FileManager.default.removeItem(at: source) }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-orient-bad-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        let document = try #require(PDFDocument(url: source))
        let wrong = PDFDocument()
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index)?.copy() as? PDFPage)
            page.rotation = page.rotation + actual
            wrong.insert(page, at: wrong.pageCount)
        }
        #expect(wrong.write(to: output))

        // Erwartet werden 90° – geliefert wird etwas anderes.
        // Dieselbe Auflösung wie oben: Sonst prüft die Gegenprobe nicht
        // dieselbe Sache wie der Test, den sie absichert.
        let diffs = try RenderDifferential.compare(
            sourceURL: source, outputURL: output, dpi: 72,
            sourceRotationDegrees: 90)
        let worst = diffs.map(\.changedAreaRatio).max() ?? 0
        if actual == 90 {
            #expect(worst < 0.01, "Die erwartete Drehung darf nicht auffallen")
        } else {
            #expect(worst > 0.02, """
                Falsche Drehung um \(actual)° wird nicht erkannt (CAR \
                \(String(format: "%.4f", worst))).
                """)
        }
    }
}
