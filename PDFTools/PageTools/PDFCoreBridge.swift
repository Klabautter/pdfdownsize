import Foundation
import CoreGraphics
import pdfcore

/// Swift-Brücke über die pdfcore-C-ABI (Monster Epic Phase 5/6).
/// Kein qpdf-C++-Symbol tritt hier hinaus; Fehler kommen als Code und werden
/// in typisierte Errors übersetzt.
enum PDFCoreError: Error, Equatable {
    case openFailed(code: UInt32)
    case checkFailed
    case internalError
}

final class PDFCoreDocument {
    /// Phase 8 – Serialisierung je QPDF-INSTANZ statt je Prozess.
    ///
    /// libqpdf ist gegen gleichzeitige Nutzung EINER QPDF-Instanz aus
    /// mehreren Threads nicht abgesichert; VERSCHIEDENE Instanzen dagegen
    /// schon (qpdf ≥ 10.6, hier 12.4.0). Der frühere globale NSLock
    /// serialisierte alle Dokumente im Prozess gegeneinander – das war der
    /// dokumentierte Flaschenhals, an dem Zeitlimits (hangGuard zählt
    /// Wartezeit mit) und parallele Mehr-Dokument-Läufe scheiterten. Die
    /// Sperre hängt jetzt an der Instanz; prozessweite Einstiegspunkte ohne
    /// Instanz (open, version) behalten eine kleine globale Sperre.
    ///
    /// Achtung: Kein gelockter Aufruf darf einen zweiten gelockten Aufruf
    /// auf DEMSELBEN Objekt tätigen (kein NSLock-Reentrancy) – alle Methoden
    /// sind bewusst Blattfunktionen.
    private let gate = NSLock()

    /// Nur für Einstiegspunkte ohne Instanz und für `init` (das Handle
    /// existiert dort noch nicht). Offen ist billig; hier konservativ zu
    /// serialisieren kostet nichts und hält die Initialisierung der Library
    /// geordnet.
    private static let processGate = NSLock()

    let handle: OpaquePointer

    init(path: String) throws {
        var status = PDFCORE_OK
        Self.processGate.lock()
        defer { Self.processGate.unlock() }
        guard let handle = pdfcore_open(path, &status), status == PDFCORE_OK else {
            throw PDFCoreError.openFailed(code: status.rawValue)
        }
        self.handle = handle
    }

    deinit {
        pdfcore_close(handle)
    }

    /// Anzahl Seiten (libqpdf Page Tree).
    var pageCount: Int {
        gate.lock(); defer { gate.unlock() }
        return Int(pdfcore_page_count(handle))
    }

    /// Strukturprüfung im Sinne von `qpdf --check`.
    func check() throws {
        gate.lock(); defer { gate.unlock() }
        let result = pdfcore_check(handle)
        guard result == PDFCORE_OK.rawValue else {
            throw result == PDFCORE_ERR_CHECK_FAILED.rawValue
                ? PDFCoreError.checkFailed
                : PDFCoreError.internalError
        }
    }
    static var version: String {
        Self.processGate.lock(); defer { Self.processGate.unlock() }
        var buffer = [CChar](repeating: 0, count: 64)
        let needed = Int(pdfcore_version(&buffer, buffer.count))
        if needed >= 0 && needed < buffer.count {
            return String(cString: buffer)
        }
        var large = [CChar](repeating: 0, count: max(needed + 1, 1))
        _ = pdfcore_version(&large, large.count)
        return String(cString: large)
    }

    // MARK: - Epic Phase 7 – semantische Inspection

    /// Geometrie+Rotation einer Seite (0-basiert).
    func pageInfo(at index: Int) throws -> (mediaBox: [Double], cropBox: [Double], rotation: Int) {
        gate.lock(); defer { gate.unlock() }
        var info = pdfcore_page_info()
        let result = pdfcore_page_info(handle, Int32(index), &info)
        guard result == 0 else {
            throw PDFCoreError.internalError
        }
        let media = [info.media_box.0, info.media_box.1,
                     info.media_box.2, info.media_box.3]
        let crop = [info.crop_box.0, info.crop_box.1,
                    info.crop_box.2, info.crop_box.3]
        return (media, crop, Int(info.rotation))
    }

    /// (total, links, widgets) über alle Seiten.
    func annotationCounts() throws -> (total: Int, links: Int, widgets: Int) {
        gate.lock(); defer { gate.unlock() }
        var total: Int32 = 0, links: Int32 = 0, widgets: Int32 = 0
        guard pdfcore_annotation_counts(handle, &total, &links, &widgets) == 0 else {
            throw PDFCoreError.internalError
        }
        return (Int(total), Int(links), Int(widgets))
    }

    /// (total, links, widgets) für EINE Seite.
    func annotationCounts(page index: Int) throws -> (total: Int, links: Int, widgets: Int) {
        gate.lock(); defer { gate.unlock() }
        var total: Int32 = 0, links: Int32 = 0, widgets: Int32 = 0
        guard pdfcore_page_annotation_counts(handle, Int32(index),
                                             &total, &links, &widgets) == 0 else {
            throw PDFCoreError.internalError
        }
        return (Int(total), Int(links), Int(widgets))
    }

    enum StringListKind: Int32 {
        case links = 0
        case outlineLabels = 1
        case pageLabels = 2
        case images = 3
        // Masterplan Finding 6 – vollständiger semantischer Snapshot.
        case namedDestinations = 4
        case attachments = 5
        case formFields = 6
        case signatures = 7
        case outlineTree = 8
        /// „sourcePage|destType|targetPage|namedDest|x0,y0,x1,y1"
        case linkDetails = 9
        /// Phase 23c – Form-XObject-Ressourcen (Platzierungsgeometrie in
        /// Formen). Format siehe PDFCORE_LIST_FORM_RESOURCES im C-Header.
        case formResources = 10
    }

    func stringList(_ kind: StringListKind) throws -> [String] {
        gate.lock(); defer { gate.unlock() }
        var n: Int32 = 0
        guard pdfcore_string_list_count(handle, kind.rawValue, &n) == 0 else {
            throw PDFCoreError.internalError
        }
        var out: [String] = []
        for i in 0..<Int(n) {
            var buf = [CChar](repeating: 0, count: 1024)
            var needed = pdfcore_string_list_get(handle, kind.rawValue, Int32(i),
                                                 &buf, buf.count)
            guard needed >= 0 else { continue }
            // Der Rückgabewert ist die BENÖTIGTE Länge. Passt der Eintrag nicht
            // in den Puffer, wird mit exakter Größe wiederholt – sonst würden
            // z. B. lange Formularwerte still abgeschnitten.
            if needed >= buf.count {
                buf = [CChar](repeating: 0, count: Int(needed) + 1)
                needed = pdfcore_string_list_get(handle, kind.rawValue, Int32(i),
                                                 &buf, buf.count)
                guard needed >= 0 else { continue }
            }
            out.append(String(cString: buf))
        }
        return out
    }

    func linkURLs() throws -> [String] {
        try stringList(.links)
    }

    func outlineLabels() throws -> [String] {
        try stringList(.outlineLabels)
    }

    var formFieldCount: Int {
        gate.lock(); defer { gate.unlock() }
        return Int(pdfcore_form_field_count(handle))
    }

    var namedDestinationCount: Int {
        gate.lock(); defer { gate.unlock() }
        return Int(pdfcore_named_destination_count(handle))
    }

    var attachmentCount: Int {
        gate.lock(); defer { gate.unlock() }
        return Int(pdfcore_attachment_count(handle))
    }

    var hasPageLabels: Bool {
        gate.lock(); defer { gate.unlock() }
        return pdfcore_has_page_labels(handle) == 1
    }

    // MARK: - Epic Phase 13 – Page Labels

    /// Liest /PageLabels als kodierte Einträge „start|style|prefix|first“.
    func pageLabelEncodings() throws -> [String] {
        gate.lock(); defer { gate.unlock() }
        var n: Int32 = 0
        let rc = pdfcore_string_list_count(handle, PDFCORE_LIST_PAGE_LABELS, &n)
        guard rc == 0 else { throw PDFCoreError.internalError }
        var out: [String] = []
        for i in 0..<Int(n) {
            var buf = [CChar](repeating: 0, count: 512)
            let needed = pdfcore_string_list_get(handle,
                                                 PDFCORE_LIST_PAGE_LABELS,
                                                 Int32(i), &buf, buf.count)
            if needed >= 0 { out.append(String(cString: buf)) }
        }
        return out
    }

    /// Schreibt kodierte Page-Label-Einträge („start|style|prefix|first“).
    /// Schreibt einen flachen Outline-Baum über die Bridge.
    ///
    /// Der Aufbau lief zuvor über PDFKit (`PDFDocument.write(to:)`) – und ein
    /// einziger solcher Schreibvorgang zerstört die Textextrahierbarkeit:
    /// gemessen 470 → 242 Wörter an einem arXiv-Paper, weil die
    /// /ToUnicode-Abbildungen verlorengehen (Befund 15). Über die Bridge
    /// bleiben die Objekte unverändert.
    static func writeOutlines(titles: [String], pageIndices: [Int],
                              doc: PDFCoreDocument) throws {
        precondition(titles.count == pageIndices.count)
        let cStrings: [UnsafeMutablePointer<CChar>?] = titles.map { strdup($0) }
        defer { for p in cStrings where p != nil { free(p) } }
        let indices = pageIndices.map(Int32.init)

        doc.gate.lock(); defer { doc.gate.unlock() }
        let rc: Int32 = cStrings.withUnsafeBufferPointer { buf in
            indices.withUnsafeBufferPointer { idx in
                let ptr = UnsafeRawPointer(buf.baseAddress!)
                    .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                return pdfcore_write_outlines(doc.handle, ptr,
                                              idx.baseAddress,
                                              Int32(titles.count))
            }
        }
        guard rc == PDFCORE_OK.rawValue else { throw PDFCoreError.checkFailed }
    }

    static func writePageLabelEncodings(_ encodings: [String],
                                        doc: PDFCoreDocument) throws {
        let cStrings: [UnsafeMutablePointer<CChar>?] =
            encodings.map { strdup($0) }
        defer { for p in cStrings where p != nil { free(p) } }
        doc.gate.lock(); defer { doc.gate.unlock() }
        let rc: Int32 = cStrings.withUnsafeBufferPointer { buf in
            // const char *const * → konstante Sicht auf das char*-Array.
            let ptr = UnsafeRawPointer(buf.baseAddress!)
                .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            return pdfcore_write_page_labels(doc.handle, ptr,
                                             Int32(encodings.count))
        }
        guard rc == PDFCORE_OK.rawValue else { throw PDFCoreError.internalError }
    }

    // MARK: - Epic Phase 11 – Internal Links

    /// Zielseiten aller Links (Seitenreihenfolge):
    /// ≥ 0 = Seitenindex, -1 = dangling, -2 = externer URI-Link.
    func internalLinkTargets() throws -> [Int] {
        gate.lock(); defer { gate.unlock() }
        var ptr: UnsafeMutablePointer<Int32>?
        var n: Int32 = 0
        let rc = pdfcore_internal_link_targets(handle, &ptr, &n)
        guard rc == 0 else { throw PDFCoreError.internalError }
        defer { free(ptr) }
        var out: [Int] = []
        if let base = ptr {
            for i in 0..<Int(n) { out.append(Int(base[i])) }
        }
        return out
    }

    /// Phase-11-Policy: dangling interne Links entfernen. Gibt Anzahl zurück.
    @discardableResult
    func removeDanglingLinkAnnotations() -> Int {
        gate.lock(); defer { gate.unlock() }
        var removed: Int32 = 0
        _ = pdfcore_remove_dangling_link_annots(handle, &removed)
        return Int(removed)
    }

