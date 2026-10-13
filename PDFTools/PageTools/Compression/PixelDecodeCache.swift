import Foundation
import CoreGraphics

// MARK: - V2-Maps-Perf – Session-Scope-Cache dekodierter Quellraster
//
// Befund der V2-11-Zertifizierung (Maps/CAD): Die Kandidatenphase dekodierte
// dieselbe große Rasterquelle mehrfach – je Auflösungsstufe der Leiter eine
// eigene Dekodierung (§9.4), dazu das Zielraster des Einstiegs (Schritt 4).
// Bei einer 45-MB-USGS-Karte dominiert genau das die candidate_ms.
//
// Dieser Cache dekoliert EINMAL je (Ressource, Ebene) und stellt dasselbe
// `CGImage` allen Quality-Rungs der Bracketed Search bereit – die encodiert
// nur um, sie braucht die Pixel nicht neu. Die Referenz jeder Stufe entsteht
// weiterhin durch Resampling aus DEM dekodierten Original (nicht kaskadierend
// – Qualitätsdeterminismus).
//
// POLITIK
//
//   Schlüssel   (Ressource, Ebene). Ebene 0 = volle Dekodierung (DCT, Flate,
//               CCITT, JPX ohne Reduktion); JPX mit cp_reduce dekodierte je
//               Stufe direkt auf 1/2^N – dessen Ebene IST die Reduktionsstufe
//               (`ImagePixelSource.decodeLevel`). Gleiche Ebene ⇒ dasselbe
//               Raster, wie zwei getrennte Dekodierungen es geliefert hätten.
//
//   Lebenszeit  Ein Eintrag lebt, bis ihn der Generator explizit freigibt:
//               Blätter (Ebenen, die keine künftige Leiter-Stufe mehr braucht)
//               sobald die Stufe fertig ist, alles Übrige mit Abschluss der
//               Ressource. Global: cancel()/deinit (RAII wie CandidateStore).
//
//   Budget      Bytebudget über die Rastergrößen; bei Überschreitung wird
//               least-recently-used verdrängt. Verdrängung ist ERGEBNISNEUTRAL:
//               Eine erneute Dekodierung liefert dasselbe Raster (determini-
//               stische Quelle), ändert also kein CandidateSet – nur die
//               Laufzeit. Große Karten können so mehrere aktive Jobs übertreffen;
//               der Cache degradiert dann graceful auf Wieder-Dekodierung.
//
//   Threads     Die Kandidatengenerierung läuft parallel unter dem Pixel-
//               Budget-Scheduler (§15); alle Zugriffe laufen unter einer Sperre,
//               die Dekodierung selbst geschieht außerhalb (im Ruf des Job).
//
// Das Budget ist konfigurierbar (PDFTOOLS_DECODE_CACHE_BUDGET in Bytes,
// Muster wie PDFTOOLS_PIXEL_BUDGET des Schedulers). Default 192 MB – groß
// genug für zwei volle Kartenraster, klein genug, um den Scheduler nicht
// zu verdoppeln.
final class PixelDecodeCache: @unchecked Sendable {

    struct Config: Sendable {
        var budgetBytes: Int64 = 192 * 1024 * 1024

        /// Env-Überschreibung (Bytes) – Muster der Scheduler-Budgets.
        static func resolved(env: [String: String] = ProcessInfo.processInfo.environment)
            -> Config {
            var config = Config()
            if let raw = env["PDFTOOLS_DECODE_CACHE_BUDGET"]?
                .trimmingCharacters(in: .whitespaces),
               let bytes = Int64(raw), bytes > 0 {
                config.budgetBytes = bytes
            }
            return config
        }
    }

    /// Ein gecachtes Raster. `CGImage` ist unveränderlich – geteilte Nutzung
    /// im Resampler/Klassifizierer ist ausschließlich lesend.
    private struct Entry {
        let image: CGImage
        let bytes: Int64
        /// LRU-Stempel (monotone Zählung, keine Wall-Clock-Abhängigkeit).
        var lastUse: UInt64
    }

    private let config: Config
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var cachedBytes: Int64 = 0
    private var clock: UInt64 = 0

    // Telemetrie (MapsDecodeCacheTests, Rapport).
    private(set) var hits = 0
    private(set) var misses = 0
    private(set) var evictions = 0
    private(set) var peakCachedBytes: Int64 = 0

    init(config: Config = .resolved()) {
        self.config = config
    }

    deinit { removeAll() }

    // MARK: Zugriff

