import Foundation
import PDFKit

/// Zentrale PDF-Validierung (Epic Phase 3).
/// Workflow-spezifische Policies statt universeller Annahmen:
/// eine Kompression muss alles erhalten, ein Merge nur plausible Struktur.
enum PDFValidator {

    // MARK: Policies

    struct Policy {
        var expectedPageCount: Int?
        var requiresOpenable = true
        var plausibleGeometry = true
        var plausibleRotations = true
        /// Text muss erhalten bleiben, wenn die Referenz Text enthält.
        var preservesText = false
        var textSimilarityThreshold: Double = 0.95
        /// Anzahl Annotationen darf nicht sinken.
        var preservesAnnotations = false
        /// Anzahl Link-Annotationen darf nicht sinken.
        var preservesLinks = false
        /// Widget-Annotationen (Formularfelder) dürfen nicht sinken.
        var preservesForms = false
        /// Signatur-Marker im Output melden (Warnung, kein Fail – Originale bleiben unangetastet).
        var reportsSignatures = true

        // MARK: Masterplan Schritt 8 – erweiterte Pflichtprüfungen

        /// Strukturprüfung über libqpdf (entspricht `qpdf --check`).
        var runsStructureCheck = false
        /// Vollständiger semantischer Vergleich gegen die Referenz.
        /// Abweichungen ab dieser Schwere lassen die Validierung scheitern.
        var failsOnSemanticSeverity: PDFSemanticSnapshot.Severity?

        /// Abweichungen, die für diese Operation zur Aufgabe gehören.
        ///
        /// Hier steht Produktpolitik – ausdrücklich und begründet. Wer Seiten
        /// auswählt, verliert Outline-Einträge; das ist gewollt. Der
        /// Unterschied zu vorher: Solche Fälle werden ANGEMELDET, nicht durch
        /// eine milde Einstufung verdeckt. Sie erscheinen weiter im Bericht,
        /// erkennbar als `[erwartet]`.
        ///
        /// Was NICHT hierher gehört: Verluste, die man gerade nicht beheben
        /// kann. Dafür gibt es einen Fehlschlag.
        var expectedDifferences: Set<PDFSemanticSnapshot.Kind> = []
        /// Geometrie (MediaBox/CropBox/Rotation) muss exakt der Referenz
        /// entsprechen – für Operationen, die nichts an Seiten ändern dürfen.
        var preservesGeometry = false

        /// Pfad der Quelldatei – nötig, um zu erkennen, welche Verweise dort
        /// überhaupt auflösbar waren.
        ///
        /// Ohne diese Unterscheidung zählt die Erhaltungsprüfung nur Links und
        /// meldet jeden Wegfall als Verlust – auch das Aufräumen toter
        /// Verweise. An `2608.23540v1.pdf` ergab das „671 → 0 Links": Das
        /// Dokument trägt ein defektes Zielverzeichnis (doppelte Schlüssel,
        /// von qpdf als null behandelt), ALLE 671 Verweise zeigen schon im
        /// Original ins Leere, und ihr Entfernen ist richtig.
        var sourceURL: URL?

        /// Ausgabeseite → Quellseite. Gesetzt bei Operationen, die Seiten
        /// auswählen oder umordnen.
        ///
        /// Ohne sie vergleicht die Erhaltungsprüfung DOKUMENTWEITE Summen –
        /// und bei einer Teilmenge sinkt jede Summe zwangsläufig, ohne dass
        /// etwas verloren ginge. Mit ihr wird pro Seitenpaar geprüft: Behält
        /// die übernommene Seite, was sie in der Quelle hatte? Das ist die
        /// Frage, die zählt.
        ///
        /// Dieselbe Lehre wie beim Render-Vergleich (Befund 1) und der
        /// Differenzmatrix (Befund 12): Ein Vergleich ohne Seitenzuordnung
        /// misst etwas anderes, als er zu messen vorgibt.
        var pageMapping: [Int: Int]?

        /// Masterplan A3: Seiten (0-basiert), die gegen das Original gerendert
        /// werden. Gesetzt von der Kompression aus ihrem Plan
        /// (`renderSamplePages(pageCount:changedBytesByPage:)`); nil = keine
        /// Render-Stichprobe.
        var renderSamplePages: [Int]?

        /// Masterplan N4: Der Lauf rechnet absichtlich nach Graustufen
        /// („Eigene" mit Graustufen). Die Stichprobe prüft dann nur die
        /// Struktur – fehlende Farbe ist gewollt, kein Verlust.
        var renderSampleExpectsGrayscale = false

        /// Verlustfreie Strukturoptimierung desselben Dokuments: alles muss
        /// bleiben. Masterplan Schritt 8 verlangt hier die volle Liste:
        /// qpdf-check, Seitenzahl, Geometrie, Text, Annotationen, Links,
        /// Named Destinations, Outlines, Page Labels, Formulare, Attachments.
        /// Kompression ändert Bilddaten – sonst nichts.
        ///
        /// Deshalb steht hier `expectedDifferences: []`, und das ist eine
        /// Aussage, keine Auslassung: Es gibt keine Struktur, deren Verlust
        /// bei Kompression hinnehmbar wäre. Verliert eine Ausgabe Lesezeichen,
        /// Sprungziele, Seitenbezeichnungen, Formularfelder, Anhänge oder
        /// Annotationen, ist sie mangelhaft und erreicht den Nutzer nicht.
        ///
        /// Die Signatur-GÜLTIGKEIT ist davon ausgenommen – sie überlebt kein
        /// Neuschreiben der Streams. Darauf weist `reportsSignatures` als
        /// Warnung hin; das Signaturfeld selbst muss erhalten bleiben.
        static let compression = Policy(preservesText: true,
                                        preservesAnnotations: true,
                                        preservesLinks: true,
                                        preservesForms: true,
                                        runsStructureCheck: true,
                                        failsOnSemanticSeverity: .high,
                                        expectedDifferences: [],
                                        preservesGeometry: true)

