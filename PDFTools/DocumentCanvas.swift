import SwiftUI
import PDFKit

/// Native Dokumentansicht der Kompression: PDFKit statt vorgerenderter
/// Bilder – Pinch-Zoom, Smart-Zoom (Doppeltipp), Trackpad-Scrollen und
/// scharfe Darstellung in jeder Vergrößerung, wie in Vorschau.
///
/// Mit `compressed` zeigt die Ansicht den Vorher-Nachher-Vergleich: zwei
/// deckungsgleiche PDFViews, links vom Teiler das Original, rechts das
/// Ergebnis. Zoom und Ausschnitt laufen synchron, egal auf welcher Seite
/// des Teilers man zoomt oder scrollt.
struct DocumentCanvas: NSViewRepresentable {
    let original: PDFDocument
    var compressed: PDFDocument?
    let pageIndex: Int
    /// Anteil der Breite, der das Original zeigt (nur im Vergleich).
    var fraction: Double = 0.5
    /// Suchbegriff, dessen Fundstellen markiert werden (leer = keine).
    var highlight: String = ""
    /// Seiten, deren Text dezent markiert wird (z. B. erkannter OCR-Text).
    var markedPages: Set<Int> = []
    var controller: CanvasController?
    var onPageChange: (Int) -> Void = { _ in }
    /// Seitenrahmen in SwiftUI-Koordinaten (oben links), für Scan-Linie
    /// und Teiler.
    var onPageFrame: (CGRect) -> Void = { _ in }

    func makeNSView(context: Context) -> CompareCanvasView {
        let view = CompareCanvasView()
        view.onPageChange = onPageChange
        view.onPageFrame = onPageFrame
        controller?.view = view
        return view
    }

    func updateNSView(_ view: CompareCanvasView, context: Context) {
        controller?.view = view
        view.onPageChange = onPageChange
        view.onPageFrame = onPageFrame
        view.show(original: original, compressed: compressed)
        view.fraction = CGFloat(fraction)
        view.setHighlight(highlight, markedPages: markedPages)
        view.go(toPage: pageIndex)
    }
}

/// Zoom-Knöpfe für Mausnutzer; Trackpad und ⌘± wirken direkt in der Ansicht.
@MainActor
final class CanvasController {
    weak var view: CompareCanvasView?

    func zoomIn() { view?.base.zoomIn(nil) }
    func zoomOut() { view?.base.zoomOut(nil) }
    func fit() { view?.base.autoScales = true }
}

/// AppKit-Kern des Vergleichs. Unten liegt IMMER die Ansicht des Originals,
/// darüber – in einem Clip rechts vom Teiler – die des Ergebnisses. Beide
/// haben dieselbe Größe; der Clip schneidet nur ab. Klicks links vom Teiler
/// treffen das Original, rechts das Ergebnis.
///
/// Das Original bleibt unten liegen, damit Verwerfen („Mit anderem Modus
/// versuchen") nur die obere Ansicht ausblendet: Vorher wechselte die untere
/// Ansicht das Dokument und zeigte ein bis zwei Sekunden eine weiße Seite
/// (Sichtabnahme 2026-10-12, L5).
final class CompareCanvasView: NSView {
    let base = CompareCanvasView.makePDFView()
    let overlay = CompareCanvasView.makePDFView()
    private let clip = ClipView()
    private var syncing = false
    private var observers: [NSObjectProtocol] = []

    var onPageChange: (Int) -> Void = { _ in }
    var onPageFrame: (CGRect) -> Void = { _ in }

    var fraction: CGFloat = 0.5 {
        didSet {
            guard fraction != oldValue else { return }
            needsLayout = true
        }
    }

    var isComparing: Bool { overlay.document != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(base)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.addSubview(overlay)
        addSubview(clip)
        observe(base)
        observe(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private static func makePDFView() -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displaysPageBreaks = true
        view.autoScales = true
        view.backgroundColor = .windowBackgroundColor   // gleich Theme.canvas
        // Blattkante wie in Vorschau: Ohne Schatten ist weißes Papier auf
        // der hellen Fläche nicht abzugrenzen (Sichtabnahme 2026-10-12).
        view.pageShadowsEnabled = true
        view.displayBox = .cropBox
        return view
    }

    // MARK: Inhalt

    func show(original: PDFDocument, compressed: PDFDocument?) {
        let baseDocument = original
        let overlayDocument = compressed
        let changed = base.document !== baseDocument || overlay.document !== overlayDocument
        if base.document !== baseDocument {
            base.document = baseDocument
            base.autoScales = true
        }
        if overlay.document !== overlayDocument {
            overlay.document = overlayDocument
            if overlayDocument != nil {
                overlay.autoScales = true
                mirror(from: base, to: overlay)
            }
        }
        // Ohne Vergleich darf keine leere Ansicht obenauf Klicks schlucken.
        clip.isHidden = overlayDocument == nil
        // PDFView legt ihre Scroll-View erst mit einem Dokument an.
        observeScrolling(base)
        observeScrolling(overlay)
        // Nur bei neuem Inhalt neu layouten: SwiftUI ruft das bei JEDER
        // Aktualisierung (z. B. jeder Seitenrahmen-Meldung während eines
        // Pinch) – unnötige Layoutpässe mitten in der Geste.
        if changed { needsLayout = true }
    }

    private var highlightQuery = ""
    private var highlightPages: Set<Int> = []
    private weak var highlightDocument: PDFDocument?

    /// Markiert Suchtreffer (gelb) – ohne Suche den Text der markierten
    /// Seiten (dezent in Akzentfarbe), damit sichtbar ist, was erkannt wurde.
    func setHighlight(_ query: String, markedPages: Set<Int> = []) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != highlightQuery || markedPages != highlightPages
                || highlightDocument !== base.document else { return }
        highlightQuery = trimmed
        highlightPages = markedPages
        highlightDocument = base.document
        guard let document = base.document else { base.highlightedSelections = nil; return }
        if trimmed.count >= 2 {
            let hits = document.findString(trimmed, withOptions: .caseInsensitive)
            hits.forEach { $0.color = .systemYellow.withAlphaComponent(0.55) }
            base.highlightedSelections = hits
            return
        }
        let marks = markedPages.sorted().compactMap { index -> PDFSelection? in
            guard let page = document.page(at: index),
                  let selection = page.selection(for: page.bounds(for: .cropBox)),
                  !(selection.string ?? "").isEmpty else { return nil }
            selection.color = NSColor.controlAccentColor.withAlphaComponent(0.18)
            return selection
        }
        base.highlightedSelections = marks.isEmpty ? nil : marks
    }