    /// Epic Phase 16 – Producer in /Info setzen.
    func setProducer(_ producer: String) {
        gate.lock(); defer { gate.unlock() }
        _ = pdfcore_set_producer(handle, producer)
    }

    /// Speichert das sanitisierte Dokument unter einem neuen Pfad.
    func save(to url: URL) throws {
        gate.lock(); defer { gate.unlock() }
        let rc = pdfcore_save(handle, url.path)
        guard rc == PDFCORE_OK.rawValue else { throw PDFCoreError.internalError }
    }

    /// OCR-Textebene als eigenen Content-Stream an die Seite hängen
    /// (`pdfcore_append_ocr_layer`: bestehender Inhalt in q … Q, Font
    /// /PDFToolsOCR = Helvetica/WinAnsi).
    func appendOCRLayer(pageIndex: Int, content: String) throws {
        gate.lock(); defer { gate.unlock() }
        let bytes = Array(content.utf8)
        let rc = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                pdfcore_append_ocr_layer(handle, Int32(pageIndex), $0, buffer.count)
            }
        }
        guard rc == PDFCORE_OK.rawValue else {
            throw rc == PDFCORE_ERR_CHECK_FAILED.rawValue ? PDFCoreError.checkFailed
                                                          : PDFCoreError.internalError
        }
    }

    /// Phase V2-9 (§15.6) – finaler Write mit Writer-Optionen: EIN Write
    /// statt der Zwei-Write-Kette images.pdf + qpdf-CLI-Struktur-Pass.
    /// Die Optionen tragen die bestehenden Struktur-Pass-Flags (Abbildung in
    /// `pdfcore_save_with_options`, siehe Header).
    func save(to url: URL, options: PDFCoreSaveOptions) throws {
        gate.lock(); defer { gate.unlock() }
        let rc = pdfcore_save_with_options(
            handle, url.path,
            options.objectStreamsGenerate ? 1 : 0,
            options.recompressFlate ? 1 : 0,
            Int32(clamping: options.compressionLevel),
            options.linearize ? 1 : 0)
        guard rc == PDFCORE_OK.rawValue else { throw PDFCoreError.internalError }
    }
}

/// Phase V2-9 (§15.6) – finale Writer-Optionen des Single-Write-Pfads.
/// Abgebildete Struktur-Pass-Flags (Compressor.structurePassArguments):
/// object streams generate/disable, Flate-Rekompression + Level, Linearize.
/// Zopfli (FlatePolicy .maximum) ist bewusst NICHT Teil davon – der
/// Maximum-Pfad fällt in Swift auf den Zwei-Write-Pfad zurück (§15.7).
struct PDFCoreSaveOptions: Sendable {
    /// 1 = --object-streams=generate (Default modern), 0 = disable
    /// (CompatibilityPolicy .maximum).
    var objectStreamsGenerate: Bool = true
    /// --recompress-flate.
    var recompressFlate: Bool = false
    /// --compression-level=N; < 0 = qpdf-Standard belassen.
    var compressionLevel: Int = -1
    /// --linearize.
    var linearize: Bool = false
}

// MARK: - Epic Phase 21 – Bild-XObject-Inspektion

struct PDFCoreImageInfo: Equatable {
    let pageIndex: Int
    let name: String
    let width: Int
    let height: Int
    let bitsPerComponent: Int
    let colorspace: String
    let filters: [String]
    let hasSMask: Bool
    /// Gleiches Bild-Objekt auf >1 Seite platziert.
    let isShared: Bool
    /// Platzierungsbreite/-höhe in pt aus dem cm/Do-Scan (Phase 23b); 0 = unbekannt.
    let placedWidthPt: Int
    let placedHeightPt: Int
    /// Eindeutige PDF-Objektidentität – die einzige zulässige Adressierung
    /// für Mutationen (Masterplan Finding 13).
    let objectID: PDFObjectID
    let hasMask: Bool
    /// `/Mask` als Array – Farbschlüssel statt Schablone.
    let hasColorKeyMask: Bool
    let isImageMask: Bool
    /// Die Werte des `/Decode`-Arrays, leer wenn keins vorhanden.
    let decodeArray: [Double]
    var hasDecodeArray: Bool { !decodeArray.isEmpty }
    let encodedByteCount: Int

    /// Effective DPI gemäß Platzierung; 0 wenn unbekannt.
    var effectiveDPI: Double {
        guard placedWidthPt > 0 else { return 0 }
        return Double(width) / Double(placedWidthPt) * 72.0
    }
}

extension PDFCoreDocument {

    /// Eine Zeile je PLATZIERUNG. Für Entscheidungen wird stattdessen
    /// `imageResources()` benutzt – dort ist je OBJEKT gruppiert.
    func inspectImages() throws -> [PDFCoreImageInfo] {
        let rows = try stringList(.images)
        var out: [PDFCoreImageInfo] = []
        for line in rows {
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init)
            guard f.count >= 17,
                  let page = Int(f[0]), let w = Int(f[2]), let h = Int(f[3]),
                  let bpc = Int(f[4]),
                  let objNum = Int(f[11]), let gen = Int(f[12]) else { continue }
            out.append(PDFCoreImageInfo(
                pageIndex: page, name: f[1], width: w, height: h,
                bitsPerComponent: bpc, colorspace: f[5],
                filters: f[6].split(separator: "+").map(String.init),
                hasSMask: f[7] == "1", isShared: f[8] == "1",
                placedWidthPt: Int(f[9]) ?? 0,
                placedHeightPt: Int(f[10]) ?? 0,
                objectID: PDFObjectID(objectNumber: objNum, generation: gen),
                hasMask: f[13] != "0",
                hasColorKeyMask: f[13] == "2",
                isImageMask: f[14] == "1",
                decodeArray: f[15] == "-" ? []
                    : f[15].split(separator: ",").compactMap { Double($0) },
                encodedByteCount: Int(f[16]) ?? -1))
        }
        return out
    }

    /// Masterplan Schritt 1 – Bild-Ressourcen je OBJEKTIDENTITÄT.
    ///
    /// Die Platzierungsgrößen stammen aus dem cm/Do-Scan der Content-Streams;
    /// ein geteiltes XObject sammelt alle seine Platzierungen unter EINER
    /// `PDFObjectID`. Genau darauf beruht die sichere Ersetzung.
    ///
    /// Phase 23c – zweite Scan-Quelle: Bilder in (verschachtelten) Formen
    /// hängen nicht in den Seiten-Resources; der Seiten-Scan sieht ihre
    /// Geometrie nicht. Der Form-Scan ergänzt genau die fehlenden Größen,
    /// ohne eine bestehende Platzierung zu verändern.
    func imageResources() throws -> [PDFImageResource] {
        let placements = try inspectImages()
        guard !placements.isEmpty else { return [] }

        // Platzierungsgeometrie je Seite aus den Content-Bytes – nur Seiten,
        // die Bilder referenzieren: Nachgeschlagen wird unten ausschließlich
        // `info.pageIndex`. Früher lief der Scan über JEDE Seite (Statistik-
        // Jahrbuch, >1.000 Textseiten: 35 s allein für die Schnellschätzung).
        var placedByPageAndName: [String: (Double, Double)] = [:]
        // Lage auf der Seite (CTM beim Do) – für die OCR eingebetteter Fotos.
        var transformByPageAndName: [String: [Double]] = [:]
        for pageIndex in Set(placements.map(\.pageIndex)).sorted() where pageIndex < pageCount {
            guard let bytes = try? pageContentBytes(pageIndex: pageIndex) else { continue }
            var scanner = CMDoScanner(bytes: bytes)
            for placement in scanner.scan() where placement.placedW > 0 {
                let key = "\(pageIndex)|\(Self.normalizedResourceName(placement.name))"
                // Mehrfachplatzierung desselben Namens auf einer Seite: die
                // GRÖSSTE zählt, sonst würde zu stark verkleinert.
                let existing = placedByPageAndName[key]
                if existing == nil || placement.placedW > existing!.0 {
                    placedByPageAndName[key] = (placement.placedW, placement.placedH)
                    transformByPageAndName[key] = placement.transform
                }
            }
        }

        // Phase 23c – Platzierungsgeometrie aus den Form-Content-Bytes,
        // je (Seite, Objektidentität) statt je Name: Form-Bilder können in
        // verschiedenen Formen unter demselben Namen stehen.
        let placedByPageAndObject = try formPlacementSizes()

        var grouped: [PDFObjectID: [PDFCoreImageInfo]] = [:]
        var order: [PDFObjectID] = []
        for info in placements {
            if grouped[info.objectID] == nil { order.append(info.objectID) }
            grouped[info.objectID, default: []].append(info)
        }

        return order.compactMap { objectID -> PDFImageResource? in
            guard let infos = grouped[objectID], let first = infos.first else { return nil }
            var known: [PDFImageFilter] = []
            var unknown: [String] = []
            for raw in first.filters where !raw.isEmpty {
                if let filter = PDFImageFilter(rawName: raw) {
                    known.append(filter)
                } else {
                    unknown.append(raw)
                }
            }
            let placementModels = infos.map { info -> PDFImagePlacement in
                let key = "\(info.pageIndex)|\(Self.normalizedResourceName(info.name))"
                let formKey = "\(info.pageIndex)|\(objectID.objectNumber)|\(objectID.generation)"
                // Beide Quellen ergänzen sich; die GRÖSSTE bekannte
                // Platzierung zählt (bestehende Regel – sie limitiert das
                // Verkleinern am stärksten, effectiveDPI nimmt das Minimum).
                var placed = (0.0, 0.0)
                for candidate in [placedByPageAndName[key],
                                  placedByPageAndObject[formKey]].compactMap({ $0 })
                where candidate.0 > placed.0 {
                    placed = candidate
                }
                return PDFImagePlacement(
                    pageIndex: info.pageIndex,
                    resourceName: info.name,
                    placedWidthPoints: placed.0,
                    placedHeightPoints: placed.1,
                    transform: transformByPageAndName[key])
            }
            return PDFImageResource(
                objectID: objectID,
                width: first.width,
                height: first.height,
                bitsPerComponent: first.bitsPerComponent,
                colorSpace: PDFColorSpaceDescriptor(rawName: first.colorspace),
                filters: known,
                unknownFilters: unknown,
                hasSoftMask: first.hasSMask,
                hasExplicitMask: first.hasMask,
                hasColorKeyMask: first.hasColorKeyMask,
                isImageMask: first.isImageMask,
                decodeArray: first.decodeArray,
                encodedByteCount: first.encodedByteCount,
                placements: placementModels)
        }
    }

    /// Der Scanner liefert Namen ohne, die Inspektion mit führendem Slash.
    static func normalizedResourceName(_ name: String) -> String {
        name.hasPrefix("/") ? String(name.dropFirst()) : name
    }

    // MARK: Phase 23c – Platzierungsgeometrie aus Form-XObjects

    /// Deckel gegen Dekompressionsbomben: Ein Form-Content, dessen rohe
    /// ODER dekodierte Größe darüber liegt, wird übersprungen.
    private static let formContentByteLimit = 32 * 1024 * 1024
    /// Budget gescannter Formen je Seite – dasselbe Maß wie der
    /// Sammel-Walk im C-Kern (64 Formen, Zykel-Abschneidung).
    private static let maxFormsPerScan = 64
    /// Nesting-Tiefe der Form-Kette (walk_resources erlaubt 16 Ebenen).
    private static let maxFormDepth = 16

    /// cm/Do-Scan über die Content-Bytes aller errebbaren Form-XObjects.
    ///
    /// Kettenskala: Der Scan einer Form liefert Größen in FORM-Koordinaten.
    /// Die endgültige Größe ist Ahnen-CTM × /Matrix × Inhalt. Die Skala der
    /// obersten Ebene kommt aus dem Seiten-Scan (der Scanner meldet die CTM
    /// an jedem Do – auch an Form-Do); Unterformen erben die Platzierung,
    /// die der Eltern-Scan für ihr Do sieht, multipliziert mit ihrer
    /// /Matrix. Die Multiplikation über die Spaltennormen ist für
    /// achsenparallele Matrizen exakt (der praktisch allein vorkommende
    /// Fall) und sonst eine Näherung – bewusst best effort statt eines
    /// zweiten Content-Analyzers.
    private func formPlacementSizes() throws -> [String: (Double, Double)] {
        let rows = try formResources()
        guard !rows.isEmpty else { return [:] }

        // Forms je Seite: Matrix-Skalierung und Bild-Map; Unterformen je
        // Eltern-Form bzw. direkt in den Seiten-Resources.
        struct FormNode {
            var scaleX = 1.0
            var scaleY = 1.0
            var images: [String: PDFObjectID] = [:]
        }
        var nodes: [Int: [PDFObjectID: FormNode]] = [:]
        var pageRoots: [Int: [(name: String, form: PDFObjectID)]] = [:]
        var nestedChildren: [Int: [PDFObjectID: [(name: String, form: PDFObjectID)]]] = [:]
        for row in rows {
            var node = nodes[row.pageIndex]?[row.formID] ?? FormNode()
            if row.isImage {
                node.images[row.name] = row.targetID
            } else {
                node.scaleX = row.matrixScaleX
                node.scaleY = row.matrixScaleY
                if let parent = row.parentFormID {
                    nestedChildren[row.pageIndex, default: [:]][parent, default: []]
                        .append((row.name, row.formID))
                } else {
                    pageRoots[row.pageIndex, default: []].append((row.name, row.formID))
                }
            }
            nodes[row.pageIndex, default: [:]][row.formID] = node
        }

        var placed: [String: (Double, Double)] = [:]
        func record(_ pageIndex: Int, _ objectID: PDFObjectID,
                    _ size: (Double, Double)) {
            guard size.0 > 0 else { return }
            let key = "\(pageIndex)|\(objectID.objectNumber)|\(objectID.generation)"
            // Mehrfachplatzierung desselben Objekts: die GRÖSSTE zählt
            // (dieselbe Regel wie bei der Seiten-Quelle).
            if let existing = placed[key], existing.0 >= size.0 { return }
            placed[key] = size
        }

        func formContent(_ formID: PDFObjectID) -> [UInt8]? {
            // Roh-Deckel zuerst: Eine Dekompressionsbombe würde sonst erst
            // beim Dekodieren den Speicher sprengen.
            guard let raw = objectStreamBytes(objectID: formID, decoded: false),
                  raw.count <= Self.formContentByteLimit,
                  let decoded = objectStreamBytes(objectID: formID, decoded: true),
                  decoded.count <= Self.formContentByteLimit else { return nil }
            return [UInt8](decoded)
        }

        func scanForm(_ pageIndex: Int, _ formID: PDFObjectID,
                      outerScale: (Double, Double), depth: Int,
                      visited: inout Set<PDFObjectID>) {
            guard depth < Self.maxFormDepth,
                  visited.count < Self.maxFormsPerScan,
                  !visited.contains(formID),
                  let node = nodes[pageIndex]?[formID],
                  let bytes = formContent(formID) else { return }
            visited.insert(formID)
            var scanner = CMDoScanner(bytes: bytes)
            for placement in scanner.scan() where placement.placedW > 0 {
                let name = Self.normalizedResourceName(placement.name)
                // outerScale bildet den Form-Raum bereits auf die Seite ab.
                let size = (outerScale.0 * placement.placedW,
                            outerScale.1 * placement.placedH)
                if let imageID = node.images[name] {
                    record(pageIndex, imageID, size)
                }
                // Unterform: ihre Platzierung im Eltern-Content ist das
                // nächste Kettenglied-CTM; ihre /Matrix liegt zwischen.
                for child in nestedChildren[pageIndex]?[formID] ?? []
                where child.name == placement.name {
                    if let childNode = nodes[pageIndex]?[child.form] {
                        let childOuter = (size.0 * childNode.scaleX,
                                          size.1 * childNode.scaleY)
                        scanForm(pageIndex, child.form, outerScale: childOuter,
                                 depth: depth + 1, visited: &visited)
                    }
                }
            }
        }

        // Seiten aufsteigend – die Reihenfolge ist Teil der
        // Determinismus-Zusage (Erster Fund gewinnt bei Doppelbesuchen).
        for pageIndex in 0..<pageCount where nodes[pageIndex] != nil {
            // Kettenskala der obersten Ebene: Platzierung der Form im
            // Seiten-Content (größte pro Name, wie überall).
            var pageScale: [String: (Double, Double)] = [:]
            if let bytes = try? pageContentBytes(pageIndex: pageIndex) {
                var scanner = CMDoScanner(bytes: bytes)
                for placement in scanner.scan() where placement.placedW > 0 {
                    let name = Self.normalizedResourceName(placement.name)
                    if let existing = pageScale[name],
                       existing.0 >= placement.placedW { continue }
                    pageScale[name] = (placement.placedW, placement.placedH)
                }
            }
            var visited: Set<PDFObjectID> = []
            for root in pageRoots[pageIndex] ?? [] {
                guard let rootNode = nodes[pageIndex]?[root.form] else { continue }
                let ctm = pageScale[root.name] ?? (1, 1)
                let outer = (ctm.0 * rootNode.scaleX, ctm.1 * rootNode.scaleY)
                scanForm(pageIndex, root.form, outerScale: outer,
                         depth: 0, visited: &visited)
            }
        }
        return placed
    }
}

