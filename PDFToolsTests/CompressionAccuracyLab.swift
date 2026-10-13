import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan Schritt 7 – Accuracy Lab.
///
/// Der Plan verlangt ausdrücklich: erst MESSEN, dann Gates setzen
/// („Keine willkürliche ±10-%-Vorgabe vor Messung"). Dieses Lab erzeugt die
/// Datenbasis: je PDF die geschätzte gegen die tatsächliche Ausgabegröße,
/// aggregiert nach Dokumentklasse.
///
/// Start über `Scripts/accuracy-lab.sh`; ohne konfigurierten Korpus tut es
/// nichts (die reguläre Suite soll nicht minutenlang messen).
@Suite(.serialized) struct CompressionAccuracyLab {

    // MARK: - Dokumentklassen

    /// Klassifikation aus den ANALYSIERTEN Bildressourcen – nicht aus dem
    /// Dateinamen. Ein Report nach Klassen ist nur so viel wert wie seine
    /// Klassifikation.
    enum DocumentClass: String, CaseIterable {
        case photo
        case scan
        case screenshot
        case textOnly
        case vector
        case mixed
        case alreadyOptimized

        static func classify(resources: [PDFImageResource],
                             pageCount: Int,
                             documentBytes: Int,
                             hasText: Bool) -> DocumentClass {
            // Ohne Bilder entscheidet der Text: Ein Textdokument und eine
            // reine Vektorzeichnung verhalten sich bei der Kompression
            // verschieden – beim einen ist praktisch nichts zu holen, beim
            // anderen hängt es an den Zeichenbefehlen. Sie in einen Topf zu
            // werfen macht die Klassenaussage wertlos (Plan 7.3).
            guard !resources.isEmpty else { return hasText ? .textOnly : .vector }

            let imageBytes = resources.reduce(0) { $0 + max($1.encodedByteCount, 0) }
            let imageShare = documentBytes > 0
                ? Double(imageBytes) / Double(documentBytes) : 0

            // Ein Scan ist ein Dokument, dessen Seiten praktisch nur aus je
            // einem großen Bild bestehen und das keinen echten Text trägt.
            let fullPageImages = resources.filter { $0.maxEdge >= 1000 }.count
            if !hasText, fullPageImages >= max(pageCount - 1, 1) { return .scan }

            if imageShare < 0.10 { return .vector }

            let averageDPI = resources.compactMap(\.effectiveDPI).reduce(0, +)
                / Double(max(resources.compactMap(\.effectiveDPI).count, 1))
            // Wenig Auflösungsreserve und kleine Streams: da ist nichts zu holen.
            if averageDPI > 0, averageDPI < 150, imageShare < 0.5 {
                return .alreadyOptimized
            }

            let flateShare = Double(resources.filter { $0.terminalFilter == .flate }.count)
                / Double(resources.count)
            if flateShare > 0.6 { return .screenshot }

            if hasText, imageShare > 0.3 { return .mixed }
            return .photo
        }
    }

    // MARK: - Messung

    struct Measurement {
        let fixture: String
        /// Name der gemessenen Voreinstellung („Smart", „Custom High", …).
        let preset: String
        let documentClass: DocumentClass
        let originalBytes: Int64
        let estimatedBytes: Int64
        /// Unter- und Obergrenze des Bereichs, den die App ANZEIGT.
        ///
        /// Das ist die Zusage, die der Nutzer liest – „Bereich 4,6–10,4 MB".
        /// Der Fehler gegen den Punktwert sagt darüber nichts: Eine Schätzung
        /// kann 40 % danebenliegen und trotzdem im zugesagten Bereich bleiben,
        /// oder 30 % danebenliegen und ihn verlassen.
        let lowBytes: Int64
        let highBytes: Int64
        let actualBytes: Int64