        /// Seiten-Assembly (Merge/Extract/Split).
        ///
        /// Diese Politik war leer – `Policy()` – mit der Begründung,
        /// Dokument-Level-Strukturen gingen „mit PDFKit-Kopien bewusst
        /// verloren". Damit war ALLES ungeprüft, auch was erhalten bleiben
        /// kann: Text, Annotationen, Links, Formularfelder. Eine
        /// Einschränkung des Legacy-Backends war zur allgemeinen Politik
        /// erhoben worden.
        ///
        /// Was das kostete, zeigte sich an einem CVPR-Paper: 187
        /// Link-Annotationen wurden zu 2, und der Korpuslauf meldete PASS
        /// (Befund 13).
        ///
        /// Was hier NICHT geprüft wird, hat einen sachlichen Grund: Outlines
        /// und Page Labels beziehen sich auf das Gesamtdokument. Bei einer
        /// Teilmenge von Seiten dürfen sie schrumpfen – das ist kein Verlust,
        /// sondern die Operation. Der Seitenzahlabgleich steht ohnehin schon
        /// im Runner.
        static let assembly = Policy(preservesText: true,
                                     preservesAnnotations: true,
                                     preservesLinks: true,
                                     preservesForms: true,
                                     runsStructureCheck: true)

        /// Seitenoperationen ohne Referenzvergleich der Semantik, aber mit
        /// verpflichtender Strukturprüfung.
        static func pageOperation(expectedPageCount: Int?) -> Policy {
            Policy(expectedPageCount: expectedPageCount, runsStructureCheck: true)
        }

        /// OCR legt eine unsichtbare Textebene ins Original. Text DARF
        /// dazukommen; Annotationen, Links, Formularfelder und Geometrie
        /// müssen gegen die Quelle erhalten bleiben – das verspricht die
        /// Oberfläche („Aussehen, Links, Formulare und Lesezeichen bleiben
        /// erhalten"), und vorher prüfte die Laufzeit davon nichts (Befund
        /// A3, Review 2026-10-09).
        static func ocr(expectedPageCount: Int?, sourceURL: URL?) -> Policy {
            Policy(expectedPageCount: expectedPageCount,
                   preservesAnnotations: true,
                   preservesLinks: true,
                   preservesForms: true,
                   runsStructureCheck: true,
                   preservesGeometry: true,
                   sourceURL: sourceURL)
        }

        /// Rotation ändert die Rotation – aber sonst nichts.
        static func rotate(expectedPageCount: Int?) -> Policy {
            Policy(expectedPageCount: expectedPageCount,
                   preservesText: true,
                   preservesAnnotations: true,
                   runsStructureCheck: true)
        }

        /// Bilder → PDF: keine Referenz, aber valide Struktur und Geometrie.
        static func imagesToPDF(expectedPageCount: Int?) -> Policy {
            Policy(expectedPageCount: expectedPageCount, runsStructureCheck: true)
        }
    }

    // MARK: Report

    struct Report {
        /// Masterplan D5: Ein Apple-Framework (Textextraktion, Zeichnen) lief
        /// ins Zeitlimit. Ein anderer Bildplan ändert daran nichts – die
        /// Rückfallkette endet sofort.
        var frameworkTimedOut = false
        var failures: [String] = []
        var warnings: [String] = []
        var signatureDetected = false

        /// V2-5 (§11.2) – dieselben Befunde maschinenlesbar, ADDITIV zu den
        /// Strings: Die String-Listen bleiben unverändert sichtbar, die
        /// QA-Rollback-Kette (§11.5) wertet ausschließlich die Findings aus.
        var findings: [ValidationFinding] = []

        var isValid: Bool { failures.isEmpty }

        /// Findings, die einen Re-Plan auslösen dürfen (§11.5: nur Failures,
        /// niemals info/warning).
        var blockingFindings: [ValidationFinding] {
            findings.filter { $0.severity.triggersRollback }
        }

        /// Meldung + zugehöriges Finding; ohne Finding bleibt es bei der
        /// Meldung (dann ist der Text die einzige Auswertungsbasis).
        mutating func fail(_ message: String, _ finding: ValidationFinding? = nil) {
            failures.append(message)
            if let finding { findings.append(finding) }
        }

        mutating func warn(_ message: String, _ finding: ValidationFinding? = nil) {
            warnings.append(message)
            if let finding { findings.append(finding) }
        }
    }

    enum ValidationError: LocalizedError {
        case invalid([String])

        var errorDescription: String? {
            switch self {
            case .invalid(let failures):
                return "Validierung fehlgeschlagen: " + failures.joined(separator: "; ")
            }
        }
    }

    // MARK: API

    /// Masterplan C6: dieselbe Prüfung abseits des Main Actors. OCR und
    /// „PDF erstellen“ prüften bisher in `Task { @MainActor }` – bei einem
    /// 1000-Seiten-Dokument stand die Oberfläche dabei.
    static func validateOffMain(outputURL: URL, referenceURL: URL? = nil,
                                policy: Policy) async -> Report {
        await Task.detached(priority: .userInitiated) {
            validate(outputURL: outputURL, referenceURL: referenceURL, policy: policy)
        }.value
    }

