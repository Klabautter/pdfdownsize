import Foundation

/// Probelauf des verlustfreien Struktur-Passes für die Sofort-Schätzung.
///
/// Bis 2026-10-13 schätzte die Vorschau den Nicht-Bild-Anteil nur über drei
/// Pauschalwerte (`StructureProfile.structureRetention`) und legte das breite
/// Bild-Band (×0,6) auch über diesen Anteil. Ein Kontoauszug ohne Bilder
/// bekam so „bis zu 44 %" angezeigt und schrumpfte tatsächlich um 2 %.
///
/// Für textlastige, nicht zu große Dateien ist der echte Struktur-Pass in
/// Millisekunden gelaufen – dann wird gemessen statt geraten. Gemessen wird
/// exakt der Prozess, den auch der Kompressionslauf startet
/// (`Compressor.makeStructureProcess`). Kern-235, Bildanteil ≤ 10 %
/// (58 Dokumente): mittlerer Fehler 11,5 → 8,5 Punkte, Median 5,2 → 2,2.
enum StructureTrial {
    /// Größere Dateien bleiben beim Pauschalmodell: Der Pass braucht dort
    /// Sekunden (31 MB: ~10 s) und die Vorschau soll sofort stehen.
    static let maximumFileBytes: Int64 = 16 * 1024 * 1024
    /// Gemessen wird nur, wenn der Nicht-Bild-Anteil das Ergebnis trägt.
    static let minimumNonImageShare = 0.5
    static let timeoutSeconds = 2.0
    /// Band um einen GEMESSENEN Strukturanteil. Nach unten bleibt Luft für
    /// das, was der Lauf zusätzlich holt (Dedup, Font-Subsetting).
    static let measuredLowerBand = 0.93
    static let measuredUpperBand = 1.02

    private struct Key: Hashable {
        let path: String
        let size: Int64
        let modified: Date?
        let objectStreamsDisabled: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: Double?] = [:]

    /// Anteil der Dateigröße, der nach dem Struktur-Pass bleibt (≤ 1), oder
    /// `nil`, wenn nicht gemessen wurde (zu groß, bildlastig, kein qpdf,
    /// Zeitlimit). Ergebnis je Datei und Kompatibilitätsmodus gemerkt – die
    /// Vorschau fragt bei jeder Reglerbewegung erneut.
    static func retention(url: URL, original: Int64, imageBytes: Int64,
                          compatibility: CompatibilityPolicy) -> Double? {
        guard original > 0, original <= maximumFileBytes,
              Double(max(original - imageBytes, 0)) / Double(original) >= minimumNonImageShare
        else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let key = Key(path: url.path, size: original, modified: modified,
                      objectStreamsDisabled: compatibility == .maximum)
        lock.lock()
        if let known = cache[key] { lock.unlock(); return known }
        lock.unlock()

        let measured = measure(url: url, original: original, compatibility: compatibility)
        lock.lock()
        if cache.count > 256 { cache.removeAll() }
        cache[key] = measured
        lock.unlock()
        return measured
    }

    private static func measure(url: URL, original: Int64,
                                compatibility: CompatibilityPolicy) -> Double? {
        guard let qpdfPath = Compressor.findQPDF() else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("structure-trial-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Compressor.makeStructureProcess(
            qpdfPath: qpdfPath, input: url, output: output, linearize: false,
            compatibility: compatibility, flate: .standard)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            return nil
        }
        // Exit 3 = Warnungen, Ergebnis gültig – wie im Produktionspfad.
        guard process.terminationStatus == 0 || process.terminationStatus == 3 else { return nil }
        let size = Compressor.fileSize(of: output)
        guard size > 0 else { return nil }
        // Never-Grow: Wird die Datei nicht kleiner, bleibt das Original.
        return min(Double(size) / Double(original), 1.0)
    }
}
