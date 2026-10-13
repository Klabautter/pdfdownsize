import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan §11.7 / Phase V2-1 §7.8 – `statab_2012` Semantic-Regression.
///
/// DER FALL (Baseline 2026-08-31, Smoke_30):
/// `RealWorld/Census/statab_2012.pdf` (31,96 MB, 940 Seiten) scheiterte in
/// ALLEN drei Presets mit identischer Meldung:
///
///     Validierung fehlgeschlagen: Seite 12 Textinhalt:
///     cc107b880a69c3db → 24dcacc7aed05197
///
/// BEFUND (Isolation-Lauf vom 2026-09-01, Smart, Stufen in AUSFÜHRUNGS-
/// reihenfolge verglichen):
///
///     00_original   fp12 = cc107b880a69c3db   (Original)
///     20_dedup      fp12 = cc107b880a69c3db   unverändert
///     30_fonts      fp12 = 24dcacc7aed05197   ← ABWEICHUNG ENTSTAND HIER
///     40_metadata   fp12 = 24dcacc7aed05197
///     10_images     fp12 = 24dcacc7aed05197   (Endausgabe der Pipeline)
///     50_structure  fp12 = 24dcacc7aed05197
///
/// Verursacher war der FONT-PASS (pdfcore_font_audit: Font-Dedup +
/// Unused-Font-GC). Der Mechanismus, per qpdf-Analyse der Stufendatei
/// 30_fonts gegen 20_dedup nachgewiesen:
///
///   1. Seite 12 referenziert im /Font-Map u. a. /C0_0 → Objekt 444349
///      (Type0, BQOPPG+LucidaSans, /Encoding /Identity-H) und nutzt ihn im
///      Content: `/C0_0  1 Tf <0016…>Tj` – sechsstellige Zahlen wie
///      „260,698“.
///   2. Seite 12 hat ACHT /Contents-Streams. Der Tf ist ÜBER DIE GRENZE
///      ZWEIER STREAMS GETEILT: Stream 6 endet mit `/C0_0  ` (Name plus
///      Leerzeichen), Stream 7 beginnt mit `1 Tf`. Im zusammensetzten
///      Content ist das gültig.
///   3. Der Tf-Scanner der Unused-Font-GC scannte JEDEEN Array-Eintrag
///      isoliert: In Stream 6 blieb der Name ohne operatorisches Ende,
///      in Stream 7 stand `Tf` ohne Namen voran. Die Nutzung wurde nicht
///      erkannt, der Eintrag galt als unbenutzt.
///   4. Die GC trug /C0_0 aus der Resources-Map (gemessen: unused_fonts_
///      removed = 1 auf dem einseitigen Extrakt, dupRefs = 0 – Dedup und
///      Bild-Pässe waren unbeteiligt). PDFKit ergänzte die fehlende Schrift
///      still, die Textextraktion drehte („260,698“ → NUL-durchsetzte
///      Falschzeichen) → Fingerprint 24dcacc7.
///
/// V2-5 (§11.7-Exit): Die Ursache ist REPARIERT, nicht umgangen. Der
/// pdfcore-Tf-Scanner scannt die KONKATENATION aller /Contents-Bytes einer
/// Seite/Form (mit Trenn-Byte gegen Tokenverschmelzung, Budget wie die
/// bestehenden Scans) und erkennt Tf-Nutzung über Array-Grenzen. Der
/// dokumentierte Exit gilt damit ERFÜLLT – alle normalen Presets laufen
/// ERFOLGREICH mit unverändertem Text-Fingerprint:
///
///     statab_2012: 31.959.786 B (Born-Digital-Text, ein Bild) → der
///     Pipeline-Output ist größer als die Eingabe, Never-Grow liefert das
///     byte-identische Original (sicherer Fallback ohne Semantikänderung);
///     Zahlen je Preset in der Testausgabe. qpdf --check nicht fatal.
///
/// Das hier ist der PERMANENTE Regressionstest dafür. Skip gibt es nicht:
/// Fehlt die Datei, kehrt der Test EARLY zurück; ist sie ausdrücklich
/// angefordert (PDFTOOLS_STATAB=1) und fehlt, ist das ein FEHLSCHLAG.
@Suite struct StatabSemanticRegressionTests {

    /// Seite 12 (1-basiert) trägt den dokumentierten Fingerprint des
    /// Originals – nach dem Scanner-Fix muss er UNVERÄNDERT bleiben.
    static let documentedOriginalFingerprint = "cc107b880a69c3db"