    /// Validiert `output` gegen die Policy. Die Referenz kann als URL oder als
    /// bereits geladenes Dokument übergeben werden (z. B. Originaldaten aus dem RAM).
    @discardableResult
    static func validate(outputURL: URL,
                         referenceURL: URL? = nil,
                         referenceDocument: PDFDocument? = nil,
                         referenceSnapshot: PDFSemanticSnapshot? = nil,
                         policy: Policy) -> Report {
        // Die Validierung öffnet Dokumente, liest jede Seite und erzeugt bei
        // Bedarf zwei vollständige Snapshots. Alles davon ist autoreleased;
        // ohne eigenen Pool blieb je Aufruf rund 15 MB liegen. Der Report
        // besteht nur aus Strings und übersteht das Leeren des Pools.
        autoreleasepool {
        let fm = FileManager.default

        var report = Report()

        guard fm.fileExists(atPath: outputURL.path) else {
            report.fail("Ausgabedatei existiert nicht", ValidationFinding(
                kind: .structure, severity: .fatal, pages: [],
                message: "Ausgabedatei existiert nicht"))
            return report
        }
        let size = Compressor.fileSize(of: outputURL)
        guard size > 0 else {
            report.fail("Ausgabedatei ist leer", ValidationFinding(
                kind: .structure, severity: .fatal, pages: [],
                message: "Ausgabedatei ist leer"))
            return report
        }

        guard let outDoc = PDFDocument(url: outputURL), !outDoc.isLocked else {
            report.fail("Ausgabe kann nicht geöffnet werden", ValidationFinding(
                kind: .structure, severity: .fatal, pages: [],
                message: "Ausgabe kann nicht geöffnet werden"))
            return report
        }

        let refDoc: PDFDocument?
        if let referenceDocument {
            refDoc = referenceDocument
        } else {
            refDoc = referenceURL.flatMap { PDFDocument(url: $0) }
        }

        // Masterplan C2: Die Snapshots entstehen VOR der Strukturprüfung –
        // deren Textvergleich liest dann die Zeichenzahlen aus ihnen, statt
        // den Text aller Seiten ein drittes und viertes Mal zu extrahieren.
        // Die Referenz kommt, wenn vorhanden, vom Aufrufer (einmal je Lauf,
        // auch über Re-Plans hinweg).
        var snapshots: (before: PDFSemanticSnapshot, after: PDFSemanticSnapshot)?
        var snapshotError: Error?
        if policy.failsOnSemanticSeverity != nil, let referenceURL {
            do {
                let before = try referenceSnapshot ?? PDFSemanticSnapshot.capture(referenceURL)
                let after = try PDFSemanticSnapshot.capture(outputURL)
                snapshots = (before, after)
            } catch {
                snapshotError = error
            }
        }
        // Masterplan D5: Lief die Textextraktion ins Zeitlimit, darf keine
        // zweite, ungeschützte Extraktion folgen (sie hinge genauso). Die
        // Prüfung gilt als nicht bestanden – das Original bleibt.
        if let timeout = snapshotError as? PDFSemanticSnapshot.SnapshotError {
            report.frameworkTimedOut = true
            let message = timeout.localizedDescription
            report.fail(message, ValidationFinding(kind: .text, severity: .error, pages: [], message: message))
            return report
        }

        validateStructure(outDoc,
                          expectedPageCount: policy.expectedPageCount,
                          reference: refDoc,
                          policy: policy,
                          textCounts: snapshots.map {
                              ($0.before.pages.reduce(0) { $0 + $1.textCharacterCount },
                               $0.after.pages.reduce(0) { $0 + $1.textCharacterCount },
                               $0.before.pages.reduce(0) { $0 + $1.wordCount })
                          },
                          report: &report)

        // Masterplan Schritt 8 – unabhängige Strukturprüfung über libqpdf.
        // PDFKit öffnet auch Dokumente, die strukturell beschädigt sind.
        if policy.runsStructureCheck {
            do {
                let core = try PDFCoreDocument(path: outputURL.path)
                try core.check()
            } catch {
                report.fail("Strukturprüfung (qpdf) fehlgeschlagen: "
                    + "\(error.localizedDescription)", ValidationFinding(
                    kind: .structure, severity: .error, pages: [],
                    message: "Strukturprüfung (qpdf) fehlgeschlagen: "
                        + "\(error.localizedDescription)"))
            }
        }

        // Vollständiger semantischer Vergleich gegen die Referenz.
        //
        // Verlangt die Policy diesen Vergleich, muss er auch stattfinden.
        // Fehlt die Referenzdatei, wird das GEMELDET statt still übersprungen –
        // sonst behauptet eine Policy eine Prüfung, die nie läuft.
        if let threshold = policy.failsOnSemanticSeverity, referenceURL == nil {
            report.warnings.append("Semantikvergleich übersprungen: keine "
                + "Referenzdatei übergeben (Policy verlangt Schwelle "
                + "\(threshold.rawValue))")
        }
        if let threshold = policy.failsOnSemanticSeverity,
           referenceURL != nil {
            do {
                if let snapshotError { throw snapshotError }
                guard let (before, after) = snapshots else { throw CocoaError(.fileReadUnknown) }
                for difference in PDFSemanticSnapshot.differences(
                        before, after, expecting: policy.expectedDifferences) {
                    // V2-5 (§11.2) – jede Abweichung wird zusätzlich als
                    // maschinenlesbares Finding geführt; die Schwelle der
                    // Policy entscheidet wie bisher über Fail oder Warn.
                    let finding = ValidationFinding(
                        kind: Self.findingKind(of: difference.kind),
                        severity: Self.findingSeverity(of: difference.severity),
                        pages: difference.pages,
                        message: difference.message)
                    if difference.severity <= threshold {
                        report.fail(difference.message, finding)
                    } else {
                        report.warn(difference.message, finding)
                    }
                }
            } catch {
                report.fail("Semantikvergleich nicht möglich: "
                    + "\(error.localizedDescription)", ValidationFinding(
                    kind: .structure, severity: .error, pages: [],
                    message: "Semantikvergleich nicht möglich: "
                        + "\(error.localizedDescription)"))
            }
        }

        if policy.preservesGeometry, let refDoc {
            validateGeometry(outDoc, reference: refDoc, report: &report)
        }

        if let pages = policy.renderSamplePages, !pages.isEmpty {
            if let referenceURL {
                validateRenderSample(outputURL: outputURL, referenceURL: referenceURL,
                                     pages: pages,
                                     expectsGrayscale: policy.renderSampleExpectsGrayscale,
                                     report: &report)
            } else {
                report.warnings.append("Render-Stichprobe übersprungen: keine Referenzdatei")
            }
        }

        if policy.reportsSignatures,
           Compressor.containsDigitalSignature(at: outputURL) {
            report.signatureDetected = true
            report.warn("Digitale Signatur im Output erkannt", ValidationFinding(
                kind: .structure, severity: .info, pages: [],
                message: "Digitale Signatur im Output erkannt"))
        }

        return report
        }
    }

