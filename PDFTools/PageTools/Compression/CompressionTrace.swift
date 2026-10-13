import Foundation

/// Masterplan §7.4 – Resource Trace: pro Bildressource die Herkunft und die
/// getroffene Entscheidung, als JSON neben dem Output geschrieben.
///
/// Der Trace wird AUSSCHLIESSLICH aus bestehenden Plan-/Result-Daten
/// abgeleitet (CompressionPipeline, CompressionExecutor.Result) – es gibt
/// keine zweite Analyse und keinen zweiten Entscheidungspfad. Aktiviert
/// über die Umgebung `PDFTOOLS_COMPRESSION_TRACE=1`; im Produktionslauf
/// bleibt er aus.
///
/// JSON-Schema (Schlüssel snake_case, wie im Masterplan skizziert):
///
///     {
///       "schema": 1,
///       "document": "<Dateiname>",
///       "pass_attribution": { "jpeg": 0, "jpeg_repack": 0, ... },
///       "stage_timings": { "open_document_ms": 3.1, ... },
///       "resources": [
///         {
///           "object_id": "123 0",
///           "pages": [4, 8],
///           "source": {
///             "codec": "DCTDecode",
///             "bytes": 1827340,
///             "width": 4032,
///             "height": 3024,
///             "effective_dpi": 690.3,
///             "colorspace": "DeviceRGB"
///           },
///           "selected": "jpeg q=0.85 target=1200x900",
///           "reason": "kleinster Kandidat der Qualitätsleiter, der das Multi-Gate hält",
///           "applied": true,
///           "estimated_saved_bytes": 1613228
///         }
///       ]
///     }
struct CompressionTrace: Codable, Sendable {

    struct Source: Codable, Sendable {
        var codec: String
        var bytes: Int
        var width: Int
        var height: Int
        /// 0 = unbekannt (keine messbare Platzierung).
        var effectiveDPI: Double
        var colorspace: String
    }

    struct Resource: Codable, Sendable {
        /// „123 0“ – Objektnummer und Generation.
        var objectID: String
        var pages: [Int]
        var source: Source
        var selected: String
        var reason: String
        /// false, wenn die Bridge die Ersetzung verweigert hat.
        var applied: Bool
        /// Plan-Erwartung der Ersparnis (0 bei Keep) – `estimated`.
        var estimatedSavedBytes: Int
        /// Phase V2-2 – Klassifikation des Bildinhalts. Seit V2-11 in
        /// jedem Produktionslauf gefüllt (Candidate Engine, §8).
        var classification: Classification?

        enum CodingKeys: String, CodingKey {
            case objectID = "object_id"
            case pages, source, selected, reason, applied
            case estimatedSavedBytes = "estimated_saved_bytes"
            case classification
        }
    }

    /// Phase V2-2 – Klassifikationszeile im Trace (§8: `classification.class`
    /// + `confidence`). Features bleiben bewusst außen vor; sie wandern mit
    /// der Candidate-Engine (V2-3) in die `ResourceDecision`.
    struct Classification: Codable, Sendable {
        var contentClass: String
        var confidence: Double
        /// Ausgelöste Regel des Regelwerks (§8.3) – Diagnose.
        var rule: String

        enum CodingKeys: String, CodingKey {
            case contentClass = "class"
            case confidence, rule
        }
    }

    var schema: Int
    var document: String
    /// Pass-Attribution §7.6 – gesparte Bytes je Pass (alle `estimated`).
    var passAttribution: [String: Int]
    /// Stufenzeiten §7.3 (Millisekunden, leeres Objekt ohne StageTimer).
    var stageTimings: [String: Double]
    var resources: [Resource]
    /// V2-8 (§14.1) – selektive Font-Entscheidungen. Nur im Candidate-
    /// Engine-Pfad mit Font-Kandidaten gefüllt; ohne sie bleibt das Feld
    /// im JSON aus (additiv wie `classification`).
    var fonts: [Font]?

    enum CodingKeys: String, CodingKey {
        case schema, document
        case passAttribution = "pass_attribution"
        case stageTimings = "stage_timings"
        case resources
        case fonts
    }

    /// V2-8 – Trace-Zeile EINES Font-Kandidaten (§14.3/§14.4).
    struct Font: Codable, Sendable {
        var objectID: String
        var pages: [Int]
        var selected: String
        var reason: String
        /// true = der Subset-Kandidat wurde gewählt und ausgeführt.
        var applied: Bool
        /// false, wenn die je-Font-QA den Font zurückgerollt hat.
        var qaPassed: Bool
        var estimatedSavedBytes: Int

        enum CodingKeys: String, CodingKey {
            case objectID = "object_id"
            case pages, selected, reason, applied
            case qaPassed = "qa_passed"
            case estimatedSavedBytes = "estimated_saved_bytes"
        }
    }
}

enum CompressionTraceWriter {

