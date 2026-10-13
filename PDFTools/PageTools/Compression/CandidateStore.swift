import Foundation

// MARK: - Masterplan §9.12 – Candidate Store
//
// 100 Bilder × mehrere Kandidaten übersteigen jeden RAM-Cache. Der Store
// verwaltet Payloads nach Größe:
//
//     klein    → RAM (bis zur Payload-Grenze und innerhalb des Budgets)
//     groß     → Temp-Datei im Workspace-Temp
//     sehr groß→ regenerierbar: nur Metadaten (Rezept), der Executor kodiert
//                den Kandidaten deterministisch aus den Planparametern neu
//
// Dateinamen sind deterministisch (Ressource + CandidateID), das Instanz-
// verzeichnis isoliert parallele Läufe. Aufräumen ist RAII: deinit und
// cancel() entfernen alles. Der bestehende CompressionPlanArtifacts-Cache
// bleibt NICHT angetastet – er nimmt weiterhin ausschließlich die Payload
// des GEWÄHLTEN Kandidaten auf (Executor-Fallback bei verworfenem Cache).

/// Ablageort einer Kandidaten-Payload.
enum CandidatePayload: Equatable, Sendable {
    case memory(Data)
    case file(URL, bytes: Int)
    case regenerable(CandidateRecipe)

    var byteCount: Int? {
        switch self {
        case .memory(let data): return data.count
        case .file(_, let bytes): return bytes
        case .regenerable: return nil
        }
    }
}