// MARK: - Phase 3-Followup – Zopfli-Byteschnur

/// Kandidat für den Zopfli-Repack (Phase 3-Followup).
struct PDFCoreFlateStream: Sendable {
    let objectID: PDFObjectID
    /// Länge der KODIERTEN Stream-Bytes (die zopfli unterbieten muss).
    let rawByteCount: Int
}

/// Phase 3-Followup – reine Byteschnur ohne Dokumentzugriff: Nur diese
/// beiden Schritte dürfen im Executor parallel laufen (zlib-Inflate und
/// Zopfli-DEFLATE); alles am Dokument-Handle bleibt seriell.
enum ZopfliCodec {

    /// roher zlib-Strom (RFC 1950) → Inhalt. `maxContentBytes` bricht ab,
    /// bevor ein kleiner Strom den Speicher sprengen kann.
    static func inflate(_ raw: Data, maxContentBytes: Int) -> Data? {
        guard !raw.isEmpty else { return nil }
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        let status: Int32 = raw.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_CHECK_FAILED.rawValue)
            }
            return pdfcore_zlib_inflate(base, rawBuf.count, maxContentBytes,
                                        &ptr, &len)
        }
        guard status == PDFCORE_OK.rawValue, let base = ptr, len > 0 else {
            if let base = ptr { free(base) }
            return nil
        }
        defer { free(base) }
        return Data(bytes: base, count: len)
    }

    /// Inhalt → zlib-Strom via Zopfli (ZOPFLI_FORMAT_ZLIB).
    static func compress(_ content: Data) -> Data? {
        guard !content.isEmpty else { return nil }
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        let status: Int32 = content.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_INTERNAL.rawValue)
            }
            return pdfcore_zopfli_compress(base, rawBuf.count, &ptr, &len)
        }
        guard status == PDFCORE_OK.rawValue, let base = ptr, len > 0 else {
            if let base = ptr { free(base) }
            return nil
        }
        defer { free(base) }
        return Data(bytes: base, count: len)
    }
}

// MARK: - Phase V2-1 (§7.5) – Native Byte-Attribution

extension PDFCoreDocument {

    /// Native Byte-Attribution dieses Dokuments; Definitionen siehe
    /// `DocumentSpaceInventory` (Compression/SpaceAttribution.swift) und
    /// den Header-Kommentar von `pdfcore_space_inventory`.
    /// `documentBytes` ist die Dateigröße der Eingabe – der Aufrufer liefert
    /// sie, die Bridge liest keine Dateigrößen.
    func spaceInventory(documentBytes: Int64) throws -> DocumentSpaceInventory {
        gate.lock(); defer { gate.unlock() }
        var raw = pdfcore_space_inventory_t()
        let rc = pdfcore_space_inventory(handle, documentBytes, &raw)
        guard rc == PDFCORE_OK.rawValue else { throw PDFCoreError.internalError }
        return DocumentSpaceInventory(
            documentBytes: raw.document_bytes,
            jpegBytes: raw.jpeg_bytes,
            jpxBytes: raw.jpx_bytes,
            ccittBytes: raw.ccitt_bytes,
            jbig2Bytes: raw.jbig2_bytes,
            flateImageBytes: raw.flate_image_bytes,
            otherImageBytes: raw.other_image_bytes,
            fontProgramBytes: raw.font_program_bytes,
            contentStreamBytes: raw.content_stream_bytes,
            metadataBytes: raw.metadata_bytes,
            embeddedFileBytes: raw.embedded_file_bytes,
            objectStreamBytes: raw.object_stream_bytes,
            unattributedBytes: raw.unattributed_bytes)
    }
}

// MARK: - Masterplan Schritt 1/2 – objektbasierte Mutation

/// Phase 3b – Ergebnis des Content-Hash-Dedup.
struct PDFCoreDedupStats: Equatable, Sendable {
    /// Absorbierte doppelte Stream-Objekte.
    let mergedStreams: Int
    /// Absorbierte doppelte Dict-/Array-Objekte.
    let mergedObjects: Int
    /// Gesparte Rohbytes (Schätzung; verwaiste Objekte verschwinden erst
    /// beim Schreiben).
    let estimatedBytesSaved: Int
}

extension PDFCoreDocument {

    /// Ersetzt GENAU EIN Bildobjekt durch JPEG-Daten.
    ///
    /// Es gibt bewusst keine namensbasierte Variante mehr: Sie hätte auf
    /// Seite 2 ein fremdes `/Im0` mit überschrieben (Masterplan Finding 13).
    /// Die Bridge verweigert die Ersetzung zusätzlich selbst, wenn das
    /// Objekt Masken, ein /Decode-Array oder /ImageMask trägt.
    /// Führt mehrfach identisch gespeicherte Bilder auf ein Objekt zusammen.
    ///
    /// Verlustfrei – es wird kein Byte neu kodiert, nur ein Verweis
    /// umgehängt. Liefert die Anzahl der umgehängten Verweise.
    @discardableResult
    func deduplicateImages() throws -> Int {
        gate.lock(); defer { gate.unlock() }
        var merged: Int32 = 0
        let rc = pdfcore_deduplicate_images(handle, &merged)
        guard rc == PDFCORE_OK.rawValue else {
            throw PDFCoreError.checkFailed
        }
        return Int(merged)
    }

