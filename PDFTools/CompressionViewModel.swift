import SwiftUI
import PDFKit
import AppKit
import Combine
import UniformTypeIdentifiers

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Fortschritts-Sammelstelle des Bulk-Laufs: Der Phase-8-Runner meldet je
/// Dokument einen Bruchteil, hier entsteht daraus EIN Gesamtwert (Mittel
/// über alle Dokumente). Wird aus parallelen Tasks gerufen, also gesperrt.
private final class BulkProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Double]

    init(count: Int) {
        fractions = Array(repeating: 0, count: count)
    }

    func update(index: Int, fraction: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard fractions.indices.contains(index) else { return 0 }
        fractions[index] = min(max(fraction, 0), 1)
        return fractions.reduce(0, +) / Double(fractions.count)
    }
}

/// Session-State des Komprimierer-Tools.
/// Wird von der AppShell gehalten – Toolwechsel verwirft keine Arbeit (§7).
@MainActor
final class CompressionViewModel: ObservableObject {

    static let dpiPresets: [Int] = [72, 96, 120, 150, 200, 220, 300]
    /// Ab hier weisen wir früh darauf hin, dass ein Lauf mehrere Minuten
    /// dauern kann. Seiten zählen zusätzlich, weil ein langes Scan-PDF trotz
    /// kleiner Dateigröße viel Arbeit verursachen kann.
    nonisolated static let largeInputByteThreshold: Int64 = 25_000_000
    nonisolated static let largeInputPageThreshold = 100

    // MARK: - Session State

    @Published var inputURL: URL?
    @Published var mode: CompressionMode = .smart {
        didSet {
            guard mode != oldValue else { return }
            // Ein ungesichertes Ergebnis gehört zum alten Modus – stehen
            // lassen hieße, eine Smart-Datei unter „Klein" anzubieten.
            clearSingleOutcome()
            errorMessage = nil
            inspectorPinned = (mode == .custom)
            refreshEstimate()
            refreshBulkEstimates()
        }
    }
    /// Läuft gerade ein Einzel- oder Stapellauf? Siehe `Activity`.
    @Published private(set) var activity: Activity = .idle
    /// Ergebnis des Einzelpfads: keins, ungesichert oder gesichert.
    @Published private(set) var singleOutcome: SingleOutcome = .none
    @Published var errorMessage: String?
    @Published var hasSignature = false
    /// Fortschritt des laufenden Laufs; nach einem Stapellauf trägt
    /// `progressLabel` die Zusammenfassung („3 von 4 komprimiert").
    @Published var progressValue: Double = 0
    @Published var progressLabel = ""
    @Published var estimate: CompressionEstimate?
    @Published var estimateRefreshing = false
    /// Phase V2-10 (§16.3) – Zielgrößen-Assessment des Estimators, nur
    /// gesetzt, wenn ein Ziel eingegeben ist und die Schätzung frisch ist.
    @Published var targetAssessment: CompressionEstimator.TargetSizeAssessment?
    /// Geöffnetes Original für die native Ansicht – EINMAL je Datei, nicht
    /// je Seitenwechsel (früher: neu öffnen + rendern bei jedem Klick).
    @Published private(set) var originalDocument: PDFDocument?
    /// Geöffnetes Ergebnis für den Vorher-Nachher-Vergleich.
    @Published private(set) var compressedDocument: PDFDocument?
    /// Angezeigte Seite (0-basiert) – vor dem Lauf die Vorschau, danach der
    /// Vorher/Nachher-Vergleich. Komprimiert wird immer das ganze Dokument.
    @Published private(set) var selectedPage = 0
    /// Miniaturen der Stichprobenseiten (die ersten `samplePageCount`).
    @Published private(set) var pageThumbnails: [Int: NSImage] = [:]
    private var thumbnailTask: Task<Void, Never>?
    /// Seitenleiste als Stichprobe: Ein 300-Seiten-PDF lädt nicht 300
    /// Miniaturen; weitere Seiten erreicht man in der Ansicht selbst.
    static let samplePageCount = 3

    /// Inspector-Wunschzustand – überlebt Toolwechsel, da im VM gehalten.
    @Published var inspectorPinned = false

    // MARK: - Eigene Einstellungen

    /// „Eigene" beginnt bei Smart (Rundgang 2026-10-19): Auflösung, JPEG-
    /// Qualität und Schalter sind beim Öffnen die Werte des Smart-Modus,
    /// die Technik steht auf den Werkseinstellungen der Presets. Die Werte
    /// gelten für den Lauf der App und werden nicht mehr gesichert – mit
    /// gesicherten 150 DPI / 70 % schätzte Eigene beim Öffnen mehr Ersparnis
    /// als Smart und brauchte einen Link „Auf Smart-Werte zurücksetzen".
    @Published var customDPI: Double
    @Published var customQuality: Double
    @Published var customCapEnabled: Bool
    @Published var customMaxPixels: Double
    @Published var customGraphicsJPEG: Bool
    @Published var customForceGray: Bool
    @Published var customStripMetadata: Bool

    // MARK: Phase 9 – Linearisierung (eigener Schalter) und Advanced-Politiken

    /// „Für schnelles Laden im Web optimieren" – getrennt vom Preset:
    /// Linearize ist kein Größenhebel und kann die Datei minimal größer
    /// machen. Der Struktur-Pass setzt daraus `--linearize` (Compressor).
    @Published var linearizeForWeb: Bool {
        didSet { defaults.set(linearizeForWeb, forKey: "compressLinearize") }
    }
    /// Phase V2-10 (§17) – Zielgröße in MB als Freitext (leer = aus). Der
    /// Text wird zu `CompressionGoal.targetBytes` geparst und landet über
    /// `currentOptions.goal` im EINEN Optionsobjekt; es gibt keinen zweiten
    /// Weg zur Engine.
    /// Gilt je Dokument (Rundgang 2026-10-15): Ein einmal eingetragenes
    /// Ziel klebte sonst an jeder weiteren Datei und meldete dort
    /// „verfehlt". Beim Wechsel des Dokuments wird das Feld geleert.
    @Published var targetSizeText: String {
        didSet { scheduleEstimateRefresh() }
    }
    /// S/W-Richtlinie: verlustfreier Race (G4/JBIG2) oder unangetastet.
    @Published var customBilevelPolicy: BilevelPolicy
    /// „Modern" (Objekt-Streams, progressive Scans erlaubt) oder
    /// „Maximal kompatibel" (Baseline-JPEG, Objekt-Streams aus).
    @Published var customCompatibility: CompatibilityPolicy
    /// JPEG-Kodierer; Default mozjpeg, ImageIO als Fallback.
    @Published var customJPEGBackend: JPEGBackend
    /// Phase 5b – Font-Subsetting (seit V2-11 der selektive Pfad mit
    /// je-Font-QA, §14) – wie in den Presets an.
    @Published var customFontSubsetting: Bool

