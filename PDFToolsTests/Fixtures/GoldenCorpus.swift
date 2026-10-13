import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan Finding 19 / Schritt 10 – Golden- und Malformed-Korpus.
///
/// Beide Korpora werden GENERIERT, nicht als Binärdateien mitgeliefert.
/// Der Masterplan verlangt „physisch vorhanden ODER reproduzierbar"; ein
/// Generator ist die stärkere Variante:
///   - er ist versioniert und im Review lesbar,
///   - er kann nicht stillschweigend verrutschen wie eine kopierte Datei,
///   - und er trägt die Erwartungen direkt neben dem Dokument, das sie erfüllt.
///
/// Jeder Eintrag bringt seine EXAKTE Erwartung mit. Golden heißt: 100 % PASS.
enum GoldenCorpus {

    // MARK: - Erwartungen

    /// Was ein Golden-Dokument nachweislich enthält. Nur Eigenschaften, die
    /// der Snapshot auch wirklich messen kann – keine Wunschangaben.
    struct Expectation: Codable, Equatable {
        var pageCount: Int
        var outlineEntries: Int?
        var namedDestinations: Int?
        var formFields: Int?
        var signatures: Int?
        var attachments: Int?
        var hasPageLabels: Bool?
        var externalLinks: Int?
        /// Bild-XObjects je Objektidentität (nicht je Platzierung).
        var imageObjects: Int?
        /// Bilder, die die Capability-Politik NICHT transformieren darf.
        var untransformableImages: Int?
        var hasText: Bool?

        init(pageCount: Int) { self.pageCount = pageCount }
    }

    struct Entry {
        let category: String
        let name: String
        let expectation: Expectation
        let make: () throws -> URL
    }

    // MARK: - Katalog

