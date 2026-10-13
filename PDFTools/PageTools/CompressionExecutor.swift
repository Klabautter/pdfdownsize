import Foundation
import CoreGraphics

/// Masterplan Schritt 1–4 – führt einen `CompressionPlan` über libqpdf aus.
///
/// Der Executor entscheidet NICHTS. Er setzt exakt um, was im Plan steht –
/// genau deshalb kann die Schätzung nicht vom Ergebnis abweichen (Finding 11).
///
/// Sicherheitseigenschaften:
///  - Bilder werden ausschließlich über `PDFObjectID` adressiert (Finding 13).
///  - Maskierte Bilder und unbekannte Filter erreichen den Executor nie; die
///    Bridge verweigert sie zusätzlich selbst (Findings 14/15).
///  - Es gibt keinen Seiten-Thumbnail-Ersatz mehr.
enum CompressionExecutor {

    struct Result {
        let outputURL: URL
        let replacedImages: Int
        let skippedImages: Int
        /// Bilder, deren Ersetzung die Bridge abgelehnt hat. > 0 ist ein Fehler
        /// im Plan, kein tolerierbarer Zustand – deshalb wird er gemeldet.
        let rejectedByBridge: [PDFObjectID]
        /// Verweise, die auf ein bereits vorhandenes, bitgleiches Bild
        /// umgehängt wurden.
        var mergedDuplicateImages: Int = 0
        /// Phase 1b – behaltene DCT-Streams, die neu verpackt wurden
        /// (Koeffizienten bitidentisch, optimierte Huffman-/Scan-Verpackung).
        var repackedImages: Int = 0
        /// Phase 3-Followup – Flate-Streams, die per Zopfli neu verpackt
        /// wurden (nur Max-Preset, verlustfrei, Never-Grow).
        var zopfliRepackedStreams: Int = 0
        /// Phase 3-Followup – gesparte Rohbytes des Zopfli-Passes.
        var zopfliEstimatedBytesSaved: Int = 0
        /// Phase 6C – CMYK-Bilder, die über den kontrollierten YCCK-Re-Encode
        /// ersetzt wurden (hinter ΔE-Gate und 6b-Race).
        var cmykReencodedImages: Int = 0
        /// Phase 3b – vom Content-Hash-Dedup absorbierte Stream-Objekte
        /// (Bild-, Content- und sonstige Streams).
        var deduplicatedStreams: Int = 0
        /// Phase 3b – absorbierte Dict-/Array-Duplikate.
        var deduplicatedObjects: Int = 0
        /// Phase 3b – gesparte Rohbytes (Schätzung, Never-Grow implizit).
        var dedupEstimatedBytesSaved: Int = 0
        /// Phase 5a – gefundene /Font-Dicts (Inventar).
        var auditedFontObjects: Int = 0
        /// Phase 5a – gefundene FontFile/2/3-Programme (eindeutig).
        var auditedFontFileStreams: Int = 0
        /// Phase 5a – umgehängte Font-Dict-Referenzen (semantischer Dedup).
        var deduplicatedFontRefs: Int = 0
        /// Phase 5a – entfernte Font-Einträge aus Resources-Maps (GC).
        var removedUnusedFonts: Int = 0
        /// Phase 5a – gesparte Rohbytes (Schätzung über FontFile-Größen).
        var fontEstimatedBytesSaved: Int = 0
        /// V2-8 (§14.4) – selektiv subsettete Fonts (je-Font-QA bestanden).
        var selectiveSubsettedFonts: Int = 0
        /// V2-8 (§14.4) – Fonts, die der C-Kern konservativ behalten hat.
        var selectiveRefusedFonts: Int = 0
        /// V2-8 (§14.4) – Fonts, deren QA scheiterte; NUR SIE wurden
        /// zurückgerollt (keep), nie das ganze Dokument.
        var selectiveRolledBackFonts: Int = 0
        /// V2-8 (§14.4) – gesparte Programmbytes der selektiven Subsets.
        var selectiveFontSubsetEstimatedBytesSaved: Int = 0
        /// V2-8 (§14.4) – Verlauf je Font (Trace-Qulle, §7.4).
        var selectiveFontOutcomes: [FontOptimizer.FontOutcome] = []
        /// V2-8 (§14.6) – entfernte Einträge aus Resource-Maps (gesamt).
        var resourceGCEntriesRemoved: Int = 0
        /// V2-8 (§14.6) – geschätzte Rohbytes der entfernten Einträge.
        var resourceGCEstimatedBytesSaved: Int = 0
        /// Seiten-Thumbnails (/Thumb) entfernt – verlustfrei, Viewer
        /// regenerieren sie, verwaiste Streams verwirft der Writer.
        var removedPageThumbs: Int = 0
        /// Content-Streams kompaktiert (Seiten-/Contents + Form-XObjects).
        var minifiedContentStreams: Int = 0
        /// Phase V2-7 (§13) – rekonstruierte MRC-Scan-Seiten.
        var mrcPages: Int = 0
        /// V2-9 (§15.6) – true, wenn der EINZIGE Write bereits mit finalen
        /// Writer-Optionen (Struktur-Pass-Flags) lief; der Compressor lässt
        /// dann den qpdf-CLI-Pass weg. NUR im candidateEngine-Pfad (§25).
        var singleWriteUsed: Bool = false

        // MARK: Phase V2-1 (§7.6) – Pass Attribution
        //
        // Gesparte Bytes je Pass. ALLE Werte sind `estimated`: Sie werden
        // auf Stream-Ebene vor dem finalen Schreiben bestimmt (Plan-Erwar-
        // tung bzw. gemessene Stream-Delta). `actual` wird erst nach dem
        // Write messbar (z. B. über den Failure-Isolation-Mode, §7.7);
        // Dedup/Fonts bleiben im Kern selbst Schätzungen und werden mit
        // „estimated“ geführt, nicht als measured ausgegeben.
        var bytesSavedJPEG: Int = 0
        /// Verlustfreier JPEG-Repack behaltener DCT-Streams (1b/6b) –
        /// gemessene Stream-Delta (original − repackte Bytes).
        var bytesSavedJPEGRepack: Int = 0
        var bytesSavedLosslessResize: Int = 0
        /// V2-3b – Exact-Palette-Ersatz (§9.6, verlustfrei).
        var bytesSavedIndexed: Int = 0
        /// CCITT G4 + verlustfreies JBIG2.
        var bytesSavedBilevel: Int = 0
        var bytesSavedCMYK: Int = 0
        /// Phase V2-7 – MRC-Seitenbündel (§13): Original-Raster gegen
        /// Layer-Bundle (Plan-Erwartung).
        var bytesSavedMRC: Int = 0
        /// Schätzung des Content-Hash-Dedup (aus dem C-Kern).
        var bytesSavedDedup: Int = 0
        /// Schätzung Font-Dedup/GC (aus dem C-Kern).
        var bytesSavedFonts: Int = 0
        /// Zopfli-Repack großer Flate-Streams (gemessene Stream-Delta).
        var bytesSavedFlateRepack: Int = 0
        /// V2-8 (§14.4) – selektives Font-Subsetting (einzeln QA-geprüft).
        var bytesSavedSelectiveFontSubset: Int = 0
        /// V2-8 (§14.6) – Resource GC (Rohbytes entferuter Map-Einträge).
        var bytesSavedResourceGC: Int = 0
        /// Content-Minify (Whitespace/Zahlen/leere q Q – kodierte Delta).
        var bytesSavedContentMinify: Int = 0
        /// Struktur-Pass – vom AUFRUFER gesetzt (der Pass läuft im
        /// Compressor, nicht im Executor); Differenz der Stufendateien.
        var bytesSavedStructure: Int = 0

