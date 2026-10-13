import Testing
import Foundation
@testable import PDFTools

/// Phase V2-1 (§7.5) – Native Byte-Attribution.
///
/// Festgenagelt werden die EIGENSCHAFTEN der Messung, nicht konkrete
/// Dokumentwerte:
///   1. Vollständigkeit: Σ(Kategorien) + unattributed = documentBytes.
///   2. Determinismus: zwei Messungen desselben Dokuments sind gleich.
///   3. Stabilität unter der Definition: vor/nach einem verlustfreien Pass
///      bleibt die Definition dieselbe (Bildduplikate verschwinden →
///      jpeg_bytes schrumpft, unattributed wächst entsprechend).
///   4. Environment-geführter Cross-Check gegen Scripts/byte-attribution.py
///      (unabhängige Referenz, bleibt bestehen) – läuft nur auf Anforderung,
///      weil er python3 und Korpusdokumente braucht.
@Suite struct SpaceAttributionTests {

    @Test(.hangGuard) func inventarIstVollständigUndDeterministisch() throws {
        let url = try PDFFixtures.dedupStreamsPDF(pages: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try PDFCoreDocument(path: url.path)
        let documentBytes = Int64(
            (try FileManager.default.attributesOfItem(atPath: url.path))[.size] as! Int)
        let inventory = try doc.spaceInventory(documentBytes: documentBytes)

        // 1. Vollständigkeit – die Restbilanz schließt die Messung ab.
        #expect(inventory.attributedBytes + inventory.unattributedBytes
                    == inventory.documentBytes, Comment(rawValue: "Attribution schließt nicht auf die Dokumentgröße auf: \(inventory)"))

        // 2. Determinismus – dieselbe Datei, dasselbe Ergebnis.
        let again = try doc.spaceInventory(documentBytes: documentBytes)
        #expect(again == inventory)

        // Die Fixture trägt JPEG-Bilder und Content-Streams; die Font-Dicts
        // sind ohne FontFile (kein eingebettetes Programm).
        #expect(inventory.jpegBytes > 0, Comment(rawValue: "Fixture hat JPEG-Bilder"))
        #expect(inventory.contentStreamBytes > 0, Comment(rawValue: "Fixture hat Content-Streams"))
        #expect(inventory.fontProgramBytes == 0, Comment(rawValue: "Fixture-Fonts tragen kein FontFile-Programm"))
        #expect(inventory.objectStreamBytes == 0, Comment(rawValue: "RawPDFBuilder schreibt keine Objektströme"))
    }

