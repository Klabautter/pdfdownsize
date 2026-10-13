import Foundation
import PDFKit

/// Masterplan Finding 6 – DER zentrale semantische Snapshot eines PDFs.
///
/// Es gibt bewusst nur dieses eine Snapshot-Modell. Frühere Arbeitsstände
/// pflegten drei parallele Strukturen (PDFKit-Snapshot, libqpdf-Snapshot,
/// Test-„FullSemanticSnapshot"), die je Feature auseinanderliefen. Stattdessen:
/// ein Modell, mehrere Capture-Backends.
///
/// - `.pdfKit`  – sieht Text, Rendering-Semantik, Annotationsobjekte
/// - `.libQPDF` – sieht Dokumentstrukturen (Named Dests, Page Labels,
///                Attachments, Formularwerte, Signaturen) exakt
/// - `.merged`  – Vollbild: Struktur aus libqpdf, Text/Annotationen aus PDFKit
///
/// Verglichen wird immer Semantik, nie Binäridentität. Der Snapshot ist
/// deterministisch (alle Listen sortiert oder in Dokumentreihenfolge) und
/// Codable, damit Corpus-Reports ihn serialisieren können.
struct PDFSemanticSnapshot: Equatable, Codable, Sendable {

    // MARK: - Backend

    enum Backend: String, Codable, Sendable {
        case pdfKit
        case libQPDF
        case merged
    }

    // MARK: - Teil-Snapshots

    struct DocumentSnapshot: Equatable, Codable, Sendable {
        var pageCount: Int = 0
        var producer: String = ""
        /// Nutzergepflegte Dokumentinformation.
        ///
        /// `producer` steht bewusst NICHT hier: Der Producer nennt das
        /// schreibende Werkzeug und ändert sich bei jeder Bearbeitung – ihn
        /// als Verlust zu melden wäre falsch. Titel, Autor, Thema und
        /// Schlagwörter sind dagegen Eingaben des Nutzers.
        var title: String = ""
        var author: String = ""
        var subject: String = ""
        var keywords: String = ""

        /// Die vier Felder als Paare – für Vergleich und Meldung.
        var userMetadata: [(String, String)] {
            [("Titel", title), ("Autor", author),
             ("Thema", subject), ("Schlagwörter", keywords)]
        }

        var hasPageLabels: Bool = false
        /// Kodierte Label-Ranges „start|style|prefix|first“ in Dokumentreihenfolge.
        var pageLabelRanges: [String] = []
        var isEncrypted: Bool = false
    }

    struct PageSnapshot: Equatable, Codable, Sendable {
        var index: Int
        /// Vollständige Box-Information (x0,y0,x1,y1) – nicht nur Breite/Höhe,
        /// weil ein verschobener Ursprung sichtbares Cropping bedeutet.
        var mediaBox: [Double]
        var cropBox: [Double]
        var rotation: Int
        var textCharacterCount: Int
        var wordCount: Int
        /// Stabiler Fingerprint des Seitentexts (erkennt Textverfälschung,
        /// die eine reine Zeichenzählung nicht sieht).
        var textFingerprint: String
        var annotationCount: Int
        var annotationTypes: [String]
        var linkCount: Int
        var widgetCount: Int

        var mediaBoxWidth: Double { mediaBox.count == 4 ? mediaBox[2] - mediaBox[0] : 0 }
        var mediaBoxHeight: Double { mediaBox.count == 4 ? mediaBox[3] - mediaBox[1] : 0 }
        var cropBoxWidth: Double { cropBox.count == 4 ? cropBox[2] - cropBox[0] : 0 }
        var cropBoxHeight: Double { cropBox.count == 4 ? cropBox[3] - cropBox[1] : 0 }
    }

    struct NavigationSnapshot: Equatable, Codable, Sendable {
        struct OutlineEntry: Equatable, Codable, Sendable {
            var depth: Int
            var label: String
            /// 0-basierte Zielseite, -1 = unauflösbar.
            var targetPage: Int
        }
        struct NamedDestination: Equatable, Codable, Sendable {
            var name: String
            var targetPage: Int
        }
        var outline: [OutlineEntry] = []
        var namedDestinations: [NamedDestination] = []
        /// Ein Link, vollständig genug, um ihn wiederzuerkennen.
        ///
        /// Die reine Zielseite (`internalLinkTargets`) beantwortet nur „wie
        /// viele zeigen ins Leere". Sie beantwortet nicht, ob der Link noch
        /// an derselben Stelle derselben Seite sitzt und dasselbe meint
        /// (Final Core Hardening 6.3).
        struct Link: Equatable, Codable, Sendable {
            /// Seite, auf der die Verweisfläche liegt.
            var sourcePage: Int
            /// explicit | named | uri | none
            var destinationType: String
            /// Zielseite, -1 = unauflösbar, -2 = kein Seitenziel (URI).
            var targetPage: Int
            /// Bei `named`: der Zielname, sonst leer.
            var namedDestination: String
            /// Verweisfläche „x0,y0,x1,y1" auf zwei Nachkommastellen.
            var bounds: String
        }

        /// Ziel je interner Link-Annotation in Dokumentreihenfolge.
        /// -1 = dangling, -2 = externer Link.
        var internalLinkTargets: [Int] = []
        var links: [Link] = []
        var externalLinkURLs: [String] = []

        var outlineLabels: [String] { outline.map(\.label) }
        var outlineDepth: Int { (outline.map(\.depth).max() ?? -1) + 1 }
    }

