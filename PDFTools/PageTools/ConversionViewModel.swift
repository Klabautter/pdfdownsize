import Foundation
import AppKit
import PDFKit
import Combine
import UniformTypeIdentifiers

/// Konvertieren-Workspace (Review-Feedback §15–17): PDF → Bilder und
/// Bilder → PDF in einem Bereich. Der Eingabetyp bestimmt die Richtung.
@MainActor
final class ConversionViewModel: ObservableObject {

    enum Direction: String {
        case pdfToImages
        case imagesToPdf
    }

    enum Stage {
        case choose          // noch keine Quelle
        case ready           // Quelle gesetzt, Parameter wählbar
        case working
        case done
    }

    // MARK: State

    @Published var stage: Stage = .choose
    @Published var direction: Direction?

    @Published var pdfURL: URL?
    @Published var imageURLs: [URL] = []

    /// Geteilte Export-Einstellungen (Single Source of Truth mit Organize,
    /// siehe `PageImageExporter.Settings`). Zuständigkeit: Convert = schneller
    /// Formatwechsel für einzelne Dateien.
    @Published var exportSettings = PageImageExporter.Settings()

    @Published var isWorking = false
    @Published var progress = 0.0
    @Published var statusLabel = ""
    @Published var resultFolder: URL?
    @Published var savedPDF: URL?
    @Published var errorMessage: String?

    /// View soll den Datei-Importer öffnen (Ablage-Menü).
    @Published var wantsFiles = false

    private var workTask: Task<Void, Never>?
    private var operationID = UUID()

    var hasSource: Bool { pdfURL != nil || !imageURLs.isEmpty }

    // MARK: Routing (§17: Drag&Drop entscheidet automatisch)

    func accept(_ urls: [URL]) {
        guard !isWorking else { return }
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let images = urls.filter { ImageImporter.isSupported($0) }

        // Review P1.2: gemischte Auswahl nicht still halbieren.
        if !pdfs.isEmpty && !images.isEmpty {
            errorMessage = String(localized: "Bitte entweder eine PDF oder Bilder auswählen – gemischte Dateien kannst du unter „Organisieren“ kombinieren.")
            return
        }

        if let first = pdfs.first {
            direction = .pdfToImages
            pdfURL = first
            imageURLs = []
            errorMessage = nil
            stage = .ready
            resultFolder = nil
            savedPDF = nil
        } else if !images.isEmpty {
            direction = .imagesToPdf
            imageURLs = images
            pdfURL = nil
            errorMessage = nil
            stage = .ready
            resultFolder = nil
            savedPDF = nil
        } else if !urls.isEmpty {
            errorMessage = String(localized: "Unterstützt werden PDF- und Bilddateien.")
        }
    }

    /// Importer-Typen je Karte (Review P1.1, Variante A):
    /// Klick bestimmt die Richtung, Drop routet weiterhin automatisch.
    func openImporter(forDirection newDirection: Direction) -> [UTType] {
        switch newDirection {
        case .pdfToImages: return [.pdf]
        case .imagesToPdf: return [.image]
        }
    }

    func reset() {
        guard !isWorking else { return }
        workTask?.cancel()
        workTask = nil
        stage = .choose
        direction = nil
        pdfURL = nil
        imageURLs = []
        isWorking = false
        progress = 0
        statusLabel = ""
        resultFolder = nil
        savedPDF = nil
        errorMessage = nil
    }

    /// Sichtbarer Abbruch-Zustand für Leiste, Menü und Tests (S3, Review 2026-10-09).
    @Published private(set) var isCancelling = false

    func cancelWork() {
        guard isWorking else { return }
        isCancelling = true
        workTask?.cancel()
    }

    // MARK: PDF → Bilder

    nonisolated static func pages(of url: URL) -> [PageItem]? {
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else {
            return nil
        }
        let source = SourceDocument(url: url, pageCount: doc.pageCount)
        return (0..<doc.pageCount).map { PageItem(source: source, pageIndex: $0) }
    }

