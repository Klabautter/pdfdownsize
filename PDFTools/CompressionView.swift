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
    /// B4: Vorher/Nachher einer fertigen Stapelzeile (Doppelklick).
    @State private var bulkComparison: URL?

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
                            // N14 (B1): erst wählen und prüfen, dann fragen.
                            let urls = CompressionViewModel.pickPDFs(prompt: String(localized: "Hinzufügen"))
                            guard !urls.isEmpty else { return }
                            discardGuard.runAfterProbe(urls, ifUnsaved: viewModel.hasUnsavedResult) {
                                viewModel.add(urls)
                            }
                        } label: {
                            Label("Weitere PDFs hinzufügen", systemImage: "plus")
                        }
                        .disabled(viewModel.isWorking)
                    }

                }
            }
            // Sichern-Fehler des Stapels (⌘S oder Knopf). N28: Hier statt an
            // der Stapelliste – sonst blieb ⌘S in der Vorher/Nachher-Ansicht
            // einer Stapelzeile ohne sichtbaren Fehler.
            .alert("Sichern fehlgeschlagen", isPresented: Binding(
                get: { viewModel.bulkSaveError != nil },
                set: { if !$0 { viewModel.bulkSaveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.bulkSaveError ?? "")
            }
            // onOpenURL liegt zentral auf RootView (Routing ins aktive Tool).
            .focusedSceneObject(viewModel)
    }

    @ViewBuilder
    private var content: some View {
        if let compared = bulkComparison, viewModel.bulkResult(for: compared) != nil {
            BulkComparisonStage(viewModel: viewModel, input: compared,
                                onBack: { bulkComparison = nil })
        } else if !viewModel.bulkInputs.isEmpty {
            BulkStage(viewModel: viewModel, isTargeted: isTargeted,
                      onCompare: { bulkComparison = $0 })
        } else if viewModel.inputURL == nil {
            WorkspaceWelcome(icon: "doc.zipper",
                             title: String(localized: "PDFs komprimieren"),
                             subtitle: String(localized: "Eine PDF oder gleich mehrere."),
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
        } else if let verdict = viewModel.rejection, let url = viewModel.inputURL {
            RejectedDocumentView(fileName: url.lastPathComponent, verdict: verdict,
                                 onChooseOther: { viewModel.chooseFiles() },
                                 onClose: { viewModel.clearSingleSelection() },
                                 onUnlock: { viewModel.unlock(password: $0) },
                                 passwordError: viewModel.passwordError,
                                 isUnlocking: viewModel.isUnlocking)
                .dropTargetOverlay(isTargeted, inset: 12)
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
        discardGuard.runAfterProbe(pdfs, ifUnsaved: viewModel.hasUnsavedResult) {
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
    /// Solange das Zielgrößen-Feld den Fokus hat, ist Return KEIN
    /// „Komprimieren" (Rundgang 2026-10-15: Bestätigen startete den Lauf).
    @FocusState private var targetFieldFocused: Bool

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
        } header: {
            ControlPanel(viewModel: viewModel, part: .header,
                         targetFieldFocused: $targetFieldFocused)
                .padding(.bottom, 20)
        } panel: {
            ControlPanel(viewModel: viewModel, part: .settings,
                         targetFieldFocused: $targetFieldFocused)
        } footer: {
            ControlPanel(viewModel: viewModel, part: .action,
                         targetFieldFocused: $targetFieldFocused)
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
    private var originalBytes: Int64 { viewModel.inputFileSize }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Das Pult besteht aus dem Inhalt, der bei Platzmangel scrollt, und der
    /// Aktion, die darunter stehen bleibt (`ToolWorkspace.footer`): In
    /// „Eigene" rutschte „Komprimieren" sonst unter den Fensterrand
    /// (Sichtabnahme 2026-10-12, M7).
    enum Part { case header, settings, action }
    var part: Part = .settings
    @FocusState.Binding var targetFieldFocused: Bool
    @Environment(\.panelScrollProxy) private var scrollProxy

    var body: some View {
        Group {
            switch part {
            case .header:
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Divider()
                }
            case .settings:
                VStack(alignment: .leading, spacing: 20) {
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
        // Masterplan F2: Der Fokusring bleibt – ohne ihn sah man per Tastatur
        // nicht, welches Bedienelement aktiv ist.
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
            // Vier gleich breite Segmente über die volle Pultbreite: Der
            // SwiftUI-Picker bemisst Segmente nach Inhalt (60/60/71/64 pt),
            // damit sprangen die Breiten mit der Auswahl (Rundgang
            // 2026-10-19). Dasselbe Systemcontrol, nur gleich verteilt.
            ModeSegments(mode: $viewModel.mode)
                .frame(maxWidth: .infinity)
                .disabled(viewModel.isWorking)

            Text(Self.purpose(viewModel.mode))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.hasSignature {
                Label("Digital signiert – die Signatur wird dabei ungültig.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.warningText)
            }
            if viewModel.pdfaPart > 0 {
                Label("PDF/A-Dokument: Die Kennzeichnung geht beim Komprimieren verloren.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    // Nicht erreicht ist eine Auskunft, kein Warnzeichen.
                    Label(CompressionViewModel.targetResultText(requested: target,
                                                               achieved: r.outputBytes,
                                                               met: r.targetMet ?? false),
                          systemImage: r.targetMet == true ? "checkmark.circle" : "target")
                        .font(.callout)
                        .foregroundStyle(r.targetMet == true ? AnyShapeStyle(Theme.savingsText) : AnyShapeStyle(.secondary))
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
                if let note = CompressionViewModel.lowPotentialNote(e, mode: viewModel.mode) {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let assessment = viewModel.targetAssessment {
                    Label(CompressionViewModel.targetEstimateText(assessment), systemImage: "target")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.estimateRefreshing {
                SizeReadout(original: original, content: .estimating)
            } else {
                // N14 (B1): Die Schätzung ist fertig, aber ohne Ergebnis (etwa
                // weil das Bildinventar scheiterte) – vorher blieb hier
                // „Wird geschätzt …“ stehen.
                SizeReadout(original: original, content: .unavailable)
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
                            .focused($targetFieldFocused)
                            // Return bestätigt nur das Feld.
                            .onSubmit { targetFieldFocused = false }
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
                .help(viewModel.mode == .custom
                      ? "Bei „Eigene“ gelten die festen Einstellungen; das Ziel kann sie nicht unterschreiten und dient nur als Rückmeldung."
                      : "Gewünschte Höchstgröße. Verkleinert so weit, wie es die Qualitätsgrenzen des Modus erlauben.")
                if viewModel.targetSizeInvalid {
                    Text("Bitte eine Zahl in MB eingeben, zum Beispiel 5 oder 2,5.")
                        .font(.footnote)
                        .foregroundStyle(Theme.warningText)
                }
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
        .id(Self.optionsAnchor)
        // Aufgeklappt ins Bild rollen – in „Eigene" lagen die Optionen
        // sonst unsichtbar unter dem Pultrand (Rundgang 2026-10-15).
        .onChange(of: showOptions) { _, expanded in
            guard expanded, let scrollProxy else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if reduceMotion {
                    scrollProxy.scrollTo(Self.optionsAnchor, anchor: .bottom)
                } else {
                    withAnimation { scrollProxy.scrollTo(Self.optionsAnchor, anchor: .bottom) }
                }
            }
        }
    }

    private static let optionsAnchor = "optionen"

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
            // Ein gescheitertes Sichern meldet sich hier – vorher stand der
            // Fehler unsichtbar im Zustand und tauchte erst nach „Verwerfen"
            // unter dem Komprimieren-Knopf auf.
            VStack(alignment: .leading, spacing: 8) {
                if let error = viewModel.errorMessage {
                    InlineNotice(message: error)
                }
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
                .keyboardShortcut(targetFieldFocused ? nil : .defaultAction)
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
        /// Keine Schätzung möglich – Komprimieren geht trotzdem (N14, B1).
        case unavailable
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
        .motionSafeAnimation(.smooth(duration: 0.25), value: content)
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
        case .unavailable:
            VStack(alignment: .leading, spacing: 2) {
                Text("—").font(Theme.figure).foregroundStyle(.tertiary)
                Text("Keine Schätzung möglich – Komprimieren geht trotzdem.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .foregroundStyle(Theme.savingsText)
                Text("\(CompressionResult.format(original)) → \(CompressionResult.format(output))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .alreadyOptimal:
            VStack(alignment: .leading, spacing: 2) {
                Label("Bereits optimal", systemImage: "checkmark.seal.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.savingsText)
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
                case .estimating, .unavailable:
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
        .adaptiveGlass(in: .rect(cornerRadius: Theme.panelRadius))
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
        .motionSafeAnimation(.easeInOut(duration: 0.25), value: scanning)
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
                .motionSafeAnimation(.easeInOut(duration: 0.25), value: scanning)
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
            .adaptiveGlass(in: .capsule)
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
                .adaptiveGlass(in: .circle)
        }
        .position(x: x, y: top + height / 2)
        .gesture(drag)
        // Masterplan F2: per Tastatur fokussierbar, Pfeiltasten verschieben
        // um 5 %.
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: fraction = max(fraction - 0.05, 0)
            case .right: fraction = min(fraction + 0.05, 1)
            default: break
            }
        }
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .accessibilityElement()
        .accessibilityLabel("Teiler")
        .accessibilityValue("\(Int(fraction * 100)) % Original")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: fraction = min(fraction + 0.05, 1)
            case .decrement: fraction = max(fraction - 0.05, 0)
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
        .adaptiveGlass(in: .capsule)
    }
}

// MARK: - Mehrere Dateien

private struct BulkRow: Identifiable {
    let index: Int
    let url: URL
    var id: URL { url }
}

/// B4: Vorher/Nachher einer Stapeldatei in der vorhandenen DocumentStage –
/// kein neues Bedienkonzept, nur „Zurück zur Liste“ oben links.
private struct BulkComparisonStage: View {
    @ObservedObject var viewModel: CompressionViewModel
    let input: URL
    let onBack: () -> Void
    @State private var fraction = 0.5
    @State private var page = 0
    @State private var original: PDFDocument?
    @State private var compressed: PDFDocument?
    @State private var thumbs: [Int: NSImage] = [:]

    private var pageCount: Int { original?.pageCount ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Label("Zurück zur Liste", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                Text(input.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let r = viewModel.bulkResult(for: input) {
                    Text("\(Int(r.savedPercent.rounded())) % kleiner · \(CompressionResult.format(r.outputBytes))")
                        .foregroundStyle(Theme.savingsText)
                        .monospacedDigit()
                    if viewModel.isBulkResultSaved(for: input) {
                        Label("Gesichert", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.savingsText)
                            .font(.callout)
                    } else if !r.alreadyOptimized {
                        Button("Sichern …") {
                            viewModel.saveBulkResult(for: input)
                            if !viewModel.isBulkResultSaved(for: input), let error = viewModel.errorMessage {
                                viewModel.errorMessage = nil
                                viewModel.bulkSaveError = error
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            ZStack(alignment: .bottom) {
                if let original {
                    DocumentStage(original: original, compressed: compressed, pageIndex: page,
                                  fraction: $fraction, onPageChange: { page = $0 })
                        .padding(.top, 16)
                        .padding(.horizontal, 24)
                        .padding(.bottom, pageCount > 1 ? 112 : 24)
                } else {
                    PaperSheet(image: nil)
                        .padding(24)
                }
                if pageCount > 1 {
                    PageStrip(thumbs: thumbs,
                              sampleCount: min(pageCount, CompressionViewModel.samplePageCount),
                              pageCount: pageCount,
                              selected: page,
                              caption: String(localized: "Seite \(page + 1) von \(pageCount)"),
                              onSelect: { page = min(max($0, 0), pageCount - 1) })
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
            }
        }
        .background(Theme.canvas)
        .task(id: input) {
            thumbs = [:]
            // N14 (C6): beide Dokumente abseits des Main Threads öffnen.
            let output = viewModel.bulkResult(for: input)?.outputURL
            // N23: eine entsperrte Datei über ihre Arbeitskopie (die Ausgabe
            // ist wieder verschlüsselt – PDFKit braucht dafür das Passwort).
            let source = viewModel.bulkUnlocked[input]?.workingCopy ?? input
            let password = viewModel.bulkUnlocked[input]?.password
            let samples = CompressionViewModel.samplePageCount
            let loaded = await Task.detached(priority: .userInitiated) {
                let compared = output.flatMap { PDFDocument(url: $0) }
                if let password, compared?.isLocked == true { _ = compared?.unlock(withPassword: password) }
                let srcDoc = PDFDocument(url: source)
                var preThumbs: [Int: NSImage] = [:]
                if let srcDoc {
                    for index in 0..<min(srcDoc.pageCount, samples) {
                        if Task.isCancelled { break }
                        autoreleasepool {
                            if let p = srcDoc.page(at: index) {
                                preThumbs[index] = p.thumbnail(of: CGSize(width: 80, height: 100), for: .cropBox)
                            }
                        }
                    }
                }
                return (SendableDocument(srcDoc), SendableDocument(compared), preThumbs)
            }.value
            guard !Task.isCancelled else { return }
            original = loaded.0.value
            compressed = loaded.1.value
            thumbs = loaded.2
            page = 0
        }
    }
}

private struct BulkStage: View {
    @ObservedObject var viewModel: CompressionViewModel
    @EnvironmentObject private var discardGuard: DiscardGuard
    let isTargeted: Bool
    var onCompare: (URL) -> Void = { _ in }
    @State private var selection: Set<URL> = []
    @State private var showsCustom = true
    // N14 (B2): Entsperren einer gesperrten Stapeldatei.
    @State private var unlockTarget: URL?
    @State private var unlockPassword = ""
    @State private var unlockError: String?

    // Sichern-Fehler als System-Alert (Befunde M7/S6) – Aktionsfehler
    // gehören nicht in eine Fußzeile. Seit N14 (B4) im ViewModel
    // (`bulkSaveError`), damit ⌘S ihn ebenfalls zeigt; der Alert hängt an
    // `CompressionView` (N28).

    private var rows: [BulkRow] {
        viewModel.bulkInputs.enumerated().map { BulkRow(index: $0.offset, url: $0.element) }
    }

    /// Gesichert-Stand aus dem ViewModel (Befund S9): überlebt den
    /// Werkzeugwechsel, vorher hielt ihn ein `@State` dieser View.
    private var allSaved: Bool { viewModel.allBulkResultsSaved }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            // B4: „Eigene“ im Stapel – dieselbe Einstellfläche wie im Einzelweg,
            // aber begrenzt und scrollbar, damit die Dateiliste im 640-pt-Fenster
            // nicht zusammengedrückt wird.
            if viewModel.mode == .custom, !viewModel.isWorking {
                DisclosureGroup("Einstellungen für „Eigene“", isExpanded: $showsCustom) {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView {
                            CustomSettingsPanel(viewModel: viewModel)
                                .frame(maxWidth: 520, alignment: .leading)
                                .padding(.trailing, 8)
                        }
                        .frame(maxHeight: 220)
                        // N14 (B4): Start erst auf Wunsch – auch nach
                        // geänderten Einstellungen. Neu starten verwirft
                        // ungesicherte Ergebnisse, deshalb über DiscardGuard.
                        if viewModel.bulkNeedsCustomStart {
                            Button("Mit diesen Einstellungen komprimieren") {
                                discardGuard.run(ifUnsaved: viewModel.hasUnsavedResult) {
                                    viewModel.startBulkWithCurrentSettings()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            Table(rows, selection: $selection) {
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
                    Text(CompressionResult.format(viewModel.bulkFileSizes[row.url] ?? 0))
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
                .width(155)
            }
            // B4: keine leeren Zebrastreifen unter der letzten Datei.
            .alternatingRowBackgrounds(.disabled)
            // B4: Doppelklick oder Kontextmenü auf eine fertige Zeile zeigt Vorher/Nachher.
            .contextMenu(forSelectionType: URL.self) { urls in
                if let url = urls.first, let r = viewModel.bulkResult(for: url), !r.alreadyOptimized {
                    Button("Vorher/Nachher vergleichen") { onCompare(url) }
                }
            } primaryAction: { urls in
                guard let url = urls.first, let r = viewModel.bulkResult(for: url), !r.alreadyOptimized else { return }
                onCompare(url)
            }
            if !viewModel.bulkSigned.isEmpty {
                Label(String(localized: "\(viewModel.bulkSigned.count) Dateien digital signiert – die Signatur wird dabei ungültig."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .dropTargetOverlay(isTargeted)
        .alert("Passwort eingeben", isPresented: Binding(
            get: { unlockTarget != nil }, set: { if !$0 { unlockTarget = nil } })) {
            SecureField("Passwort", text: $unlockPassword)
            Button("Entsperren") {
                guard let url = unlockTarget else { return }
                let password = unlockPassword
                unlockPassword = ""
                Task {
                    if let error = await viewModel.unlockBulkFile(url, password: password) {
                        unlockError = error
                    }
                }
            }
            Button("Abbrechen", role: .cancel) { unlockPassword = "" }
        } message: {
            Text(unlockTarget?.lastPathComponent ?? "")
        }
        .alert("Entsperren fehlgeschlagen", isPresented: Binding(
            get: { unlockError != nil }, set: { if !$0 { unlockError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(unlockError ?? "")
        }
    }

    private var totalInput: Int64 {
        viewModel.bulkInputs.reduce(0) { $0 + (viewModel.bulkFileSizes[$1] ?? 0) }
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
            // B4: Auch nach dem Lauf wählbar – ein Wechsel fragt bei
            // ungesicherten Ergebnissen nach und startet den Stapel neu.
            Picker("Modus", selection: Binding(
                get: { viewModel.mode },
                set: { newMode in
                    discardGuard.run(ifUnsaved: viewModel.hasUnsavedResult) {
                        viewModel.changeBulkMode(to: newMode)
                    }
                })) {
                ForEach(CompressionMode.allCases) { m in
                    Text(ControlPanel.label(m)).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .disabled(viewModel.isWorking)
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
                .foregroundStyle(Theme.savingsText)
                .monospacedDigit()
        } else if let verdict = viewModel.bulkVerdicts[url], !verdict.isOK {
            // Vorprüfung (B1): Grund sofort, nicht „…“ – die Datei läuft nicht mit.
            HStack(spacing: 8) {
                Label(verdict.shortLabel,
                      systemImage: verdict == .locked ? "lock" : "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(verdict.title + " " + verdict.detail)
                // N14 (B2): Wie im Einzelweg entsperren statt nur ablehnen.
                if verdict == .locked, !viewModel.isWorking {
                    Button("Entsperren …") {
                        unlockPassword = ""
                        unlockTarget = url
                    }
                    .buttonStyle(.link)
                }
            }
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
        if let result = viewModel.bulkResult(for: url), !viewModel.isWorking {
            HStack(spacing: 8) {
                if !result.alreadyOptimized {
                    Button { onCompare(url) } label: {
                        Label("Vorher/Nachher vergleichen", systemImage: "rectangle.split.2x1")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Vorher/Nachher vergleichen")
                }
                if viewModel.isBulkResultSaved(for: url) {
                    Label("Gesichert", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.savingsText)
                        .font(.callout)
                } else {
                    Button("Sichern …") { saveSingle(url) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                }
            }
        } else if viewModel.isWorking {
            if !viewModel.bulkCancelledURLs.contains(url), viewModel.bulkResult(for: url) == nil,
               viewModel.bulkErrors[url] == nil, viewModel.bulkVerdicts[url]?.isOK != false {
                Button { viewModel.cancelBulkFile(at: row.index) } label: {
                    Label("Diese Datei abbrechen", systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Diese Datei abbrechen – die übrigen laufen weiter")
            }
        } else {
            HStack(spacing: 6) {
                // B4: Fehlgeschlagene oder abgebrochene Datei allein wiederholen.
                if viewModel.bulkErrors[url] != nil || viewModel.bulkCancelledURLs.contains(url) {
                    Button("Wiederholen") { viewModel.retryBulkFile(at: row.index) }
                        .buttonStyle(.link)
                }
                Button { viewModel.removeBulkInput(at: row.index) } label: {
                    Label("Aus der Liste entfernen", systemImage: "minus.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Aus der Liste entfernen")
            }
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
                        .foregroundStyle(Theme.savingsText)
                    Text(viewModel.progressLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if allSaved {
                    // Nach dem Sichern dasselbe Muster wie im Pult (S9).
                    Label("Gesichert", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.savingsText)
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
        viewModel.saveBulkResult(for: url)
        if !viewModel.isBulkResultSaved(for: url), let error = viewModel.errorMessage {
            viewModel.errorMessage = nil
            viewModel.bulkSaveError = error
        }
    }

    private func chooseFolderAndSave() {
        // Teilerfolge stehen in bulkSavedURLs; der Fehler nennt den Rest.
        viewModel.saveAllBulkWithPanel()
    }
}

// MARK: - Modus-Segmente

/// Die Modus-Wahl als `NSSegmentedControl` mit gleich verteilten Segmenten
/// (`fillEqually`): dasselbe Control, das der SwiftUI-Picker hostet, nur
/// dass die vier Segmente gleich breit sind und die volle Breite füllen –
/// nichts springt, wenn die Auswahl wechselt.
private struct ModeSegments: NSViewRepresentable {
    @Binding var mode: CompressionMode
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: CompressionMode.allCases.map(ControlPanel.label),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.segmentStyle = .automatic
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel(String(localized: "Modus"))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if let index = CompressionMode.allCases.firstIndex(of: mode),
           control.selectedSegment != index {
            control.selectedSegment = index
        }
        control.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: ModeSegments
        init(_ parent: ModeSegments) { self.parent = parent }

        @objc func changed(_ sender: NSSegmentedControl) {
            let modes = CompressionMode.allCases
            guard modes.indices.contains(sender.selectedSegment) else { return }
            parent.mode = modes[sender.selectedSegment]
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
            // Ehrlich zur Sofort-Schätzung (Befund B5, Review 2026-10-09).
            // Kein „Auf Smart-Werte zurücksetzen" mehr: Eigene beginnt bei
            // Smart (Rundgang 2026-10-19).
            Text("Die Sofort-Schätzung folgt Auflösung, Bildkante und Qualität. Graustufen und Grafik-JPEG wirken erst im Lauf.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: viewModel.currentOptions) { _, _ in viewModel.scheduleEstimateRefresh() }
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