    struct FormSnapshot: Equatable, Codable, Sendable {
        struct Field: Equatable, Codable, Sendable {
            /// Voll qualifizierter Name über die /Parent-Kette („parent.child“).
            var name: String
            var type: String
            var value: String
            var flags: Int
        }
        struct Signature: Equatable, Codable, Sendable {
            var fieldName: String
            var subFilter: String
        }
        var fields: [Field] = []
        var signatures: [Signature] = []

        var fieldNames: [String] { fields.map(\.name) }
    }

    struct AttachmentSnapshot: Equatable, Codable, Sendable {
        var name: String
        /// Länge des DEKODIERTEN Anhangs, -1 wenn nicht lesbar.
        ///
        /// Nicht die gespeicherte Streamlänge: Die schrumpft, sobald qpdf
        /// nachpackt, ohne dass der Anhang ein anderer wäre.
        var byteCount: Int
        /// Prüfsumme über den dekodierten Inhalt, „-" wenn nicht lesbar.
        /// Gleiche Länge bei anderem Inhalt wäre sonst unsichtbar.
        var contentHash: String = "-"
    }

    // MARK: - Inhalt

    var backend: Backend
    var document: DocumentSnapshot
    var pages: [PageSnapshot]
    var navigation: NavigationSnapshot
    var form: FormSnapshot
    var attachments: [AttachmentSnapshot]

    // Bequemer Zugriff für bestehende Aufrufer.
    var pageCount: Int { document.pageCount }
    var outlineLabels: [String] { navigation.outlineLabels }
    var formFieldNames: [String] { form.fieldNames }
    var externalLinkURLs: [String] { navigation.externalLinkURLs }

    // MARK: - Capture

    static func capture(_ url: URL, backend: Backend = .merged) throws -> PDFSemanticSnapshot {
        // Auch der Einstieg gehört in den Pool: `.merged` öffnet das Dokument
        // hier und reicht es weiter – ein Pool erst in `capture(doc)` ließe
        // das PDFDocument samt Seitencache liegen.
        try autoreleasepool {
        switch backend {
        case .pdfKit:
            guard let doc = PDFDocument(url: url), !doc.isLocked else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return capture(doc)
        case .libQPDF:
            return try captureViaLibQPDF(url)
        case .merged:
            guard let doc = PDFDocument(url: url), !doc.isLocked else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var snapshot = capture(doc)
            snapshot.backend = .merged
            // Dokumentstrukturen kommen von libqpdf: PDFKit meldet Named
            // Destinations, Page Labels, Attachments und Feldwerte nicht
            // zuverlässig. Ist libqpdf nicht verfügbar, bleibt der PDFKit-
            // Stand stehen – erkennbar am Backend-Feld, kein stiller Verlust.
            if let structure = try? captureViaLibQPDF(url) {
                snapshot.document.hasPageLabels = structure.document.hasPageLabels
                snapshot.document.pageLabelRanges = structure.document.pageLabelRanges
                snapshot.navigation.namedDestinations = structure.navigation.namedDestinations
                snapshot.navigation.internalLinkTargets = structure.navigation.internalLinkTargets
                snapshot.navigation.links = structure.navigation.links
                snapshot.navigation.outline = structure.navigation.outline
                snapshot.navigation.externalLinkURLs = structure.navigation.externalLinkURLs
                snapshot.form = structure.form
                snapshot.attachments = structure.attachments
                for i in snapshot.pages.indices where i < structure.pages.count {
                    // libqpdf kennt geerbte Boxen/Rotationen exakt.
                    snapshot.pages[i].mediaBox = structure.pages[i].mediaBox
                    snapshot.pages[i].cropBox = structure.pages[i].cropBox
                    snapshot.pages[i].rotation = structure.pages[i].rotation
                }
            }
            return snapshot
        }
        }
    }

    /// PDFKit-Sicht: Text, Annotationsobjekte, Rendering-Semantik.
    ///
    /// Der gesamte Aufbau läuft in einem Pool: Neben den Seitenobjekten
    /// erzeugen `page.string` und `page.annotations` je Seite autoreleased
    /// Objekte. Der Rückgabewert besteht nur aus Structs und Strings und
    /// übersteht das Leeren des Pools.
    static func capture(_ doc: PDFDocument) -> PDFSemanticSnapshot {
        autoreleasepool {
        var pages: [PageSnapshot] = []
        var fields: [FormSnapshot.Field] = []
        var externalURLs: [String] = []

        for i in 0..<doc.pageCount {
            // Seitenzugriffe von PDFKit sind autoreleased; bei einem
            // 300-Seiten-Dokument summiert sich das ohne Pool spürbar.
            autoreleasepool {
            guard let page = doc.page(at: i) else { return }
            let media = page.bounds(for: .mediaBox)
            let crop = page.bounds(for: .cropBox)
            let annos = page.annotations

            for a in annos where a.type == "Widget" {
                guard let name = a.fieldName else { continue }
                fields.append(FormSnapshot.Field(
                    name: name,
                    type: a.widgetFieldType.rawValue,
                    value: Self.widgetValue(a),
                    flags: 0))
            }
            for a in annos where a.type == "Link" {
                if let url = a.url?.absoluteString { externalURLs.append(url) }
            }

            let text = page.string ?? ""
            pages.append(PageSnapshot(
                index: i,
                mediaBox: [media.minX, media.minY, media.maxX, media.maxY],
                cropBox: [crop.minX, crop.minY, crop.maxX, crop.maxY],
                rotation: RotationNormalizer.normalized(page.rotation),
                textCharacterCount: text.count,
                wordCount: text.split(whereSeparator: { $0.isWhitespace }).count,
                textFingerprint: Self.fingerprint(text),
                annotationCount: annos.count,
                annotationTypes: annos.compactMap { $0.type }.sorted(),
                linkCount: annos.filter { $0.type == "Link" }.count,
                widgetCount: annos.filter { $0.type == "Widget" }.count))
            }
        }

        var outline: [NavigationSnapshot.OutlineEntry] = []
        flatten(doc.outlineRoot, depth: 0, into: &outline)

        let attrs = (doc.documentAttributes ?? [:]) as? [PDFDocumentAttribute: Any]

        return PDFSemanticSnapshot(
            backend: .pdfKit,
            document: DocumentSnapshot(
                pageCount: doc.pageCount,
                producer: attrs?[.producerAttribute] as? String ?? "",
                title: attrs?[.titleAttribute] as? String ?? "",
                author: attrs?[.authorAttribute] as? String ?? "",
                subject: attrs?[.subjectAttribute] as? String ?? "",
                keywords: (attrs?[.keywordsAttribute] as? [String])?
                    .joined(separator: ", ")
                    ?? attrs?[.keywordsAttribute] as? String ?? "",
                hasPageLabels: false,
                pageLabelRanges: [],
                isEncrypted: doc.isEncrypted),
            pages: pages,
            navigation: NavigationSnapshot(
                outline: outline,
                namedDestinations: [],
                internalLinkTargets: [],
                externalLinkURLs: externalURLs.sorted()),
            form: FormSnapshot(fields: fields.sorted { $0.name < $1.name },
                               signatures: []),
            attachments: [])
        }
    }