    func exportPdfToImages(to parent: URL) {
        let folder: URL
        do {
            folder = try PageImageExporter.makeExportFolder(
                in: parent, named: pdfURL?.lastPathComponent ?? String(localized: "Seiten"))
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard !isWorking, direction == .pdfToImages, let url = pdfURL else { return }
        let options = exportSettings.options
        let runID = UUID()
        operationID = runID
        isWorking = true
        isCancelling = false
        progress = 0
        statusLabel = "Vorbereiten …"
        errorMessage = nil

        workTask = Task { @MainActor in
            defer { isWorking = false; isCancelling = false }
            do {
                guard let pages = Self.pages(of: url) else {
                    throw ImageImporter.ImportError.unreadable(url.lastPathComponent)
                }
                let total = pages.count
                let urls = try await PageImageExporter.export(pages: pages,
                                                              options: options,
                                                              to: folder) { fraction in
                    Task { @MainActor in
                        guard self.isWorking, self.operationID == runID,
                              self.stage != .done else { return }
                        self.progress = fraction
                        self.statusLabel = "Seite \(Int((fraction * Double(total)).rounded(.up))) / \(total) …"
                    }
                }
                guard !Task.isCancelled else { return }
                resultFolder = folder
                _ = urls.count
                stage = .done
                statusLabel = String(localized: "\(urls.count) Bilder exportiert")
            } catch is CancellationError {
                statusLabel = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Bilder → PDF

    /// Testbarer Kern: kombiniert alle Bilder in eine temporäre PDF.
    /// Die einseitigen Zwischen-PDFs werden nach dem Merge aufgeräumt (Review P0.4).
    @concurrent nonisolated static func combinedTemporaryPDF(from imageURLs: [URL],
                                                 progress: @escaping (Double) -> Void) async throws -> URL {
        guard !imageURLs.isEmpty else {
            throw ImageImporter.ImportError.unreadable("keine Dateien")
        }
        var intermediatePDFs: [URL] = []
        defer {
            for url in intermediatePDFs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var items: [PageItem] = []
        for (i, imgURL) in imageURLs.enumerated() {
            // Abbrechen greift zwischen den Bildern, nicht erst am Ende
            // (Befund B11, Review 2026-10-09); die Konvertierung selbst
            // läuft abseits des Main Threads.
            try Task.checkCancellation()
            let converted = try await Task.detached(priority: .userInitiated) {
                try ImageImporter.singlePagePDF(from: imgURL)
            }.value
            intermediatePDFs.append(converted)
            let source = SourceDocument(url: converted,
                                        pageCount: 1,
                                        displayFileName: imgURL.lastPathComponent)
            items.append(PageItem(source: source, pageIndex: 0))
            progress(Double(i + 1) / Double(imageURLs.count) * 0.7)
        }

        // Befund B11: Auch das Zusammensetzen ist abbrechbar – die Bridge
        // prüft den Task-Zustand zwischen den Seiten und beim Schreiben und
        // lässt bei Abbruch nichts unter `out` zurück.
        try Task.checkCancellation()
        let out = SessionScratch.makeURL()
        try await PageAssemblyService.assemble(pages: items, to: out) { fraction in
            guard !Task.isCancelled else { return }
            progress(0.7 + fraction * 0.3)
        }
        try Task.checkCancellation()

        // Masterplan Schritt 8 – auch dieser Output beweist seine Operation:
        // Seitenzahl UND unabhängige Strukturprüfung, nicht nur „öffnet sich".
        let report = PDFValidator.validate(
            outputURL: out,
            policy: .imagesToPDF(expectedPageCount: items.count))
        guard report.isValid else {
            try? FileManager.default.removeItem(at: out)
            throw CompressionError.validationFailed
        }
        return out
    }

    /// Kombiniert die geladenen Bilder und speichert sie über ein Save-Panel.
    func saveImagesAsPdf() {
        guard !isWorking, direction == .imagesToPdf, !imageURLs.isEmpty else { return }
        let runID = UUID()
        operationID = runID
        isWorking = true
        isCancelling = false
        progress = 0
        statusLabel = "Erstelle PDF …"
        errorMessage = nil

        let urls = imageURLs
        workTask = Task { @MainActor in
            defer { isWorking = false; isCancelling = false }
            do {
                let tempURL = try await Self.combinedTemporaryPDF(from: urls) { fraction in
                    Task { @MainActor in
                        guard self.isWorking, self.operationID == runID,
                              self.stage != .done else { return }
                        self.progress = fraction
                    }
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }

                let panel = NSSavePanel()
                panel.allowedContentTypes = [.pdf]
                panel.nameFieldStringValue = String(localized: "Konvertiert.pdf")
                guard panel.runModal() == .OK, let dest = panel.url else {
                    try? FileManager.default.removeItem(at: tempURL)
                    statusLabel = ""
                    return
                }

                if FileManager.default.fileExists(atPath: dest.path) {
                    _ = try FileManager.default.replaceItemAt(dest, withItemAt: tempURL)
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                }
                savedPDF = dest
                stage = .done
                statusLabel = String(localized: "Gesichert")
            } catch is CancellationError {
                // nichts tun
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