    /// Die Kategorien stammen wörtlich aus Masterplan Schritt 10.
    static var entries: [Entry] {
        var list: [Entry] = []

        func add(_ category: String, _ name: String,
                 _ expectation: Expectation,
                 _ make: @escaping () throws -> URL) {
            list.append(Entry(category: category, name: name,
                              expectation: expectation, make: make))
        }

        // --- complex links / bookmarks / named destinations ------------------
        var linkExpectation = Expectation(pageCount: 2)
        linkExpectation.outlineEntries = 2
        linkExpectation.hasText = true
        linkExpectation.namedDestinations = 0
        add("navigation", "outline-internal-link", linkExpectation) {
            try PDFFixtures.outlinedWithInternalLinkPDF()
        }

        var namedExpectation = Expectation(pageCount: 2)
        namedExpectation.namedDestinations = 2
        namedExpectation.hasText = true
        namedExpectation.outlineEntries = 0
        add("navigation", "named-destinations", namedExpectation) {
            try PDFFixtures.namedDestinationPDF()
        }

        var nestedExpectation = Expectation(pageCount: 2)
        nestedExpectation.outlineEntries = 2
        nestedExpectation.hasText = false
        add("navigation", "nested-outline", nestedExpectation) {
            try PDFFixtures.nestedOutlinePDF()
        }

        var externalExpectation = Expectation(pageCount: 1)
        externalExpectation.externalLinks = 1
        externalExpectation.hasText = true
        externalExpectation.imageObjects = 0
        add("navigation", "external-links", externalExpectation) {
            try PDFFixtures.rawExternalLinkPDF()
        }

        // Die PDFKit-Annotationsfixture rastert ihre Seite beim Schreiben –
        // sie prüft deshalb Annotationserhalt, NICHT Texterhalt.
        var annotationExpectation = Expectation(pageCount: 1)
        annotationExpectation.externalLinks = 1
        annotationExpectation.hasText = false
        add("navigation", "rasterized-annotations", annotationExpectation) {
            try PDFFixtures.multiAnnotationPDF()
        }

        // --- forms ----------------------------------------------------------
        var formExpectation = Expectation(pageCount: 1)
        formExpectation.formFields = 2
        add("forms", "form-hierarchy", formExpectation) {
            try PDFFixtures.formHierarchyPDF()
        }

        var widgetExpectation = Expectation(pageCount: 2)
        widgetExpectation.formFields = 2
        add("forms", "form-widgets", widgetExpectation) {
            try PDFFixtures.formWidgetsPDF()
        }

        var signatureExpectation = Expectation(pageCount: 1)
        signatureExpectation.signatures = 1
        // Das Signaturfeld ist auch ein Formularfeld – beide Listen sehen es.
        signatureExpectation.formFields = 1
        add("forms", "signature-field", signatureExpectation) {
            try PDFFixtures.signatureFieldPDF()
        }

        var utf16Expectation = Expectation(pageCount: 1)
        utf16Expectation.formFields = 1
        add("forms", "utf16-field-names", utf16Expectation) {
            try PDFFixtures.utf16FormFieldPDF()
        }

        // --- page labels ----------------------------------------------------
        var labelExpectation = Expectation(pageCount: 3)
        labelExpectation.hasPageLabels = true
        add("page-labels", "roman-then-decimal", labelExpectation) {
            try PDFFixtures.pageLabelPDF()
        }

        // --- attachments ----------------------------------------------------
        var attachmentExpectation = Expectation(pageCount: 1)
        attachmentExpectation.attachments = 1
        add("attachments", "single-embedded-file", attachmentExpectation) {
            try PDFFixtures.attachmentPDF()
        }

        // --- shared XObjects ------------------------------------------------
        var sharedExpectation = Expectation(pageCount: 2)
        sharedExpectation.imageObjects = 1
        sharedExpectation.untransformableImages = 0
        add("shared-xobjects", "shared-image-two-pages", sharedExpectation) {
            try PDFFixtures.sharedImageObjectPDF(pixels: 600)
        }

        var sameNameExpectation = Expectation(pageCount: 2)
        sameNameExpectation.imageObjects = 2
        add("shared-xobjects", "same-name-different-objects", sameNameExpectation) {
            try PDFFixtures.sameResourceNameDifferentObjectsPDF(pixels: 600).url
        }

        // --- masks / transparency -------------------------------------------
        var maskExpectation = Expectation(pageCount: 1)
        // Nur EIN Objekt: Das Maskenbild hängt am Bilddictionary, nicht an
        // den Seitenressourcen – der Ressourcen-Walk sieht es zu Recht nicht.
        maskExpectation.imageObjects = 1
        // Ein maskiertes Bild ist TRANSFORMIERBAR.
        //
        // Hier stand 1 – die Erwartung, dass es unangetastet bleibt. Sie
        // beruhte auf der Annahme, Bild und Maske müssten gemeinsam
        // umgerechnet werden. Nach PDF 32000-1 §8.9.6.4 wird eine weiche
        // Maske auf ihr Basisbild skaliert und muss dessen Masse nicht
        // teilen; das Bild darf also allein neu kodiert werden, solange die
        // Maskenbeziehung im Wörterbuch erhalten bleibt.
        //
        // Die alte Erwartung kostete 143,5 MB im Korpus – 40 % aller
        // Bilddaten.
        maskExpectation.untransformableImages = 0
        add("masks", "soft-masked-image", maskExpectation) {
            try PDFFixtures.softMaskedImagePDF(pixels: 600)
        }

        var decodeExpectation = Expectation(pageCount: 1)
        decodeExpectation.imageObjects = 1
        decodeExpectation.untransformableImages = 1
        add("masks", "decode-array-image", decodeExpectation) {
            try PDFFixtures.decodeArrayImagePDF(pixels: 600)
        }

        let transparencyExpectation = Expectation(pageCount: 1)
        add("masks", "transparency", transparencyExpectation) {
            try PDFFixtures.transparentPDF()
        }

        // --- unsupported filters --------------------------------------------
        // Phase V2-3c (§9.10): CCITTFaxDecode-EINGÄNGE sind inzwischen
        // dekodierbar (eigener Fax-Shim, Bilevel-Race) – die Eingangs-Sperre
        // trägt nur noch JBIG2Decode, und selbst für CCITT nur für die
        // regulären (resamplenden) Pfade. Diese Fixture bleibt DENNOCH
        // untransformierbar, und zwar aus anderen Gründen als früher: Sie
        // trägt BitsPerComponent 8 (CCITTFaxDecode verlangt laut Norm 1)
        // und NUR DEN DecodeParms-DUMMY-Inhalt ohne /K – der Katalog
        // verweigert beides deterministisch, bevor ein Decode läuft. Ein
        // gültiger CCITT-Eingang wäre inzwischen transformierbar; der
        // Erwartungswert (1 untransformiert) bleibt trotzdem bestehen.
        var ccittExpectation = Expectation(pageCount: 1)
        ccittExpectation.imageObjects = 1
        ccittExpectation.untransformableImages = 1
        add("filters", "unsupported-ccitt", ccittExpectation) {
            try PDFFixtures.unsupportedFilterImagePDF(pixels: 600)
        }

        var flateExpectation = Expectation(pageCount: 1)
        flateExpectation.imageObjects = 1
        flateExpectation.untransformableImages = 0
        add("filters", "flate-image", flateExpectation) {
            try PDFFixtures.flateImagePDF(pixels: 400)
        }

        // --- fonts / text ----------------------------------------------------
        var textExpectation = Expectation(pageCount: 1)
        textExpectation.hasText = true
        textExpectation.imageObjects = 0
        add("text", "vector-text", textExpectation) {
            try PDFFixtures.vectorTextPDF(lines: 20)
        }

        var paragraphExpectation = Expectation(pageCount: 2)
        paragraphExpectation.hasText = true
        paragraphExpectation.imageObjects = 0
        add("text", "multi-paragraph", paragraphExpectation) {
            try PDFFixtures.rawMultiParagraphPDF(pages: 2)
        }

        var tinyExpectation = Expectation(pageCount: 1)
        tinyExpectation.hasText = true
        tinyExpectation.imageObjects = 0
        add("text", "tiny-text", tinyExpectation) {
            try PDFFixtures.rawTinyTextPDF()
        }

        var multiFontExpectation = Expectation(pageCount: 1)
        multiFontExpectation.hasText = true
        multiFontExpectation.imageObjects = 0
        add("text", "multiple-fonts", multiFontExpectation) {
            try PDFFixtures.multipleFontsPDF()
        }

        // --- photos / scans / bereits optimiert -------------------------------
        var photoExpectation = Expectation(pageCount: 1)
        photoExpectation.imageObjects = 1
        add("images", "photo-high-dpi", photoExpectation) {
            try PDFFixtures.placedPhotoPDF(pixels: 2400, placedPoints: 400)
        }

        var optimizedExpectation = Expectation(pageCount: 1)
        optimizedExpectation.imageObjects = 1
        add("images", "already-optimized", optimizedExpectation) {
            try PDFFixtures.placedPhotoPDF(pixels: 400, placedPoints: 400)
        }

        var scanExpectation = Expectation(pageCount: 3)
        scanExpectation.imageObjects = 3
        scanExpectation.hasText = false
        add("images", "scan-like", scanExpectation) {
            try PDFFixtures.scanLikePDF(pages: 3, pixels: 1200)
        }

        var screenshotExpectation = Expectation(pageCount: 1)
        screenshotExpectation.imageObjects = 1
        screenshotExpectation.untransformableImages = 0
        add("images", "screenshot", screenshotExpectation) {
            try PDFFixtures.screenshotLikePDF(pixels: 1200)
        }

        var grayscaleExpectation = Expectation(pageCount: 1)
        grayscaleExpectation.imageObjects = 1
        add("images", "grayscale", grayscaleExpectation) {
            try PDFFixtures.grayscalePDF()
        }

        let manyImagesExpectation = Expectation(pageCount: 1)
        add("images", "many-images", manyImagesExpectation) {
            try PDFFixtures.manyImagesPDF(count: 12)
        }

        // --- Geometrie --------------------------------------------------------
        var cropExpectation = Expectation(pageCount: 1)
        cropExpectation.hasText = true
        add("geometry", "cropbox-offset", cropExpectation) {
            try PDFFixtures.croppedPagePDF()
        }

        var mixedSizeExpectation = Expectation(pageCount: 3)
        mixedSizeExpectation.imageObjects = 3
        add("geometry", "mixed-page-sizes", mixedSizeExpectation) {
            try PDFFixtures.mixedSizesPDF()
        }

        var rotationExpectation = Expectation(pageCount: 4)
        rotationExpectation.imageObjects = 1
        add("geometry", "mixed-rotation", rotationExpectation) {
            try PDFFixtures.mixedRotationPDF()
        }

        let rotatedExpectation = Expectation(pageCount: 3)
        add("geometry", "rotated", rotatedExpectation) {
            try PDFFixtures.rotatedPDF()
        }

        // --- Struktur ---------------------------------------------------------
        var objectStreamExpectation = Expectation(pageCount: 2)
        objectStreamExpectation.hasText = true
        objectStreamExpectation.imageObjects = 1
        add("structure", "object-streams", objectStreamExpectation) {
            try PDFFixtures.objectStreamPDF()
        }

        var comboExpectation = Expectation(pageCount: 4)
        comboExpectation.outlineEntries = 2
        comboExpectation.externalLinks = 1
        comboExpectation.imageObjects = 3
        add("structure", "complex-combination", comboExpectation) {
            try PDFFixtures.complexCombinationPDF()
        }

        let multiContentExpectation = Expectation(pageCount: 4)
        add("structure", "multi-content-types", multiContentExpectation) {
            try PDFFixtures.multiContentTypePDF()
        }

        return list
    }