        /// Summe aller Pass-Ersparnisse (jeweils `estimated`).
        var bytesSavedTotal: Int {
            bytesSavedJPEG + bytesSavedJPEGRepack + bytesSavedLosslessResize
                + bytesSavedIndexed + bytesSavedBilevel + bytesSavedCMYK
                + bytesSavedMRC
                + bytesSavedDedup + bytesSavedFonts
                + bytesSavedSelectiveFontSubset + bytesSavedResourceGC
                + bytesSavedContentMinify
                + bytesSavedFlateRepack + bytesSavedStructure
        }
    }

    enum ExecutionError: LocalizedError {
        case payloadUnavailable(PDFObjectID)
        case bridgeRejected(PDFObjectID)

        var errorDescription: String? {
            switch self {
            case .payloadUnavailable(let id):
                return String(localized: "Bilddaten für Objekt \(id) konnten nicht erzeugt werden.")
            case .bridgeRejected(let id):
                return String(localized: "Objekt \(id) ist nicht sicher ersetzbar.")
            }
        }
    }

    /// Wendet den Plan auf ein geöffnetes Dokument an und speichert nach
    /// `outputURL`. Das Originaldokument wird nie verändert (Masterplan 2.3):
    /// `document` ist ein eigenes Handle, gespeichert wird über Temp + Rename.
    ///
    /// Phase V2-1: `stageTimer` sammelt Stufenzeiten (§7.3), `isolation`
    /// schreibt Zwischenstände nach den Pass-Grenzen (§7.7). Beide sind
    /// optional und nil im Produktionslauf – reine Telemetrie.
    ///
    /// Phase V2-9 (§15.6): `singleWrite` schaltet den EINEN finalen Write
    /// mit Writer-Optionen frei (über `singleWriteRequested`, §15.6/§15.7).
    static func execute(plan: CompressionPlan,
                        artifacts: CompressionPlanArtifacts,
                        document: PDFCoreDocument,
                        pixels: ImagePixelSource,
                        resources: [PDFImageResource],
                        outputURL: URL,
                        isCancelled: (() -> Bool)? = nil,
                        progress: ((Double) -> Void)? = nil,
                        stageTimer: StageTimer? = nil,
                        isolation: CompressionIsolation? = nil,
                        singleWrite: Bool = false) throws -> Result {

        let resourcesByID = Dictionary(uniqueKeysWithValues:
            resources.map { ($0.objectID, $0) })
        var replaced = 0
        var cmykReencoded = 0
        var mrcPages = 0
        var rejected: [PDFObjectID] = []
        // Phase V2-9 (§15.6) – Ergebnis des Single-Write-Pfads (Telemetrie).
        var singleWriteUsed = false
        let transformable = plan.transformedActions
        // Phase V2-1 – Pass-Attribution je Bildaktion (estimated).
        var savedJPEG = 0
        var savedLossless = 0
        var savedIndexed = 0
        var savedBilevel = 0
        var savedCMYK = 0
        var savedMRC = 0

        try StageTimer.run(stageTimer, .executionMs) {
        for (index, action) in transformable.enumerated() {
            if let isCancelled, isCancelled() { throw CancellationError() }
            progress?(Double(index) / Double(max(transformable.count, 1)))
            // Wie im Planner: Bilddaten je Aktion freigeben, nicht erst am
            // Ende des Dokuments.
            try autoreleasepool {

            guard let resource = resourcesByID[action.objectID] else {
                // Der Plan nennt ein Objekt, das das Dokument nicht kennt.
                // Das ist ein Konsistenzfehler, kein Grund zum Weitermachen.
                throw ExecutionError.payloadUnavailable(action.objectID)
            }

            let (payload, globals) = try payloadData(for: action,
                                                     resource: resource,
                                                     artifacts: artifacts,
                                                     pixels: pixels,
                                                     backend: plan.jpegBackend)

            do {
                switch action {
                case .keep:
                    // Kann nicht auftreten: `transformedActions` filtert
                    // Keep-Aktionen bereits heraus. Der Fall steht nur da,
                    // damit das switch vollständig bleibt.
                    return                // `decodeApplied` ist eine ERKLÄRUNG an die Bridge: Die
                // übergebenen Bytes tragen die fertigen Farbwerte, ein
                // vorhandenes /Decode ist beim Dekodieren angewendet worden.
                // Ohne sie verweigert die Bridge die Ersetzung – zweite
                // Verteidigungslinie gegen ein unangewendetes /Decode, das
                // Bilder umkehren würde.
                case .jpeg(let objectID, let target, _, let grayscale, _, _, _):
                    try document.replaceImage(objectID: objectID,
                                              jpegData: payload,
                                              newWidth: target.width,
                                              newHeight: target.height,
                                              grayscale: grayscale,
                                              decodeApplied: resource.hasDecodeArray)
                case .cmykJpegReencode(let objectID, let target, _, _, _):
                    // Phase 6C – die Bridge trägt DeviceCMYK bzw. den
                    // ICCBased-4-Farbraum der Quelle über die Ersetzung.
                    try document.replaceImageCMYK(objectID: objectID,
                                                  jpegData: payload,
                                                  newWidth: target.width,
                                                  newHeight: target.height,
                                                  decodeApplied: resource.hasDecodeArray)
                    cmykReencoded += 1
                case .losslessResize(let objectID, let target, let grayscale, _, _, let predictor):
                    // Die Komponentenzahl folgt dem Farbraum der Quelle, damit
                    // ein CMYK-Bild vierkanalig bleibt.
                    let components = grayscale
                        ? 1 : (resource.colorSpace.componentCount ?? 3)
                    try document.replaceImageLossless(objectID: objectID,
                                                      flateData: payload,
                                                      width: target.width,
                                                      height: target.height,
                                                      components: components,
                                                      predictor: predictor,
                                                      decodeApplied: resource.hasDecodeArray)
                case .indexed(let objectID, let target, let bpc,
                              let paletteComponents, let palette, _, _, _, _):
                    // V2-3b (§9.6) – die Indizes kommen als Flate+Prädiktor-
                    // Strom, die Palette aus dem Plan; die Bridge baut
                    // /ColorSpace [/Indexed …] und /DecodeParms. Exakt und
                    // quantisiert teilen sich das Format (nur die Herkunft
                    // der Palette unterscheidet sich).
                    try document.replaceImageIndexed(objectID: objectID,
                                                     indexData: payload,
                                                     paletteData: palette,
                                                     width: target.width,
                                                     height: target.height,
                                                     bitsPerComponent: bpc,
                                                     paletteComponents: paletteComponents,
                                                     decodeApplied: resource.hasDecodeArray)
                case .ccittG4(let objectID, _, _):
                    // Phase 2b – Bilevel behält seine Maße; die Bridge schreibt
                    // BitsPerComponent 1, DeviceGray und die /BlackIs1-
                    // DecodeParms der Phase-2b-Konvention.
                    try document.replaceImageCCITT(objectID: objectID,
                                                   g4Data: payload,
                                                   width: resource.width,
                                                   height: resource.height)
                case .jbig2(let objectID, _, _):
                    // Globals legt die Bridge als eigenes indirektes
                    // Stream-Objekt an und verdrahtet /JBIG2Globals.
                    try document.replaceImageJBIG2(objectID: objectID,
                                                   pageData: payload,
                                                   globalsData: globals ?? Data(),
                                                   width: resource.width,
                                                   height: resource.height)
                case .mrc(_, let descriptor, _, _):
                    // Phase V2-7 (§13.7) – Seitenrekonstruktion über die
                    // Bridge: BG + Photos + FG-Maske ersetzen den Raster-Draw,
                    // OCR-/Text-Operatoren und Annotationen bleiben. Der
                    // Original-Raster verwaist (Resource-Eintrag entfernt)
                    // und wird vom Writer verworfen.
                    try MRCPageRewriter.applyBundle(
                        document, pageIndex: descriptor.pageIndex,
                        descriptor: descriptor, bundle: payload)
                    mrcPages += 1
                }
                replaced += 1
                // Plan-Erwartung der Ersparnis – nur ERSETZTE Bilder zählen.
                if let expected = action.expectedEncodedBytes {
                    let saved = max(0, action.originalEncodedBytes - expected)
                    switch action {
                    case .jpeg: savedJPEG += saved
                    case .losslessResize: savedLossless += saved
                    case .indexed: savedIndexed += saved
                    case .ccittG4, .jbig2: savedBilevel += saved
                    case .cmykJpegReencode: savedCMYK += saved
                    case .mrc: savedMRC += saved
                    case .keep: break
                    }
                }
            } catch PDFCoreError.checkFailed {
                // Die Bridge hat die Ersetzung verweigert (z. B. Maske, die
                // der Planner nicht gesehen hat). Das Dokument bleibt intakt,
                // aber der Plan war falsch – wird oben gemeldet.
                rejected.append(action.objectID)
            }
            }
        }
        }

        // Phase 1b – verlustfreier Repack (jpegtran-Semantik) für behaltene
        // DCT-Streams. Transformierte Bilder kommen bereits aus mozjpeg und
        // werden nicht doppelt angefasst.
        //
        // Phase 6b – der Pass ist farbraumagnostisch und damit für CMYK
        // OFFEN: jpeg_read/write_coefficients übernimmt die DCT-Koeffizienten
        // unabhängig von der Komponentenzahl und schreibt den Adobe-APP14-
        // Marker (inkl. Transform-Byte) automatisch. Verifiziert in
        // CMYKPipelineTests. Die Bedingung unten verlangt ausschließlich
        // DCTDecode (keine Vorfilter, keine unbekannten Filter) – genau die
        // Skip-Regel der Phase 6b.
        //
        // Skip-Regel: Bereits progressive Streams (SOF2) sind die Ziel-
        // verpackung – nichts zu tun. Never-Grow: Nicht kleiner → Bytes
        // bleiben, wie sie sind. Beides entscheidet der Repack selbst;
        // hier bleibt nur das Anwenden.
        //
        // Phase 3c – im Kompatibilitätsmodus nur optimize-only (Baseline):
        // progressive Scans sind der eine Verzicht, den alte Leser brauchen.
        // Die Ersparnis beider Verpackungen modelliert der Estimator über
        // `keptDCTRepackSaving`; das Unsicherheitsband schluckt die Streuung.
        let repackProgressive = plan.compatibilityPolicy != .maximum
        var repacked = 0
        var savedRepack = 0
        try StageTimer.run(stageTimer, .jpegRepackMs) {
        for resource in resources where resource.terminalFilter == .dct
                                            && resource.unknownFilters.isEmpty
                                            && resource.filters == [.dct] {
            if let isCancelled, isCancelled() { throw CancellationError() }
            if plan.action(for: resource.objectID)?.transformsImage == true { continue }
            guard let original = document.imageStreamData(objectID: resource.objectID,
                                                          decoded: false) else { continue }
            guard case .repacked(let data) = JPEGEncoder.repack(
                original, progressive: repackProgressive) else { continue }
            // Ein Verweigern der Bridge ist hier kein Planfehler, sondern
            // Teil der Sicherheitsleiter: Dann bleiben die Originalbytes.
            do {
                try document.replaceImageStreamBytes(objectID: resource.objectID,
                                                     data: data)
                repacked += 1
                // Gemessenes Stream-Delta – nie negativ (Never-Grow).
                savedRepack += max(0, original.count - data.count)
            } catch PDFCoreError.checkFailed, PDFCoreError.internalError {
                continue
            }
        }
        }

        // Phase 3-Followup – Zopfli-Repack großer Flate-Streams, NUR im
        // Max-Preset (flatePolicy .maximum). Verlustfrei: Der Pass operiert
        // auf der rohen zlib-Stufe (inflate + Zopfli-DEFLATE); dekodierte
        // Bytes und der Predictor im Wörterbuch bleiben unverändert. Parallel
        // läuft ausschließlich die reine Byteschnur – das Dokument-Handle
        // wird seriell bedient.
        var zopfliRepacked = 0
        var zopfliSaved = 0
        if plan.flatePolicy == .maximum {
            try StageTimer.run(stageTimer, .zopfliRepackMs) {
                (zopfliRepacked, zopfliSaved) = try CompressionExecutor.zopfliRepackStreams(
                    document: document, isCancelled: isCancelled)
        }
        }

        // Mehrfach identisch gespeicherte Bilder zusammenführen.
        //
        // NACH der Umwandlung, aus zwei Gründen: Zum einen erwischt es damit
        // auch Bilder, die erst durch unsere Transformation identisch werden
        // – zwei gleiche Vorlagen ergeben bei gleichen Parametern dieselbe
        // Ausgabe. Zum anderen ist es hier verlustfrei; es wird kein Byte
        // neu kodiert, nur ein Verweis umgehängt.
        //
        // Über den Korpus gemessen liegen so 30 MB doppelt im Bestand, also
        // 8 % aller Bilddaten – wiederholte Logos, Hintergründe, Diagramme.
        let mergedImages = StageTimer.run(stageTimer, .dedupMs) {
            plan.dedupPolicy == .off
                ? 0 : ((try? document.deduplicateImages()) ?? 0)
        }

        // Phase 3b – Content-Hash-Dedup über ALLE indirekten Objekte:
        // Streams bei identischen dekomprimierten Bytes + whitelist-gleichen
        // Dicts (JBIG2Globals-Kandidaten und ObjStm schließt der C-Kern aus),
        // Dicts/Arrays bei kanonisch gleicher Form. Nach den Bild-
        // transformationen, vor dem finalen Write-Pass – dadurch erwischt er
        // auch Inhalte, die erst durch gleiche Transformationen identisch
        // wurden. Verlustfrei, Never-Grow implizit: Der Pass hängt nur
        // Referenzen um, verwaiste Objekte verwirft der Writer.
        var dedupStreams = 0
        var dedupObjects = 0
        var dedupBytes = 0
        if plan.dedupPolicy != .off {
            let stats = StageTimer.run(stageTimer, .dedupMs) {
                (try? document.deduplicate()) ?? PDFCoreDedupStats(
                    mergedStreams: 0, mergedObjects: 0, estimatedBytesSaved: 0)
            }
            dedupStreams = stats.mergedStreams
            dedupObjects = stats.mergedObjects
            dedupBytes = stats.estimatedBytesSaved
        }

        // Phase V2-1 §7.7 – Isolation-Stufe nach den Dedup-Eingriffen.
        if let isolation {
            isolation.recordDocument(
                document: document, stage: "20_dedup",
                qpdfPath: Compressor.findQPDF())
        }

        // Phase 5a – Font-Attribution: Dedup getrennter Font-Objekte mit
        // identischem FontProgramm plus GC unbenutzter Font-Einträge.
        //
        // Reihenfolge (bewusst): NACH den Bildtransformationen und NACH dem
        // Content-Hash-Dedup, VOR Metadaten und Write-Pass. Der Document-
        // Dedup fasst kanonisch identische Objekte zuerst zusammen; der
        // Font-Pass sieht dadurch den Endzustand der Referenzen und dupli-
        // ziert keine Arbeit. Spätere Schritte (Metadatenpolitik, Producer)
        // fassen keine Fonts mehr an – die Tf-Usage-Fakten der GC bleiben
        // bis zum Schreiben gültig. Verlustfrei: Gemerged wird nur bei
        // identischem FontFile-Hash UND gleicher semantischer Dict-Form,
        // die GC trägt nur Einträge ohne Tf-Nutzung; unscanbare Contents
        // schützen ihre ganze Map, /AcroForm/DR und Type3-Fonts bleiben
        // stehen. Never-Grow implizit: es wird nur umgehängt und getragen,
        // verwaiste Objekte verwirft der Writer.
        var fontStats = PDFCoreFontAuditStats(
            fontObjects: 0, fontFileStreams: 0, duplicateFontRefsRemoved: 0,
            unusedFontsRemoved: 0, estimatedBytesSaved: 0)
        if plan.fontPolicy != .off {
            fontStats = StageTimer.run(stageTimer, .fontMs) {
                (try? document.auditFonts()) ?? PDFCoreFontAuditStats(
                    fontObjects: 0, fontFileStreams: 0,
                    duplicateFontRefsRemoved: 0, unusedFontsRemoved: 0,
                    estimatedBytesSaved: 0)
            }
        }

        // Phase 5b / V2-8 (§14.1/§14.4) – Font-Subsetting: immer der LETZTE
        // Font-Eingriff, nach Dedup und GC.
        //
        // Seit V2-11 gibt es nur den SELEKTIVEN Weg (§4.18): Der Plan trägt
        // fontSubsets (Candidate-Entscheidungen, Aktivierungspolitik §14.3)
        // – subsettet wird einzeln je Font mit je-Font-QA; ein Fail rollt
        // NUR diesen Font zurück (keep), nie das Dokument. Der frühere
        // globale Snapshot-Rollback-Pass (fontSubsettingPolicy .on) ist
        // entfernt; die Politik gate't heute die fontSubsets-Entscheidung im
        // Planner. fontPolicy .off trägt ebenfalls keine Subsets.
        var activeDocument = document
        var selective = FontOptimizer.Outcome(document: document)
        if !plan.fontSubsets.isEmpty {
            selective = try StageTimer.run(stageTimer, .fontMs) {
                try FontOptimizer.applySelectiveSubsetting(
                    document: activeDocument, decisions: plan.fontSubsets)
            }
            activeDocument = selective.document
        }

        // V2-8 (§14.6) – Resource GC: NACH dem Font-Pass, mit Politik .auto.
        // Der traceVersion-Check bleibt als Absicherung der
        // Plan-Konsistenz (der Plan trägt die Politik nur im Candidate-
        // Pfad). Trägt unbenutzte Einträge aus den Resource-Maps; die
        // MRC-/Bild-Rekonstruktion liegt vor diesem Punkt, ihre neuen
        // XObjects sind via Do benutzt und geschützt.
        var gcStats = PDFCoreResourceGCStats()
        if plan.traceVersion >= 2 && plan.resourceGCPolicy == .auto {
            gcStats = StageTimer.run(stageTimer, .resourceGCMs) {
                (try? activeDocument.removeUnusedResources())
                    ?? PDFCoreResourceGCStats()
            }
        }

        // Seiten-Thumbnails (/Thumb): NACH GC, VOR Metadaten/Write. Immer
        // aktiv, keine Politik – reine Vorschaubilder, kein Inhalt. Der
        // Validator prüft sie nicht (kein Snapshot-Feld), qpdf --check
        // bleibt grün, verwaiste Streams verwirft der Writer (Never-Grow).
        var removedThumbs = 0
        if plan.traceVersion >= 2 {
            removedThumbs = StageTimer.run(stageTimer, .resourceGCMs) {
                (try? activeDocument.removePageThumbs()) ?? 0
            }
        }

        // Content-Minify: NACH Thumbs, VOR Metadaten/Write. Immer aktiv im
        // traceVersion-2-Plan – Whitelist-regeln im C-Kern, Never-Grow pro
        // Stream, Validator (Text/Render) fängt jede Abweichung fail-closed.
        var minifiedStreams = 0
        var minifiedSaved = 0
        if plan.traceVersion >= 2 {
            let stats = StageTimer.run(stageTimer, .resourceGCMs) {
                (try? activeDocument.minifyContentStreams()) ?? (streams: 0, savedBytes: 0)
            }
            minifiedStreams = stats.streams
            minifiedSaved = stats.savedBytes
        }

        // Phase V2-1 §7.7 – Isolation-Stufe nach den Font-Eingriffen.
        if let isolation {
            isolation.recordDocument(
                document: activeDocument, stage: "30_fonts",
                qpdfPath: Compressor.findQPDF())
        }

        // Metadatenpolitik (Finding 12) – erreicht den Writer jetzt wirklich.
        switch plan.metadataPolicy {
        case .preserve:
            break
        case .strip:
            try activeDocument.stripMetadata(keepProducer: true)
        }

        // Producer als LETZTER Schritt, damit er auch nach dem Strippen steht.
        activeDocument.setProducer("PDFTools")

        // Phase V2-1 §7.7 – Isolation-Stufe nach Metadaten/Producer.
        if let isolation {
            isolation.recordDocument(
                document: activeDocument, stage: "40_metadata",
                qpdfPath: Compressor.findQPDF())
        }

        try StageTimer.run(stageTimer, .writeMs) {
            if singleWrite {
                // Phase V2-9 (§15.6) – EIN Write: die Writer-Optionen tragen
                // exakt die Struktur-Pass-Flags des Plans (object streams
                // generate/disable, Flate-Rekompression Level 9, Linearize).
                // Metadaten/Producer sind oben am Dokument geschehen. Flate-
                // Maximum (Zopfli) fällt AUSSERHALB hier zurück auf den
                // Zwei-Write-Pfad (§15.7) – der Aufrufer reicht singleWrite
                // nur bei FlatePolicy .standard.
                try activeDocument.save(to: outputURL, options: PDFCoreSaveOptions(
                    objectStreamsGenerate: plan.compatibilityPolicy != .maximum,
                    recompressFlate: true,
                    compressionLevel: 9,
                    linearize: plan.linearizationPolicy == .fastWebView))
                singleWriteUsed = true
            } else {
                try activeDocument.save(to: outputURL)
            }
        }

        return Result(outputURL: outputURL,
                      replacedImages: replaced,
                      skippedImages: plan.keptActions.count,
                      rejectedByBridge: rejected,
                      mergedDuplicateImages: mergedImages,
                      repackedImages: repacked,
                      zopfliRepackedStreams: zopfliRepacked,
                      zopfliEstimatedBytesSaved: zopfliSaved,
                      cmykReencodedImages: cmykReencoded,
                      deduplicatedStreams: dedupStreams,
                      deduplicatedObjects: dedupObjects,
                      dedupEstimatedBytesSaved: dedupBytes,
                      auditedFontObjects: fontStats.fontObjects,
                      auditedFontFileStreams: fontStats.fontFileStreams,
                      deduplicatedFontRefs: fontStats.duplicateFontRefsRemoved,
                      removedUnusedFonts: fontStats.unusedFontsRemoved,
                      fontEstimatedBytesSaved: fontStats.estimatedBytesSaved,
                      selectiveSubsettedFonts: selective.subsetted,
                      selectiveRefusedFonts: selective.refused,
                      selectiveRolledBackFonts: selective.rolledBack,
                      selectiveFontSubsetEstimatedBytesSaved:
                          selective.estimatedBytesSaved,
                      selectiveFontOutcomes: selective.perFont,
                      resourceGCEntriesRemoved: gcStats.totalEntriesRemoved,
                      resourceGCEstimatedBytesSaved:
                          gcStats.estimatedBytesSaved,
                      removedPageThumbs: removedThumbs,
                      minifiedContentStreams: minifiedStreams,
                      mrcPages: mrcPages,
                      singleWriteUsed: singleWriteUsed,
                      bytesSavedJPEG: savedJPEG,
                      bytesSavedJPEGRepack: savedRepack,
                      bytesSavedLosslessResize: savedLossless,
                      bytesSavedIndexed: savedIndexed,
                      bytesSavedBilevel: savedBilevel,
                      bytesSavedCMYK: savedCMYK,
                      bytesSavedMRC: savedMRC,
                      bytesSavedDedup: dedupBytes,
                      bytesSavedFonts: fontStats.estimatedBytesSaved,
                      bytesSavedFlateRepack: zopfliSaved,
                      bytesSavedSelectiveFontSubset:
                          selective.estimatedBytesSaved,
                      bytesSavedResourceGC: gcStats.estimatedBytesSaved,
                      bytesSavedContentMinify: minifiedSaved)
    }

