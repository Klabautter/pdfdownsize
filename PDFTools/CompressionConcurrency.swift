import Foundation

/// Phase 8 – Parallelität pro Dokument.
///
/// Vorher serialisierte EIN globaler Lock in der PDFCoreBridge ALLE
/// Dokumente im Prozess gegeneinander: Zwei unabhängige Kompressionen
/// teilten sich prozessweit eine Sperre, und alles wartete auf alles.
/// Jetzt serialisiert jede QPDF-Instanz nur noch sich selbst (Sperre je
/// `PDFCoreDocument`), und die Parallelität zwischen Dokumenten wird hier
/// begrenzt – der eine Hebel, an dem die Anzahl gleichzeitiger
/// Kompressionen steht.
///
/// Startwert `min(2, activeProcessorCount)`: Zwei Dokumente halten die
/// Bildkodierer beschäftigt, ohne den Rechner (oder parallele
/// Korpus-Chargen) zu überlasten. Konfigurierbar über
/// `maxConcurrentDocuments` oder die Umgebungsvariable
/// `PDFTOOLS_COMPRESSION_CONCURRENCY` (überschreibt den Startwert; ein
/// Wert < 1 wird ignoriert).
///
/// Innerhalb EINES Dokuments bleibt alles serialisiert – der Executor
/// arbeitet Bilder eins nach dem anderen, und die Instanz-Sperre der
/// Bridge sichert zusätzlich ab. Nur zwischen Dokumenten läuft es parallel.
enum CompressionConcurrency {

    /// Überschreibung aus der Umgebung (Lastversuche, Korpuslauf).
    private static var environmentLimit: Int? {
        guard let raw = ProcessInfo.processInfo
            .environment["PDFTOOLS_COMPRESSION_CONCURRENCY"],
            let value = Int(raw), value >= 1 else { return nil }
        return value
    }

    private static let limitLock = NSLock()
    private static var overrideLimit: Int?

    /// Aktives Limit gleichzeitig komprimierter Dokumente (≥ 1).
    static var maxConcurrentDocuments: Int {
        get {
            limitLock.lock(); defer { limitLock.unlock() }
            return overrideLimit
                ?? environmentLimit
                ?? min(2, ProcessInfo.processInfo.activeProcessorCount)
        }
        set {
            limitLock.lock(); defer { limitLock.unlock() }
            precondition(newValue >= 1, "Limit muss mindestens 1 sein")
            overrideLimit = newValue
        }
    }

    /// Setzt das Limit auf den Startwert zurück (Tests, Lastversuche).
    static func resetLimit() {
        limitLock.lock(); defer { limitLock.unlock() }
        overrideLimit = nil
    }