    // MARK: - Erzeugen

    /// Schreibt den kompletten Golden-Korpus nach `<root>/Golden/<Kategorie>/`
    /// und legt ein maschinenlesbares Manifest daneben.
    @discardableResult
    static func generate(into root: URL) throws -> URL {
        let fm = FileManager.default
        let goldenRoot = root.appendingPathComponent("Golden", isDirectory: true)
        // Vollständig neu aufbauen: ein Rest aus einem alten Lauf würde
        // Erwartungen und Dateien auseinanderlaufen lassen.
        try? fm.removeItem(at: goldenRoot)
        try fm.createDirectory(at: goldenRoot, withIntermediateDirectories: true)

        var manifest: [String: Expectation] = [:]
        for entry in entries {
            let categoryDir = goldenRoot.appendingPathComponent(entry.category,
                                                                isDirectory: true)
            try fm.createDirectory(at: categoryDir, withIntermediateDirectories: true)
            let source = try entry.make()
            defer { try? fm.removeItem(at: source) }
            let destination = categoryDir.appendingPathComponent("\(entry.name).pdf")
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
            manifest["\(entry.category)/\(entry.name).pdf"] = entry.expectation
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest)
            .write(to: goldenRoot.appendingPathComponent("manifest.json"))
        return goldenRoot
    }

