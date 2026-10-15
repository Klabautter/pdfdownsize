import SwiftUI
import UniformTypeIdentifiers
import PDFKit

/// Komprimieren – das Hauptwerkzeug.
///
/// Das Dokument füllt die Fläche wie in Vorschau. Darüber schweben zwei
/// Glaselemente: rechts das Pult (Datei, Modus, Größe, Aktion), unten die
/// Seitenleiste mit ALLEN Seiten – sie macht sichtbar, dass immer das ganze
/// Dokument komprimiert wird, auch wenn groß nur eine Seite zu sehen ist.
struct CompressionView: View {
    @ObservedObject var viewModel: CompressionViewModel
    /// Abgelegte Bilder gehören zu Konvertieren – RootView wechselt dorthin,
    /// statt dass die Fläche „nur PDF" meldet.
    var onForeignFiles: (([URL]) -> Void)? = nil
    @EnvironmentObject private var discardGuard: DiscardGuard

    @State private var isTargeted = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                handleDrop(urls)
            } isTargeted: { targeted in
                isTargeted = targeted
            }
            // „Eigene" liegt IM Pult (Befund Sichtabnahme 2026-10-12): Der
            // frühere Inspector schob das Dokument nach links und legte ein
            // zweites Paneel neben das Pult.
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Nur mit geöffneter Datei/Liste: Auf dem Startbildschirm
                    // übernimmt „PDFs auswählen …" in der Mitte diese Rolle.
                    if viewModel.inputURL != nil || !viewModel.bulkInputs.isEmpty {
                        Button {
                            discardGuard.run(ifUnsaved: viewModel.hasUnsavedResult) {
                                viewModel.addFiles()
                            }
                        } label: {
                            Label("Weitere PDFs hinzufügen", systemImage: "plus")
                        }
                        .disabled(viewModel.isWorking)
                    }

                }
            }
            // onOpenURL liegt zentral auf RootView (Routing ins aktive Tool).
            .focusedSceneObject(viewModel)
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.bulkInputs.isEmpty {
            BulkStage(viewModel: viewModel, isTargeted: isTargeted)
        } else if viewModel.inputURL == nil {
            WorkspaceWelcome(icon: "doc.zipper",
                             title: String(localized: "PDFs komprimieren"),
                             subtitle: String(localized: "Eine PDF oder gleich mehrere – alles bleibt auf dem Mac."),
                             dropHint: String(localized: "Dateien auch hierher ziehen"),
                             isTargeted: isTargeted) {
                // ⌘O liegt im Ablage-Menü (Commands.swift) – nicht doppelt
                // vergeben (Befund B13).
                Button("PDFs auswählen …") { viewModel.chooseFiles() }
                    .buttonStyle(.borderedProminent)
                if let error = viewModel.errorMessage {
                    InlineNotice(message: error)
                        .frame(maxWidth: 360)
                }
            }
        } else {
            SingleStage(viewModel: viewModel, isTargeted: isTargeted)
        }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else {
            let images = urls.filter { ImageImporter.isSupported($0) }
            if !images.isEmpty, let onForeignFiles {
                onForeignFiles(images)
            } else {
                viewModel.errorMessage = String(localized: "Bitte nur PDF-Dateien ablegen.")
            }
            return true
        }
        // Auf eine geöffnete Datei oder Liste abgelegt: hinzufügen statt ersetzen.
        discardGuard.run(ifUnsaved: viewModel.hasUnsavedResult) {
            if viewModel.inputURL != nil || !viewModel.bulkInputs.isEmpty {
                viewModel.add(pdfs)
            } else if pdfs.count == 1, let url = pdfs.first {
                viewModel.select(url)
            } else {
                viewModel.selectMany(pdfs)
            }
        }
        return true
    }
}

// MARK: - Einzeldokument

private struct SingleStage: View {
    @ObservedObject var viewModel: CompressionViewModel
    let isTargeted: Bool

    @State private var compareFraction: Double = 0.5

    private var pending: CompressionResult? { viewModel.pendingResult }
    private var showsCompare: Bool {
        if let pending, !pending.alreadyOptimized { return true }
        return false
    }
    private var pageCount: Int { viewModel.estimate?.pageCount ?? 0 }