    // MARK: - Phase 3-Followup – Zopfli-Repack

    /// Schwellwerte des Passes: Erst ab 64 KB Rohgröße lohnt Zopfli (die
    /// ~1000× höhere Laufzeit), und der Inhalt je Stream wie die Summe der
    /// gleichzeitig vorgehaltenen Inhalte ist gedeckelt – ein kleiner
    /// zlib-Strom kann beim Inflate gigantisch aufblähen. Größere Inhalte
    /// überspringt der Pass bewusst: Bei Dokumenten dieser Größenklasse
    /// liegt der Gewinn ohnehin bei 6a/6b und dem Struktur-Pass.
    static let zopfliMinimumRawBytes = 64 * 1024
    static let zopfliMaximumContentBytes = 16 * 1024 * 1024
    static let zopfliContentBudgetBytes = 64 * 1024 * 1024
    /// 2–4 parallele zopfli-Kodierer; darüber streiten die Kerne mit den
    /// (seriellen) Restarbeiten.
    static let zopfliConcurrencyLimit = 3

    /// Repackt alle Flate-Streams, deren Zopfli-Verpackung kleiner ist.
    /// Rückgabe: (repackete Streams, gesparte Rohbytes).
    private static func zopfliRepackStreams(document: PDFCoreDocument,
                                            isCancelled: (() -> Bool)?)
        throws -> (repacked: Int, saved: Int) {
        let candidates = try document.flateStreams(
            minimumRawBytes: zopfliMinimumRawBytes)
        guard !candidates.isEmpty else { return (0, 0) }

        // Seriell: Rohbytes holen und inflate. Das Handle bleibt unter uns.
        var contents: [(PDFCoreFlateStream, Data)] = []
        var budget = zopfliContentBudgetBytes
        for candidate in candidates {
            if let isCancelled, isCancelled() { throw CancellationError() }
            guard budget > 0 else { break }
            guard let raw = document.streamBytes(objectID: candidate.objectID),
                  let content = ZopfliCodec.inflate(
                      raw, maxContentBytes: zopfliMaximumContentBytes) else { continue }
            guard content.count <= budget else { continue }
            budget -= content.count
            contents.append((candidate, content))
        }
        guard !contents.isEmpty else { return (0, 0) }

        // Parallel: reine Byteschnur, gleitendes Fenster über Semaphore.
        // Serielle Queue je Stream statt einer konkurrenten: nur serielle
        // Queues laufen auf dem Overcommit-Pool (siehe
        // CompressionPlanner.generateCandidateEntries – Deadlock-Befund).
        let slots = DispatchSemaphore(value: zopfliConcurrencyLimit)
        let group = DispatchGroup()
        let lock = NSLock()
        var compressed: [PDFObjectID: Data] = [:]
        for (candidate, content) in contents {
            group.enter()
            slots.wait()
            DispatchQueue(label: "pdfcore.zopfli-repack").async {
                defer { slots.signal(); group.leave() }
                guard let data = ZopfliCodec.compress(content) else { return }
                lock.lock()
                compressed[candidate.objectID] = data
                lock.unlock()
            }
        }
        group.wait()

        // Seriell: zurücksetzen – NUR wenn kleiner (Never-Grow). Die Bridge
        // verweigert zusätzlich selbst alles außer reinen Flate-Streams.
        var repacked = 0
        var saved = 0
        for (candidate, _) in contents {
            if let isCancelled, isCancelled() { throw CancellationError() }
            guard let data = compressed[candidate.objectID],
                  data.count < candidate.rawByteCount else { continue }
            do {
                try document.replaceFlateStreamBytes(objectID: candidate.objectID,
                                                     data: data)
            } catch PDFCoreError.checkFailed, PDFCoreError.internalError {
                continue
            }
            repacked += 1
            saved += candidate.rawByteCount - data.count
        }
        return (repacked, saved)
    }