    /// Liest das Manifest eines erzeugten Golden-Korpus.
    static func manifest(at root: URL) throws -> [String: Expectation] {
        let url = root.appendingPathComponent("Golden/manifest.json")
        return try JSONDecoder().decode([String: Expectation].self,
                                        from: Data(contentsOf: url))
    }

    /// Prüft ein Dokument gegen seine Erwartung. Leeres Ergebnis = erfüllt.
    static func verify(_ url: URL, against expectation: Expectation) -> [String] {
        var problems: [String] = []
        guard let snapshot = try? PDFSemanticSnapshot.capture(url) else {
            return ["Dokument nicht lesbar"]
        }

        func check<T: Equatable>(_ label: String, _ expected: T?, _ actual: T) {
            guard let expected, expected != actual else { return }
            problems.append("\(label): erwartet \(expected), gefunden \(actual)")
        }

        check("Seitenzahl", expectation.pageCount, snapshot.pageCount)
        check("Outline-Einträge", expectation.outlineEntries,
              snapshot.navigation.outline.count)
        check("Named Destinations", expectation.namedDestinations,
              snapshot.navigation.namedDestinations.count)
        check("Formularfelder", expectation.formFields, snapshot.form.fields.count)
        check("Signaturen", expectation.signatures, snapshot.form.signatures.count)
        check("Attachments", expectation.attachments, snapshot.attachments.count)
        check("Page Labels", expectation.hasPageLabels, snapshot.document.hasPageLabels)
        check("Externe Links", expectation.externalLinks,
              snapshot.navigation.externalLinkURLs.count)

        if let expectedText = expectation.hasText {
            let hasText = snapshot.pages.contains { $0.textCharacterCount > 0 }
            check("Text vorhanden", expectedText, hasText)
        }

        if expectation.imageObjects != nil || expectation.untransformableImages != nil {
            guard let document = try? PDFCoreDocument(path: url.path),
                  let resources = try? document.imageResources() else {
                problems.append("Bildressourcen nicht lesbar")
                return problems
            }
            check("Bildobjekte", expectation.imageObjects, resources.count)
            check("Nicht transformierbare Bilder", expectation.untransformableImages,
                  resources.filter { !$0.transformCapability.isSafe }.count)
        }

        return problems
    }
}
