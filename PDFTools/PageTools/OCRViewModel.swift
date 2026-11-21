import Foundation
import pdfcore
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

    /// Der eine Arbeitszustand. Früher stand der Lauf doppelt – in
    /// `stage == .working` und in einem eigenen `isWorking` (plus
    /// `isCancelling`) –, und beides musste von Hand gleich gehalten werden.
    enum Stage: Equatable {
        case choose          // noch keine Quelle
        case ready           // Quelle gesetzt, Sprache wählbar
        case working(cancelling: Bool)
        case done
        /// Masterplan B1: Die Datei lässt sich nicht verarbeiten (gesperrt,
        /// leer, kaputt). Fläche zeigt Grund und nächsten Schritt.
        case rejected(DocumentProbe.Verdict)
    }

    // MARK: State

    @Published var stage: Stage = .choose
    @Published var pdfURL: URL?

    /// Masterplan B2: entsperrte PDF (Passwort nur im Speicher). Erhebung und
    /// Lauf arbeiten auf der Arbeitskopie; gesichert wird mit der
    /// Verschlüsselung des Originals.
    @Published private(set) var unlocked: UnlockedDocument?
    @Published private(set) var passwordError: String?
    @Published private(set) var isUnlocking = false
    /// Die Datei, die gelesen wird.
    var workingURL: URL? { unlocked?.workingCopy ?? pdfURL }
    @Published var languagePreset: OCREngine.OCRLanguagePreset = .germanEnglish

    var isWorking: Bool {
        if case .working = stage { return true }
        return false
    }
    /// Sichtbarer Abbruch-Zustand für Leiste, Menü und Tests (S3, Review 2026-10-09).
    var isCancelling: Bool { stage == .working(cancelling: true) }
    @Published var progress = 0.0
    @Published var statusLabel = ""
    /// Vision lädt beim ersten Lauf nach Installation oder Update bis zu
    /// einer Minute seine Modelle (10.11.2026). Wird erst nach kurzer
    /// Wartezeit sichtbar, damit warme Läufe nicht flackern.
    @Published private(set) var isPreparingRecognition = false
    private var enginePreparing = false
    static let preparationHintDelay: Duration = .milliseconds(1500)

    /// Text der Fortschrittsleiste – während der Vorbereitung deren Hinweis.
    var progressLabel: String {
        isPreparingRecognition ? String(localized: "Texterkennung wird vorbereitet …") : statusLabel
    }
    /// Rohergebnis der Engine; die Textspalte liest `textSections`.
    @Published var pageResults: [OCREngine.PageResult] = [] {
        didSet {
            if !suppressSectionRebuild {
                let built = Self.sections(from: pageResults)
                textSections = built
                totalWords = Self.wordCount(in: built)
            }
            updateSearchHits()
        }
    }
    private var suppressSectionRebuild = false
    /// Gecachte Wortzahl (kein `.split` über alle Seiten bei jedem SwiftUI-Render).
    @Published private(set) var totalWords = 0
    /// Gecachte Dateigröße der geladenen PDF (kein `stat` im View-Body).
    @Published private(set) var fileSize: Int64 = 0
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
            // C6: Tippen startet die Suche erst nach 250 ms Pause.
            updateSearchHits(delay: .milliseconds(250))
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
    struct TextSection: Equatable, Identifiable, Sendable {
        let pageIndex: Int
        let body: String
        let note: String?
        var id: Int { pageIndex }
        var title: String { String(localized: "Seite \(pageIndex + 1)") }
    }

    /// Abschnitte in Seitenreihenfolge – aus `pageResults` abgeleitet.
    @Published private(set) var textSections: [TextSection] = []

    nonisolated private static func sections(from results: [OCREngine.PageResult]) -> [TextSection] {
        results.sorted { $0.pageIndex < $1.pageIndex }.map { page in
            if page.skippedExistingText {
                // Vorhandener Text steht in der Spalte und zählt für Kopieren
                // und „Als Text sichern“ – nur die Markierung im Dokument
                // bleibt den neu erkannten Seiten vorbehalten. Dass er nicht
                // neu erkannt wurde, sagt der Kopf EINMAL (`resultLine`),
                // nicht jede Seite (Rundgang 2026-10-19).
                let existing = Self.paragraphs(fromExistingText: page.existingText ?? "")
                if existing.isEmpty {
                    return TextSection(pageIndex: page.pageIndex, body: "",
                                       note: String(localized: "Hatte bereits Text und wurde nicht erneut erkannt."))
                }
                return TextSection(pageIndex: page.pageIndex, body: existing, note: nil)
            }
            let paragraphs = OCRTextLayout.paragraphs(from: page.lines)
            if paragraphs.isEmpty {
                return TextSection(pageIndex: page.pageIndex, body: "", note: String(localized: "Kein Text erkannt."))
            }
            return TextSection(pageIndex: page.pageIndex,
                               body: paragraphs.joined(separator: "\n\n"), note: nil)
        }
    }

    nonisolated private static func wordCount(in sections: [TextSection]) -> Int {
        sections.reduce(0) { $0 + $1.body.split { $0.isWhitespace || $0.isNewline }.count }
    }

    /// Vorhandenen Seitentext in Absätze bringen: Leerzeilen trennen,
    /// Zeilenumbrüche innerhalb eines Absatzes zu Leerzeichen.
    nonisolated private static func paragraphs(fromExistingText text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isNewline)
                     .map { $0.trimmingCharacters(in: .whitespaces) }
                     .filter { !$0.isEmpty }
                     .joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    struct SearchHit: Identifiable, Hashable, Sendable {
        let id: Int
        let pageIndex: Int
        /// Fundstelle im `body` des Seitenabschnitts (UTF-16, für NSTextView).
        let range: NSRange
        /// Umfeld des Treffers, gekürzt.
        let snippet: String
    }

    /// Angezeigte Treffer höchstens – große Dokumente fluten sonst die Liste.
    nonisolated static let maximumSearchHits = 200

    /// Treffer (höchstens `maximumSearchHits`) und Gesamtzahl – einmal je
    /// Suchbegriff/Ergebnis berechnet, nicht bei jeder Darstellung.
    @Published private(set) var searchHits: [SearchHit] = []
    @Published private(set) var searchHitTotal = 0

    private var searchTask: Task<Void, Never>?

    /// Masterplan C6: Die Suche läuft abseits des Hauptthreads; ein neuer
    /// Begriff bricht die laufende Suche ab. Über 1000 Seiten Text blockierte
    /// sie vorher bei jedem Tastendruck die Oberfläche.
    private func updateSearchHits(delay: Duration = .zero) {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchHits = []; searchHitTotal = 0; return }
        let sections = textSections
        searchTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let (hits, total) = await Task.detached(priority: .userInitiated) {
                Self.searchHits(query: query, in: sections)
            }.value
            guard !Task.isCancelled, let self,
                  self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.searchHits = hits
            self.searchHitTotal = total
        }
    }

    nonisolated static func searchHits(query: String, in textSections: [TextSection]) -> ([SearchHit], Int) {
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
        return (hits, total)
    }

    nonisolated private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
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
    var meanConfidence: Float? {
        let all = pageResults.flatMap(\.lines)
        guard !all.isEmpty else { return nil }
        return all.map(\.confidence).reduce(0, +) / Float(all.count)
    }

    // MARK: Routing

    /// Seitenzahl der geladenen PDF – für die Kopfzeile vor dem Lauf (L8).
    @Published private(set) var pageCount = 0

    /// Vorprüfung (19.10.2026): Welche Seiten haben schon Text? Läuft beim
    /// Laden im Hintergrund. Haben alle Seiten Text, gibt es keinen Lauf –
    /// die Spalte zeigt den vorhandenen Text sofort, Kopieren und „Als
    /// Text sichern" stehen bereit. Vorher lief die Erkennung durch alle
    /// Seiten und meldete erst danach „Keine Seite musste erkannt werden".
    @Published private(set) var survey: OCREngine.TextSurvey?
    private var surveyTask: Task<Void, Never>?

    /// Alle Seiten haben schon Text – nichts zu erkennen.
    var needsNoRecognition: Bool { stage == .ready && survey?.allHaveText == true }
    /// Die Textspalte zeigt Text: nach dem Lauf oder weil alles schon da ist.
    var showsText: Bool { stage == .done || needsNoRecognition }

    /// Die eine Zeile im Kopf, die sagt, was mit den Seiten geschieht oder
    /// geschah: vor dem Lauf aus der Vorprüfung, danach aus dem Ergebnis.
    var resultLine: String? {
        switch stage {
        case .done:
            let recognized = recognizedPageCount, skipped = skippedPageCount
            let total = recognized + skipped
            if recognized == 0 {
                return String(localized: "Alle \(total) Seiten hatten schon Text – nichts musste erkannt werden.")
            }
            if skipped == 0 {
                return String(localized: "Alle \(total) Seiten erkannt.")
            }
            let recognizedPart = recognized == 1
                ? String(localized: "1 Seite erkannt")
                : String(localized: "\(recognized) Seiten erkannt")
            let skippedPart = skipped == 1
                ? String(localized: "1 hatte schon Text")
                : String(localized: "\(skipped) hatten schon Text")
            return recognizedPart + ", " + skippedPart + "."
        case .ready, .working:
            guard let survey, survey.pageCount > 0 else { return nil }
            if survey.allHaveText {
                return String(localized: "Alle \(survey.pageCount) Seiten haben schon Text.")
            }
            if survey.pagesWithText.isEmpty { return nil }
            let toRecognize = survey.pagesToRecognize
            return toRecognize == 1
                ? String(localized: "1 von \(survey.pageCount) Seiten wird erkannt, die übrigen haben schon Text.")
                : String(localized: "\(toRecognize) von \(survey.pageCount) Seiten werden erkannt, die übrigen haben schon Text.")
        case .choose, .rejected:
            return nil
        }
    }

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
            surveyTask?.cancel()
            survey = nil
            pageCount = 0
            discardUnlocked()
            pdfURL = first
            fileSize = Compressor.fileSize(of: first)
            errorMessage = nil
            stage = .ready
            hasSignature = false
            // Vorprüfung (B1) – erst prüfen, dann Erhebung und Signaturscan starten.
            Task.detached(priority: .userInitiated) {
                let verdict = DocumentProbe.inspect(first)
                let signed = verdict.isOK ? Compressor.containsDigitalSignature(at: first) : false
                await MainActor.run {
                    guard self.pdfURL == first, self.stage == .ready else { return }
                    if case .ok(let pages) = verdict {
                        self.pageCount = pages
                        self.hasSignature = signed
                        self.startSurvey(source: first, reading: first)
                    } else {
                        self.surveyTask?.cancel()
                        self.survey = nil
                        self.errorMessage = nil
                        self.stage = .rejected(verdict)
                    }
                }
            }
        } else if !images.isEmpty {
            errorMessage = String(localized: "Bilder bitte zuerst unter „Konvertieren“ als PDF sichern.")
        } else if !urls.isEmpty {
            errorMessage = String(localized: "OCR braucht eine PDF-Datei.")
        }
    }

    /// Erhebung des vorhandenen Texts. `reading` ist bei einer entsperrten
    /// Datei die Arbeitskopie.
    private func startSurvey(source: URL, reading: URL) {
        surveyTask?.cancel()
        surveyTask = Task { @MainActor in
            // Kein `try?` mehr (B1): Ein Fehler hier ist eine Auskunft.
            // Eine gesperrte oder kaputte Datei meldet die Vorprüfung
            // selbst; alles andere steht als Hinweis im Pult.
            let result: OCREngine.TextSurvey
            do {
                result = try await OCREngine.surveyExistingText(sourceURL: reading)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, pdfURL == source, stage == .ready else { return }
                errorMessage = error.localizedDescription
                return
            }
            guard !Task.isCancelled, pdfURL == source, stage == .ready else { return }
            survey = result
            if result.allHaveText {
                // Der vorhandene Text steht sofort in der Spalte.
                pageResults = result.pagesWithText
            }
        }
    }

    /// B2: Passwort prüfen, Arbeitskopie anlegen, Erhebung darauf starten.
    func unlock(password: String) {
        guard stage == .rejected(.locked), let url = pdfURL, !password.isEmpty, !isUnlocking else { return }
        isUnlocking = true
        passwordError = nil
        Task.detached(priority: .userInitiated) {
            let outcome: Result<(UnlockedDocument, Int), Error>
            do {
                guard case .ok(let pages) = DocumentProbe.inspect(url, password: password) else {
                    throw PDFCoreError.openFailed(code: PDFCORE_ERR_PASSWORD.rawValue)
                }
                outcome = .success((try UnlockedDocument.unlock(url, password: password), pages))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                self.isUnlocking = false
                guard self.pdfURL == url, self.stage == .rejected(.locked) else {
                    if case .success(let done) = outcome { done.0.discard() }
                    return
                }
                switch outcome {
                case .success(let (unlocked, pages)):
                    self.unlocked = unlocked
                    self.pageCount = pages
                    self.stage = .ready
                    self.startSurvey(source: url, reading: unlocked.workingCopy)
                case .failure(let error):
                    self.passwordError = UnlockedDocument.failureMessage(for: error)
                }
            }
        }
    }

    private func discardUnlocked() {
        unlocked?.discard()
        unlocked = nil
        passwordError = nil
    }

    func reset() {
        guard !isWorking else { return }
        workTask?.cancel()
        workTask = nil
        surveyTask?.cancel()
        surveyTask = nil
        survey = nil
        discardUnsavedOutput()
        stage = .choose
        pdfURL = nil
        discardUnlocked()
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

    func cancelWork() {
        guard isWorking else { return }
        stage = .working(cancelling: true)
        endPreparation()
        workTask?.cancel()
    }

    // MARK: Lauf

    func runOCR() {
        guard stage == .ready, let url = workingURL, !isWorking, !needsNoRecognition else { return }
        discardUnsavedOutput()
        let runID = UUID()
        operationID = runID
        progress = 0
        statusLabel = "Vorbereiten …"
        errorMessage = nil
        pageResults = []
        outputURL = nil
        savedURL = nil
        stage = .working(cancelling: false)
        endPreparation()

        let languages = languagePreset.recognitionLanguages
        workTask = Task { @MainActor in
            // Jeder Ausgang ohne Ergebnis führt zurück zu `.ready`.
            defer {
                if operationID == runID { endPreparation() }
                if isWorking { stage = .ready }
            }
            do {
                // N14 (C6): Seitenzahl abseits des Main Threads.
                let total = await Task.detached(priority: .userInitiated) {
                    PDFDocument(url: url)?.pageCount ?? 0
                }.value
                let output = try await OCREngine.run(
                    sourceURL: url, languages: languages,
                    preparing: { active in
                        Task { @MainActor in
                            guard self.isWorking, self.operationID == runID else { return }
                            self.preparationChanged(active, runID: runID)
                        }
                    }) { fraction in
                    Task { @MainActor in
                        guard self.isWorking, self.operationID == runID else { return }
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
                statusLabel = String(localized: "Wird geprüft …")
                let report = await PDFValidator.validateOffMain(
                    outputURL: output.outputURL,
                    referenceURL: url,
                    policy: .ocr(expectedPageCount: total, sourceURL: url))
                try Task.checkCancellation()
                guard report.isValid else {
                    try? FileManager.default.removeItem(at: output.outputURL)
                    // Den tatsächlichen Grund nennen – vorher hieß es immer
                    // „Seitenzahl" (Befund B12, Review 2026-10-09).
                    throw OCRError.validationFailed(report.failures.joined(separator: "; "))
                }
                let built = await Task.detached(priority: .userInitiated) {
                    let sections = Self.sections(from: output.pages)
                    return (sections, Self.wordCount(in: sections))
                }.value
                suppressSectionRebuild = true
                textSections = built.0
                totalWords = built.1
                pageResults = output.pages
                suppressSectionRebuild = false
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

    private func preparationChanged(_ active: Bool, runID: UUID) {
        guard active else { endPreparation(); return }
        enginePreparing = true
        Task { @MainActor in
            try? await Task.sleep(for: Self.preparationHintDelay)
            guard enginePreparing, isWorking, !isCancelling, operationID == runID else { return }
            isPreparingRecognition = true
        }
    }

    private func endPreparation() {
        enginePreparing = false
        isPreparingRecognition = false
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
        guard canSaveSearchablePDF, outputURL != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = (pdfURL?.deletingPathExtension().lastPathComponent).map { $0 + "_" + String(localized: "durchsuchbar", comment: "Dateisuffix") }
            ?? String(localized: "Durchsuchbar")
        panel.nameFieldStringValue = base + ".pdf"
        // Wie Komprimieren: der Dialog öffnet im Ordner des Originals – vorher
        // im zuletzt benutzten Ordner (G3: OCR-Ergebnis landete in Dokumente).
        if let dir = pdfURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        // Der Name des Originals wird schon im Dialog abgelehnt – vorher kam
        // erst „Ersetzen?" und danach der Hinweis (L10).
        let guardian = SourceNameGuard(sources: pdfURL.map { [$0] } ?? [])
        panel.delegate = guardian
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        // Masterplan N37: Neuverschlüsseln und Verschieben abseits des Main Threads.
        guard let temp = outputURL else { return }
        let sources = pdfURL.map { [$0] } ?? []
        let unlocked = self.unlocked
        Task { @MainActor in
            do {
                try SourceOverwrite.check(dest, sources: sources)
                try await Task.detached(priority: .userInitiated) {
                    var payload = temp
                    if let unlocked {
                        payload = SessionScratch.makeURL(prefix: "locked-")
                        try unlocked.reencrypt(temp, to: payload)
                    }
                    if FileManager.default.fileExists(atPath: dest.path) {
                        _ = try FileManager.default.replaceItemAt(dest, withItemAt: payload)
                    } else {
                        try FileManager.default.moveItem(at: payload, to: dest)
                    }
                    if payload != temp { try? FileManager.default.removeItem(at: temp) }
                }.value
                guard self.outputURL == temp else { return }
                self.outputURL = nil
                self.savedURL = dest
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Sichert das Ergebnis an ein gegebenes Ziel (ohne Dialog).
    func saveOutcome(to dest: URL) throws {
        guard canSaveSearchablePDF, let temp = outputURL else { return }
        // „Das Original bleibt unverändert" – also auch nicht überschreiben
        // (Befund B12, Review 2026-10-09; Masterplan E3).
        try SourceOverwrite.check(dest, sources: pdfURL.map { [$0] } ?? [])
        // B2: Eine entsperrte Datei geht mit ihrem Passwort zurück.
        var payload = temp
        if let unlocked {
            payload = SessionScratch.makeURL(prefix: "locked-")
            try unlocked.reencrypt(temp, to: payload)
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: payload)
        } else {
            try FileManager.default.moveItem(at: payload, to: dest)
        }
        if payload != temp { try? FileManager.default.removeItem(at: temp) }
        outputURL = nil
        savedURL = dest
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
        surveyTask?.cancel()
        surveyTask = nil
        survey = nil
        discardUnsavedOutput()
        currentPage = 0
        searchQuery = ""
        pageResults = []
        savedURL = nil
        progress = 0
        statusLabel = ""
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