    @Test(.hangGuard) func definitionStabilVorUndNachVerlustfreiemPass() throws {
        let url = try PDFFixtures.dedupStreamsPDF(pages: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try PDFCoreDocument(path: url.path)
        let documentBytes = Int64(
            (try FileManager.default.attributesOfItem(atPath: url.path))[.size] as! Int)
        let before = try doc.spaceInventory(documentBytes: documentBytes)

        // Verlustfreier Pass: Duplikate werden referenziell zusammengeführt;
        // der Writer verwirft die Zwillinge beim nächsten Speichern. Um den
        // Effekt auf die Kategorien zu sehen, speichern wir in eine neue Datei.
        _ = try doc.deduplicate()
        let merged = FileManager.default.temporaryDirectory
            .appendingPathComponent("space-inventory-merged-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: merged) }
        try doc.save(to: merged)

        let mergedDoc = try PDFCoreDocument(path: merged.path)
        let mergedBytes = Int64(
            (try FileManager.default.attributesOfItem(atPath: merged.path))[.size] as! Int)
        let after = try mergedDoc.spaceInventory(documentBytes: mergedBytes)

        // Dieselbe Definition, beide Male geschlossen:
        #expect(after.attributedBytes + after.unattributedBytes == after.documentBytes)
        // Duplikate entfernt → Bildbytes schrumpfen, unattributed wächst.
        #expect(after.jpegBytes < before.jpegBytes, Comment(rawValue: "Dedup hat die Bildzwillinge nicht entfernt: \(before) → \(after)"))
        #expect(after.unattributedBytes + after.attributedBytes == mergedBytes)
    }

    /// Cross-Check gegen Scripts/byte-attribution.py (unabhängige Referenz).
    /// Environment-geführt (PDFTOOLS_SPACE_CROSSCHECK=1): spawn python3 und
    /// braucht die Referenzdokumente. Bekannte legitime Differenzen sind in
    /// `DocumentSpaceInventory` dokumentiert (ObjStm/unklassifizierte Streams
    /// liegen hier in eigenen Kategorien bzw. in unattributed).
    /// Cross-Check gegen Scripts/byte-attribution.py (unabhängige Referenz).
    ///
    /// Environment-geführt (PDFTOOLS_SPACE_CROSSCHECK=1). Die Referenzwerte
    /// stammen aus einem VOLLSTÄNDIGEN Lauf des Skripts (python3) über die
    /// jeweiligen Dokumente; das Skript bleibt die unabhängige Referenz und
    /// wird NICHT im Test gespawnt: Unter dem App-Sandbox-Profil des
    /// Test-Hosts blockiert der Zugriff auf Desktop-Dateien des Python-
    /// Kindes (und auf das Skript selbst) endlos – gemessen, nicht ohne
    /// Sandbox-Ausnahme behebbar. Neu messen:
    ///
    ///     python3 Scripts/byte-attribution.py <pdf> --no-dpi
    ///
    /// Erwartete Relationen (dokumentierte Differenzen, siehe
    /// DocumentSpaceInventory):
    ///   - images/fonts/content/metadata/embedded: identisch
    ///   - unattributed(hier) = structure_estimate(Skript) − object_stream(hier)
    @Test(.hangGuard) func crossCheckGegenReferenzSkript() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PDFTOOLS_SPACE_CROSSCHECK"] == "1"
            || env["TEST_RUNNER_PDFTOOLS_SPACE_CROSSCHECK"] == "1" else {
            return
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()

        // Referenz (Scripts/byte-attribution.py, python3, --no-dpi,
        // gemessen 2026-09-01): Kategorien und structure_estimate; images
        // ist die Summe über die Bildklassen des Skripts.
        let adoc = repoRoot.appendingPathComponent("Benchmarks/adhoc/PDF-Dokument.pdf")
        try Self.compareWithReference(
            pdf: adoc,
            reference: Reference(
                images: 17_151_897, fonts: 0, contentStreams: 124_910,
                metadata: 0, embeddedFiles: 0, structureEstimate: 19_611))

        // statab – nur wenn der Korpus die Datei bereitstellt.
        let statab = CorpusRootResolver.resolve().root
            .appendingPathComponent("RealWorld/Census/statab_2012.pdf")
        if FileManager.default.fileExists(atPath: statab.path) {
            try Self.compareWithReference(
                pdf: statab,
                reference: Reference(
                    images: 74_961, fonts: 29_572, contentStreams: 17_131_036,
                    metadata: 486_939, embeddedFiles: 0,
                    structureEstimate: 14_237_278))
        }
    }

    private struct Reference {
        var images: Int64
        var fonts: Int64
        var contentStreams: Int64
        var metadata: Int64
        var embeddedFiles: Int64
        var structureEstimate: Int64
    }

    private static func compareWithReference(pdf: URL, reference: Reference) throws {
        // Raw stat statt attributesOfItem: Foundation liest beim Attribut-
        // zugriff Extended Attributes – und getxattr auf Desktop-Dateien
        // blockiert unter dem App-Sandbox-Profil endlos (gemessen). Rohe
        // open/stat-Syscalls funktionieren, genau wie pdfcore sie nutzt.
        var status = stat()
        guard stat(pdf.path, &status) == 0, status.st_size > 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let documentBytes = Int64(status.st_size)
        let native = try PDFCoreDocument(path: pdf.path)
            .spaceInventory(documentBytes: documentBytes)
        let name = pdf.lastPathComponent

        #expect(reference.images == native.imageBytesTotal,
                Comment(rawValue: "\(name): Bilder \(native.imageBytesTotal) ≠ Referenz \(reference.images)"))
        #expect(reference.fonts == native.fontProgramBytes,
                Comment(rawValue: "\(name): Fonts \(native.fontProgramBytes) ≠ Referenz \(reference.fonts)"))
        #expect(reference.contentStreams == native.contentStreamBytes,
                Comment(rawValue: "\(name): Content \(native.contentStreamBytes) ≠ Referenz \(reference.contentStreams)"))
        #expect(reference.metadata == native.metadataBytes,
                Comment(rawValue: "\(name): Metadaten \(native.metadataBytes) ≠ Referenz \(reference.metadata)"))
        #expect(reference.embeddedFiles == native.embeddedFileBytes,
                Comment(rawValue: "\(name): Anhänge \(native.embeddedFileBytes) ≠ Referenz \(reference.embeddedFiles)"))
        // Dokumentierte Differenz: unattributed(hier) =
        // structure_estimate(Skript) − object_stream_bytes(hier).
        #expect(native.unattributedBytes == reference.structureEstimate - native.objectStreamBytes,
                Comment(rawValue: "\(name): Restbilanz \(native.unattributedBytes) ≠ Referenz \(reference.structureEstimate) − ObjStm \(native.objectStreamBytes)"))
    }
}
