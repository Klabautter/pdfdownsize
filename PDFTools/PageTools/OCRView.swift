import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// OCR-Workspace: PDF wählen → erkennen → durchsuchbares PDF speichern.
/// Zuständigkeit: nur Texterkennung. Mischen/Sortieren → Organisieren,
/// Formatwechsel → Konvertieren.
///
/// Layout (Neugestaltung 2026-10-12, Vorbild Vorschau mit Text-Seitenleiste):
/// links das Dokument, rechts eine feste, fensterhohe Textspalte. Oben
/// Kopf (Datei, Kennzahlen, Fortschritt), in der Mitte der erkannte Text als
/// Fließtext je Seite, unten die Aktionen. Dokument und Spalte zeigen immer
/// dieselbe Seite.
struct OCRView: View {
    @ObservedObject var vm: OCRViewModel
    /// Abgelegte Bilder gehören zu Konvertieren – RootView wechselt dorthin.
    var onForeignFiles: (([URL]) -> Void)? = nil
    @EnvironmentObject private var discardGuard: DiscardGuard

    /// Dieselbe Karte wie das Pult in Komprimieren und Konvertieren
    /// (ToolWorkspace): gleiche Breite, gleicher Abstand, gleiches Glas.
    private static let columnWidth: CGFloat = 330
    private static let columnInset: CGFloat = 16
    @State private var showImporter = false
    @State private var isTargeted = false

    var body: some View {
        Group {
            switch vm.stage {
            case .choose:
                chooseState
            case .ready, .working, .done:
                workingState
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .focusedSceneObject(vm)
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            let images = urls.filter { ImageImporter.isSupported($0) }
            if pdfs.isEmpty, !images.isEmpty, let onForeignFiles {
                onForeignFiles(images)
                return true
            }
            discardGuard.run(ifUnsaved: vm.hasUnsavedResult) { vm.accept(urls) }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if vm.stage == .done {
                    // Der Schalter wirkt im Dokument – also bei der Toolbar
                    // des Dokuments, nicht zwischen den Textaktionen.
                    Toggle(isOn: $vm.showsRecognizedText) {
                        Label("Erkannten Text markieren", systemImage: "highlighter")
                    }
                    .help("Erkannten Text im Dokument markieren")
                }
                // Dasselbe Muster wie Komprimieren (Befund S2).
                if vm.stage != .choose {
                    Button {
                        vm.wantsFiles = true
                    } label: {
                        Label("Andere PDF öffnen …", systemImage: "plus")
                    }
                    .disabled(vm.isWorking)
                }
            }
        }
        .onChange(of: vm.wantsFiles) { _, wants in
            if wants {
                vm.wantsFiles = false
                showImporter = true
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.pdf],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result {
                discardGuard.run(ifUnsaved: vm.hasUnsavedResult) { vm.accept(urls) }
            }
        }
    }

    // MARK: - Auswahl

    private var chooseState: some View {
        WorkspaceWelcome(icon: "text.viewfinder",
                         title: String(localized: "PDF durchsuchbar machen"),
                         subtitle: String(localized: "Text in gescannten Seiten erkennen – lokal auf dem Mac."),
                         dropHint: String(localized: "Dateien auch hierher ziehen"),
                         isTargeted: isTargeted) {
            Button("PDF auswählen …") { showImporter = true }
                .buttonStyle(.borderedProminent)
            if let error = vm.errorMessage {
                InlineNotice(message: error)
                    .frame(maxWidth: 420)
            }
        }
    }

    // MARK: - Quelle gesetzt

    @ViewBuilder
    private var workingState: some View {
        // Die Suche gehört in die Toolbar (Befund S13) – nur mit Ergebnis.
        if vm.stage == .done {
            workspace
                .searchable(text: $vm.searchQuery, placement: .toolbar,
                            prompt: "Im erkannten Text suchen")
        } else {
            workspace
        }
    }