    /// Aktivierung nur über die Umgebung – Benchmark-/Debug-Regal.
    static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["PDFTOOLS_COMPRESSION_TRACE"] == "1"
            || env["TEST_RUNNER_PDFTOOLS_COMPRESSION_TRACE"] == "1"
    }

    /// Baut den Trace aus den bestehenden Pipeline-Daten ab. Keine neue
    /// Analyse: Die Quelle ist genau der Plan, den auch der Executor fuhr,
    /// und genau das Result, das der Executor meldet.
    ///
    /// Phase V2-2 – `classifications` kommt aus dem Planner (nur im
    /// `.v2`-Pfad gefüllt) und ergänzt je Resource die Inhaltsklasse.
    static func makeTrace(plan: CompressionPlan,
                          resources: [PDFImageResource],
                          execution: CompressionExecutor.Result,
                          stageTimer: StageTimer?,
                          documentName: String,
                          classifications: [PDFObjectID: ResourceClassification] = [:]) -> CompressionTrace {
        // V2-8 – Font-Entscheidungen sind die ResourceDecisions, deren Set
        // einen fontKeep-Kandidaten trägt (Font-Sets bestehen NUR aus
        // fontKeep/fontSubset; Bild-Sets nie).
        let fontResourceIDs = Set(plan.candidateSets.filter { set in
            set.candidates.contains { candidate in
                if case .fontKeep = candidate.kind { return true }
                return false
            }
        }.map(\.resourceID))
        let fontDecisions = plan.decisions.filter {
            fontResourceIDs.contains($0.resourceID)
        }
        return CompressionTrace(
            schema: 1,
            document: documentName,
            passAttribution: passAttribution(execution),
            stageTimings: stageTimings(stageTimer),
            resources: buildResources(plan: plan, resources: resources,
                                      execution: execution,
                                      classifications: classifications),
            fonts: fontDecisions.isEmpty
                ? nil : buildFonts(decisions: fontDecisions,
                                   execution: execution))
    }

    /// V2-8 – Font-Zeilen aus Plan und Ausführung ableiten (keine zweite
    /// Analyse): `selected` ist die gewählte Kandidaten-ID, `applied` nur
    /// für Subsets, die die je-Font-QA durchlaufen haben.
    private static func buildFonts(
        decisions: [ResourceDecision],
        execution: CompressionExecutor.Result
    ) -> [CompressionTrace.Font] {
        let outcomesByID = Dictionary(execution.selectiveFontOutcomes.map {
            ("\( $0.objectID.objectNumber) \($0.objectID.generation)", $0)
        }, uniquingKeysWith: { first, _ in first })
        return decisions.map { decision in
            let outcome = outcomesByID[decision.resourceID]
            let applied = outcome?.result == .subsetted
            return CompressionTrace.Font(
                objectID: decision.resourceID,
                pages: decision.pages,
                selected: decision.selectedCandidateID.rawValue,
                reason: decision.reason,
                applied: applied,
                qaPassed: applied,
                estimatedSavedBytes: outcome?.estimatedSavedBytes ?? 0)
        }
    }

    /// Gesparte Bytes je Pass (§7.6) – alle Werte `estimated`.
    static func passAttribution(_ execution: CompressionExecutor.Result)
        -> [String: Int] {
        return [
            "jpeg": execution.bytesSavedJPEG,
            "jpeg_repack": execution.bytesSavedJPEGRepack,
            "lossless_resize": execution.bytesSavedLosslessResize,
            "indexed": execution.bytesSavedIndexed,
            "bilevel": execution.bytesSavedBilevel,
            "cmyk": execution.bytesSavedCMYK,
            "mrc": execution.bytesSavedMRC,
            "dedup": execution.bytesSavedDedup,
            "fonts": execution.bytesSavedFonts,
            "font_subset_selective": execution.bytesSavedSelectiveFontSubset,
            "resource_gc": execution.bytesSavedResourceGC,
            "flate_repack": execution.bytesSavedFlateRepack,
            "structure": execution.bytesSavedStructure,
        ]
    }

    private static func stageTimings(_ timer: StageTimer?) -> [String: Double] {
        guard let timer else { return [:] }
        let values = timer.timings
        var out: [String: Double] = [:]
        for field in StageTimings.Field.allCases {
            out[StageTimings.jsonKey(field)] = values.value(field)
        }
        return out
    }

    private static func buildResources(plan: CompressionPlan,
                                       resources: [PDFImageResource],
                                       execution: CompressionExecutor.Result,
                                       classifications: [PDFObjectID: ResourceClassification] = [:])
        -> [CompressionTrace.Resource] {
        let rejected = Set(execution.rejectedByBridge)
        return resources.map { resource in
            let action = plan.action(for: resource.objectID)
            let isApplied = action.map {
                $0.transformsImage && !rejected.contains($0.objectID)
            } ?? false
            let classification = classifications[resource.objectID].map {
                CompressionTrace.Classification(contentClass: $0.contentClass.rawValue,
                                                confidence: $0.confidence,
                                                rule: $0.features == nil ? "bilevel" : "v2")
            }
            return CompressionTrace.Resource(
                objectID: "\(resource.objectID.objectNumber) \(resource.objectID.generation)",
                pages: resource.placements.map(\.pageIndex).sorted(),
                source: CompressionTrace.Source(
                    codec: resource.terminalFilter?.rawValue ?? "unbekannt",
                    bytes: resource.encodedByteCount,
                    width: resource.width,
                    height: resource.height,
                    effectiveDPI: resource.effectiveDPI ?? 0,
                    colorspace: Self.colorspaceName(resource.colorSpace)),
                selected: selectedDescription(action),
                reason: reasonDescription(action),
                applied: isApplied,
                estimatedSavedBytes: estimatedSaved(action),
                classification: classification)
        }
    }

    /// Lesbarer Farbraumname für den Trace.
    private static func colorspaceName(_ descriptor: PDFColorSpaceDescriptor) -> String {
        switch descriptor {
        case .deviceGray: return "DeviceGray"
        case .deviceRGB: return "DeviceRGB"
        case .deviceCMYK: return "DeviceCMYK"
        case .calGray: return "CalGray"
        case .calRGB: return "CalRGB"
        case .lab: return "Lab"
        case .iccBased(let n): return "ICCBased:\(n)"
        case .indexed: return "Indexed"
        case .separation: return "Separation"
        case .deviceN: return "DeviceN"
        case .pattern: return "Pattern"
        case .none: return "None"
        case .unknown(let raw): return raw
        }
    }

    /// Beschreibt die GEWÄHLTE Aktion – nur aus Plan-Daten abgeleitet.
    private static func selectedDescription(
        _ action: ImageCompressionAction?) -> String {
        guard let action else { return "keine" }
        switch action {
        case .keep:
            return "keep"
        case .losslessResize(_, let target, let grayscale, _, _, _):
            return "lossless_resize target=\(target.width)x\(target.height)"
                + (grayscale ? " grayscale" : "")
        case .jpeg(_, let target, let quality, let grayscale, _, _, _):
            return String(format: "jpeg q=%.2f target=%dx%d%@",
                          quality, target.width, target.height,
                          grayscale ? " grayscale" : "")
        case .cmykJpegReencode(_, let target, let quality, _, _):
            return String(format: "cmyk_jpeg q=%.2f target=%dx%d",
                          quality, target.width, target.height)
        case .ccittG4:
            return "ccitt_g4"
        case .jbig2:
            return "jbig2"
        case .indexed(_, let target, let bpc, let components, let palette, _, _, let quantized, let dithered):
            return "indexed bpc=\(bpc) target=\(target.width)x\(target.height) "
                + "palette=\(palette.count / max(components, 1))x\(components)"
                + (quantized ? (dithered ? " quantized+dither" : " quantized") : " exact")
        case .mrc(_, let descriptor, _, _):
            return String(format: "mrc bg=%.0fdpi/q%.2f photo=%.0fdpi mask=%@ photos=%d",
                          descriptor.backgroundDPI, descriptor.backgroundQuality,
                          descriptor.photoDPI,
                          descriptor.maskCodec == .jbig2 ? "jbig2" : "g4",
                          descriptor.photoRegionCount)
        }
    }

    /// Begründung der Wahl – Keeps tragen ihren Grund im Plan, Transfor-
    /// mationen sind „kleinster Kandidat, der die Politik hält“.
    private static func reasonDescription(
        _ action: ImageCompressionAction?) -> String {
        guard let action else { return "unbekannt" }
        switch action {
        case .keep(_, let reason, _):
            return reason.explanation
        case .jpeg, .cmykJpegReencode:
            return "kleinster Kandidat der Qualitätsleiter, der das Multi-Gate hält"
        case .losslessResize:
            return "verlustfreie Verkleinerung (Grafik/CMYK-Politik)"
        case .indexed:
            return "kleinster verlustfreier Kandidat – exakte Palette, bitgenau verifiziert (§9.6)"
        case .ccittG4, .jbig2:
            return "kleinster bitidenter Bilevel-Kandidat"
        case .mrc:
            return "MRC-Seitenbündel (§13) – Seiten-QA bestanden, kleinste Stufe"
        }
    }

    /// Plan-Erwartung der Ersparnis (original − erwartet), 0 bei Keep.
    private static func estimatedSaved(_ action: ImageCompressionAction?) -> Int {
        guard let action, let expected = action.expectedEncodedBytes else { return 0 }
        return max(0, action.originalEncodedBytes - expected)
    }

    /// Schreibt den Trace neben den Output (`<output>.trace.json`).
    static func write(_ trace: CompressionTrace, nextTo outputURL: URL) throws {
        let target = outputURL.deletingPathExtension()
            .appendingPathExtension("trace.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(trace).write(to: target, options: [.atomic])
    }
}