    func go(toPage index: Int) {
        for view in [base, overlay] {
            guard let document = view.document, index < document.pageCount,
                  let page = document.page(at: index), view.currentPage !== page else { continue }
            view.go(to: page)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let split = bounds.width * fraction
        let clipFrame = NSRect(x: split, y: 0, width: bounds.width - split, height: bounds.height)
        // Gleiche Größe und Lage wie base; der Clip schneidet links ab.
        let overlayFrame = NSRect(x: -split, y: 0, width: bounds.width, height: bounds.height)
        if base.frame != bounds { base.frame = bounds }
        if clip.frame != clipFrame { clip.frame = clipFrame }
        if overlay.frame != overlayFrame { overlay.frame = overlayFrame }
        observeScrolling(base)
        observeScrolling(overlay)
        reportPageFrame()
    }

    // MARK: Synchronisierung

    private func observe(_ view: PDFView) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: view,
                                            queue: .main) { [weak self] _ in
            self?.mirror(from: view)
        })
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: view,
                                            queue: .main) { [weak self] _ in
            guard let self, let page = view.currentPage,
                  let index = view.document?.index(for: page) else { return }
            self.mirror(from: view)
            let report = self.onPageChange
            DispatchQueue.main.async { report(index) }
        })
    }

    /// Scrollen: Die Clip-Ansicht der inneren Scroll-View meldet
    /// Grenzänderungen. Einmal je Clip-Ansicht (idempotent).
    private var observedClipViews: Set<ObjectIdentifier> = []

    private func observeScrolling(_ view: PDFView) {
        guard let clipView = Self.scrollView(of: view)?.contentView,
              observedClipViews.insert(ObjectIdentifier(clipView)).inserted else { return }
        clipView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView,
            queue: .main) { [weak self] _ in
            self?.mirror(from: view)
        })
    }

    private func mirror(from source: PDFView) {
        let target = source === base ? overlay : base
        mirror(from: source, to: target)
    }

    private func mirror(from source: PDFView, to target: PDFView) {
        defer { reportPageFrame() }
        guard !syncing, target.document != nil, source.document != nil else { return }
        syncing = true
        defer { syncing = false }
        if target.autoScales != source.autoScales { target.autoScales = source.autoScales }
        if abs(target.scaleFactor - source.scaleFactor) > 0.0001 {
            target.scaleFactor = source.scaleFactor
        }
        if let page = source.currentPage,
           let index = source.document?.index(for: page),
           let targetPage = target.document?.page(at: index),
           target.currentPage !== targetPage {
            target.go(to: targetPage)
        }
        if let from = Self.scrollView(of: source)?.contentView,
           let toScroll = Self.scrollView(of: target) {
            let origin = from.bounds.origin
            if toScroll.contentView.bounds.origin != origin {
                toScroll.contentView.scroll(to: origin)
                toScroll.reflectScrolledClipView(toScroll.contentView)
            }
        }
    }

    static func scrollView(of view: PDFView) -> NSScrollView? {
        view.subviews.compactMap { $0 as? NSScrollView }.first
            ?? view.documentView?.enclosingScrollView
    }

    private var lastPageFrame: CGRect = .null

    private func reportPageFrame() {
        guard let page = base.currentPage else { return }
        let inView = base.convert(page.bounds(for: base.displayBox), from: page)
        let local = convert(inView, from: base)
        // SwiftUI misst von oben links.
        let flipped = CGRect(x: local.minX, y: bounds.height - local.maxY,
                             width: local.width, height: local.height)
        guard flipped != lastPageFrame else { return }
        lastPageFrame = flipped
        // Nie während eines Layout-/View-Updates in SwiftUI-Zustand schreiben.
        let report = onPageFrame
        DispatchQueue.main.async { report(flipped) }
    }

    /// Clip-Container: trifft nur innerhalb seiner eigenen Fläche.
    private final class ClipView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden, frame.contains(point) else { return nil }
            return super.hitTest(point)
        }
    }
}
