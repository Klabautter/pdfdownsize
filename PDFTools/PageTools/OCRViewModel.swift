import Foundation
import AppKit
import PDFKit
import Combine
import UniformTypeIdentifiers

/// OCR-Workspace: PDF wählen → lokal erkennen (Apple Vision, DE/EN) →
/// Original mit unsichtbarer Textebene + durchsuchbarer Text. Muster wie
/// `ConversionViewModel`: choose/ready/working/done, Temp-Output +
/// Validierung (Schritt 8), Speichern erst über Save-Panel, Abbruch räumt
/// Temps weg. Seit v2 keine gerasterte Kopie mehr – daher keine Zustimmung.
@MainActor
final class OCRViewModel: ObservableObject {

    enum Stage {
        case choose          // noch keine Quelle
        case ready           // Quelle gesetzt, Sprache wählbar
        case working
        case done
    }

    // MARK: State

    @Published var stage: Stage = .choose
    @Published var pdfURL: URL?
    @Published var languagePreset: OCREngine.OCRLanguagePreset = .germanEnglish

    @Published var isWorking = false
    @Published var progress = 0.0
    @Published var statusLabel = ""
    /// Rohergebnis der Engine; die Textspalte liest `textSections`.
    @Published var pageResults: [OCREngine.PageResult] = [] {
        didSet {
            textSections = Self.sections(from: pageResults)
            updateSearchHits()
        }
    }
    @Published var outputURL: URL?
    @Published var savedURL: URL?
    @Published var errorMessage: String?

    /// View soll den Datei-Importer öffnen (Ablage-Menü).
    @Published var wantsFiles = false