    /// libqpdf-Sicht: exakte Dokumentstruktur inklusive vererbter Attribute.
    static func captureViaLibQPDF(_ url: URL) throws -> PDFSemanticSnapshot {
        let doc = try PDFCoreDocument(path: url.path)
        let pageCount = doc.pageCount

        var pages: [PageSnapshot] = []
        for i in 0..<pageCount {
            let info = try doc.pageInfo(at: i)
            // Annotationen JE SEITE: Dokumentweite Summen würden einen
            // Verlust auf Seite 1 gegen einen Zuwachs auf Seite 2 aufheben.
            let counts: (total: Int, links: Int, widgets: Int) =
                (try? doc.annotationCounts(page: i)) ?? (0, 0, 0)
            pages.append(PageSnapshot(
                index: i,
                mediaBox: info.mediaBox,
                cropBox: info.cropBox,
                rotation: RotationNormalizer.normalized(info.rotation),
                textCharacterCount: 0,
                wordCount: 0,
                textFingerprint: "",
                annotationCount: counts.total,
                annotationTypes: [],
                linkCount: counts.links,
                widgetCount: counts.widgets))
        }

        let outline = (try? doc.stringList(.outlineTree))?.compactMap {
            row -> NavigationSnapshot.OutlineEntry? in
            // Format „depth|label|targetPage". Das Label darf selbst „|"
            // enthalten, deshalb wird die Tiefe von vorn und das Ziel von
            // hinten gelesen; alles dazwischen ist das Label.
            guard let head = row.firstIndex(of: "|"),
                  let depth = Int(row[..<head]) else { return nil }
            let rest = row[row.index(after: head)...]
            guard let tail = rest.lastIndex(of: "|"),
                  let target = Int(rest[rest.index(after: tail)...]) else { return nil }
            return NavigationSnapshot.OutlineEntry(
                depth: depth, label: String(rest[..<tail]), targetPage: target)
        } ?? []

        let links = (try? doc.stringList(.linkDetails))?.compactMap {
            row -> NavigationSnapshot.Link? in
            // „sourcePage|destType|targetPage|namedDest|rect" – der Zielname
            // ist bereinigt und enthält kein „|", deshalb reicht ein Split.
            let parts = row.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 5,
                  let source = Int(parts[0]), let target = Int(parts[2])
            else { return nil }
            return NavigationSnapshot.Link(
                sourcePage: source, destinationType: String(parts[1]),
                targetPage: target, namedDestination: String(parts[3]),
                bounds: String(parts[4]))
        } ?? []

        let namedDests = (try? doc.stringList(.namedDestinations))?.compactMap {
            row -> NavigationSnapshot.NamedDestination? in
            guard let sep = row.lastIndex(of: "|"),
                  let target = Int(row[row.index(after: sep)...]) else { return nil }
            return NavigationSnapshot.NamedDestination(
                name: String(row[..<sep]), targetPage: target)
        } ?? []

        let attachments = (try? doc.stringList(.attachments))?.compactMap {
            row -> AttachmentSnapshot? in
            // „name|size|checksum" – der Name ist bereinigt und trägt kein
            // „|", Größe und Prüfsumme stehen hinten.
            let parts = row.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, let size = Int(parts[1]) else { return nil }
            return AttachmentSnapshot(name: String(parts[0]), byteCount: size,
                                      contentHash: String(parts[2]))
        } ?? []

        let fields = (try? doc.stringList(.formFields))?.compactMap {
            row -> FormSnapshot.Field? in
            // Format „name|type|value|flags"; Name und Wert dürfen „|"
            // enthalten, deshalb von beiden Enden her zerlegen.
            let parts = row.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 4, let flags = Int(parts[parts.count - 1]) else { return nil }
            let name = String(parts[0])
            let type = String(parts[1])
            let value = parts[2..<(parts.count - 1)].joined(separator: "|")
            return FormSnapshot.Field(name: name, type: type, value: value, flags: flags)
        } ?? []

        let signatures = (try? doc.stringList(.signatures))?.compactMap {
            row -> FormSnapshot.Signature? in
            guard let sep = row.lastIndex(of: "|") else { return nil }
            return FormSnapshot.Signature(fieldName: String(row[..<sep]),
                                          subFilter: String(row[row.index(after: sep)...]))
        } ?? []

        return PDFSemanticSnapshot(
            backend: .libQPDF,
            document: DocumentSnapshot(
                pageCount: pageCount,
                producer: "",
                hasPageLabels: doc.hasPageLabels,
                pageLabelRanges: (try? doc.pageLabelEncodings()) ?? [],
                isEncrypted: false),
            pages: pages,
            navigation: NavigationSnapshot(
                outline: outline,
                namedDestinations: namedDests,
                internalLinkTargets: (try? doc.internalLinkTargets()) ?? [],
                links: links,
                externalLinkURLs: ((try? doc.linkURLs()) ?? []).sorted()),
            form: FormSnapshot(fields: fields, signatures: signatures),
            attachments: attachments)
    }