    /// Ablage der persistierten Einstellungen. Injizierbar, damit Tests
    /// nicht die echten Einstellungen der App überschreiben (der Testlauf
    /// teilt sich die Defaults-Domain mit der App als Test-Host).
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Die Bildwerte von Smart und die Werkseinstellungen der Technik –
        // dieselbe Quelle wie der Smart-Modus selbst (`CompressionOptions.smart`).
        let smart = CompressionOptions.smart
        customDPI = Double(Self.dpiPresets[Self.nearestDPIIndex(smart.image.targetDPI)])
        customQuality = min(max(smart.image.jpegQuality, 0.4), 0.95)
        customCapEnabled = smart.image.hardPixelCap
        customMaxPixels = Double(min(max(smart.image.maxPixelEdge, 800), 4000))
        customGraphicsJPEG = smart.image.aggressiveGraphics
        customForceGray = smart.image.forceGrayscale
        customStripMetadata = smart.metadataPolicy == .strip
        linearizeForWeb = defaults.bool(forKey: "compressLinearize")
        targetSizeText = ""
        customBilevelPolicy = smart.image.bilevelPolicy
        customCompatibility = smart.compatibilityPolicy
        customJPEGBackend = smart.image.jpegBackend
        customFontSubsetting = smart.fontSubsettingPolicy == .on
    }

    static func nearestDPIIndex(_ value: Double) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, preset) in dpiPresets.enumerated() {
            let distance = abs(Double(preset) - value)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    // MARK: - Lauf- und Ergebniszustand

    /// Ein laufender Einzel- oder Stapellauf. Das Abbruch-Flag gehört zum
    /// Lauf: Rückmeldungen eines Laufs, der nicht mehr der aktuelle ist
    /// (beendet oder abgelöst), schreiben nichts mehr.
    struct Run {
        let startedAt: Date
        let flag: CancelFlag
        var isCancelling = false
    }

    /// EIN Wert statt der früheren losen Felder `isWorking`, `workStartedAt`,
    /// `isCancelling` und `cancelFlag`: „bricht ab" ohne Lauf oder ein Lauf
    /// ohne Startzeit sind nicht mehr darstellbar.
    enum Activity {
        case idle
        case running(Run)
    }

    /// Ergebnis des Einzelpfads. Früher zwei Optionals (`pendingResult`,
    /// `result`), die nie gleichzeitig gesetzt sein durften.
    enum SingleOutcome {
        case none
        /// Fertig, liegt als Temp-Datei vor und ist noch nicht gesichert.
        case pending(CompressionResult)
        /// Gesichert; `outputURL` ist das Ziel.
        case saved(CompressionResult)
    }

    var isWorking: Bool { currentRun != nil }
    var workStartedAt: Date? { currentRun?.startedAt }
    var isCancelling: Bool { currentRun?.isCancelling ?? false }
    var pendingResult: CompressionResult? {
        if case .pending(let r) = singleOutcome { return r }
        return nil
    }
    var result: CompressionResult? {
        if case .saved(let r) = singleOutcome { return r }
        return nil
    }

    private var currentRun: Run? {
        if case .running(let run) = activity { return run }
        return nil
    }

    /// Gehört `flag` zum laufenden Lauf?
    private func isCurrent(_ flag: CancelFlag) -> Bool {
        currentRun?.flag === flag
    }

    /// idle → running. Setzt den Fortschritt zurück und liefert das
    /// Abbruch-Flag des neuen Laufs.
    private func beginRun() -> CancelFlag {
        let flag = CancelFlag()
        activity = .running(Run(startedAt: Date(), flag: flag))
        progressValue = 0
        progressLabel = String(localized: "Dokument wird analysiert …")
        return flag
    }

    /// running → idle, aber nur für den eigenen Lauf.
    private func endRun(_ flag: CancelFlag) {
        guard isCurrent(flag) else { return }
        activity = .idle
    }

    var canCompress: Bool {
        inputURL != nil && !isWorking
    }

    /// Sichtbarer Vorabhinweis für große/aufwendige Dokumente. Die
    /// Dateigröße ist sofort verfügbar; die Seitenzahl kommt mit der
    /// asynchronen Schätzung hinzu.
    var largeFileNotice: String? {
        guard let inputURL else { return nil }
        let bytes = Compressor.fileSize(of: inputURL)
        let pages = estimate?.pageCount
        guard Self.isLargeDocument(bytes: bytes, pageCount: pages) else { return nil }
        return String(localized: "Große Datei – die Komprimierung kann mehrere Minuten dauern. Sie läuft weiter, bis sie fertig ist oder du abbrichst.")
    }

    nonisolated static func isLargeDocument(bytes: Int64, pageCount: Int?) -> Bool {
        bytes >= largeInputByteThreshold
            || (pageCount ?? 0) >= largeInputPageThreshold
    }

    /// Keine scheingenaue Restzeit: Wir zeigen stattdessen zuverlässig, wie
    /// lange der laufende Job bereits aktiv ist. Das bleibt auch sichtbar,
    /// wenn eine native Bildkodierung längere Zeit keinen Prozentwert meldet.
    nonisolated static func elapsedTimeText(startedAt: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = elapsed / 3_600
        let minutes = (elapsed % 3_600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Phase V2-10 (§17) – das geparste Ziel in Bytes; nil, wenn das Feld
    /// leer oder ungültig ist („aus").
    var goalBytes: Int64? {
        Self.parseTargetBytes(targetSizeText)
    }

    /// Das Ziel als `CompressionGoal` – nil heißt Preset-Politik wie bisher.
    var goal: CompressionGoal? {
        goalBytes.map { CompressionGoal.targetBytes($0) }
    }

    /// MB-Freitext → Bytes. Deutsch-tolerant: Komma oder Punkt als Dezimal-
    /// trenner. „10" und „10,5" → 10 000 000 / 10 500 000 Bytes (ByteCount-
    /// Formatter-Dezimalstil, .file). Leer, nicht-numerisch oder ≤ 0 heißt
    /// AUS – kein stiller Ersatzwert. Obergrenze 1 TB gegen Tippfehler.
    nonisolated static func parseTargetBytes(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite,
              value > 0, value <= 1_000_000 else { return nil }
        return Int64((value * 1_000_000).rounded())
    }

    /// Die Konfiguration des Custom-Pfads.
    ///
    /// `ssimThreshold: 0` und eine einstufige Leiter drücken aus, was gemeint
    /// ist: Der Nutzer hat eine Qualität gewählt, sie wird ausgeführt. Zuvor
    /// stand hier `1.1` – eine per Konstruktion unerreichbare Schwelle, mit
    /// der jedes Bild am Qualitätsgate scheiterte und unverändert blieb.
    /// Custom komprimierte deshalb überhaupt nicht.
    ///
    /// Gelesen wird im Planner die abgeleitete `JPEGQualityPolicy`; diese
    /// Rohwerte bestehen nur noch für die Legacy-Brücke `ImageEngineConfig`.
    /// Die Optionen des Custom-Pfads – aus der PRODUKTIONS-Factory.
    ///
    /// Dieselbe Stelle, die auch der CorpusRunner benutzt: Nur so prüft der
    /// Korpus, was die App tatsächlich tut (Plan 2.2).
    var customOptions: CompressionOptions {
        var options = CompressionPresetFactory.custom(
            dpi: customDPI,
            quality: customQuality,
            grayscale: customForceGray,
            aggressiveGraphics: customGraphicsJPEG,
            maxPixelEdge: Int(customMaxPixels),
            hardPixelCap: customCapEnabled,
            stripMetadata: customStripMetadata)
        // Advanced-Panel-Politiken – dieselben Werte, die auch der
        // Produktionspfad über `currentOptions` erhält.
        options.image.bilevelPolicy = customBilevelPolicy
        options.image.jpegBackend = customJPEGBackend
        options.compatibilityPolicy = customCompatibility
        // Steuert seit V2-11 den SELEKTIVEN Font-Subset-Pfad (je-Font-QA,
        // §14.4); der frühere globale Snapshot-Pass existiert nicht mehr.
        options.fontSubsettingPolicy = customFontSubsetting ? .on : .off
        return options
    }

    /// Kantenlimit, das nie greift (größer als jedes dekodierbare Bild).
    static let unlimitedPixelEdge = 100_000

    var customConfig: ImageEngineConfig {
        // „Bildkante begrenzen" aus ⇒ kein Kantenlimit. Vorher ging der
        // versteckte Slider-Wert (2200) weiter in die Engine und begrenzte
        // Bilder ohne bekannte Platzierung (Befund B6, Review 2026-10-09).
        ImageEngineConfig(
            targetDPI: customDPI,
            maxPixelEdge: customCapEnabled ? Int(customMaxPixels) : Self.unlimitedPixelEdge,
            jpegQuality: customQuality,
            ssimThreshold: 0,
            qualityLadder: [customQuality],
            tolerance: 1.15,
            aggressiveGraphics: customGraphicsJPEG,
            forceGrayscale: customForceGray,
            hardPixelCap: customCapEnabled)
    }

    // MARK: - Aktionen

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let url = panel.url {
            select(url)
        }
    }

    func select(_ url: URL) {
        guard !isWorking else { return }
        workTask?.cancel()
        workTask = nil
        clearBulk()
        clearSingleOutcome()

        inputURL = url
        selectedPage = 0
        errorMessage = nil
        hasSignature = false
        estimate = nil
        targetAssessment = nil
        targetSizeText = ""
        originalDocument = PDFDocument(url: url)

        let currentURL = url
        pageThumbnails = [:]
        thumbnailTask?.cancel()
        thumbnailTask = Task.detached(priority: .utility) {
            guard let doc = PDFDocument(url: currentURL) else { return }
            var thumbs: [Int: NSImage] = [:]
            for index in 0..<min(doc.pageCount, Self.samplePageCount) {
                if Task.isCancelled { return }
                guard let page = doc.page(at: index) else { continue }
                thumbs[index] = page.thumbnail(of: CGSize(width: 80, height: 100), for: .cropBox)
            }
            let ready = thumbs
            await MainActor.run {
                guard self.inputURL == currentURL else { return }
                self.pageThumbnails = ready
            }
        }
        Task.detached(priority: .utility) {
            let signature = Compressor.containsDigitalSignature(at: currentURL)
            await MainActor.run {
                guard self.inputURL == currentURL else { return }
                self.hasSignature = signature
            }
        }
        refreshEstimate()
    }

    /// Single-Auswahl verwerfen – zurück zur leeren Auswahl (dort liegen
    /// „Auswählen …" UND „Mehrere …"). Nur im Ruhezustand; Temps werden
    /// mit entsorgt.
    func clearSingleSelection() {
        guard !isWorking else { return }
        workTask?.cancel()
        workTask = nil
        estimateDebounceTask?.cancel()
        thumbnailTask?.cancel()
        pageThumbnails = [:]
        clearSingleOutcome()
        inputURL = nil
        errorMessage = nil
        hasSignature = false
        estimate = nil
        estimateRefreshing = false
        targetAssessment = nil
        originalDocument = nil
    }

    /// Masterplan Schritt 6 – die UI baut GENAU EIN Optionsobjekt und
    /// übergibt es unverändert an Estimator und Compressor. Es gibt keinen
    /// zweiten Weg, auf dem ein Toggle verloren gehen könnte.
    var currentOptions: CompressionOptions {
        var options = CompressionOptions.make(mode: mode,
                                              customConfig: mode == .custom ? customConfig : nil,
                                              stripMetadata: mode == .custom ? customStripMetadata : false,
                                              linearize: linearizeForWeb,
                                              goal: goal)
        // Die Advanced-Panel-Politiken gelten im Custom-Modus; die Presets
        // behalten ihre Fabrik-Vorgaben (Bilevel-Race an, mozjpeg, modern).
        if mode == .custom {
            options.image.bilevelPolicy = customBilevelPolicy
            options.image.jpegBackend = customJPEGBackend
            options.compatibilityPolicy = customCompatibility
            // Steuert seit V2-11 den SELEKTIVEN Font-Subset-Pfad (§14).
            options.fontSubsettingPolicy = customFontSubsetting ? .on : .off
        }
        return options
    }

    /// Phase 9 – der Schätzer liefert ein Band; die Anzeige nennt den
    /// Bereich statt einer scheingenauen Punktzahl
    /// („Voraussichtlich 8–11 MB"). Gleiche Einheit wird nur einmal genannt.
    nonisolated static func estimateRangeText(low: Int64, high: Int64) -> String {
        String(localized: "Voraussichtlich \(estimateRangeFigure(low: low, high: high))")
    }

    /// Der Bereich allein („8–11 MB") – für Zeilen, die ihr eigenes Wort
    /// davorsetzen (Befund S8: keine String-Ersetzung in der Anzeige).
    nonisolated static func estimateRangeFigure(low: Int64, high: Int64) -> String {
        guard high > low else { return CompressionResult.format(low) }
        let lo = CompressionResult.format(low)
        let hi = CompressionResult.format(high)
        if let unit = sharedUnitSuffix(lo, hi) {
            return "\(lo.dropLast(unit.count))–\(hi)"
        }
        return "\(lo)–\(hi)"
    }

    /// Der gemeinsame Einheits-Suffix zweier formatierter Byteangaben
    /// (etwa „ MB“ bei „8,1 MB“ und „11,3 MB“); nil, wenn die Einheiten
    /// abweichen. Wird „812 Bytes“ gegen „1,1 MB“ gestellt, bleibt der
    /// Suffix leer – genau dann, wenn eine collapsed Form irreführend wäre.
    private nonisolated static func sharedUnitSuffix(_ a: String, _ b: String) -> String? {
        let aChars = Array(a), bChars = Array(b)
        var shared = 0
        while shared < aChars.count && shared < bChars.count
                && aChars[aChars.count - 1 - shared] == bChars[bChars.count - 1 - shared] {
            shared += 1
        }
        let suffix = String(aChars[(aChars.count - shared)...])
        // Eine echte Einheit steht hinter einem Leerzeichen und lässt auf
        // BEIDEN Seiten eine Zahl übrig.
        guard shared > 0, shared < aChars.count, shared < bChars.count,
              suffix.first?.isWhitespace == true else { return nil }
        return suffix
    }

    /// Aktualisiert die Schätzung; bei gesetztem Ziel zusätzlich das
    /// §16.3-Assessment (Reachability + „sicher erreichbar ca. X").
    @discardableResult
    func refreshEstimate() -> Task<Void, Never>? {
        estimateGeneration += 1
        let generation = estimateGeneration
        guard let url = inputURL else {
            estimateRefreshing = false
            return nil
        }
        let currentURL = url
        let currentMode = mode
        let options = currentOptions
        let goal = self.goal
        let estimateProvider = self.estimateProvider
        estimateRefreshing = true
        // Ein neuer Stand macht den laufenden Plan wertlos – abbrechen statt
        // ihn weiterrechnen zu lassen (sonst laufen bei jedem Moduswechsel
        // mehrere volle Planungen parallel zur Kompression).
        estimateTask?.cancel()
        let task = Task.detached(priority: .utility) {
            let estimated = estimateProvider(currentURL, options)
            guard !Task.isCancelled else { return }
            let assessment = goal.flatMap { goalValue in
                CompressionEstimator.assessTargetSize(url: currentURL,
                                                      goal: goalValue)
            }
            await MainActor.run {
                guard self.estimateGeneration == generation else { return }
                self.estimateRefreshing = false
                // Verworfene Läufe (Feld weitergetippt) schreiben nicht:
                // Das Ziel gehört zur Schätzung, sonst mischen sich
                // Candidate-Engine-Pläne verschiedener Ziele.
                guard self.inputURL == currentURL,
                      self.mode == currentMode,
                      self.goal == goal,
                      self.currentOptions == options,
                      let estimated else { return }
                self.estimate = estimated
                self.targetAssessment = assessment
            }
        }
        estimateTask = task
        return task
    }

    /// Tastatureingabe ins Zielgrößen-Feld: Je Tastendruck keine Planung –
    /// der vorherige geparkte Refresh wird verworfen (Debounce).
    private func scheduleEstimateRefresh() {
        estimateGeneration += 1
        estimateDebounceTask?.cancel()
        guard inputURL != nil else { return }
        estimateDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            refreshEstimate()
        }
    }

    func compress() {
        guard let input = inputURL, canCompress else { return }
        workTask?.cancel()

        // Ein noch ungesichertes Ergebnis würde sonst ohne Temp-Aufräumen
        // ersetzt (nur programmatisch erreichbar; die Oberfläche zeigt dann
        // keinen Komprimieren-Knopf).
        clearSingleOutcome()
        errorMessage = nil
        let flag = beginRun()
        // Dasselbe Optionsobjekt, das auch die Schätzung erzeugt hat.
        let options = currentOptions
        workTask = Task.detached(priority: .userInitiated) {
            var completed: CompressionResult?
            do {
                let tempResult = try Compressor().compress(inputURL: input,
                                                           options: options,
                                                           isCancelled: { flag.isCancelled }) { fraction, label in
                    Task { @MainActor in
                        // Verspätete Meldungen nach Laufende schreiben nicht mehr.
                        guard self.isCurrent(flag) else { return }
                        self.progressValue = fraction
                        self.progressLabel = ProgressText.userFacing(label)
                    }
                }
                completed = tempResult
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.isCurrent(flag) else {
                        try? FileManager.default.removeItem(at: tempResult.outputURL)
                        return
                    }
                    self.endRun(flag)
                    self.singleOutcome = .pending(tempResult)
                }
            } catch is CancellationError {
                // Epic P9: fertige Temp-Ausgabe bei Abbruch sofort entsorgen.
                if let done = completed {
                    try? FileManager.default.removeItem(at: done.outputURL)
                }
                await MainActor.run {
                    guard self.isCurrent(flag) else { return }
                    self.endRun(flag)
                    self.progressLabel = ""
                }
            } catch {
                await MainActor.run {
                    guard self.isCurrent(flag) else { return }
                    self.errorMessage = Self.userFacingMessage(for: error)
                    self.endRun(flag)
                }
            }
        }
    }

    func cancelWork() {
        guard case .running(var run) = activity else { return }
        run.isCancelling = true
        activity = .running(run)
        progressLabel = String(localized: "Wird abgebrochen …")
        run.flag.cancel()
        workTask?.cancel()
    }

    // MARK: - Bulk (Phase 8 + Bulk-UI)

    /// Ein erfolgreich komprimiertes Stapel-Dokument. Eingabe, Ergebnis und
    /// Sicherungsziel stehen zusammen – früher drei parallele Listen
    /// (`bulkResults`, `bulkResultInputs`, `bulkSavedURLs`) plus eine
    /// Gesichert-Menge in der View, die beim Werkzeugwechsel verloren ging.
    struct BulkSuccess {
        let input: URL
        let result: CompressionResult
        /// Ziel nach dem Sichern; nil = noch ungesichert.
        var savedTo: URL?
    }

    /// Erfolge des letzten Bulk-Laufs, in Eingabereihenfolge.
    @Published private(set) var bulkSuccesses: [BulkSuccess] = []
    var bulkResults: [CompressionResult] { bulkSuccesses.map(\.result) }
    var bulkResultInputs: [URL] { bulkSuccesses.map(\.input) }
    /// Eingaben des (laufenden oder letzten) Bulk-Laufs, in Reihenfolge.
    @Published private(set) var bulkInputs: [URL] = []
    /// Billige Metadaten je Bulk-Eingabe (nur Öffnen, kein Planen):
    /// Seitenzahl für die Listenanzeige, asynchron nachgeladen.
    @Published private(set) var bulkPageCounts: [URL: Int] = [:]
    /// Schnellschätzung je Bulk-Eingabe für den gewählten Modus.
    @Published private(set) var bulkEstimates: [URL: CompressionEstimate] = [:]
    private var bulkEstimateTask: Task<Void, Never>?
    /// Modus, mit dem der letzte Bulk-Lauf gestartet wurde – bestimmt die
    /// Namensvorschläge beim Sichern (Suffix je Stufe statt immer „klein").
    private(set) var bulkMode: CompressionMode = .smart
    /// Fortschritt je Dokument-Index (0…1) für die Listenanzeige.
    @Published private(set) var bulkFractions: [Int: Double] = [:]
    /// Aktuelle Stufenmeldung je Dokument-Index.
    @Published private(set) var bulkLabels: [Int: String] = [:]
    /// Fehlermeldung je Eingabe (kein Erfolg für diese Datei).
    @Published private(set) var bulkErrors: [URL: String] = [:]
    /// Einzeln abgebrochene Eingaben (laufen nicht mehr, Rest läuft weiter).
    @Published private(set) var bulkCancelledURLs: Set<URL> = []
    /// Gesicherte Ziele, in Reihenfolge der Ergebnisse.
    var bulkSavedURLs: [URL] { bulkSuccesses.compactMap(\.savedTo) }

    /// Wurde das Ergebnis zu dieser Eingabe schon gesichert?
    func isBulkResultSaved(for url: URL) -> Bool {
        bulkSuccesses.first { $0.input == url }?.savedTo != nil
    }

    /// Alle Erfolge gesichert (und es gibt mindestens einen).
    var allBulkResultsSaved: Bool {
        !bulkSuccesses.isEmpty && bulkSuccesses.allSatisfy { $0.savedTo != nil }
    }

    /// true, sobald mehr als ein Dokument für Bulk ausgewählt ist.
    var isBulkSelection: Bool { bulkInputs.count > 1 }

    /// Phase 8 – Bulk-Kern (sammelnd): mehrere unabhängige Dokumente über
    /// den Runner komprimieren. EINE fehlerhafte oder einzeln abgebrochene
    /// Datei bricht den Lauf NICHT ab – ihr Fehler steht in `bulkErrors`,
    /// ihr Abbruch in `bulkCancelledURLs`, der Rest läuft weiter. Nur der
    /// globale Abbruch (cancelWork / Task-Abbruch) wirft CancellationError.
    ///
    /// Fortschritt läuft zweigleisig: `progressValue`/`progressLabel` als
    /// Gesamtwert plus `bulkFractions`/`bulkLabels` je Dokument für die
    /// Listenanzeige. Liefert die Erfolge in Eingabereihenfolge.
    @discardableResult
    func runBulkCompression(_ urls: [URL]) async throws -> [CompressionResult] {
        guard let flag = beginBulkRun(urls) else { return [] }
        return try await performBulkRun(urls, flag: flag)
    }

    /// idle → running für einen Stapel – synchron, damit zwischen Klick und
    /// Laufbeginn kein Moment liegt, in dem die Oberfläche noch „bereit"
    /// zeigt und ein zweiter Klick einen zweiten Lauf startet.
    private func beginBulkRun(_ urls: [URL]) -> CancelFlag? {
        guard !urls.isEmpty, !isWorking else { return nil }
        // Alte Bulk-Temps entsorgen, bevor neue entstehen.
        discardBulkResults()
        bulkInputs = urls
        bulkMode = mode
        bulkFractions = Dictionary(uniqueKeysWithValues: urls.indices.map { ($0, 0.0) })
        bulkLabels = [:]
        bulkErrors = [:]
        bulkCancelledURLs = []
        // Einzel-State parken: Bulk und Einzel teilen sich Fortschritt/Abbruch.
        clearSingleOutcome()
        errorMessage = nil
        return beginRun()
    }

    private func performBulkRun(_ urls: [URL], flag: CancelFlag) async throws -> [CompressionResult] {
        // Ein Nachfolger hat das Ruder übernommen – dann räumt der nicht mehr.
        defer { endRun(flag) }

        // Dasselbe Optionsobjekt wie im Einzellauf: Custom-Panel,
        // Zielgröße und Linearize gelten für JEDE Bulk-Datei.
        let options = currentOptions
        let progress = BulkProgressAccumulator(count: urls.count)
        do {
            let outcomes = try await CompressionConcurrency.compressDocumentsCollecting(
                inputURLs: urls,
                options: options,
                isCancelled: { flag.isCancelled || Task.isCancelled },
                isCancelledFor: { [weak self] _, url in
                    self?.bulkCancelledURLs.contains(url) ?? false
                },
                onDocumentProgress: { index, url, fraction, label in
                    let overall = progress.update(index: index, fraction: fraction)
                    Task { @MainActor [weak self] in
                        // Nach Laufende keine verspätete Meldung mehr
                        // durchlassen (die Zusammenfassung bleibt stehen).
                        guard let self, self.isCurrent(flag),
                              self.progressValue < 1 else { return }
                        self.progressValue = overall
                        self.progressLabel = "\(url.lastPathComponent) "
                            + String(localized: "(\(index + 1) von \(urls.count))")
                            + " – \(ProgressText.userFacing(label))"
                        self.bulkFractions[index] = fraction
                        self.bulkLabels[index] = label
                    }
                })
            try Task.checkCancellation()
            var successes: [BulkSuccess] = []
            var errors: [URL: String] = [:]
            for (index, outcome) in outcomes.enumerated() {
                let url = urls[index]
                switch outcome {
                case .success(let r):
                    successes.append(BulkSuccess(input: url, result: r))
                case .failure(let error):
                    if error is CancellationError,
                       bulkCancelledURLs.contains(url) {
                        // Einzeln abgebrochen – steht bereits in der Menge,
                        // kein Fehlertext nötig.
                    } else {
                        errors[url] = Self.userFacingMessage(for: error)
                    }
                }
                bulkFractions[index] = 1
            }
            bulkSuccesses = successes
            bulkErrors = errors
            progressValue = 1
            let ok = successes.count
            let cancelled = bulkCancelledURLs.count
            let failed = errors.count
            progressLabel = Self.bulkSummaryText(total: urls.count, ok: ok,
                                                 cancelled: cancelled, failed: failed)
            return successes.map(\.result)
        } catch is CancellationError {
            // Wie im Einzelpfad: globaler Abbruch ist kein Fehler.
            if isCurrent(flag) { progressLabel = "" }
            throw CancellationError()
        } catch {
            if isCurrent(flag) { errorMessage = error.localizedDescription }
            throw error
        }
    }

    /// Zusammenfassung nach einem Sammellauf („3 von 4 komprimiert").
    nonisolated static func bulkSummaryText(total: Int, ok: Int,
                                            cancelled: Int, failed: Int) -> String {
        let text = String(localized: "\(ok) von \(total) komprimiert")
        var rest: [String] = []
        if cancelled > 0 { rest.append(String(localized: "\(cancelled) abgebrochen")) }
        if failed > 0 { rest.append(String(localized: "\(failed) fehlgeschlagen")) }
        guard !rest.isEmpty else { return text }
        return text + " (\(rest.joined(separator: ", ")))"
    }

    /// Bricht genau EINE Bulk-Datei ab – der Rest läuft weiter. Vor dem
    /// Start ist das ein schlichtes Entfernen (siehe `removeBulkInput`).
    func cancelBulkFile(at index: Int) {
        guard isWorking,
              bulkInputs.indices.contains(index) else { return }
        bulkCancelledURLs.insert(bulkInputs[index])
        bulkLabels[index] = String(localized: "Wird abgebrochen …")
    }

    /// Entfernt eine Bulk-Datei aus der Liste (nur im Ruhezustand).
    /// Zugehörige Temps, Fehler- und Abbruchvermerke werden mit aufgeräumt.
    func removeBulkInput(at index: Int) {
        guard !isWorking,
              bulkInputs.indices.contains(index) else { return }
        let url = bulkInputs[index]
        if let i = bulkSuccesses.firstIndex(where: { $0.input == url }) {
            // Das Temp bleibt auch nach dem Sichern liegen (Kopie beim
            // Sichern) und geht jetzt mit.
            try? FileManager.default.removeItem(at: bulkSuccesses[i].result.outputURL)
            bulkSuccesses.remove(at: i)
        }
        bulkInputs.remove(at: index)
        bulkErrors.removeValue(forKey: url)
        bulkCancelledURLs.remove(url)
        bulkPageCounts.removeValue(forKey: url)
        bulkEstimates.removeValue(forKey: url)
        bulkFractions = [:]
        bulkLabels = [:]
    }

    /// Erfolg zu einer Bulk-Eingabe (nil ohne Erfolg).
    func bulkResult(for url: URL) -> CompressionResult? {
        bulkSuccesses.first { $0.input == url }?.result
    }

    /// UI-Einstieg für einen Bulk-Lauf – fire-and-forget wie compress().
    /// Zustand, Fortschritt und Fehlermeldung verwaltet runBulkCompression;
    /// ein geworfener Fehler ist dort bereits gesichtet und wird hier nur
    /// noch eingesammelt.
    func compressAll(_ urls: [URL]) {
        guard !urls.isEmpty, !isWorking else { return }
        workTask?.cancel()
        // Einzel-State zurücksetzen, damit die Bulk-Liste die Bühne bekommt.
        inputURL = nil
        guard let flag = beginBulkRun(urls) else { return }
        workTask = Task.detached(priority: .userInitiated) {
            _ = try? await self.performBulkRun(urls, flag: flag)
        }
    }

    /// Mehrfach-Auswahl (Open-Panel). Eine Datei → Einzelpfad, mehrere →
    /// Bulk-Liste. Nur PDFs, duplikatbereinigt, sortiert für Determinismus.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK {
            selectMany(panel.urls)
        }
    }

    /// Drop/Panel-Eingang für 1…n URLs. Leere und Nicht-PDFs werden
    /// still übergangen; bleibt genau ein PDF, gilt der Einzelpfad.
    func selectMany(_ urls: [URL]) {
        guard !isWorking else { return }
        let pdfs = urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .reduce(into: [URL]()) { acc, url in
                if !acc.contains(url) { acc.append(url) }
            }
            .sorted(by: { $0.path < $1.path })
        guard !pdfs.isEmpty else {
            errorMessage = String(localized: "Bitte nur PDF-Dateien ablegen.")
            return
        }
        workTask?.cancel()
        workTask = nil
        if pdfs.count == 1 {
            clearBulk()
            select(pdfs[0])
        } else {
            clearSingleOutcome()
            errorMessage = nil
            inputURL = nil
            originalDocument = nil
            targetSizeText = ""
            thumbnailTask?.cancel()
            pageThumbnails = [:]
            estimate = nil
            targetAssessment = nil
            discardBulkResults()
            bulkInputs = pdfs
            bulkFractions = [:]
            bulkLabels = [:]
            bulkErrors = [:]
            bulkCancelledURLs = []
            bulkPageCounts = [:]
            refreshBulkPageCounts()
            refreshBulkEstimates()
        }
    }

    /// Weitere PDFs hinzufügen: aus einer Einzeldatei wird ein Stapel, ein
    /// bestehender Stapel wächst. Duplikate fallen in `selectMany` heraus.
    func addFiles() {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        panel.prompt = String(localized: "Hinzufügen")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        add(panel.urls)
    }

    /// Wie `addFiles`, ohne Panel (Drop auf eine geöffnete Datei).
    func add(_ urls: [URL]) {
        let existing = bulkInputs.isEmpty ? (inputURL.map { [$0] } ?? []) : bulkInputs
        selectMany(existing + urls)
    }

    /// Schnellschätzung je Datei (Millisekunden je Dokument), neu bei
    /// Auswahl- und Moduswechsel.
    func refreshBulkEstimates() {
        bulkEstimateTask?.cancel()
        let urls = bulkInputs
        guard !urls.isEmpty else { bulkEstimates = [:]; return }
        let options = currentOptions
        bulkEstimateTask = Task.detached(priority: .utility) {
            var estimates: [URL: CompressionEstimate] = [:]
            for url in urls {
                if Task.isCancelled { return }
                if let e = CompressionEstimator.quickEstimate(
                    url: url, options: options, isCancelled: { Task.isCancelled }) {
                    estimates[url] = e
                }
            }
            await MainActor.run {
                guard self.bulkInputs == urls, !Task.isCancelled else { return }
                self.bulkEstimates = estimates
            }
        }
    }

    /// Lädt die Seitenzahlen der Bulk-Liste billig nach (nur Öffnen, kein
    /// Planen wie die Schätzung). Schreibt nur, wenn die Auswahl seither
    /// unverändert ist.
    private func refreshBulkPageCounts() {
        let urls = bulkInputs
        Task.detached(priority: .utility) {
            var counts: [URL: Int] = [:]
            for url in urls {
                if let doc = PDFDocument(url: url), !doc.isLocked {
                    counts[url] = doc.pageCount
                }
            }
            await MainActor.run {
                guard self.bulkInputs == urls else { return }
                self.bulkPageCounts = counts
            }
        }
    }

    /// Bulk-Auswahl + Temps verwerfen (Einzel-State bleibt unberührt).
    func clearBulk() {
        guard !isWorking else { return }
        discardBulkResults()
        bulkInputs = []
        bulkFractions = [:]
        bulkLabels = [:]
        bulkErrors = [:]
        bulkCancelledURLs = []
        bulkPageCounts = [:]
        bulkEstimates = [:]
    }

    /// Verwirft die Erfolge samt Temps (gesicherte Ziele sind Kopien).
    private func discardBulkResults() {
        for success in bulkSuccesses {
            try? FileManager.default.removeItem(at: success.result.outputURL)
        }
        bulkSuccesses = []
    }

    /// Speichert alle erfolgreichen Bulk-Ergebnisse in einen Ordner.
    /// Namen folgen dem Lauf-Modus (`_klein`/`_smart`/`_qualitaet`/`_eigene`),
    /// Namenskonflikte bekommen einen nummerierten Suffix. Fehlgeschlagene oder abgebrochene
    /// Dateien werden übersprungen. Liefert die Ziel-URLs.
    /// Temp-Dateien bleiben bis zum Verwerfen der Auswahl erhalten.
    @discardableResult
    func saveAllBulk(to folder: URL) throws -> [URL] {
        guard !bulkSuccesses.isEmpty else { return [] }
        var saved: [URL] = []
        for index in bulkSuccesses.indices {
            let input = bulkSuccesses[index].input
            let result = bulkSuccesses[index].result
            let suggested = folder.appendingPathComponent(
                Compressor.suggestedOutputName(for: input, mode: bulkMode))
            var dest = suggested
            var suffix = 2
            while FileManager.default.fileExists(atPath: dest.path)
                || saved.contains(where: { $0.path.caseInsensitiveCompare(dest.path) == .orderedSame }) {
                dest = folder.appendingPathComponent(
                    suggested.deletingPathExtension().lastPathComponent + "_\(suffix).pdf")
                suffix += 1
            }
            let finalized = try Compressor.finalize(result: result, destination: dest,
                                                     preservingSource: true)
            saved.append(finalized.outputURL)
            // Bereits gespeicherte Erfolge bleiben auch bei einem spaeteren Fehler sichtbar.
            bulkSuccesses[index].savedTo = finalized.outputURL
        }
        return saved
    }

    /// Sichert EIN Bulk-Ergebnis über ein Save-Panel – hier ist der Name
    /// frei wählbar (Vorschlag: Eingabename + Modus-Suffix).
    func saveBulkResult(for url: URL) {
        guard let result = bulkResult(for: url) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = Compressor.suggestedOutputName(for: url, mode: bulkMode)
        if let dir = url.deletingLastPathComponent() as URL? {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            _ = try Compressor.finalize(result: result, destination: dest,
                                        preservingSource: true)
            if let i = bulkSuccesses.firstIndex(where: { $0.input == url }) {
                bulkSuccesses[i].savedTo = dest
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Gesamt-Ersparnis über die erfolgreichen Bulk-Ergebnisse
    /// (Summen, nicht Mittel).
    var bulkSavedPercent: Double {
        let input = bulkResults.reduce(0) { $0 + $1.inputBytes }
        let output = bulkResults.reduce(0) { $0 + $1.outputBytes }
        guard input > 0 else { return 0 }
        return (1 - Double(output) / Double(input)) * 100
    }

    /// Öffnet das Ergebnis für den Vergleich (einmal je Ergebnis).
    func loadCompressedDocument() {
        guard let pending = pendingResult else { return }
        if compressedDocument?.documentURL == pending.outputURL { return }
        compressedDocument = PDFDocument(url: pending.outputURL)
    }

    /// Wechselt die angezeigte Seite – Vorschau und (nach dem Lauf)
    /// Vergleich folgen ihr. Kein Neuöffnen, kein Neurendern: die native
    /// Ansicht blättert nur.
    func showPage(_ index: Int) {
        let last = max((originalDocument?.pageCount ?? estimate?.pageCount ?? 1) - 1, 0)
        let clamped = min(max(index, 0), last)
        guard clamped != selectedPage else { return }
        selectedPage = clamped
    }

    func savePending(_ r: CompressionResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = Compressor.suggestedOutputName(for: inputURL, mode: mode)
        if let dir = inputURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            // Das Ergebnis wird verschoben – vorher die offene Ansicht lösen.
            compressedDocument = nil
            singleOutcome = .saved(try Compressor.finalize(result: r, destination: destination))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            loadCompressedDocument()   // Sichern gescheitert: Vergleich bleibt
        }
    }

    /// Liegt ein Ergebnis vor, das beim Ersetzen oder Schließen verloren
    /// ginge? „Bereits optimiert" zählt nicht – da gibt es nichts zu sichern.
    var hasUnsavedResult: Bool {
        if let pending = pendingResult { return !pending.alreadyOptimized }
        return bulkSuccesses.contains { $0.savedTo == nil }
    }

    /// pending → none: Temp löschen. Ein Sichern-Fehler gehört zum
    /// verworfenen Ergebnis und geht mit.
    func discardPending() {
        compressedDocument = nil
        guard case .pending(let r) = singleOutcome else { return }
        try? FileManager.default.removeItem(at: r.outputURL)
        singleOutcome = .none
        errorMessage = nil
    }

    /// pending/saved → none (ein ungesichertes Temp wird gelöscht).
    private func clearSingleOutcome() {
        discardPending()
        singleOutcome = .none
    }

    // MARK: - Privat

    private var workTask: Task<Void, Never>?
    private var estimateDebounceTask: Task<Void, Never>?
    private var estimateGeneration = 0
    private var estimateTask: Task<Void, Never>?
    var estimateProvider: @Sendable (URL, CompressionOptions) -> CompressionEstimate? = {
        // Vorschau: Schnellschätzung aus dem Inventar (Millisekunden statt
        // eines halben Kompressionslaufs). Die planbasierte Schätzung bleibt
        // für Tests und Diagnose erhalten.
        CompressionEstimator.quickEstimate(url: $0, options: $1,
                                           isCancelled: { Task.isCancelled })
    }

    // MARK: - Phase V2-10 (§17) – Zielgrößen-Texte (ViewModel-Logik, getestet)

    /// Anzeige der Schätzer-Zeile bei gesetztem Ziel – ersetzt das normale
    /// Band (§17): nicht erreichbare Ziele nennen die sicher erreichbare
    /// Größe (Actual-Size-Feedback-Muster, §12.6/§16.3).
    nonisolated static func targetEstimateText(
        _ assessment: CompressionEstimator.TargetSizeAssessment) -> String {
        let target = CompressionResult.format(assessment.targetBytes)
        switch assessment.reachability {
        case .likelyReachable:
            return String(localized: "Ziel \(target) – voraussichtlich erreichbar")
        case .uncertain:
            return String(localized: "Ziel \(target) – unsicher, der Lauf entscheidet")
        case .notSafelyReachable:
            // Keine zweite Zahl neben der Schätzung (Rundgang 2026-10-15:
            // „sicher erreichbar 867 KB" stand neben „voraussichtlich 694 KB").
            return String(localized: "Ziel \(target) – wird vermutlich nicht ganz erreicht")
        }
    }

    /// Engine-Fehler in Nutzersprache. Die Validierung meldet ihre Befunde
    /// als Testvertrag mit Fingerprints („Seite 7 Textinhalt: adfb… → dd7b…");
    /// dem Nutzer gehört stattdessen, WAS passiert wäre und dass seine Datei
    /// unverändert bleibt (Rundgang 2026-10-15).
    nonisolated static func userFacingMessage(for error: Error) -> String {
        guard case PDFValidator.ValidationError.invalid(let failures) = error else {
            return error.localizedDescription
        }
        var pages: [Int] = []
        for failure in failures {
            var rest = Substring(failure)
            while let range = rest.range(of: "Seite ") {
                rest = rest[range.upperBound...]
                let digits = rest.prefix(while: \.isNumber)
                if let n = Int(digits), !pages.contains(n) { pages.append(n) }
            }
        }
        pages.sort()
        let textual = failures.contains { $0.contains("Text") }
        let location: String
        switch pages.count {
        case 0: location = ""
        case 1: location = String(localized: " auf Seite \(pages[0])")
        default:
            let list = pages.prefix(4).map(String.init).joined(separator: ", ")
            location = pages.count > 4
                ? String(localized: " auf den Seiten \(list) …")
                : String(localized: " auf den Seiten \(list)")
        }
        return textual
            ? String(localized: "Nicht komprimiert: Das Ergebnis hätte\(location) Text verloren. Die Datei bleibt unverändert.")
            : String(localized: "Nicht komprimiert: Das Ergebnis wich\(location) vom Original ab. Die Datei bleibt unverändert.")
    }

    /// Ergebnis-Anzeige nach dem Lauf (§17): erreichte Größe gegen das
    /// Ziel. Ohne ✓/✗ im Text – das Symbol trägt das Label in der
    /// Oberfläche (Befund M4).
    nonisolated static func targetResultText(requested: Int64,
                                             achieved: Int64,
                                             met: Bool) -> String {
        let target = CompressionResult.format(requested)
        let out = CompressionResult.format(achieved)
        // Nicht erreicht ist kein Scheitern (Rundgang 2026-10-15): Der
        // Modus hat geholt, was seine Qualitätsgrenzen erlauben.
        return met
            ? String(localized: "Ziel \(target) erreicht: \(out)")
            : String(localized: "Kleinstmöglich in diesem Modus: \(out) – Ziel war \(target)")
    }

    /// Dezenter Hinweis auf QA-Nachläufe (V2-5-Felder) – nil, wenn es keine
    /// gab; die Oberfläche zeigt ihn nur dann.
    nonisolated static func qualityHintText(qaReplanCount: Int,
                                            fallbackCount: Int) -> String? {
        guard qaReplanCount > 0 || fallbackCount > 0 else { return nil }
        if fallbackCount > 0 {
            return String(localized: "Qualität geprüft – zur Sicherheit wurde ein verlustfreier Durchgang gewählt.")
        }
        return qaReplanCount == 1
            ? String(localized: "Qualität geprüft – ein Durchgang wurde wiederholt.")
            : String(localized: "Qualität geprüft – \(qaReplanCount) Durchgänge wurden wiederholt.")
    }
}