    /// Digitale Signatur im Original: Die Textebene macht sie ungültig.
    @Published var hasSignature = false
    /// Angezeigte Seite – Dokument und Textspalte folgen ihr gemeinsam.
    @Published var currentPage = 0
    /// Suche im erkannten Text; ein neuer Begriff beginnt beim ersten Treffer.
    @Published var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            selectedHit = 0
            updateSearchHits()
        }
    }
    /// Gewählter Treffer (Index in `searchHits`) – ‹ › in der Textspalte.
    @Published var selectedHit = 0
    /// Erkannten Text im Dokument markieren (Toolbar-Schalter).
    @Published var showsRecognizedText = false
    /// Seiten mit erkanntem Text – Grundlage der Markierung.
    var recognizedPageIndices: Set<Int> {
        Set(pageResults.filter { !$0.skippedExistingText && !$0.lines.isEmpty }.map(\.pageIndex))
    }

    // MARK: Textspalte

    /// Ein Seitenabschnitt der Textspalte: Überschrift, Fließtext (Absätze
    /// durch Leerzeilen getrennt) oder ein Hinweis, warum es keinen gibt.
    struct TextSection: Equatable, Identifiable {
        let pageIndex: Int
        let body: String
        let note: String?
        var id: Int { pageIndex }
        var title: String { String(localized: "Seite \(pageIndex + 1)") }
    }

    /// Abschnitte in Seitenreihenfolge – aus `pageResults` abgeleitet.
    @Published private(set) var textSections: [TextSection] = []

    private static func sections(from results: [OCREngine.PageResult]) -> [TextSection] {
        results.sorted { $0.pageIndex < $1.pageIndex }.map { page in
            if page.skippedExistingText {
                return TextSection(pageIndex: page.pageIndex, body: "",
                                   note: String(localized: "Hatte bereits Text und wurde nicht erneut erkannt."))
            }
            let paragraphs = OCRTextLayout.paragraphs(from: page.lines)
            if paragraphs.isEmpty {
                return TextSection(pageIndex: page.pageIndex, body: "", note: String(localized: "Kein Text erkannt."))
            }
            return TextSection(pageIndex: page.pageIndex,
                               body: paragraphs.joined(separator: "\n\n"), note: nil)
        }
    }

    struct SearchHit: Identifiable, Hashable {
        let id: Int
        let pageIndex: Int
        /// Fundstelle im `body` des Seitenabschnitts (UTF-16, für NSTextView).
        let range: NSRange
        /// Umfeld des Treffers, gekürzt.
        let snippet: String
    }

    /// Angezeigte Treffer höchstens – große Dokumente fluten sonst die Liste.
    static let maximumSearchHits = 200

    /// Treffer (höchstens `maximumSearchHits`) und Gesamtzahl – einmal je
    /// Suchbegriff/Ergebnis berechnet, nicht bei jeder Darstellung.
    @Published private(set) var searchHits: [SearchHit] = []
    @Published private(set) var searchHitTotal = 0

    private func updateSearchHits() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchHits = []; searchHitTotal = 0; return }
        var hits: [SearchHit] = []
        var total = 0
        for section in textSections where !section.body.isEmpty {
            let body = section.body
            var searchRange = body.startIndex..<body.endIndex
            while let range = body.range(of: query,
                                         options: [.caseInsensitive, .diacriticInsensitive],
                                         range: searchRange) {
                if total < Self.maximumSearchHits {
                    hits.append(SearchHit(id: total, pageIndex: section.pageIndex,
                                          range: NSRange(range, in: body),
                                          snippet: Self.snippet(body, around: range)))
                }
                total += 1
                searchRange = range.upperBound..<body.endIndex
            }
        }
        searchHits = hits
        searchHitTotal = total
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex)
            ?? text.endIndex
        let excerpt = text[start..<end].replacingOccurrences(of: "\n", with: " ")
        return (start > text.startIndex ? "…" : "") + excerpt
            + (end < text.endIndex ? "…" : "")
    }

    /// Treffer um `delta` weiterschalten (zyklisch) und die Seite mitnehmen.
    func stepHit(_ delta: Int) {
        let hits = searchHits
        guard !hits.isEmpty else { return }
        selectedHit = ((selectedHit + delta) % hits.count + hits.count) % hits.count
        currentPage = hits[selectedHit].pageIndex
    }

    var recognizedPageCount: Int { pageResults.filter { !$0.skippedExistingText }.count }
    var skippedPageCount: Int { pageResults.filter(\.skippedExistingText).count }

    private var workTask: Task<Void, Never>?
    private var operationID = UUID()

    var hasSource: Bool { pdfURL != nil }
    /// Erkannter Text als Fließtext, Seiten durch Leerzeilen getrennt –
    /// derselbe Text wie in der Spalte, ohne Überschriften und Hinweise.
    var fullText: String {
        textSections.map(\.body).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    var hasText: Bool { textSections.contains { !$0.body.isEmpty } }
    var totalWords: Int { pageResults.map(\.wordCount).reduce(0, +) }
    var meanConfidence: Float? {
        let all = pageResults.flatMap(\.lines)
        guard !all.isEmpty else { return nil }
        return all.map(\.confidence).reduce(0, +) / Float(all.count)
    }

    // MARK: Routing

    /// Seitenzahl der geladenen PDF – für die Kopfzeile vor dem Lauf (L8).
    @Published private(set) var pageCount = 0

    /// Durchsuchbare PDF erzeugt, aber noch nicht gesichert (und es wurde
    /// überhaupt etwas erkannt – sonst gibt es nichts zu verlieren).
    var hasUnsavedResult: Bool { outputURL != nil && recognizedPageCount > 0 }

    /// v1: nur PDFs. Bilder → Hinweis auf Konvertieren, gemischt → Organisieren
    /// (gleiche Sprache wie im Convert-Tool, keine stille Halbierung).
    func accept(_ urls: [URL]) {
        guard !isWorking else { return }
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let images = urls.filter { ImageImporter.isSupported($0) }

        if !pdfs.isEmpty && !images.isEmpty {
            errorMessage = String(localized: "Bitte nur eine PDF auswählen – gemischte Dateien kannst du unter „Organisieren“ kombinieren.")
            return
        }
        if let first = pdfs.first {
            resetRunState()
            pageCount = PDFDocument(url: first)?.pageCount ?? 0
            pdfURL = first
            errorMessage = nil
            stage = .ready
            hasSignature = false
            Task.detached(priority: .utility) {
                let signed = Compressor.containsDigitalSignature(at: first)
                await MainActor.run {
                    guard self.pdfURL == first else { return }
                    self.hasSignature = signed
                }
            }
        } else if !images.isEmpty {
            errorMessage = String(localized: "Bilder bitte zuerst unter „Konvertieren“ als PDF sichern.")
        } else if !urls.isEmpty {
            errorMessage = String(localized: "OCR braucht eine PDF-Datei.")
        }
    }

    func reset() {
        guard !isWorking else { return }
        workTask?.cancel()
        workTask = nil
        discardUnsavedOutput()
        stage = .choose
        pdfURL = nil
        isWorking = false
        progress = 0
        statusLabel = ""
        pageResults = []
        outputURL = nil
        savedURL = nil
        errorMessage = nil
        hasSignature = false
        currentPage = 0
        searchQuery = ""
        showsRecognizedText = false
    }

    /// Sichtbarer Abbruch-Zustand für Leiste, Menü und Tests (S3, Review 2026-10-09).
    @Published private(set) var isCancelling = false

    func cancelWork() {
        guard isWorking else { return }
        isCancelling = true
        workTask?.cancel()
    }

    // MARK: Lauf

    func runOCR() {
        guard stage == .ready, let url = pdfURL, !isWorking else { return }
        discardUnsavedOutput()
        let runID = UUID()
        operationID = runID
        isWorking = true
        isCancelling = false
        progress = 0
        statusLabel = "Vorbereiten …"
        errorMessage = nil
        pageResults = []
        outputURL = nil
        savedURL = nil
        stage = .working

        let languages = languagePreset.recognitionLanguages
        workTask = Task { @MainActor in
            defer { isWorking = false; isCancelling = false }
            do {
                let total = PDFDocument(url: url)?.pageCount ?? 0
                let output = try await OCREngine.run(
                    sourceURL: url, languages: languages) { fraction in
                    Task { @MainActor in
                        guard self.isWorking, self.operationID == runID,
                              self.stage != .done else { return }
                        self.progress = fraction
                        // Die Seite, die gerade bearbeitet wird: nie „Seite 0"
                        // (Befund B12). `fraction` meldet den Stand NACH einer
                        // Seite, also ist die nächste in Arbeit.
                        let done = Int((fraction * Double(max(total, 1))).rounded(.down))
                        self.statusLabel = String(localized: "Seite \(min(total, done + 1)) von \(total) …")
                    }
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: output.outputURL)
                    stage = .ready
                    statusLabel = ""
                    return
                }
                // Der Output beweist, was die Oberfläche verspricht: Seitenzahl,
                // qpdf-Struktur, und gegen die Quelle Annotationen, Links,
                // Formularfelder und Geometrie (Befund A3).
                let report = PDFValidator.validate(
                    outputURL: output.outputURL,
                    referenceURL: url,
                    policy: .ocr(expectedPageCount: total, sourceURL: url))
                guard report.isValid else {
                    try? FileManager.default.removeItem(at: output.outputURL)
                    // Den tatsächlichen Grund nennen – vorher hieß es immer
                    // „Seitenzahl" (Befund B12, Review 2026-10-09).
                    throw OCRError.validationFailed(report.failures.joined(separator: "; "))
                }
                pageResults = output.pages
                outputURL = output.outputURL
                stage = .done
                statusLabel = String(localized: "\(output.recognizedPageCount) von \(total) Seiten erkannt")
            } catch is CancellationError {
                stage = .ready
                statusLabel = ""
            } catch {
                errorMessage = error.localizedDescription
                stage = .ready
            }
        }
    }

    // MARK: Ausgabe

    func copyFullText() {
        let text = fullText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Erkannten Text als .txt sichern (Seiten durch Leerzeilen getrennt).
    func saveText() {
        let text = fullText
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let base = (pdfURL?.deletingPathExtension().lastPathComponent).map { $0 + "_Text" }
            ?? String(localized: "Erkannter Text")
        panel.nameFieldStringValue = base + ".txt"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Nur wenn Text erkannt wurde: Ohne erkannte Seite gleicht die Ausgabe
    /// dem Original, es gibt nichts zu sichern (Sichtabnahme 2026-10-12, L7).
    var canSaveSearchablePDF: Bool {
        stage == .done && outputURL != nil && recognizedPageCount > 0
    }

    func saveOutcome() {
        guard canSaveSearchablePDF, let temp = outputURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = (pdfURL?.deletingPathExtension().lastPathComponent).map { $0 + "_" + String(localized: "durchsuchbar", comment: "Dateisuffix") }
            ?? String(localized: "Durchsuchbar")
        panel.nameFieldStringValue = base + ".pdf"
        // Der Name des Originals wird schon im Dialog abgelehnt – vorher kam
        // erst „Ersetzen?" und danach der Hinweis (L10).
        let guardian = SourceNameGuard(source: pdfURL)
        panel.delegate = guardian
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        // „Das Original bleibt unverändert" – also auch nicht überschreiben
        // (Befund B12, Review 2026-10-09).
        if let source = pdfURL, dest.standardizedFileURL == source.standardizedFileURL {
            errorMessage = String(localized: "Bitte einen anderen Namen wählen – das Original bleibt unverändert.")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: dest)
            }
            outputURL = nil
            savedURL = dest
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Intern

    /// Verwirft einen noch nicht gespeicherten Lauf-Output (kein Temp-Leak).
    private func discardUnsavedOutput() {
        if let temp = outputURL {
            try? FileManager.default.removeItem(at: temp)
        }
        outputURL = nil
    }

    private func resetRunState() {
        discardUnsavedOutput()
        currentPage = 0
        searchQuery = ""
        pageResults = []
        savedURL = nil
        isWorking = false
        progress = 0
        statusLabel = ""
    }

}

// MARK: - Sichern-Dialog

/// Lehnt im Sichern-Dialog den Namen der Quelldatei ab, BEVOR macOS nach dem
/// Ersetzen fragt. Die Prüfung in `saveOutcome` bleibt als zweite Sicherung.
private final class SourceNameGuard: NSObject, NSOpenSavePanelDelegate {
    let source: URL?

    init(source: URL?) { self.source = source }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard let source, let panel = sender as? NSSavePanel, let directory = panel.directoryURL else {
            return filename
        }
        var candidate = directory.appendingPathComponent(filename)
        if candidate.pathExtension.isEmpty { candidate.appendPathExtension("pdf") }
        guard candidate.standardizedFileURL == source.standardizedFileURL else { return filename }
        let alert = NSAlert()
        alert.messageText = String(localized: "Bitte einen anderen Namen wählen")
        alert.informativeText = String(localized: "Das Original bleibt unverändert – die durchsuchbare PDF braucht einen eigenen Namen oder Ordner.")
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: panel)
        return nil
    }
}

