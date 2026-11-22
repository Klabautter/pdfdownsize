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

    /// Aktiver Arbeitsstand über alle Werkzeuge (v1.2). Nach Komprimieren,
    /// OCR, Organisieren oder Konvertieren fließt das erzeugte Ergebnis weiter,
    /// statt beim Werkzeugwechsel still auf das alte Original zurückzufallen.
    @State private var activeDocument: WorkspaceDocument?
    /// Welcher Arbeitsstand aktuell in welchem Werkzeug geöffnet ist.
    @State private var toolDocuments: [AppTool: WorkspaceDocument] = [:]
    /// Zuletzt erzeugtes Ergebnis je Werkzeug (für Lineage & Weiter-Aktionen).
    @State private var toolResults: [AppTool: WorkspaceDocument] = [:]
    /// Ungesicherte Zwischenstände, deren weiterbearbeiteter Nachfolger
    /// derselben Abstammung bereits gesichert wurde (keine doppelte ⌘Q-Rückfrage).
    @State private var supersededPendingURLs: Set<URL> = []

    /// Masterplan B3: Nach „Beenden“ in der Rückfrage fragt das Beenden, das
    /// dem Schließen des letzten Fensters folgt, nicht ein zweites Mal.
    @State private var quitConfirmed = false

    /// Was beim Beenden oder Schließen verloren ginge – über alle Werkzeuge.
    private var pendingWork: PendingWork {
        guard !quitConfirmed else { return PendingWork() }
        let compressUnsaved: Bool = {
            if let pending = compressionVM.pendingResult, !pending.alreadyOptimized {
                return !supersededPendingURLs.contains(pending.outputURL)
            }
            return compressionVM.hasUnsavedResult
        }()
        let ocrUnsaved = ocrVM.hasUnsavedResult
            && !(ocrVM.outputURL.map { supersededPendingURLs.contains($0) } ?? false)
        let organizeUnsaved = organizeVM.hasUnsavedResult
            && !(organizeVM.outcome.map { supersededPendingURLs.contains($0.url) } ?? false)
        return PendingWork(
            unsavedResult: compressUnsaved || ocrUnsaved || organizeUnsaved,
            running: compressionVM.isWorking || ocrVM.isWorking
                || conversionVM.isWorking || organizeVM.isProcessing)
    }

    private func askBeforeQuit(_ work: PendingWork, reply: @escaping (Bool) -> Void) {
        discardGuard.confirmQuit(work) { confirmed in
            if confirmed { quitConfirmed = true }
            reply(confirmed)
        }
    }

    /// Mit offenem Inspector (Modus „Eigene") liegen Pult und Inspector
    /// nebeneinander – dafür braucht das Fenster mehr Breite (Befund S5).
    private var minWidth: CGFloat { 940 }

    var body: some View {
        classic
        .frame(minWidth: minWidth, minHeight: 640)
        // Dateien öffnen (Finder/Dock/Open With) – immer ins aktive Tool routen.
        .onOpenURL { url in receive([url]) }
        // Masterplan G3: `--open <pfad> [<pfad> …]` beim Start – für UI-Tests,
        // damit kein Dateidialog nötig ist. Derselbe Weg wie „Öffnen mit“.
        .task {
            if let tool = Self.launchArgumentTool() { selectedTool = tool }
            receive(Self.launchArgumentFiles())
        }
        .onReceive(NotificationCenter.default.publisher(for: OpenFilesDelegate.didReceiveFiles)) { note in
            receive(note.object as? [URL] ?? [])
        }
        .focusedSceneObject(discardGuard)
        .environmentObject(discardGuard)
        .discardConfirmation(discardGuard)
        // B3: ⌘Q fragt über den App-Delegate, ⌘W über den Fenster-Proxy –
        // beide mit demselben Dialog.
        .background(WindowCloseGuard { window in
            let work = pendingWork
            guard work.needsConfirmation else { return true }
            askBeforeQuit(work) { confirmed in
                if confirmed { window.close() }
            }
            return false
        })
        .onAppear {
            OpenFilesDelegate.current?.pendingWork = { pendingWork }
            OpenFilesDelegate.current?.confirmQuit = { work, reply in
                askBeforeQuit(work, reply: reply)
            }
            if let buffered = OpenFilesDelegate.current?.drainBufferedOpenURLs(), !buffered.isEmpty {
                receive(buffered)
            }
        }
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
                CompressionView(
                    viewModel: compressionVM,
                    onForeignFiles: routeImages,
                    onOpenInOrganize: { handoff in
                        openFrom(.compress, handoff: handoff, in: .organize)
                    },
                    onOpenInOCR: { handoff in
                        openFrom(.compress, handoff: handoff, in: .ocr)
                    },
                    lineageBadge: toolDocuments[.compress]?.statusBadge,
                    alreadyCompressed: toolDocuments[.compress]?.isCompressed ?? false)

            case .organize:
                OrganizeView(
                    vm: organizeVM,
                    onOpenConvert: {
                        selectedTool = .convert
                    },
                    onCompress: { url, password in
                        openFrom(.organize, handoff: ToolHandoff(url: url, password: password), in: .compress)
                    },
                    onOpenInOCR: { handoff in
                        openFrom(.organize, handoff: handoff, in: .ocr)
                    },
                    lineageBadge: toolDocuments[.organize]?.statusBadge,
                    alreadyCompressed: toolDocuments[.organize]?.isCompressed ?? false)

            case .convert:
                ConvertView(
                    vm: conversionVM,
                    onOpenInOrganize: { urls in
                        if urls.count == 1, let pdf = urls.first, pdf == conversionVM.savedPDF {
                            openFrom(.convert, handoff: ToolHandoff(url: pdf, password: nil), in: .organize)
                        } else {
                            organizeVM.importDocuments(urls)
                            conversionVM.reset()
                            selectedTool = .organize
                        }
                    },
                    onOpenInCompress: { handoff in
                        openFrom(.convert, handoff: handoff, in: .compress)
                    },
                    lineageBadge: toolDocuments[.convert]?.statusBadge)

            case .ocr:
                OCRView(
                    vm: ocrVM,
                    onForeignFiles: routeImages,
                    onOpenInCompress: { handoff in
                        openFrom(.ocr, handoff: handoff, in: .compress)
                    },
                    onOpenInOrganize: { handoff in
                        openFrom(.ocr, handoff: handoff, in: .organize)
                    },
                    lineageBadge: toolDocuments[.ocr]?.statusBadge,
                    alreadyCompressed: toolDocuments[.ocr]?.isCompressed ?? false)

            }
        }
        // Mit geöffnetem Dokument steht dessen Name im Titel und das
        // Werkzeug im Untertitel (Sichtabnahme 2026-10-15); ohne Dokument
        // bleibt der Werkzeugname der Titel (§13: nie „Custom“ o. ä.).
        .navigationTitle(documentTitle ?? selectedTool.label)
        .navigationSubtitle(documentTitle == nil ? "" : selectedTool.label)
        // Für Menü-Befehle (§33): aktives Tool im Fokus-Environment melden.
        .focusedSceneValue(\.appTool, selectedTool)
        // Masterplan F2: Werkzeugwechsel per Menü (⌘1–⌘4).
        .focusedSceneValue(\.selectTool, ToolSelector { selectedTool = $0 })
        .onChange(of: selectedTool) { _, tool in handOver(to: tool) }
        .onChange(of: compressionVM.inputURL) { old, new in rememberOpened(new, closing: old, in: .compress) }
        .onChange(of: ocrVM.pdfURL) { old, new in rememberOpened(new, closing: old, in: .ocr) }
        .onChange(of: conversionVM.pdfURL) { old, new in rememberOpened(new, closing: old, in: .convert) }
        // Ergebnisse automatisch als aktiven Arbeitsstand nachführen (v1.2).
        .onChange(of: compressionVM.pendingResult?.outputURL) { _, url in
            guard let url, let pending = compressionVM.pendingResult, !pending.alreadyOptimized else { return }
            recordResult(from: .compress, url: url, password: compressionVM.unlocked?.password, saved: false)
        }
        .onChange(of: compressionVM.result?.outputURL) { _, url in
            guard let url, let saved = compressionVM.result, !saved.alreadyOptimized else { return }
            recordResult(from: .compress, url: url, password: compressionVM.unlocked?.password, saved: true)
        }
        .onChange(of: ocrVM.outputURL) { _, url in
            guard let url, ocrVM.canSaveSearchablePDF else { return }
            recordResult(from: .ocr, url: url, password: ocrVM.unlocked?.password, saved: false)
        }
        .onChange(of: ocrVM.savedURL) { _, url in
            guard let url else { return }
            recordResult(from: .ocr, url: url, password: ocrVM.unlocked?.password, saved: true)
        }
        .onChange(of: organizeVM.outcome?.url) { _, url in
            guard let url, let outcome = organizeVM.outcome else { return }
            recordResult(from: .organize, url: url, password: outcome.encryption?.password, saved: false)
        }
        .onChange(of: organizeVM.savedURL) { _, url in
            guard let url else { return }
            recordResult(from: .organize, url: url, password: organizeVM.outcome?.encryption?.password, saved: true)
        }
        .onChange(of: conversionVM.savedPDF) { _, url in
            guard let url else { return }
            recordResult(from: .convert, url: url, password: nil, saved: true)
        }
        // B6: Die Merkstelle folgt dem ABGESCHLOSSENEN Import (die Liste
        // ändert sich erst danach), ignoriert konvertierte Bilder und wird
        // gelöscht, wenn das Dokument in Organisieren entfernt wird.
        .onChange(of: organizeVM.project.documents.map(\.url)) { old, new in
            if new.isEmpty {
                let closedLineage = toolDocuments[.organize]?.lineageID
                toolDocuments[.organize] = nil
                toolResults[.organize] = nil
                if let closedLineage, activeDocument?.lineageID == closedLineage {
                    activeDocument = nil
                }
                return
            }
            if let active = activeDocument, old.contains(active.url), !new.contains(active.url),
               !organizeVM.containsSource(active.url) {
                activeDocument = nil
            }
            if let added = organizeVM.project.documents.last(where: { !$0.isConvertedImage }),
               !old.contains(added.url) {
                // Eigene Übergabe erkennen (direkt oder über entsperrte Arbeitskopie).
                let knownURL = toolDocuments[.organize]?.url
                let originalForWorking = organizeVM.unlockedSources[added.url]?.original
                if knownURL == added.url || (knownURL != nil && knownURL == originalForWorking) {
                    if organizeVM.project.documents.count > 1 {
                        // Weitere Datei dazugeladen → kein rein komprimierter Einzelstand mehr.
                        toolDocuments[.organize] = WorkspaceDocument(url: added.url)
                    }
                    return
                }
                let fresh = WorkspaceDocument(url: originalForWorking ?? added.url,
                                              password: organizeVM.unlockedSources[added.url]?.password)
                toolDocuments[.organize] = fresh
                toolResults[.organize] = nil
                activeDocument = fresh
            }
        }
    }

    /// Merkt eine im Werkzeug geöffnete PDF. Eigene Übergaben behalten ihre
    /// Abstammung (`completedTools`); eine frisch geöffnete Datei startet neu.
    private func rememberOpened(_ url: URL?, closing old: URL?, in tool: AppTool) {
        if let url {
            if toolDocuments[tool]?.url == url {
                return
            }
            let fresh = WorkspaceDocument(url: url)
            toolDocuments[tool] = fresh
            toolResults[tool] = nil
            activeDocument = fresh
        } else {
            let closedLineage = toolDocuments[tool]?.lineageID
            let closedURL = toolDocuments[tool]?.url ?? old
            toolDocuments[tool] = nil
            toolResults[tool] = nil
            if let active = activeDocument,
               active.url == closedURL || (closedLineage != nil && active.lineageID == closedLineage) {
                activeDocument = nil
            }
        }
    }

    /// Aktualisiert den aktiven Arbeitsstand nach einem Ergebnis in `tool`.
    private func recordResult(from tool: AppTool, url: URL, password: String?, saved: Bool) {
        let base: WorkspaceDocument?
        if tool == .organize, organizeVM.project.documents.count > 1 {
            // Zusammengeführtes Dokument aus mehreren Quellen gilt nicht mehr
            // als „bereits komprimiert“.
            base = nil
        } else {
            base = toolDocuments[tool]
        }
        let completed: Set<AppTool>
        if tool == .convert {
            completed = []
        } else {
            completed = (base?.completedTools ?? []).union([tool])
        }
        let lineageID = base?.lineageID ?? UUID()
        let updated = WorkspaceDocument(lineageID: lineageID,
                                        url: url,
                                        password: password ?? base?.password,
                                        completedTools: completed)
        toolResults[tool] = updated
        activeDocument = updated

        if saved {
            markUpstreamPendingSuperseded(for: lineageID, savedIn: tool)
        }
    }

    /// Wurde ein weiterbearbeiteter Nachfolger derselben Abstammung gesichert,
    /// sollen ältere ungesicherte Zwischenstände in vorgelagerten Werkzeugen
    /// beim Beenden nicht fälschlich als „ungesichert“ warnen.
    private func markUpstreamPendingSuperseded(for lineageID: UUID, savedIn tool: AppTool) {
        if tool != .compress,
           let pending = compressionVM.pendingResult, !pending.alreadyOptimized,
           toolResults[.compress]?.lineageID == lineageID {
            supersededPendingURLs.insert(pending.outputURL)
        }
        if tool != .ocr,
           let out = ocrVM.outputURL,
           toolResults[.ocr]?.lineageID == lineageID {
            supersededPendingURLs.insert(out)
        }
        if tool != .organize,
           let outcome = organizeVM.outcome, organizeVM.savedURL == nil,
           toolResults[.organize]?.lineageID == lineageID {
            supersededPendingURLs.insert(outcome.url)
        }
    }

    /// Explizite Übergabe per „Weiter in …“-Knopf aus einem Ergebnis-Pult.
    private func openFrom(_ source: AppTool, handoff: ToolHandoff, in target: AppTool) {
        let lineageDoc: WorkspaceDocument
        if let res = toolResults[source] {
            lineageDoc = WorkspaceDocument(lineageID: res.lineageID,
                                           url: handoff.url,
                                           password: handoff.password ?? res.password,
                                           completedTools: res.completedTools)
        } else if source == .convert {
            lineageDoc = WorkspaceDocument(url: handoff.url, password: handoff.password)
        } else {
            let base = toolDocuments[source]
            lineageDoc = WorkspaceDocument(lineageID: base?.lineageID ?? UUID(),
                                           url: handoff.url,
                                           password: handoff.password ?? base?.password,
                                           completedTools: (base?.completedTools ?? []).union([source]))
        }
        let targetUnsaved: Bool = switch target {
        case .compress: compressionVM.hasUnsavedResult
        case .organize: organizeVM.hasUnsavedResult
        case .ocr: ocrVM.hasUnsavedResult
        case .convert: false
        }
        discardGuard.run(ifUnsaved: targetUnsaved) {
            activeDocument = lineageDoc
            deliver(lineageDoc, to: target, replaceOrganize: true)
            selectedTool = target
        }
    }

    /// Liefert eine unabhängige Kopie, falls `doc` noch auf eine ungesicherte
    /// Temp-Datei eines anderen Werkzeugs zeigt.
    private func materializedForHandoff(_ doc: WorkspaceDocument, target: AppTool) -> WorkspaceDocument? {
        if target != .compress,
           let pending = compressionVM.pendingResult,
           pending.outputURL == doc.url,
           let copy = compressionVM.handOffResult() {
            return WorkspaceDocument(lineageID: doc.lineageID,
                                     url: copy.url,
                                     password: copy.password ?? doc.password,
                                     completedTools: doc.completedTools)
        }
        if target != .ocr,
           let temp = ocrVM.outputURL,
           temp == doc.url,
           let copy = ocrVM.handOffResult() {
            return WorkspaceDocument(lineageID: doc.lineageID,
                                     url: copy.url,
                                     password: copy.password ?? doc.password,
                                     completedTools: doc.completedTools)
        }
        if target != .organize,
           let outcome = organizeVM.outcome,
           organizeVM.savedURL == nil,
           outcome.url == doc.url,
           let copy = organizeVM.handOffCurrentOutcome() {
            return WorkspaceDocument(lineageID: doc.lineageID,
                                     url: copy.url,
                                     password: copy.password ?? doc.password,
                                     completedTools: doc.completedTools)
        }
        guard FileManager.default.fileExists(atPath: doc.url.path) else { return nil }
        return doc
    }

    private func deliver(_ doc: WorkspaceDocument, to tool: AppTool, replaceOrganize: Bool) {
        toolDocuments[tool] = doc
        toolResults[tool] = nil
        switch tool {
        case .compress:
            compressionVM.select(doc.url, password: doc.password)
        case .organize:
            if replaceOrganize {
                organizeVM.replaceDocuments(with: doc.url, password: doc.password)
            } else {
                organizeVM.importDocument(doc.url, password: doc.password)
            }
        case .convert:
            conversionVM.accept([doc.url], password: doc.password)
        case .ocr:
            ocrVM.accept([doc.url], password: doc.password)
        }
    }

    /// Beim Werkzeugwechsel (Masterplan B6 / v1.2):
    /// Der aktive Arbeitsstand fließt weiter – nach Komprimieren/OCR/Organisieren
    /// also das aktuelle Ergebnis statt des alten Originals. Laufende Arbeit,
    /// ungesicherte Ergebnisse und bearbeitete Seitenprojekte werden nie
    /// überschrieben.
    private func handOver(to tool: AppTool) {
        guard let active = activeDocument else { return }
        // Hat dieses Werkzeug genau diesen Stand selbst erzeugt, bleibt sein
        // Ergebnis-Bildschirm unverändert stehen.
        if toolResults[tool]?.url == active.url { return }

        switch tool {
        case .compress:
            guard compressionVM.inputURL != active.url,
                  toolDocuments[.compress]?.url != active.url,
                  compressionVM.bulkInputs.isEmpty,
                  !compressionVM.isWorking, !compressionVM.hasUnsavedResult else { return }
            guard let ready = materializedForHandoff(active, target: .compress) else { return }
            deliver(ready, to: .compress, replaceOrganize: false)

        case .organize:
            guard organizeVM.outcome == nil, !organizeVM.isProcessing else { return }
            if organizeVM.containsSource(active.url) || toolDocuments[.organize]?.url == active.url {
                return
            }
            let sameLineageUntouched = !organizeVM.hasChanges
                && organizeVM.project.documents.count == 1
                && toolDocuments[.organize]?.lineageID == active.lineageID
            // Hat Organisieren eigene Bearbeitungen derselben Abstammung, nicht doppelt einfügen.
            if toolDocuments[.organize]?.lineageID == active.lineageID && !sameLineageUntouched {
                return
            }
            guard let ready = materializedForHandoff(active, target: .organize) else { return }
            deliver(ready, to: .organize, replaceOrganize: sameLineageUntouched)

        case .convert:
            guard conversionVM.pdfURL != active.url,
                  toolDocuments[.convert]?.url != active.url,
                  conversionVM.imageURLs.isEmpty,
                  !conversionVM.isWorking, conversionVM.resultFolder == nil,
                  conversionVM.savedPDF == nil else { return }
            guard let ready = materializedForHandoff(active, target: .convert) else { return }
            deliver(ready, to: .convert, replaceOrganize: false)

        case .ocr:
            guard ocrVM.pdfURL != active.url,
                  toolDocuments[.ocr]?.url != active.url,
                  !ocrVM.isWorking, !ocrVM.hasUnsavedResult else { return }
            guard let ready = materializedForHandoff(active, target: .ocr) else { return }
            deliver(ready, to: .ocr, replaceOrganize: false)
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

    /// `--tool compress|organize|convert|ocr` beim Start (G3).
    static func launchArgumentTool(_ arguments: [String] = CommandLine.arguments) -> AppTool? {
        guard let index = arguments.firstIndex(of: "--tool"), index + 1 < arguments.count else { return nil }
        return AppTool(rawValue: arguments[index + 1])
    }

    /// Pfade hinter `--open` (einmalig mit mehreren Pfaden oder wiederholt
    /// `--open <pfad>`, damit AppKit zusätzliche Pfade nicht als freie
    /// Positionsargumente beim Kaltstart abfängt).
    static func launchArgumentFiles(_ arguments: [String] = CommandLine.arguments) -> [URL] {
        var result: [URL] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--open" {
                index += 1
                while index < arguments.count, !arguments[index].hasPrefix("-") {
                    result.append(URL(fileURLWithPath: arguments[index]))
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return result
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
            discardGuard.runAfterProbe(pdfs, ifUnsaved: compressionVM.hasUnsavedResult) {
                compressionVM.selectMany(pdfs)
            }
        case .organize:
            organizeVM.importDocuments(urls)
        case .convert:
            conversionVM.accept(urls)
        case .ocr:
            if pdfs.isEmpty, !images.isEmpty { routeImages(images); return }
            guard !pdfs.isEmpty else { return }
            discardGuard.runAfterProbe(pdfs, ifUnsaved: ocrVM.hasUnsavedResult) {
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