    var body: some View {
        // Dasselbe Layout wie Konvertieren und OCR (Befund S5): Pult rechts
        // im ScrollView, Dokument links, Seitenleiste unten auf der Fläche.
        ToolWorkspace {
            ZStack(alignment: .bottom) {
                page
                    .padding(.top, 28)
                    .padding(.horizontal, 32)
                    .padding(.bottom, pageCount > 1 ? 112 : 28)
                if pageCount > 1 {
                    PageStrip(thumbs: viewModel.pageThumbnails,
                              sampleCount: min(pageCount, CompressionViewModel.samplePageCount),
                              pageCount: pageCount,
                              selected: viewModel.selectedPage,
                              caption: stripCaption,
                              onSelect: { viewModel.showPage($0) })
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
            }
        } panel: {
            ControlPanel(viewModel: viewModel, part: .settings)
        } footer: {
            ControlPanel(viewModel: viewModel, part: .action)
                .padding(.top, 20)
        }
        .dropTargetOverlay(isTargeted)
        .task(id: pending?.outputURL) {
            if showsCompare {
                compareFraction = 0.5
                viewModel.loadCompressedDocument()
            }
        }
    }

    private var stripCaption: String {
        let position = String(localized: "Seite \(viewModel.selectedPage + 1) von \(pageCount)")
        if showsCompare || viewModel.result != nil {
            return String(localized: "Alle \(pageCount) Seiten komprimiert · \(position)")
        }
        if viewModel.isWorking { return String(localized: "Alle \(pageCount) Seiten werden komprimiert") }
        return position
    }

    @ViewBuilder
    private var page: some View {
        if let original = viewModel.originalDocument {
            DocumentStage(original: original,
                          compressed: showsCompare ? viewModel.compressedDocument : nil,
                          pageIndex: viewModel.selectedPage,
                          scanning: viewModel.isWorking,
                          fraction: $compareFraction,
                          onPageChange: { viewModel.showPage($0) })
        } else {
            PaperSheet(image: nil)
        }
    }
}

// MARK: - Pult

private struct ControlPanel: View {
    @ObservedObject var viewModel: CompressionViewModel
    @EnvironmentObject private var discardGuard: DiscardGuard
    @State private var showOptions = false

    private var pending: CompressionResult? { viewModel.pendingResult }
    private var finished: CompressionResult? { pending ?? viewModel.result }
    private var originalBytes: Int64 {
        viewModel.inputURL.map { Compressor.fileSize(of: $0) } ?? 0
    }

    /// Das Pult besteht aus dem Inhalt, der bei Platzmangel scrollt, und der
    /// Aktion, die darunter stehen bleibt (`ToolWorkspace.footer`): In
    /// „Eigene" rutschte „Komprimieren" sonst unter den Fensterrand
    /// (Sichtabnahme 2026-10-12, M7).
    enum Part { case settings, action }
    var part: Part = .settings

    var body: some View {
        Group {
            switch part {
            case .settings:
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Divider()
                    if finished == nil {
                        modeSection
                        if viewModel.mode == .custom {
                            CustomSettingsPanel(viewModel: viewModel)
                        }
                    }
                    // In „Eigene" steht die Schätzung im festen Fuß über dem
                    // Knopf: Sie bleibt beim Regeln sichtbar und nichts
                    // verschiebt sich unter dem Zeiger (2026-10-13).
                    if !estimateInFooter {
                        sizeSection
                    }
                    if finished == nil {
                        optionsSection
                    }
                }
            case .action:
                VStack(alignment: .leading, spacing: 16) {
                    if estimateInFooter {
                        sizeSection
                    }
                    actionBar
                }
            }
        }
        // Kein Fokusring um das Glas-Pult (sah „viereckig" aus, sobald ein
        // Bedienelement den Fokus hatte).
        .focusEffectDisabled()
    }

