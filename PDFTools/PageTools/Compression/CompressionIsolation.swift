import Foundation
import PDFKit

/// Masterplan §7.7 – Failure Isolation Mode.
///
/// Benchmark-/Debug-Regal, KEIN Produktverhalten: Ist die Isolation
/// aktiviert (Umgebung `PDFTOOLS_COMPRESSION_ISOLATE=<dir>` oder explizit
/// übergeben), schreibt die Pipeline ihren Zwischenzustand nach jeder
/// Stufe nach `<dir>`:
///
///     00_original.pdf    Eingabe
///     10_images.pdf      nach den Bildtransformationen (Pipeline-Output)
///     20_dedup.pdf       nach Bild-/Content-Hash-Dedup
///     30_fonts.pdf       nach Font-Dedup/GC und Font-Subsetting
///     40_metadata.pdf    nach Metadatenpolitik und Producer-Stempel
///     50_structure.pdf   nach dem Struktur-Pass
///
/// Je Stufe entsteht daneben ein gleichnamiges JSON mit Bytes, qpdf-check-
/// Ergebnis und dem PDFKit-Text-Fingerprint je Seite (Seitennummer 1-basiert
/// → Fingerprint). Damit lässt sich SEMANTIK-Regression (z. B. statab_2012,
/// §11.7) einem Pass zuordnen: die erste Stufe, deren Seiten-Fingerprint von
/// der Eingabe abweicht, trägt die Ursache.
struct CompressionIsolation {

    let directory: URL

    /// Aus der Umgebung – im normalen Produktlauf nil.
    static func fromEnvironment() -> CompressionIsolation? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["PDFTOOLS_COMPRESSION_ISOLATE"],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return CompressionIsolation(directory: URL(fileURLWithPath: raw,
                                                   isDirectory: true))
    }

    /// Legt das Zielverzeichnis an (bestehende Stufendateien werden
    /// entfernt, damit kein Lauf die Artefakte eines anderen liest).
    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in Self.stageFileNames {
            try? fm.removeItem(at: directory.appendingPathComponent(name + ".pdf"))
            try? fm.removeItem(at: directory.appendingPathComponent(name + ".json"))
        }
    }

    static let stageFileNames = [
        "00_original", "10_images", "20_dedup",
        "30_fonts", "40_metadata", "50_structure",
    ]

    /// Kopiert/verschiebt die Datei als Stufenstand und schreibt das
    /// Stufen-JSON (Bytes, qpdf --check, Text-Fingerprints je Seite).
    func record(stage: String, file: URL, qpdfPath: String?) throws {
        let fm = FileManager.default
        let target = directory.appendingPathComponent(stage + ".pdf")
        try? fm.removeItem(at: target)
        try fm.copyItem(at: file, to: target)
        try writeStageRecord(stage: stage, file: target, qpdfPath: qpdfPath)
    }

    /// Sichert den AKTUELLEN Dokumentzustand als Stufenstand (Executor-Grenzen
    /// 20/30/40 haben keine Datei auf der Platte – der Write-Pass kommt später).
    func recordDocument(document: PDFCoreDocument, stage: String,
                        qpdfPath: String?) {
        let target = directory.appendingPathComponent(stage + ".pdf")
        do {
            try? FileManager.default.removeItem(at: target)
            try document.save(to: target)
            try writeStageRecord(stage: stage, file: target, qpdfPath: qpdfPath)
        } catch {
            // Isolation darf den Lauf niemals beenden – fehlgeschlagene
            // Stufenstände bleiben einfach aus.
        }
    }

    private func writeStageRecord(stage: String, file: URL,
                                  qpdfPath: String?) throws {
        let fm = FileManager.default
        let bytes = Int64((try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int64 ?? 0)
        var fingerprints: [String: String] = [:]
        var pageCount = 0
        if let snapshot = try? PDFSemanticSnapshot.capture(file,
                                                           backend: .pdfKit) {
            pageCount = snapshot.pageCount
            for page in snapshot.pages where !page.textFingerprint.isEmpty {
                fingerprints[String(page.index + 1)] = page.textFingerprint
            }
        }
        let entry = StageRecord(
            stage: stage, bytes: bytes, qpdfCheck: Self.qpdfCheck(
                qpdfPath: qpdfPath, url: file),
            pages: pageCount, pageTextFingerprints: fingerprints)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(entry)
        try json.write(to: directory.appendingPathComponent(stage + ".json"),
                       options: [.atomic])
    }

    struct StageRecord: Codable {
        var stage: String
        var bytes: Int64
        var qpdfCheck: String
        var pages: Int
        /// Seitennummer (1-basiert) → Text-Fingerprint (leere Seiten fehlen).
        var pageTextFingerprints: [String: String]

        enum CodingKeys: String, CodingKey {
            case stage, bytes
            case qpdfCheck = "qpdf_check"
            case pages
            case pageTextFingerprints = "page_text_fingerprints"
        }
    }

    /// qpdf --check über den gebündelten Helfer (0 ok, 3 Warnungen, sonst fatal).
    static func qpdfCheck(qpdfPath: String?, url: URL) -> String {
        guard let qpdfPath else { return "not-run" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdfPath)
        process.arguments = ["--check", url.path]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        do { try process.run() } catch { return "fatal:spawn" }
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return "ok"
        case 3: return "warnings"
        default:
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            let first = err.split(separator: "\n").first.map(String.init) ?? ""
            return "fatal:exit\(process.terminationStatus)\(first.isEmpty ? "" : ": \(first)")"
        }
    }
}
