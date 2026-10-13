import Foundation

/// Masterplan §7.3 – Stufenzeiten der Compression-Pipeline.
///
/// V2 braucht nicht nur die Gesamtzeit, sondern die Antwort auf „welcher
/// Pass kostet was?“. Die Zeiten werden an den bestehenden Stufengrenzen
/// gemessen – additive Telemetrie, ohne Verhalten des Produktionspfads zu
/// ändern. Feldnamen folgen den JSON-Schlüsseln des Masterplans.
///
/// Zuschreibung: `feature_analysis_ms` misst seit V2-11 die V2-Feature-
/// Extraktion im Candidate-Pfad (§8.1), `candidate_generation_ms` die
/// übrige Kandidatenerzeugung (Dekodieren, Kodierläufe, Messung).
struct StageTimings: Equatable, Sendable, Codable {
    /// PDF öffnen (PDFCoreDocument init).
    var openDocumentMs: Double = 0
    /// Bildinventar inkl. cm/Do-Scan der Platzierungen.
    var inventoryMs: Double = 0
    /// Analyse: Pixel dekodieren, Bilevel-Prüfung, Klassifikation.
    var featureAnalysisMs: Double = 0
    /// Planung: Kandidaten kodieren, Leiter-/Race-Entscheidungen.
    var candidateGenerationMs: Double = 0
    /// Bildtransformationen (Ersetzungen über die Bridge).
    var executionMs: Double = 0
    /// Verlustfreier JPEG-Repack behaltener DCT-Streams (1b/6b).
    var jpegRepackMs: Double = 0
    /// Zopfli-Repack großer Flate-Streams (nur Max-Preset).
    var zopfliRepackMs: Double = 0
    /// Bild-Dedup + Content-Hash-Dedup (3b).
    var dedupMs: Double = 0
    /// Font-Dedup/GC (5a) + Font-Subsetting (5b, auch selektiv §14.4).
    var fontMs: Double = 0
    /// V2-8 (§14.6) – Resource GC der Resource-Maps.
    var resourceGCMs: Double = 0
    /// Finaler Schreibvorgang des Dokuments.
    var writeMs: Double = 0
    /// Struktur-Pass (qpdf) im Compressor.
    var structureMs: Double = 0
    /// Semantische Validierung (PDFValidator) im Compressor.
    var semanticValidationMs: Double = 0

    enum Field: String, CaseIterable, Sendable {
        case openDocumentMs, inventoryMs, featureAnalysisMs
        case candidateGenerationMs, executionMs, jpegRepackMs
        case zopfliRepackMs, dedupMs, fontMs, resourceGCMs, writeMs
        case structureMs, semanticValidationMs
    }

    func value(_ field: Field) -> Double {
        switch field {
        case .openDocumentMs: return openDocumentMs
        case .inventoryMs: return inventoryMs
        case .featureAnalysisMs: return featureAnalysisMs
        case .candidateGenerationMs: return candidateGenerationMs
        case .executionMs: return executionMs
        case .jpegRepackMs: return jpegRepackMs
        case .zopfliRepackMs: return zopfliRepackMs
        case .dedupMs: return dedupMs
        case .fontMs: return fontMs
        case .resourceGCMs: return resourceGCMs
        case .writeMs: return writeMs
        case .structureMs: return structureMs
        case .semanticValidationMs: return semanticValidationMs
        }
    }

    /// Snake_case-JSON-Schlüssel wie im Masterplan §7.3.
    static func jsonKey(_ field: Field) -> String {
        switch field {
        case .openDocumentMs: return "open_document_ms"
        case .inventoryMs: return "inventory_ms"
        case .featureAnalysisMs: return "feature_analysis_ms"
        case .candidateGenerationMs: return "candidate_generation_ms"
        case .executionMs: return "execution_ms"
        case .jpegRepackMs: return "jpeg_repack_ms"
        case .zopfliRepackMs: return "zopfli_ms"
        case .dedupMs: return "dedup_ms"
        case .fontMs: return "font_ms"
        case .resourceGCMs: return "resource_gc_ms"
        case .writeMs: return "write_ms"
        case .structureMs: return "structure_ms"
        case .semanticValidationMs: return "semantic_validation_ms"
        }
    }
}

/// Sammelt Stufenzeiten. Referenztyp, weil Planer und Executor dieselbe
/// Instanz füllen; der Zugang je Dokument ist serialisiert, die Sperre
/// schützt zusätzlich gegen parallele Mehrdokument-Läufe.
final class StageTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var values = StageTimings()

    /// Misst `body` und addiert die Dauer auf `field`.
    func measure<T>(_ field: StageTimings.Field, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        let result = try body()
        add(field, milliseconds: stageMs(since: start))
        return result
    }

    /// Misst `body`; ohne Timer läuft `body` UNVERÄNDERT. So bleiben die
    /// Messpunkte im Produktionspfad harmlos: nil-Timer = reines Durchreichen.
    static func run<T>(_ timer: StageTimer?,
                       _ field: StageTimings.Field,
                       _ body: () throws -> T) rethrows -> T {
        guard let timer else { return try body() }
        return try timer.measure(field, body)
    }

    func add(_ field: StageTimings.Field, milliseconds: Double) {
        lock.lock(); defer { lock.unlock() }
        switch field {
        case .openDocumentMs: values.openDocumentMs += milliseconds
        case .inventoryMs: values.inventoryMs += milliseconds
        case .featureAnalysisMs: values.featureAnalysisMs += milliseconds
        case .candidateGenerationMs: values.candidateGenerationMs += milliseconds
        case .executionMs: values.executionMs += milliseconds
        case .jpegRepackMs: values.jpegRepackMs += milliseconds
        case .zopfliRepackMs: values.zopfliRepackMs += milliseconds
        case .dedupMs: values.dedupMs += milliseconds
        case .fontMs: values.fontMs += milliseconds
        case .resourceGCMs: values.resourceGCMs += milliseconds
        case .writeMs: values.writeMs += milliseconds
        case .structureMs: values.structureMs += milliseconds
        case .semanticValidationMs: values.semanticValidationMs += milliseconds
        }
    }

    /// Summe aller bisher gemessenen Stufen.
    var timings: StageTimings {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// Millisekunden seit `start` – eine Stelle für die Dauer-Arithmetik.
func stageMs(since start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) * 1000
        + Double(elapsed.components.attoseconds) / 1e15
}