        /// Liegt das Ergebnis ausserhalb des angezeigten Bereichs?
        var outsideDisplayedRange: Bool {
            actualBytes < lowBytes || actualBytes > highBytes
        }
        /// Und zwar nach OBEN – die Datei wurde grösser als zugesagt.
        /// Das ist die Richtung, die der Nutzer als gebrochenes Versprechen
        /// erlebt; nach unten ist er positiv überrascht.
        var aboveDisplayedRange: Bool { actualBytes > highBytes }

        /// Positiv = überschätzt (Ergebnis kleiner als vorhergesagt).
        var signedError: Int64 { estimatedBytes - actualBytes }
        var absoluteError: Int64 { abs(signedError) }
        var percentageError: Double {
            guard actualBytes > 0 else { return 0 }
            return Double(signedError) / Double(actualBytes) * 100
        }
        var absolutePercentageError: Double { abs(percentageError) }

        // MARK: Die Sicht des Nutzers

        /// Was die Anzeige verspricht, in Prozentpunkten Ersparnis.
        var promisedSaving: Double {
            guard originalBytes > 0 else { return 0 }
            return (1 - Double(estimatedBytes) / Double(originalBytes)) * 100
        }
        /// Was tatsächlich herauskommt.
        var deliveredSaving: Double {
            guard originalBytes > 0 else { return 0 }
            return (1 - Double(actualBytes) / Double(originalBytes)) * 100
        }
        /// Zuviel Versprochenes in PROZENTPUNKTEN Ersparnis.
        ///
        /// Das ist die Größe, die der Nutzer merkt: „85 % kleiner" angezeigt,
        /// 60 % geliefert – 25 Punkte zuviel versprochen. Nicht zu verwechseln
        /// mit dem prozentualen Fehler der Dateigröße; ein kleiner Fehler auf
        /// eine kleine Datei kann ein großes Versprechen brechen.
        var overpromisePoints: Double { promisedSaving - deliveredSaving }
    }

    struct Aggregate {
        let label: String
        let count: Int
        let medianAPE: Double
        let mape: Double
        let p75: Double
        let p90: Double
        let p95: Double
        let worst: Double
        let worstFixture: String

        /// Mittlerer absoluter Fehler in BYTES.
        ///
        /// Prozente allein täuschen in beide Richtungen: 50 % daneben auf
        /// 40 kB merkt niemand, 5 % auf 800 MB sind 40 MB.
        let meanAbsoluteErrorBytes: Double

        /// Mittlerer VORZEICHENBEHAFTETER Fehler in Prozent.
        ///
        /// Die eigentliche Frage aus Plan 7.4: Liegt die Schätzung
        /// systematisch daneben, und in welche Richtung? Ein Betrag von 7 %
        /// sieht harmlos aus – wenn er zu 90 % in dieselbe Richtung zeigt,
        /// ist er ein Systemfehler und keine Streuung.
        /// Negativ = die Ausgabe wurde GRÖSSER als geschätzt (zu optimistisch).
        let signedBias: Double

        /// Anteil der Fälle, in denen mehr als 20 bzw. 30 Prozentpunkte
        /// Ersparnis versprochen als geliefert wurden (Plan 7.5).
        let overpromiseOver20: Double
        let overpromiseOver30: Double

        /// Anteil der Schätzungen, die überhaupt zu optimistisch waren.
        let tooOptimisticShare: Double

        /// Anteil der Fälle, in denen das Ergebnis den ANGEZEIGTEN Bereich
        /// verlässt – und der Anteil, in dem es ihn nach oben verlässt.
        ///
        /// Das ist die Kennzahl zur tatsächlichen Zusage der Oberfläche.
        /// Alle anderen messen den Abstand zum Punktwert, den die App zwar
        /// anzeigt, aber mit einem Bereich versieht.
        let outsideRangeShare: Double
        let aboveRangeShare: Double