    /// Führt `body` für jedes Element aus, höchstens `limit` gleichzeitig.
    ///
    /// Sliding Window: Ein abgeschlossenes Dokument gibt seinen Platz frei,
    /// das nächste startet. Kündigt `body` an oder wirft, bricht die Gruppe
    /// ab und zieht die laufenden Aufgaben mit.
    static func forEachDocument<Item: Sendable>(_ items: [Item],
                                                limit: Int? = nil,
                                                _ body: @escaping @Sendable (Item) async throws -> Void) async throws {
        let maxInFlight = max(1, limit ?? maxConcurrentDocuments)
        guard !items.isEmpty else { return }
        var iterator = items.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<maxInFlight {
                guard let item = iterator.next() else { break }
                group.addTask { try await body(item) }
            }
            while try await group.next() != nil {
                if let item = iterator.next() {
                    group.addTask { try await body(item) }
                }
            }
        }
    }

    /// Komprimiert unabhängige Dokumente mit dem aktiven Limit.
    ///
    /// Ergebnisse kommen in EINGABEREIHENFOLGE zurück; der erste Fehler
    /// bricht den Lauf ab (das Original eines Dokuments bleibt stets
    /// unangetastet). Je Dokument läuft ein eigener autoreleasepool –
    /// das Phase-8-Prinzip „ein Dokument zur Zeit, Transienten sofort
    /// frei" gilt damit auch auf dem parallelen Pfad.
    ///
    /// `onDocumentProgress` meldet den Fortschritt JEDES Dokuments
    /// (Index in der Eingabeliste, URL, Bruchteil 0…1, Stufentext aus dem
    /// Compressor). Es wird aus parallelen Tasks GERUFEN – die
    /// Zusammensetzung zu einem Gesamtwert liegt beim Empfänger.
    static func compressDocuments(inputURLs: [URL],
                                  mode: CompressionMode = .smart,
                                  limit: Int? = nil,
                                  isCancelled: (() -> Bool)? = nil,
                                  onDocumentProgress: ((Int, URL, Double, String) -> Void)? = nil) async throws -> [CompressionResult] {
        var results = [CompressionResult?](repeating: nil, count: inputURLs.count)
        var iterator = inputURLs.enumerated().makeIterator()
        let maxInFlight = max(1, limit ?? maxConcurrentDocuments)
        try await withThrowingTaskGroup(of: (Int, CompressionResult).self) { group in
            for _ in 0..<maxInFlight {
                guard let (index, url) = iterator.next() else { break }
                group.addTask {
                    (index, try compressOne(url, index: index, mode: mode,
                                            isCancelled: isCancelled,
                                            onProgress: onDocumentProgress))
                }
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                if let (nextIndex, url) = iterator.next() {
                    group.addTask {
                        (nextIndex, try compressOne(url, index: nextIndex, mode: mode,
                                                    isCancelled: isCancelled,
                                                    onProgress: onDocumentProgress))
                    }
                }
            }
        }
        return try results.map { result in
            guard let result else { throw CompressionError.loadFailed }
            return result
        }
    }

    /// Sammelnde Variante für die Bulk-UI: Eine fehlerhafte oder einzeln
    /// abgebrochene Datei bricht NICHT den Gesamtlauf ab. Das Ergebnis steht
    /// in Eingabereihenfolge als `Result` je Dokument; geworfen wird nur
    /// `CancellationError` bei globalem Abbruch (cancelWork / Task-Abbruch).
    ///
    /// Nimmt die VOLLEN `CompressionOptions` (Custom-Panel, Zielgröße,
    /// Linearize) – dieselben, die auch der Einzellauf über
    /// `currentOptions` erhält. Es gibt keinen zweiten Optionsweg.
    ///
    /// `isCancelledFor` meldet den Abbruch EINER Datei (pro-Datei-Abbrechen
    /// in der Liste); `isCancelled` bleibt der globale Schalter. Beide werden
    /// vom Compressor regelmäßig geprüft, der Abbruch greift also auch bei
    /// langen Einzel-Encodes – die übrigen Dokumente laufen weiter.
    static func compressDocumentsCollecting(inputURLs: [URL],
                                            options: CompressionOptions,
                                            limit: Int? = nil,
                                            isCancelled: (() -> Bool)? = nil,
                                            isCancelledFor: ((Int, URL) -> Bool)? = nil,
                                            onDocumentProgress: ((Int, URL, Double, String) -> Void)? = nil) async throws -> [Result<CompressionResult, Error>] {
        var results = [Result<CompressionResult, Error>?](repeating: nil, count: inputURLs.count)
        var iterator = inputURLs.enumerated().makeIterator()
        let maxInFlight = max(1, limit ?? maxConcurrentDocuments)
        try await withThrowingTaskGroup(of: (Int, Result<CompressionResult, Error>).self) { group in
            for _ in 0..<maxInFlight {
                guard let (index, url) = iterator.next() else { break }
                group.addTask {
                    (index, collectOne(url, index: index, options: options,
                                       isCancelled: isCancelled, isCancelledFor: isCancelledFor,
                                       onProgress: onDocumentProgress))
                }
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                if let (nextIndex, url) = iterator.next() {
                    group.addTask {
                        (nextIndex, collectOne(url, index: nextIndex, options: options,
                                               isCancelled: isCancelled, isCancelledFor: isCancelledFor,
                                               onProgress: onDocumentProgress))
                    }
                }
            }
        }
        // Globaler Abbruch bleibt ein Abbruch (kein Teilergebnis-Erfolg).
        try Task.checkCancellation()
        if isCancelled?() == true { throw CancellationError() }
        return results.map { $0 ?? .failure(CompressionError.loadFailed) }
    }

    /// Ein Dokument für die sammelnde Variante: wirft nie, sondern fängt
    /// je Datei (Fehler, Einzelabbruch) als `Result` – nur so laufen die
    /// übrigen Dokumente weiter.
    private static func collectOne(_ url: URL, index: Int, options: CompressionOptions,
                                   isCancelled: (() -> Bool)?,
                                   isCancelledFor: ((Int, URL) -> Bool)?,
                                   onProgress: ((Int, URL, Double, String) -> Void)?) -> Result<CompressionResult, Error> {
        do {
            let combined: () -> Bool = {
                (isCancelled?() ?? false) || (isCancelledFor?(index, url) ?? false) || Task.isCancelled
            }
            return try .success(autoreleasepool {
                try Compressor().compress(inputURL: url, options: options,
                                          isCancelled: combined,
                                          progress: onProgress.map { report in
                                              { fraction, label in report(index, url, fraction, label) }
                                          })
            })
        } catch {
            return .failure(error)
        }
    }

    private static func compressOne(_ url: URL, index: Int, mode: CompressionMode,
                                    isCancelled: (() -> Bool)?,
                                    onProgress: ((Int, URL, Double, String) -> Void)?) throws -> CompressionResult {
        try autoreleasepool {
            try Compressor().compress(inputURL: url, mode: mode,
                                      isCancelled: isCancelled,
                                      progress: onProgress.map { report in
                                          { fraction, label in report(index, url, fraction, label) }
                                      })
        }
    }
}