    // MARK: Render-Stichprobe (Masterplan A3)

    /// Höchstens so viele Seiten werden gerendert (erste, letzte und die mit
    /// den meisten veränderten Bildbytes). Kosten je Seite rund 60 ms.
    static let maximumRenderSamplePages = 6
    static let renderSampleDPI = 110.0
    /// Obergrenze der Stichprobe je Seite in Pixeln. 12 MP reichen bis A1 bei
    /// vollen 110 DPI; A0 wird mit 88 DPI gemessen. Die frühere Grenze von
    /// 40 MP kostete je Seite 45 s (Debug) – bei sechs Stichprobenseiten
    /// mehr als die ganze Kompression.
    static let maximumRenderSamplePixels = 12_000_000
    /// Kantenlänge, auf der die Grenzen der Stichprobe geeicht sind: A4 bei
    /// 110 DPI.
    ///
    /// Struktur (SSIM 0,70, N3): Auf einem feineren Raster liegen fast alle
    /// Messfenster in leeren Flächen; eine leer gewordene große Seite misst
    /// dort weit über der Grenze. Große Seiten werden für die Struktur
    /// deshalb zusätzlich auf diesem Raster gemessen.
    ///
    /// Farbe (N17): Der Farberhalt vergleicht Pixel für Pixel mit einem
    /// Pixel Spielraum. Auf einem feineren Raster reicht der Spielraum nicht
    /// mehr über die Kante eines dünnen Strichs, der durch erlaubtes
    /// Verkleinern weicher wurde. Große Seiten werden für die Farbe deshalb
    /// NUR auf diesem Raster gemessen: wie das Blatt, das sie sind
    /// (übergroße Scan-Seiten gelten überall als A4).
    static let renderSampleCalibratedEdge = 1300

    /// Masterplan N3: Maßstab (Pixel je Punkt) für eine Seite. Normal
    /// `renderSampleDPI`; für große Seiten so weit gesenkt, dass das Raster
    /// unter der Pixelgrenze bleibt. Vorher gab es oberhalb der Grenze kein
    /// Bild, und die Seite galt als „nicht vergleichbar" – Plakate und
    /// Rollenplots ließen sich nicht mehr komprimieren. nil bei einer Box
    /// ohne brauchbare Fläche.
    static func renderSampleScale(for box: CGRect) -> Double? {
        let area = Double(box.width) * Double(box.height)
        guard area.isFinite, area > 0 else { return nil }
        // 0,995: Die Kanten werden gerundet; das Produkt soll sicher unter
        // der Grenze bleiben.
        let fitting = (Double(maximumRenderSamplePixels) / area).squareRoot() * 0.995
        return min(renderSampleDPI / 72.0, fitting)
    }
    /// Masterplan D5/N16: So lange darf der Hilfsprozess an Referenz und
    /// Ausgabe EINER Seite arbeiten, bevor er beendet wird.
    static let renderSampleTimeout = 30.0
    /// Strukturkollaps: dieselbe Grenze wie der Katastrophen-Floor der
    /// Bildgates – darunter ist eine Seite kaputt, nicht nur komprimiert.
    static let renderSampleMinimumSSIM = QualityGatePolicy.catastrophicGlobalFloor
    /// Farbverlust. Die Stichprobe ist ein Katastrophennetz wie die SSIM-
    /// Grenze darüber (0,70, weit unter den Stufengrenzen), keine zweite
    /// Qualitätsentscheidung: Sie schlägt an, wenn im farbigsten Prozent der
    /// Seite weniger als 30 % der Farbe übrig sind
    /// (`QualityGates.peakChromaRetention`).
    ///
    /// Gemessen 19.11. (N17, Ausgaben von 1.0.9): Die härteste erlaubte
    /// Ausgabe – Klein auf dünner satter Tinte, 910-px-JPEG – behält 51 %,
    /// Smart 71 %, zwei echte übergroße Scans 73–98 %. Grau gewordene Farbe
    /// liegt bei 0 %. Die Grenze sitzt dazwischen, näher am Verlust.
    ///
    /// Vorher (A3): ΔE über 24 im farbigsten Prozent. Das lehnte die
    /// Verkleinerung von Scans mit dünner satter Tinte ab (ΔE 26–39, Smart
    /// endete im Fehler, Klein fiel auf verlustfrei zurück) und übersah einen
    /// echten Handschrift-Scan, der komplett grau wurde (ΔE 20).
    static let renderSampleMinimumChromaRetention = 0.30

