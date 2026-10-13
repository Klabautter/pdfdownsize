import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct CellFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct OrganizeView: View {
    /// Von der AppShell gehalten – überlebt Toolwechsel (§7).
    @ObservedObject var vm: MergeViewModel
    /// Cross-Link nach Konvertieren (RootView verdrahtet Tab-Wechsel).
    var onOpenConvert: (() -> Void)? = nil
    /// Ergebnis-PDF ans Komprimieren übergeben (RootView verdrahtet den
    /// Werkzeugwechsel). Ersetzt „Mit Smart komprimieren": Dort wählt man
    /// die Stufe selbst (Sichtabnahme 2026-10-12).
    var onCompress: ((URL) -> Void)? = nil
    @Environment(\.undoManager) private var undoManager

    @State private var lastAnchorID: UUID?
    @State private var isTargeted = false
    /// Tastaturfokus des Rasters: Pfeiltasten wandern durch die Auswahl
    /// (Befund S10). Ein Klick auf eine Kachel holt den Fokus.
    @FocusState private var gridFocused: Bool
    @State private var showImporter = false
    @State private var showSplitSheet = false
    @State private var showImageExportSheet = false
    @State private var cellFrames: [UUID: CGRect] = [:]
    @State private var dragInsertIndex: Int?

    // MARK: Drag-State (Reorder V1.5 + Multi-Drag V2)
    @State private var draggingIDs: [UUID] = []
    @State private var dragPreviewThumb: NSImage?
    @State private var pointerX: CGFloat = 0
    @State private var pointerViewportY: CGFloat = 0
    @State private var contentOffsetY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 1
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var scrollPosition = ScrollPosition()

    // Click/Drag-Unterscheidung (einheitlicher Selection-Handler)
    @State private var pendingClickID: UUID?
    @State private var pendingClickModifiers: NSEvent.ModifierFlags = []

    var body: some View {
        Group {
            if let outcome = vm.outcome {
                outcomeState(outcome)
            } else if vm.project.documents.isEmpty {
                emptyState
            } else {
                organizer
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        // System-„Alles auswählen" (⌘A) landet hier, wenn der Organizer in
        // der Responder-Kette steht – kein eigenes ⌘A mehr (Befund B13).
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            if vm.outcome == nil, !vm.project.pages.isEmpty { vm.selectAll() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Kein Import, solange „PDF erstellen" läuft (Befund S11).
            guard !vm.isProcessing else { return false }
            vm.importDocuments(urls)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .onAppear { vm.attachUndoManager(undoManager) }
        .onChange(of: undoManager) { _, m in vm.attachUndoManager(m) }
        .onChange(of: vm.wantsImport) { _, wants in
            if wants {
                vm.wantsImport = false
                showImporter = true
            }
        }
        .onChange(of: vm.wantsSplit) { _, wants in
            if wants {
                vm.wantsSplit = false
                showSplitSheet = true
            }
        }
        .onChange(of: vm.wantsImages) { _, wants in
            if wants {
                vm.wantsImages = false
                showImageExportSheet = true
            }
        }
        .sheet(isPresented: $showSplitSheet) {
            SplitSheet(vm: vm)
        }
        .sheet(isPresented: $showImageExportSheet) {
            ImageExportSheet(vm: vm, onOpenConvert: onOpenConvert)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: ImageImporter.allowedTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                vm.importDocuments(urls)
            }
        }
        .focusedSceneObject(vm)
        .toolbar {
            // Im leeren Zustand führt die Einstiegskarte zur Dateiauswahl.
            if vm.outcome == nil && !vm.project.documents.isEmpty {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showImporter = true } label: {
                        Label("PDFs oder Bilder hinzufügen", systemImage: "plus")
                    }
                    .disabled(vm.isProcessing)

                    Menu {
                        Button("Alle auswählen") { vm.selectAll() }
                        Divider()
                        Button("PDF aufteilen …") {
                            showSplitSheet = true
                        }
                        .disabled(vm.project.pages.isEmpty || vm.isProcessing)
                        Button("Seiten als Bilder exportieren …") {
                            showImageExportSheet = true
                        }
                        .disabled(vm.project.pages.isEmpty || vm.isProcessing)
                        Divider()
                        Button {
                            vm.resetChanges()
                        } label: {
                            Label("Änderungen zurücksetzen", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(!vm.hasChanges || vm.isProcessing)
                        Button(role: .destructive) {
                            vm.removeAllDocuments()
                        } label: {
                            Label("Alle entfernen", systemImage: "xmark.circle")
                        }
                        .disabled(vm.isProcessing)
                    } label: {
                        Label("Weitere Aktionen", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.iconOnly)
                    .help("Weitere Aktionen")

                    Button {
                        vm.mergeAndPrepare()
                    } label: {
                        // Eigener HStack statt Label: garantiert sichtbaren Text
                        // als Primary Action (Review §23).
                        HStack(spacing: 5) {
                            Image(systemName: "doc.badge.plus")
                            Text("PDF erstellen")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(vm.project.pages.isEmpty || vm.isProcessing)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        WorkspaceWelcome(icon: "rectangle.grid.2x2",
                         title: String(localized: "Seiten organisieren"),
                         subtitle: String(localized: "PDFs und Bilder zusammenführen, Seiten sortieren oder aufteilen."),
                         dropHint: String(localized: "PDFs oder Bilder auch hierher ziehen"),
                         isTargeted: isTargeted) {
            Button("Dateien auswählen …") { showImporter = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            if let error = vm.errorMessage {
                InlineNotice(message: error, onDismiss: { vm.errorMessage = nil })
                    .frame(maxWidth: 360)
            }
        }
    }

    // MARK: - Organizer

    private var organizer: some View {
        VStack(spacing: 0) {
            if vm.isProcessing {
                WorkProgressBar(progress: vm.progress,
                                label: vm.processingLabel,
                                isCancelling: vm.isCancelling,
                                compact: true,
                                onCancel: { vm.cancelProcessing() })
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }

            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 14) {
                        statsHeader
                        if vm.signatureWarningDocs.isEmpty == false {
                            warningBanner
                        }
                        if let error = vm.errorMessage {
                            InlineNotice(message: error, onDismiss: { vm.errorMessage = nil })
                        }
                        pageGrid
                            .disabled(vm.isProcessing)
                    }
                    .padding(16)
                    .padding(.bottom, 72)
                    // Content-Offset tracken – Grundlage für Auto-Scroll während des Drags.
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: ScrollOffsetKey.self,
                                                   value: -inner.frame(in: .named("grid")).minY)
                        }
                    )
                }
                .coordinateSpace(name: "grid")
                .scrollPosition($scrollPosition)
                .onPreferenceChange(ScrollOffsetKey.self) { contentOffsetY = $0 }
                .onAppear { viewportHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, h in viewportHeight = h }
                .overlay {
                    // Stapel-Preview im Viewport-Koordinatenraum (Pointer ruht während Auto-Scroll).
                    dragPreview
                }
            }

        }
        .background(Theme.canvas)
        .dropTargetOverlay(isTargeted)
        .overlay(alignment: .bottom) {
            // Nur mit Auswahl: Die Seitenzahl steht schon im Kopf.
            if !vm.selectedPageIDs.isEmpty {
                footerStrip
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: vm.selectedPageIDs.isEmpty)
    }

    /// Kopf: bei EINEM Dokument Name · Seiten · Größe; bei mehreren eine
    /// Legende (Farbpunkt, Name, Seiten) – die Seiten tragen den Farbpunkt,
    /// statt jede Kachel mit dem Dateinamen zu beschriften.
    private var statsHeader: some View {
        let documents = vm.project.documents
        return VStack(alignment: .leading, spacing: 6) {
            if documents.count == 1, let only = documents.first {
                Text(verbatim: "\(only.fileName) · \(Counted.pages(vm.project.totalPages)) · \(CompressionResult.format(only.fileSize))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("\(documents.count) Dokumente · \(Counted.pages(vm.project.totalPages)) · \(CompressionResult.format(vm.project.totalSourceBytes))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // Umbrechend: ab vier, fünf Dateien lief die Zeile über (Befund S12).
                FlowLayout(spacing: 14, lineSpacing: 4) {
                    ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                        HStack(spacing: 5) {
                            Circle().fill(DocumentPalette.color(index)).frame(width: 8, height: 8)
                            Text("\(document.fileName)  \(Text(verbatim: Counted.pages(document.pageCount)).foregroundStyle(.secondary))")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                        .frame(maxWidth: 260)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var warningBanner: some View {
        Label("Digitale Signatur erkannt (\(vm.signatureWarningDocs.joined(separator: ", "))) – Zusammenführen macht sie ungültig.",
              systemImage: "exclamationmark.shield.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pageGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(vm.project.pages.enumerated()), id: \.element.id) { index, item in
                let documentIndex = vm.project.documents.firstIndex { $0.id == item.sourceDocumentID }
                // Dateiname nur am Beginn eines Blocks aus demselben Dokument.
                let startsBlock = index == 0
                    || vm.project.pages[index - 1].sourceDocumentID != item.sourceDocumentID
                PageCellView(item: item,
                             documentLabel: startsBlock && vm.project.documents.count > 1
                                ? vm.project.document(for: item.sourceDocumentID)?.fileName : nil,
                             documentColor: vm.project.documents.count > 1
                                ? documentIndex.map(DocumentPalette.color) : nil,
                             isSelected: vm.selectedPageIDs.contains(item.id),
                             showLeadingIndicator: dragInsertIndex == index,
                             showTrailingIndicator: dragInsertIndex == vm.project.pages.count && index == vm.project.pages.count - 1,
                             service: ThumbnailService.shared,
                             positionLabel: String(localized: "Seite \(index + 1) von \(vm.project.pages.count)"),
                             onRotate: { delta in
                                 vm.ensureContextSelection(item)
                                 vm.rotateSelectedPages(by: delta)
                             },
                             onDelete: {
                                 vm.ensureContextSelection(item)
                                 vm.deleteSelectedPages()
                             })
                    .simultaneousGesture(pageGesture(for: item))
                    // Bedienungshilfen: „Drücken" wählt die Seite aus – die
                    // Geste oben erreicht VoiceOver nicht (Sichtabnahme
                    // 2026-10-12, L1).
                    .accessibilityAction { handlePageClick(item, modifiers: []) }
                    .contextMenu {
                        // Während der Verarbeitung komplett gesperrt (Befund S11).
                        Group {
                            Button("Nur diese Seite auswählen") {
                                vm.tapSelect(item)
                                lastAnchorID = item.id
                            }
                            Divider()
                            Button("Nach links drehen") {
                                vm.ensureContextSelection(item)
                                vm.rotateSelectedPages(by: 270)
                            }
                            Button("Nach rechts drehen") {
                                vm.ensureContextSelection(item)
                                vm.rotateSelectedPages(by: 90)
                            }
                            Divider()
                            Button("Auswahl extrahieren …") {
                                vm.ensureContextSelection(item)
                                vm.extractSelectedPages()
                            }
                            Divider()
                            Button("Seite löschen", role: .destructive) {
                                vm.ensureContextSelection(item)
                                vm.deleteSelectedPages()
                            }
                        }
                        .disabled(vm.isProcessing)
                    }
                    .opacity(draggingIDs.contains(item.id) ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.12), value: draggingIDs)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: CellFramesKey.self,
                                                   value: [item.id: geo.frame(in: .named("grid"))])
                        }
                    )
            }
        }
        .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
        // Tastatur (Befund S10): Pfeiltasten bewegen die Auswahl, ⇧ erweitert
        // sie. Das System-⌘A beantwortet die View oben (`selectAll`).
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in moveSelection(direction) }
        // `onMoveCommand` kommt nur an, wenn das Raster den Tastaturfokus
        // hält – das tat es in der Sichtabnahme (2026-10-12, M4) auch nach
        // einem Klick nicht, die Pfeiltasten blieben ohne Wirkung. Die
        // Pfeiltasten hängen deshalb zusätzlich am Fenster.
        .background(ArrowKeyCatcher(isEnabled: vm.outcome == nil && !vm.isProcessing
                                        && !vm.project.pages.isEmpty) { direction in
            moveSelection(direction)
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Seiten")
    }

    // MARK: - Tastatur (Befund S10)

    /// Spalten des adaptiven Rasters aus den gemessenen Kachelrahmen: alle
    /// Kacheln der ersten Zeile.
    private var gridColumns: Int {
        let frames = vm.project.pages.compactMap { cellFrames[$0.id] }
        guard let top = frames.map(\.minY).min() else { return 1 }
        return max(frames.filter { abs($0.minY - top) < 1 }.count, 1)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let pages = vm.project.pages
        guard !pages.isEmpty else { return }
        let anchorIndex = pages.firstIndex { $0.id == lastAnchorID }
            ?? pages.lastIndex { vm.selectedPageIDs.contains($0.id) }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -gridColumns
        case .down: step = gridColumns
        @unknown default: return
        }
        let target: Int
        if let anchorIndex {
            target = min(max(anchorIndex + step, 0), pages.count - 1)
        } else {
            target = step > 0 ? 0 : pages.count - 1
        }
        let item = pages[target]
        if NSEvent.modifierFlags.contains(.shift) {
            // Bereich vom ersten Anker aus erweitern.
            let origin = vm.selectedPageIDs.isEmpty ? nil
                : (pages.first { vm.selectedPageIDs.contains($0.id) }?.id)
            vm.rangeSelect(to: item, anchor: origin ?? lastAnchorID)
        } else {
            vm.tapSelect(item)
        }
        lastAnchorID = item.id
    }

    // MARK: - Einheitlicher Click/Drag-Handler (Review §6)

    /// EIN Gesture-Handler pro Kachel statt konkurrierender Tap-Gesten:
    /// MouseDown cappt die Modifier-Keys (kleine AppKit-Bridge über NSEvent),
    /// am Ende entscheidet die Bewegungsdistanz zwischen Click und Drag.
    private func pageGesture(for item: PageItem) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("grid"))
            .onChanged { value in
                if pendingClickID == nil && draggingIDs.isEmpty {
                    pendingClickID = item.id
                    // Modifier beim MouseDown cappen – hier sind sie garantiert gültig.
                    pendingClickModifiers = NSEvent.modifierFlags
                }
                guard pendingClickID == item.id || draggingIDs.contains(item.id) else { return }

                let dx = value.translation.width.magnitude
                let dy = value.translation.height.magnitude
                if draggingIDs.isEmpty, dx >= 6 || dy >= 6 {
                    startDrag(for: item)
                }
                guard !draggingIDs.isEmpty else { return }
                pointerX = value.location.x
                pointerViewportY = value.location.y - contentOffsetY
                dragInsertIndex = insertionIndex(at: value.location)
            }
            .onEnded { _ in
                if draggingIDs.isEmpty {
                    // Kein Drag passiert → Click mit den gecappten Modifiern auswerten.
                    if let clicked = pendingClickID,
                       let clickedItem = vm.project.pages.first(where: { $0.id == clicked }) {
                        handlePageClick(clickedItem, modifiers: pendingClickModifiers)
                    }
                    pendingClickID = nil
                    pendingClickModifiers = []
                    dragInsertIndex = nil
                } else {
                    finishDrag()
                }
            }
    }

    /// Eine Quelle der Wahrheit für Selection (Review §6).
    private func handlePageClick(_ item: PageItem, modifiers: NSEvent.ModifierFlags) {
        gridFocused = true
        if modifiers.contains(.shift) {
            vm.rangeSelect(to: item, anchor: lastAnchorID)
            if lastAnchorID == nil { lastAnchorID = item.id }
            return
        }
        if modifiers.contains(.command) {
            vm.cmdToggle(item)
            if lastAnchorID == nil { lastAnchorID = item.id }
            return
        }
        vm.tapSelect(item)
        lastAnchorID = item.id
    }

    /// Mac-Konvention: Ziehen einer nicht selektierten Seite verschiebt nur diese;
    /// Ziehen innerhalb einer Mehrfachauswahl bewegt die ganze Gruppe (§9).
    private func startDrag(for item: PageItem) {
        let group: [PageItem]
        if vm.selectedPageIDs.contains(item.id), vm.selectedPageIDs.count > 1 {
            group = vm.orderedSelection
        } else {
            vm.tapSelect(item)
            lastAnchorID = item.id
            group = [item]
        }
        draggingIDs = group.map(\.id)
        pendingClickID = nil
        pendingClickModifiers = []

        let lead = group[0]
        Task { @MainActor in
            dragPreviewThumb = await ThumbnailService.shared.thumbnail(
                sourceID: lead.sourceDocumentID,
                url: lead.sourceURL,
                pageIndex: lead.sourcePageIndex,
                additionalRotation: lead.rotation,
                pixelHeight: 260)
        }
        startAutoScroll()
    }

    private func finishDrag() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        defer {
            draggingIDs = []
            dragPreviewThumb = nil
            dragInsertIndex = nil
            pendingClickID = nil
            pendingClickModifiers = []
        }
        guard let target = dragInsertIndex else { return }
        vm.movePages(draggingIDs, to: target)
    }

    // MARK: - Auto-Scroll am oberen/unteren Rand (Phase 7)

    private func startAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard !draggingIDs.isEmpty else { break }

                let edgeMargin: CGFloat = 72
                let step: CGFloat = 30
                var delta: CGFloat = 0
                if pointerViewportY < edgeMargin {
                    delta = -step
                } else if pointerViewportY > viewportHeight - edgeMargin {
                    delta = step
                } else {
                    continue
                }

                scrollPosition.scrollTo(y: max(0, contentOffsetY + delta))
                // Finger ruht horizontal unverändert; Content-Y unter dem Finger
                // verschiebt sich um den gescrollten Betrag.
                let contentUnderFinger = CGPoint(x: pointerX,
                                                 y: pointerViewportY + contentOffsetY)
                dragInsertIndex = insertionIndex(at: contentUnderFinger)
            }
        }
    }

    /// Schwebender Stapel-Preview, der dem Zeiger folgt (§19).
    private var dragPreview: some View {
        ZStack {
            if draggingIDs.count > 1 { previewCard(shift: CGSize(width: -9, height: -9), opacity: 0.45) }
            if !draggingIDs.isEmpty { previewCard(shift: CGSize(width: -4.5, height: -4.5), opacity: 0.7) }
            if !draggingIDs.isEmpty {
                previewCard(shift: .zero, opacity: 1)
                    .overlay(alignment: .bottomTrailing) {
                        if draggingIDs.count > 1 {
                            Text("+\(draggingIDs.count - 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor))
                                .padding(6)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
        .position(x: pointerX, y: pointerViewportY)
        .opacity(draggingIDs.isEmpty ? 0 : 1)
        .animation(.easeInOut(duration: 0.1), value: draggingIDs.isEmpty)
    }

    private func previewCard(shift: CGSize, opacity: Double) -> some View {
        Group {
            if let dragPreviewThumb {
                Image(nsImage: dragPreviewThumb)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: "doc.richtext")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 104, height: 132)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        .opacity(opacity)
        .offset(shift)
    }

    private func insertionIndex(at point: CGPoint) -> Int {
        guard !vm.project.pages.isEmpty else { return 0 }

        for (i, item) in vm.project.pages.enumerated() {
            if let frame = cellFrames[item.id], frame.contains(point) {
                return point.x < frame.midX ? i : i + 1
            }
        }

        var nearest = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, item) in vm.project.pages.enumerated() {
            guard let frame = cellFrames[item.id] else { continue }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let dx = point.x - center.x, dy = point.y - center.y
            let d = dx * dx + dy * dy
            if d < bestDistance {
                bestDistance = d
                nearest = point.x < frame.midX ? i : i + 1
            }
        }
        return nearest
    }

    // MARK: - Selection Bar (Footer)

    /// Selection-Aktionen leben unten – nah am Zustand, statt disabled Icons oben (§15–§17).
    private var footerStrip: some View {
        HStack(spacing: 10) {
            Text("\(vm.selectedPageIDs.count) ausgewählt")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            if !vm.selectedPageIDs.isEmpty {
                Divider()
                    .frame(height: 14)

                Button { vm.moveSelectionLeft() } label: {
                    Label("Auswahl nach links verschieben", systemImage: "chevron.left")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!vm.canMoveLeft())
                .help("Auswahl nach links verschieben")

                Button { vm.moveSelectionRight() } label: {
                    Label("Auswahl nach rechts verschieben", systemImage: "chevron.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!vm.canMoveRight())
                .help("Auswahl nach rechts verschieben")

                Button { vm.rotateSelectedPages(by: 270) } label: {
                    Label("Auswahl nach links drehen", systemImage: "rotate.left")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Auswahl nach links drehen")

                Button { vm.rotateSelectedPages(by: 90) } label: {
                    Label("Auswahl nach rechts drehen", systemImage: "rotate.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Auswahl nach rechts drehen")

                // §65 Feature 1: Auswahl als eigene PDF exportieren.
                Button {
                    vm.extractSelectedPages()
                } label: {
                    Text("Extrahieren …")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .disabled(vm.isProcessing)
                .help("Ausgewählte Seiten als eigene PDF sichern")

                Button(role: .destructive) { vm.deleteSelectedPages() } label: {
                    Text("Löschen")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }

        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        // Haarlinie: Glas auf weißer Fläche hat sonst keine Kante.
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
        .animation(.easeInOut(duration: 0.15), value: vm.selectedPageIDs.isEmpty)
    }

    // MARK: - Ergebnis (Befund S4)

    /// Dasselbe Muster wie Komprimieren, Konvertieren und OCR: links die
    /// erzeugte PDF in der nativen Vorschau, rechts das Pult mit Kennzahlen,
    /// Sichern, „Mit Smart komprimieren" und dem Weg zurück zu den Seiten.
    private func outcomeState(_ o: MergeViewModel.MergeOutcome) -> some View {
        ToolWorkspace {
            DocumentPreview(url: vm.savedURL ?? o.url, scanning: vm.isProcessing)
        } panel: {
            VStack(alignment: .leading, spacing: 20) {
                PanelHeader(title: o.kind.title,
                            subtitle: "\(Counted.pages(o.pageCount)) · \(CompressionResult.format(o.outputBytes))",
                            closeDisabled: vm.isProcessing,
                            onClose: leaveOutcome)
                Divider()

                // „X % kleiner“ nur beim Merge – beim Extract wurden Seiten entfernt,
                // nicht komprimiert (Review #5).
                if o.kind.showsSizeComparison {
                    VStack(alignment: .leading, spacing: 2) {
                        // Erst ab einem gerundeten Prozent: „0 % kleiner" in
                        // Grün las sich wie ein Ergebnis (Sichtabnahme
                        // 2026-10-12, L2).
                        if Double(o.outputBytes) <= Double(o.combinedInputBytes) * 0.995 {
                            Text("\(Int(((1 - Double(o.outputBytes) / Double(max(o.combinedInputBytes, 1))) * 100).rounded())) % kleiner")
                                .font(Theme.figure)
                                .foregroundStyle(Theme.savings)
                            Text("\(CompressionResult.format(o.combinedInputBytes)) → \(CompressionResult.format(o.outputBytes))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text(CompressionResult.format(o.outputBytes))
                                .font(Theme.figure)
                            Text("Summe der Originale: \(CompressionResult.format(o.combinedInputBytes))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    // Befund A4 (Review 2026-10-09): Was das Zusammenführen NICHT
                    // mitnimmt, stand nirgends. Die Grenzen liegen in der Assembly
                    // (PageAssemblyService: Lesezeichen nur erste Ebene und nur bei
                    // einer Quelle, Seitenbeschriftungen nur bei einer Quelle; die
                    // Bridge kopiert keine Dateianhänge, XMP-Metadaten, Tag-Struktur
                    // oder Ebenen). Ehrlich sagen statt still verlieren.
                    Text("Übernommen: Seiten, Anmerkungen, Links und Formularfelder. Nicht übernommen: Dateianhänge, XMP-Metadaten, Tag-Struktur und Ebenen. Lesezeichen nur die erste Ebene und Seitenbeschriftungen nur, wenn alle Seiten aus einer Datei stammen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = vm.errorMessage {
                    InlineNotice(message: error, onDismiss: { vm.errorMessage = nil })
                }

                if vm.isProcessing {
                    WorkProgressBar(progress: vm.progress,
                                    label: vm.processingLabel,
                                    isCancelling: vm.isCancelling,
                                    onCancel: { vm.cancelProcessing() })
                } else if let saved = vm.savedURL {
                    SavedResultBlock(urls: [saved])
                } else {
                    VStack(spacing: 8) {
                        // ⌘S liegt im Ablage-Menü (Commands.swift, Befund S15).
                        Button {
                            vm.saveOutcome(o)
                        } label: {
                            Text("Sichern …").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button {
                            if let handoff = vm.handOffOutcome(o) { onCompress?(handoff) }
                        } label: {
                            Text("Komprimieren …").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .help("Die zusammengestellte PDF im Werkzeug „Komprimieren“ öffnen")
                    }
                }

                Button("Zurück zu den Seiten", action: leaveOutcome)
                    .buttonStyle(.borderless)
                    .disabled(vm.isProcessing)
            }
        }
    }

    private func leaveOutcome() {
        guard let o = vm.outcome else { return }
        if vm.savedURL == nil {
            try? FileManager.default.removeItem(at: o.url)
        }
        vm.outcome = nil
        vm.savedURL = nil
        vm.errorMessage = nil
    }
}

/// Umbrechende Zeile (für die Dokument-Legende): Elemente laufen nach
/// rechts und brechen am Rand um – wie ein Textabsatz.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + lineHeight), origins)
    }
}

// MARK: - Seitenkachel

struct PageCellView: View {
    let item: PageItem
    /// Dateiname – nur am Beginn eines Dokumentblocks (sonst nil).
    var documentLabel: String? = nil
    /// Farbpunkt des Quelldokuments, nur bei mehreren Dokumenten.
    var documentColor: Color? = nil
    let isSelected: Bool
    let showLeadingIndicator: Bool
    let showTrailingIndicator: Bool
    let service: ThumbnailService
    /// „Seite 3 von 12" – Position im Projekt für VoiceOver (Befund S10).
    var positionLabel: String? = nil
    var onRotate: ((Int) -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var thumb: NSImage?

    private var rotationText: String? {
        item.rotation == 0 ? nil : String(localized: "um \(item.rotation)° gedreht")
    }

    private var accessibilityDescription: String {
        var parts = [positionLabel ?? String(localized: "Seite \(item.sourcePageIndex + 1)")]
        parts.append(String(localized: "aus \(item.sourceURL.lastPathComponent)"))
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 170)

            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    if let documentColor {
                        Circle().fill(documentColor).frame(width: 7, height: 7)
                    }
                    Text("Seite \(item.sourcePageIndex + 1)")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    // Die Miniatur ist bereits gedreht gerendert; statt einer
                    // Kapsel nur ein stilles Symbol (Befund G3).
                    if item.rotation != 0 {
                        Image(systemName: "rotate.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                // Feste Höhe, damit Kacheln mit und ohne Namen gleich hoch sind.
                Text(documentLabel ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear,
                              lineWidth: 2)
        )
        .overlay(alignment: .leading) {
            if showLeadingIndicator {
                Capsule().fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
        .overlay(alignment: .trailing) {
            if showTrailingIndicator {
                Capsule().fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
        .help(rotationText.map { String(localized: "Seite \(item.sourcePageIndex + 1) · \($0)") }
              ?? String(localized: "Seite \(item.sourcePageIndex + 1)"))
        .task(id: item.id) { await reloadThumb() }
        .onChange(of: item.rotation) { _, _ in Task { await reloadThumb() } }
        // VoiceOver (Befund S10): ein Element je Kachel mit Name, Zustand
        // und den wichtigsten Aktionen.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityValue([isSelected ? String(localized: "ausgewählt") : nil, rotationText]
                                .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Nach rechts drehen") { onRotate?(90) }
        .accessibilityAction(named: "Nach links drehen") { onRotate?(270) }
        .accessibilityAction(named: "Löschen") { onDelete?() }
    }

    private func reloadThumb() async {
        thumb = await service.thumbnail(sourceID: item.sourceDocumentID,
                                        url: item.sourceURL,
                                        pageIndex: item.sourcePageIndex,
                                        additionalRotation: item.rotation)
    }
}

/// Unterscheidbare Farben für Quelldokumente (Legende im Kopf + Seitenpunkt).
enum DocumentPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

// MARK: - Pfeiltasten (M4)

/// Fängt die Pfeiltasten des Fensters, solange das Seitenraster zu sehen
/// ist. Nicht während ein Textfeld schreibt, ein Sheet offen ist oder ⌘/⌥/⌃
/// gedrückt sind – dort gehören die Tasten jemand anderem.
private struct ArrowKeyCatcher: NSViewRepresentable {
    let isEnabled: Bool
    let onMove: (MoveCommandDirection) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.isEnabled = isEnabled
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.isEnabled = isEnabled
        view.onMove = onMove
    }

    final class CatcherView: NSView {
        var isEnabled = false
        var onMove: (MoveCommandDirection) -> Void = { _ in }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handles(event) else { return event }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func handles(_ event: NSEvent) -> Bool {
            guard isEnabled, let window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil,
                  !(window.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            else { return false }
            let direction: MoveCommandDirection
            switch event.keyCode {
            case 123: direction = .left
            case 124: direction = .right
            case 125: direction = .down
            case 126: direction = .up
            default: return false
            }
            onMove(direction)
            return true
        }
    }
}
