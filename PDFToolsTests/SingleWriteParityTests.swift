import Testing
import Foundation
@testable import PDFTools

/// Masterplan §15.6 – Single Final Write: Output-Parität gegen den
/// bisherigen Zwei-Write-Pfad.
///
/// Beweis je Fixture (photo/graphics/bilevel/cmyk/jpx/fonts/ObjStm-Input):
///   1. qpdf --check ohne strukturellen Fehler (ok oder nur Warnungen)
///   2. Semantik gleich (PDFSemanticSnapshot, vollständiger Snapshot)
///   3. Größe „nicht relevant schlechter“: Single-Write ≤ Alter + 1 %
///
/// Beide Pfade fahren DENSELBEN Plan (deterministische Planung, frisches
/// Öffnen des Originals – PDFObjectID-Regel); nur der Write unterscheidet
/// sich: images.pdf + qpdf-CLI-Pass vs. EIN Write mit Writer-Optionen.
///
/// §15.7-Ausnahme, hier mitgetestet: FlatePolicy .maximum (Zopfli) fällt
/// auf den Zwei-Write-Pfad zurück – `CompressionPipeline.singleWriteRequested`
/// meldet false, der Executor schreibt wie bisher.
@Suite struct SingleWriteParityTests {

    private static let tolerance: Double = 1.01

    // MARK: Fixtures (photo/graphics/bilevel/cmyk/jpx/fonts/ObjStm)

    private struct FixtureCase {
        let name: String
        let build: () throws -> URL
        var linearize: Bool = false
        var compatibility: CompatibilityPolicy = .modern
        var stripMetadata: Bool = false
    }

    private static func fixtures() -> [FixtureCase] {
        [
            // photo – JPEG-Quelle, Resample + mozjpeg-Race.
            FixtureCase(name: "photo", build: { try PDFFixtures.photoAtWidth(1600) }),
            // graphics – verlustfreie Flate/Palette-Pfade.
            FixtureCase(name: "graphics", build: { try PDFFixtures.manyImagesPDF(count: 6) }),
            // bilevel-Eingang (CCITT G4 → Race KEEP/G4/JBIG2).
            FixtureCase(name: "bilevel", build: { try PDFFixtures.ccittG4InputPDF() }),
            // CMYK (ΔE-Gate/6b-Race-Pfad).
            FixtureCase(name: "cmyk", build: { try PDFFixtures.cmykPhotoPDF(pixelWidth: 1200) }),
            // JPX-Eingang (OpenJPEG-Shim).
            FixtureCase(name: "jpx", build: { try PDFFixtures.jpxImagePDF(kind: .photoRGBLossy, placedWidth: 400) }),
            // Fonts (Font-Dedup/GC laufen mit).
            FixtureCase(name: "fonts", build: { try PDFFixtures.dedupFontsPDF(pages: 2) }),
            // ObjStm-Eingang: Objekt-Streams im EINEN Write neu generieren.
            FixtureCase(name: "objstm", build: { try PDFFixtures.objectStreamPDF() }),
            // Varianten: linearize / Kompatibilität (ObjStm aus) / Metadaten.
            FixtureCase(name: "linearize", build: { try PDFFixtures.photoAtWidth(1200) }, linearize: true),
            FixtureCase(name: "compat-maximum", build: { try PDFFixtures.objectStreamPDF() }, compatibility: .maximum),
            FixtureCase(name: "strip-metadata", build: { try PDFFixtures.metadataPDF() }, stripMetadata: true),
        ]
    }

    private static func optionsFor(_ fixture: FixtureCase) -> CompressionOptions {
        var options = CompressionOptions(
            image: .smart,
            metadataPolicy: fixture.stripMetadata ? .strip : .preserve,
            linearizationPolicy: fixture.linearize ? .fastWebView : .none,
            flatePolicy: .standard,
            compatibilityPolicy: fixture.compatibility)
        options.featureFlags.candidateEngine = true
        options.featureFlags.singleWrite = true
        return options
    }

    // MARK: Der Zwei-Write-Pfad (Referenz, wie vor V2-9 produziert)