    /// Stichprobenseiten (0-basiert, sortiert): erste und letzte Seite plus die
    /// Seiten mit den meisten veränderten Bildbytes.
    static func renderSamplePages(pageCount: Int, changedBytesByPage: [Int: Int]) -> [Int] {
        guard pageCount > 0 else { return [] }
        var pages: Set<Int> = [0, pageCount - 1]
        let ranked = changedBytesByPage
            .filter { $0.key >= 0 && $0.key < pageCount && $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for (page, _) in ranked where pages.count < maximumRenderSamplePages {
            pages.insert(page)
        }
        return pages.sorted()
    }

    /// Messwerte einer Stichprobenseite – das, was der Hilfsprozess liefert.
    /// `comparable == false`: Die Seite ließ sich nicht in zwei gleich große
    /// Raster rendern (verschiedene Seitengrößen, Seite fehlt, Box unbrauchbar).
    struct RenderSampleMeasurement: Codable, Equatable {
        var page: Int               // 0-basiert
        var comparable: Bool
        /// Struktur: der schlechtere Wert aus voller Auflösung und geeichtem Raster.
        var structureSSIM: Double?
        /// Farberhalt im farbigsten Prozent (0…1), siehe
        /// `QualityGates.peakChromaRetention`; nil ohne Farbe in der Referenz.
        var chromaRetention: Double?
    }

    /// Bewertet die Stichprobenseiten von Original und Ausgabe und meldet
    /// Strukturkollaps (`.render`) oder Farbverlust (`.color`) mit Seite.
    /// Die Befunde sind `.error`: Sie lösen den vorhandenen Re-Plan aus
    /// (RollbackPlanner stuft die Ressourcen dieser Seiten zurück) – keine
    /// zweite Entscheidungslogik.
    ///
    /// Gerendert und gemessen wird im Hilfsprozess (Masterplan N16):
    /// CoreGraphics kam an einem mutierten JPX-Bild nicht zurück. Hängt er an
    /// einer Seite länger als `renderSampleTimeout`, wird er beendet und die
    /// Prüfung gilt als nicht bestanden.
    private static func validateRenderSample(outputURL: URL, referenceURL: URL,
                                             pages: [Int], expectsGrayscale: Bool,
                                             report: inout Report) {
        let measurements: [RenderSampleMeasurement]
        switch FrameworkProbe.renderSample(referenceURL: referenceURL, outputURL: outputURL, pages: pages) {
        case .success(let values):
            measurements = values
        case .failure(.stalled(let page)):
            report.frameworkTimedOut = true
            let number = (page ?? pages.first ?? 0) + 1
            let message = String(localized: "Seite \(number) ließ sich nicht in angemessener Zeit darstellen.")
            report.fail(message, ValidationFinding(kind: .render, severity: .error,
                                                   pages: [number], message: message))
            return
        case .failure:
            // Dokumente nicht zu öffnen, Hilfsprozess abgestürzt oder nicht
            // startbar: nichts gemessen, also nicht bestanden.
            report.fail("Render-Stichprobe nicht möglich", ValidationFinding(
                kind: .render, severity: .error, pages: [],
                message: "Render-Stichprobe nicht möglich"))
            return
        }
        for measurement in measurements {
            let number = measurement.page + 1
            guard measurement.comparable else {
                report.fail("Seite \(number): nicht vergleichbar gerendert", ValidationFinding(
                    kind: .render, severity: .error, pages: [number],
                    message: "Seite \(number): nicht vergleichbar gerendert"))
                continue
            }
            if let structureSSIM = measurement.structureSSIM, structureSSIM < renderSampleMinimumSSIM {
                let message = String(format: "Seite %d: Darstellung weicht vom Original ab (SSIM %.3f)",
                                     number, structureSSIM)
                report.fail(message, ValidationFinding(
                    kind: .render, severity: .error, pages: [number], message: message))
            }
            // N4: Rechnet der Lauf absichtlich nach Graustufen, ist fehlende
            // Farbe gewollt. Die Strukturprüfung darüber bleibt.
            if !expectsGrayscale,
               let retention = measurement.chromaRetention, retention < renderSampleMinimumChromaRetention {
                let message = String(format: "Seite %d: Farbe geht verloren (noch %.0f %% im farbigsten Prozent)",
                                     number, retention * 100)
                report.fail(message, ValidationFinding(
                    kind: .color, severity: .error, pages: [number], message: message))
            }
        }
    }

    /// Rendert und misst die Stichprobenseiten – läuft im Hilfsprozess
    /// (`ProbeMode`). nil, wenn sich eines der Dokumente nicht öffnen lässt.
    /// `onPage` meldet Beginn und Ende je Seite an den Aufrufer.
    static func measureRenderSample(referenceURL: URL, outputURL: URL, pages: [Int],
                                    onPage: PDFSemanticSnapshot.PageProgress? = nil) -> [RenderSampleMeasurement]? {
        guard let source = CGPDFDocument(referenceURL as CFURL),
              let output = CGPDFDocument(outputURL as CFURL) else { return nil }
        var result: [RenderSampleMeasurement] = []
        for index in pages where index < source.numberOfPages && index < output.numberOfPages {
            autoreleasepool {
                // Das Zeitlimit je Seite gilt dem RENDERN (CoreGraphics kann
                // hängen). Das Messen danach ist eigener Code und zählt nicht
                // dazu: Im Debug-Build braucht es an einer 12-MP-Seite allein
                // über 15 s, zusammen mit dem Rendern riss es die 30 s.
                onPage?(true, index)
                var rendered: (CGImage, CGImage)?
                if let sourcePage = source.page(at: index + 1),
                   // N3: EIN Maßstab für beide, bestimmt an der Quellseite.
                   // Weicht die Seitengröße der Ausgabe ab, entstehen
                   // verschieden große Raster – das bleibt ein Befund.
                   let scale = renderSampleScale(for: sourcePage.getBoxRect(.cropBox)),
                   let reference = renderPage(source, index: index, scale: scale),
                   let candidate = renderPage(output, index: index, scale: scale) {
                    rendered = (reference, candidate)
                }
                onPage?(false, index)
                guard let (reference, candidate) = rendered,
                      reference.width == candidate.width, reference.height == candidate.height
                else {
                    result.append(RenderSampleMeasurement(page: index, comparable: false))
                    return
                }
                let census = ChromaCensus.of(reference)
                let edge = max(reference.width, reference.height)
                guard let refSample = QualityGates.sample(reference, maxEdge: edge, census: census),
                      let outSample = QualityGates.sample(candidate, maxEdge: edge),
                      let measurement = QualityGates.measure(reference: refSample, candidate: outSample)
                else {
                    // Zu klein zum Messen (unter 8 px): vergleichbar, ohne Werte.
                    result.append(RenderSampleMeasurement(page: index, comparable: true))
                    return
                }
                // Große Seiten zusätzlich auf dem geeichten Raster
                // (`renderSampleCalibratedEdge`):
                //  • Struktur (N3): es gilt der schlechtere Wert – nie milder
                //    als die volle Auflösung allein.
                //  • Farbe (N17): es gilt das geeichte Raster.
                var structureSSIM = measurement.globalSSIM
                var colorSamples = (refSample, outSample)
                if edge > renderSampleCalibratedEdge,
                   let refSmall = QualityGates.sample(reference, maxEdge: renderSampleCalibratedEdge, census: census),
                   let outSmall = QualityGates.sample(candidate, maxEdge: renderSampleCalibratedEdge),
                   let small = QualityGates.measure(reference: refSmall, candidate: outSmall) {
                    structureSSIM = min(structureSSIM, small.globalSSIM)
                    colorSamples = (refSmall, outSmall)
                }
                let chromaRetention = colorSamples.0.isColor
                    ? QualityGates.peakChromaRetention(reference: colorSamples.0, candidate: colorSamples.1)
                    : nil
                result.append(RenderSampleMeasurement(
                    page: index, comparable: true,
                    structureSSIM: structureSSIM.isFinite ? structureSSIM : nil,
                    chromaRetention: chromaRetention.flatMap { $0.isFinite ? $0 : nil }))
            }
        }
        return result
    }

    /// Seite im Maßstab `scale` (Pixel je Punkt) auf Weiß, Rotation über die
    /// Zeichenmatrix.
    private static func renderPage(_ document: CGPDFDocument, index: Int, scale: Double) -> CGImage? {
        guard let page = document.page(at: index + 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        guard let rawW = PixelExtent.edge(Double(rotated ? box.height : box.width), scale: scale),
              let rawH = PixelExtent.edge(Double(rotated ? box.width : box.height), scale: scale)
        else { return nil }
        let w = max(8, rawW), h = max(8, rawH)
        guard w * h <= maximumRenderSamplePixels,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        // getDrawingTransform skaliert nie hoch: erst auf DPI skalieren, dann
        // die Transformation in Punkten (Rotation, Box-Ursprung) anwenden.
        ctx.scaleBy(x: CGFloat(w) / ((rotated ? box.height : box.width)),
                    y: CGFloat(h) / ((rotated ? box.width : box.height)))
        ctx.concatenate(page.getDrawingTransform(
            .cropBox,
            rect: CGRect(x: 0, y: 0, width: rotated ? box.height : box.width,
                         height: rotated ? box.width : box.height),
            rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// Seitengeometrie muss Punkt für Punkt der Referenz entsprechen.
    /// Ein verschobener CropBox-Ursprung ist sichtbares Cropping und darf
    /// bei einer Kompression nicht vorkommen.
    private static func validateGeometry(_ doc: PDFDocument,
                                         reference: PDFDocument,
                                         report: inout Report) {
        guard doc.pageCount == reference.pageCount else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let refPage = reference.page(at: i) else { continue }
            for box in [PDFDisplayBox.mediaBox, .cropBox] {
                let a = page.bounds(for: box), b = refPage.bounds(for: box)
                if abs(a.minX - b.minX) > 1 || abs(a.minY - b.minY) > 1
                    || abs(a.width - b.width) > 1 || abs(a.height - b.height) > 1 {
                    let name = box == .mediaBox ? "MediaBox" : "CropBox"
                    let message = "Seite \(i + 1): \(name) verändert "
                        + "(\(Int(b.width))×\(Int(b.height)) → \(Int(a.width))×\(Int(a.height)))"
                    report.fail(message, ValidationFinding(
                        kind: .geometry, severity: .error, pages: [i + 1],
                        message: message))
                }
            }
            if RotationNormalizer.normalized(page.rotation)
                != RotationNormalizer.normalized(refPage.rotation) {
                let message = "Seite \(i + 1): Rotation verändert "
                    + "(\(refPage.rotation)° → \(page.rotation)°)"
                report.fail(message, ValidationFinding(
                    kind: .geometry, severity: .error, pages: [i + 1],
                    message: message))
            }
        }
    }

    // MARK: - V2-5 (§11.2) – Mapping Snapshot → Finding

    /// Vergleichspunkt → Finding-Art. Ohne exakte Entsprechung gilt
    /// `.structure` (konservativ: der Befund bleibt sichtbar).
    private static func findingKind(of kind: PDFSemanticSnapshot.Kind)
        -> ValidationFinding.Kind {
        switch kind {
        case .pageCount: return .pageCount
        case .geometry: return .geometry
        case .textLoss, .textContent: return .text
        case .annotations: return .annotation
        case .links, .externalLinks, .internalLinks,
             .namedDestinations, .namedDestinationTarget:
            return .link
        case .formWidgets, .formFields, .fieldValue, .fieldType, .fieldFlags:
            return .form
        case .outline, .outlineTargets, .outlineStructure:
            return .outline
        case .attachments, .attachmentContent:
            return .attachment
        case .signatures, .metadata, .pageLabels:
            return .structure
        }
    }

    /// Snapshot-Schwere → Finding-Schwere. critical/high sind Failures und
    /// dürfen einen Re-Plan auslösen (§11.5), medium/low bleiben Meldungen.
    private static func findingSeverity(of severity: PDFSemanticSnapshot.Severity)
        -> ValidationFinding.Severity {
        switch severity {
        case .critical: return .fatal
        case .high: return .error
        case .medium: return .warning
        case .low: return .info
        }
    }

    /// Wirft, wenn die Policy verletzt wird.
    static func assertValid(_ report: Report) throws {
        guard report.isValid else { throw ValidationError.invalid(report.failures) }
    }

    // MARK: Kernprüfungen

    private static func validateStructure(_ doc: PDFDocument,
                                          expectedPageCount: Int?,
                                          reference: PDFDocument?,
                                          policy: Policy,
                                          textCounts: (input: Int, output: Int, inputWords: Int)? = nil,
                                          report: inout Report) {
        if let expected = expectedPageCount, doc.pageCount != expected {
            report.fail("Seitenzahl \(doc.pageCount) ≠ erwartet \(expected)",
                        ValidationFinding(
                            kind: .pageCount, severity: .error, pages: [],
                            message: "Seitenzahl \(doc.pageCount) ≠ erwartet \(expected)"))
        }
        if !policy.requiresOpenable { return }

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else {
                report.fail("Seite \(i + 1) nicht ladbar", ValidationFinding(
                    kind: .structure, severity: .error, pages: [i + 1],
                    message: "Seite \(i + 1) nicht ladbar"))
                continue
            }
            if policy.plausibleGeometry {
                let bounds = page.bounds(for: .mediaBox)
                if bounds.width <= 0 || bounds.height <= 0
                    || bounds.width.isInfinite || bounds.height.isInfinite
                    || bounds.width > 1_000_000 || bounds.height > 1_000_000 {
                    report.fail("MediaBox von Seite \(i + 1) unplausibel",
                                ValidationFinding(
                                    kind: .geometry, severity: .error,
                                    pages: [i + 1],
                                    message: "MediaBox von Seite \(i + 1) unplausibel"))
                }
            }
            if policy.plausibleRotations {
                let rotation = RotationNormalizer.normalized(page.rotation)
                if ![0, 90, 180, 270].contains(rotation) {
                    report.fail("Rotation von Seite \(i + 1) unplausibel (\(rotation)°)",
                                ValidationFinding(
                                    kind: .geometry, severity: .error,
                                    pages: [i + 1],
                                    message: "Rotation von Seite \(i + 1) unplausibel (\(rotation)°)"))
                }
            }
        }

        if policy.preservesText, let ref = reference {
            // Mit Seitenzuordnung wird nur der Text der ÜBERNOMMENEN Seiten
            // verglichen. Ohne sie meldete jede Teilmengen-Operation einen
            // Verlust: `extract-first-half` behält die Hälfte der Seiten und
            // damit rund die Hälfte des Textes – das ist die Operation, kein
            // Mangel.
            let inputText: String
            let outputText: String
            if policy.pageMapping == nil, let textCounts {
                // C2: Zeichenzahlen aus den Snapshots – derselbe Vergleich
                // (Summe der Seitentexte), ohne erneute Extraktion.
                // Wie bisher: Eingaben ohne sichtbaren Text (nur Leerraum)
                // prüfen nichts.
                if textCounts.inputWords > 0, textCounts.input > 0 {
                    let ratio = Double(textCounts.output) / Double(textCounts.input)
                    if ratio < policy.textSimilarityThreshold {
                        let message = String(format: "Textverlust: %.0f %% erhalten", ratio * 100)
                        report.fail(message, ValidationFinding(
                            kind: .text, severity: .error, pages: [], message: message))
                    }
                }
                inputText = ""
                outputText = ""
            } else if let mapping = policy.pageMapping {
                let pairs = mapping.sorted { $0.key < $1.key }
                inputText = pairs.compactMap { ref.page(at: $0.value)?.string }.joined()
                outputText = pairs.compactMap { doc.page(at: $0.key)?.string }.joined()
            } else {
                inputText = (0..<ref.pageCount).compactMap { ref.page(at: $0)?.string }.joined()
                outputText = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined()
            }
            if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let ratio = Double(outputText.count) / Double(max(inputText.count, 1))
                if ratio < policy.textSimilarityThreshold {
                    let message = String(format: "Textverlust: %.0f %% erhalten", ratio * 100)
                    report.fail(message, ValidationFinding(
                        kind: .text, severity: .error, pages: [],
                        message: message))
                }
            }
        }

        if let mapping = policy.pageMapping, let ref = reference {
            comparePerPage(mapping: mapping, reference: ref, output: doc,
                           policy: policy, report: &report)
        } else {
            compareCounts(in: reference, out: doc,
                          selector: { totalAnnotations($0) },
                          label: "Annotationen",
                          kind: .annotation,
                          hardFail: policy.preservesAnnotations,
                          report: &report)
            compareCounts(in: reference, out: doc,
                          selector: { countSubtype("Link", in: $0) },
                          label: "Links",
                          kind: .link,
                          hardFail: policy.preservesLinks,
                          report: &report)
            compareCounts(in: reference, out: doc,
                          selector: { countSubtype("Widget", in: $0) },
                          label: "Formularfelder",
                          kind: .form,
                          hardFail: policy.preservesForms,
                          report: &report)
        }
    }

    /// Prüft je Seitenpaar, was die übernommene Seite behalten hat.
    ///
    /// Gemeldet wird die SUMME der Verluste über alle Paare, nicht jeder
    /// Einzelfall – ein Dokument mit hundert betroffenen Seiten soll eine
    /// Zeile erzeugen, nicht hundert. Die Zahl der betroffenen Seiten steht
    /// dabei, sonst wäre nicht erkennbar, ob es ein Einzelfall oder ein
    /// Muster ist.
    private static func comparePerPage(mapping: [Int: Int],
                                       reference: PDFDocument,
                                       output: PDFDocument,
                                       policy: Policy,
                                       report: inout Report) {
        struct Loss { var pages = 0; var numbers: [Int] = []; var before = 0; var after = 0 }
        var annotations = Loss(), links = Loss(), widgets = Loss()

        // Wie viele Verweise der Quelle sind schon dort unauflösbar?
        //
        // Sie dürfen entfernt werden – genau dafür gibt es die
        // dangling-Politik. Nur was AUFLÖSBAR war und danach fehlt, ist ein
        // Verlust. Die Zahl wird dokumentweit ermittelt; eine seitengenaue
        // Zuordnung gibt die Bridge nicht her, und für die Frage „wurde mehr
        // entfernt als tot war?" genügt sie.
        var deadInSource = 0
        if let sourceURL = policy.sourceURL,
           let core = try? PDFCoreDocument(path: sourceURL.path),
           let targets = try? core.internalLinkTargets() {
            deadInSource = targets.filter { $0 == -1 }.count
        }

        for (outIndex, srcIndex) in mapping.sorted(by: { $0.key < $1.key }) {
            guard let outPage = output.page(at: outIndex),
                  srcIndex >= 0, srcIndex < reference.pageCount,
                  let srcPage = reference.page(at: srcIndex) else { continue }

            func tally(_ selector: (PDFPage) -> Int, into loss: inout Loss) {
                let before = selector(srcPage), after = selector(outPage)
                if after < before {
                    loss.pages += 1
                    loss.numbers.append(outIndex + 1)
                    loss.before += before
                    loss.after += after
                }
            }
            tally({ $0.annotations.count }, into: &annotations)
            // Typ über den sicheren Zugriff: `PDFAnnotation.type` wirft bei einem
            // ungültigen /Subtype eine Objective-C-Ausnahme (Fuzz-Fund crash-108408).
            tally({ $0.annotations.filter { PDFSemanticSnapshot.subtype($0) == "Link" }.count }, into: &links)
            tally({ $0.annotations.filter { PDFSemanticSnapshot.subtype($0) == "Widget" }.count }, into: &widgets)
        }

        // Bleiben ALLE Quellseiten erhalten, darf kein Verweis wegfallen –
        // dann ist jeder Verlust ein Fehler. Fehlt dagegen eine Seite, sind
        // Verweise auf sie zwangsläufig unauflösbar und werden zu Recht
        // entfernt; das ist die Operation, kein Mangel.
        //
        // Die Unterscheidung ist keine Toleranz, sondern eine Fallunterscheidung:
        // Sie hängt daran, ob die Zielseite noch existiert – nicht an einem
        // Schwellwert.
        let keepsEveryPage = Set(mapping.values).count >= reference.pageCount
        let context = keepsEveryPage
            ? "" : " (Teilmenge – Verweise auf entfernte Seiten entfallen)"

        // Verluste bis zur Zahl der bereits toten Verweise sind erwartbar.
        //
        // Das Budget skaliert mit der Vervielfachung: `merge` übernimmt jede
        // Quellseite zweimal, also erscheinen auch ihre toten Verweise
        // zweimal. Ohne diesen Faktor meldete die Prüfung an
        // `2608.23540v1.pdf` „1342 → 0", während dasselbe Dokument bei
        // reorder (Faktor 1) längst durchlief – derselbe Sachverhalt, zwei
        // Urteile.
        let distinctSources = Set(mapping.values).count
        let duplication = distinctSources > 0
            ? max(1, mapping.count / distinctSources) : 1
        let deadBudget = deadInSource * duplication

        func emit(_ loss: Loss, _ label: String, kind: ValidationFinding.Kind,
                  hardFail: Bool) {
            guard loss.pages > 0 else { return }
            let removed = loss.before - loss.after
            if label.hasPrefix("Links") || label.hasPrefix("Annotationen"),
               removed <= deadBudget {
                let message = "\(label): \(loss.before) → \(loss.after) "
                    + "auf \(loss.pages) Seite\(loss.pages == 1 ? "" : "n") "
                    + "(\(deadBudget) Verweise waren bereits in der Quelle tot)"
                report.warn(message, ValidationFinding(
                    kind: kind, severity: .warning, pages: loss.numbers.sorted(),
                    message: message))
                return
            }
            let message = "\(label): \(loss.before) → \(loss.after) "
                + "auf \(loss.pages) Seite\(loss.pages == 1 ? "" : "n")\(context)"
            // Verluste, die die Policy zum Fail erklärt, sind .error-Findings
            // und dürfen einen Rollback (§11.5) auslösen; Politik-Warnungen
            // bleiben .warning.
            let finding = ValidationFinding(
                kind: kind,
                severity: hardFail && keepsEveryPage ? .error : .warning,
                pages: loss.numbers.sorted(),
                message: message)
            if hardFail && keepsEveryPage { report.fail(message, finding) }
            else { report.warn(message, finding) }
        }
        emit(annotations, "Annotationen verloren", kind: .annotation,
             hardFail: policy.preservesAnnotations)
        emit(links, "Links verloren", kind: .link, hardFail: policy.preservesLinks)
        emit(widgets, "Formularfelder verloren", kind: .form,
             hardFail: policy.preservesForms)
    }

    private static func totalAnnotations(_ doc: PDFDocument) -> Int {
        (0..<doc.pageCount).reduce(0) { sum, i in
            sum + (doc.page(at: i)?.annotations.count ?? 0)
        }
    }

    /// Zählt Anmerkungen eines Typs („Link", „Widget").
    ///
    /// Zwei Korrekturen (19.11.2026): Der Typ kommt über den sicheren Zugriff
    /// (`PDFAnnotation.type` wirft bei ungültigem /Subtype – crash-108408).
    /// Und der Vergleich traf vorher nie: `type` liefert „Link",
    /// `PDFAnnotationSubtype.link.rawValue` ist „/Link" – die Zählung ergab
    /// immer 0, die Prüfung auf verlorene Links und Formularfelder lief leer.
    private static func countSubtype(_ name: String, in doc: PDFDocument) -> Int {
        (0..<doc.pageCount).reduce(0) { sum, i in
            sum + (doc.page(at: i)?.annotations.filter { PDFSemanticSnapshot.subtype($0) == name }.count ?? 0)
        }
    }

    private static func compareCounts(in reference: PDFDocument?,
                                      out doc: PDFDocument,
                                      selector: (PDFDocument) -> Int,
                                      label: String,
                                      kind: ValidationFinding.Kind,
                                      hardFail: Bool,
                                      report: inout Report) {
        guard let ref = reference else { return }
        let before = selector(ref)
        let after = selector(doc)
        guard before > 0 else { return }
        if after < before {
            let message = "\(label): \(before) → \(after)"
            let finding = ValidationFinding(
                kind: kind, severity: hardFail ? .error : .warning, pages: [],
                message: message)
            if hardFail {
                report.fail(message, finding)
            } else {
                report.warn(message, finding)
            }
        }
    }
}