// MARK: - Absatzbildung

/// Macht aus OCR-Zeilen (Lesereihenfolge, Boxen normiert mit Ursprung
/// unten links) Absätze für die Textspalte. Reine Funktion, ohne Zustand.
///
/// Regeln, in dieser Reihenfolge je Zeilenpaar:
/// 1. Leere Zeile → Absatzende.
/// 2. Dieselbe Textzeile (Tabellenzellen nebeneinander) → mit Leerzeichen anhängen.
/// 3. Vertikaler Sprung deutlich über dem üblichen Zeilenabstand (Leerzeile
///    im Scan) → Absatzende; ebenso vor und nach einer mehrzelligen Zeile
///    (Tabellen- und Formularzeilen fließen nicht in den Text).
/// 4. Aufzählungszeichen oder Nummerierung am Zeilenanfang → neuer Absatz.
/// 5. Satzende (. ! ? :) und die nächste Zeile beginnt groß, mit Ziffer oder
///    Aufzählung → Absatzende, wenn die Zeile spürbar vor dem rechten Rand
///    des Textblocks endet (kurze Schlusszeile). Ohne Geometrie (Nullboxen)
///    gilt die Textregel allein.
/// 6. Trennstrich am Zeilenende: vor Kleinbuchstaben Silbentrennung
///    (Strich fällt weg), sonst echter Bindestrich (bleibt, kein Leerzeichen).
/// 7. Satzzeilen: Mindestens drei aufeinanderfolgende Zeilen, die jede für
///    sich ein ganzer Satz sind (beginnt wie ein Satz, endet mit Satzzeichen),
///    sind eine Liste von Einzelzeilen – jede bleibt ein eigener Absatz, auch
///    wenn alle gleich breit sind und Regel 5 deshalb nicht greift
///    (Sichtabnahme 2026-10-12: 22 Zeilen wurden zu einem Absatz). In
///    Fließtext endet praktisch nie dreimal in Folge ein Satz am Zeilenende.
enum OCRTextLayout {