    /// Dokument links, Textspalte rechts als schwebende Glaskarte – dasselbe
    /// Bild wie das Pult in Komprimieren und Konvertieren (eine Pult-Sprache,
    /// 15.10.2026). Die Karte ist fensterhoch, weil der erkannte Text scrollt.
    private var workspace: some View {
        GeometryReader { geo in
            let canvasWidth = max(geo.size.width - Self.columnWidth - Self.columnInset, 200)
            ZStack(alignment: .topLeading) {
                Theme.canvas
                Group {
                    if let url = vm.outputURL ?? vm.savedURL ?? vm.pdfURL {
                        DocumentPreview(url: url, scanning: vm.isWorking,
                                        page: $vm.currentPage,
                                        highlight: vm.stage == .done ? vm.searchQuery : "",
                                        markedPages: vm.stage == .done && vm.showsRecognizedText
                                            ? vm.recognizedPageIndices : []) { selected, count in
                            String(localized: "Seite \(selected + 1) von \(count)")
                        }
                    }
                }
                .frame(width: canvasWidth, height: geo.size.height)
                // Vor dem Lauf so hoch wie ihr Inhalt (wie die anderen
                // Pulte); mit erkanntem Text fensterhoch, weil der scrollt.
                textColumn
                    .frame(width: Self.columnWidth,
                           height: vm.stage == .done ? geo.size.height - 2 * Self.columnInset : nil)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
                    .glassEffect(.regular, in: .rect(cornerRadius: Theme.panelRadius))
                    .padding(Self.columnInset)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
            }
        }
        .dropTargetOverlay(isTargeted)
    }

    // MARK: - Textspalte

