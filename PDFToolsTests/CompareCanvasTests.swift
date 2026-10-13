import Testing
import Foundation
import AppKit
import SwiftUI
import PDFKit
import CoreText
@testable import PDFTools

/// Nutzerbefund 2026-09-30: Vorher-Nachher-Vergleich unscharf, kein Zoom,
/// Durchklicken der Seiten ruckelt.
///
/// Neu: native PDFViews (Zoom/Scrollen wie in Vorschau), deckungsgleich
/// übereinander, Original bis zum Teiler.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Zoom oder Ausschnitt laufen zwischen Original und Ergebnis
///     auseinander – der Vergleich zeigt verschiedene Stellen.
///  2. Klicks/Gesten rechts vom Teiler landen im Original (oder umgekehrt).
///  3. Ein Seitenwechsel erreicht nur eine der beiden Ansichten.
///  4. Seitenwechsel öffnen Dokumente neu (Ruckeln, Speicher).
///  5. Ohne Ergebnis bleibt eine unsichtbare zweite Ansicht aktiv.
@MainActor
@Suite struct CompareCanvasTests {

    private func document(pages: Int) throws -> (URL, PDFDocument) {
        let url = try PDFFixtures.write(
            PDFFixtures.document(pages: (0..<pages).map { PDFFixtures.textPage("Seite \($0 + 1)") }),
            name: "canvas-\(UUID().uuidString)")
        return (url, try #require(PDFDocument(url: url)))
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func canvas(original: PDFDocument, compressed: PDFDocument?) -> CompareCanvasView {
        let view = CompareCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        view.show(original: original, compressed: compressed)
        view.layoutSubtreeIfNeeded()
        settle()
        return view
    }

    @Test func zoomUndAusschnittLaufenSynchron() throws {
        let (a, original) = try document(pages: 3)
        let (b, compressed) = try document(pages: 3)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let view = canvas(original: original, compressed: compressed)
        #expect(view.isComparing)

        // 1a. Zoom im Original (links) → Ergebnis folgt.
        view.overlay.autoScales = false
        view.overlay.scaleFactor = 2.5
        settle()
        #expect(abs(view.base.scaleFactor - 2.5) < 0.001, "Ergebnis-Zoom \(view.base.scaleFactor)")

        // 1b. Scrollen im Ergebnis (rechts) → Original folgt.
        let scroll = try #require(CompareCanvasView.scrollView(of: view.base))
        scroll.contentView.scroll(to: NSPoint(x: 120, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        let other = try #require(CompareCanvasView.scrollView(of: view.overlay))
        let po = other.contentView.bounds.origin, pb = scroll.contentView.bounds.origin
        // Gleitkomma-Rest (1e-13) ist kein Versatz; 0,01 px liegt weit unter einem Pixel.
        #expect(abs(po.x - pb.x) < 0.01 && abs(po.y - pb.y) < 0.01,
                "Original \(other.contentView.bounds.origin) ≠ Ergebnis \(scroll.contentView.bounds.origin)")
    }

    @Test func klicksTreffenDieRichtigeSeiteDesTeilers() throws {
        let (a, original) = try document(pages: 1)
        let (b, compressed) = try document(pages: 1)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let view = canvas(original: original, compressed: compressed)
        view.fraction = 0.5
        view.layoutSubtreeIfNeeded()

        func owner(_ point: NSPoint) -> PDFView? {
            var hit = view.hitTest(point)
            while let current = hit, !(current is PDFView) { hit = current.superview }
            return hit as? PDFView
        }
        // Seit 2026-10-13 liegt das Original unten (`base`) und das Ergebnis
        // im Clip rechts vom Teiler (`overlay`) – vorher umgekehrt. Die Zusage
        // an den Nutzer ist dieselbe: links Original, rechts Ergebnis.
        #expect(owner(NSPoint(x: 200, y: 300)) === view.base, "links muss das Original treffen")
        #expect(owner(NSPoint(x: 600, y: 300)) === view.overlay, "rechts muss das Ergebnis treffen")
    }

    @Test func seitenwechselErreichtBeideAnsichten() throws {
        let (a, original) = try document(pages: 4)
        let (b, compressed) = try document(pages: 4)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let view = canvas(original: original, compressed: compressed)
        view.go(toPage: 2)
        settle()
        #expect(view.base.currentPage.flatMap { original.index(for: $0) } == 2)
        #expect(view.overlay.currentPage.flatMap { compressed.index(for: $0) } == 2)
    }

    @Test func ohneErgebnisKeineZweiteAnsicht() throws {
        let (a, original) = try document(pages: 2)
        defer { try? FileManager.default.removeItem(at: a) }
        let view = canvas(original: original, compressed: nil)
        #expect(!view.isComparing)
        #expect(view.base.document === original)
        func owner(_ point: NSPoint) -> NSView? { view.hitTest(point) }
        var hit = owner(NSPoint(x: 100, y: 300))
        while let current = hit, !(current is PDFView) { hit = current.superview }
        #expect(hit === view.base, "ohne Vergleich trifft alles die eine Ansicht")
    }

    /// 4: Seitenwechsel im ViewModel öffnen nichts neu.
    @Test func seitenwechselOeffnetDokumenteNichtNeu() async throws {
        let (a, _) = try document(pages: 5)
        defer { try? FileManager.default.removeItem(at: a) }
        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        viewModel.select(a)
        let opened = try #require(viewModel.originalDocument)
        viewModel.showPage(3)
        viewModel.showPage(1)
        #expect(viewModel.selectedPage == 1)
        #expect(viewModel.originalDocument === opened)
        // Stichprobe statt aller Seiten.
        let deadline = Date().addingTimeInterval(10)
        while viewModel.pageThumbnails.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.pageThumbnails.count == CompressionViewModel.samplePageCount)
        viewModel.clearSingleSelection()
    }

    /// OCR-Ergebnis im Dokument statt daneben (2026-10-01). Fehlermöglich-
    /// keiten: Markierung auf falschen Seiten, Suche wird von der Markierung
    /// verdeckt, Seiten ohne Text erzeugen leere Markierungen.
    @Test func erkannterTextWirdAufDenGewaehltenSeitenMarkiert() throws {
        // Echte Textzeichen (die Bild-Fixture oben hat keinen extrahierbaren Text).
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 1...3 {
            pdf.beginPDFPage(nil)
            pdf.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
                string: "Textseite \(index)",
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])), pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let original = try #require(PDFDocument(data: data as Data))
        let view = canvas(original: original, compressed: nil)

        view.setHighlight("", markedPages: [1])
        let marks = view.base.highlightedSelections ?? []
        #expect(marks.count == 1)
        #expect(marks.first?.pages.first == original.page(at: 1))

        view.setHighlight("Textseite 3", markedPages: [1])
        let hits = view.base.highlightedSelections ?? []
        #expect(hits.count == 1, "Suche muss die Markierung ersetzen")
        #expect(hits.first?.pages.first == original.page(at: 2))

        view.setHighlight("", markedPages: [])
        #expect((view.base.highlightedSelections ?? []).isEmpty)
    }