    // MARK: - Phase 5b/V2-8 – Font-QA

    /// Die je-Font-QA des selektiven Subsettings lebt in
    /// `FontOptimizer.fontQAPasses` (Text-Fingerprints dokumentweit,
    /// Never-Grow, Render-Stichprobe je Font – §14.4). Der frühere globale
    /// Snapshot-Gate-Pass (`subsetGatePasses`/`applyFontSubsetting`) ist mit
    /// dem V2-Cutover entfernt (§4.18).

    /// Liefert die Bytes für eine Aktion: bevorzugt die beim Planen erzeugten,
    /// sonst deterministisch aus denselben Planparametern neu kodiert.
    /// JBIG2-Aktionen tragen zusätzlich die Globals (oder nil).
    private static func payloadData(for action: ImageCompressionAction,
                                    resource: PDFImageResource,
                                    artifacts: CompressionPlanArtifacts,
                                    pixels: ImagePixelSource,
                                    backend: JPEGBackend) throws -> (Data, Data?) {
        if let cached = artifacts.payload(for: action.objectID) {
            return (cached, artifacts.globals(for: action.objectID))
        }

        // Phase 2b – Bilevel deterministisch neu erzeugen: dieselbe
        // Pufferherleitung wie beim Planen, dann derselbe Kodierer.
        switch action {
        case .ccittG4, .jbig2:
            guard let buffer = BilevelSource.buffer(for: resource, pixels: pixels) else {
                throw ExecutionError.payloadUnavailable(action.objectID)
            }
            if case .ccittG4 = action {
                guard let data = BilevelCodec.encodeG4(buffer) else {
                    throw ExecutionError.payloadUnavailable(action.objectID)
                }
                return (data, nil)
            }
            guard let encoded = BilevelCodec.encodeJBIG2(buffer) else {
                throw ExecutionError.payloadUnavailable(action.objectID)
            }
            return (encoded.page, encoded.globals)
        case .mrc(_, let descriptor, _, _):
            // Phase V2-7 – Bundle deterministisch regenerieren (dieselbe
            // Segmentierung + Kodierung wie in der Planung), wenn die
            // Payload nicht überlebt hat (Budget/Metadata-only).
            guard let bundle = MRCPageRewriter.regenerateBundle(
                descriptor: descriptor, resource: resource, pixels: pixels)
            else {
                throw ExecutionError.payloadUnavailable(action.objectID)
            }
            return (bundle, nil)
        default:
            break
        }

        // Die Komponentenzahl muss hier DIESELBE sein wie beim Planen –
        // sonst schreibt der Executor RGB-Bytes in ein Objekt, das als CMYK
        // deklariert wird, und das Bild wäre unbrauchbar.
        let components = action.grayscale
            ? 1 : (resource.colorSpace.componentCount ?? 3)

        guard let target = action.targetSize,
              let image = pixels.decodedImage(for: resource, target: target),
              let resized = ImageResampler.resize(image, to: target,
                                                  components: components) else {
            throw ExecutionError.payloadUnavailable(action.objectID)
        }

        switch action {
        case .jpeg(_, _, let quality, _, _, _, _):
            // Dasselbe Backend wie beim Planen – es kommt über den Plan
            // (`backend`), sonst lieferte der Fallback andere Kandidaten
            // als die Schätzung annahm.
            guard let data = ImageResampler.encodeJPEG(resized, quality: quality,
                                                       backend: backend) else {
                throw ExecutionError.payloadUnavailable(action.objectID)
            }
            return (data, nil)
        case .cmykJpegReencode(_, _, let quality, _, _):
            // Phase 6C – derselbe deterministische Umlauf wie beim Planen:
            // CMYK-Resample (oben), 4-Kanal-Pixelbuffer, YCCK-Kodierer des
            // Shims. Das ΔE-Gate ist Planner-Sache; hier entstehen dieselben
            // Bytes.
            guard let cmykPixels = ImageResampler.rawBitmap(resized, components: 4),
                  let data = JPEGEncoder.encodeCMYK(pixels: cmykPixels,
                                                    width: resized.width,
                                                    height: resized.height,
                                                    quality: quality) else {
                throw ExecutionError.payloadUnavailable(action.objectID)
            }
            return (data, nil)
        case .losslessResize(_, _, _, _, _, let predictor):
            // Deterministische Rekodierung wie beim Planen: derselbe Race –
            // Predictor-Entscheidung steht in der Aktion, Bytes sind damit
            // identisch zur Planung (Finding 11).
            if predictor {
                guard let data = ImageResampler.encodeLossless(
                    resized, components: components) else {
                    throw ExecutionError.payloadUnavailable(action.objectID)
                }
                return (data, nil)
            }
            guard let raw = ImageResampler.rawBitmap(resized, components: components),
                  let data = ImageProcessor.flateBest(raw) else {
                throw ExecutionError.payloadUnavailable(action.objectID)
            }
            return (data, nil)
        case .indexed(_, let target, _, let paletteComponents, _, _, _, let quantized, let dithered):
            // V2-3b – deterministischer Neuaufbau wie beim Planen: dieselbe
            // Pixelherleitung (oben), derselbe Scan aus EINEM Lauf, damit
            // Palette und Indizes zueinander passen. Exakt wie quantisiert
            // (Median-Cut + Dithering-Flag aus der Aktion) sind
            // deterministisch – das Ergebnis ist identisch zur Planung
            // (Finding 11).
            guard target.pixelCount <= PaletteOptimizer.fullVerificationPixelCap else {
                throw ExecutionError.payloadUnavailable(action.objectID)
            }
            if quantized {
                // Quantisiert braucht RGB (der exakte Pfad deckt Grau ab).
                guard paletteComponents == 3,
                      case .success(let encoded) = PaletteOptimizer.encodeQuantized(
                          resized, dither: dithered) else {
                    throw ExecutionError.payloadUnavailable(action.objectID)
                }
                return (encoded.indexStream, nil)
            }
            guard case .success(let encoded) = PaletteOptimizer.encodeExact(
                resized, components: paletteComponents) else {
                throw ExecutionError.payloadUnavailable(action.objectID)
            }
            return (encoded.indexStream, nil)
        case .keep, .ccittG4, .jbig2, .mrc:
            // .mrc wurde im Bilevel-Zweig oben behandelt (Regeneration) und
            // ist nur hier gelistet, damit der switch vollständig bleibt.
            throw ExecutionError.payloadUnavailable(action.objectID)
        }
    }
}

