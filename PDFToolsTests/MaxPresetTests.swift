import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import PDFTools

/// Phase 3c (Roadmap) – Verdrahtung des Maximum-Presets, des Kompatibilitäts-
/// verhaltens und der Estimator-Rückführung.
///
/// Festgenagelt werden:
///   1. NUR das Maximum-Preset schickt QPDF_ZOPFLI=silent in den qpdf-Prozess;
///      Smart (und alle anderen Presets) erben die Parent-Umgebung.
///   2. Der Kompatibilitätsmodus repackt behaltene DCT-Streams nur mit
///      optimierten Huffman-Tabellen (Baseline) und verzichtet im
///      Struktur-Pass auf Objekt-Streams.
///   3. Der Estimator führt Repack- und Dedup-Ersparnis messbar in seinem
///      Band (Roadmap Phase 1b offener Punkt).
@Suite struct MaxPresetTests {

    // MARK: - Helfer

    private static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("max-\(label)-\(UUID().uuidString)")
    }

    private static func syntheticPlan(originalDocumentBytes: Int,
                                      originalImageBytes: Int) -> CompressionPlan {
        CompressionPlan(
            documentID: "max-estimator",
            actions: [.keep(objectID: PDFObjectID(objectNumber: 1, generation: 0),
                            reason: .withinBudget,
                            originalEncodedBytes: originalImageBytes)],
            metadataPolicy: .preserve,
            linearizationPolicy: .none,
            dedupPolicy: .auto,
            fontPolicy: .auto,
            compatibilityPolicy: .modern,
            originalImageBytes: originalImageBytes,
            originalDocumentBytes: originalDocumentBytes)
    }

    // MARK: 1 – Maximum-Preset → Zopfli

    /// Voraussetzung aller Env-Capture-Tests: Die Suite selbst reist nicht
    /// mit einem gesetzten QPDF_ZOPFLI an.
    @Test func maximumPresetSetztQPDFZopfliSilent() throws {
        #expect(ProcessInfo.processInfo.environment["QPDF_ZOPFLI"] == nil,
                "Testumgebung trägt bereits QPDF_ZOPFLI – Capture unbrauchbar")
        let environment = try #require(Compressor.structurePassEnvironment(
            flate: .maximum, compatibility: .modern))
        #expect(environment["QPDF_ZOPFLI"] == "silent")
        // Die Parent-Umgebung wird ergänzt, nicht ersetzt.
        #expect(environment.count >=
                ProcessInfo.processInfo.environment.count)
    }

    /// Sicherheitsnetz: Smart – und damit auch Small/Quality/Custom – erbt
    /// die Umgebung, setzt also nie Zopfli.
    @Test func standardPresetErbtDieUmgebung() {
        #expect(Compressor.structurePassEnvironment(
            flate: .standard, compatibility: .modern) == nil)
    }

    /// Und im Kompatibilitätsmodus läuft Zopfli ebenfalls nie.
    @Test func kompatibilitaetsmodusBleibtOhneZopfli() {
        #expect(Compressor.structurePassEnvironment(
            flate: .maximum, compatibility: .maximum) == nil)
    }

    /// Nur die interne Stufe trägt die Max-Politik; kein anderes Preset erbt
    /// sie, und die Bildwerte folgen bewusst `quality`.
    /// Ende-zu-Ende am Stellvertreter: Der für das Maximum-Preset gebaute
    /// Prozess trägt QPDF_ZOPFLI=silent und die Roadmap-Flags – gefangen von
    /// einem Skript statt des echten qpdf (Zopfli ist ~100× zu langsam für
    /// einen Testlauf gegen echte Bytes).
    @Test(.hangGuard) func strukturPassProzessFührtZopfliEnvMitSich() throws {
        let capture = Self.tempURL("capture.txt")
        let script = Self.tempURL("qpdf-stand-in.sh")
        try Data("#!/bin/sh\nenv > \(capture.path)\nexit 0\n".utf8)
            .write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let process = Compressor.makeStructureProcess(
            qpdfPath: script.path,
            input: Self.tempURL("in.pdf"),
            output: Self.tempURL("out.pdf"),
            linearize: false, compatibility: .modern, flate: .maximum)
        try process.run()
        process.waitUntilExit()

        let captured = try String(contentsOf: capture, encoding: .utf8)
        #expect(captured.contains("QPDF_ZOPFLI=silent"),
                "QPDF_ZOPFLI=silent erreicht den qpdf-Prozess nicht")
        #expect(captured.contains("PATH="),
                "Umgebung wurde ersetzt statt ergänzt")
    }

    /// Produktionspfad auf Miniatur: Das Maximum-Preset läuft durch die volle
    /// Kompression und bleibt gültig. (Ob Zopfli wirklich anspringt, prüft
    /// der Capture-Test oben – hier geht es um die Verdrahtung der Optionen.)
    @Test(.hangGuard) func maximumPresetKomprimiertEndToEnd() throws {
        let input = try PDFFixtures.textPDF(lines: 200)
        defer { try? FileManager.default.removeItem(at: input) }

        let result = try Compressor().compress(inputURL: input,
                                               options: .maximum)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.outputBytes <= result.inputBytes,
                "Maximum-Preset hat die Datei vergrößert")
        #expect(Compressor.pageCount(of: result.outputURL) ==
                Compressor.pageCount(of: input),
                "Seitenzahl hat sich geändert")
    }

    // MARK: 2 – Kompatibilitätsverhalten

    /// qpdf-Seite: Der Kompatibilitätsmodus schreibt Objekt-Streams ab,
    /// sonst bleiben es die Roadmap-Flags.
    @Test func kompatibilitaetsmodusSchreibtObjektstreamsAb() {
        #expect(Compressor.structurePassArguments(linearize: false,
                                                  objectStreamsDisabled: false)
                == ["--object-streams=generate", "--recompress-flate",
                    "--compression-level=9"])
        #expect(Compressor.structurePassArguments(linearize: false,
                                                  objectStreamsDisabled: true)
                == ["--object-streams=disable", "--recompress-flate",
                    "--compression-level=9"])
        #expect(Compressor.structurePassArguments(linearize: true,
                                                  objectStreamsDisabled: false)
                == ["--object-streams=generate", "--recompress-flate",
                    "--compression-level=9", "--linearize"])
    }

    /// Die Politik wandert über den Plan in den Executor: Behaltene DCT-
    /// Streams werden optimize-only neu verpackt – NIE progressiv. Zum
    /// Kontrast derselbe Lauf im modernen Modus.
    @Test(.hangGuard) func kompatibilitaetsmodusRepacktNurBaseline() throws {
        let image = try #require(MozjpegBackendTests.noiseImage(400, 400))
        let baseline = try #require(
            ImageResampler.encodeJPEG(image, quality: 0.85, backend: .imageIO))
        #expect(MozjpegBackendTests.sofMarker(baseline) == 0xC0,
                "Fixture ist nicht baseline – Ausgangslage trägt nicht")
        let input = try MozjpegBackendTests.dctPDF(jpeg: baseline, pixels: 400)
        defer { try? FileManager.default.removeItem(at: input) }

        var options = CompressionOptions.smart
        options.compatibilityPolicy = .maximum

        let planned = try CompressionPipeline.plan(inputURL: input,
                                                   options: options)
        #expect(planned.plan.compatibilityPolicy == .maximum,
                "Plan trägt die Kompatibilitätspolitik nicht")

        let out = Self.tempURL("compat.pdf").appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                        options: options)

        let core = try PDFCoreDocument(path: out.path)
        let resources = try core.imageResources()
        try #require(resources.count == 1)
        let bytes = try #require(core.imageStreamData(
            objectID: resources[0].objectID, decoded: false))
        #expect(MozjpegBackendTests.sofMarker(bytes) != 0xC2,
                "Kompatibilitätsmodus hat progressive Scans geschrieben")
        #expect(bytes.count <= baseline.count,
                "Repack hat das Bild wachsen lassen")

        // Kontrast: moderner Modus kommt progressiv heraus.
        let modernOut = Self.tempURL("modern.pdf").appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: modernOut) }
        _ = try CompressionPipeline.run(inputURL: input, outputURL: modernOut,
                                        options: .smart)
        let modernCore = try PDFCoreDocument(path: modernOut.path)
        let modernResources = try modernCore.imageResources()
        try #require(modernResources.count == 1)
        let modernBytes = try #require(modernCore.imageStreamData(
            objectID: modernResources[0].objectID, decoded: false))
        #expect(MozjpegBackendTests.sofMarker(modernBytes) == 0xC2,
                "Kontrastfall trägt nicht: moderner Repack blieb baseline")
    }

    // MARK: 3 – Estimator-Rückführung (Phase 1b offener Punkt)

    /// Regression: Der Punktwert enthält die Repack-Ersparnis behaltener
    /// DCT-Streams – faktorisiert mit `keptDCTRepackSaving` (5 %).
    @Test func estimatorBandEnthältRepackFaktor() throws {
        let plan = Self.syntheticPlan(
            originalDocumentBytes: 10_000_000, originalImageBytes: 8_000_000)
        let withoutRepack = CompressionEstimator.estimate(
            plan: plan, pageCount: 1, structureRetention: 1.0)
        let withRepack = CompressionEstimator.estimate(
            plan: plan, pageCount: 1, structureRetention: 1.0,
            repackableDCTBytes: 100_000)

        let delta = withoutRepack.pointBytes - withRepack.pointBytes
        #expect(delta == 5_000,
                "Repack-Faktor ist im Punktwert nicht nachvollziehbar: \(delta)")
        // Das Band bleibt eine Band-Schätzung und folgt dem Punkt.
        #expect(withRepack.lowBytes < withRepack.pointBytes)
        #expect(withRepack.highBytes > withRepack.pointBytes)
    }

    /// Die Dedup-Ersparnis geht als gemessene Größe in den Punktwert ein;
    /// der Clamp hält den Punktwert nie unter null.
    @Test func estimatorZiehtGemesseneDedupErsparnisAb() throws {
        let plan = Self.syntheticPlan(
            originalDocumentBytes: 10_000_000, originalImageBytes: 8_000_000)
        let base = CompressionEstimator.estimate(
            plan: plan, pageCount: 1, structureRetention: 1.0)
        let deduped = CompressionEstimator.estimate(
            plan: plan, pageCount: 1, structureRetention: 1.0,
            dedupEstimatedBytes: 120_000)
        #expect(base.pointBytes - deduped.pointBytes == 120_000)

        let clamped = CompressionEstimator.estimate(
            plan: plan, pageCount: 1, structureRetention: 1.0,
            dedupEstimatedBytes: 500_000_000)
        #expect(clamped.pointBytes == 0)
    }

    /// Ende-zu-Ende über die Dokument-Analyse: Auf einem Duplikat-Dokument
    /// schätzt der Estimator mit Dedup messbar kleiner als mit
    /// `dedupPolicy .off` – die Vorschau erkennt die doppelten Streams.
    @Test(.hangGuard) func estimatorErkenntDedupErsparnisAmDokument() throws {
        let url = try PDFFixtures.dedupStreamsPDF(pages: 6)
        defer { try? FileManager.default.removeItem(at: url) }

        var offOptions = CompressionOptions.smart
        offOptions.dedupPolicy = .off
        let withoutDedup = try #require(CompressionEstimator.estimate(
            url: url, options: offOptions))
        let withDedup = try #require(CompressionEstimator.estimate(
            url: url, options: .smart))

        #expect(withDedup.pointBytes < withoutDedup.pointBytes,
                Comment(rawValue: "Dedup-Vorschau senkt die Schätzung nicht: "
                    + "\(withDedup.pointBytes) vs \(withoutDedup.pointBytes)"))
    }
}
