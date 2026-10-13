import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan Finding 18 / Schritt 9 – Korpus-Inventar.
///
/// Das Gate verlangt „220+ brauchbare RealWorld PDFs" UND „Producer-/
/// Content-Diversität dokumentiert". Beides wird hier GEMESSEN und als
/// Report geschrieben – nicht von Hand gepflegt (Finding 19: Statuszahlen
/// stammen aus Werkzeugen, nicht aus abgeschriebenen Notizen).
@Suite(.serialized) struct CorpusInventoryTests {

    struct DocumentFacts {
        let relativePath: String
        let category: String
        let producer: String
        let pageCount: Int
        let byteCount: Int64
        let imageObjects: Int
        let hasText: Bool
        let hasForm: Bool
        let hasOutline: Bool
        let hasNamedDestinations: Bool
        let hasAttachments: Bool
        let untransformableImages: Int
    }

    /// Sind alle Inhaltseigenschaften belegt, nach denen die Prüfungen
    /// unten suchen? Dann muss nicht weiter analysiert werden.
    static func coverageComplete(_ facts: [DocumentFacts]) -> Bool {
        facts.contains { $0.hasText }
            && facts.contains { $0.imageObjects > 0 }
            && facts.contains { $0.hasForm }
            && facts.contains { $0.hasOutline }
            && facts.contains { $0.untransformableImages > 0 }
    }

    @Test func inventoryCorpusAndVerifyCoverage() throws {
        let config = CorpusRunnerCore.Config.fromEnvironment()
        guard FileManager.default.fileExists(atPath: config.corpusRoot.path) else {
            print("Korpus-Inventar übersprungen: \(config.corpusRoot.path) fehlt "
                + "(PDFTOOLS_CORPUS_ROOT setzen)")
            return
        }

        let realWorld = CorpusRunnerCore.enumeratePDFs(
            under: config.corpusRoot.appendingPathComponent("RealWorld"))
        guard !realWorld.isEmpty else {
            print("Korpus-Inventar übersprungen: keine RealWorld-PDFs")
            return
        }

        // ZWEI DURCHGÄNGE – aus gemessenem Anlass.
        //
        // Vorher analysierte dieser Test JEDES RealWorld-Dokument
        // vollständig: `imageResources()` plus semantischer Abzug. Für den
        // IPCC-Bericht allein sind das 320 Sekunden (40 723 Bilder). Als er
        // in den Korpus kam, wuchs die Regression von wenigen Minuten auf
        // über zwanzig – und niemandem fiel auf, warum, weil der Test ja
        // bestand.
        //
        // Die teuren Prüfungen unten sind aber EXISTENZPRÜFUNGEN: Sie
        // verlangen EIN Dokument mit Text, EINES mit Formular, EINES mit
        // nicht transformierbaren Bildern. Sobald jede Eigenschaft belegt
        // ist, bringt weiteres Analysieren keine Aussage mehr.
        //
        // Der vollständige Bericht braucht dagegen alle Daten – er entsteht
        // deshalb nur auf ausdrückliche Anforderung.
        let wantsFullInventory =
            ProcessInfo.processInfo.environment["PDFTOOLS_CORPUS_INVENTORY"] == "1"

        var facts: [DocumentFacts] = []
        var unreadable: [String] = []

        // Kleine Dokumente zuerst: Die Existenzprüfungen sind gleichgültig
        // dagegen, WELCHES Dokument sie erfüllt – also die billigsten
        // zuerst nehmen. Bei vollem Inventar bleibt die Reihenfolge egal.
        let ordered = wantsFullInventory ? realWorld
            : realWorld.sorted { Compressor.fileSize(of: $0) < Compressor.fileSize(of: $1) }

        var analyzed = 0
        for url in ordered {
            let relative = url.path.replacingOccurrences(
                of: config.corpusRoot.path + "/", with: "")
            // „Brauchbar" heißt: Das Dokument lässt sich öffnen und hat Seiten.
            // Eine Datei, die niemand lesen kann, zählt nicht zum Ziel.
            guard let document = try? PDFCoreDocument(path: url.path),
                  document.pageCount > 0 else {
                unreadable.append(relative)
                continue
            }

            // Ist schon jede Inhaltseigenschaft belegt, entfällt die teure
            // Analyse – die günstigen Angaben werden weiter erhoben, denn
            // Anzahl, Erzeuger und Kategorien brauchen jedes Dokument.
            let stillSearching = wantsFullInventory || !Self.coverageComplete(facts)
            let resources = stillSearching ? ((try? document.imageResources()) ?? []) : []
            let snapshot = stillSearching ? (try? PDFSemanticSnapshot.capture(url)) : nil
            if stillSearching { analyzed += 1 }

            facts.append(DocumentFacts(
                relativePath: relative,
                category: relative.split(separator: "/").dropFirst().first
                    .map(String.init) ?? "unbekannt",
                producer: Self.producer(of: url),
                pageCount: document.pageCount,
                byteCount: Compressor.fileSize(of: url),
                imageObjects: resources.count,
                hasText: snapshot?.pages.contains { $0.textCharacterCount > 0 } ?? false,
                hasForm: (snapshot?.form.fields.count ?? 0) > 0,
                hasOutline: (snapshot?.navigation.outline.count ?? 0) > 0,
                hasNamedDestinations:
                    (snapshot?.navigation.namedDestinations.count ?? 0) > 0,
                hasAttachments: (snapshot?.attachments.count ?? 0) > 0,
                untransformableImages:
                    resources.filter { !$0.transformCapability.isSafe }.count))
        }

        // Der Bericht entsteht NUR aus vollständigen Daten. Ihn aus einem
        // abgekürzten Durchgang zu schreiben hiesse, Teilzahlen als
        // Gesamtaussage abzulegen – genau der Fehler, gegen den Finding 19
        // sich richtet.
        if wantsFullInventory {
            let report = Self.renderReport(facts: facts, unreadable: unreadable,
                                           corpusRoot: config.corpusRoot)
            let destination = config.corpusRoot
                .appendingPathComponent("Results", isDirectory: true)
                .appendingPathComponent("CORPUS_INVENTORY.md")
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try report.write(to: destination, atomically: true, encoding: .utf8)
            print("Korpus-Inventar geschrieben: \(destination.path)")
        } else {
            print("Korpus-Inventar: Kurzfassung (\(analyzed) von \(facts.count) "
                + "Dokumenten analysiert). Vollständig mit "
                + "PDFTOOLS_CORPUS_INVENTORY=1.")
        }

        let producers = Set(facts.map(\.producer)).subtracting(["unbekannt"])
        print("""
        ━━ Korpus-Inventar ━━
        RealWorld brauchbar: \(facts.count) (nicht lesbar: \(unreadable.count))
        Kategorien:          \(Set(facts.map(\.category)).count)
        Erzeuger:            \(producers.count)
        analysiert:          \(analyzed) von \(facts.count)
        """)

        // --- Gate 18 ---------------------------------------------------------
        let countMessage = "Finding 18 verlangt 220+ brauchbare RealWorld-PDFs, "
            + "vorhanden: \(facts.count)"
        #expect(facts.count >= 220, "\(countMessage)")
        #expect(unreadable.isEmpty,
                "Nicht lesbare Korpusdateien: \(unreadable.joined(separator: ", "))")