        init(label: String, measurements: [Measurement]) {
            self.label = label
            self.count = measurements.count
            let errors = measurements.map(\.absolutePercentageError).sorted()
            func percentile(_ p: Double) -> Double {
                guard !errors.isEmpty else { return 0 }
                let index = Int((Double(errors.count - 1) * p).rounded())
                return errors[max(0, min(errors.count - 1, index))]
            }
            self.medianAPE = percentile(0.5)
            self.mape = errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count)
            self.p75 = percentile(0.75)
            self.p90 = percentile(0.90)
            self.p95 = percentile(0.95)
            let worstMeasurement = measurements.max {
                $0.absolutePercentageError < $1.absolutePercentageError
            }
            self.worst = worstMeasurement?.absolutePercentageError ?? 0
            self.worstFixture = worstMeasurement?.fixture ?? "-"

            let n = Double(max(measurements.count, 1))
            self.meanAbsoluteErrorBytes =
                measurements.reduce(0.0) { $0 + Double($1.absoluteError) } / n
            self.signedBias =
                measurements.reduce(0.0) { $0 + $1.percentageError } / n
            self.overpromiseOver20 = Double(
                measurements.filter { $0.overpromisePoints > 20 }.count) / n * 100
            self.overpromiseOver30 = Double(
                measurements.filter { $0.overpromisePoints > 30 }.count) / n * 100
            self.tooOptimisticShare = Double(
                measurements.filter { $0.signedError < 0 }.count) / n * 100
            self.outsideRangeShare = Double(
                measurements.filter(\.outsideDisplayedRange).count) / n * 100
            self.aboveRangeShare = Double(
                measurements.filter(\.aboveDisplayedRange).count) / n * 100
        }
    }

    // MARK: - Zielwerte (Plan 7.4 / Gate 7)

    /// Was die Schätzung leisten MUSS.
    ///
    /// Die Werte sind aus der Messung abgeleitet, nicht gewünscht: Sie liegen
    /// über dem heutigen Stand, aber nah genug daran, dass eine
    /// Verschlechterung auffällt. Eine Sperre, die nie greift, ist keine.
    ///
    /// Bewusst NICHT enthalten ist ein Ziel für die Anzeige einer harten
    /// Einzelzahl. Der Report beantwortet diese Frage getrennt, und die
    /// Antwort lautet derzeit nein.
    struct Targets {
        /// Gemessen 6,8 %.
        static let medianAPE = 10.0
        /// Gemessen 16,7 %.
        static let mape = 25.0
        /// Gemessen 46,8 % – breit, aber die Schwelle hält den Stand fest.
        static let p90 = 60.0
        /// Gemessen 12,5 %.
        static let overpromiseOver30 = 15.0
        /// Gemessen −4,9 %. Der Betrag zählt: Beide Richtungen sind Fehler.
        static let absoluteBias = 10.0

        /// Bekannte Schwachstelle, als Sperrklinke festgehalten.
        ///
        /// Vektorgrafiken werden systematisch zu optimistisch geschätzt:
        /// Bias −19,6 %, und in 44,7 % der Fälle wird mehr als 20
        /// Prozentpunkte Ersparnis versprochen als geliefert. Das ist der
        /// schlechteste Wert aller Klassen und der eigentliche Grund, warum
        /// eine harte Einzelzahl in der Anzeige derzeit nicht zu
        /// verantworten ist.
        ///
        /// Die Schwelle steht auf dem heutigen Stand. Sie erlaubt keine
        /// Verschlechterung und behauptet nicht, das Problem sei gelöst.
        static let vectorOverpromiseOver20 = 45.0
    }

    // MARK: - Lauf

    @Test(.measurementRun) func measureEstimatorAccuracy() throws {
        // Dieses Labor fährt den gesamten Korpus durch fünf Voreinstellungen.
        // Es gehört zu `Scripts/accuracy-lab.sh`, nicht in jeden
        // Regressionslauf – dort kostete es zuletzt 74 Sekunden, und mit den
        // Custom-Voreinstellungen wäre es ein Vielfaches.
        //
        // Der Wächter fragt ausdrücklich nach der Anforderung. Auf das blosse
        // Vorhandensein des Korpusverzeichnisses zu prüfen war schon beim
        // Korpus-Runner falsch: Seit der Pfad fest eingetragen ist, ist es
        // immer da.
        guard ProcessInfo.processInfo.environment["PDFTOOLS_ACCURACY_LAB"] == "1"
        else {
            print("Accuracy Lab übersprungen: nicht angefordert "
                + "(PDFTOOLS_ACCURACY_LAB). Start über Scripts/accuracy-lab.sh.")
            return
        }

        let config = CorpusRunnerCore.Config.fromEnvironment()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: config.corpusRoot.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else {
            Issue.record(Comment(rawValue:
                "Accuracy Lab angefordert, aber Korpus fehlt unter "
                + config.corpusRoot.path))
            return
        }

        let fixtures = CorpusRunnerCore.fixtures(for: config.suite, config: config)
        try #require(!fixtures.isEmpty, "Keine Fixtures unter \(config.corpusRoot.path)")

        // Smart UND jede benannte Custom-Voreinstellung getrennt (Plan 7.2).
        // Ein Gesamtwert über alle Voreinstellungen sagt nichts: Aggressive
        // schätzt anders daneben als High, und die Anzeige gilt jeweils für
        // genau eine davon.
        var presets: [(name: String, options: CompressionOptions)] =
            [("Smart", CompressionOptions.smart)]
        presets += CompressionPresetFactory.CustomPreset.allCases.map {
            ($0.rawValue, $0.options)
        }

        var measurements: [Measurement] = []

        // Lebenszeichen. Der Lauf dauert über zwanzig Minuten und meldete
        // bisher nichts, bis er fertig war – bricht er vorher ab, weiss
        // niemand, wo. Der Korpus-Runner führt aus demselben Grund ein
        // Live-Protokoll.
        let progressURL = config.corpusRoot
            .appendingPathComponent("Results", isDirectory: true)
            .appendingPathComponent("accuracy-lab-progress.log")
        try? FileManager.default.createDirectory(
            at: progressURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? "Accuracy Lab gestartet: \(Date())\n\(fixtures.count) Dokumente × "
            .appending("\(presets.count) Voreinstellungen\n")
            .write(to: progressURL, atomically: true, encoding: .utf8)
        var done = 0
        let total = fixtures.count * presets.count

        func note(_ line: String) {
            guard let handle = try? FileHandle(forWritingTo: progressURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.appending("\n").utf8))
        }

        for (presetName, options) in presets {
        note("── \(presetName) ──")
        for fixture in fixtures {
            done += 1
            if done % 25 == 0 {
                note("  \(done)/\(total) – zuletzt: \(fixture.lastPathComponent)")
            }
            let relativePath = fixture.path
                .replacingOccurrences(of: config.corpusRoot.path + "/", with: "")
            guard let document = try? PDFCoreDocument(path: fixture.path),
                  let resources = try? document.imageResources() else { continue }

            let originalBytes = Compressor.fileSize(of: fixture)
            let hasText = (PDFDocument(url: fixture)?.string?.count ?? 0) > 200
            let documentClass = DocumentClass.classify(
                resources: resources,
                pageCount: document.pageCount,
                documentBytes: Int(originalBytes),
                hasText: hasText)

            guard let estimate = CompressionEstimator.estimate(url: fixture,
                                                               options: options)
            else { continue }

            // Die tatsächliche Größe kommt aus dem echten Produktionspfad –
            // inklusive Struktur-Pass und „nie größer als das Original".
            guard let result = try? Compressor().compress(inputURL: fixture,
                                                          options: options)
            else { continue }
            defer { try? FileManager.default.removeItem(at: result.outputURL) }

            measurements.append(Measurement(
                fixture: relativePath,
                preset: presetName,
                documentClass: documentClass,
                originalBytes: originalBytes,
                estimatedBytes: estimate.pointBytes,
                lowBytes: estimate.lowBytes,
                highBytes: estimate.highBytes,
                actualBytes: result.outputBytes))
        }
        }

        try #require(!measurements.isEmpty, "Keine Messungen zustande gekommen")

        // Report schreiben – die Zahlen sollen NICHT von Hand abgeschrieben
        // werden (Masterplan Finding 19 / Kapitel 10).
        let report = Self.renderReport(measurements: measurements,
                                       corpusRoot: config.corpusRoot.path)
        let destination = config.corpusRoot
            .appendingPathComponent("Results", isDirectory: true)
            .appendingPathComponent("COMPRESSION_ACCURACY_LAB.md")
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try report.write(to: destination, atomically: true, encoding: .utf8)

        let overall = Aggregate(label: "Gesamt", measurements: measurements)
        print("""
        ━━ Compression Accuracy Lab ━━
        Messungen: \(overall.count)
        Median APE: \(String(format: "%.1f", overall.medianAPE)) %
        MAPE:       \(String(format: "%.1f", overall.mape)) %
        P90:        \(String(format: "%.1f", overall.p90)) %
        P95:        \(String(format: "%.1f", overall.p95)) %
        Worst:      \(String(format: "%.1f", overall.worst)) % (\(overall.worstFixture))
        Report:     \(destination.path)
        """)

        // Die Zielwerte, aus der Messung abgeleitet und hier verankert.
        func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
        #expect(overall.medianAPE <= Targets.medianAPE, """
            Median APE \(fmt(overall.medianAPE)) % über dem Ziel \
            \(fmt(Targets.medianAPE)) %
            """)
        #expect(overall.mape <= Targets.mape,
                "MAPE \(fmt(overall.mape)) % über dem Ziel \(fmt(Targets.mape)) %")
        #expect(overall.p90 <= Targets.p90,
                "P90 \(fmt(overall.p90)) % über dem Ziel \(fmt(Targets.p90)) %")
        #expect(overall.overpromiseOver30 <= Targets.overpromiseOver30, """
            In \(fmt(overall.overpromiseOver30)) % der Fälle werden mehr als 30 \
            Prozentpunkte Ersparnis zuviel versprochen (Ziel \
            \(fmt(Targets.overpromiseOver30)) %).
            """)
        #expect(abs(overall.signedBias) <= Targets.absoluteBias, """
            Systematische Schieflage \(fmt(overall.signedBias)) % über dem Ziel \
            ±\(fmt(Targets.absoluteBias)) %.
            """)

        // Die bekannte Schwachstelle als Sperrklinke: Sie darf nicht
        // schlechter werden, und sie bleibt sichtbar.
        let vector = measurements.filter { $0.documentClass == .vector }
        if !vector.isEmpty {
            let v = Aggregate(label: "vector", measurements: vector)
            #expect(v.overpromiseOver20 <= Targets.vectorOverpromiseOver20, """
                Vektorgrafiken: \(fmt(v.overpromiseOver20)) % der Schätzungen \
                versprechen mehr als 20 Prozentpunkte zuviel (Sperrklinke \
                \(fmt(Targets.vectorOverpromiseOver20)) %). Das ist die \
                schlechteste Klasse und der Grund, warum die Anzeige derzeit \
                keine harte Einzelzahl verantworten kann.
                """)
        }
    }

    // MARK: - Report

    static func renderReport(measurements: [Measurement],
                             corpusRoot: String) -> String {
        var lines: [String] = []
        lines.append("# Compression Accuracy Lab")
        lines.append("")
        lines.append("Automatisch erzeugt von `CompressionAccuracyLab`. "
            + "Nicht von Hand bearbeiten.")
        lines.append("")
        lines.append("- Korpus: `\(corpusRoot)`")
        lines.append("- Messungen: \(measurements.count)")
        lines.append("- Erzeugt: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        func percent(_ value: Double) -> String { String(format: "%.1f %%", value) }
        func signed(_ value: Double) -> String { String(format: "%+.1f %%", value) }
        func bytes(_ value: Double) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
        }

        func table(_ header: String, _ aggregates: [Aggregate]) -> [String] {
            var out = ["| \(header) | n | Median APE | MAPE | P75 | P90 | P95 "
                + "| MAE | Bias | zu optimistisch | >20 Pkt | >30 Pkt "
                + "| ausserhalb Bereich | davon zu gross |"]
            out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
            for a in aggregates {
                out.append("| \(a.label) | \(a.count) | \(percent(a.medianAPE)) | "
                    + "\(percent(a.mape)) | \(percent(a.p75)) | \(percent(a.p90)) | "
                    + "\(percent(a.p95)) | \(bytes(a.meanAbsoluteErrorBytes)) | "
                    + "\(signed(a.signedBias)) | \(percent(a.tooOptimisticShare)) | "
                    + "\(percent(a.overpromiseOver20)) | \(percent(a.overpromiseOver30)) | "
                    + "\(percent(a.outsideRangeShare)) | \(percent(a.aboveRangeShare)) |")
            }
            return out
        }

        lines.append("## Lesehilfe")
        lines.append("")
        lines.append("- **Median APE / MAPE / P75 / P90 / P95**: Betrag des "
            + "Fehlers auf die geschätzte Dateigröße.")
        lines.append("- **MAE**: derselbe Fehler in Bytes. Prozente täuschen in "
            + "beide Richtungen – 50 % auf 40 kB merkt niemand, 5 % auf 800 MB "
            + "sind 40 MB.")
        lines.append("- **Bias**: mittlerer Fehler MIT Vorzeichen. Negativ heisst: "
            + "die Ausgabe wird im Schnitt grösser als geschätzt, die Anzeige "
            + "verspricht also systematisch zu viel.")
        lines.append("- **zu optimistisch**: Anteil der Fälle, in denen die "
            + "Ausgabe grösser ausfiel als geschätzt.")
        lines.append("- **ausserhalb Bereich**: Anteil der Fälle, in denen das "
            + "Ergebnis den ANGEZEIGTEN Bereich verlässt – „Bereich 4,6–10,4 MB\u{201C} "
            + "ist die Zusage, die der Nutzer liest. **davon zu gross**: der Teil "
            + "davon, bei dem die Datei grösser wurde als zugesagt; nach unten ist "
            + "der Nutzer positiv überrascht.")
        lines.append("- **>20 Pkt / >30 Pkt**: Anteil der Fälle, in denen mehr "
            + "Ersparnis versprochen als geliefert wurde – gemessen in "
            + "PROZENTPUNKTEN Ersparnis, also so, wie der Nutzer es merkt "
            + "(„85 % kleiner" + "\u{201C}" + " angezeigt, 60 % geliefert = 25 Punkte).")
        lines.append("")

        lines.append("## Nach Voreinstellung")
        lines.append("")
        lines.append("Getrennt, weil die Anzeige immer für genau EINE "
            + "Voreinstellung gilt. Ein Mittelwert darüber sagt niemandem etwas.")
        lines.append("")
        var presetAggregates = [Aggregate(label: "Gesamt", measurements: measurements)]
        for preset in Self.presetOrder(in: measurements) {
            let subset = measurements.filter { $0.preset == preset }
            guard !subset.isEmpty else { continue }
            presetAggregates.append(Aggregate(label: preset, measurements: subset))
        }
        lines += table("Voreinstellung", presetAggregates)
        lines.append("")

        lines.append("## Nach Dokumentklasse")
        lines.append("")
        var classAggregates: [Aggregate] = []
        for documentClass in DocumentClass.allCases {
            let subset = measurements.filter { $0.documentClass == documentClass }
            guard !subset.isEmpty else { continue }
            classAggregates.append(Aggregate(label: documentClass.rawValue,
                                             measurements: subset))
        }
        lines += table("Klasse", classAggregates)
        lines.append("")

        lines.append("## Voreinstellung × Klasse")
        lines.append("")
        lines.append("Erst hier wird sichtbar, ob ein Fehler an der "
            + "Voreinstellung oder am Dokumenttyp hängt – die Voraussetzung "
            + "für eine Korrektur, die keine pauschale ist.")
        lines.append("")
        var crossAggregates: [Aggregate] = []
        for preset in Self.presetOrder(in: measurements) {
            for documentClass in DocumentClass.allCases {
                let subset = measurements.filter {
                    $0.preset == preset && $0.documentClass == documentClass
                }
                guard subset.count >= 3 else { continue }
                crossAggregates.append(Aggregate(
                    label: "\(preset) / \(documentClass.rawValue)",
                    measurements: subset))
            }
        }
        lines += table("Voreinstellung / Klasse", crossAggregates)
        lines.append("")

        lines.append("## Zielwerte")
        lines.append("")
        lines.append("Aus der Messung abgeleitet und in `CompressionAccuracyLab.Targets` "
            + "verankert. Sie liegen über dem heutigen Stand, aber nah genug daran, "
            + "dass eine Verschlechterung auffällt.")
        lines.append("")
        lines.append("| Kennzahl | Ziel | gemessen | |")
        lines.append("|---|---:|---:|---|")
        func check(_ name: String, _ target: Double, _ value: Double,
                   suffix: String = " %") -> String {
            let ok = abs(value) <= target
            return "| \(name) | \(String(format: "%.1f", target))\(suffix) | "
                + "\(String(format: "%.1f", value))\(suffix) | "
                + (ok ? "erfüllt" : "**verfehlt**") + " |"
        }
        let overallForTargets = Aggregate(label: "Gesamt", measurements: measurements)
        lines.append(check("Median APE", Targets.medianAPE, overallForTargets.medianAPE))
        lines.append(check("MAPE", Targets.mape, overallForTargets.mape))
        lines.append(check("P90", Targets.p90, overallForTargets.p90))
        lines.append(check(">30 Punkte zuviel versprochen",
                           Targets.overpromiseOver30, overallForTargets.overpromiseOver30))
        lines.append(check("Betrag der Schieflage", Targets.absoluteBias,
                           overallForTargets.signedBias))
        let vectorSubset = measurements.filter { $0.documentClass == .vector }
        if !vectorSubset.isEmpty {
            let v = Aggregate(label: "vector", measurements: vectorSubset)
            lines.append(check("vector: >20 Punkte (Sperrklinke)",
                               Targets.vectorOverpromiseOver20, v.overpromiseOver20))
        }
        lines.append("")
        lines.append("Die Sperrklinke für `vector` steht auf dem heutigen Stand. "
            + "Sie erlaubt keine Verschlechterung und behauptet nicht, das "
            + "Problem sei gelöst: Vektorgrafiken werden systematisch zu "
            + "optimistisch geschätzt, und das ist der schwerste offene Punkt "
            + "der Schätzung.")
        lines.append("")

        lines.append("## Ist eine harte Einzelzahl verantwortbar?")
        lines.append("")
        let overall = Aggregate(label: "Gesamt", measurements: measurements)
        lines.append("Diese Frage stellt Plan 7.8, und der Report soll sie "
            + "beantworten statt sie offenzulassen.")
        lines.append("")
        lines.append("| Kriterium | Wert | Beurteilung |")
        lines.append("|---|---:|---|")
        lines.append("| P90 des Fehlers | \(percent(overall.p90)) | "
            + (overall.p90 <= 15 ? "trägt eine Einzelzahl"
                                 : "zu breit für eine Einzelzahl") + " |")
        lines.append("| Anteil >20 Punkte zuviel versprochen | "
            + "\(percent(overall.overpromiseOver20)) | "
            + (overall.overpromiseOver20 <= 5 ? "vertretbar"
                                              : "der Nutzer wird regelmässig enttäuscht") + " |")
        lines.append("| Systematischer Bias | \(signed(overall.signedBias)) | "
            + (abs(overall.signedBias) <= 5 ? "keine Schieflage"
                                            : "systematisch, korrekturwürdig") + " |")
        lines.append("| Ergebnis ausserhalb des angezeigten Bereichs | "
            + "\(percent(overall.outsideRangeShare)) | "
            + (overall.outsideRangeShare <= 10 ? "der Bereich trägt"
                                               : "der angezeigte Bereich hält nicht, was er zusagt") + " |")
        lines.append("| davon: Datei grösser als zugesagt | "
            + "\(percent(overall.aboveRangeShare)) | "
            + (overall.aboveRangeShare <= 5 ? "selten"
                                            : "der Nutzer erlebt ein gebrochenes Versprechen") + " |")
        lines.append("")
        lines.append("Die Oberfläche zeigt heute BEIDES: einen Punktwert und "
            + "darunter den Bereich. Die Frage nach der „harten Einzelzahl\u{201C} ist "
            + "damit halb beantwortet – entscheidend ist, ob der Bereich hält.")
        lines.append("")
        lines.append("### Was daraus folgen würde – nicht umgesetzt")
        lines.append("")
        lines.append("Dieser Report SAMMELT und DOKUMENTIERT; er ändert nichts am "
            + "Verhalten. Zwei Eingriffe legen die Daten nahe:")
        lines.append("")
        lines.append("1. **Bandfaktoren nachziehen.** Die Grenzen 0,55× und 1,25× "
            + "stammen aus 63 Messungen eines frühen Laufs. Inzwischen liegen "
            + "\(measurements.count) vor. Ob die Grenzen passen, sagt die Spalte "
            + "„ausserhalb Bereich\u{201C}.")
        lines.append("2. **Klassenbezogene Korrektur.** Der Gesamt-Bias verdeckt zwei "
            + "gegenläufige Systemfehler: Vektorgrafiken und Screenshots werden zu "
            + "optimistisch geschätzt, Scans und bereits optimierte Dokumente zu "
            + "pessimistisch. Ein pauschaler Faktor wäre deshalb nachweislich falsch. "
            + "Eine Korrektur je Klasse setzt voraus, dass die Klassifikation aus "
            + "diesem Labor in den Produktionscode wandert – ein Eingriff in den "
            + "Schätzer, keine Messung.")
        lines.append("")

        lines.append("## Die zwanzig schlechtesten Einzelmessungen")
        lines.append("")
        lines.append("| Fixture | Voreinstellung | Klasse | Original | Geschätzt "
            + "| Tatsächlich | Fehler | zuviel versprochen |")
        lines.append("|---|---|---|---:|---:|---:|---:|---:|")
        for m in measurements.sorted(by: {
            $0.overpromisePoints > $1.overpromisePoints
        }).prefix(20) {
            lines.append("| `\(m.fixture)` | \(m.preset) | "
                + "\(m.documentClass.rawValue) | \(m.originalBytes) | "
                + "\(m.estimatedBytes) | \(m.actualBytes) | "
                + signed(m.percentageError) + " | "
                + String(format: "%+.1f Pkt", m.overpromisePoints) + " |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Voreinstellungen in stabiler Reihenfolge – Smart zuerst, dann die
    /// benannten Custom-Stufen in ihrer Aufzählungsreihenfolge.
    static func presetOrder(in measurements: [Measurement]) -> [String] {
        var order = ["Smart"]
        order += CompressionPresetFactory.CustomPreset.allCases.map(\.rawValue)
        let present = Set(measurements.map(\.preset))
        return order.filter { present.contains($0) }
    }}
