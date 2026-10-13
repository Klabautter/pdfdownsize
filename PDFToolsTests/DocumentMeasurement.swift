import Testing
import Foundation
@testable import PDFTools

/// Ein einzelnes Dokument messen – ohne Sonde im Testbaum.
///
/// WARUM ES DAS GIBT
///
/// Beim Untersuchen der Kompression sind mehrfach Wegwerf-Testdateien
/// entstanden, die den Dokumentpfad fest verdrahtet hatten. Eine davon
/// (`IPCCCheck.swift`) blieb liegen und komprimierte danach bei JEDEM
/// Regressionslauf einen 404-MB-Bericht – neun Minuten, die niemand
/// bemerkte, weil der Test ja bestand.
///
/// Der Bedarf war aber echt. Also gibt es hier EINEN Weg dafür, der nur auf
/// ausdrückliche Anforderung läuft und den Pfad von aussen bekommt:
///
///     Scripts/measure-document.sh <datei.pdf> [klein|smart|qualitaet|custom:<dpi>:<q>|smart:<dpi>[:<leiter>]]
@Suite(.serialized) struct DocumentMeasurement {

    @Test(.measurementRun) func measureSingleDocument() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PDFTOOLS_MEASURE_DOCUMENT"], !path.isEmpty else {
            print("Dokumentmessung übersprungen: nicht angefordert "
                + "(PDFTOOLS_MEASURE_DOCUMENT). Start über "
                + "Scripts/measure-document.sh.")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Dokument nicht gefunden: \(path)")
            return
        }

        let presetName = env["PDFTOOLS_MEASURE_PRESET"] ?? "smart"
        // Die Stufe muss BEIDE Seiten steuern – Plan und Ausführung. Vorher
        // plante sie mit der gewählten Stufe und komprimierte dann fest mit
        // `smart`; alle drei Stufen hätten dasselbe Ergebnis gemeldet.
        let options: ImageCompressionOptions
        let mode: CompressionMode
        // Messvarianten (Feature-Freeze: Messinstrumentierung, kein Produkt-
        // pfad): `custom:<dpi>:<q>` fährt die feste Qualität wie der Custom-
        // Reiter; `smart:<dpi>[:<q1,q2,…>]` fährt die Smart-Leiter samt Anker
        // und Gates auf einer anderen Zielauflösung bzw. Leiter.
        let parts = presetName.split(separator: ":").map(String.init)
        switch parts.first ?? "smart" {
        case "klein":     options = .small;   mode = .small
        case "qualitaet": options = .quality; mode = .quality
        case "custom" where parts.count == 3:
            let dpi = Double(parts[1]) ?? 150, q = Double(parts[2]) ?? 0.75
            options = ImageCompressionOptions(ImageEngineConfig(
                targetDPI: dpi, maxPixelEdge: 4000, jpegQuality: q,
                ssimThreshold: 0, qualityLadder: [q], tolerance: 1.15,
                aggressiveGraphics: false))
            mode = .custom
        case "smart" where parts.count >= 2:
            let dpi = Double(parts[1]) ?? 150
            let ladder = parts.count >= 3
                ? parts[2].split(separator: ",").compactMap { Double($0) }
                : [0.60, 0.75, 0.90]
            options = ImageCompressionOptions(
                targetDPI: dpi, tolerance: 1.15, maxPixelEdge: 2200, hardPixelCap: false,
                jpegQuality: ladder.max() ?? 0.9, qualityLadder: ladder, ssimThreshold: 0.90,
                forceGrayscale: false, aggressiveGraphics: false)
            mode = .smart
        default:          options = .smart;   mode = .smart
        }
        let isVariant = parts.count >= 2

        var lines: [String] = []
        lines.append("Dokument:  \(url.lastPathComponent)")
        lines.append("Stufe:     \(presetName)")
        let inputBytes = Compressor.fileSize(of: url)
        lines.append(String(format: "Eingabe:   %.1f MB", Double(inputBytes) / 1_048_576))

        // Erst planen – das sagt, WARUM etwas passiert oder nicht.
        let started = Date()
        let planned = try CompressionPipeline.plan(
            inputURL: url, options: CompressionOptions(image: options))
        let planSeconds = Date().timeIntervalSince(started)

        var jpegN = 0, lossN = 0, bilevelN = 0, cmykN = 0, keptBytes = 0
        var reasons: [String: (n: Int, bytes: Int)] = [:]
        var fromBytes = 0, toBytes = 0
        for action in planned.plan.actions {
            switch action {
            case .keep(_, let reason, let bytes):
                let key = "\(reason)"
                reasons[key, default: (0, 0)].n += 1
                reasons[key, default: (0, 0)].bytes += max(bytes, 0)
                keptBytes += max(bytes, 0)
            case .jpeg(_, _, _, _, _, let from, let to):
                jpegN += 1; fromBytes += max(from, 0); toBytes += to
            case .cmykJpegReencode(_, _, _, let from, let to):
                cmykN += 1; fromBytes += max(from, 0); toBytes += to
            case .losslessResize(_, _, _, let from, let to, _):
                lossN += 1; fromBytes += max(from, 0); toBytes += to
            case .ccittG4(_, let from, let to), .jbig2(_, let from, let to):
                bilevelN += 1; fromBytes += max(from, 0); toBytes += to
            case .indexed(_, _, _, _, _, let from, let to, _, _):
                lossN += 1; fromBytes += max(from, 0); toBytes += to
            case .mrc(_, _, let from, let to):
                lossN += 1; fromBytes += max(from, 0); toBytes += to
            }
        }
        lines.append(String(format: "Plan:      %d Aktionen in %.0f s",
                            planned.plan.actions.count, planSeconds))
        lines.append(String(format: "  JPEG %d, verlustfrei %d, Bilevel %d, CMYK-Re-Encode %d, unverändert %.1f MB",
                            jpegN, lossN, bilevelN, cmykN, Double(keptBytes) / 1_048_576))
        lines.append(String(format: "  Bilddaten %.1f MB → %.1f MB erwartet",
                            Double(fromBytes) / 1_048_576, Double(toBytes) / 1_048_576))
        if !reasons.isEmpty {
            lines.append("  Gründe fürs Unverändertlassen (nach Datenmenge):")
            for (key, v) in reasons.sorted(by: { $0.value.bytes > $1.value.bytes }).prefix(8) {
                lines.append(String(format: "    %-52@ %6d Stk %7.1f MB",
                                    key as NSString, v.n, Double(v.bytes) / 1_048_576))
            }
        }

        // Dann wirklich ausführen – der Plan ist eine Erwartung, kein Ergebnis.
        let runStarted = Date()
        do {
            let result: CompressionResult
            if isVariant {
                var variant = CompressionOptions(image: options)
                variant.featureFlags.mrc = (mode != .custom)
                result = try Compressor().compress(inputURL: url, options: variant)
            } else {
                result = try Compressor().compress(inputURL: url, mode: mode)
            }
            // Auf Wunsch das Ergebnis behalten – ohne das lässt sich nicht
            // nachsehen, WORIN es sich von einem Vergleichswerkzeug
            // unterscheidet, nur DASS es sich unterscheidet.
            if let keep = env["PDFTOOLS_MEASURE_KEEP"], !keep.isEmpty {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: keep))
                try FileManager.default.copyItem(
                    at: result.outputURL, to: URL(fileURLWithPath: keep))
                lines.append("Ausgabe:   \(keep)")
            }
            defer { try? FileManager.default.removeItem(at: result.outputURL) }
            lines.append(String(format: "Ergebnis:  %.1f MB (%.1f %% gespart) in %.0f s",
                                Double(result.outputBytes) / 1_048_576,
                                result.savedPercent,
                                Date().timeIntervalSince(runStarted)))
        } catch {
            lines.append("Ergebnis:  FEHLER – \(error)")
        }

        let text = lines.joined(separator: "\n")
        if let out = env["PDFTOOLS_MEASURE_OUTPUT"], !out.isEmpty {
            try text.write(to: URL(fileURLWithPath: out),
                           atomically: true, encoding: .utf8)
        }
        print(text)
    }
}