    private static func statabURL(fileManager: FileManager = .default) -> URL? {
        let root = CorpusRootResolver.resolve()
        let candidate = root.root
            .appendingPathComponent("RealWorld/Census/statab_2012.pdf")
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Seiten-Text-Fingerprint mit DEMSELBEN Maß wie der Snapshot
    /// (Wortfrequenz-FNV), ohne 940 Seiten capturen zu müssen.
    private static func pageFingerprint(_ url: URL, page index: Int) -> String? {
        guard let doc = PDFDocument(url: url), !doc.isLocked,
              doc.pageCount > index, let page = doc.page(at: index) else {
            return nil
        }
        return PDFSemanticSnapshot.fingerprint(page.string ?? "")
    }

    private static func qpdfCheck(_ url: URL) -> String {
        CompressionIsolation.qpdfCheck(qpdfPath: Compressor.findQPDF(), url: url)
    }

    // MARK: - Permanenter Regressionstest (§11.7-Exit)

    @Test(.measurementRun) func statabSmartErfolgreichMitUnverändertemText() async throws {
        let env = ProcessInfo.processInfo.environment
        let requested = env["PDFTOOLS_STATAB"] == "1"
            || env["TEST_RUNNER_PDFTOOLS_STATAB"] == "1"
        guard let statab = Self.statabURL() else {
            // Datei fehlt → env-gated; ausdrücklich angefordert darf niemals
            // still durchlaufen (kein stummer Skip).
            #expect(!requested, Comment(rawValue:
                "statab_2012 ausdrücklich angefordert (PDFTOOLS_STATAB=1), "
                + "aber nicht unter RealWorld/Census gefunden."))
            return
        }

        let fm = FileManager.default
        let inputBytes = Compressor.fileSize(of: statab)
        let originalFP = try #require(Self.pageFingerprint(statab, page: 11),
                                      "Original hat keinen Text auf Seite 12")

        // (a) PIPELINE-EBENE (ohne Never-Grow): der ECHTE Pipeline-Output
        // trägt den Text von Seite 12 unverändert – genau das, was vor dem
        // Scanner-Fix der Font-Pass zerstört hat (Fingerprint 24dcacc7).
        let pipelineOut = fm.temporaryDirectory
            .appendingPathComponent("statab-pipeline-\(UUID().uuidString).pdf")
        defer { try? fm.removeItem(at: pipelineOut) }
        _ = try CompressionPipeline.run(inputURL: statab,
                                        outputURL: pipelineOut,
                                        options: .smart)
        let pipelineFP = try #require(Self.pageFingerprint(pipelineOut, page: 11),
                                      "Pipeline-Output hat keinen Text auf Seite 12")
        #expect(pipelineFP == originalFP,
                Comment(rawValue:
                    "Der PIPELINE-Output verändert Seite 12 – der Scanner-Fix "
                    + "hält nicht: pipeline=\(pipelineFP.prefix(16)) "
                    + "original=\(originalFP.prefix(16))"))
        #expect(pipelineFP == Self.documentedOriginalFingerprint,
                Comment(rawValue:
                    "Der dokumentierte Original-Fingerprint stimmt nicht mehr "
                    + "(erwartet \(Self.documentedOriginalFingerprint), "
                    + "gemessen \(pipelineFP.prefix(16))) – Befund aktualisieren!"))
        // qpdf --check nicht fatal (das Dokument trägt Quellen-Warnungen;
        // genau die toleriert auch die Pipeline-Validierung).
        #expect(["ok", "warnings"].contains(Self.qpdfCheck(pipelineOut)),
                "Strukturprüfung des Pipeline-Outputs fatal")

        // (b) PRODUKTIONSEBENE (§11.7): alle normalen Presets laufen
        // ERFOLGREICH. statab ist Born-Digital-Text mit einem Bild – der
        // Pipeline-Output ist größer als die Eingabe, Never-Grow liefert
        // deshalb das byte-identische Original (sicherer Fallback ohne
        // Semantikänderung). Gemeldet werden die Zahlen je Preset.
        for mode in [CompressionMode.small, .smart, .quality] {
            let result = try Compressor().compress(inputURL: statab, mode: mode)
            defer { try? fm.removeItem(at: result.outputURL) }
            let fp = try #require(Self.pageFingerprint(result.outputURL, page: 11))
            #expect(fp == originalFP,
                    Comment(rawValue:
                        "\(mode.rawValue): Seite 12 verändert "
                        + "(\(fp.prefix(16)) statt \(originalFP.prefix(16)))"))
            #expect(result.outputBytes <= result.inputBytes,
                    Comment(rawValue: "\(mode.rawValue): Never-Grow verletzt"))
            #expect(["ok", "warnings"].contains(Self.qpdfCheck(result.outputURL)),
                    "\(mode.rawValue): Strukturprüfung fatal")
            print("STATAB \(mode.rawValue): \(inputBytes) → \(result.outputBytes) "
                + "(\(String(format: "%.1f", result.savedPercent)) % gespart, "
                + "returnedOriginal=\(result.returnedOriginal)), "
                + "fp12=\(fp.prefix(16)) unverändert, qpdf nicht fatal")
        }
    }

    // MARK: - Fixture-Ebene (schnell, immer aktiv)

    /// Die Mechanismus-Zusage in klein: Der Split-Tf-Fall (Fixture mit
    /// /Contents-Array und geteiltem Tf) darf den Font weder in der Bridge
    /// noch in der Pipeline berühren. Vollständige Abdeckung in
    /// `FontDedupTests.gcErkenntTfNutzungÜberContentsArrayGrenze`.
    @Test(.hangGuard) func fixtureGeteilterTfWirdNichtBeräumt() throws {
        let url = try PDFFixtures.splitTfContentsPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.auditFonts()
        #expect(stats.unusedFontsRemoved == 0,
                Comment(rawValue:
                    "Der Scanner fasst eine über die Contents-Grenze genutzte "
                    + "Schrift an: \(stats)"))
    }
}