    /// Phase 3b (Roadmap) – allgemeiner Content-Hash-Dedup über ALLE
    /// indirekten Objekte (Vorbild MuPDF -ggg): Streams werden nur bei
    /// identischen dekomprimierten Bytes UND whitelist-gleichen Wörterbüchern
    /// zusammengeführt; JBIG2Globals-Kandidaten, /ObjStm, Seitenbaum und
    /// Katalog bleiben außen vor, verschlüsselte Dokumente laufen leer.
    /// Verlustfrei – kein Byte wird neu kodiert, nur Referenzen werden
    /// umgehängt; verwaiste Objekte verwirft der Writer beim Schreiben.
    @discardableResult
    func deduplicate() throws -> PDFCoreDedupStats {
        gate.lock(); defer { gate.unlock() }
        var stats = pdfcore_dedup_stats_t()
        let rc = pdfcore_deduplicate_document(handle, &stats)
        guard rc == PDFCORE_OK.rawValue else {
            throw PDFCoreError.checkFailed
        }
        return PDFCoreDedupStats(
            mergedStreams: Int(stats.merged_streams),
            mergedObjects: Int(stats.merged_objects),
            estimatedBytesSaved: Int(stats.estimated_bytes_saved))
    }

    func replaceImage(objectID: PDFObjectID, jpegData: Data,
                      newWidth: Int, newHeight: Int,
                      grayscale: Bool, decodeApplied: Bool = false) throws {
        gate.lock(); defer { gate.unlock() }
        let rc: Int32 = jpegData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_CHECK_FAILED.rawValue)
            }
            return pdfcore_replace_image_object(
                handle, Int32(objectID.objectNumber), Int32(objectID.generation),
                base, raw.count, Int32(newWidth), Int32(newHeight),
                grayscale ? 1 : 0, decodeApplied ? 1 : 0)
        }
        guard rc == PDFCORE_OK.rawValue else {
            throw rc == PDFCORE_ERR_CHECK_FAILED.rawValue
                ? PDFCoreError.checkFailed
                : PDFCoreError.internalError
        }
    }

    /// Phase 6C – ersetzt GENAU EIN vierkanaliges Bildobjekt (CMYK) durch
    /// JPEG-Daten aus dem kontrollierten mozjpeg-Shim (YCCK, transform 2).
    /// Die Verweigerungspolitik der JPEG-Ersetzung gilt unverändert; ein
    /// nicht-trivialer /ColorSpace (ICCBased-4) bleibt erhalten, weil die
    /// YCCK-Daten die Werte dieses Farbraums tragen.
    func replaceImageCMYK(objectID: PDFObjectID, jpegData: Data,
                          newWidth: Int, newHeight: Int,
                          decodeApplied: Bool = false) throws {
        gate.lock(); defer { gate.unlock() }
        let rc: Int32 = jpegData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_CHECK_FAILED.rawValue)
            }
            return pdfcore_replace_image_object_cmyk(
                handle, Int32(objectID.objectNumber), Int32(objectID.generation),
                base, raw.count, Int32(newWidth), Int32(newHeight),
                decodeApplied ? 1 : 0)
        }
        guard rc == PDFCORE_OK.rawValue else {
            throw rc == PDFCORE_ERR_CHECK_FAILED.rawValue
                ? PDFCoreError.checkFailed
                : PDFCoreError.internalError
        }
    }

    /// Verlustfreier Ersatz: Flate-kodierte Pixel mit adaptivem
    /// PNG-Zeilenprädiktor statt JPEG.
    /// Für Grafiken/Screenshots, deren Kanten JPEG sichtbar beschädigt.
    /// - Parameter components: 1 = grau, 3 = RGB, 4 = CMYK. Der Farbraum der
    ///   Ausgabe folgt den übergebenen Bytes, damit ein CMYK-Bild CMYK bleibt.
    func replaceImageLossless(objectID: PDFObjectID, flateData: Data,
                              width: Int, height: Int,
                              components: Int,
                              predictor: Bool = true,
                              decodeApplied: Bool = false) throws {
        gate.lock(); defer { gate.unlock() }
        let rc: Int32 = flateData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_CHECK_FAILED.rawValue)
            }
            return pdfcore_replace_image_object_flate(
                handle, Int32(objectID.objectNumber), Int32(objectID.generation),
                base, raw.count, Int32(width), Int32(height),
                Int32(components), predictor ? 1 : 0, decodeApplied ? 1 : 0)
        }
        guard rc == PDFCORE_OK.rawValue else {
            throw rc == PDFCORE_ERR_CHECK_FAILED.rawValue
                ? PDFCoreError.checkFailed
                : PDFCoreError.internalError
        }
    }

    /// Stream-Bytes eines Bildobjekts.
    /// - `decoded: false` → rohe Bytes (bei DCTDecode: JPEG)
    /// - `decoded: true`  → von libqpdf aufgelöste Bytes (Flate/LZW/RunLength
    ///   inkl. Predictor). Kann libqpdf nicht ALLE Filter auflösen, wird
    ///   `nil` geliefert – niemals Ersatzdaten.
    func imageStreamData(objectID: PDFObjectID, decoded: Bool) -> Data? {
        gate.lock(); defer { gate.unlock() }
        var ptr: UnsafeMutablePointer<CChar>?
        var len: Int = 0
        let rc = pdfcore_get_image_object_data(
            handle, Int32(objectID.objectNumber), Int32(objectID.generation),
            decoded ? 1 : 0, &ptr, &len)
        guard rc == PDFCORE_OK.rawValue, let base = ptr, len > 0 else {
            if let base = ptr { free(base) }
            return nil
        }
        defer { free(base) }
        return Data(bytes: base, count: len)
    }

    // MARK: Phase V2-3c (§9.10) – CCITT-Eingangs-Decode

    /// /DecodeParms-Katalog eines CCITTFaxDecode-Eingangs, wie ihn
    /// `pdfcore_get_image_ccitt_parms` aus dem Stream-Wörterbuch liest.
    struct CCITTDecodeParms: Equatable, Sendable {
        /// /K: -1 = G4 (T.6), 0 = G3 1D, 1..64 = G3 2D (gemischt).
        let k: Int
        let columns: Int
        let rows: Int
        let blackIs1: Bool
        let endOfLine: Bool
        let endOfBlock: Bool
        let encodedByteAlign: Bool
        let damagedRowsBeforeError: Int
        /// 1, wenn das Dictionary ausschließlich bekannte Schlüssel trägt.
        let knownKeysOnly: Bool

        /// §9.10 / §4 – „vollständig rekonstruierbar oder nichts“: Liefert
        /// die Begründung, WARUM diese Parameter nicht dekodiert werden
        /// dürfen, oder nil, wenn der Katalog vollständig abgedeckt ist.
        ///
        /// Abdeckung (jede Zeile deterministisch verweigert):
        ///   /K                 – Pflicht; nur -1, 0 oder 1...64
        ///   /Columns //Rows    – Pflicht; müssen /Width //Height entsprechen
        ///   /BlackIs1          – true/false beide ok: Der Fax-Strom codiert
        ///                        weisse/schwarze Läufe intrinsisch, der
        ///                        Flag kehrt nur die Abtastwert-Deutung im
        ///                        Leser um – die Tinten-1-Extraktion ist
        ///                        identisch
        ///   /EncodedByteAlign  – true wird VERWEIGERT (libtiffs
        ///                        Bytealign-Verhalten ohne Quellcode der
        ///                        vendored Version nicht verifizierbar)
        ///   /EndOfLine         – nur ohne G4 (T.6 kennt keine EOLs) und
        ///                        PFLICHT bei K > 0 (2D braucht die
        ///                        EOL-Synchronisation; empirisch gegen
        ///                        die vendored libtiff bestätigt)
        ///   /EndOfBlock        – beide Werte ok: gelesen wird
        ///                        zeilenzahlgesteuert, ein angehängter
        ///                        EOFB/RTC wird nicht berührt
        ///   /DamagedRowsBeforeError – nur 0 (libtiff hat kein
        ///                        Toleranzfenster; kaputte Ströme scheitern
        ///                        am Decode und bleiben per decodeFailed
        ///                        in KEEP)
        ///   fremde Schlüssel   – VERWEIGERT (keine Dekodier-Extras, die
        ///                        libtiff nicht abbilden kann)
        func acceptanceIssue(expectedWidth: Int,
                             expectedHeight: Int) -> String? {
            guard knownKeysOnly else {
                return "DecodeParms trägt fremde Schlüssel"
            }
            guard k == -1 || (0...64).contains(k) else {
                return "/K \(k) außerhalb des abgedeckten Bereichs"
            }
            guard columns == expectedWidth, rows == expectedHeight else {
                return "Columns/Rows (\(columns)x\(rows)) weichen von " +
                       "Width/Height (\(expectedWidth)x\(expectedHeight)) ab"
            }
            guard !encodedByteAlign else {
                return "/EncodedByteAlign wird nicht abgedeckt"
            }
            guard damagedRowsBeforeError == 0 else {
                return "/DamagedRowsBeforeError \(damagedRowsBeforeError) " +
                       "wird nicht abgedeckt"
            }
            if k < 0, endOfLine {
                return "/EndOfLine bei G4 nicht plausibel"
            }
            if k > 0, !endOfLine {
                return "K > 0 verlangt /EndOfLine (2D-Synchronisation)"
            }
            return nil
        }
    }

    /// Liest /DecodeParms eines CCITTFaxDecode-Bildobjekts. nil heißt:
    /// nicht rekonstruierbar (fehlende/ungültige Parameter) – deterministisch
    /// KEEP.
    func ccittDecodeParms(objectID: PDFObjectID) -> CCITTDecodeParms? {
        gate.lock(); defer { gate.unlock() }
        var parms = pdfcore_ccitt_parms_t()
        let rc = pdfcore_get_image_ccitt_parms(
            handle, Int32(objectID.objectNumber), Int32(objectID.generation),
            &parms)
        guard rc == PDFCORE_OK.rawValue, parms.present == 1 else { return nil }
        return CCITTDecodeParms(
            k: Int(parms.k),
            columns: Int(parms.columns),
            rows: Int(parms.rows),
            blackIs1: parms.black_is_1 != 0,
            endOfLine: parms.end_of_line != 0,
            endOfBlock: parms.end_of_block != 0,
            encodedByteAlign: parms.byte_aligned != 0,
            damagedRowsBeforeError: Int(parms.damaged_rows),
            knownKeysOnly: parms.known_keys_only != 0)
    }

    /// Phase 1b – Ersetzt NUR die Stream-Bytes eines Bildobjekts; das
    /// Wörterbuch bleibt unverändert. Für den verlustfreien JPEG-Repack:
    /// Gleiche Koeffizienten und Dimensionen, also bleiben /Decode, /SMask
    /// & Co. gültig. Die Bridge weigert sich selbst bei Filtern ≠ DCTDecode.
    func replaceImageStreamBytes(objectID: PDFObjectID, data: Data) throws {
        gate.lock(); defer { gate.unlock() }
        let rc: Int32 = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_CHECK_FAILED.rawValue)
            }
            return pdfcore_replace_image_stream_bytes(
                handle, Int32(objectID.objectNumber), Int32(objectID.generation),
                base, raw.count)
        }
        guard rc == PDFCORE_OK.rawValue else {
            throw rc == PDFCORE_ERR_CHECK_FAILED.rawValue
                ? PDFCoreError.checkFailed
                : PDFCoreError.internalError
        }
    }

    /// Phase 3-Followup – Zopfli-Repack großer Flate-Streams (nur
    /// Max-Preset). Kandidaten: Streams mit EXAKT /FlateDecode (keine
    /// Vorfilter, keine /ObjStm-/XRef-Ströme) und Rohgröße >= der Schwelle.
    func flateStreams(minimumRawBytes: Int) throws -> [PDFCoreFlateStream] {
        gate.lock(); defer { gate.unlock() }
        var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: Int32 = 0
        let rc = pdfcore_flate_stream_list(handle, minimumRawBytes, &list, &count)
        guard rc == PDFCORE_OK.rawValue else { throw PDFCoreError.internalError }
        guard let list, count > 0 else { return [] }
        defer { pdfcore_free_strings(list, count) }
        var out: [PDFCoreFlateStream] = []
        for index in 0..<Int(count) {
            guard let entry = list[index].map({ String(cString: $0) }) else { continue }
            let parts = entry.split(separator: "|").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            out.append(PDFCoreFlateStream(
                objectID: PDFObjectID(objectNumber: parts[0], generation: parts[1]),
                rawByteCount: parts[2]))
        }
        return out
    }

    /// Rohe (kodierte) Stream-Bytes eines beliebigen Stream-Objekts.
    func streamBytes(objectID: PDFObjectID) -> Data? {
        gate.lock(); defer { gate.unlock() }
        var ptr: UnsafeMutablePointer<UInt8>?
        var len: Int = 0
        let rc = pdfcore_get_stream_bytes(
            handle, Int32(objectID.objectNumber), Int32(objectID.generation),
            &ptr, &len)
        guard rc == PDFCORE_OK.rawValue, let base = ptr, len > 0 else {
            if let base = ptr { free(base) }
            return nil
        }
        defer { free(base) }
        return Data(bytes: base, count: len)
    }

    /// Phase 23c – Stream-Bytes eines beliebigen Stream-Objekts.
    /// - `decoded: true` → von libqpdf aufgelöste Bytes; kann libqpdf nicht
    ///   ALLE Filter auflösen, wird `nil` geliefert – niemals Ersatzdaten.
    /// - `decoded: false` → rohe (kodierte) Bytes (wie `streamBytes`).
    func objectStreamBytes(objectID: PDFObjectID, decoded: Bool) -> Data? {
        gate.lock(); defer { gate.unlock() }
        var ptr: UnsafeMutablePointer<CChar>?
        var len: Int = 0
        let rc = pdfcore_get_object_stream_bytes(
            handle, Int32(objectID.objectNumber), Int32(objectID.generation),
            decoded ? 1 : 0, &ptr, &len)
        guard rc == PDFCORE_OK.rawValue, let base = ptr, len > 0 else {
            if let base = ptr { free(base) }
            return nil
        }
        defer { free(base) }
        return Data(bytes: base, count: len)
    }

    /// Ersetzt NUR die rohen Stream-Bytes eines Flate-Streams; das
    /// Wörterbuch (inklusive /DecodeParms) bleibt unverändert. Die Bridge
    /// verweigert alles, was nicht exakt /FlateDecode ist.
    func replaceFlateStreamBytes(objectID: PDFObjectID, data: Data) throws {
        gate.lock(); defer { gate.unlock() }
        let rc: Int32 = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_CHECK_FAILED.rawValue)
            }
            return pdfcore_replace_stream_bytes(
                handle, Int32(objectID.objectNumber), Int32(objectID.generation),
                base, raw.count)
        }
        guard rc == PDFCORE_OK.rawValue else {
            throw rc == PDFCORE_ERR_CHECK_FAILED.rawValue
                ? PDFCoreError.checkFailed
                : PDFCoreError.internalError
        }
    }

    // MARK: Phase 2b – Bilevel-Ersatz (CCITT G4 / JBIG2)

    /// Ersetzt GENAU EIN Bildobjekt durch einen nackten CCITT-G4-Stream.
    /// Die Bridge schreibt BitsPerComponent 1, /DeviceGray und
    /// /DecodeParms <</K -1/Columns/Rows/BlackIs1 true>>. Die Verweigerungs-
    /// politik der JPEG-Ersetzung gilt unverändert.
    func replaceImageCCITT(objectID: PDFObjectID, g4Data: Data,
                           width: Int, height: Int) throws {
        gate.lock(); defer { gate.unlock() }
        let rc: Int32 = g4Data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_CHECK_FAILED.rawValue)
            }
            return pdfcore_replace_image_object_ccitt(
                handle, Int32(objectID.objectNumber), Int32(objectID.generation),
                base, raw.count, Int32(width), Int32(height))
        }
        guard rc == PDFCORE_OK.rawValue else {
            throw rc == PDFCORE_ERR_CHECK_FAILED.rawValue
                ? PDFCoreError.checkFailed
                : PDFCoreError.internalError
        }
    }

    /// Ersetzt GENAU EIN Bildobjekt durch einen JBIG2-Seitenstrom. Globals
    /// (falls vorhanden) legt die Bridge als eigenes indirektes Stream-Objekt
    /// an und verdrahtet /DecodeParms <</JBIG2Globals …>>.
    func replaceImageJBIG2(objectID: PDFObjectID, pageData: Data,
                           globalsData: Data, width: Int, height: Int) throws {
        gate.lock(); defer { gate.unlock() }
        let rc: Int32 = pageData.withUnsafeBytes { pageRaw -> Int32 in
            guard let pageBase = pageRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_CHECK_FAILED.rawValue)
            }
            return globalsData.withUnsafeBytes { globalsRaw -> Int32 in
                let globalsBase = globalsRaw.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                return pdfcore_replace_image_object_jbig2(
                    handle, Int32(objectID.objectNumber), Int32(objectID.generation),
                    pageBase, pageRaw.count,
                    globalsBase, globalsRaw.count,
                    Int32(width), Int32(height))
            }
        }
        guard rc == PDFCORE_OK.rawValue else {
            throw rc == PDFCORE_ERR_CHECK_FAILED.rawValue
                ? PDFCoreError.checkFailed
                : PDFCoreError.internalError
        }
    }

    /// Ersetzt GENAU EIN Bildobjekt durch einen /Indexed-Farbraum-Stream
    /// (FlateDecode + PNG-Prädiktor, Masterplan §9.6).
    /// Die Bridge schreibt `/ColorSpace [/Indexed /DeviceGray|/DeviceRGB
    /// hival <Lookup>]` (Lookup immer als String), `/BitsPerComponent` und
    /// `/DecodeParms <</Predictor 15/Colors 1/BitsPerComponent/Columns>>`.
    /// Die Verweigerungspolitik der replace_-Familie gilt unverändert; die
    /// Strukturprüfung deckt Palette (Komponenten, Einträge ≤ 2^bpc) und
    /// BitsPerComponent ab – die Zeilenpackung der ENTPACKTEN Indizes
    /// (ceil(width·bpc/8) Bytes je Zeile, ISO 32000-1 §8.9.3) ist Sache des
    /// Aufrufers und dort durch das Bitgenau-Gate bewiesen.
    func replaceImageIndexed(objectID: PDFObjectID, indexData: Data,
                             paletteData: Data, width: Int, height: Int,
                             bitsPerComponent: Int, paletteComponents: Int,
                             decodeApplied: Bool = false) throws {
        gate.lock(); defer { gate.unlock() }
        let rc: Int32 = indexData.withUnsafeBytes { idxRaw -> Int32 in
            guard let idxBase = idxRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_CHECK_FAILED.rawValue)
            }
            return paletteData.withUnsafeBytes { palRaw -> Int32 in
                guard let palBase = palRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return Int32(PDFCORE_ERR_CHECK_FAILED.rawValue)
                }
                return pdfcore_replace_image_object_indexed(
                    handle, Int32(objectID.objectNumber), Int32(objectID.generation),
                    idxBase, idxRaw.count, palBase, palRaw.count,
                    Int32(width), Int32(height),
                    Int32(bitsPerComponent), Int32(paletteComponents),
                    decodeApplied ? 1 : 0)
            }
        }
        guard rc == PDFCORE_OK.rawValue else {
            throw rc == PDFCORE_ERR_CHECK_FAILED.rawValue
                ? PDFCoreError.checkFailed
                : PDFCoreError.internalError
        }
    }

    // MARK: Phase V2-7 (§13.7) – MRC-Seitenrekonstruktion

    /// EIN MRC-Layer für die Seitenrekonstruktion.
    struct MRCLayer {
        enum Kind {
            /// 8-bit JPEG (DCTDecode) – Hintergrund/Photo-Regionen.
            case jpeg(components: Int)
            /// ImageMask über JBIG2Decode (lossless, Refinement aus).
            case jbig2Mask(globals: Data?)
            /// ImageMask über CCITTFaxDecode (G4, /BlackIs1 true).
            case ccittG4Mask
        }
        let kind: Kind
        let width: Int
        let height: Int
        let data: Data
        /// Sub-Rect im BILDPIXELRAUM mit oben-links-Ursprung; nil = Vollbild.
        /// Die y-Spiegelung in den PDF-Bildraum nimmt die Bridge vor.
        var rect: CGRect?

        var isMask: Bool {
            if case .jpeg = kind { return false }
            return true
        }
    }

    /// Ersetzt den Full-Page-Raster-Draw (`cm /name Do`) der Seite durch die
    /// Layer-Zeichnung (§13.7): Background → Photos → FG-Maske, unter
    /// Wahrung der ursprünglichen cm-Transform. Text-Operatoren (inkl.
    /// unsichtbarem OCR-Layer), Annotationen, Boxes und /Rotate bleiben
    /// unberührt. Die Bridge verweigert transaktional (checkFailed), wenn
    /// Seite/Name/Draw nicht exakt der Beschreibung entsprechen.
    func replacePageImageDrawWithLayers(pageIndex: Int,
                                        imageObjectID: PDFObjectID,
                                        resourceName: String,
                                        layers: [MRCLayer]) throws {
        gate.lock(); defer { gate.unlock() }

        // Alle Layer-Bytes und Globals in EINEN zusammenhängenden Puffer –
        // die C-Pointer müssen für die Dauer des Aufrufs gültig bleiben,
        // und ein einziger withUnsafeBytes-Block garantiert das (Muster wie
        // replaceImageJBIG2, dort mit zwei Schachtelungen).
        var combined = Data()
        struct Layout { var dataOffset = 0; var dataLen = 0
                        var globalsOffset = 0; var globalsLen = 0 }
        var layouts = [Layout]()
        for layer in layers {
            var layout = Layout()
            layout.dataOffset = combined.count
            layout.dataLen = layer.data.count
            combined.append(layer.data)
            if case .jbig2Mask(let globals) = layer.kind, let globals,
               !globals.isEmpty {
                layout.globalsOffset = combined.count
                layout.globalsLen = globals.count
                combined.append(globals)
            }
            layouts.append(layout)
        }

        var cLayers = [pdfcore_mrc_layer_t]()
        cLayers.reserveCapacity(layers.count)
        for (index, layer) in layers.enumerated() {
            var c = pdfcore_mrc_layer_t()
            c.width = Int32(layer.width)
            c.height = Int32(layer.height)
            if let rect = layer.rect {
                c.rect.0 = Double(rect.minX)
                c.rect.1 = Double(rect.minY)
                c.rect.2 = Double(rect.maxX)
                c.rect.3 = Double(rect.maxY)
            }
            switch layer.kind {
            case .jpeg(let components):
                c.kind = 0
                c.components = Int32(components)
                c.is_mask = 0
            case .jbig2Mask:
                c.kind = 1
                c.components = 1
                c.is_mask = 1
            case .ccittG4Mask:
                c.kind = 2
                c.components = 1
                c.is_mask = 1
            }
            c.len = layouts[index].dataLen
            c.globals_len = layouts[index].globalsLen
            cLayers.append(c)
        }

        let rc: Int32 = combined.withUnsafeBytes { (base: UnsafeRawBufferPointer) -> Int32 in
            let basePointer = base.baseAddress?.assumingMemoryBound(to: UInt8.self)
            for (index, layout) in layouts.enumerated() {
                cLayers[index].bytes = basePointer.map { $0 + layout.dataOffset }
                cLayers[index].globals = basePointer.map { $0 + layout.globalsOffset }
            }
            defer {
                for index in cLayers.indices {
                    cLayers[index].bytes = nil
                    cLayers[index].globals = nil
                }
            }
            return resourceName.withCString { namePtr in
                cLayers.withUnsafeMutableBufferPointer { buffer in
                    pdfcore_replace_page_image_draw_with_layers(
                        handle, Int32(pageIndex),
                        Int32(imageObjectID.objectNumber),
                        Int32(imageObjectID.generation),
                        namePtr, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        guard rc == PDFCORE_OK.rawValue else {
            throw rc == PDFCORE_ERR_CHECK_FAILED.rawValue
                ? PDFCoreError.checkFailed
                : PDFCoreError.internalError
        }
    }

    /// Strukturprofil – Eingang in die Größenschätzung.
    struct StructureProfile {
        /// Dokument nutzt bereits Object Streams.
        let usesObjectStreams: Bool
        let isLinearized: Bool
        /// Mindestens ein Content-Stream ist unkomprimiert.
        let hasUncompressedContent: Bool

        /// Wie stark der qpdf-Struktur-Pass die NICHT-Bild-Bytes voraussichtlich
        /// verdichtet. Werte aus dem Accuracy Lab (63 Dokumente, 2026-08-26):
        /// Bereits objektstrom-komprimierte Dokumente verlieren kaum noch etwas;
        /// unkomprimierte Content-Streams schrumpfen dagegen deutlich.
        var structureRetention: Double {
            if hasUncompressedContent { return 0.35 }
            if usesObjectStreams { return 0.93 }
            return 0.62
        }
    }

    var structureProfile: StructureProfile {
        gate.lock(); defer { gate.unlock() }
        let flags = pdfcore_structure_profile(handle)
        guard flags >= 0 else {
            // Unbekannt: konservativ wie ein bereits optimiertes Dokument
            // behandeln, damit die Schätzung nicht zu optimistisch wird.
            return StructureProfile(usesObjectStreams: true, isLinearized: false,
                                    hasUncompressedContent: false)
        }
        return StructureProfile(usesObjectStreams: flags & 1 != 0,
                                isLinearized: flags & 2 != 0,
                                hasUncompressedContent: flags & 4 != 0)
    }

    /// Masterplan Finding 12 – Metadatenpolitik im Produktionspfad.
    func stripMetadata(keepProducer: Bool) throws {
        gate.lock(); defer { gate.unlock() }
        let rc = pdfcore_strip_metadata(handle, keepProducer ? 1 : 0)
        guard rc == PDFCORE_OK.rawValue else { throw PDFCoreError.internalError }
    }
}

// MARK: - Phase 5a – Font-Attribution, Font-Dedup, Unused-Font-GC

/// Phase 5a – Ergebnis des Font-Audits: Dedup und GC in einem Durchgang.
struct PDFCoreFontAuditStats: Equatable, Sendable {
    /// Gefundene /Font-Dicts.
    let fontObjects: Int
    /// FontFile/FontFile2/FontFile3-Programme (eindeutige Streams).
    let fontFileStreams: Int
    /// Umgehängte Font-Dict-Referenzen (Dedup: identischer FontFile-Hash +
    /// identische semantische Dict-Form).
    let duplicateFontRefsRemoved: Int
    /// Entfernte Einträge aus Resources-Maps (Unused-Font-GC).
    let unusedFontsRemoved: Int
    /// Gesparte Rohbytes (Schätzung über die FontFile-Größen).
    let estimatedBytesSaved: Int
}

extension PDFCoreDocument {

    /// Phase 5a – Font-Dedup und Unused-Font-GC in einem Durchgang.
    ///
    /// Der C-Kern findet alle /Font-Dicts samt FontProgrammen, führt Dicts
    /// mit identischem FontFile-Hash UND identischer semantischer Form auf
    /// das Objekt mit der niedrigsten Objektnummer zusammen (FontFile-
    /// Duplikate ohne Dict-Übereinstimmung bleiben getrennt) und trägt
    /// Font-Einträge aus Resources-Maps, die kein Tf ihres Contents je
    /// benutzt. Konservativ: unscanbare Contents schützen ihre ganze Map,
    /// /AcroForm/DR und Type3-Fonts bleiben stehen, der Seitenbaum bleibt
    /// unangetastet. Verlustfrei, Never-Grow implizit.
    @discardableResult
    func auditFonts() throws -> PDFCoreFontAuditStats {
        gate.lock(); defer { gate.unlock() }
        var stats = pdfcore_font_audit_stats()
        let rc = pdfcore_font_audit(handle, &stats)
        guard rc == PDFCORE_OK.rawValue else {
            throw PDFCoreError.checkFailed
        }
        return PDFCoreFontAuditStats(
            fontObjects: Int(stats.font_objects),
            fontFileStreams: Int(stats.font_file_streams),
            duplicateFontRefsRemoved: Int(stats.duplicate_font_refs_removed),
            unusedFontsRemoved: Int(stats.unused_fonts_removed),
            estimatedBytesSaved: Int(stats.estimated_bytes_saved))
    }
}

// MARK: - Phase 5b – Font-Subsetting (hb-subset)

/// Phase 5b – Ergebnis des Subset-Passes.
struct PDFCoreFontSubsetStats: Equatable, Sendable {
    /// Neu geschriebene Fontprogramme (konservativ verifiziert).
    let subsettedFonts: Int
    /// Font-Dicts, die unangetastet blieben (Whitelist, unscanbar, korrupt …).
    let keptFonts: Int
    /// Gesparte dekodierte Programmbytes (Schätzung; Never-Grow je Font).
    let estimatedBytesSaved: Int
}

extension PDFCoreDocument {

    /// Phase 5b – Fontprogramme auf die benutzten Glyphen reduzieren.
    ///
    /// Der C-Kern ermittelt je Font die benutzten Codes/CIDs aus dem Content,
    /// subsettet nur die Whitelist-Konstellationen (Simple-TrueType mit
    /// sauberem Code→Unicode-Pfad, Identity-H/V-CIDFonts mit FontFile2) und
    /// schreibt /Widths bzw. /W konsistent mit. Codes, /Encoding und
    /// /ToUnicode bleiben unverändert. Eine Strukturprüfung (qpdf --check-
    /// Äquivalent) läuft intern nach allen Mutationen; scheitert sie, wirft
    /// die Methode und der Aufrufer verwirft den Pass komplett.
    /// Verschrittene Documente laufen leer, Type3 und alle nicht sicher
    /// handhabbaren Fonts bleiben stehen.
    @discardableResult
    func subsetFonts(minBytesSaved: Int = 0) throws -> PDFCoreFontSubsetStats {
        gate.lock(); defer { gate.unlock() }
        var stats = pdfcore_font_subset_stats()
        let rc = pdfcore_font_subset(handle, Int64(minBytesSaved), &stats)
        guard rc == PDFCORE_OK.rawValue else {
            throw PDFCoreError.checkFailed
        }
        return PDFCoreFontSubsetStats(
            subsettedFonts: Int(stats.subsetted_fonts),
            keptFonts: Int(stats.kept_fonts),
            estimatedBytesSaved: Int(stats.estimated_bytes_saved))
    }
}

// MARK: - Phase V2-8 (§14.1/§21) – Selektives Font-Subsetting + Resource GC

/// V2-8 – EIN Font-Kandidat der Trockenplanung (`pdfcore_font_subset_candidates`).
struct PDFCoreFontSubsetCandidate: Equatable, Sendable {
    /// 安全-Klassifikation des C-Kerns: 0 = subsetting-safe, sonst der
    /// dokumentierte Behalte-Grund (1 Type3, 2 AcroForm/DR, 3 CIDFont-
    /// Nachfolger, 4 geteiltes Programm, 5 unscanbarer Content,
    /// 6 Trockenplanung verweigert/ohne Gewinn).
    enum Reason: Int, Sendable {
        case safe = 0
        case type3 = 1
        case acroFormDefaultResources = 2
        case cidDescendant = 3
        case sharedFontProgram = 4
        case unscannableContent = 5
        case dryPlanRefused = 6

        var explanation: String {
            switch self {
            case .safe: return "subsetting-safe (Trockenplanung erfolgreich)"
            case .type3: return "Type3-Font"
            case .acroFormDefaultResources: return "/AcroForm/DR (Feld-DA ohne Seitenevent)"
            case .cidDescendant: return "CIDFont-Nachfolger (läuft über das Type0-Dict)"
            case .sharedFontProgram: return "geteiltes Fontprogramm"
            case .unscannableContent: return "unscanbarer Content"
            case .dryPlanRefused: return "Trockenplanung verweigert oder ohne Gewinn"
            }
        }
    }

    let objectID: PDFObjectID
    /// Ehrliche Schätzung der Trockenplanung (hb-subset gelaufen, nicht mutiert).
    let estimatedBytesSaved: Int
    /// Dekodierte FontFile2-Größe – Basis der relativen Aktivierungspolitik.
    let originalProgramBytes: Int
    let subsettable: Bool
    let reason: Reason
    /// Seiten (0-basiert), von denen aus der Font erreichbar ist – Basis der
    /// Render-Stichprobe (§14.4).
    let pages: [Int]
}

extension PDFCoreDocument {

    /// V2-8 (§14.1) – Trockenplanung aller Font-Dicts: Whitelist, Benutzung
    /// und hb-subset laufen vollständig, NICHTS wird mutiert. Liefert je Font
    /// die Objektidentität, die ehrliche Ersparnis und die 安全-Klassifikation.
    func fontSubsetCandidates(minBytesSaved: Int = 0)
        throws -> [PDFCoreFontSubsetCandidate] {
        gate.lock(); defer { gate.unlock() }
        var list: UnsafeMutablePointer<pdfcore_font_subset_candidate_t>?
        var count: Int32 = 0
        var pages: UnsafeMutablePointer<Int32>?
        var pagesCount: Int32 = 0
        let rc = pdfcore_font_subset_candidates(handle, Int64(minBytesSaved),
                                                &list, &count, &pages,
                                                &pagesCount)
        guard rc == PDFCORE_OK.rawValue else {
            throw PDFCoreError.checkFailed
        }
        defer {
            if let list, let pages {
                pdfcore_font_subset_candidates_free(list, pages)
            } else if let list {
                pdfcore_font_subset_candidates_free(list, nil)
            }
        }
        guard let list, count > 0 else { return [] }
        var out: [PDFCoreFontSubsetCandidate] = []
        out.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let raw = list[i]
            var pageIndices: [Int] = []
            if let pages, raw.page_count > 0,
               Int(raw.page_first) + Int(raw.page_count) <= Int(pagesCount) {
                pageIndices.reserveCapacity(Int(raw.page_count))
                for p in Int(raw.page_first)..<Int(raw.page_first)
                            + Int(raw.page_count) {
                    pageIndices.append(Int(pages[p]))
                }
            }
            out.append(PDFCoreFontSubsetCandidate(
                objectID: PDFObjectID(objectNumber: Int(raw.obj_number),
                                      generation: Int(raw.generation)),
                estimatedBytesSaved: Int(raw.estimated_bytes_saved),
                originalProgramBytes: Int(raw.original_program_bytes),
                subsettable: raw.subsettable != 0,
                reason: PDFCoreFontSubsetCandidate.Reason(
                    rawValue: Int(raw.reason_code)) ?? .dryPlanRefused,
                pages: pageIndices))
        }
        return out
    }

    /// V2-8 (§14.1) – subsettet NUR die genannten Font-Dicts. Verweigert der
    /// C-Kern konservativ (Schutz, Whitelist, Drift der Objektidentität),
    /// bleibt der Font stehen – die Statistik berichtet, was SHIPPED.
    @discardableResult
    func subsetSelectedFonts(_ ids: [PDFObjectID], minBytesSaved: Int = 0)
        throws -> PDFCoreFontSubsetStats {
        gate.lock(); defer { gate.unlock() }
        guard !ids.isEmpty else {
            return PDFCoreFontSubsetStats(subsettedFonts: 0, keptFonts: 0,
                                          estimatedBytesSaved: 0)
        }
        var objects = [Int32](repeating: 0, count: ids.count)
        var generations = [Int32](repeating: 0, count: ids.count)
        for (i, id) in ids.enumerated() {
            objects[i] = Int32(id.objectNumber)
            generations[i] = Int32(id.generation)
        }
        var stats = pdfcore_font_subset_stats()
        let rc = objects.withUnsafeBufferPointer { objs in
            generations.withUnsafeBufferPointer { gens in
                pdfcore_font_subset_selected(handle, objs.baseAddress,
                                             gens.baseAddress,
                                             Int32(ids.count), &stats)
            }
        }
        guard rc == PDFCORE_OK.rawValue else {
            throw PDFCoreError.checkFailed
        }
        return PDFCoreFontSubsetStats(
            subsettedFonts: Int(stats.subsetted_fonts),
            keptFonts: Int(stats.kept_fonts),
            estimatedBytesSaved: Int(stats.estimated_bytes_saved))
    }
}

/// V2-8 (§14.6) – Ergebnis der Resource GC.
struct PDFCoreResourceGCStats: Equatable, Sendable {
    var xobjectsRemoved: Int = 0
    var extGStatesRemoved: Int = 0
    var colorSpacesRemoved: Int = 0
    var patternsRemoved: Int = 0
    var shadingsRemoved: Int = 0
    var propertiesRemoved: Int = 0
    var estimatedBytesSaved: Int = 0

    var totalEntriesRemoved: Int {
        xobjectsRemoved + extGStatesRemoved + colorSpacesRemoved
            + patternsRemoved + shadingsRemoved + propertiesRemoved
    }
}

extension PDFCoreDocument {

    /// V2-8 (§14.6) – unbenutzte Einträge aus Resource-Maps tragen (XObject,
    /// ExtGState, ColorSpace, Pattern, Shading, Properties). Konservativ:
    /// nur bei vollständig scanbarem Content, /AcroForm/DR und Properties
    /// unter StructTree/OC bleiben stehen. Font-Maps gehören bewusst nicht
    /// dazu (die Unused-Font-GC der Phase 5a deckt sie ab).
    @discardableResult
    func removeUnusedResources() throws -> PDFCoreResourceGCStats {
        gate.lock(); defer { gate.unlock() }
        var stats = pdfcore_resource_gc_stats()
        let rc = pdfcore_remove_unused_resources(handle, &stats)
        guard rc == PDFCORE_OK.rawValue else {
            throw PDFCoreError.checkFailed
        }
        return PDFCoreResourceGCStats(
            xobjectsRemoved: Int(stats.xobjects_removed),
            extGStatesRemoved: Int(stats.extgstates_removed),
            colorSpacesRemoved: Int(stats.colorspaces_removed),
            patternsRemoved: Int(stats.patterns_removed),
            shadingsRemoved: Int(stats.shadings_removed),
            propertiesRemoved: Int(stats.properties_removed),
            estimatedBytesSaved: Int(stats.estimated_bytes_saved))
    }

    /// Seiten-Thumbnails (/Thumb) entfernen – verlustfrei, Viewer
    /// regenerieren sie. Verwaiste Thumb-Streams verwirft der Writer.
    ///
    /// Rebuild-tolerant: Das Symbol existiert erst nach dem nächsten
    /// `build-pdfcore.sh`-Lauf in libpdfcore_universal.a. Bis dahin löst
    /// dlsym nil auf und der Pass meldet 0 (Skip) statt den Link zu
    /// brechen – kein Verhalten ändert sich, kein Build bricht.
    @discardableResult
    func removePageThumbs() throws -> Int {
        gate.lock(); defer { gate.unlock() }
        typealias Fn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>?) -> Int32
        // RTLD_DEFAULT ((void*)-2) ist in Swift nicht als Makro verfügbar.
        guard let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2),
              let sym = dlsym(defaultHandle, "pdfcore_remove_page_thumbs") else {
            return 0
        }
        let fn = unsafeBitCast(sym, to: Fn.self)
        var removed: Int32 = 0
        let rc = fn(handle, &removed)
        guard rc == PDFCORE_OK.rawValue else {
            throw PDFCoreError.checkFailed
        }
        return Int(removed)
    }

    /// Content-Streams kompaktieren (Seiten-/Contents + Form-XObjects):
    /// Whitespace-Minimum, wertexakte Zahlen, leere `q Q`-Paare. Verlustfrei
    /// per Whitelist im C-Kern; ohne Vorteil oder Fehlform bleibt der Stream
    /// stehen (Never-Grow pro Stream).
    ///
    /// Rebuild-tolerant wie `removePageThumbs`: ohne neues `.a` meldet der
    /// Pass (0, 0) als Skip.
    func minifyContentStreams() throws -> (streams: Int, savedBytes: Int) {
        gate.lock(); defer { gate.unlock() }
        typealias Fn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>?,
                                       UnsafeMutablePointer<Int64>?) -> Int32
        // RTLD_DEFAULT ((void*)-2) ist in Swift nicht als Makro verfügbar.
        guard let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2),
              let sym = dlsym(defaultHandle, "pdfcore_minify_content_streams") else {
            return (0, 0)
        }
        let fn = unsafeBitCast(sym, to: Fn.self)
        var streams: Int32 = 0
        var saved: Int64 = 0
        let rc = fn(handle, &streams, &saved)
        guard rc == PDFCORE_OK.rawValue else {
            throw PDFCoreError.checkFailed
        }
        return (Int(streams), Int(saved))
    }
}