    /// Nutzerbefund 2026-10-01: Pinch-Zoom „buggt“ (Tasten gehen). Ein Pinch
    /// ändert den Zoom der PDFView; daraufhin meldet die Fläche den neuen
    /// Seitenrahmen an SwiftUI, das die Ansicht aktualisiert. Fehlermöglich-
    /// keit: Diese Aktualisierung setzt den Zoom zurück oder springt.
    @Test func zoomBleibtNachSwiftUIAktualisierungStehen() async throws {
        let (a, original) = try document(pages: 2)
        defer { try? FileManager.default.removeItem(at: a) }
        var fraction = 0.5
        let binding = Binding(get: { fraction }, set: { fraction = $0 })
        let host = NSHostingView(rootView: DocumentStage(original: original, compressed: nil,
                                                         pageIndex: 0, fraction: binding))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))
        func find(_ v: NSView) -> CompareCanvasView? {
            if let c = v as? CompareCanvasView { return c }
            for s in v.subviews { if let c = find(s) { return c } }
            return nil
        }
        let canvas = try #require(find(host))
        for target in [1.7, 2.4, 3.1] {
            // Wie ein Pinch: Zoom ändern, ohne autoScales anzufassen.
            canvas.base.scaleFactor = target
            try await Task.sleep(for: .milliseconds(400))   // Seitenrahmen → SwiftUI → updateNSView
            #expect(abs(canvas.base.scaleFactor - target) < 0.01,
                    "Zoom \(target) → \(canvas.base.scaleFactor) nach Aktualisierung")
        }
    }
}
