import Foundation
import AppKit
import PDFKit

/// Masterplan Finding 17 – DER Assembly-Service.
///
/// Produktionsaufrufer kennen nur diesen Typ. Welches Backend die Seiten
/// tatsächlich kopiert, ist eine Entscheidung des Service, keine des
/// Aufrufers – genau das erlaubte, den Wechsel in Schritt 11 an EINER
/// Stelle zu vollziehen. Seither kopiert ausschliesslich libqpdf; die
/// Begründung mit den Messwerten steht unten am Abschnitt „Backend".
///
/// Vorher lag dieser Code als `nonisolated static`-Sammlung im
/// `MergeViewModel` – also PDF-Kernlogik in einer UI-Schicht. Der Inhalt ist
/// unverändert übernommen; nur der Ort und der Einstiegspunkt sind neu.
enum PageAssemblyService {

    /// Bequemer Einstieg für Aufrufer, die bereits `PageItem`s halten –
    /// ein dünner Wrapper über den neutralen Assembly-Plan.
    @concurrent nonisolated static func assemble(pages: [PageItem], to outputURL: URL,
                                     progress: @escaping (Double) -> Void) async throws {
        try await assemble(plan: pages.assemblyPlan, to: outputURL,
                           progress: progress)
    }

    /// Führt einen neutralen PageAssemblyPlan aus.
    @concurrent nonisolated static func assemble(plan: PageAssemblyPlan, to outputURL: URL,
                                     progress: @escaping (Double) -> Void) async throws {
        // Befund B11 (Review 2026-10-09) – Abbruch greift ZWISCHEN den
        // Seiten und während des Schreibens, nicht erst nach der fertigen
        // Datei. Der Task-Zustand wird an die Bridge durchgereicht; ein
        // Abbruch nach dem Schreiben räumt die Ausgabe weg, damit kein
        // Ergebnis liegen bleibt, das der Aufrufer nie zu sehen bekommt.
        try Task.checkCancellation()
        func bailIfCancelled() throws {
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: outputURL)
                throw CancellationError()
            }
        }

        // Phase 12 – Outline-Capture VOR dem Assemble (Quellen-Sicht).
        var seenSources = Set<URL>()
        var sourceURLsInOrder: [URL] = []
        for item in plan.pages where seenSources.insert(item.sourceURL).inserted {
            sourceURLsInOrder.append(item.sourceURL)
        }
        let outlineSpecsPerSource = sourceURLsInOrder.map {
            $0.topLevelOutlineEntries()
        }
        // Phase 13 – Page-Label-Capture VOR dem Assemble (nur Single-Source-Policy).
        var sourceLabelEncodings: [String] = []
        if sourceURLsInOrder.count == 1,
           let core = try? PDFCoreDocument(path: sourceURLsInOrder[0].path) {
            sourceLabelEncodings = (try? core.pageLabelEncodings()) ?? []
        }

        // Fehlende Quellen VOR dem Bridge-Aufruf abfangen.
            //
        // Die Bridge meldet einen fehlenden Pfad als generischen
        // Öffnungsfehler; der Aufrufer erfüre dadurch nicht, WELCHE Datei
        // fehlt – deshalb die Prüfung vorab.
        for page in plan.pages where !FileManager.default.fileExists(
            atPath: page.sourceURL.path) {
            throw MergeError.missingSource(page.sourceURL.lastPathComponent)
        }

        // Phase-11-Policy (dangling interne Links entfernen) läuft im
        // C-Layer. Der Fortschritt kommt aus der Bridge – gemeldet wird,
        // NACHDEM eine Seite kopiert wurde, nicht vorher.
        // `write` ist synchron – der Fortschritt kommt über den Rückruf,
        // nicht über Nebenläufigkeit. Ein `await` davor hat der Übersetzer
        // zu Recht als wirkungslos gemeldet.
        //
        // `shouldContinue` läuft synchron auf dem Thread dieses Aufrufs –
        // `Task.isCancelled` sieht dort denselben Task wie dieser Funktions-
        // rumpf. Die Bridge wirft bei `false` einen eigenen Statuscode, den
        // `PDFCoreAssembler` als `CancellationError` weitergibt.
        try PDFCoreAssembler.write(
            plan: plan, to: outputURL, removeDanglingLinks: true,
            onPage: { done, total in
                guard !Task.isCancelled else { return }
                progress(Double(done) / Double(max(total, 1)))
            },
            shouldContinue: { !Task.isCancelled })
        try bailIfCancelled()

        // Nachsorge an der fertigen Datei: Enthält sie noch kaputte interne
        // Links – etwa weil eine Named-Dest-Tabelle das Kopieren nicht
        // überlebt hat –, werden sie hier entfernt.
        //
        // Jeder Nachsorgeschritt öffnet ein eigenes Dokument – ohne Pool
        // bleiben die alle bis zum Ende des Aufrufs liegen.
        autoreleasepool { Self.sanitizeWrittenOutput(at: outputURL) }
        try bailIfCancelled()

        // Phase 14 – Formularfeld-Namen eindeutig halten.
        //
        // Läuft in der BRIDGE, im selben Schritt, der das /AcroForm aufbaut.
        // Zuvor stand hier eine PDFKit-Umbenennung mit anschliessendem
        // `doc.write(to:)` – und ein PDFKit-Schreibvorgang zerstört die
        // /ToUnicode-Abbildungen von Type1-Fonts: beim Zusammenführen zweier
        // Formulare gemessen 2 CMaps vorher, 0 danach (Befund 15).
        //
        // Die Bridge benennt auf FELD-Ebene um, nicht auf Widget-Ebene: Ein
        // Feld mit mehreren Erscheinungsstellen bleibt ein Feld (Plan 4.5).

        // Phase 11 – dangling interne Links entfernen (Bridge, schreibt bei Änderung).
        autoreleasepool { Self.sanitizeWrittenOutput(at: outputURL) }

        // Phase 12 – Outline-Rebuild (PDFKit-Schritt).
        if sourceURLsInOrder.count == 1 {
            autoreleasepool {
                applyTopLevelOutlines(specs: outlineSpecsPerSource.first ?? [],
                                      plan: plan,
                                      to: outputURL)
            }
        }
        try bailIfCancelled()

        // Phase 13+16 – LETZTER Schritt über die Bridge: Page Labels schreiben
        // und Producer deterministisch stempeln; qpdf-Writer erhält dabei
        // Outlines und /Info.
        do {
            let core = try PDFCoreDocument(path: outputURL.path)
            if sourceURLsInOrder.count == 1, !sourceLabelEncodings.isEmpty {
                applyPageLabels(encodings: sourceLabelEncodings,
                                plan: plan,
                                doc: core)
            }
            core.setProducer("PDFTools")
            try core.save(to: outputURL)
        } catch {
            // Metadata/Labels sind optional – Assembly selbst bleibt gültig.
        }
    }


    /// Epic Phase 16 – deterministische Producer-Metadaten.
    nonisolated static func stampMetadata(on url: URL) {
        guard let doc = PDFDocument(url: url) else { return }
        // ObjC-Dictionary importiert unter MemberImportVisibility als
        // [AnyHashable:Any] – explizit auf den getypten Key casten.
        var attrs = (doc.documentAttributes ?? [:])
            as? [PDFDocumentAttribute: Any] ?? [:]
        attrs[.producerAttribute] = "PDFTools"
        doc.documentAttributes = attrs
        _ = doc.write(to: url)
    }
    /// Wandelt „start|style|prefix|first“-Range-Einträge in korrekt nummerierte
    /// pro-Seite-Einträge um (Reorder/Delete/Extract-fest) und schreibt sie.
    nonisolated static func applyPageLabels(encodings: [String],
                                            plan: PageAssemblyPlan,
                                            doc: PDFCoreDocument) {
        struct Def {
            let start: Int
            let style: String
            let prefix: String
            let firstNumber: Int   // effektive Nummer bei `start`
        }
        var defs: [Def] = []
        for enc in encodings {
            let parts = enc.split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count == 4, let start = Int(parts[0]) else { continue }
            defs.append(Def(start: start,
                            style: parts[1],
                            prefix: parts[2],
                            firstNumber: Int(parts[3]) ?? 1))
        }
        guard !defs.isEmpty else { return }
        defs.sort { $0.start < $1.start }   // aufsteigend: letzte passende gewinnt

        var perPageEncodings: [String] = []
        for (outIndex, item) in plan.pages.enumerated() {
            guard let def = defs.last(where: { item.sourcePageIndex >= $0.start }) else {
                continue
            }
            let offset = item.sourcePageIndex - def.start
            var body = def.style + "|" + def.prefix + "|"
            if !def.style.isEmpty {
                body += String(def.firstNumber + offset)
            }
            perPageEncodings.append("\(outIndex)|\(body)")
        }
        guard !perPageEncodings.isEmpty else { return }

        try? PDFCoreDocument.writePageLabelEncodings(perPageEncodings, doc: doc)
    }

    /// Setzt die Top-Level-Outlines anhand des Plans neu zusammen.
    /// Ziel-Seiten fehlen im Output → Eintrag droppen (keine halben Bäume).
    nonisolated static func applyTopLevelOutlines(
        specs: [TopLevelOutlineEntry],
        plan: PageAssemblyPlan,
        to outputURL: URL
    ) {
        guard !specs.isEmpty else { return }
        var firstOccurrence: [Int: Int] = [:]
        for (outIndex, item) in plan.pages.enumerated()
        where firstOccurrence[item.sourcePageIndex] == nil {
            firstOccurrence[item.sourcePageIndex] = outIndex
        }

        // Der Aufbau läuft über die BRIDGE, nicht über PDFKit.
        //
        // Zuvor stand hier `doc.outlineRoot = root; doc.write(to: outputURL)`.
        // Ein einziger PDFKit-Schreibvorgang zerstört die
        // Textextrahierbarkeit: gemessen 470 → 242 Wörter auf der ersten Seite
        // eines arXiv-Papers, weil die /ToUnicode-Abbildungen der Type1-Fonts
        // verlorengehen. Sichtbar war das nicht im Rendering – die Seite sah
        // unverändert aus, war aber nicht mehr durchsuchbar (Befund 15).
        //
        // Weil dieser Schritt für BEIDE Backends lief, trugen auch
        // libqpdf-Ausgaben den Schaden, obwohl die Assemblierung selbst
        // einwandfrei war.
        guard let core = try? PDFCoreDocument(path: outputURL.path) else { return }
        let pageCount = core.pageCount

        var titles: [String] = []
        var indices: [Int] = []
        for spec in specs {
            guard spec.sourcePageIndex >= 0,
                  let outIndex = firstOccurrence[spec.sourcePageIndex],
                  outIndex < pageCount else { continue }   // Policy-Drop
            titles.append(spec.title)
            indices.append(outIndex)
        }
        guard !titles.isEmpty else { return }

        try? PDFCoreDocument.writeOutlines(titles: titles, pageIndices: indices,
                                           doc: core)
        try? core.save(to: outputURL)
    }

    /// Öffnet eine fertige Ausgabe, entfernt dangling interne Links über die
    /// libqpdf-Bridge und schreibt die Datei nur bei Änderung zurück.
    nonisolated static func sanitizeWrittenOutput(at url: URL) {
        guard let core = try? PDFCoreDocument(path: url.path) else { return }
        if core.removeDanglingLinkAnnotations() > 0 {
            try? core.save(to: url)
        }
    }

    // MARK: - Backend

    /// Die Seiten-Assembly läuft ausschliesslich über libqpdf.
    ///
    /// Der PDFKit-Pfad ist mit Masterplan Schritt 11 entfernt worden. Die
    /// Grundlage war die Differenzmatrix über den ECHTEN Korpus
    /// (`assembly-differential`, 285 Dokumente, beide Backends gegen die
    /// Quelle gemessen):
    ///
    /// | Ergebnis | Dokumente |
    /// |---|---|
    /// | nur libqpdf verliert etwas | **0** |
    /// | nur PDFKit verliert etwas | 8 |
    ///
    /// Dazu vier Eigenschaften, in denen PDFKit nachweislich schlechter war:
    ///  - **Textextrahierbarkeit**: Ein `PDFDocument.write(to:)` zerstört die
    ///    /ToUnicode-Abbildungen von Type1-Fonts – 470 Wörter einer Seite
    ///    wurden zu 242 (Befund 15).
    ///  - **Interne Verweise**: 187 Link-Annotationen eines CVPR-Papers
    ///    wurden zu 2 (Befund 13).
    ///  - **Speicher**: 2938 MB gegen 71 MB am selben Dokument, im Korpuslauf
    ///    eine Spitze von 20.8 GB gegen 450 MB.
    ///  - **Beschädigte Bilder**: Ein Dokument mit kaputtem Bildstream rendert
    ///    nach PDFKit-Assemblierung schwarz statt weiss (Befund 5).
    ///
    /// Belegt durch den Korpuslauf `2026-08-28_124805_full_merged`:
    /// 3135 Operationen, 0 Fehlschläge, alle vier Fixture-Klassen 100 %.

}