    /// images.pdf (Executor, Writer-Defaults) + qpdf-CLI-Pass mit den
    /// bestehenden Struktur-Pass-Flags; Never-Grow-Regel wie in
    /// Compressor.runStructurePass (nicht kleiner → Eingabe bleibt;
    /// Linearisierung vergrößert planmäßig und bleibt trotzdem).
    private static func legacyFinalOutput(images: URL,
                                          cliOutput: URL,
                                          linearize: Bool,
                                          compatibility: CompatibilityPolicy,
                                          flate: FlatePolicy) throws -> URL {
        let qpdfPath = try #require(Compressor.findQPDF(), "qpdf fehlt")
        let process = Compressor.makeStructureProcess(
            qpdfPath: qpdfPath, input: images, output: cliOutput,
            linearize: linearize,
            compatibility: compatibility,
            flate: flate)
        try process.run()
        process.waitUntilExit()
        let succeeded = process.terminationStatus == 0
            || process.terminationStatus == 3
        let outputSize = Compressor.fileSize(of: cliOutput)
        guard succeeded, outputSize > 0 else { return images }
        if linearize { return cliOutput }
        return outputSize < Compressor.fileSize(of: images) ? cliOutput : images
    }

    /// qpdf --check: 0 = ok, 3 = nur Warnungen – beides „strukturell in
    /// Ordnung“ (dieselbe Bewertung wie die Smoke-Validierung).
    private static func qpdfCheck(_ url: URL) -> String {
        guard let qpdfPath = Compressor.findQPDF() else { return "fatal:qpdf-missing" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdfPath)
        process.arguments = ["--check", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "fatal:spawn"
        }
        switch process.terminationStatus {
        case 0: return "ok"
        case 3: return "warnings"
        default: return "fatal:\(process.terminationStatus)"
        }
    }

    // MARK: Der Vergleich

    @Test(.hangGuard) func parityUeberAlleFixtures() throws {
        var table = "\n=== SINGLE-WRITE-PARITÄT (§15.6) ===\n"
        table += "fixture        |    old |    new |    Δ   | check(old) | check(new) | semantik\n"
        for fixture in Self.fixtures() {
            let input = try fixture.build()
            defer { try? FileManager.default.removeItem(at: input) }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("singlewrite-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            var options = Self.optionsFor(fixture)

            // ALTER PFAD (Referenz): Executor-Write (Writer-Defaults) +
            // qpdf-CLI-Pass mit den bestehenden Struktur-Pass-Flags.
            options.featureFlags.singleWrite = false
            let images = dir.appendingPathComponent("images.pdf")
            let legacyOutcome = try CompressionPipeline.run(
                inputURL: input, outputURL: images, options: options)
            #expect(!legacyOutcome.execution.singleWriteUsed,
                    "Legacy-Lauf darf den Single-Write-Pfad nicht benutzen")
            let cliOutput = dir.appendingPathComponent("structure-cli.pdf")
            let oldFinal = try Self.legacyFinalOutput(
                images: images, cliOutput: cliOutput,
                linearize: fixture.linearize,
                compatibility: fixture.compatibility,
                flate: options.flatePolicy)

            // NEUER PFAD: modern → EIN Write mit finalen Writer-Optionen;
            // compat-maximum → dokumentierter Zwei-Write-Fallback (s. o.).
            options.featureFlags.singleWrite = true
            let single = dir.appendingPathComponent("single.pdf")
            let outcomeNew = try CompressionPipeline.run(
                inputURL: input, outputURL: single, options: options)
            if fixture.compatibility == .modern {
                #expect(outcomeNew.execution.singleWriteUsed,
                        "Single-Write muss gemeldet werden (Fixture \(fixture.name))")
            } else {
                #expect(!outcomeNew.execution.singleWriteUsed,
                        "Kompatibilitätsmodus fällt auf Zwei-Write zurück (Fixture \(fixture.name))")
            }