    static func paragraphs(from lines: [OCREngine.Line]) -> [String] {
        let trimmed = lines.map { ($0, $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let hasGeometry = trimmed.contains { !$0.0.boundingBox.isEmpty }
        let metrics = hasGeometry ? Metrics(lines: trimmed.map(\.0)) : nil
        // Zeilen, die sich eine Textzeile mit einer Nachbarin teilen (Tabellen-
        // und Formularzeilen): sie bleiben je Zeile ein eigener Absatz.
        let sharesRow: [Bool] = trimmed.indices.map { i in
            guard let metrics else { return false }
            let before = i > 0 && metrics.sameRow(trimmed[i - 1].0, trimmed[i].0)
            let after = i + 1 < trimmed.count && metrics.sameRow(trimmed[i].0, trimmed[i + 1].0)
            return before || after
        }

        let sentenceLine = satzzeilen(trimmed.map(\.1))

        var paragraphs: [String] = []
        var current = ""
        var previous: (line: OCREngine.Line, index: Int)?

        func close() {
            if !current.isEmpty { paragraphs.append(current) }
            current = ""
            previous = nil
        }

        for (i, (line, text)) in trimmed.enumerated() {
            guard !text.isEmpty else { close(); continue }                      // 1
            if let prev = previous, let metrics {
                if metrics.sameRow(prev.line, line) {                           // 2
                    current += " " + text
                    previous = (line, i)
                    continue
                }
                if metrics.gapBreaks(prev.line, line) || sharesRow[prev.index] || sharesRow[i] {
                    close()                                                     // 3
                }
            }
            if !current.isEmpty {
                if startsListItem(text) {                                       // 4
                    close()
                } else if let prev = previous,                                  // 7
                          sentenceLine[prev.index] || (sentenceLine[i] && endsSentence(current)) {
                    // In der Folge, an ihrem Ende und an ihrem Anfang (sofern
                    // der Text davor mit einem Satz schließt).
                    close()
                } else if endsSentence(current), startsNewSentence(text),       // 5
                          previous.map({ metrics?.endsShort($0.line) ?? true }) ?? true {
                    close()
                }
            }
            current = current.isEmpty ? text : join(current, text)              // 6
            previous = (line, i)
        }
        close()
        return paragraphs
    }

    // MARK: Textregeln

    /// Kleinste Folge, ab der ganze Sätze je Zeile als Einzelzeilen gelten.
    static let minimumSentenceLineRun = 3

    /// Markiert Zeilen in Folgen von mindestens `minimumSentenceLineRun`
    /// Zeilen, die jede ein vollständiger Satz sind (Regel 7).
    private static func satzzeilen(_ texts: [String]) -> [Bool] {
        let complete = texts.map { !$0.isEmpty && startsNewSentence($0) && endsSentence($0) }
        var marked = [Bool](repeating: false, count: texts.count)
        var start = 0
        while start < complete.count {
            guard complete[start] else { start += 1; continue }
            var end = start
            while end + 1 < complete.count, complete[end + 1] { end += 1 }
            if end - start + 1 >= minimumSentenceLineRun {
                for index in start...end { marked[index] = true }
            }
            start = end + 1
        }
        return marked
    }

    private static func join(_ head: String, _ tail: String) -> String {
        guard let last = head.last else { return tail }
        if last == "-" || last == "\u{AD}" {
            if tail.first?.isLowercase == true { return String(head.dropLast()) + tail }
            return head + tail
        }
        return head + " " + tail
    }

    private static func endsSentence(_ text: String) -> Bool {
        // Schließende Anführungszeichen/Klammern nach dem Satzzeichen zählen mit.
        let closing: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "»", "«", ")", "]"]
        guard let last = text.last(where: { !closing.contains($0) }) else { return false }
        return ".!?:".contains(last)
    }

    private static func startsNewSentence(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first.isUppercase || first.isNumber || startsListItem(text)
    }

    private static let bullets: Set<Character> = ["•", "●", "○", "▪", "‣", "◦", "-", "–", "—", "*"]

    static func startsListItem(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if bullets.contains(first) {
            // Nur mit Leerzeichen danach („- Vollmacht"), nicht „-5 °C".
            return text.dropFirst().first?.isWhitespace == true
        }
        // „1." / „12)" / „a)" / „(b)" vor einem Leerzeichen.
        var index = text.startIndex
        if text[index] == "(" { index = text.index(after: index) }
        let labelStart = index
        while index < text.endIndex, text[index].isNumber || (text[index].isLetter && text.distance(from: labelStart, to: index) < 1) {
            index = text.index(after: index)
        }
        guard index > labelStart, index < text.endIndex, text.distance(from: labelStart, to: index) <= 3 else { return false }
        guard text[index] == "." || text[index] == ")" else { return false }
        let after = text.index(after: index)
        return after == text.endIndex || text[after].isWhitespace
    }

    // MARK: Geometrie

    /// Typischer Zeilenabstand und -höhe eines Blocks (Median: robust gegen
    /// Ausreißer wie Überschriften oder Fußnoten).
    private struct Metrics {
        let pitch: Double?      // Median des Abstands aufeinanderfolgender Zeilen (midY)
        let height: Double      // Median der Zeilenhöhe
        let rightEdge: Double   // rechter Rand des Textblocks

        init(lines: [OCREngine.Line]) {
            let boxes = lines.map(\.boundingBox).filter { !$0.isEmpty }
            let heights = boxes.map { Double($0.height) }.sorted()
            height = Metrics.median(heights) ?? 0
            var steps: [Double] = []
            for (a, b) in zip(boxes, boxes.dropFirst()) {
                let step = Double(a.midY - b.midY)
                if step > height * 0.3 { steps.append(step) }
            }
            pitch = steps.count >= 3 ? Metrics.median(steps.sorted()) : nil
            rightEdge = boxes.map { Double($0.maxX) }.max() ?? 1
        }

        private static func median(_ sorted: [Double]) -> Double? {
            guard !sorted.isEmpty else { return nil }
            let mid = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }

        func sameRow(_ a: OCREngine.Line, _ b: OCREngine.Line) -> Bool {
            let ab = a.boundingBox, bb = b.boundingBox
            guard !ab.isEmpty, !bb.isEmpty else { return false }
            return abs(ab.midY - bb.midY) < min(ab.height, bb.height) / 2 && bb.minX >= ab.minX
        }

        func gapBreaks(_ a: OCREngine.Line, _ b: OCREngine.Line) -> Bool {
            let ab = a.boundingBox, bb = b.boundingBox
            guard !ab.isEmpty, !bb.isEmpty else { return false }
            let step = Double(ab.midY - bb.midY)
            if let pitch, pitch > 0 { return step > pitch * 1.5 }
            return step > Double(max(ab.height, bb.height)) * 1.9
        }

        /// Endet die Zeile spürbar vor dem rechten Rand des Blocks?
        func endsShort(_ line: OCREngine.Line) -> Bool {
            let box = line.boundingBox
            guard !box.isEmpty else { return true }
            let blockWidth = max(rightEdge - Double(box.minX), 0.05)
            return Double(box.maxX) < rightEdge - blockWidth * 0.12
        }
    }
}
