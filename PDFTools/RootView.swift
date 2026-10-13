import SwiftUI

enum AppTool: String, CaseIterable, Identifiable {
    case compress
    case organize
    case convert
    case ocr

    var id: Self { self }

    var label: String {
        switch self {
        case .compress: return String(localized: "Komprimieren")
        case .organize: return String(localized: "Organisieren")
        case .convert: return String(localized: "Konvertieren")
        case .ocr: return "OCR"
        }
    }

    var icon: String {
        switch self {
        case .compress: return "arrow.down.doc"
        case .organize: return "rectangle.grid.2x2"
        case .convert: return "arrow.left.arrow.right"
        case .ocr: return "text.viewfinder"
        }
    }
}

/// App Shell: Sidebar = Navigation, Detail = aktives Tool.
/// Session-State liegt in ViewModels auf dieser Ebene – Toolwechsel verwirft keine Arbeit,
/// aber nur das aktive Tool ist gemountet (kein Toolbar-Leak mehr, §4–§7).
struct RootView: View {
    @State private var selectedTool: AppTool = .compress

    @StateObject private var compressionVM = CompressionViewModel()
    @StateObject private var organizeVM = MergeViewModel()
    @StateObject private var conversionVM = ConversionViewModel()
    @StateObject private var ocrVM = OCRViewModel()
    @StateObject private var discardGuard = DiscardGuard()

    /// „Öffnen mit"/Dock liefert mehrere Dateien als EINZELNE Ereignisse
    /// kurz nacheinander. Sie werden gesammelt und als ein Stapel geroutet –
    /// vorher ersetzte jede Datei die vorige, übrig blieb eine
    /// (Sichtabnahme 2026-10-12, M1).
    @State private var incomingURLs: [URL] = []
    @State private var incomingTask: Task<Void, Never>?

    /// Mit offenem Inspector (Modus „Eigene") liegen Pult und Inspector
    /// nebeneinander – dafür braucht das Fenster mehr Breite (Befund S5).
    private var minWidth: CGFloat { 940 }

    var body: some View {
        NavigationSplitView {
            // Vier Zeilen ohne Abschnittsköpfe (Befund G1): Komprimieren
            // steht oben und ist vorausgewählt – die Reihenfolge trägt die
            // Hierarchie.
            List(AppTool.allCases, selection: $selectedTool) { tool in
                Label(tool.label, systemImage: tool.icon)
                    .tag(tool)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
            .listStyle(.sidebar)
        } detail: {
            switch selectedTool {
            case .compress:
                CompressionView(viewModel: compressionVM)

            case .organize:
                OrganizeView(vm: organizeVM, onOpenConvert: {
                    selectedTool = .convert
                }, onCompress: { url in
                    discardGuard.run(ifUnsaved: compressionVM.hasUnsavedResult) {
                        compressionVM.select(url)
                        selectedTool = .compress
                    }
                })

            case .convert:
                ConvertView(vm: conversionVM, onOpenInOrganize: { urls in
                    organizeVM.importDocuments(urls)
                    conversionVM.reset()
                    selectedTool = .organize
                })

            case .ocr:
                OCRView(vm: ocrVM)

            }
        }
        .frame(minWidth: minWidth, minHeight: 640)
        // §13: Primärtitel = Toolname, nicht „Custom“ o. ä.
        .navigationTitle(selectedTool.label)
        // Dateien öffnen (Finder/Dock/Open With) – immer ins aktive Tool routen.
        .onOpenURL { url in receive([url]) }
        .onReceive(NotificationCenter.default.publisher(for: OpenFilesDelegate.didReceiveFiles)) { note in
            receive(note.object as? [URL] ?? [])
        }
        // Für Menü-Befehle (§33): aktives Tool im Fokus-Environment melden.
        .focusedSceneValue(\.appTool, selectedTool)
        .focusedSceneObject(discardGuard)
        .environmentObject(discardGuard)
        .discardConfirmation(discardGuard)
    }

    /// Sammelt eingehende Dateien kurz und routet sie als einen Stapel.
    /// Dieselbe Datei kann über beide Wege (`onOpenURL` und App-Delegate)
    /// gemeldet werden – sie zählt nur einmal.
    private func receive(_ urls: [URL]) {
        for url in urls where !incomingURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            incomingURLs.append(url)
        }
        guard !incomingURLs.isEmpty else { return }
        incomingTask?.cancel()
        incomingTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let batch = incomingURLs
            incomingURLs = []
            route(batch)
        }
    }

    /// Geöffnete Dateien ins aktive Werkzeug – als ein Stapel.
    private func route(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch selectedTool {
        case .compress:
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return }
            discardGuard.run(ifUnsaved: compressionVM.hasUnsavedResult) {
                compressionVM.selectMany(pdfs)
            }
        case .organize:
            organizeVM.importDocuments(urls)
        case .convert:
            conversionVM.accept(urls)
        case .ocr:
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return }
            discardGuard.run(ifUnsaved: ocrVM.hasUnsavedResult) {
                ocrVM.accept(pdfs)
            }
        }
    }
}

/// Gemeinsamer Einstieg für die vier Werkzeuge – das System-Muster für
/// leere Inhalte (`ContentUnavailableView`), damit alle Werkzeuge gleich
/// aussehen und sich wie macOS anfühlen. Die ganze Fläche ist Drop-Ziel.
struct WorkspaceWelcome<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let dropHint: String
    var isTargeted: Bool
    let actions: Actions

    init(icon: String, title: String, subtitle: String, dropHint: String,
         isTargeted: Bool = false,
         @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.dropHint = dropHint
        self.isTargeted = isTargeted
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
                .symbolRenderingMode(.hierarchical)
        } description: {
            Text(subtitle)
        } actions: {
            VStack(spacing: 12) {
                actions
                    .controlSize(.large)
                Text("\(dropHint) · Lokal verarbeitet")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .dropTargetOverlay(isTargeted, inset: 12)
    }
}