    private var estimateInFooter: Bool {
        viewModel.mode == .custom && finished == nil
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: .pdf))
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.inputURL?.lastPathComponent ?? "")
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(viewModel.inputURL?.path ?? "")
                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Button {
                discardGuard.run(ifUnsaved: viewModel.hasUnsavedResult) {
                    viewModel.clearSingleSelection()
                }
            } label: {
                Label("Schließen", systemImage: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .imageScale(.large)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(viewModel.isWorking)
            .help("Schließen")
        }
    }

    private var metaLine: String {
        var parts = [CompressionResult.format(originalBytes)]
        if let e = viewModel.estimate {
            parts.append(Counted.pages(e.pageCount))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Modus

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Modus", selection: $viewModel.mode) {
                ForEach(CompressionMode.allCases) { m in
                    Text(Self.label(m)).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(viewModel.isWorking)

            Text(Self.purpose(viewModel.mode))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.hasSignature {
                Label("Digital signiert – die Signatur wird dabei ungültig.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    static func label(_ m: CompressionMode) -> String {
        m == .custom ? String(localized: "Eigene") : m.shortLabel
    }

    static func purpose(_ m: CompressionMode) -> String {
        switch m {
        case .small: return String(localized: "Zum Verschicken: so klein wie möglich, gut lesbar am Bildschirm.")
        case .smart: return String(localized: "Empfohlen: am Bildschirm kaum vom Original zu unterscheiden, deutlich kleiner.")
        case .quality: return String(localized: "Zum Drucken: Bilder behalten Druckauflösung.")
        case .custom: return String(localized: "Auflösung, Qualität und Technik selbst festlegen.")
        }
    }

    // MARK: Größe

    @ViewBuilder
    private var sizeSection: some View {
        let original = originalBytes
        VStack(alignment: .leading, spacing: 10) {
            if let r = finished {
                SizeReadout(original: original,
                            content: r.alreadyOptimized ? .alreadyOptimal : .result(r.outputBytes))
                if let target = r.targetRequestedBytes {
                    Label(CompressionViewModel.targetResultText(requested: target,
                                                               achieved: r.outputBytes,
                                                               met: r.targetMet ?? false),
                          systemImage: r.targetMet == true ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(r.targetMet == true ? Theme.savings : .orange)
                }
                if let hint = CompressionViewModel.qualityHintText(qaReplanCount: r.qaReplanCount,
                                                                   fallbackCount: r.qaFallbackCount) {
                    Text(hint).font(.footnote).foregroundStyle(.secondary)
                }
                if pending != nil {
                    Button("Mit anderem Modus versuchen") { viewModel.discardPending() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            } else if let e = viewModel.estimate {
                // Auch bei geringem Potenzial bleibt es eine Schätzung – „bereits
                // optimal" sagt erst ein echter Lauf (Formulare gewinnen oft
                // über Schriften/Struktur, die das Inventar-Modell nicht sieht).
                SizeReadout(original: original,
                            content: .estimate(point: e.pointBytes),
                            refreshing: viewModel.estimateRefreshing)
                if let assessment = viewModel.targetAssessment {
                    Label(CompressionViewModel.targetEstimateText(assessment), systemImage: "target")
                        .font(.callout)
                        .foregroundStyle(assessment.reachability == .notSafelyReachable
                                         ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            } else {
                SizeReadout(original: original, content: .estimating)
            }
        }
    }

    // MARK: Optionen

    private var optionsSection: some View {
        DisclosureGroup(isExpanded: $showOptions) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Höchstens") {
                    HStack(spacing: 6) {
                        TextField("", text: $viewModel.targetSizeText, prompt: Text("—"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
                .help(viewModel.mode == .custom
                      ? "Bei „Eigene“ gelten die festen Einstellungen; das Ziel kann sie nicht unterschreiten und dient nur als Rückmeldung."
                      : "Gewünschte Höchstgröße. Verkleinert so weit, wie es die Qualitätsgrenzen des Modus erlauben.")
                Toggle("Schnelles Laden im Web", isOn: $viewModel.linearizeForWeb)
                    .toggleStyle(.switch)
                    .help("Linearisiert das PDF, damit die erste Seite im Browser sofort erscheint.")
            }
            .padding(.top, 8)
            .disabled(viewModel.isWorking)
        } label: {
            HStack {
                Text("Optionen")
                if !showOptions, let summary = optionsSummary {
                    Spacer()
                    Text(summary).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }

    private var optionsSummary: String? {
        var parts: [String] = []
        if let bytes = viewModel.goalBytes { parts.append("≤ \(CompressionResult.format(bytes))") }
        if viewModel.linearizeForWeb { parts.append("Web") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: Aktion

    @ViewBuilder
    private var actionBar: some View {
        if viewModel.isWorking {
            WorkProgressBar(progress: viewModel.progressValue,
                            label: viewModel.progressLabel,
                            startedAt: viewModel.workStartedAt,
                            isCancelling: viewModel.isCancelling,
                            onCancel: { viewModel.cancelWork() })
        } else if let r = pending {
            if r.alreadyOptimized {
                Button { viewModel.discardPending() } label: {
                    Text("Fertig").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                HStack(spacing: 8) {
                    Button("Verwerfen") { viewModel.discardPending() }
                        .buttonStyle(.bordered)
                    // ⌘S liegt im Ablage-Menü (Commands.swift, Befund S15).
                    Button {
                        viewModel.savePending(r)
                    } label: {
                        Text("Sichern …").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
        } else if let saved = viewModel.result {
            SavedResultBlock(urls: [saved.outputURL],
                             followUp: (String(localized: "Weitere PDF öffnen …"), { viewModel.chooseFiles() }))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let error = viewModel.errorMessage {
                    InlineNotice(message: error)
                }
                Button {
                    viewModel.compress()
                } label: {
                    Text("Komprimieren").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canCompress)
                if viewModel.largeFileNotice != nil {
                    Text("Große Datei – das kann einige Minuten dauern.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .help(viewModel.largeFileNotice ?? "")
                }
            }
        }
    }
}

// MARK: - Größenanzeige

/// Größe als Zahl plus Leiste: volle Breite = Original. Vor dem Lauf EIN
/// geschätzter Wert (der Punktwert des Schätzers, keine Spanne – eine
/// Spanne liest sich wie Unsicherheit, 15.10.2026), danach das Ergebnis
/// auf demselben Maßstab.
struct SizeReadout: View {
    enum Content: Equatable {
        case estimating
        case estimate(point: Int64)
        case result(Int64)
        case alreadyOptimal
    }

    let original: Int64
    let content: Content
    var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headline
            bar.frame(height: 6)
        }
        .opacity(refreshing ? 0.5 : 1)
        .animation(.smooth(duration: 0.25), value: content)
        .accessibilityElement(children: .combine)
    }

    private func ratio(_ bytes: Int64) -> CGFloat {
        guard original > 0 else { return 0 }
        return CGFloat(min(max(Double(bytes) / Double(original), 0), 1))
    }

    private func percent(_ bytes: Int64) -> Int {
        guard original > 0 else { return 0 }
        return max(0, Int(((1 - Double(bytes) / Double(original)) * 100).rounded()))
    }

    /// „≈ 75 %" – der Punktwert, mit Tilde als Schätzung gekennzeichnet.
    static func estimateFigure(point: Int64, original: Int64) -> String {
        guard original > 0 else { return "—" }
        let pct = max(0, Int(((1 - Double(point) / Double(original)) * 100).rounded()))
        return "≈ \(pct) %"
    }

    @ViewBuilder
    private var headline: some View {
        switch content {
        case .estimating:
            VStack(alignment: .leading, spacing: 2) {
                Text("—").font(Theme.figure).foregroundStyle(.tertiary)
                Text("Wird geschätzt …").font(.callout).foregroundStyle(.secondary)
            }
        case .estimate(let point):
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.estimateFigure(point: point, original: original)) kleiner")
                    .font(Theme.figure)
                Text("Voraussichtlich \(CompressionResult.format(point))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .result(let output):
            VStack(alignment: .leading, spacing: 2) {
                Text("\(percent(output)) % kleiner")
                    .font(Theme.figure)
                    .foregroundStyle(Theme.savings)
                Text("\(CompressionResult.format(original)) → \(CompressionResult.format(output))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .alreadyOptimal:
            VStack(alignment: .leading, spacing: 2) {
                Label("Bereits optimal", systemImage: "checkmark.seal.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.savings)
                Text("Kaum weitere Verkleinerung möglich – das Original bleibt die beste Wahl.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                switch content {
                case .estimating:
                    EmptyView()
                case .estimate(let point):
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(w * ratio(point), 6))
                case .result(let output):
                    Capsule().fill(Theme.savings)
                        .frame(width: max(w * ratio(output), 6))
                case .alreadyOptimal:
                    Capsule().fill(Theme.savings.opacity(0.5))
                }
            }
        }
    }
}

// MARK: - Seitenleiste

/// Seitenleiste als Stichprobe: die ersten Seiten als Miniaturen, dazu
/// Vor/Zurück für alle weiteren. Früher lud sie JEDE Seite als Miniatur
/// (Speicher, Ruckeln beim Durchklicken großer Dokumente).
struct PageStrip: View {
    let thumbs: [Int: NSImage]
    let sampleCount: Int
    let pageCount: Int
    let selected: Int
    let caption: String
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(spacing: 8) {
                step(-1, symbol: "chevron.left", help: String(localized: "Vorherige Seite"))
                ForEach(0..<sampleCount, id: \.self) { index in
                    thumb(index)
                }
                if pageCount > sampleCount {
                    Text("…")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                step(1, symbol: "chevron.right", help: String(localized: "Nächste Seite"))
            }
            .frame(height: 52)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.panelRadius))
    }

    private func step(_ delta: Int, symbol: String, help: String) -> some View {
        let target = selected + delta
        return Button {
            onSelect(target)
        } label: {
            Label(help, systemImage: symbol)
                .frame(width: 22, height: 22)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(target < 0 || target >= pageCount)
        .help(help)
    }

    private func thumb(_ index: Int) -> some View {
        Button {
            onSelect(index)
        } label: {
            Group {
                if let image = thumbs[index] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    // Platzhalter, bis die Miniatur da ist – gedeckt statt weiß,
                    // damit nicht kurz leere Blätter aufblitzen (L5).
                    Rectangle().fill(.quaternary).aspectRatio(0.707, contentMode: .fit)
                }
            }
            .frame(height: 46)
            .overlay {
                Rectangle()
                    .strokeBorder(index == selected ? Color.accentColor : Color.primary.opacity(0.15),
                                  lineWidth: index == selected ? 2.5 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .help("Seite \(index + 1)")
        .accessibilityLabel("Seite \(index + 1)")
        .accessibilityAddTraits(index == selected ? .isSelected : [])
    }
}

// MARK: - Papier

/// Die gewählte Seite als Blatt auf der Fläche. Während der Arbeit ist sie
/// leicht abgedunkelt – der Fortschritt steht im Pult; kein eigener
/// Effekt, den kein Apple-Werkzeug zeigt (Befund G2).
struct PaperSheet: View {
    let image: NSImage?
    var scanning = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.white)
                    .aspectRatio(0.707, contentMode: .fit)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .opacity(scanning ? 0.85 : 1)
        .animation(.easeInOut(duration: 0.25), value: scanning)
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Vorher/Nachher direkt auf dem Blatt: links Original, rechts Ergebnis.
/// Die Seite in der nativen Ansicht: zoombar wie in Vorschau. Nach dem Lauf
/// zeigt sie den Vorher-Nachher-Vergleich mit Teiler; Zoom und Ausschnitt
/// sind auf beiden Seiten des Teilers identisch.
struct DocumentStage: View {
    let original: PDFDocument
    let compressed: PDFDocument?
    let pageIndex: Int
    var scanning = false
    @Binding var fraction: Double
    var highlight: String = ""
    var markedPages: Set<Int> = []
    var onPageChange: (Int) -> Void = { _ in }

    @State private var pageFrame: CGRect = .zero
    @State private var controller = CanvasController()

    private var comparing: Bool { compressed != nil }

    var body: some View {
        GeometryReader { geo in
            DocumentCanvas(original: original,
                           compressed: compressed,
                           pageIndex: pageIndex,
                           fraction: fraction,
                           highlight: highlight,
                           markedPages: markedPages,
                           controller: controller,
                           onPageChange: onPageChange,
                           onPageFrame: { pageFrame = $0 })
                .opacity(scanning ? 0.85 : 1)
                .animation(.easeInOut(duration: 0.25), value: scanning)
                .overlay(alignment: .topLeading) {
                    if comparing {
                        divider(in: geo.size)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if comparing {
                        // Marken sitzen am Blatt, nicht am Rand der Fläche
                        // (Sichtabnahme 2026-10-12: sie hingen weit darüber).
                        let page = visiblePage(in: geo.size)
                        HStack {
                            tag(String(localized: "Original"))
                            Spacer(minLength: 8)
                            tag(String(localized: "Komprimiert"))
                        }
                        .padding(10)
                        .frame(width: page.width)
                        .offset(x: page.minX, y: page.minY)
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    zoomControls.padding(10)
                }
                .coordinateSpace(.named("canvas"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(comparing ? "Vorher-Nachher-Vergleich" : "Seitenvorschau")
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }

    /// Sichtbarer Teil des Blatts in der Fläche (ohne Messung: die Fläche).
    private func visiblePage(in size: CGSize) -> CGRect {
        let area = CGRect(origin: .zero, size: size)
        guard !pageFrame.isEmpty else { return area }
        let visible = pageFrame.intersection(area)
        return visible.isNull ? area : visible
    }

    /// Teiler über die sichtbare Seitenhöhe; nur Linie und Griff nehmen
    /// Ziehen an – überall sonst zoomt und scrollt die Ansicht.
    private func divider(in size: CGSize) -> some View {
        let x = size.width * fraction
        let visible = visiblePage(in: size)
        let top = visible.minY
        let height = visible.height
        let drag = DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                fraction = min(max(value.location.x / max(size.width, 1), 0), 1)
            }
        return ZStack {
            // Weiße Linie mit dunkler Kontur: auf weißem Papier wie auf
            // dunklen Fotos zu sehen (Sichtabnahme 2026-10-12).
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: height)
                .padding(.horizontal, 0.5)
                .background(Color.black.opacity(0.35))
                .shadow(color: .black.opacity(0.3), radius: 2)
            Rectangle()
                .fill(Color.clear)
                .frame(width: 14, height: height)
                .contentShape(Rectangle())
            Image(systemName: "arrow.left.and.right")
                .font(.caption.weight(.bold))
                .frame(width: 30, height: 30)
                .glassEffect(.regular, in: .circle)
        }
        .position(x: x, y: top + height / 2)
        .gesture(drag)
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .accessibilityElement()
        .accessibilityLabel("Teiler")
        .accessibilityValue("\(Int(fraction * 100)) % Original")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: fraction = min(fraction + 0.1, 1)
            case .decrement: fraction = max(fraction - 0.1, 0)
            @unknown default: break
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            // Die Tooltips versprachen ⌘−/⌘+, es gab die Kürzel nicht
            // (Befund B13, Review 2026-10-09). Labels tragen zugleich den
            // VoiceOver-Namen (B14).
            Button { controller.zoomOut() } label: { Label("Verkleinern", systemImage: "minus.magnifyingglass") }
                .labelStyle(.iconOnly)
                .keyboardShortcut("-", modifiers: .command)
                .help("Verkleinern (⌘−)")
            Button { controller.fit() } label: { Label("Seite einpassen", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .labelStyle(.iconOnly)
                .keyboardShortcut("0", modifiers: .command)
                .help("Seite einpassen (⌘0)")
            Button { controller.zoomIn() } label: { Label("Vergrößern", systemImage: "plus.magnifyingglass") }
                .labelStyle(.iconOnly)
                .keyboardShortcut("+", modifiers: .command)
                .help("Vergrößern (⌘+)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Mehrere Dateien

private struct BulkRow: Identifiable {
    let index: Int
    let url: URL
    var id: URL { url }
}

private struct BulkStage: View {
    @ObservedObject var viewModel: CompressionViewModel
    @EnvironmentObject private var discardGuard: DiscardGuard
    let isTargeted: Bool

    /// Eingaben, deren Ergebnis gesichert wurde (Befund S9): Die Zeile
    /// zeigt dann „Gesichert" statt des Sichern-Links.
    @State private var savedInputs: Set<URL> = []
    /// Sichern-Fehler als System-Alert (Befunde M7/S6) – Aktionsfehler
    /// gehören nicht in eine Fußzeile.
    @State private var saveError: String?

    private var rows: [BulkRow] {
        viewModel.bulkInputs.enumerated().map { BulkRow(index: $0.offset, url: $0.element) }
    }

    private var allSaved: Bool {
        !viewModel.bulkResults.isEmpty
            && viewModel.bulkResultInputs.allSatisfy { savedInputs.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Table(rows) {
                TableColumn("Datei") { row in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(for: .pdf))
                            .resizable().frame(width: 20, height: 20)
                        Text(row.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                TableColumn("Seiten") { row in
                    Text(viewModel.bulkPageCounts[row.url].map(String.init) ?? "–")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(60)
                TableColumn("Größe") { row in
                    Text(CompressionResult.format(Compressor.fileSize(of: row.url)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(80)
                TableColumn("Ergebnis") { row in
                    outcome(row)
                }
                .width(min: 160, ideal: 220)
                TableColumn("") { row in
                    trailing(row)
                }
                .width(90)
            }
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .dropTargetOverlay(isTargeted)
        .onChange(of: viewModel.bulkResults.count) { _, _ in savedInputs = [] }
        .alert("Sichern fehlgeschlagen", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var totalInput: Int64 {
        viewModel.bulkInputs.reduce(0) { $0 + Compressor.fileSize(of: $1) }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.bulkInputs.count) PDFs")
                    .font(.title2.weight(.semibold))
                Text("\(CompressionResult.format(totalInput)) zusammen")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Picker("Modus", selection: $viewModel.mode) {
                ForEach(CompressionMode.allCases) { m in
                    Text(ControlPanel.label(m)).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .disabled(viewModel.isWorking || !viewModel.bulkResults.isEmpty)
            Button("Alle entfernen", role: .destructive) {
                discardGuard.run(ifUnsaved: viewModel.hasUnsavedResult) { viewModel.clearBulk() }
            }
                .buttonStyle(.bordered)
                .disabled(viewModel.isWorking)
        }
    }

    @ViewBuilder
    private func outcome(_ row: BulkRow) -> some View {
        let url = row.url
        if let r = viewModel.bulkResult(for: url) {
            Text(r.alreadyOptimized ? "Bereits optimal"
                 : "\(Int(r.savedPercent.rounded())) % kleiner · \(CompressionResult.format(r.outputBytes))")
                .foregroundStyle(Theme.savings)
                .monospacedDigit()
        } else if viewModel.bulkCancelledURLs.contains(url) {
            Text("Abgebrochen").foregroundStyle(.secondary)
        } else if let message = viewModel.bulkErrors[url] {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(message)
        } else if viewModel.isWorking {
            ProgressView(value: viewModel.bulkFractions[row.index] ?? 0)
                .progressViewStyle(.linear)
        } else if let e = viewModel.bulkEstimates[url] {
            Text("Voraussichtlich \(SizeReadout.estimateFigure(point: e.pointBytes, original: e.originalBytes)) kleiner")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Text("…").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func trailing(_ row: BulkRow) -> some View {
        let url = row.url
        if viewModel.bulkResult(for: url) != nil, !viewModel.isWorking {
            if savedInputs.contains(url) {
                Label("Gesichert", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.savings)
                    .font(.callout)
            } else {
                Button("Sichern …") { saveSingle(url) }
                    .buttonStyle(.link)
            }
        } else if viewModel.isWorking {
            if !viewModel.bulkCancelledURLs.contains(url), viewModel.bulkResult(for: url) == nil,
               viewModel.bulkErrors[url] == nil {
                Button { viewModel.cancelBulkFile(at: row.index) } label: {
                    Label("Diese Datei abbrechen", systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Diese Datei abbrechen – die übrigen laufen weiter")
            }
        } else {
            Button { viewModel.removeBulkInput(at: row.index) } label: {
                Label("Aus der Liste entfernen", systemImage: "minus.circle.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Aus der Liste entfernen")
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            if viewModel.isWorking {
                WorkProgressBar(progress: viewModel.progressValue,
                                label: viewModel.progressLabel,
                                startedAt: viewModel.workStartedAt,
                                isCancelling: viewModel.isCancelling,
                                compact: true,
                                onCancel: { viewModel.cancelWork() })
            } else if !viewModel.bulkResults.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(viewModel.bulkSavedPercent.rounded())) % kleiner")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.savings)
                    Text(viewModel.progressLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if allSaved {
                    // Nach dem Sichern dasselbe Muster wie im Pult (S9).
                    Label("Gesichert", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.savings)
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting(viewModel.bulkSavedURLs)
                    }
                    .buttonStyle(.bordered)
                } else {
                    if !viewModel.bulkSavedURLs.isEmpty {
                        Button("Im Finder zeigen") {
                            NSWorkspace.shared.activateFileViewerSelecting(viewModel.bulkSavedURLs)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Alle sichern …") { chooseFolderAndSave() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                if let error = viewModel.errorMessage {
                    InlineNotice(message: error)
                } else {
                    Text(ControlPanel.purpose(viewModel.mode))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Alle komprimieren") {
                    viewModel.compressAll(viewModel.bulkInputs)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.bulkInputs.isEmpty)
            }
        }
        .controlSize(.large)
    }

    private func saveSingle(_ url: URL) {
        let before = viewModel.bulkSavedURLs.count
        viewModel.saveBulkResult(for: url)
        if viewModel.bulkSavedURLs.count > before {
            savedInputs.insert(url)
        } else if let error = viewModel.errorMessage {
            viewModel.errorMessage = nil
            saveError = error
        }
    }

    private func chooseFolderAndSave() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Hier sichern")
        panel.message = String(localized: "Ordner für die komprimierten PDFs wählen")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            _ = try viewModel.saveAllBulk(to: folder)
            savedInputs.formUnion(viewModel.bulkResultInputs)
        } catch {
            // Teilerfolge stehen in bulkSavedURLs; der Fehler nennt den Rest.
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Eigene Einstellungen (im Pult)

/// Eigene Einstellungen als Zeilen im Pult. Werte ändern die Schätzung
/// sofort – sie ist ein Inventar-Modell und kostet nur Millisekunden.
///
/// Bewusst keine `Form(.columns)` mehr: Ihre Spalten richteten sich nicht
/// nach der Pultbreite (Abschnittstitel in der Wertespalte, Wert über dem
/// Regler), und leere Kontrollkästchen waren auf dem hellen Glas kaum zu
/// sehen (Sichtabnahme 2026-10-12). Jetzt: Titel links, Wert oder Schalter
/// rechts, Regler in voller Breite darunter.
private struct CustomSettingsPanel: View {
    @ObservedObject var viewModel: CompressionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group(String(localized: "Bilder")) {
                sliderRow(String(localized: "Auflösung"), value: String(localized: "\(Int(viewModel.customDPI)) DPI"),
                          help: String(localized: "72–96 Bildschirm · 150–220 Lesen (Smart: 220) · 300 Druck")) {
                    Slider(value: dpiPresetBinding,
                           in: 0...Double(CompressionViewModel.dpiPresets.count - 1),
                           step: 1) { Text("Auflösung") }
                }
                sliderRow(String(localized: "JPEG-Qualität"), value: "\(Int(viewModel.customQuality * 100)) %",
                          help: String(localized: "Gilt für Bilder, die verkleinert, umgefärbt oder aus verlustfreier Ablage neu kodiert werden. Vorhandene JPEGs innerhalb der Zielauflösung bleiben unverändert.")) {
                    Slider(value: $viewModel.customQuality, in: 0.4...0.95, step: 0.05) {
                        Text("JPEG-Qualität")
                    }
                }
                switchRow(String(localized: "Bildkante begrenzen"), isOn: $viewModel.customCapEnabled)
                if viewModel.customCapEnabled {
                    sliderRow(String(localized: "Längste Kante"), value: String(localized: "\(Int(viewModel.customMaxPixels).formatted()) px")) {
                        Slider(value: $viewModel.customMaxPixels, in: 800...4000, step: 100) {
                            Text("Längste Kante")
                        }
                    }
                }
                switchRow(String(localized: "Graustufen"), isOn: $viewModel.customForceGray)
                switchRow(String(localized: "Grafiken als JPEG"), isOn: $viewModel.customGraphicsJPEG,
                          help: String(localized: "Grafikflächen und Screenshots zusätzlich als JPEG kodieren"))
            }
            group(String(localized: "Dokument")) {
                switchRow(String(localized: "Metadaten entfernen"), isOn: $viewModel.customStripMetadata)
                pickerRow(String(localized: "Kompatibilität"),
                          help: String(localized: "„Maximal“ verzichtet auf Objekt-Streams und progressive JPEGs – für sehr alte Leser")) {
                    Picker("Kompatibilität", selection: $viewModel.customCompatibility) {
                        Text("Modern").tag(CompatibilityPolicy.modern)
                        Text("Maximal").tag(CompatibilityPolicy.maximum)
                    }
                }
            }
            group(String(localized: "Technik")) {
                // Nutzen statt Verfahren (Befund S16).
                switchRow(String(localized: "S/W-Scans verlustfrei"), isOn: bilevelRaceBinding,
                          help: String(localized: "Schwarz-Weiß-Scans ohne Qualitätsverlust packen – nur, wenn das Ergebnis kleiner ist"))
                switchRow(String(localized: "Schriften verkleinern"), isOn: $viewModel.customFontSubsetting,
                          help: String(localized: "Nur die benutzten Zeichen behalten – nur, wenn der Text kopierbar bleibt"))
                // Bei „Maximal" setzt der Planer den System-Kodierer (Baseline-
                // JPEG); das stand nirgends (Befund B2, Review 2026-10-09).
                pickerRow(String(localized: "JPEG-Kodierer"),
                          help: viewModel.customCompatibility == .maximum
                            ? String(localized: "Bei Kompatibilität „Maximal“ wird immer der System-Kodierer verwendet (Baseline-JPEG).")
                            : String(localized: "mozJPEG: kleinere Dateien bei gleicher Qualität. System: Kodierer von macOS.")) {
                    Picker("JPEG-Kodierer", selection: $viewModel.customJPEGBackend) {
                        Text("mozJPEG").tag(JPEGBackend.mozjpeg)
                        Text("System").tag(JPEGBackend.imageIO)
                    }
                    .disabled(viewModel.customCompatibility == .maximum)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                // Ein Weg zurück zu sinnvollen Werten (Befund S16): die
                // Bildwerte von Smart, Technik auf Werkseinstellung.
                Button("Auf Smart-Werte zurücksetzen") { resetToSmart() }
                    .buttonStyle(.link)
                // Ehrlich zur Sofort-Schätzung (Befund B5, Review 2026-10-09).
                Text("Die Sofort-Schätzung folgt Auflösung, Bildkante und Qualität. Graustufen und Grafik-JPEG wirken erst im Lauf.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: viewModel.currentOptions) { _, _ in viewModel.refreshEstimate() }
    }

    // MARK: Zeilen

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// Titel links, Wert rechts, Regler in voller Breite darunter.
    private func sliderRow<S: View>(_ title: String, value: String, help: String = "",
                                    @ViewBuilder slider: () -> S) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)   // der Regler trägt Titel und Wert selbst
            slider()
                .labelsHidden()
                .accessibilityValue(value)
        }
        .help(help)
    }

    /// Titel links, Schalter rechts – auf hellem wie dunklem Glas eindeutig.
    private func switchRow(_ title: String, isOn: Binding<Bool>, help: String = "") -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .accessibilityLabel(title)
        .help(help)
    }

    private func pickerRow<P: View>(_ title: String, help: String = "",
                                    @ViewBuilder picker: () -> P) -> some View {
        HStack {
            Text(title)
                .accessibilityHidden(true)   // die Auswahl trägt den Titel selbst
            Spacer(minLength: 8)
            picker()
                .labelsHidden()
                .fixedSize()
        }
        .help(help)
    }

    /// Die Smart-Bildwerte (`ImageCompressionOptions.smart`) plus die
    /// Werkseinstellungen der Technik-Politiken.
    private func resetToSmart() {
        let smart = ImageCompressionOptions.smart
        viewModel.customDPI = Double(CompressionViewModel.dpiPresets[
            CompressionViewModel.nearestDPIIndex(smart.targetDPI)])
        viewModel.customQuality = min(max(smart.jpegQuality, 0.4), 0.95)
        viewModel.customCapEnabled = false
        viewModel.customForceGray = false
        viewModel.customGraphicsJPEG = false
        viewModel.customStripMetadata = false
        viewModel.customCompatibility = .modern
        viewModel.customJPEGBackend = .mozjpeg
        viewModel.customBilevelPolicy = .auto
        viewModel.customFontSubsetting = false
    }

    private var bilevelRaceBinding: Binding<Bool> {
        Binding {
            viewModel.customBilevelPolicy == .auto
        } set: { newValue in
            viewModel.customBilevelPolicy = newValue ? .auto : .keep
        }
    }

    /// Slider rastet auf sinnvolle Standard-DPI-Werte ein (§14–§15).
    private var dpiPresetBinding: Binding<Double> {
        Binding {
            let index = CompressionViewModel.dpiPresets.firstIndex(of: Int(viewModel.customDPI))
                ?? CompressionViewModel.nearestDPIIndex(viewModel.customDPI)
            return Double(index)
        } set: { newValue in
            let index = min(Int(newValue.rounded()), CompressionViewModel.dpiPresets.count - 1)
            viewModel.customDPI = Double(CompressionViewModel.dpiPresets[index])
        }
    }
}

#Preview {
    CompressionView(viewModel: CompressionViewModel())
        .environmentObject(DiscardGuard())
}