// MARK: - Phase 4b – JPX/JPEG2000-Eingabedekodierung

/// Dekodiert JPX-Stream-Bytes über den OpenJPEG-Shim (`pdfcore_jpx_decode`).
///
/// Die Ausgabeform des Shims ist im Header (`pdfcore.h`) dokumentiert:
/// ein Little-Endian-Kopf mit Metadaten und Komponententabelle plus einem
/// interleaved 8-bit-Zielpuffer auf dem Referenzraster (Komponente 0).
/// JPX wird ausschließlich als INPUT dekodiert – einen JPX-Encode gibt es
/// bewusst nicht (Output-Verbot, Roadmap Phase 4).
enum JPXDecoder {

    struct ComponentGeometry: Equatable, Sendable {
        /// Rastergröße DERSELBEN Komponente (vor Hochrechnung, nach `reduce`).
        let width: Int
        let height: Int
        /// Subsampling-Faktoren der Quelle.
        let dx: Int
        let dy: Int
        let precision: Int
        let signed: Bool
    }

    struct Decoded: Equatable, Sendable {
        /// Referenzraster = Masse der Komponente 0 (bereits um `reduce`
        /// verkleinert). Der Pixelpuffer trägt genau diese Masse.
        let width: Int
        let height: Int
        let components: Int
        /// prec/sgnd der Komponente 0.
        let precision: Int
        let signed: Bool
        /// true = alle Komponenten liefern dieselben Masse wie Komponente 0.
        let uniformGrid: Bool
        let componentGeometries: [ComponentGeometry]
        /// Interleaved 8-bit-Pixel (Breite × Höhe × Komponenten, ohne
        /// Zeilenpadding). prec 9–16 ist im Shim um (prec-8) geschoben,
        /// vorzeichenbehaftete Werte um 2^(prec-1) versetzt.
        let pixels: Data
    }

