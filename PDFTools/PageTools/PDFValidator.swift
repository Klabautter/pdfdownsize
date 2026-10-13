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

    /// Validiert `output` gegen die Policy. Die Referenz kann als URL oder als
    /// bereits geladenes Dokument übergeben werden (z. B. Originaldaten aus dem RAM).
    @discardableResult
    static func validate(outputURL: URL,
                         referenceURL: URL? = nil,
                         referenceDocument: PDFDocument? = nil,
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

        validateStructure(outDoc,
                          expectedPageCount: policy.expectedPageCount,
                          reference: refDoc,
                          policy: policy,
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
           let referenceURL {
            do {
                let before = try PDFSemanticSnapshot.capture(referenceURL)
                let after = try PDFSemanticSnapshot.capture(outputURL)
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
            if let mapping = policy.pageMapping {
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
                          selector: { countSubtype(.link, in: $0) },
                          label: "Links",
                          kind: .link,
                          hardFail: policy.preservesLinks,
                          report: &report)
            compareCounts(in: reference, out: doc,
                          selector: { countSubtype(.widget, in: $0) },
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
            tally({ $0.annotations.filter { $0.type == "Link" }.count }, into: &links)
            tally({ $0.annotations.filter { $0.type == "Widget" }.count }, into: &widgets)
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

    private static func countSubtype(_ subtype: PDFAnnotationSubtype, in doc: PDFDocument) -> Int {
        (0..<doc.pageCount).reduce(0) { sum, i in
            sum + (doc.page(at: i)?.annotations.filter { $0.type == subtype.rawValue }.count ?? 0)
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
