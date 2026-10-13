import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Final Core Hardening, Phase 5 – Kompression muss semantisch konservativ
/// sein.
///
/// Kompression ändert Bilddaten, sonst nichts. Geht dabei ein Lesezeichen,
/// ein Sprungziel oder die Seitennummerierung verloren, ist das Ergebnis
/// mangelhaft – kein Nebeneffekt, den man hinnimmt.
///
/// Vorher waren genau diese Verluste als MEDIUM eingestuft, während die
/// Kompressionspolitik erst ab HIGH scheitert. Ein Dokument konnte also seine
/// Navigation verlieren und trotzdem als PASS beim Nutzer landen. Diese Suite
/// hält das geschlossen.
@Suite struct CompressionSeverityTests {

    // MARK: - Einstufung

    /// Ein Schnappschusspaar, das sich in genau einem Punkt unterscheidet.
    /// Synthetisch, damit der Test die EINSTUFUNG prüft und nicht die
    /// Kompression – jeder Punkt einzeln, ohne Nebengeräusche.
    static func pair(losing kind: PDFSemanticSnapshot.Kind) throws
        -> (PDFSemanticSnapshot, PDFSemanticSnapshot) {
        let url = try PDFFixtures.outlineLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)
        var after = before

        switch kind {
        case .outline:
            after.navigation.outline = []
        case .namedDestinations:
            after.navigation.namedDestinations = []
        case .pageLabels:
            after.document.hasPageLabels = false
        case .attachments:
            after.attachments = []
        case .signatures:
            after.form.signatures = []
        default:
            Issue.record("kein Aufbau für \(kind.rawValue)")
        }
        return (before, after)
    }

    /// Vorbedingung: Das „Vorher" muss die Struktur überhaupt tragen, sonst
    /// prüft der Test nichts (ein Vergleich 0 → 0 meldet nie etwas).
    static func seeded(_ s: PDFSemanticSnapshot, _ kind: PDFSemanticSnapshot.Kind)
        -> PDFSemanticSnapshot {
        var s = s
        switch kind {
        case .outline where s.navigation.outline.isEmpty:
            s.navigation.outline = [.init(depth: 0, label: "Kapitel", targetPage: 0)]
        case .namedDestinations where s.navigation.namedDestinations.isEmpty:
            s.navigation.namedDestinations = [.init(name: "ziel", targetPage: 0)]
        case .pageLabels:
            s.document.hasPageLabels = true
        case .attachments where s.attachments.isEmpty:
            s.attachments = [.init(name: "anhang.txt", byteCount: 12)]
        case .signatures where s.form.signatures.isEmpty:
            s.form.signatures = [.init(fieldName: "Sig1", subFilter: "adbe.pkcs7.detached")]
        default: break
        }
        return s
    }

    /// Jeder dieser Verluste blockiert – bei einer Operation, die keine
    /// Seiten wegnimmt, gibt es für keinen davon einen Grund.
    @Test(.hangGuard, arguments: [
        PDFSemanticSnapshot.Kind.outline, .namedDestinations, .pageLabels,
        .attachments, .signatures,
    ])
    func structureLossIsBlocking(kind: PDFSemanticSnapshot.Kind) throws {
        var (before, after) = try Self.pair(losing: kind)
        before = Self.seeded(before, kind)

        let diffs = PDFSemanticSnapshot.differences(before, after)
        let mine = diffs.filter { $0.kind == kind }
        #expect(!mine.isEmpty, """
            Verlust „\(kind.rawValue)" wird gar nicht gemeldet. Gemeldet \
            wurde: \(diffs.map(\.message).joined(separator: "; "))
            """)
        for d in mine {
            #expect(d.severity <= .high, """
                „\(kind.rawValue)" ist als \(d.severity.rawValue) eingestuft \
                und damit für die Kompressionspolitik (Schwelle high) nicht \
                blockierend: \(d.message)
                """)
        }
    }

    /// Kein Vergleichspunkt darf unterhalb der Kompressionsschwelle liegen –
    /// sonst gibt es wieder einen Verlust, der still durchgeht. Der Test
    /// nimmt jede Art einzeln und lässt sie verschwinden.
    @Test(.hangGuard) func noComparisonPointFallsBelowThreshold() throws {
        let url = try PDFFixtures.outlineLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let base = try PDFSemanticSnapshot.capture(url)

        // Ein Schnappschuss, dem alles fehlt, was fehlen kann.
        var stripped = base
        stripped.navigation.outline = []
        stripped.navigation.namedDestinations = []
        stripped.navigation.externalLinkURLs = []
        stripped.document.hasPageLabels = false
        stripped.attachments = []
        stripped.form.signatures = []
        stripped.form.fields = []
        stripped.pages = stripped.pages.map {
            var p = $0
            p.annotationCount = 0
            p.linkCount = 0
            p.widgetCount = 0
            return p
        }
        let full = Self.seeded(Self.seeded(Self.seeded(
            Self.seeded(Self.seeded(base, .outline), .namedDestinations),
            .pageLabels), .attachments), .signatures)

        let diffs = PDFSemanticSnapshot.differences(full, stripped)
        #expect(!diffs.isEmpty, "Vollverlust erzeugt keine einzige Meldung")
        let weak = diffs.filter { $0.severity > .high }
        #expect(weak.isEmpty, """
            Diese Verluste liegen unter der Kompressionsschwelle und gingen \
            als PASS durch: \(weak.map { "\($0.kind.rawValue)=\($0.severity.rawValue)" }
                .joined(separator: ", "))
            """)
    }

    // MARK: - Produktpolitik (Plan 5.3)

    /// Kompression erklärt keine Ausnahme – und das ist eine Aussage, keine
    /// Auslassung.
    @Test func compressionDeclaresNoExceptions() {
        #expect(PDFValidator.Policy.compression.expectedDifferences.isEmpty, """
            Die Kompressionspolitik erklärt einen Strukturverlust für \
            erwartet. Wenn das gewollt ist, gehört die Begründung an die \
            Policy – und dieser Test angepasst.
            """)
        #expect(PDFValidator.Policy.compression.failsOnSemanticSeverity == .high)
    }

    /// Eine angemeldete Ausnahme verschwindet nicht aus dem Bericht – sie
    /// wird als solche kenntlich. Der Unterschied zu „mild eingestuft":
    /// Man sieht weiterhin, was passiert ist.
    @Test(.hangGuard) func expectedDifferenceStaysVisible() throws {
        var (before, after) = try Self.pair(losing: .outline)
        before = Self.seeded(before, .outline)

        let declared = PDFSemanticSnapshot.differences(
            before, after, expecting: [.outline])
        let entry = try #require(declared.first { $0.kind == .outline },
                                 "Ausnahme unterdrückt die Meldung komplett")
        #expect(entry.isExpected)
        #expect(entry.severity == .low)
        #expect(entry.message.hasPrefix("[erwartet]"))

        // Andere Arten bleiben davon unberührt.
        var lostBoth = after
        lostBoth.document.hasPageLabels = false
        var withLabels = before
        withLabels.document.hasPageLabels = true
        let mixed = PDFSemanticSnapshot.differences(
            withLabels, lostBoth, expecting: [.outline])
        let labels = try #require(mixed.first { $0.kind == .pageLabels })
        #expect(labels.severity <= .high,
                "Eine Ausnahme für Outlines darf Page Labels nicht mit entschärfen")
    }

    // MARK: - Der Validator blockt wirklich

    /// Der Beweis am echten Dokument: Eine Ausgabe, der Outline-Einträge
    /// fehlen, kommt durch die Kompressionspolitik nicht durch.
    ///
    /// Erzeugt wird der Verlust über eine Seitenauswahl – bei Assembly ist
    /// das die Operation und in Ordnung, bei Kompression wäre dieselbe Datei
    /// ein Mangel. Genau diese Unterscheidung soll die Politik treffen.
    @Test(.hangGuard) func validatorRejectsStructureLoss() async throws {
        let source = try PDFFixtures.nestedOutlinePDF()
        defer { try? FileManager.default.removeItem(at: source) }
        let doc = try #require(PDFDocument(url: source))
        try #require(doc.pageCount >= 2)
        let outlineCount = try PDFSemanticSnapshot.capture(source)
            .navigation.outline.count
        try #require(outlineCount > 0, "Fixture trägt keine Outline")

        let src = SourceDocument(url: source, pageCount: doc.pageCount)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sev-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(
            plan: PageAssemblyPlan(pages: [PageItem(source: src, pageIndex: 0)
                .assemblyItem]),
            to: out, progress: { _ in })

        let asCompression = PDFValidator.validate(
            outputURL: out, referenceURL: source,
            policy: .compression)
        #expect(!asCompression.isValid, """
            Eine Ausgabe mit \(outlineCount) verlorenen Outline-Einträgen \
            gilt als gültige Kompression.
            """)
        #expect(asCompression.failures.contains { $0.contains("Outline") },
                "Fehlschlag nennt den Grund nicht: \(asCompression.failures)")
    }

    /// Und dieselbe Datei ist als Seitenauswahl in Ordnung – der Verlust ist
    /// dort angemeldet, nicht verdeckt.
    @Test(.hangGuard) func sameLossIsAcceptedWhenDeclared() async throws {
        let source = try PDFFixtures.nestedOutlinePDF()
        defer { try? FileManager.default.removeItem(at: source) }
        let doc = try #require(PDFDocument(url: source))
        let src = SourceDocument(url: source, pageCount: doc.pageCount)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sev-ok-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(
            plan: PageAssemblyPlan(pages: [PageItem(source: src, pageIndex: 0)
                .assemblyItem]),
            to: out, progress: { _ in })

        var policy = PDFValidator.Policy.compression
        policy.expectedDifferences = [.outline, .namedDestinations, .pageLabels]
        policy.preservesText = false      // Teilmenge: dokumentweite Summen sinken
        policy.preservesLinks = false
        policy.preservesAnnotations = false
        policy.preservesForms = false
        policy.preservesGeometry = false
        policy.pageMapping = [0: 0]

        let report = PDFValidator.validate(outputURL: out, referenceURL: source,
                                           policy: policy)
        let structural = report.failures.filter {
            $0.contains("Outline") || $0.contains("Named") || $0.contains("Page Labels")
        }
        #expect(structural.isEmpty, """
            Angemeldeter Verlust scheitert trotzdem: \(structural)
            """)
    }
}

/// Was Kompression mit Navigation, Labels und Anhängen wirklich macht –
/// gemessen, nicht angenommen.
///
/// Diese Sonde ist der Grund, warum die Einstufungen oben angehoben werden
/// konnten, ohne die Suite mit falschen Fehlschlägen zu fluten: Sie belegt,
/// dass der Kompressionspfad diese Strukturen erhält.
@Suite(.serialized) struct CompressionStructurePreservation {

    static let fixtures: [(String, () throws -> URL)] = [
        ("nestedOutline",    PDFFixtures.nestedOutlinePDF),
        ("namedDestination", PDFFixtures.namedDestinationPDF),
        ("pageLabel",        PDFFixtures.pageLabelPDF),
        ("attachment",       PDFFixtures.attachmentPDF),
        ("outlineLink",      PDFFixtures.outlineLinkPDF),
        ("signatureField",   PDFFixtures.signatureFieldPDF),
    ]

    @Test(.hangGuard, arguments: fixtures.indices)
    func compressionPreservesStructure(index: Int) throws {
        let (name, make) = Self.fixtures[index]
        let input = try make()
        defer { try? FileManager.default.removeItem(at: input) }
        let before = try PDFSemanticSnapshot.capture(input)

        let result = try Compressor().compress(inputURL: input, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let after = try PDFSemanticSnapshot.capture(result.outputURL)

        let losses = PDFSemanticSnapshot.differences(before, after)
            .filter { $0.severity <= .high }
        #expect(losses.isEmpty, """
            \(name): Kompression verliert \
            \(losses.map(\.message).joined(separator: " | "))
            """)
    }
}

/// Final Core Hardening 5.3 – Metadaten: erhalten, wenn niemand ihr Entfernen
/// verlangt hat; angemeldet, wenn doch.
@Suite struct CompressionMetadataPolicyTests {

    /// Ohne Auftrag bleibt die Dokumentinformation stehen.
    @Test(.hangGuard) func metadataSurvivesPlainCompression() throws {
        let input = try PDFFixtures.metadataPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let before = try PDFSemanticSnapshot.capture(input)
        try #require(!before.document.title.isEmpty, "Fixture trägt keinen Titel")

        let result = try Compressor().compress(inputURL: input, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let after = try PDFSemanticSnapshot.capture(result.outputURL)

        #expect(after.document.title == before.document.title)
        #expect(after.document.author == before.document.author)
        #expect(after.document.subject == before.document.subject)
        #expect(after.document.keywords == before.document.keywords)
    }

    /// Der Verlust wird gemeldet – und zwar blockierend, solange ihn niemand
    /// angemeldet hat.
    @Test(.hangGuard) func unrequestedMetadataLossIsBlocking() throws {
        let input = try PDFFixtures.metadataPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let before = try PDFSemanticSnapshot.capture(input)
        var after = before
        after.document.title = ""
        after.document.author = ""

        let diff = try #require(
            PDFSemanticSnapshot.differences(before, after)
                .first { $0.kind == .metadata },
            "Metadatenverlust wird gar nicht bemerkt")
        #expect(diff.severity <= .high)
        #expect(diff.before.contains("Quartalsbericht Q3"),
                "Meldung nennt nicht, was fehlt: \(diff.message)")

        // Angemeldet: sichtbar, aber kein Mangel.
        let declared = try #require(
            PDFSemanticSnapshot.differences(before, after, expecting: [.metadata])
                .first { $0.kind == .metadata })
        #expect(declared.isExpected)
        #expect(declared.severity == .low)
    }

    /// Der Producer ändert sich bei jeder Bearbeitung – das ist kein Verlust
    /// und darf keine Meldung erzeugen.
    @Test(.hangGuard) func producerChangeIsNotAMetadataLoss() throws {
        let input = try PDFFixtures.metadataPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let before = try PDFSemanticSnapshot.capture(input)
        var after = before
        after.document.producer = "PDFTools \(UUID().uuidString)"

        #expect(PDFSemanticSnapshot.differences(before, after).isEmpty, """
            Ein geänderter Producer wird als Abweichung gemeldet.
            """)
    }

    /// Und wenn der Nutzer das Strippen verlangt, meldet der Kompressor es an
    /// – der Lauf scheitert nicht daran.
    @Test(.hangGuard) func strippingIsDeclaredAndSucceeds() throws {
        let input = try PDFFixtures.metadataPDF()
        defer { try? FileManager.default.removeItem(at: input) }

        var options = CompressionPresetFactory.smart(stripMetadata: true)
        options.linearizationPolicy = .none
        let result = try Compressor().compress(inputURL: input, options: options)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let after = try PDFSemanticSnapshot.capture(result.outputURL)
        #expect(after.document.title.isEmpty,
                "Strippen verlangt, Titel steht noch: \(after.document.title)")
    }
}

/// Gate 5, letzter Punkt – absichtlich beschädigte Dokumente kommen nicht
/// als gültiges Ergebnis durch.
///
/// Zwei Richtungen, die man leicht verwechselt:
///
/// 1. Als AUSGABE ist ein beschädigtes Dokument immer ein Fehlschlag. Egal
///    was hineinging, was herauskommt, muss lesbar sein.
/// 2. Als EINGABE ist ein beschädigtes Dokument erlaubt – Reparatur gehört
///    zur Aufgabe. Erlaubt ist aber nur zweierlei: ein sauberer Fehler oder
///    eine intakte Ausgabe. Ein „Erfolg" mit kaputtem Ergebnis ist keins.
@Suite(.serialized) struct MalformedOutputRejectionTests {

    static let damaged = MalformedCorpus.entries

    static func write(_ entry: MalformedCorpus.Entry) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-\(entry.name)-\(UUID().uuidString).pdf")
        try entry.make().write(to: url)
        return url
    }

    /// Ein beschädigtes Dokument als Kompressionsausgabe wird abgelehnt.
    @Test(.hangGuard, arguments: damaged.indices)
    func damagedOutputIsRejected(index: Int) throws {
        let entry = Self.damaged[index]
        // Referenz mit ECHTEM Text: `textPDF` rastert seinen Text in ein Bild
        // und hat null extrahierbare Zeichen – gegen die wäre jeder
        // Textvergleich stumm.
        let reference = try PDFFixtures.vectorTextPDF(lines: 20)
        defer { try? FileManager.default.removeItem(at: reference) }
        let broken = try Self.write(entry)
        defer { try? FileManager.default.removeItem(at: broken) }

        let report = PDFValidator.validate(outputURL: broken,
                                           referenceURL: reference,
                                           policy: .compression)
        #expect(!report.isValid, """
            „\(entry.name)“ (\(entry.defect)) gilt als gültige \
            Kompressionsausgabe.
            """)
    }

    /// Die Strukturprüfung allein – ohne Referenz – muss erkennen, was
    /// objektiv unlesbar ist.
    ///
    /// Sie erkennt bewusst NICHT alles. Drei Gruppen sind zu unterscheiden:
    ///
    /// - **unlesbar** (abgeschnitten, kaputter Trailer, kein PDF, Zyklus im
    ///   Seitenbaum, falsche /Length, zu kurzer Bildstream): Die Prüfung
    ///   schlägt an. Das sind Schäden, die man einer Datei ansieht.
    /// - **von qpdf repariert** (kaputte xref, ins Leere zeigender
    ///   /Contents-Verweis, falscher /Count): Beim Lesen normalisiert qpdf
    ///   sie weg – das Ergebnis IST danach lesbar. Ob dabei etwas fehlt,
    ///   zeigt erst der Vergleich mit der Quelle.
    /// - **nur relativ erkennbar** (/Rotate 137, entartete MediaBox, Link auf
    ///   ein nicht existierendes Ziel): Eine absolute Prüfung darauf wäre
    ///   falsch. Sie würde Dokumente ablehnen, deren Defekt aus der QUELLE
    ///   stammt und die wir nur durchreichen – der Nutzer könnte sie dann gar
    ///   nicht mehr bearbeiten. Ob WIR den Defekt eingeführt haben, beantwortet
    ///   der Geometrie- und Linkvergleich gegen die Quelle (Befund 17:
    ///   nicht bestrafen, was schon vorher tot war).
    @Test(.hangGuard) func structureCheckCatchesUnreadableDamage() throws {
        let selfEvident: Set<String> = [
            "truncated", "damaged-trailer", "not-a-pdf",
            "page-tree-cycle", "bad-stream-length", "image-dimension-mismatch",
        ]
        for entry in Self.damaged where selfEvident.contains(entry.name) {
            let url = try Self.write(entry)
            defer { try? FileManager.default.removeItem(at: url) }

            guard let core = try? PDFCoreDocument(path: url.path) else {
                continue  // öffnet gar nicht – erkannt
            }
            #expect(throws: (any Error).self) { try core.check() }
        }
    }

    /// Ein beschädigtes Dokument als EINGABE: sauberer Fehler oder intakte
    /// Ausgabe – nichts dazwischen.
    @Test(.hangGuard, arguments: damaged.indices)
    func damagedInputNeverYieldsBrokenSuccess(index: Int) throws {
        let entry = Self.damaged[index]
        let broken = try Self.write(entry)
        defer { try? FileManager.default.removeItem(at: broken) }

        let result: CompressionResult
        do {
            result = try Compressor().compress(inputURL: broken, mode: .smart)
        } catch {
            return  // sauberer Fehler – zulässig
        }
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        // Zwei Zusagen, je nachdem was zurückkam.
        if result.returnedOriginal {
            // Durchgereicht: Die Datei muss byte-identisch sein. Für den
            // Schaden des Nutzers sind wir nicht verantwortlich – dafür,
            // ihn nicht zu verändern, schon.
            let original = try Data(contentsOf: broken)
            let delivered = try Data(contentsOf: result.outputURL)
            #expect(original == delivered, """
                „\(entry.name)“: unverändert zurückgegeben, aber die Bytes \
                stimmen nicht (\(original.count) → \(delivered.count)).
                """)
            return
        }

        // Selbst erzeugt: Dann steht auch die Zusage, dass es lesbar ist.
        let core = try #require(try? PDFCoreDocument(path: result.outputURL.path), """
            „\(entry.name)“: Kompression meldet Erfolg, die Ausgabe lässt sich \
            nicht öffnen.
            """)
        #expect(core.pageCount > 0, "„\(entry.name)“: Erfolg ohne Seiten")
        #expect(throws: Never.self) { try core.check() }
    }
}

/// Was ausgeliefert wird, ist entweder von uns geprüft oder unverändert –
/// und der Aufrufer kann es unterscheiden.
@Suite struct DeliveryGuaranteeTests {

    /// Bei einem Dokument, das sich nicht schrumpfen lässt, kommt das
    /// Original zurück – als solches gekennzeichnet und byte-identisch.
    @Test(.hangGuard) func incompressibleInputIsPassedThroughVerbatim() throws {
        // Zufallsdaten als Bild: nichts daran ist kleiner zu bekommen.
        let input = try PDFFixtures.photoHeavyPDF(pixels: 40)
        defer { try? FileManager.default.removeItem(at: input) }
        let before = try Data(contentsOf: input)

        let result = try Compressor().compress(inputURL: input, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        if result.returnedOriginal {
            #expect(try Data(contentsOf: result.outputURL) == before,
                    "Als unverändert gemeldet, aber die Bytes weichen ab")
            #expect(result.outputBytes == result.inputBytes)
        } else {
            #expect(result.outputBytes < result.inputBytes, """
                Weder durchgereicht noch kleiner – dann ist die Größenregel \
                verletzt: \(result.inputBytes) → \(result.outputBytes)
                """)
        }
    }

    /// Das Kennzeichen überlebt das Verschieben an den Zielort.
    @Test(.hangGuard) func finalizeKeepsProvenance() throws {
        let input = try PDFFixtures.photoHeavyPDF(pixels: 40)
        defer { try? FileManager.default.removeItem(at: input) }
        let result = try Compressor().compress(inputURL: input, mode: .smart)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }
        let final = try Compressor.finalize(result: result, destination: destination)

        #expect(final.returnedOriginal == result.returnedOriginal)
        #expect(final.alreadyOptimized == result.alreadyOptimized)
    }
}