    /// `reduce` entspricht opj cp_reduce: N dekodiert direkt auf 1/2^N.
    /// `nil` heißt: nicht dekodierbar (kein gültiger Codestream, prec > 16,
    /// verweigerte Struktur) – der Aufrufer behält das Original.
    static func decode(_ stream: Data, reduce: Int = 0) -> Decoded? {
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status: Int32 = stream.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(PDFCORE_ERR_INTERNAL.rawValue)
            }
            return pdfcore_jpx_decode(base, raw.count,
                                      Int32(max(0, min(reduce, 30))),
                                      &out, &outLen)
        }
        guard status == PDFCORE_OK.rawValue, let buf = out, outLen > 32 else {
            if let buf = out { free(buf) }
            return nil
        }
        defer { free(buf) }

        let bytes = UnsafeRawBufferPointer(start: buf, count: outLen)
        guard bytes[0] == UInt8(ascii: "J"), bytes[1] == UInt8(ascii: "P"),
              bytes[2] == UInt8(ascii: "X"), bytes[3] == UInt8(ascii: "D"),
              bytes[4] == 1 else { return nil }   // Version/Fremdformat

        func u32le(_ offset: Int) -> UInt32? {
            guard offset + 4 <= outLen else { return nil }
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }

        let components = Int(bytes[5])
        guard components >= 1, components <= 4,
              let flags = u32le(8), let width = u32le(12), let height = u32le(16),
              let tableOffset = u32le(20), let payloadOffset = u32le(24),
              let payloadLen = u32le(28) else { return nil }
        guard Int(width) > 0, Int(height) > 0,
              payloadOffset >= tableOffset + UInt32(components) * 24,
              Int(payloadOffset) + Int(payloadLen) <= outLen else { return nil }

        var geometries: [ComponentGeometry] = []
        geometries.reserveCapacity(components)
        for c in 0..<components {
            let base = Int(tableOffset) + c * 24
            guard let w = u32le(base), let h = u32le(base + 4),
                  let dx = u32le(base + 8), let dy = u32le(base + 12),
                  let prec = u32le(base + 16), let sgnd = u32le(base + 20),
                  w > 0, h > 0 else { return nil }
            geometries.append(ComponentGeometry(width: Int(w), height: Int(h),
                                                dx: Int(dx), dy: Int(dy),
                                                precision: Int(prec),
                                                signed: sgnd != 0))
        }
        let expected = Int(width) * Int(height) * components
        guard Int(payloadLen) == expected else { return nil }

        return Decoded(
            width: Int(width),
            height: Int(height),
            components: components,
            precision: Int(bytes[6]),
            signed: bytes[7] != 0,
            uniformGrid: flags & 1 != 0,
            componentGeometries: geometries,
            pixels: Data(bytes[Int(payloadOffset)..<Int(payloadOffset) + expected]))
    }
}