        // Diversität ist laut Masterplan wichtiger als bloße Anzahl.
        #expect(producers.count >= 5,
                "Zu wenig Erzeuger-Vielfalt: \(producers.sorted())")
        #expect(Set(facts.map(\.category)).count >= 4,
                "Zu wenige Quellkategorien")

        // Inhaltsvielfalt: Der Korpus muss die Eigenschaften abdecken, gegen
        // die der Core arbeitet – sonst prüft er nur eine Dokumentsorte.
        #expect(facts.contains { $0.hasText }, "Kein Dokument mit Text")
        #expect(facts.contains { $0.imageObjects > 0 }, "Kein Dokument mit Bildern")
        #expect(facts.contains { $0.hasForm }, "Kein Formulardokument")
        #expect(facts.contains { $0.hasOutline }, "Kein Dokument mit Outline")
        #expect(facts.contains { $0.pageCount >= 50 },
                "Kein umfangreiches Dokument (50+ Seiten)")
        let capabilityMessage = "Kein Dokument mit nicht transformierbaren "
            + "Bildern – die Capability-Politik wird real nie geprüft"
        #expect(facts.contains { $0.untransformableImages > 0 },
                "\(capabilityMessage)")
    }

    // MARK: - Helfer

    /// Producer aus dem /Info-Dictionary. Nur der Werkzeugname, ohne
    /// Versionsnummer – sonst zählt jede Punktversion als eigener Erzeuger.
    static func producer(of url: URL) -> String {
        guard let document = PDFDocument(url: url),
              let attributes = (document.documentAttributes ?? [:])
                as? [PDFDocumentAttribute: Any],
              let raw = attributes[.producerAttribute] as? String,
              !raw.isEmpty else { return "unbekannt" }

        // Versionsangaben und Klammerzusätze abschneiden.
        var name = raw
        if let range = name.range(of: #"[\s\-_]*\d[\d.\-]*.*$"#,
                                  options: .regularExpression) {
            name.removeSubrange(range)
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? raw : name
    }

    static func renderReport(facts: [DocumentFacts], unreadable: [String],
                             corpusRoot: URL) -> String {
        var lines: [String] = []
        lines.append("# Korpus-Inventar")
        lines.append("")
        lines.append("Automatisch erzeugt von `CorpusInventoryTests` "
            + "(Masterplan Finding 18 / Schritt 9). Nicht von Hand bearbeiten.")
        lines.append("")
        lines.append("- Korpus: `\(corpusRoot.path)`")
        lines.append("- Erzeugt: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        // --- Bestand je Korpusteil ---
        lines.append("## Bestand")
        lines.append("")
        lines.append("| Teil | PDFs |")
        lines.append("|---|---:|")
        for part in ["Golden", "Synthetic", "RealWorld", "Stress", "Malformed"] {
            let count = CorpusRunnerCore.enumeratePDFs(
                under: corpusRoot.appendingPathComponent(part)).count
            lines.append("| \(part) | \(count) |")
        }
        lines.append("")

        // --- RealWorld nach Quelle ---
        lines.append("## RealWorld nach Quelle")
        lines.append("")
        lines.append("| Quelle | PDFs | Seiten gesamt | Größe |")
        lines.append("|---|---:|---:|---:|")
        let byCategory = Dictionary(grouping: facts, by: \.category)
        for (category, group) in byCategory.sorted(by: { $0.key < $1.key }) {
            let pages = group.reduce(0) { $0 + $1.pageCount }
            let bytes = group.reduce(Int64(0)) { $0 + $1.byteCount }
            lines.append("| \(category) | \(group.count) | \(pages) | "
                + "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) |")
        }
        lines.append("| **Gesamt** | **\(facts.count)** | "
            + "**\(facts.reduce(0) { $0 + $1.pageCount })** | "
            + "**\(ByteCountFormatter.string(fromByteCount: facts.reduce(Int64(0)) { $0 + $1.byteCount }, countStyle: .file))** |")
        lines.append("")

        // --- Erzeuger-Vielfalt ---
        lines.append("## Erzeuger-Vielfalt")
        lines.append("")
        lines.append("Verschiedene Werkzeuge erzeugen strukturell sehr "
            + "verschiedene PDFs. Diese Streuung ist laut Masterplan wichtiger "
            + "als die bloße Dokumentanzahl.")
        lines.append("")
        lines.append("| Erzeuger | PDFs |")
        lines.append("|---|---:|")
        let byProducer = Dictionary(grouping: facts, by: \.producer)
        for (producer, group) in byProducer.sorted(by: {
            $0.value.count != $1.value.count
                ? $0.value.count > $1.value.count : $0.key < $1.key
        }) {
            lines.append("| \(producer) | \(group.count) |")
        }
        lines.append("")

        // --- Inhaltsvielfalt ---
        lines.append("## Inhaltsvielfalt")
        lines.append("")
        lines.append("| Eigenschaft | Dokumente |")
        lines.append("|---|---:|")
        let properties: [(String, (DocumentFacts) -> Bool)] = [
            ("mit Text", { $0.hasText }),
            ("mit Bildern", { $0.imageObjects > 0 }),
            ("mit Formularfeldern", { $0.hasForm }),
            ("mit Outline", { $0.hasOutline }),
            ("mit Named Destinations", { $0.hasNamedDestinations }),
            ("mit Attachments", { $0.hasAttachments }),
            ("mit nicht transformierbaren Bildern", { $0.untransformableImages > 0 }),
            ("1 Seite", { $0.pageCount == 1 }),
            ("2–9 Seiten", { (2...9).contains($0.pageCount) }),
            ("10–49 Seiten", { (10...49).contains($0.pageCount) }),
            ("50+ Seiten", { $0.pageCount >= 50 })
        ]
        for (label, predicate) in properties {
            lines.append("| \(label) | \(facts.filter(predicate).count) |")
        }
        lines.append("")

        if !unreadable.isEmpty {
            lines.append("## Nicht lesbar")
            lines.append("")
            for path in unreadable.sorted() { lines.append("- `\(path)`") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
