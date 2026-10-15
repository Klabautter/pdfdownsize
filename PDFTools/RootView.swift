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

    /// Die zuletzt in irgendeinem Werkzeug geöffnete PDF. Ein Werkzeug, das
    /// beim Wechsel leer ist, bekommt sie still – „jetzt noch durchsuchbar
    /// machen" kostet einen Klick in der Seitenleiste statt erneutes
    /// Ablegen. Werkzeuge mit eigenem Inhalt werden nie überschrieben;
    /// wer eine Datei schließt, wird nicht mit ihr verfolgt.
    @State private var lastOpenedPDF: URL?

    /// Mit offenem Inspector (Modus „Eigene") liegen Pult und Inspector
    /// nebeneinander – dafür braucht das Fenster mehr Breite (Befund S5).
    private var minWidth: CGFloat { 940 }

    var body: some View {
        classic
        .frame(minWidth: minWidth, minHeight: 640)
        // Dateien öffnen (Finder/Dock/Open With) – immer ins aktive Tool routen.
        .onOpenURL { url in receive([url]) }
        .onReceive(NotificationCenter.default.publisher(for: OpenFilesDelegate.didReceiveFiles)) { note in
            receive(note.object as? [URL] ?? [])
        }
        .focusedSceneObject(discardGuard)
        .environmentObject(discardGuard)
        .discardConfirmation(discardGuard)
    }

    private var classic: some View {
        NavigationSplitView {
            // Vier Zeilen ohne Abschnittsköpfe (Befund G1): Komprimieren
            // steht oben und ist vorausgewählt – die Reihenfolge trägt die
            // Hierarchie.
            List(AppTool.allCases, selection: $selectedTool) { tool in
                Label(tool.label, systemImage: tool.icon)
                    .tag(tool)
            }
            // Schmaler (Sichtabnahme 2026-10-15): vier Wörter brauchen keine
            // 200 Pixel, und die Nebenwerkzeuge sollen nicht so viel Fläche
            // beanspruchen wie der Hauptzweck.
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 220)
            .listStyle(.sidebar)
        } detail: {
            switch selectedTool {
            case .compress:
                CompressionView(viewModel: compressionVM, onForeignFiles: routeImages)

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
                OCRView(vm: ocrVM, onForeignFiles: routeImages)

            }
        }
        // Mit geöffnetem Dokument steht dessen Name im Titel und das
        // Werkzeug im Untertitel (Sichtabnahme 2026-10-15); ohne Dokument
        // bleibt der Werkzeugname der Titel (§13: nie „Custom“ o. ä.).
        .navigationTitle(documentTitle ?? selectedTool.label)
        .navigationSubtitle(documentTitle == nil ? "" : selectedTool.label)
        // Für Menü-Befehle (§33): aktives Tool im Fokus-Environment melden.
        .focusedSceneValue(\.appTool, selectedTool)
        .onChange(of: selectedTool) { _, tool in handOver(to: tool) }
        .onChange(of: compressionVM.inputURL) { old, new in remember(new, closing: old) }
        .onChange(of: ocrVM.pdfURL) { old, new in remember(new, closing: old) }
        .onChange(of: conversionVM.pdfURL) { old, new in remember(new, closing: old) }
        .onChange(of: organizeVM.project.documents.count) { _, _ in
            if let last = organizeVM.project.documents.last,
               last.url.pathExtension.lowercased() == "pdf" {
                lastOpenedPDF = last.url
            }
        }
    }

    /// Merkt die zuletzt geöffnete PDF; wird sie in ihrem Werkzeug
    /// geschlossen, folgt sie nicht mehr in andere Werkzeuge.
    private func remember(_ url: URL?, closing old: URL?) {
        if let url {
            lastOpenedPDF = url
        } else if old == lastOpenedPDF {
            lastOpenedPDF = nil
        }
    }

    /// Beim Werkzeugwechsel: Ein leeres Werkzeug bekommt die zuletzt
    /// geöffnete PDF. Laufende Arbeit und eigener Inhalt bleiben unberührt.
    private func handOver(to tool: AppTool) {
        guard let url = lastOpenedPDF,
              FileManager.default.fileExists(atPath: url.path) else { return }
        switch tool {
        case .compress:
            guard compressionVM.inputURL == nil, compressionVM.bulkInputs.isEmpty,
                  !compressionVM.isWorking else { return }
            compressionVM.select(url)
        case .organize:
            guard organizeVM.project.documents.isEmpty, organizeVM.outcome == nil,
                  !organizeVM.isProcessing else { return }
            organizeVM.importDocuments([url])
        case .convert:
            guard !conversionVM.hasSource, !conversionVM.isWorking else { return }
            conversionVM.accept([url])
        case .ocr:
            guard ocrVM.pdfURL == nil, !ocrVM.isWorking else { return }
            ocrVM.accept([url])
        }
    }

    /// Bilder, die auf Komprimieren oder OCR landen, gehören zu Konvertieren –
    /// die Fläche sagt nicht „falsches Werkzeug", sie wechselt.
    private func routeImages(_ urls: [URL]) {
        guard !conversionVM.isWorking else { return }
        conversionVM.accept(urls)
        selectedTool = .convert
    }

    /// Name des Dokuments im aktiven Werkzeug – nil, solange dort nichts
    /// geöffnet ist.
    private var documentTitle: String? {
        switch selectedTool {
        case .compress:
            if compressionVM.bulkInputs.count > 1 {
                return String(localized: "\(compressionVM.bulkInputs.count) PDFs")
            }
            return compressionVM.inputURL?.lastPathComponent
        case .organize:
            let documents = organizeVM.project.documents
            if documents.count > 1 { return String(localized: "\(documents.count) Dokumente") }
            return documents.first?.fileName
        case .convert:
            if let url = conversionVM.pdfURL { return url.lastPathComponent }
            if !conversionVM.imageURLs.isEmpty { return Counted.images(conversionVM.imageURLs.count) }
            return nil
        case .ocr:
            return ocrVM.pdfURL?.lastPathComponent
        }
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
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let images = urls.filter { ImageImporter.isSupported($0) }
        switch selectedTool {
        case .compress:
            // Nur Bilder: Die PDF daraus entsteht in Konvertieren.
            if pdfs.isEmpty, !images.isEmpty { routeImages(images); return }
            guard !pdfs.isEmpty else { return }
            discardGuard.run(ifUnsaved: compressionVM.hasUnsavedResult) {
                compressionVM.selectMany(pdfs)
            }
        case .organize:
            organizeVM.importDocuments(urls)
        case .convert:
            conversionVM.accept(urls)
        case .ocr:
            if pdfs.isEmpty, !images.isEmpty { routeImages(images); return }
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
                // Lesbar, nicht als Kleingedrucktes (Sichtabnahme 2026-10-15):
                // Der Hinweis ist der erste Satz, den ein neuer Nutzer liest.
                Text("\(dropHint) · Alles bleibt auf diesem Mac")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .dropTargetOverlay(isTargeted, inset: 12)
    }
}