// MARK: - Phase 23c – Form-XObject-Ressourcen

/// Eine Ressourcen-Beziehung innerhalb eines Form-XObjects.
///
/// Die Bilder-Liste (LIST_IMAGES) findet Bild-XObjects auch in Formen –
/// aber ohne Platzierungsgeometrie, denn der cm/Do-Scan lief bisher nur
/// über die Seiten-Content-Bytes. Diese Zeilen sagen, WELCHE Form WELCHES
/// Bild (bzw. WELCHE Unterform) unter WELCHEM Namen trägt; die Geometrie
/// selbst entsteht im Swift-Scan über die Form-Content-Bytes
/// (`formPlacementSizes`).
struct PDFCoreFormResource: Equatable {
    let pageIndex: Int
    /// Die Form, deren /Resources diesen Eintrag trägt.
    let formID: PDFObjectID
    /// Die Form, in DEREN Content diese Form gezeichnet wird;
    /// nil = sie hängt direkt in den Seiten-Resources.
    let parentFormID: PDFObjectID?
    /// Spaltennormen der /Matrix der Form (1 = keine Matrix).
    let matrixScaleX: Double
    let matrixScaleY: Double
    /// Bei Bildern der Name INNERHALB der Form, bei Unterformen der Name
    /// in der ELTERN-Map – genau dort findet der Eltern-Scan sie.
    let name: String
    let targetID: PDFObjectID
    let isImage: Bool
}