    /// Liefert das Raster der Ebene – Hit aus dem Cache, Miss durch `decode`.
    /// Ein fehlgeschlagene Dekodierung (`nil`) wird NICHT gecacht; der nächste
    /// Ruf versucht es erneut (deterministisch gleiches Ergebnis).
    func image(for resource: PDFObjectID, level: Int,
               decode: () -> CGImage?) -> CGImage? {
        let key = Self.key(resource: resource, level: level)
        lock.lock()
        if let entry = entries[key] {
            clock += 1
            entries[key] = Entry(image: entry.image, bytes: entry.bytes,
                                 lastUse: clock)
            hits += 1
            let image = entry.image
            lock.unlock()
            return image
        }
        lock.unlock()

        // Dekodieren außerhalb der Sperre (teure Pixelarbeit).
        guard let image = decode() else { return nil }

        lock.lock(); defer { lock.unlock() }
        // Doppelprüfung: ein paralleler Job kann dieselbe Ebene inzwischen
        // eingeliefert haben – dann gewinnen wir dessen Eintrag (dasselbe
        // Raster, ein Dekodierlauf weniger).
        if let existing = entries[key] {
            clock += 1
            entries[key] = Entry(image: existing.image, bytes: existing.bytes,
                                 lastUse: clock)
            hits += 1
            return existing.image
        }
        misses += 1
        clock += 1
        let bytes = Self.rasterBytes(of: image)
        entries[key] = Entry(image: image, bytes: bytes, lastUse: clock)
        cachedBytes += bytes
        peakCachedBytes = max(peakCachedBytes, cachedBytes)
        evictLockedIfNeeded()
        return image
    }

    // MARK: Freigabe

    /// Gibt ALLE Ebenen einer Ressource frei (Abschluss der Kandidaten-
    /// erzeugung). Bereits entnommene `CGImage`-Referenzen bleiben gültig
    /// (ARC bei ihren Haltern) – der Cache hält nur den Wieder-Verwendungs-
    /// vorteil zurück.
    func release(resource: PDFObjectID) {
        lock.lock(); defer { lock.unlock() }
        let prefix = Self.keyPrefix(resource: resource)
        for key in entries.keys where key.hasPrefix(prefix) {
            cachedBytes -= entries[key]?.bytes ?? 0
            entries[key] = nil
        }
    }

    /// Blatt-Freigabe: verwirft alle Ebenen der Ressource AUSSER `keeping`.
    /// Der Generator ruft sie je fertiger Leiter-Stufe mit den Ebenen, die
    /// künftige Stufen noch brauchen.
    func releaseLevels(of resource: PDFObjectID, keeping: Set<Int>) {
        lock.lock(); defer { lock.unlock() }
        let prefix = Self.keyPrefix(resource: resource)
        for (key, entry) in entries where key.hasPrefix(prefix) {
            guard let level = Int(key.dropFirst(prefix.count)),
                  !keeping.contains(level) else {
                continue
            }
            cachedBytes -= entry.bytes
            entries[key] = nil
        }
    }

    /// Räumt ALLES (cancel()/deinit – RAII wie der CandidateStore).
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        cachedBytes = 0
    }

    // MARK: Telemetrie

    var currentCachedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return cachedBytes
    }

    // MARK: Innenleben

    /// Verdrängt least-recently-used, bis das Budget wieder hält. Der zuletzt
    /// genutzte Eintrag (der gerade gelieferte) bleibt stehen – ein aktiver
    /// Job wird nicht unter sich weg verdrängt.
    private func evictLockedIfNeeded() {
        guard cachedBytes > config.budgetBytes else { return }
        // Älteste zuerst (aufsteigend nach LRU-Stempel).
        let ordered = entries.sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, entry) in ordered {
            guard cachedBytes > config.budgetBytes else { break }
            entries[key] = nil
            cachedBytes -= entry.bytes
            evictions += 1
        }
    }

    private static func key(resource: PDFObjectID, level: Int) -> String {
        "\(keyPrefix(resource: resource))\(level)"
    }

    private static func keyPrefix(resource: PDFObjectID) -> String {
        "\(resource.objectNumber)-\(resource.generation)/"
    }

    /// Konservative Rastergröße (4 Byte je Bildpunkt deckt RGBA-Arbeitsformat).
    static func rasterBytes(of image: CGImage) -> Int64 {
        if image.bytesPerRow > 0 {
            return Int64(image.bytesPerRow) * Int64(image.height)
        }
        return Int64(image.width) * Int64(image.height) * 4
    }
}