// MARK: - Pixelquelle über libqpdf

/// Holt Bildpixel aus einem geöffneten Dokument – über die Objektidentität,
/// nie über Seitenrendering.
///
/// Für DCT-Bilder werden die rohen JPEG-Bytes durchgereicht (ImageIO dekodiert
/// sie). Für Flate/LZW/RunLength liefert libqpdf die dekodierten Bytes, aus
/// denen hier ein echtes `CGImage` gebaut wird – Breite, Höhe,
/// BitsPerComponent und Farbraum kommen aus dem Bilddictionary. Für JPX
/// liefert der OpenJPEG-Shim (`JPXDecoder`) die Pixel; die Farbwelt stammt
/// aus dem PDF-/ColorSpace, denn der Codestream trägt sie nicht verlässlich.
///
/// Was nicht vollständig dekodiert werden kann, liefert `nil`. Es wird
/// niemals ersatzweise die Seite gerendert (Masterplan Finding 15).
struct LibQPDFPixelSource: ImagePixelSource {
    let document: PDFCoreDocument

    func decodedImage(for resource: PDFImageResource) -> CGImage? {
        switch resource.terminalFilter {
        case .dct:
            guard let data = document.imageStreamData(objectID: resource.objectID,
                                                      decoded: false) else { return nil }
            return ImageResampler.decodeJPEG(data)
        case .flate, .lzw, .runLength, nil:
            guard let data = document.imageStreamData(objectID: resource.objectID,
                                                      decoded: true) else { return nil }
            return Self.bitmap(from: data, resource: resource)

        case .jpx:
            return jpxImage(resource: resource, reduce: 0)

        case .ccitt:
            // V2-3c (§9.10) – CCITT-Eingang über den eigenen Fax-Shim.
            // Die regulären Pfade erreichen das nie (die Capability-Sperre
            // für CCITTFaxDecode bleibt; das trueBilevel-Bild läuft vor ihr
            // über den Bilevel-Race) – die Quelle liefert die Pixel dennoch
            // vollständig, damit Klassifikation und Tests denselben Weg
            // nehmen wie für JPX. Nicht abgedeckte DecodeParms → nil.
            return ccittGrayImage(resource: resource)

        case .jbig2, .ascii85, .asciiHex, .crypt:
            // Kein verlässlicher XObject-Decoder – bewusst kein Versuch.
            // (Phase 2b: eigene CCITT/JBIG2-Outputs laufen hier nie ein,
            // sie scheitern schon an der Capability-Sperre; JBIG2-Input
            // bleibt ohne Dekodierer, TODO siehe PDFImageDomain.)
            return nil
        }
    }