    // MARK: - Helfer

    /// Wortfrequenz-Fingerprint: unabhängig von Whitespace-Normalisierung
    /// verschiedener Writer, aber empfindlich gegenüber echtem Textverlust
    /// oder Zeichenverfälschung (Encoding-Bugs).
    ///
    /// `internal` (statt private), damit Isolation-/Regressionstests
    /// EINZELNE Seiten mit DEMSELBEN Maß prüfen können, ohne das ganze
    /// Dokument zu capturen – die Definition bleibt hier die eine Quelle.
    static func fingerprint(_ text: String) -> String {
        let normalized = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return "" }
        var hash: UInt64 = 1469598103934665603   // FNV-1a
        for word in normalized.sorted() {
            for byte in word.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1099511628211
            }
        }
        return String(hash, radix: 16)
    }

    private static func widgetValue(_ annotation: PDFAnnotation) -> String {
        if let value = annotation.widgetStringValue, !value.isEmpty { return value }
        return annotation.buttonWidgetState == .onState ? "on" : ""
    }

    private static func flatten(_ outline: PDFOutline?, depth: Int,
                                into result: inout [NavigationSnapshot.OutlineEntry]) {
        guard let outline else { return }
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            let target = child.destination?.page.flatMap { page in
                page.document?.index(for: page)
            } ?? -1
            result.append(NavigationSnapshot.OutlineEntry(
                depth: depth, label: child.label ?? "", targetPage: target))
            flatten(child, depth: depth + 1, into: &result)
        }
    }

    // MARK: - Vergleich

    /// Schweregrad einer Abweichung – der Corpus-Runner leitet daraus sein
    /// Gate ab (Masterplan Finding 3: kein globales Toleranzfenster).
    enum Severity: String, Codable, Sendable, Comparable {
        case critical, high, medium, low

        private var rank: Int {
            switch self {
            case .critical: return 0
            case .high: return 1
            case .medium: return 2
            case .low: return 3
            }
        }
        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    /// Stabile Kennung eines Vergleichspunkts.
    ///
    /// Der Anzeigetext (`field`) ist für Menschen und enthält Seitennummern;
    /// er taugt nicht zum Vergleichen. Wer eine Abweichung als erwartet
    /// erklären will, nennt sie hier – ausdrücklich und nachlesbar.
    enum Kind: String, Codable, Sendable, CaseIterable {
        case pageCount, geometry, textLoss, textContent
        case annotations, links, formWidgets, externalLinks
        case outline, outlineTargets, namedDestinations, internalLinks
        case formFields, fieldValue, signatures, attachments, pageLabels
        case metadata, fieldType, fieldFlags, outlineStructure
        case namedDestinationTarget, attachmentContent
    }

    struct Difference: Equatable, Codable, Sendable {
        var kind: Kind
        var field: String
        var before: String
        var after: String
        var severity: Severity

        /// Als erwartet erklärte Abweichung – gehört zur Operation und
        /// zählt nicht als Mangel (siehe `differences(_:_:expecting:)`).
        var isExpected = false

        /// V2-5 (§11.2) – betroffene PDF-Seitennummern (1-basiert) für
        /// seitenbezogene Abweichungen; leer auf Dokumentebene. Additiv:
        /// bestehende Vergleiche und Meldungen bleiben unverändert.
        var pages: [Int] = []

        init(kind: Kind, field: String, before: String, after: String,
             severity: Severity, pages: [Int] = [], isExpected: Bool = false) {
            self.kind = kind
            self.field = field
            self.before = before
            self.after = after
            self.severity = severity
            self.pages = pages
            self.isExpected = isExpected
        }

        var message: String {
            (isExpected ? "[erwartet] " : "") + "\(field): \(before) → \(after)"
        }
    }

    /// Formular-Flags in Klartext – „1" sagt niemandem etwas, „schreibgeschützt"
    /// schon. Die Bits stehen in PDF 32000-1, Tabelle 221.
    static func formFlagText(_ flags: Int) -> String {
        var names: [String] = []
        if flags & 1 != 0 { names.append("schreibgeschützt") }
        if flags & 2 != 0 { names.append("Pflichtfeld") }
        if flags & 4 != 0 { names.append("nicht exportieren") }
        if names.isEmpty { return flags == 0 ? "keine" : "Bits \(flags)" }
        return names.joined(separator: ", ") + " (\(flags))"
    }

    /// Klare, verständliche Diagnosen – keine stillen Ignores.
    /// - Parameter expecting: Abweichungsarten, die für die laufende
    ///   Operation zur Aufgabe gehören. Wer Seiten auswählt, verliert
    ///   zwangsläufig Outline-Einträge – das ist kein Mangel, sondern die
    ///   Operation. Solche Fälle werden hier ANGEMELDET, nicht durch eine
    ///   milde Einstufung verdeckt: Sie erscheinen weiter im Bericht, als
    ///   `[erwartet]` markiert und auf `.low` gesetzt (Final Core Hardening
    ///   5.3 – Produktpolitik gehört in die Policy, nicht in die Severity).
    /// - Parameter pageMapping: Quellseite → Ausgabeseite, für Operationen,
    ///   die Seiten umordnen oder auswählen. Ohne sie wäre jedes korrekt
    ///   umgehängte Sprungziel eine Abweichung: Nach einer Umkehrung zeigt
    ///   das Lesezeichen richtigerweise auf eine ANDERE Seitennummer als
    ///   vorher. Mit ihr wird geprüft, ob es auf die richtige zeigt
    ///   (Final Core Hardening 6.7 – „targets remapped").
    static func differences(_ before: PDFSemanticSnapshot,
                            _ after: PDFSemanticSnapshot,
                            expecting: Set<Kind> = [],
                            pageMapping: [Int: Int]? = nil) -> [Difference] {
        var diffs: [Difference] = []
        // V2-5 (§11.2) – seitenbezogene Abweichungen tragen ihre PDF-
        // Seitennummern (1-basiert), damit maschinenlesbare Findings daraus
        // implicierte Ressourcen herleiten können.
        func add(_ kind: Kind, _ field: String, _ b: String, _ a: String,
                 _ s: Severity, pages: [Int] = []) {
            let expected = expecting.contains(kind)
            diffs.append(Difference(kind: kind, field: field, before: b,
                                    after: a,
                                    severity: expected ? .low : s,
                                    pages: pages,
                                    isExpected: expected))
        }

        /// Wo eine Quellseite nach der Operation liegt.
        ///
        /// Ohne Zuordnung ist das die Seite selbst – richtig für Kompression,
        /// die keine Seite bewegt. Mit Zuordnung wird aus „zeigte auf Seite 3"
        /// die Frage „zeigt es auf die Seite, auf der Seite 3 jetzt liegt?".
        /// `-1` heißt: unauflösbar, hier wie dort.
        func mapped(_ sourcePage: Int) -> Int {
            guard sourcePage >= 0 else { return sourcePage }
            guard let pageMapping else { return sourcePage }
            // Nicht übernommene Seite: Das Ziel kann nicht mehr existieren.
            return pageMapping[sourcePage] ?? -1
        }

        func pageText(_ page: Int) -> String {
            page < 0 ? "kein Ziel" : "Seite \(page + 1)"
        }

        if before.pageCount != after.pageCount {
            add(.pageCount, "Seitenzahl", "\(before.pageCount)", "\(after.pageCount)", .critical)
        }

        for (i, b) in before.pages.enumerated() {
            guard i < after.pages.count else { break }
            let a = after.pages[i]
            let page = "Seite \(i + 1)"
            let pageNumber = [i + 1]

            if !boxesMatch(b.mediaBox, a.mediaBox) {
                add(.geometry, "\(page) MediaBox", boxText(b.mediaBox), boxText(a.mediaBox), .critical, pages: pageNumber)
            }
            if !boxesMatch(b.cropBox, a.cropBox) {
                add(.geometry, "\(page) CropBox", boxText(b.cropBox), boxText(a.cropBox), .critical, pages: pageNumber)
            }
            if b.rotation != a.rotation {
                add(.geometry, "\(page) Rotation", "\(b.rotation)°", "\(a.rotation)°", .critical, pages: pageNumber)
            }
            if b.textCharacterCount > 0 && a.textCharacterCount == 0 {
                add(.textLoss, "\(page) Text", "\(b.textCharacterCount) Zeichen", "0", .critical, pages: pageNumber)
            } else if !b.textFingerprint.isEmpty,
                      !a.textFingerprint.isEmpty,
                      b.textFingerprint != a.textFingerprint {
                add(.textContent, "\(page) Textinhalt", b.textFingerprint, a.textFingerprint, .high, pages: pageNumber)
            }
            if a.annotationCount < b.annotationCount {
                add(.annotations, "\(page) Annotationen", "\(b.annotationCount)", "\(a.annotationCount)", .high, pages: pageNumber)
            }
            if a.linkCount < b.linkCount {
                add(.links, "\(page) Links", "\(b.linkCount)", "\(a.linkCount)", .high, pages: pageNumber)
            }
            if a.widgetCount < b.widgetCount {
                add(.formWidgets, "\(page) Formularfelder", "\(b.widgetCount)", "\(a.widgetCount)", .high, pages: pageNumber)
            }
        }

        let lostURLs = Set(before.navigation.externalLinkURLs)
            .subtracting(after.navigation.externalLinkURLs)
        if !lostURLs.isEmpty {
            add(.externalLinks, "Externe Links", lostURLs.sorted().joined(separator: ", "), "fehlen", .high)
        }

        // Ein verlorenes Lesezeichen ist für den Leser ein verlorener
        // Zugang zum Dokument. Bei Operationen, die keine Seiten wegnehmen,
        // gibt es dafür keinen Grund – deshalb blockierend. Wer Seiten
        // auswählt, meldet den Verlust über `expecting` an.
        if before.navigation.outline.count > after.navigation.outline.count {
            add(.outline, "Outline-Einträge", "\(before.navigation.outline.count)",
                "\(after.navigation.outline.count)", .high)
        }

        // Bis hierher zählt der Vergleich nur. „20 Lesezeichen vorher, 20
        // nachher" beweist aber nicht, dass sie noch dorthin zeigen, wo sie
        // hingehören – und genau das ist die Frage (Final Core Hardening 6.1).
        //
        // Verglichen wird beides getrennt, damit die Meldung sagt, WAS anders
        // ist: der Baum (Reihenfolge, Verschachtelung, Beschriftung) oder die
        // Ziele.
        if before.navigation.outline.count == after.navigation.outline.count {
            let shape = { (e: NavigationSnapshot.OutlineEntry) in
                "\(String(repeating: "·", count: e.depth))\(e.label)"
            }
            let shapeBefore = before.navigation.outline.map(shape)
            let shapeAfter = after.navigation.outline.map(shape)
            if shapeBefore != shapeAfter {
                let firstDiff = zip(shapeBefore, shapeAfter).enumerated()
                    .first { $0.element.0 != $0.element.1 }
                let where_ = firstDiff.map { "Eintrag \($0.offset + 1)" } ?? "Aufbau"
                add(.outlineStructure, "Outline-Baum (\(where_))",
                    firstDiff?.element.0 ?? shapeBefore.joined(separator: " / "),
                    firstDiff?.element.1 ?? shapeAfter.joined(separator: " / "),
                    .high)
            }

            for (b, a) in zip(before.navigation.outline, after.navigation.outline)
            where b.label == a.label {
                let expected = mapped(b.targetPage)
                if expected != a.targetPage {
                    add(.outline, "Outline-Ziel „\(b.label)“",
                        pageText(expected), pageText(a.targetPage), .high)
                }
            }
        }
        let danglingBefore = before.navigation.outline.filter { $0.targetPage < 0 }.count
        let danglingAfter = after.navigation.outline.filter { $0.targetPage < 0 }.count
        if danglingAfter > danglingBefore {
            add(.outlineTargets, "Outline-Ziele unauflösbar", "\(danglingBefore)", "\(danglingAfter)", .high)
        }

        // Benannte Ziele tragen Querverweise – auch solche aus anderen
        // Dokumenten. Fallen sie weg, zeigen fremde Verweise ins Leere,
        // ohne dass man es diesem Dokument ansieht.
        if before.navigation.namedDestinations.count
            > after.navigation.namedDestinations.count {
            add(.namedDestinations, "Named Destinations", "\(before.navigation.namedDestinations.count)",
                "\(after.navigation.namedDestinations.count)", .high)
        }

        // Auch hier zählt die Anzahl nichts. Ein Ziel, das seinen Namen
        // behält und auf eine andere Seite zeigt, ist ein kaputter Verweis –
        // und zwar einer, den man dem Dokument nicht ansieht (6.2).
        let destsAfter = Dictionary(
            after.navigation.namedDestinations.map { ($0.name, $0.targetPage) },
            uniquingKeysWith: { first, _ in first })
        var vanishedNames: [String] = []
        for d in before.navigation.namedDestinations {
            guard let actual = destsAfter[d.name] else {
                vanishedNames.append(d.name)
                continue
            }
            let expected = mapped(d.targetPage)
            if expected != actual {
                add(.namedDestinationTarget, "Ziel „\(d.name)“",
                    pageText(expected), pageText(actual), .high)
            }
        }
        if !vanishedNames.isEmpty {
            add(.namedDestinations, "Benannte Ziele",
                vanishedNames.sorted().joined(separator: ", "), "fehlen", .high)
        }

        let newDangling = after.navigation.internalLinkTargets.filter { $0 == -1 }.count
        let oldDangling = before.navigation.internalLinkTargets.filter { $0 == -1 }.count
        if newDangling > oldDangling {
            add(.internalLinks, "Kaputte interne Links", "\(oldDangling)", "\(newDangling)", .high)
        }

        // Bis hierher wurde nur gezählt, wie viele Links ins Leere zeigen.
        // Ein Link, der von derselben Stelle plötzlich woandershin führt,
        // fiel dabei nicht auf: Die Zahl der kaputten Links bleibt gleich
        // (6.3).
        //
        // Wiedererkannt wird ein Link an Quellseite und Verweisfläche – das
        // ist seine Identität auf dem Papier. Bei Seitenauswahl greift der
        // Vergleich nicht: dort ändern sich die Quellseiten planmäßig, und
        // die Prüfung „behält die übernommene Seite ihre Links?" macht
        // PDFValidator mit der Seitenzuordnung.
        if pageMapping == nil, !before.navigation.links.isEmpty {
            // Wiedererkannt wird ein Link an Quellseite und Verweisfläche.
            // Das trägt nur, solange die Fläche ihn eindeutig macht – und
            // genau das ist nicht immer so: `SP.800-37r2.pdf` enthält Links
            // mit entartetem Rahmen (Breite und Höhe null), sechs davon auf
            // einer Seite. Wer da über die Fläche zuordnet, vergleicht Link A
            // gegen Link B und meldet einen Unterschied, den es nicht gibt.
            //
            // Mehrdeutige Flächen werden deshalb übergangen. Über sie lässt
            // sich ehrlich nichts sagen; sie erfinden statt zu prüfen.
            func place(_ l: NavigationSnapshot.Link) -> String {
                "\(l.sourcePage)@\(l.bounds)"
            }
            var beforeCounts: [String: Int] = [:]
            for l in before.navigation.links { beforeCounts[place(l), default: 0] += 1 }
            var afterCounts: [String: Int] = [:]
            for l in after.navigation.links { afterCounts[place(l), default: 0] += 1 }

            let afterByPlace = Dictionary(
                after.navigation.links.map { (place($0), $0) },
                uniquingKeysWith: { first, _ in first })
            for b in before.navigation.links {
                let place = place(b)
                guard beforeCounts[place] == 1, afterCounts[place] == 1,
                      let a = afterByPlace[place] else { continue }
                let at = "Link auf Seite \(b.sourcePage + 1)"
                if b.destinationType != a.destinationType {
                    add(.internalLinks, "\(at): Zielart",
                        b.destinationType, a.destinationType, .high)
                } else if b.namedDestination != a.namedDestination {
                    add(.internalLinks, "\(at): Zielname",
                        b.namedDestination.isEmpty ? "keiner" : b.namedDestination,
                        a.namedDestination.isEmpty ? "keiner" : a.namedDestination, .high)
                } else if b.targetPage != a.targetPage {
                    add(.internalLinks, "\(at): Ziel",
                        pageText(b.targetPage), pageText(a.targetPage), .high)
                }
            }
        }

        let lostFields = Set(before.form.fieldNames).subtracting(after.form.fieldNames)
        if !lostFields.isEmpty {
            add(.formFields, "Formularfelder", lostFields.sorted().joined(separator: ", "), "fehlen", .high)
        }
        for b in before.form.fields {
            guard let a = after.form.fields.first(where: { $0.name == b.name }) else { continue }
            if b.value != a.value {
                add(.fieldValue, "Feldwert \(b.name)", b.value, a.value, .high)
            }
            // Typ und Flags standen im Schnappschuss und wurden nie geprüft
            // (6.5). Aus einem Textfeld einen Knopf zu machen oder ein Feld
            // schreibgeschützt zu setzen ändert, was der Nutzer mit dem
            // Formular tun kann – ohne dass ein Wert sich ändert.
            if b.type != a.type {
                add(.fieldType, "Feldtyp \(b.name)", b.type, a.type, .high)
            }
            if b.flags != a.flags {
                add(.fieldFlags, "Feld-Flags \(b.name)",
                    formFlagText(b.flags), formFlagText(a.flags), .high)
            }
        }
        // Zur Klarstellung, weil hier zwei Dinge verwechselt werden können:
        // Geprüft wird, ob das Signaturfeld noch DA ist – nicht, ob die
        // Signatur noch GÜLTIG ist. Gültigkeit kann keine Bearbeitung
        // erhalten, die Streams neu schreibt; darauf weist `reportsSignatures`
        // als Warnung hin. Das Feld selbst verschwinden zu lassen wäre
        // dagegen stiller Datenverlust.
        if before.form.signatures.count > after.form.signatures.count {
            add(.signatures, "Signaturen", "\(before.form.signatures.count)",
                "\(after.form.signatures.count)", .high)
        }

        let lostAttachments = Set(before.attachments.map(\.name))
            .subtracting(after.attachments.map(\.name))
        // Ein Anhang ist eingebettete Nutzerdatei. Ihn zu verlieren ist
        // Datenverlust, kein Nebeneffekt – strenger als der Plan verlangt,
        // und durch die Sonde gedeckt: Kompression erhält Anhänge.
        if !lostAttachments.isEmpty {
            add(.attachments, "Attachments", lostAttachments.sorted().joined(separator: ", "),
                "fehlen", .high)
        }
        // Ein Anhang mit gleichem Namen und anderem INHALT ist ein anderer
        // Anhang (6.6).
        //
        // Verglichen wird der dekodierte Inhalt, nicht seine Speicherform.
        // Die erste Fassung nahm die gespeicherte Länge und meldete daraufhin
        // 120 Fehlschläge auf 24 einwandfreien Korpusdokumenten: qpdf packt
        // eingebettete Ströme nach, „3968 → 3773 Bytes" bei bitgleichem
        // Inhalt. Ein Vergleich, der die Verpackung misst, sagt über den
        // Inhalt nichts.
        for b in before.attachments {
            guard let a = after.attachments.first(where: { $0.name == b.name })
            else { continue }
            if b.contentHash != "-", a.contentHash != "-",
               b.contentHash != a.contentHash {
                add(.attachmentContent, "Anhang „\(b.name)“",
                    "\(b.byteCount) Bytes", "\(a.byteCount) Bytes", .high)
            } else if b.contentHash == "-" || a.contentHash == "-",
                      b.byteCount >= 0, a.byteCount >= 0,
                      b.byteCount != a.byteCount {
                // Ohne Prüfsumme bleibt nur die Länge – dann aber die des
                // dekodierten Stroms, nicht die gespeicherte.
                add(.attachmentContent, "Anhang „\(b.name)“ (Länge)",
                    "\(b.byteCount) Bytes", "\(a.byteCount) Bytes", .high)
            }
        }

        // Titel und Autor sind Eingaben des Nutzers. Verschwinden sie, ohne
        // dass es jemand verlangt hat, ist das Datenverlust. Wer sie
        // absichtlich entfernt (Metadaten strippen), meldet das über
        // `expecting` an – dann steht die Absicht im Bericht statt eines
        // stillen Wegfalls (Final Core Hardening 5.3).
        let lostMetadata = zip(before.document.userMetadata,
                               after.document.userMetadata)
            .filter { !$0.1.isEmpty && $1.1.isEmpty }
        if !lostMetadata.isEmpty {
            add(.metadata, "Dokumentinformation",
                lostMetadata.map { "\($0.0)=\($0.1)" }.joined(separator: ", "),
                "fehlt", .high)
        }

        // Ohne Seitenbezeichnungen stimmt die angezeigte Seitenzahl nicht
        // mehr mit der gedruckten überein – bei römisch nummerierten
        // Vorspannseiten sofort sichtbar.
        if before.document.hasPageLabels && !after.document.hasPageLabels {
            add(.pageLabels, "Page Labels", "vorhanden", "fehlen", .high)
        } else if before.document.hasPageLabels,
                  before.document.pageLabelRanges != after.document.pageLabelRanges,
                  pageMapping == nil {
            // Die Bereiche lagen längst im Schnappschuss und wurden nie
            // angesehen: „vorhanden" gegen „vorhanden" ging als Gleichheit
            // durch, auch wenn aus römischen Vorspannseiten arabische wurden
            // (6.4). Bei Seitenauswahl greift der Vergleich nicht – dort
            // verschieben sich die Bereichsgrenzen zwangsläufig.
            add(.pageLabels, "Seitenbezeichnungen",
                before.document.pageLabelRanges.joined(separator: " / "),
                after.document.pageLabelRanges.joined(separator: " / "), .high)
        }

        return diffs
    }

    /// Differential zweier BACKENDS über dieselbe Datei (nicht vorher/nachher).
    /// Beweist, dass libqpdf und PDFKit dasselbe Dokument gleich verstehen –
    /// Grundlage für den Cutover-Nachweis (Masterplan Finding 17).
    ///
    /// Verglichen werden ausschließlich Felder, die beide Backends belegen:
    /// Text kennt nur PDFKit, Named Destinations nur libqpdf.
    static func backendDifferences(_ a: PDFSemanticSnapshot,
                                   _ b: PDFSemanticSnapshot) -> [String] {
        var diffs: [String] = []
        let an = a.backend.rawValue, bn = b.backend.rawValue

        if a.pageCount != b.pageCount {
            diffs.append("\(an) Seitenzahl \(a.pageCount) ≠ \(bn) \(b.pageCount)")
        }
        for (i, pa) in a.pages.enumerated() {
            guard i < b.pages.count else { break }
            let pb = b.pages[i]
            if !boxesMatch(pa.mediaBox, pb.mediaBox) {
                diffs.append("Seite \(i + 1): MediaBox \(an) \(boxText(pa.mediaBox)) "
                    + "vs \(bn) \(boxText(pb.mediaBox))")
            }
            if !boxesMatch(pa.cropBox, pb.cropBox) {
                diffs.append("Seite \(i + 1): CropBox \(an) \(boxText(pa.cropBox)) "
                    + "vs \(bn) \(boxText(pb.cropBox))")
            }
            if pa.rotation != pb.rotation {
                diffs.append("Seite \(i + 1): Rotation \(an) \(pa.rotation)° "
                    + "vs \(bn) \(pb.rotation)°")
            }
        }

        // Annotationszahlen vergleicht libqpdf dokumentweit, PDFKit je Seite.
        let aTotals = a.annotationTotals, bTotals = b.annotationTotals
        if aTotals.annotations != bTotals.annotations {
            diffs.append("Annotationen \(an) \(aTotals.annotations) vs \(bn) \(bTotals.annotations)")
        }
        if aTotals.links != bTotals.links {
            diffs.append("Links \(an) \(aTotals.links) vs \(bn) \(bTotals.links)")
        }
        if aTotals.widgets != bTotals.widgets {
            diffs.append("Widgets \(an) \(aTotals.widgets) vs \(bn) \(bTotals.widgets)")
        }

        if !a.outlineLabels.isEmpty && !b.outlineLabels.isEmpty
            && a.outlineLabels != b.outlineLabels {
            diffs.append("Outline-Labels \(an) \(a.outlineLabels) vs \(bn) \(b.outlineLabels)")
        }
        if !a.formFieldNames.isEmpty && !b.formFieldNames.isEmpty
            && a.formFieldNames.count != b.formFieldNames.count {
            diffs.append("Formularfelder \(an) \(a.formFieldNames.count) "
                + "vs \(bn) \(b.formFieldNames.count)")
        }
        return diffs
    }

    /// Dokumentweite Annotationssummen – der libqpdf-Capture legt sie bei
    /// mehrseitigen Dokumenten nicht je Seite ab, deshalb zentral summiert.
    var annotationTotals: (annotations: Int, links: Int, widgets: Int) {
        (pages.reduce(0) { $0 + $1.annotationCount },
         pages.reduce(0) { $0 + $1.linkCount },
         pages.reduce(0) { $0 + $1.widgetCount })
    }

    /// Rückwärtskompatible Textform für bestehende Aufrufer.
    static func compare(_ before: PDFSemanticSnapshot,
                        _ after: PDFSemanticSnapshot) -> [String] {
        differences(before, after).map(\.message)
    }

    /// Boxen gelten als gleich, wenn alle vier Koordinaten innerhalb von 1 pt
    /// liegen – Writer runden Fließkommawerte unterschiedlich.
    private static func boxesMatch(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == 4, b.count == 4 else { return a == b }
        return zip(a, b).allSatisfy { abs($0 - $1) <= 1.0 }
    }

    private static func boxText(_ box: [Double]) -> String {
        guard box.count == 4 else { return "?" }
        return box.map { String(format: "%.0f", $0) }.joined(separator: ",")
    }
}