            // 1) qpdf --check beider Outputs.
            let checkOld = Self.qpdfCheck(oldFinal)
            let checkNew = Self.qpdfCheck(outcomeNew.execution.outputURL)
            #expect(!checkOld.hasPrefix("fatal"),
                    "qpdf --check (alt, \(fixture.name)): \(checkOld)")
            #expect(!checkNew.hasPrefix("fatal"),
                    "qpdf --check (neu, \(fixture.name)): \(checkNew)")

            // 2) Semantik gleich – vollständiger Snapshot.
            let snapOld = try PDFSemanticSnapshot.capture(oldFinal)
            let snapNew = try PDFSemanticSnapshot.capture(outcomeNew.execution.outputURL)
            let diffKinds = PDFSemanticSnapshot.differences(snapOld, snapNew)
                .map { $0.kind.rawValue }.sorted()
            #expect(snapNew == snapOld,
                    "Semantik muss gleich sein (Fixture \(fixture.name); Diff: \(diffKinds))")

            // 3) Größe „nicht relevant schlechter“ (≤ +1 %).
            let oldBytes = Compressor.fileSize(of: oldFinal)
            let newBytes = Compressor.fileSize(of: outcomeNew.execution.outputURL)
            #expect(Double(newBytes) <= Double(oldBytes) * Self.tolerance,
                    "Single-Write nicht relevant schlechter (\(fixture.name)): old=\(oldBytes) new=\(newBytes)")

            table += "\(fixture.name.padding(toLength: 14, withPad: " ", startingAt: 0))"
                + " | \(String(format: "%6d", oldBytes))"
                + " | \(String(format: "%6d", newBytes))"
                + String(format: " | %+5.1f%%", Double(newBytes - oldBytes)
                            / Double(max(oldBytes, 1)) * 100)
                + " | \(checkOld.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + " | \(checkNew.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + " | \(snapNew == snapOld ? "gleich" : "DIFF")\n"

            // Debug-Dump für Paritätsanalysen (PDFTOOLS_PARITY_DUMP=1).
            if ProcessInfo.processInfo.environment["PDFTOOLS_PARITY_DUMP"] == "1" {
                let dump = URL(fileURLWithPath: "/tmp/opencode/swprobe")
                try? FileManager.default.createDirectory(at: dump,
                                                         withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: oldFinal, to: dump
                    .appendingPathComponent("\(fixture.name)-old.pdf"))
                try? FileManager.default.copyItem(at: outcomeNew.execution.outputURL, to: dump
                    .appendingPathComponent("\(fixture.name)-new.pdf"))
                try? FileManager.default.copyItem(at: input, to: dump
                    .appendingPathComponent("\(fixture.name)-input.pdf"))
            }
        }
        print(table)
    }

    // MARK: §15.7/§15.6-Ausnahmen – Zopfli und Kompatibilitätsmodus bleiben
    // im Zwei-Write-Pfad

    @Test func flateMaximumFaelltAufZweiWritePfadZurueck() {
        // Maximum (Zopfli) mit Flags: singleWriteRequested meldet false –
        // der Compressor lässt den CLI-Pass laufen (dokumentierte Ausnahme).
        var maximum = CompressionPresetFactory.maximum()
        maximum.featureFlags.candidateEngine = true
        maximum.featureFlags.singleWrite = true
        #expect(!CompressionPipeline.singleWriteRequested(options: maximum))

        // Kompatibilitätsmodus: --object-streams=disable expandiert bei
        // ObjStm-Eingängen, und der Never-Grow-Vergleich des Struktur-Passes
        // behielt images.pdf (gemessen +2,7 %) – die Interaktion bleibt im
        // Zwei-Write-Pfad (dokumentierte Ausnahme).
        let compat = Self.optionsFor(
            FixtureCase(name: "compat", build: { try PDFFixtures.objectStreamPDF() },
                        compatibility: .maximum))
        #expect(!CompressionPipeline.singleWriteRequested(options: compat))

        // Standard-Flate + Flags + modern → Single-Write aktiv.
        var standard = Self.optionsFor(Self.fixtures()[0])
        #expect(CompressionPipeline.singleWriteRequested(options: standard))

        // Flag aus → nie (Not-Aus-Schalter, §25).
        standard.featureFlags.singleWrite = false
        #expect(!CompressionPipeline.singleWriteRequested(options: standard))
        // V2-11 – Smart fährt die Core-Flags per Default: Single-Write AN.
        #expect(CompressionPipeline.singleWriteRequested(options: .smart))
        // Advanced-Flag mrc ändert daran nichts.
        var mrcOptions = CompressionOptions.smart
        mrcOptions.featureFlags.mrc = true
        #expect(CompressionPipeline.singleWriteRequested(options: mrcOptions))
    }
}