extension PDFCoreDocument {

    /// Phase 23c – Form-Ressourcen-Beziehungen aller Seiten.
    func formResources() throws -> [PDFCoreFormResource] {
        let rows = try stringList(.formResources)
        var out: [PDFCoreFormResource] = []
        for line in rows {
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init)
            guard f.count == 11,
                  let page = Int(f[0]),
                  let formObj = Int(f[1]), let formGen = Int(f[2]),
                  let parentObj = Int(f[3]), let parentGen = Int(f[4]),
                  let sx = Double(f[5]), let sy = Double(f[6]),
                  let targetObj = Int(f[8]), let targetGen = Int(f[9]) else { continue }
            out.append(PDFCoreFormResource(
                pageIndex: page,
                formID: PDFObjectID(objectNumber: formObj, generation: formGen),
                parentFormID: parentObj < 0
                    ? nil
                    : PDFObjectID(objectNumber: parentObj, generation: parentGen),
                matrixScaleX: sx, matrixScaleY: sy,
                name: f[7],
                targetID: PDFObjectID(objectNumber: targetObj, generation: targetGen),
                isImage: f[10] == "1"))
        }
        return out
    }
}

// MARK: - Epic Phase 23b – Content Bytes

extension PDFCoreDocument {
    /// Dekodierte Content-Bytes einer Seite (alle /Contents-Streams).
    func pageContentBytes(pageIndex: Int) throws -> [UInt8] {
        gate.lock(); defer { gate.unlock() }
        var ptr: UnsafeMutablePointer<CChar>?
        var len: Int = 0
        let rc = pdfcore_get_page_content(handle, Int32(pageIndex), &ptr, &len)
        guard rc == PDFCORE_OK.rawValue, let base = ptr, len > 0 else {
            return []
        }
        defer { free(base) }
        return [UInt8](UnsafeRawBufferPointer(start: base, count: len))
    }

    /// Ink-Overlay (Freihand-Tinte): hängt rohe Content-Operatoren hinter den
    /// bestehenden Seiten-Content (`pdfcore_append_page_content`). Einträge
    /// mit leerem Operator-String werden übersprungen.
    func appendPageContent(_ overlays: [(pageIndex: Int, operators: String)]) throws {
        let items = overlays.filter { !$0.operators.isEmpty }
        guard !items.isEmpty else { return }
        gate.lock(); defer { gate.unlock() }
        let indices = items.map { Int32($0.pageIndex) }
        // Etabliertes Muster (writeOutlines): strdup + const-Sicht.
        let cStrings: [UnsafeMutablePointer<CChar>?] = items.map { strdup($0.operators) }
        defer { for p in cStrings where p != nil { free(p) } }
        let rc: Int32 = cStrings.withUnsafeBufferPointer { buf in
            indices.withUnsafeBufferPointer { idx in
                let ptr = UnsafeRawPointer(buf.baseAddress!)
                    .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                return pdfcore_append_page_content(
                    handle, idx.baseAddress, ptr, Int32(items.count))
            }
        }
        guard rc == 0 else { throw PDFCoreError.internalError }
    }
}

/// Lightweight cm/Do Scanner für Effective-DPI (Phase 23b).
/// Arbeitet auf dekodierten Content-Bytes; erkennt `cm` (CTM) und `Do` (XObject).
struct CMDoScanner {
    let bytes: [UInt8]
    var i: Int = 0
    var a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1
    var e: Double = 0, f: Double = 0
    var ctmStack: [[Double]] = []
    var lastName: String = ""
    var inInlineImage = false
    var stack: [Double] = []

    mutating func scan() -> [(name: String, placedW: Double, placedH: Double, transform: [Double])] {
        var results: [(String, Double, Double, [Double])] = []
        while i < bytes.count {
            skipWS()
            guard i < bytes.count else { break }
            let ch = bytes[i]

            if inInlineImage {
                // `EI` nur mit Whitespace davor, Trenner dahinter und
                // druckbarem Nachlauf – Binärdaten tragen zufällig „ EI "
                // (2026-10-15, siehe pdfcore_skip_inline_image).
                if i > 0, isWhitespace(bytes[i-1]), matchInlineImageEnd() {
                    inInlineImage = false
                } else {
                    i += 1
                }
                continue
            }

            if ch == UInt8(ascii: "/") {
                readName()
            } else if ch == UInt8(ascii: "(") {
                skipLiteralString()
            } else if ch == UInt8(ascii: "<") && i + 1 < bytes.count
                        && bytes[i+1] == UInt8(ascii: "<") {
                i += 2
            } else if ch == UInt8(ascii: "<") {
                i += 1
                while i < bytes.count && bytes[i] != UInt8(ascii: ">") { i += 1 }
                if i < bytes.count { i += 1 }
            } else if ch == UInt8(ascii: ">") {
                i += 1
            } else if "[ ]{ }".contains(Character(UnicodeScalar(ch))) {
                i += 1
            } else if let num = tryNumber() {
                stack.append(num)
            } else if matchKeyword("q") {
                ctmStack.append([a, b, c, d, e, f])
            } else if matchKeyword("Q") {
                if !ctmStack.isEmpty {
                    let s = ctmStack.removeLast()
                    a=s[0];b=s[1];c=s[2];d=s[3];e=s[4];f=s[5]
                }
            } else if matchKeyword("cm") {
                applyCM()
            } else if matchKeyword("BI") {
                inInlineImage = true; stack.removeAll()
            } else if matchKeyword("Do") {
                if !stack.isEmpty { stack.removeLast() }
                if !lastName.isEmpty {
                    let wp = (a*a+b*b).squareRoot()
                    let hp = (c*c+d*d).squareRoot()
                    results.append((lastName, wp, hp, [a, b, c, d, e, f]))
                }
                lastName = ""; stack.removeAll()
            } else if isKnownOperator() {
                stack.removeAll()
            } else {
                // Unbekanntes Token überspringen
                while i < bytes.count && !isWhitespace(bytes[i])
                        && !"/([<>".contains(Character(UnicodeScalar(bytes[i]))) { i += 1 }
            }
        }
        return results
    }

    /// `a b c d e f cm` – die Operanden stehen in DIESER Reihenfolge auf dem
    /// Stack. Eine frühere Fassung las sie rückwärts (a bekam den Wert von f);
    /// bei `2000 0 0 2000 0 0 cm` ergab das eine Platzierungsbreite von 0 und
    /// damit gar keine Effective DPI. Die DPI-Politik lief dadurch faktisch
    /// nie – die Regression sichert `CMDoScannerTests` ab.
    private mutating func applyCM() {
        guard stack.count >= 6 else { return }
        let base = stack.count - 6
        let na = stack[base], nb = stack[base+1], nc = stack[base+2]
        let nd = stack[base+3], ne = stack[base+4], nf = stack[base+5]
        stack.removeLast(6)
        let oa=a, ob=b, oc=c, od=d, oe=e, of=f
        a=na*oa+nb*oc; b=na*ob+nb*od
        c=nc*oa+nd*oc; d=nc*ob+nd*od
        e=ne*oa+nf*oc+oe; f=ne*ob+nf*od+of
    }

    private mutating func readName() {
        i += 1   // überspringe '/'
        let start = i
        while i < bytes.count && !isWhitespace(bytes[i])
                && !"/([<>".contains(Character(UnicodeScalar(bytes[i]))) { i += 1 }
        lastName = String(bytes: bytes[start..<i], encoding: .utf8) ?? ""
    }

    private mutating func tryNumber() -> Double? {
        skipWS()
        var j = i; var dot = false; var hasDigit = false
        if j < bytes.count && (bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-")) { j += 1 }
        while j < bytes.count && ((bytes[j] >= UInt8(ascii: "0") && bytes[j] <= UInt8(ascii: "9")) || bytes[j] == UInt8(ascii: ".")) {
            if bytes[j] == UInt8(ascii: ".") { if dot { return nil }; dot = true }
            hasDigit = true; j += 1
        }
        guard hasDigit, j > i else { return nil }
        let str = String(bytes: bytes[i..<j], encoding: .utf8)!
        i = j
        return Double(str)
    }

    /// `EI` am Ende eines Inline-Bilds: dahinter Trenner oder Ende und in
    /// den nächsten 24 Bytes nur druckbares ASCII oder Whitespace.
    private mutating func matchInlineImageEnd() -> Bool {
        guard i + 2 <= bytes.count,
              bytes[i] == UInt8(ascii: "E"), bytes[i+1] == UInt8(ascii: "I") else { return false }
        let after = i + 2
        if after < bytes.count {
            let c = bytes[after]
            let delimiter = isWhitespace(c)
                || "/[]<>(){}%".utf8.contains(c)
            guard delimiter else { return false }
            for q in after..<min(bytes.count, after + 24) {
                let b = bytes[q]
                if !(isWhitespace(b) || (b >= 0x20 && b <= 0x7e)) { return false }
            }
        }
        i = after
        return true
    }

    private mutating func matchKeyword(_ kw: String) -> Bool {
        let kwBytes = Array(kw.utf8)
        guard i + kwBytes.count <= bytes.count else { return false }
        for (offset, kb) in kwBytes.enumerated() where bytes[i+offset] != kb { return false }
        let after = i + kwBytes.count
        if after < bytes.count {
            let ch = bytes[after]
            if (ch >= UInt8(ascii: "a") && ch <= UInt8(ascii: "z"))
                || (ch >= UInt8(ascii: "A") && ch <= UInt8(ascii: "Z"))
                || ch == UInt8(ascii: "'") { return false }
        }
        i = after
        return true
    }

    private mutating func skipWS() {
        while i < bytes.count && isWhitespace(bytes[i]) { i += 1 }
    }

    private mutating func skipLiteralString() {
        var depth = 1; i += 1
        while i < bytes.count && depth > 0 {
            let ch = bytes[i]
            if ch == UInt8(ascii: "\\") { i += 2; continue }
            if ch == UInt8(ascii: "(") { depth += 1 }
            else if ch == UInt8(ascii: ")") { depth -= 1 }
            i += 1
        }
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }

    /// Jedes Token, das wie ein Operator aussieht, beendet seine Operandenliste.
    ///
    /// Eine feste Operatorliste ist hier die falsche Lösung: Ein fehlender
    /// Eintrag (z. B. `ri`) hinterlässt Operanden auf dem Stack, und der
    /// nächste `cm` rechnet dann mit fremden Zahlen. Deshalb wird nach der
    /// PDF-Grammatik entschieden – Operatoren bestehen aus Buchstaben,
    /// optional gefolgt von `*`, plus die Sonderfälle `'` und `"`.
    private mutating func isKnownOperator() -> Bool {
        guard i < bytes.count else { return false }
        let first = bytes[i]
        let isLetter = (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z"))
            || (first >= UInt8(ascii: "A") && first <= UInt8(ascii: "Z"))
        guard isLetter || first == UInt8(ascii: "'") || first == UInt8(ascii: "\"") else {
            return false
        }
        while i < bytes.count {
            let ch = bytes[i]
            let letter = (ch >= UInt8(ascii: "a") && ch <= UInt8(ascii: "z"))
                || (ch >= UInt8(ascii: "A") && ch <= UInt8(ascii: "Z"))
                || ch >= 128
            if letter || ch == UInt8(ascii: "*") || ch == UInt8(ascii: "'")
                || ch == UInt8(ascii: "\"") || ch == UInt8(ascii: "0")
                || ch == UInt8(ascii: "1") {
                i += 1
            } else {
                break
            }
        }
        return true
    }
}
