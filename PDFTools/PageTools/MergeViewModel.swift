import Foundation
import PDFKit
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class MergeViewModel: ObservableObject {

    // MARK: - State

    @Published var project = PageProject()
    @Published var selectedPageIDs: Set<UUID> = []
    @Published var isProcessing = false
    @Published var processingLabel = ""
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var signatureWarningDocs: [String] = []

    /// Art des Result-Outputs – steuert Titel, Statistik und Default-Dateinamen (Review #5/#6).
    enum OutcomeKind: String {
        case merged
        case extracted

        var title: String {
            switch self {
            case .merged: return String(localized: "PDF erstellt")
            case .extracted: return String(localized: "Seiten extrahiert")
            }
        }

        /// Namenszusatz bei der Übergabe ans Komprimieren.
        var handoffSuffix: String {
            switch self {
            case .merged: return String(localized: "zusammengefuehrt", comment: "Dateisuffix")
            case .extracted: return String(localized: "extrahiert", comment: "Dateisuffix")
            }
        }

        var defaultFileName: String {
            switch self {
            case .merged: return String(localized: "Zusammengeführt.pdf")
            case .extracted: return String(localized: "Extrahierte Seiten.pdf")
            }
        }

        /// „X % kleiner als die Originale“ ist nur beim Merge aussagekräftig –
        /// beim Extract wurden Seiten entfernt, nicht komprimiert (#5).
        var showsSizeComparison: Bool {
            self == .merged
        }
    }

    struct MergeOutcome {
        let url: URL
        let pageCount: Int
        let outputBytes: Int64
        let combinedInputBytes: Int64
        let kind: OutcomeKind
    }

    @Published var outcome: MergeOutcome?

    /// Gespeicherte Zieldatei des letzten Merges (auch für Menü-Befehle erreichbar, §33).
    @Published var savedURL: URL?

    /// View soll den Datei-Importer öffnen (aus Menü-Befehl „PDFs hinzufügen …“).
    @Published var wantsImport = false

    /// View soll das Split-Sheet öffnen (aus Menü-Befehl „PDF aufteilen …“).
    @Published var wantsSplit = false

    /// View soll das Bildexport-Sheet öffnen („Seiten als Bilder exportieren …“).
    @Published var wantsImages = false

    /// Unveränderter Import-Zustand – Grundlage für „Änderungen zurücksetzen“ (§22–§25).
    private var baselineProject = PageProject()

    private weak var undoManager: UndoManager?
    private var workTask: Task<Void, Never>?
    /// Kennung des laufenden Merge-/Extract-/Split-Laufs. Fortschritts-
    /// meldungen tragen die Kennung ihres Laufs; eine Meldung, die nach dem
    /// Abbruch oder nach dem Start eines neuen Laufs eintrifft, wird
    /// verworfen statt den Zustand zu überschreiben (Befund B11).
    private var activeRunID = UUID()
    /// Laufender Kompressions-Engine-Task (wird von cancelProcessing mit gestoppt).
    private var engineTask: Task<CompressionResult, Error>?

    // MARK: - Change Tracking

    var hasChanges: Bool {
        project != baselineProject
    }

    func attachUndoManager(_ manager: UndoManager?) {
        undoManager = manager
        // Jede Aktion = genau eine eigene Undo-Gruppe (kein Event-Coalescing).
        manager?.groupsByEvent = false
    }

    private func registerPair(_ label: String,
                              _ undoBody: @escaping () -> Void,
                              _ redoBody: @escaping () -> Void) {
        undoManager?.beginUndoGrouping()
        undoManager?.registerUndo(withTarget: self) { target in
            undoBody()
            target.registerPair(label, redoBody, undoBody)
        }
        undoManager?.setActionName(label)
        undoManager?.endUndoGrouping()
    }

    /// Einheitlicher Edit-Kern: Snapshot vorher/nachher → symmetrisches Undo/Redo (§28).
    /// `syncBaseline: true` zieht die Baseline mit in die Undo-Aktion – nötig für Importe,
    /// damit ⌘Z eines Imports auch die Baseline zurücksetzt (sonst belebt „Änderungen
    /// zurücksetzen" wiederholt entfernte Importe wieder; Review P1, Variante A).
    private func performEdit(_ label: String,
                             syncBaseline: Bool = false,
                             _ mutate: (inout PageProject) -> Void) {
        let before = project
        let baselineBefore = baselineProject
        mutate(&project)
        let after = project
        guard before != after else { return }

        let baselineAfter: PageProject
        if syncBaseline {
            baselineProject = baselineBefore
            mutate(&baselineProject)
            baselineAfter = baselineProject
        } else {
            baselineAfter = baselineBefore
        }

        undoManager?.beginUndoGrouping()
        undoManager?.registerUndo(withTarget: self) { target in
            target.project = before
            target.baselineProject = baselineBefore
            target.registerInverse(label: label,
                                   redo: after, undo: before,
                                   redoBaseline: baselineAfter, undoBaseline: baselineBefore)
        }
        undoManager?.setActionName(label)
        undoManager?.endUndoGrouping()
    }

    private func registerInverse(label: String, redo: PageProject, undo: PageProject,
                                 redoBaseline: PageProject, undoBaseline: PageProject) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.project = redo
            target.baselineProject = redoBaseline
            target.registerInverse(label: label,
                                   redo: undo, undo: redo,
                                   redoBaseline: undoBaseline, undoBaseline: redoBaseline)
        }
        undoManager?.setActionName(label)
    }

    // MARK: - Import

    /// Ergebnis des Import-Scans abseits des Main Threads (B11).
    private enum ImportScan: Sendable {
        case pdf(url: URL, pageCount: Int, signed: Bool)
        case image(original: URL, converted: URL)
        case failed(String)
    }

    func importDocuments(_ urls: [URL]) {
        // Kein Import, während „PDF erstellen"/Teilen/Export läuft – der
        // Plan würde sich unter dem Lauf ändern (S11, Review 2026-10-09;
        // der View-Drop ist gesperrt, ⌘O und onOpenURL kamen hier noch an).
        guard !isProcessing else { return }
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let images = urls.filter { ImageImporter.isSupported($0) }
        guard !pdfs.isEmpty || !images.isEmpty else { return }
        errorMessage = nil

        Task { @MainActor in
            var addedDocs: [SourceDocument] = []
            var addedPages: [PageItem] = []

            // Öffnen, Signatur-Scan und Bildkonvertierung laufen abseits des
            // Main Threads – vorher blockierte ein großer Import die
            // Oberfläche (Befund B11, Review 2026-10-09). Zurück kommen nur
            // Sendable-Werte; Dokumente werden hier nicht festgehalten.
            let scanned = await Task.detached(priority: .userInitiated) { () -> [ImportScan] in
                var result: [ImportScan] = []
                for url in pdfs {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        result.append(.failed(String(localized: "Datei nicht gefunden: \(url.lastPathComponent)")))
                        continue
                    }
                    guard let doc = PDFDocument(url: url), !doc.isLocked else {
                        result.append(.failed(String(localized: "Nicht lesbar oder passwortgeschützt: \(url.lastPathComponent)")))
                        continue
                    }
                    result.append(.pdf(url: url, pageCount: doc.pageCount,
                                       signed: Compressor.containsDigitalSignature(at: url)))
                }
                for url in images {
                    do {
                        result.append(.image(original: url,
                                             converted: try ImageImporter.singlePagePDF(from: url)))
                    } catch {
                        result.append(.failed(error.localizedDescription))
                    }
                }
                return result
            }.value

            for entry in scanned {
                switch entry {
                case .failed(let message):
                    errorMessage = message
                case .pdf(let url, let pageCount, let signed):
                    let source = SourceDocument(url: url, pageCount: pageCount)
                    addedPages.append(contentsOf: (0..<pageCount).map {
                        PageItem(source: source, pageIndex: $0)
                    })
                    addedDocs.append(source)
                    if signed, !signatureWarningDocs.contains(source.fileName) {
                        signatureWarningDocs.append(source.fileName)
                    }
                case .image(let original, let converted):
                    // Bilder → einseitige Temp-PDFs (§65, Feature 4).
                    let source = SourceDocument(url: converted,
                                                pageCount: 1,
                                                displayFileName: original.lastPathComponent)
                    addedDocs.append(source)
                    addedPages.append(PageItem(source: source, pageIndex: 0))
                }
            }

            guard !addedDocs.isEmpty else { return }

            // Baseline wandert MIT in die Undo-Aktion: ⌘Z des Imports entfernt die
            // Dokumente auch aus der Baseline (Review P1, Variante A).
            performEdit(String(localized: "Dokumente hinzufügen"), syncBaseline: true) { p in
                p.documents.append(contentsOf: addedDocs)
                p.pages.append(contentsOf: addedPages)
            }
        }
    }

    // MARK: - Selection

    var orderedSelection: [PageItem] {
        project.pages.filter { selectedPageIDs.contains($0.id) }
    }

    func tapSelect(_ item: PageItem) {
        selectedPageIDs = [item.id]
    }

    func cmdToggle(_ item: PageItem) {
        if selectedPageIDs.contains(item.id) {
            selectedPageIDs.remove(item.id)
        } else {
            selectedPageIDs.insert(item.id)
        }
    }

    func rangeSelect(to item: PageItem, anchor: UUID?) {
        guard let anchor, let from = project.pages.firstIndex(where: { $0.id == anchor }),
              let to = project.pages.firstIndex(where: { $0.id == item.id }) else {
            selectedPageIDs = [item.id]
            return
        }
        selectedPageIDs = Set(project.pages[min(from, to)...max(from, to)].map(\.id))
    }

    func selectAll() {
        selectedPageIDs = Set(project.pages.map(\.id))
    }

    /// Rechtsklick auf nicht selektierte Seite → diese wird die Auswahl (§29).
    func ensureContextSelection(_ item: PageItem) {
        if !selectedPageIDs.contains(item.id) {
            selectedPageIDs = [item.id]
        }
    }

    // MARK: - Reorder V1 – genau eine Position pro Klick (§11–§14)

    func canMoveLeft() -> Bool {
        project.pages.indices.contains { i in
            selectedPageIDs.contains(project.pages[i].id) &&
            i > 0 &&
            !selectedPageIDs.contains(project.pages[i - 1].id)
        }
    }

    func canMoveRight() -> Bool {
        project.pages.indices.contains { i in
            selectedPageIDs.contains(project.pages[i].id) &&
            i < project.pages.count - 1 &&
            !selectedPageIDs.contains(project.pages[i + 1].id)
        }
    }

    func moveSelectionLeft() {
        guard canMoveLeft() else { return }
        let selected = selectedPageIDs
        performEdit(String(localized: "Seiten verschieben")) { p in
            for index in p.pages.indices {
                guard index > 0,
                      selected.contains(p.pages[index].id),
                      !selected.contains(p.pages[index - 1].id) else { continue }
                p.pages.swapAt(index, index - 1)
            }
        }
    }

    func moveSelectionRight() {
        guard canMoveRight() else { return }
        let selected = selectedPageIDs
        performEdit(String(localized: "Seiten verschieben")) { p in
            for index in p.pages.indices.reversed() {
                guard index < p.pages.count - 1,
                      selected.contains(p.pages[index].id),
                      !selected.contains(p.pages[index + 1].id) else { continue }
                p.pages.swapAt(index, index + 1)
            }
        }
    }

    /// Einzelseite oder Gruppe an Zielposition verschieben.
    /// Reihenfolge innerhalb der Gruppe bleibt erhalten; genau eine Undo-Aktion (§20, Phase 7).
    func movePages(_ ids: [UUID], to targetIndex: Int) {
        let movingIDs = Set(ids)
        let moving = project.pages.filter { movingIDs.contains($0.id) }
        guard !moving.isEmpty else { return }

        let label = moving.count == 1 ? String(localized: "Seite verschieben")
                                      : String(localized: "\(moving.count) Seiten verschoben")
        performEdit(label) { p in
            let clampedTarget = max(0, min(p.pages.count, targetIndex))
            // Einfüge-Index zählt nur Seiten, die nicht selbst gezogen werden.
            let keptBefore = p.pages[..<clampedTarget].filter { !movingIDs.contains($0.id) }.count
            p.pages.removeAll { movingIDs.contains($0.id) }
            for (offset, item) in moving.enumerated() {
                p.pages.insert(item, at: min(keptBefore + offset, p.pages.count))
            }
        }
    }

    // MARK: - Rotate / Delete / Reset

    func rotateSelectedPages(by delta: Int) {
        guard !selectedPageIDs.isEmpty else { return }
        performEdit(String(localized: "Drehen")) { p in
            for i in p.pages.indices where selectedPageIDs.contains(p.pages[i].id) {
                p.pages[i].rotation = RotationNormalizer.normalized(p.pages[i].rotation + delta)
            }
        }
    }

    func deleteSelectedPages() {
        guard !selectedPageIDs.isEmpty else { return }
        performEdit(String(localized: "Seiten löschen")) { p in
            p.pages.removeAll { selectedPageIDs.contains($0.id) }
            p.documents.removeAll { doc in
                !p.pages.contains { $0.sourceDocumentID == doc.id }
            }
        }
        selectedPageIDs.removeAll()
    }

    /// Stellt den Import-Zustand wieder her – selbst rückgängig machbar (§21–§27).
    func resetChanges() {
        guard hasChanges else { return }
        // Verworfenes Merge-Ergebnis aufräumen (nicht gespeichert → Temp löschen).
        if let previous = outcome, savedURL == nil {
            try? FileManager.default.removeItem(at: previous.url)
        }
        let before = project
        let base = baselineProject

        project = base
        selectedPageIDs.removeAll()
        outcome = nil
        savedURL = nil
        errorMessage = nil

        registerPair(String(localized: "Änderungen zurücksetzen"),
                     { self.project = before },
                     { self.project = base })
    }

    // MARK: - Merge / Extract (§65)

    /// Erstellt eine neue PDF aus der aktuell angeordneten Seitenfolge.
    func mergeAndPrepare() {
        startOutcome(pages: project.pages, kind: .merged)
    }

    /// Exportiert die Auswahl als eigene PDF – Reihenfolge und Rotationen bleiben
    /// erhalten; das Projekt selbst bleibt unangetastet (Review §65, Feature 1).
    func extractSelectedPages() {
        let pages = orderedSelection
        guard !pages.isEmpty else { return }
        // Summe der beteiligten Quelldokumente (je Dokument einmal); wird beim
        // Extract nicht als „kleiner“-Statistik gezeigt (#5).
        var seenDocs = Set<UUID>()
        let combinedBytes = pages.reduce(Int64(0)) { total, page in
            guard seenDocs.insert(page.sourceDocumentID).inserted else { return total }
            return total + (project.document(for: page.sourceDocumentID)?.fileSize ?? 0)
        }
        startOutcome(pages: pages,
                     kind: .extracted,
                     combinedInputBytes: combinedBytes)
    }

    private func startOutcome(pages: [PageItem],
                              kind: OutcomeKind,
                              combinedInputBytes: Int64? = nil) {
        guard !pages.isEmpty else { return }
        // Alte Temp-Ausgabe aufräumen, bevor ein neuer Lauf startet (kein Leak).
        if let previous = outcome, savedURL == nil {
            try? FileManager.default.removeItem(at: previous.url)
        }
        isProcessing = true
        isCancelling = false
        progress = 0
        processingLabel = "Vorbereiten …"
        errorMessage = nil
        outcome = nil
        savedURL = nil

        let inputBytes = combinedInputBytes ?? project.totalSourceBytes
        let runID = UUID()
        activeRunID = runID

        workTask = Task { @MainActor in
            defer { isProcessing = false; isCancelling = false }
            do {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("pdf")

                // Befund B11: Abbrechen greift in der Bridge zwischen den
                // Seiten und während des Schreibens – `assemble` wirft dann
                // `CancellationError`, und es liegt keine Datei unter
                // `tempURL`. Der Fortschritts-Rückruf prüft den Abbruch auf
                // dem Arbeits-Thread (dort gilt der Task dieses Laufs) und
                // noch einmal auf dem Main Actor über die Laufkennung, damit
                // eine verspätete Meldung keinen beendeten Lauf übermalt.
                try await PageAssemblyService.assemble(pages: pages, to: tempURL) { fraction in
                    guard !Task.isCancelled else { return }
                    Task { @MainActor in
                        guard self.isProcessing, self.activeRunID == runID else { return }
                        self.progress = fraction * 0.9
                        self.processingLabel = "Seite \(Int(fraction * Double(pages.count))) / \(pages.count)"
                    }
                }
                try Task.checkCancellation()

                guard let outDoc = PDFDocument(url: tempURL),
                      outDoc.pageCount == pages.count else {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw MergeError.validationFailed
                }

                // Masterplan Schritt 8 – jeder Output muss seine Operation
                // beweisen: Seitenzahl UND unabhängige Strukturprüfung über
                // libqpdf. PDFKit öffnet auch strukturell beschädigte Dateien.
                let report = PDFValidator.validate(
                    outputURL: tempURL,
                    policy: .pageOperation(expectedPageCount: pages.count))
                guard report.isValid else {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw MergeError.validationFailed
                }

                progress = 1
                outcome = MergeOutcome(url: tempURL,
                                       pageCount: pages.count,
                                       outputBytes: Self.fileSize(tempURL),
                                       combinedInputBytes: inputBytes,
                                       kind: kind)
            } catch is CancellationError {
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Sichtbarer Abbruch-Zustand für Leiste, Menü und Tests (S3, Review 2026-10-09).
    @Published private(set) var isCancelling = false

    func cancelProcessing() {
        guard isProcessing else { return }
        isCancelling = true
        workTask?.cancel()
        engineTask?.cancel()
    }

    // Die Assembly-Implementierung liegt in `PageAssemblyService`
    // (Masterplan Finding 17). Das ViewModel ruft sie nur auf.

    // MARK: - Split (§65, Feature 2)

    /// Schreibt die Teile als einzelne PDFs in den Zielordner.
    /// Kollisionsfreie Namen, Progress über die vorhandene Anzeige;
    /// bei Abbruch werden bereits geschriebene Teile wieder entfernt.
    func writeChunks(_ chunks: [[PageItem]],
                     to folder: URL,
                     baseName: String) async throws -> [URL] {
        guard !chunks.isEmpty else { return [] }
        isProcessing = true
        isCancelling = false
        progress = 0
        processingLabel = "Vorbereiten …"
        errorMessage = nil
        defer { isProcessing = false; isCancelling = false }

        let fm = FileManager.default
        var written: [URL] = []
        let total = chunks.count
        let runID = UUID()
        activeRunID = runID

        do {
            for (i, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                processingLabel = String(localized: "Teil \(i + 1) von \(total) …")

                let index = i + 1
                var dest = folder.appendingPathComponent(
                    PageSplitter.fileName(base: baseName, index: index, total: total))
                var bump = 1
                while fm.fileExists(atPath: dest.path) {
                    dest = folder.appendingPathComponent(
                        "\(baseName)_\(String(localized: "Teil", comment: "Dateiname"))_\(index)_\(bump).pdf")
                    bump += 1
                }

                // Masterplan Schritt 8 – Atomic Result Delivery: erst in den
                // Temp-Workspace schreiben, validieren, und NUR bei PASS in
                // den Zielordner verschieben. Vorher landete jeder Teil
                // ungeprüft direkt beim Nutzer.
                let staging = fm.temporaryDirectory
                    .appendingPathComponent("split-\(UUID().uuidString).pdf")
                defer { try? fm.removeItem(at: staging) }

                // Befund B11: Abbruch greift innerhalb eines Teils; der
                // Fortschritt eines abgebrochenen Laufs übermalt nichts.
                try await PageAssemblyService.assemble(pages: chunk, to: staging) { [weak self] fraction in
                    guard !Task.isCancelled else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.isProcessing, self.activeRunID == runID else { return }
                        self.progress = (Double(i) + fraction) / Double(total)
                    }
                }
                try Task.checkCancellation()

                let report = PDFValidator.validate(
                    outputURL: staging,
                    policy: .pageOperation(expectedPageCount: chunk.count))
                guard report.isValid else {
                    throw MergeError.validationFailed
                }

                try fm.moveItem(at: staging, to: dest)
                written.append(dest)
            }
            progress = 1
            return written
        } catch {
            // Keine halben Ergebnisse im Zielordner hinterlassen.
            for url in written { try? fm.removeItem(at: url) }
            throw error
        }
    }

    // MARK: - Bilder exportieren (§65, Feature 3)

    /// Schreibt die übergebenen Seiten als Bilddateien in den Zielordner.
    func exportImages(_ pages: [PageItem],
                      options: PageImageExporter.Options,
                      to folder: URL) async throws -> [URL] {
        guard !pages.isEmpty else { return [] }
        isProcessing = true
        isCancelling = false
        progress = 0
        processingLabel = "Vorbereiten …"
        errorMessage = nil
        defer { isProcessing = false; isCancelling = false }

        let total = pages.count
        return try await PageImageExporter.export(pages: pages,
                                                  options: options,
                                                  to: folder) { [weak self] fraction in
            Task { @MainActor [weak self] in
                self?.progress = fraction
                self?.processingLabel = "Seite \(Int((fraction * Double(total)).rounded(.up))) / \(total) …"
            }
        }
    }

    // MARK: - Smart nach Merge

    /// Komprimiert das Merge-/Extract-Ergebnis über EXAKT dieselbe zentrale
    /// Pipeline wie das Compress-Tool (#3): SmartCompressor → qpdf → Validation.
    /// Übergibt das Ergebnis an ein anderes Werkzeug: Kopie im Sitzungs-
    /// ordner, damit „Zurück zu den Seiten" das Original-Ergebnis löschen
    /// darf, ohne dem Empfänger die Datei wegzuziehen. Dateiname nach dem
    /// Vorgang, damit der Empfänger einen sprechenden Namen zeigt.
    func handOffOutcome(_ outcome: MergeOutcome) -> URL? {
        let base = (suggestedFileName(for: outcome) as NSString).deletingPathExtension
        let dest = SessionScratch.directory
            .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let file = dest.appendingPathComponent(base).appendingPathExtension("pdf")
            try FileManager.default.copyItem(at: outcome.url, to: file)
            return file
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func compressOutcomeWithSmart() {
        guard let current = outcome, !isProcessing else { return }
        isProcessing = true
        isCancelling = false
        processingLabel = "Smart komprimieren …"
        progress = 0
        errorMessage = nil

        let url = current.url
        let kind = current.kind
        let engine = Task.detached(priority: .userInitiated) {
            try Compressor().compress(
                inputURL: url,
                mode: .smart,
                isCancelled: { Task.isCancelled },
                progress: { fraction, label in
                    Task { @MainActor [weak self] in
                        self?.progress = fraction
                        self?.processingLabel = label
                    }
                })
        }
        engineTask = engine

        workTask = Task { @MainActor in
            defer {
                isProcessing = false
                engineTask = nil
            }
            do {
                let result = try await engine.value

                guard !Task.isCancelled else {
                    // Teil-Ergebnis verwerfen, altes Outcome bleibt bestehen.
                    try? FileManager.default.removeItem(at: result.outputURL)
                    return
                }

                // Regel wie im Compress-Tool: < 1 % Ersparnis gilt als bereits optimiert.
                if result.alreadyOptimized {
                    errorMessage = String(localized: "Keine weitere Verkleinerung möglich.")
                    return
                }

                if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                progress = 1
                outcome = MergeOutcome(url: result.outputURL,
                                       pageCount: current.pageCount,
                                       outputBytes: result.outputBytes,
                                       combinedInputBytes: current.combinedInputBytes,
                                       kind: kind)
            } catch is CancellationError {
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Save

    /// EIN Name für Sichern und für die Übergabe ans Komprimieren
    /// (Sichtabnahme 2026-10-12, L3: vorher „Zusammengeführt.pdf" hier,
    /// „medium_zusammengefuehrt.pdf" dort). Aus dem ersten Quelldokument:
    /// eine Quelle → „_bearbeitet" (es wurde nichts zusammengeführt),
    /// mehrere → „_zusammengeführt", Auswahl → „_extrahiert".
    func suggestedFileName(for outcome: MergeOutcome) -> String {
        let first = project.documents.first?.fileName ?? ""
        let stem = (first as NSString).deletingPathExtension
        guard !stem.isEmpty else { return outcome.kind.defaultFileName }
        let suffix: String
        switch outcome.kind {
        case .merged: suffix = project.documents.count > 1
            ? String(localized: "zusammengeführt", comment: "Dateisuffix")
            : String(localized: "bearbeitet", comment: "Dateisuffix")
        case .extracted: suffix = outcome.kind.handoffSuffix
        }
        return "\(stem)_\(suffix).pdf"
    }

    @discardableResult
    func saveOutcome(_ outcome: MergeOutcome) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedFileName(for: outcome)

        guard panel.runModal() == .OK, let dest = panel.url else { return nil }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: outcome.url)
            } else {
                try FileManager.default.moveItem(at: outcome.url, to: dest)
            }
            savedURL = dest
            return dest
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
    }
}


enum MergeError: LocalizedError {
    case validationFailed
    case assemblyFailed
    case missingSource(String)

    var errorDescription: String? {
        switch self {
        case .validationFailed:
            return String(localized: "Validierung fehlgeschlagen – Seitenzahl der Ausgabe stimmt nicht.")
        case .assemblyFailed:
            return String(localized: "PDF konnte nicht geschrieben werden.")
        case .missingSource(let name):
            return String(localized: "Quelle fehlt oder ist unlesbar: \(name)")
        }
    }
}