    /// Phase 6C – rohe Stream-Bytes (bei DCTDecode: JPEG) für die
    /// Größenbarriere der CMYK-Race.
    func rawImageData(for resource: PDFImageResource) -> Data? {
        document.imageStreamData(objectID: resource.objectID, decoded: false)
    }

    func decodedStreamData(for resource: PDFImageResource) -> Data? {
        document.imageStreamData(objectID: resource.objectID, decoded: true)
    }

    /// Phase 4b – JPX-Input-Decode über den OpenJPEG-Shim.
    ///
    /// Nur der reine JPX-Stream wird angenommen: `imageStreamData(decoded: false)`
    /// liefert die ROHEN Bytes – ein ASCII85/Flate-Vorfilter würde an der
    /// Codestream-Signatur scheitern und deterministisch KEEP ergeben (selten,
    /// dokumentierte Phase-4b-Grenze). Die Komponentenzahl muss zum
    /// PDF-/ColorSpace passen; der Rastervergleich gegen die erwarteten
    /// Masse verhindert, dass ein Dekodierergebnis im falschen Format
    /// interpretiert wird.
    private func jpxImage(resource: PDFImageResource, reduce: Int) -> CGImage? {
        guard resource.filters == [.jpx],
              resource.colorSpace.isDirectlyRenderable,
              let expectedComponents = resource.colorSpace.componentCount,
              let data = document.imageStreamData(objectID: resource.objectID,
                                                  decoded: false) else { return nil }
        guard let decoded = JPXDecoder.decode(data, reduce: reduce) else { return nil }
        guard decoded.components == expectedComponents,
              decoded.width == Self.reducedEdge(resource.width, reduce: reduce),
              decoded.height == Self.reducedEdge(resource.height, reduce: reduce)
        else { return nil }
        return Self.bitmap(from: decoded.pixels,
                           width: decoded.width,
                           height: decoded.height,
                           resource: resource)
    }