/// Rezept eines nur metadatierten Kandidaten. Der Executor erzeugt die
/// Bytes deterministisch aus den Planparametern neu (Finding 11); das
/// Rezept dokumentiert für Trace/Benchmark, WAS neu zu erzeugen wäre.
struct CandidateRecipe: Equatable, Codable, Sendable {
    let resourceID: String
    let candidateID: String
    let kindSummary: String
    let pixelCount: Int
    let estimatedBytes: Int
}

 final class CandidateStore: @unchecked Sendable {

    struct Config: Sendable {
        /// Gesamtes RAM-Budget für Kandidaten-Payloads (§9.12: 96–128 MB).
        var ramBudgetBytes: Int = 96 * 1024 * 1024
        /// Payloads oberhalb dieser Grenze gehen direkt auf die Platte.
        var ramPayloadLimitBytes: Int = 8 * 1024 * 1024
        /// Payloads oberhalb dieser Grenze bleiben metadata-only.
        var filePayloadLimitBytes: Int = 64 * 1024 * 1024
    }

    private let config: Config
    /// Instanz-isoliertes Temp-Verzeichnis (parallele Läufe stören sich nicht).
    private let directory: URL
    private let lock = NSLock()
    private var payloads: [String: CandidatePayload] = [:]
    private var cancelled = false

    /// V2-Maps-Perf – Session-Scope-Cache dekodierter Quellraster: Dekodiere
    /// EINMAL je (Ressource, Ebene), verwende das Pixelraster für alle
    /// Quality-Rungs der Bracketed Search wieder. Lebenszeit = Lebenszeit des
    /// Stores (eine compress()-Operation inkl. Re-Plans); Budget mit
    /// LRU-Verdrängung, RAII über cancel()/deinit (siehe PixelDecodeCache).
    let pixelCache: PixelDecodeCache

    private(set) var ramBytes = 0
    private(set) var fileBytes = 0
    /// Wie viele Payloads wegen Budget/Grenzen auf die Platte gewandert sind.
    private(set) var spilledToDisk = 0
    /// Wie viele Payloads metadata-only verwaltet werden.
    private(set) var regenerableCount = 0

    init(config: Config = Config(), directory: URL? = nil,
         pixelCache: PixelDecodeCache = PixelDecodeCache()) {
        self.config = config
        self.pixelCache = pixelCache
        let base = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTools-CandidateStore-\(UUID().uuidString)",
                                    isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base,
                                                  withIntermediateDirectories: true)
    }

    deinit { cleanupLockedState() }

    // MARK: Ablegen

    /// Legt eine Payload ab und entscheidet die Ablageart nach Größe und
    /// Budget. Deterministischer Schlüssel: Ressource + CandidateID.
    @discardableResult
    func store(_ data: Data,
               resource: PDFObjectID,
               candidate: CandidateID,
               kind: CandidateKind) -> CandidatePayload {
        lock.lock(); defer { lock.unlock() }
        let key = "\(resource.objectNumber)-\(resource.generation)-\(candidate.rawValue)"
        if let existing = payloads[key] {
            releaseBytes(existing)
            removeFile(of: existing)
        }
        guard !cancelled, !data.isEmpty else {
            return regenerablePayload(key: key, resource: resource,
                                      candidate: candidate, kind: kind,
                                      estimatedBytes: data.count)
        }

        // 1. Klein → RAM (Payload-Grenze UND Gesamtbudget).
        if data.count <= config.ramPayloadLimitBytes,
           ramBytes + data.count <= config.ramBudgetBytes {
            ramBytes += data.count
            let payload = CandidatePayload.memory(data)
            payloads[key] = payload
            return payload
        }

        // 2. Groß → Temp-Datei mit deterministischem Namen.
        if data.count <= config.filePayloadLimitBytes {
            let url = directory.appendingPathComponent(Self.fileName(for: key) + ".bin")
            do {
                try data.write(to: url, options: .atomic)
                fileBytes += data.count
                spilledToDisk += 1
                let payload = CandidatePayload.file(url, bytes: data.count)
                payloads[key] = payload
                return payload
            } catch {
                // Schreibfehler: lieber metadata-only alsabortieren.
                return regenerablePayload(key: key, resource: resource,
                                          candidate: candidate, kind: kind,
                                          estimatedBytes: data.count)
            }
        }

        // 3. Sehr groß → metadata-only.
        return regenerablePayload(key: key, resource: resource,
                                  candidate: candidate, kind: kind,
                                  estimatedBytes: data.count)
    }

    private func regenerablePayload(key: String, resource: PDFObjectID,
                                    candidate: CandidateID, kind: CandidateKind,
                                    estimatedBytes: Int) -> CandidatePayload {
        regenerableCount += 1
        let recipe = CandidateRecipe(
            resourceID: CandidateSet.resourceID(for: resource),
            candidateID: candidate.rawValue,
            kindSummary: Self.kindSummary(kind),
            pixelCount: 0,
            estimatedBytes: max(0, estimatedBytes))
        let payload = CandidatePayload.regenerable(recipe)
        payloads[key] = payload
        return payload
    }

    // MARK: Lesen

    func payload(for candidate: CandidateID, resource: PDFObjectID) -> CandidatePayload? {
        lock.lock(); defer { lock.unlock() }
        let key = "\(resource.objectNumber)-\(resource.generation)-\(candidate.rawValue)"
        return payloads[key]
    }

    /// Lädt die Bytes einer Payload; `nil` für regenerierbare Kandidaten.
    func data(for payload: CandidatePayload) -> Data? {
        switch payload {
        case .memory(let data): return data
        case .file(let url, _):
            lock.lock(); defer { lock.unlock() }
            return try? Data(contentsOf: url)
        case .regenerable: return nil
        }
    }

    // MARK: Aufräumen

    /// Entfernt ALLE Payloads (Dateien sofort, RAM-Verweise geleert). Nach
    /// `cancel` liefert `store` nur noch regenerierbare Rezepte.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        for payload in payloads.values { removeFile(of: payload) }
        payloads.removeAll()
        ramBytes = 0
        fileBytes = 0
        pixelCache.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func cleanupLockedState() {
        lock.lock(); defer { lock.unlock() }
        for payload in payloads.values { removeFile(of: payload) }
        payloads.removeAll()
        pixelCache.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func releaseBytes(_ payload: CandidatePayload) {
        switch payload {
        case .memory(let data): ramBytes -= data.count
        case .file(_, let bytes): fileBytes -= bytes
        case .regenerable: break
        }
    }

    private func removeFile(of payload: CandidatePayload) {
        if case .file(let url, _) = payload {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Schlüssel

    /// Dateinamen-safe, deterministisch aus dem Schlüssel abgeleitet.
    private static func fileName(for key: String) -> String {
        String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    static func kindSummary(_ kind: CandidateKind) -> String {
        switch kind {
        case .keep: return "keep"
        case .jpeg: return "jpeg"
        case .flate: return "flate"
        case .indexedFlate: return "indexedFlate"
        case .ccittG4: return "ccittG4"
        case .jbig2Lossless: return "jbig2Lossless"
        case .cmykJPEG: return "cmykJPEG"
        case .jpegRepack: return "jpegRepack"
        case .fontKeep: return "fontKeep"
        case .fontSubset: return "fontSubset"
        case .resourceDedup: return "resourceDedup"
        case .mrc: return "mrc"
        }
    }
}