    private var textColumn: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.panelPadding)
                .padding(.top, Theme.panelPadding)
                .padding(.bottom, 14)
            Divider()
            columnContent
                .frame(maxWidth: .infinity)
            Divider()
            footer
                .padding(Theme.panelPadding)
        }
        .focusEffectDisabled()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: vm.pdfURL?.lastPathComponent ?? "",
                        subtitle: headerSubtitle,
                        closeDisabled: vm.isWorking,
                        onClose: {
                            discardGuard.run(ifUnsaved: vm.hasUnsavedResult) { vm.reset() }
                        })
            if vm.isWorking {
                WorkProgressBar(progress: vm.progress,
                                label: vm.statusLabel,
                                isCancelling: vm.isCancelling,
                                onCancel: { vm.cancelWork() })
            }
            if vm.stage == .done, !vm.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                hitBar
            }
        }
    }

    private var headerSubtitle: String {
        switch vm.stage {
        case .done:
            return statsLine
        default:
            guard let url = vm.pdfURL else { return "" }
            let size = CompressionResult.format(Compressor.fileSize(of: url))
            guard vm.pageCount > 0 else { return size }
            return "\(size) · \(Counted.pages(vm.pageCount))"
        }
    }

    /// Trefferzeile unter dem Kopf: Stand und ‹ › wie in Vorschau (⌘G).
    private var hitBar: some View {
        HStack(spacing: 6) {
            Text(hitCaption)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                vm.stepHit(-1)
            } label: {
                Label("Vorheriger Treffer", systemImage: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            Button {
                vm.stepHit(1)
            } label: {
                Label("Nächster Treffer", systemImage: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(vm.searchHits.isEmpty)
    }

    @ViewBuilder
    private var columnContent: some View {
        switch vm.stage {
        case .done:
            OCRTextColumn(sections: vm.textSections,
                          page: $vm.currentPage,
                          hits: vm.searchHits,
                          selectedHit: vm.selectedHit)
                .frame(maxHeight: .infinity)
        case .working:
            ContentUnavailableView {
                Label("Text wird erkannt", systemImage: "text.viewfinder")
                    .symbolRenderingMode(.hierarchical)
            } description: {
                Text("Der erkannte Text erscheint hier, sobald alle Seiten bearbeitet sind.")
            }
            .frame(height: 220)
        default:
            // Kein ScrollView: Die Karte ist so hoch wie ihr Inhalt, wie
            // das Pult in Komprimieren und Konvertieren.
            setupView
                .padding(Theme.panelPadding)
        }
    }

    // MARK: - Vorbereitung

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledContent("Sprache") {
                Picker("Sprache", selection: $vm.languagePreset) {
                    ForEach(OCREngine.OCRLanguagePreset.allCases, id: \.self) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(vm.stage != .ready)

            // Ein Satz im Pult, der Rest als Tooltip (Sichtabnahme 2026-10-15).
            Text("Macht gescannte Seiten durchsuchbar – das Aussehen bleibt unverändert.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help("Legt eine unsichtbare Textebene über gescannte Seiten. Links, Formulare und Lesezeichen bleiben erhalten; Seiten mit vorhandenem Text werden übersprungen.")

            if vm.hasSignature {
                Label("Digital signiert – die Textebene macht die Signatur ungültig. Das Original bleibt unverändert.",
                      systemImage: "signature")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Aktionen

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = vm.errorMessage {
                InlineNotice(message: error)
            }
            switch vm.stage {
            case .done:
                doneActions
            case .ready:
                Button { vm.runOCR() } label: {
                    Text("Text erkennen").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.hasSource)
            default:
                EmptyView()
            }
        }
    }

    private var doneActions: some View {
        VStack(spacing: 10) {
            if let saved = vm.savedURL {
                SavedResultBlock(detail: saved.lastPathComponent, urls: [saved],
                                 followUp: (String(localized: "Weitere PDF öffnen …"), { vm.wantsFiles = true }))
            } else if vm.canSaveSearchablePDF {
                // ⌘S liegt im Ablage-Menü (Commands.swift, Befund S15).
                Button { vm.saveOutcome() } label: {
                    Text("Durchsuchbare PDF sichern …").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                // Nichts erkannt: kein Sichern-Knopf, der nur das Original
                // kopieren würde (Sichtabnahme 2026-10-12, L7).
                Text("Keine Seite musste erkannt werden – die PDF ist schon durchsuchbar. Der vorhandene Text steht oben und lässt sich kopieren oder als Text sichern.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button { vm.copyFullText() } label: {
                    Text("Text kopieren").frame(maxWidth: .infinity)
                }
                Button { vm.saveText() } label: {
                    Text("Als Text sichern …").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!vm.hasText)
        }
    }

    private var hitCaption: String {
        let total = vm.searchHitTotal
        guard total > 0 else { return String(localized: "Keine Treffer") }
        let shown = vm.searchHits.count
        let current = min(vm.selectedHit + 1, shown)
        if total > shown {
            return String(localized: "\(current) von \(shown.formatted()) Treffern · insgesamt \(total.formatted())")
        }
        return total == 1
            ? String(localized: "1 von 1 Treffer")
            : String(localized: "\(current) von \(shown.formatted()) Treffern")
    }

    private var statsLine: String {
        var parts = [String(localized: "\(vm.totalWords.formatted()) Wörter"),
                     String(localized: "\(vm.recognizedPageCount) Seiten erkannt")]
        if vm.skippedPageCount > 0 {
            parts.append(String(localized: "\(vm.skippedPageCount) hatten schon Text"))
        }
        // Keine „Ø Sicherheit" mehr (Sichtabnahme 2026-10-12, M6): Vision
        // meldet je Zeile fast immer 1,0 – auch bei sichtbarem
        // Erkennungsmüll. Die Zahl stand so gut wie immer auf 100 % und
        // sagte nichts über die Qualität.
        return parts.joined(separator: " · ")
    }
}

// MARK: - Textspalte (AppKit)

/// Der erkannte Text als EIN durchgehendes, nur lesbares Textdokument:
/// Seitenüberschriften, Fließtext in Systemstilen, Markieren und Kopieren
/// über Seitengrenzen hinweg, Suchtreffer hervorgehoben. Ein `NSTextView`,
/// weil SwiftUI-`Text` keine durchgehende Auswahl und kein Scrollen zu
/// Fundstellen kann.
///
/// Synchronisation mit dem Dokument:
/// - `page` ändert sich (Blättern links) → die Spalte scrollt zur Überschrift.
/// - Scrollen in der Spalte → die oberste sichtbare Seite wird `page`.
/// - Klick auf eine Überschrift → `page`.
/// - Treffer gewählt → Spalte scrollt hin, `page` folgt.
struct OCRTextColumn: NSViewRepresentable {
    let sections: [OCRViewModel.TextSection]
    @Binding var page: Int
    let hits: [OCRViewModel.SearchHit]
    let selectedHit: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        // TextKit 1 ausdrücklich: temporäre Attribute für Treffer und
        // Geometrie-Abfragen für die Seitensynchronisation.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 18)
        // Überschriften sind Links (Seite wählen) – ohne Linkoptik.
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .underlineStyle: 0,
            .cursor: NSCursor.pointingHand,
        ]
        textView.linkTextAttributes = linkAttributes
        textView.delegate = context.coordinator
        scroll.documentView = textView

        context.coordinator.attach(scrollView: scroll, textView: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.apply(sections: sections)
        coordinator.show(page: page)
        coordinator.apply(hits: hits, selected: selectedHit)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: OCRTextColumn
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private var observer: NSObjectProtocol?

        private var sections: [OCRViewModel.TextSection] = []
        /// Beginn jedes Abschnitts (Überschrift) im Gesamttext, in Seitenreihenfolge.
        private var sectionStarts: [(pageIndex: Int, location: Int)] = []
        /// Beginn des Fließtexts je Seite und die Stellen, an denen die
        /// Absatz-Leerzeile („\n\n" im Modell) zu einem „\n" wurde.
        private var bodyStarts: [Int: Int] = [:]
        private var bodyBreaks: [Int: [Int]] = [:]

        private var hits: [OCRViewModel.SearchHit] = []
        private var selectedHit = -1
        /// Seite, deren Abschnitt gerade oben in der Spalte steht – Referenz
        /// gegen Rückkopplung zwischen Dokument und Spalte.
        private var pageAtTop: Int?
        /// An das Dokument gemeldete Seite, die noch nicht als `page`
        /// zurückgekommen ist – bis dahin keine Rücksprünge.
        private var pendingPage: Int?
        private var programmatic = false

        init(_ parent: OCRTextColumn) {
            self.parent = parent
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func attach(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrolled() }
            }
        }

        // MARK: Inhalt

        func apply(sections: [OCRViewModel.TextSection]) {
            guard sections != self.sections, let textView, let storage = textView.textStorage else { return }
            self.sections = sections
            sectionStarts = []
            bodyStarts = [:]
            bodyBreaks = [:]
            pageAtTop = nil
            pendingPage = nil
            hits = []
            selectedHit = -1

            let headingFont = NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
            let bodyFont = NSFont.preferredFont(forTextStyle: .body)
            let noteFont = NSFont.preferredFont(forTextStyle: .callout)

            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.lineSpacing = 2.5
            bodyStyle.paragraphSpacing = 9
            let noteStyle = NSMutableParagraphStyle()
            noteStyle.paragraphSpacing = 9

            let text = NSMutableAttributedString()
            for (index, section) in sections.enumerated() {
                let headingStyle = NSMutableParagraphStyle()
                headingStyle.paragraphSpacingBefore = index == 0 ? 0 : 26
                headingStyle.paragraphSpacing = 6
                sectionStarts.append((section.pageIndex, text.length))
                text.append(NSAttributedString(string: section.title + "\n", attributes: [
                    .font: headingFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: headingStyle,
                    .link: "page:\(section.pageIndex)",
                ]))
                // Hinweis UND Text: Eine übersprungene Seite trägt den Hinweis
                // „nicht neu erkannt" über ihrem vorhandenen Text (15.10.2026).
                if let note = section.note {
                    text.append(NSAttributedString(string: note + "\n", attributes: [
                        .font: noteFont,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .paragraphStyle: noteStyle,
                    ]))
                }
                if !section.body.isEmpty {
                    bodyStarts[section.pageIndex] = text.length
                    let (display, breaks) = Self.displayBody(section.body)
                    bodyBreaks[section.pageIndex] = breaks
                    text.append(NSAttributedString(string: display + "\n", attributes: [
                        .font: bodyFont,
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: bodyStyle,
                    ]))
                }
            }
            storage.setAttributedString(text)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            scrollView?.contentView.scroll(to: .zero)
        }

        /// Absätze trennt das Modell mit Leerzeilen; die Spalte nutzt
        /// Absatzabstand statt Leerzeilen. Liefert den Anzeigetext und die
        /// UTF-16-Stellen (im Modelltext) der entfernten Zeichen.
        private static func displayBody(_ body: String) -> (String, [Int]) {
            let source = body as NSString
            var breaks: [Int] = []
            var search = NSRange(location: 0, length: source.length)
            while true {
                let found = source.range(of: "\n\n", range: search)
                guard found.location != NSNotFound else { break }
                breaks.append(found.location)
                search = NSRange(location: found.location + 2, length: source.length - found.location - 2)
            }
            return (source.replacingOccurrences(of: "\n\n", with: "\n"), breaks)
        }

        /// Fundstelle im Modelltext einer Seite → Bereich im Gesamttext.
        private func displayRange(_ hit: OCRViewModel.SearchHit) -> NSRange? {
            guard let start = bodyStarts[hit.pageIndex] else { return nil }
            let removed = (bodyBreaks[hit.pageIndex] ?? []).filter { $0 < hit.range.location }.count
            return NSRange(location: start + hit.range.location - removed, length: hit.range.length)
        }

        // MARK: Treffer

        func apply(hits: [OCRViewModel.SearchHit], selected: Int) {
            guard hits != self.hits || selected != selectedHit,
                  let textView, let layout = textView.layoutManager else { return }
            self.hits = hits
            selectedHit = selected
            let full = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            for (index, hit) in hits.enumerated() {
                guard let range = displayRange(hit) else { continue }
                let alpha: CGFloat = index == selected ? 0.9 : 0.4
                layout.addTemporaryAttribute(.backgroundColor,
                                             value: NSColor.systemYellow.withAlphaComponent(alpha),
                                             forCharacterRange: range)
            }
            guard hits.indices.contains(selected), let range = displayRange(hits[selected]) else { return }
            programmatic = true
            textView.scrollRangeToVisible(range)
            programmatic = false
            report(page: hits[selected].pageIndex)
        }

        /// Spalte hat die Seite gewechselt → Dokument nachziehen (außerhalb
        /// des SwiftUI-Updates, wie in `DocumentCanvas`).
        private func report(page: Int) {
            pageAtTop = page
            guard parent.page != page else { return }
            pendingPage = page
            DispatchQueue.main.async { [weak self] in self?.parent.page = page }
        }

        // MARK: Seite ↔ Scrollposition

        func show(page: Int) {
            if page == pendingPage { pendingPage = nil }
            guard pendingPage == nil, page != pageAtTop,
                  let start = sectionStarts.first(where: { $0.pageIndex == page })?.location,
                  let textView, let scrollView,
                  let layout = textView.layoutManager, let container = textView.textContainer else { return }
            let range = NSRange(location: start, length: 1)
            layout.ensureLayout(forCharacterRange: range)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let clip = scrollView.contentView
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let maxY = max(0, documentHeight - clip.bounds.height)
            let y = min(max(rect.minY + textView.textContainerInset.height - 10, 0), maxY)
            programmatic = true
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
            programmatic = false
            pageAtTop = page
        }

        private func scrolled() {
            guard !programmatic, let page = pageAtTopNow(), page != pageAtTop else { return }
            report(page: page)
        }

        /// Seite des Abschnitts, der am oberen Rand der Spalte sichtbar ist.
        private func pageAtTopNow() -> Int? {
            guard !sectionStarts.isEmpty, let textView, let scrollView,
                  let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
            let visible = scrollView.contentView.bounds
            let point = NSPoint(x: 0,
                                y: max(visible.minY + 12 - textView.textContainerInset.height, 0))
            layout.ensureLayout(forBoundingRect: visible, in: container)
            let glyph = layout.glyphIndex(for: point, in: container)
            let character = layout.characterIndexForGlyph(at: glyph)
            return sectionStarts.last(where: { $0.location <= character })?.pageIndex
                ?? sectionStarts.first?.pageIndex
        }

        // MARK: NSTextViewDelegate

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let value = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            guard value.hasPrefix("page:"), let page = Int(value.dropFirst(5)) else { return false }
            report(page: page)
            return true
        }
    }
}