    /// ceil(edge / 2^reduce) – die Rastergröße, die cp_reduce erwartet.
    private static func reducedEdge(_ edge: Int, reduce: Int) -> Int {
        (edge + (1 << reduce) - 1) >> reduce
    }

    /// V2-3c (§9.10) – CCITT-Eingang dekodieren und auf 8-bit DeviceGray
    /// heben (Tinte = 0, Papier = 255). NUR mit vollständig abgedeckten
    /// DecodeParms (`acceptanceIssue`), sonst nil – deterministisch KEEP.
    private func ccittGrayImage(resource: PDFImageResource) -> CGImage? {
        guard resource.filters == [.ccitt],
              resource.bitsPerComponent == 1,
              let parms = document.ccittDecodeParms(objectID: resource.objectID),
              parms.acceptanceIssue(expectedWidth: resource.width,
                                    expectedHeight: resource.height) == nil,
              let data = document.imageStreamData(objectID: resource.objectID,
                                                  decoded: false),
              let buffer = BilevelCodec.decodeCCITT(
                  data, parms: parms,
                  width: resource.width, height: resource.height)
        else { return nil }
        return Self.grayImage(fromInkBits: buffer)
    }

    /// Bilevel-Puffer (Bit 1 = Tinte, MSB-first) → 8-bit DeviceGray.
    static func grayImage(fromInkBits buffer: BilevelBuffer) -> CGImage? {
        let width = buffer.width, height = buffer.height
        var pixels = Data(count: width * height)
        let rowBytes = BilevelBuffer.rowBytes(width: width)
        pixels.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) in
            guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            buffer.data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) in
                guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return }
                for y in 0..<height {
                    let row = src + y * rowBytes
                    let out = dst + y * width
                    for x in 0..<width {
                        let ink = (row[x >> 3] >> UInt8(7 - (x & 7))) & 1
                        out[x] = ink == 1 ? 0 : 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(
                           rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// cp_reduce (Phase 4b): N dekodiert JPX direkt auf 1/2^N. Genutzt wird
    /// das NUR, wenn das reduzierte Raster das Ziel noch vollständig abdeckt
    /// – sonst wäre der weitere Resize ein Upscale mit Qualitätsverlust.
    /// Planung und Ausführung rufen mit DEMSELBEN Ziel an, deshalb liefern
    /// beide dieselben Pixel (Determinismus des Plans, Finding 11).
    func decodedImage(for resource: PDFImageResource, target: PixelSize) -> CGImage? {
        guard resource.terminalFilter == .jpx,
              target.width > 0, target.height > 0 else {
            return decodedImage(for: resource)
        }
        let reduce = Self.reduceLevel(resource: resource, target: target)
        guard reduce > 0 else { return decodedImage(for: resource) }
        return jpxImage(resource: resource, reduce: reduce)
    }

    /// V2-Maps-Perf – die Ebene des Raster-Caches IST die cp_reduce-Stufe:
    /// Sie bestimmt die Dekodierungsvariante vollständig (nicht-JPX immer 0).
    func decodeLevel(for resource: PDFImageResource, target: PixelSize) -> Int {
        guard resource.terminalFilter == .jpx,
              target.width > 0, target.height > 0 else { return 0 }
        return Self.reduceLevel(resource: resource, target: target)
    }

    /// Reduktionsstufe zu einem Ziel – dieselbe Schleife wie in
    /// `decodedImage(for:target:)`, damit Cache-Ebene und Dekodierung
    /// übereinstimmen (gebrochene Übereinstimmung wäre eine andere Raster-
    /// quelle und damit ein Determinismusbruch).
    static func reduceLevel(resource: PDFImageResource, target: PixelSize) -> Int {
        var reduce = 0
        while reduce < 5 {
            let next = reduce + 1
            if Self.reducedEdge(resource.width, reduce: next) < target.width
                || Self.reducedEdge(resource.height, reduce: next) < target.height {
                break
            }
            reduce = next
        }
        return reduce
    }

    /// Baut aus dekodierten Stream-Bytes ein CGImage.
    /// Stimmt die Byte-Anzahl nicht mit Breite × Höhe × Komponenten überein,
    /// wird abgebrochen: ein falsch interpretiertes Bild wäre schlimmer als
    /// ein übersprungenes.
    static func bitmap(from data: Data, resource: PDFImageResource) -> CGImage? {
        bitmap(from: data, width: resource.width, height: resource.height,
               resource: resource)
    }

    /// Variante mit expliziter Rastergröße – der JPX-Pfad dekodiert bei
    /// cp_reduce auf verkleinerte Masse, die nicht still dem Bilddictionary
    /// zugeordnet werden dürfen.
    static func bitmap(from data: Data, width: Int, height: Int,
                       resource: PDFImageResource) -> CGImage? {
        guard resource.bitsPerComponent == 8,
              let components = resource.colorSpace.componentCount,
              resource.colorSpace.isDirectlyRenderable else { return nil }

        let bytesPerRow = width * components
        let expected = bytesPerRow * height
        guard width > 0, height > 0, data.count >= expected else { return nil }

        // Der Farbraum folgt der Komponentenzahl. Vorher stand hier „grau
        // oder RGB" – für ein CMYK-Bild ergab das 32 Bit je Bildpunkt in
        // einem Dreikanalraum, und CoreGraphics lieferte gar kein Bild
        // zurück. Der Planner meldete dann „Pixel nicht dekodierbar", und
        // 42,4 MB CMYK im Korpus blieben unangetastet.
        let colorSpace: CGColorSpace
        switch components {
        case 1: colorSpace = CGColorSpaceCreateDeviceGray()
        case 4: colorSpace = CGColorSpaceCreateDeviceCMYK()
        default: colorSpace = CGColorSpaceCreateDeviceRGB()
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        // Überschüssige Bytes abschneiden – manche Writer padden den Stream.
        // `prefix` liefert eine Slice mit eigenem Startindex; sie wird in eine
        // eigenständige Data kopiert, bevor CoreGraphics sie übernimmt.
        let exact = Data(data.prefix(expected))
        guard let provider = CGDataProvider(data: exact as CFData) else { return nil }

        // Das /Decode-Array wird HIER angewendet, nicht ignoriert.
        //
        // Es bildet die Abtastwerte auf den Farbbereich ab; `[1 0 1 0 1 0]`
        // kehrt ein RGB-Bild um. CoreGraphics kann das übernehmen – dann
        // trägt das dekodierte Bild die fertigen Farbwerte, und das neue
        // Wörterbuch braucht kein /Decode mehr.
        //
        // Vorher wurden solche Bilder pauschal abgelehnt: 38 300 Bilder mit
        // zusammen 55,7 MB im Korpus, die Mehrzahl aller Bilder überhaupt.
        //
        // Nur bei passender Länge: Ein Array mit falscher Elementzahl wäre
        // ein defektes Dokument, und CoreGraphics würde es stillschweigend
        // anders auslegen als beabsichtigt.
        //
        // Und nur, wenn es überhaupt etwas bewirkt. Die überwiegende Mehrheit
        // der Arrays im Korpus ist die ausgeschriebene Vorgabe – sie bildet
        // jeden Wert auf sich selbst ab. Sie trotzdem zu übergeben wäre
        // wirkungslos, aber nicht folgenlos: Es hiesse, CoreGraphics für
        // nichts eine Umrechnung anzuvertrauen. `decode: nil` bedeutet
        // ohnehin genau diese Vorgabe.
        var decode: [CGFloat]?
        if resource.hasEffectiveDecodeArray,
           resource.decodeArray.count == components * 2 {
            decode = resource.decodeArray.map { CGFloat($0) }
        }

        return CGImage(width: width, height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8 * components,
                       bytesPerRow: bytesPerRow,
                       space: colorSpace,
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: decode,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
