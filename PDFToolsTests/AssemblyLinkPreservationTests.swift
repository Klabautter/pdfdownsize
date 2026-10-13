import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Interne Verweise müssen eine Assemblierung überleben.
///
/// Gefunden über die Differenzmatrix an einem CVPR-Paper: Die Quelle trägt
/// 187 Link-Annotationen und 206 GoTo-Aktionen, nach `merge` sind **2** übrig.
/// Beide Backends verlieren sie, `qpdf --pages` auf derselben Datei erhält
/// alle 187 – der Fehler liegt also im eigenen Assembler, nicht in libqpdf.
///
/// Ursache: Das Zielverzeichnis `/Names/Dests` wird nicht mitkopiert. Ohne
/// die Ziele ist jeder interne Verweis unauflösbar; die Phase-11-Politik
/// entfernt ihn daraufhin als „dangling", und bei PDFKit geht er ohnehin
/// verloren.
///
/// Dass das Gate es nicht meldete, hat einen eigenen Grund: Die
/// Validierungspolitik für Assembly war leer (`Policy()`) – mit der
/// Begründung, Dokument-Level-Strukturen gingen „mit PDFKit-Kopien bewusst
/// verloren". Damit war auch alles andere ungeprüft.
@Suite struct AssemblyLinkPreservationTests {

    /// Zählt Vorkommen im entpackten PDF – unabhängig von der eigenen Bridge,
    /// damit die geprüfte Komponente nicht ihr eigener Richter ist.
    static func rawCounts(of url: URL) throws -> (links: Int, goto: Int, dests: Int) {
        let qpdf = try #require(Compressor.findQPDF(), "qpdf nicht gefunden")
        let expanded = FileManager.default.temporaryDirectory
            .appendingPathComponent("expanded-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: expanded) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdf)
        process.arguments = ["--qdf", "--object-streams=disable",
                             url.path, expanded.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let text = (try? String(contentsOf: expanded, encoding: .isoLatin1)) ?? ""
        func count(_ needle: String) -> Int {
            text.components(separatedBy: needle).count - 1
        }
        return (count("/Subtype /Link") + count("/Subtype/Link"),
                count("/S /GoTo") + count("/S/GoTo"),
                count("/Dests"))
    }

    /// Baut ein Dokument, dessen Seite 1 per Named Destination auf Seite 2
    /// verweist – das Muster jedes Literaturverweises.
    static func documentWithInternalLink() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let c1 = b.addStream(dictionary: "",
                             content: "BT /F1 12 Tf 72 720 Td (siehe Kapitel 2) Tj ET")
        let c2 = b.addStream(dictionary: "",
                             content: "BT /F1 12 Tf 72 720 Td (Kapitel 2) Tj ET")
        let p1 = b.reserveNumber()
        let p2 = b.addObject("""
        <</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]\
        /Resources<</Font<</F1 \(font) 0 R>>>>/Contents \(c2) 0 R>>
        """)
        // Link-Annotation auf Seite 1, Ziel als Named Destination.
        let link = b.addObject("""
        <</Type/Annot/Subtype/Link/Rect[72 700 300 740]/Border[0 0 0]\
        /A<</S/GoTo/D(kapitel2)>>>>
        """)
        b.fillPage(p1, parent: pages,
                   resources: "<</Font<</F1 \(font) 0 R>>>>",
                   contents: c1, extra: "/Annots[\(link) 0 R]")
        b.fill(pages, "<</Type/Pages/Kids[\(p1) 0 R \(p2) 0 R]/Count 2>>")
        let dests = b.addObject("<</Names[(kapitel2)[\(p2) 0 R/XYZ null null null]]>>")
        let names = b.addObject("<</Dests \(dests) 0 R>>")
        let root = b.addObject(
            "<</Type/Catalog/Pages \(pages) 0 R/Names \(names) 0 R>>")
        return try b.write(rootObject: root, prefix: "internallink")
    }

    /// Die Fixture muss ihren Zweck erfüllen – sonst beweist der Test nichts.
    @Test(.hangGuard) func fixtureCarriesAnInternalLink() throws {
        let url = try Self.documentWithInternalLink()
        defer { try? FileManager.default.removeItem(at: url) }
        let counts = try Self.rawCounts(of: url)
        #expect(counts.links == 1, "Fixture ohne Link-Annotation (\(counts.links))")
        #expect(counts.goto == 1, "Fixture ohne GoTo-Aktion (\(counts.goto))")
        #expect(counts.dests >= 1, "Fixture ohne Zielverzeichnis (\(counts.dests))")
    }

    /// Werden ALLE Seiten übernommen, muss der interne Verweis erhalten
    /// bleiben – samt dem Ziel, auf das er zeigt.
    @Test(.hangGuard)
    func internalLinkSurvivesFullAssembly() async throws {
        let source = try Self.documentWithInternalLink()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembled-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let document = SourceDocument(url: source, pageCount: 2)
        let plan = PageAssemblyPlan(pages: (0..<2).map {
            PageItem(source: document, pageIndex: $0).assemblyItem
        })
        try await PageAssemblyService.assemble(plan: plan, to: output,
                                               progress: { _ in })

        let before = try Self.rawCounts(of: source)
        let after = try Self.rawCounts(of: output)

        #expect(after.links == before.links, """
            libqpdf: Link-Annotationen \(before.links) → \(after.links). \
            Werden alle Seiten übernommen, bleibt kein Verweis unauflösbar.
            """)
        #expect(after.goto == before.goto, """
            libqpdf: GoTo-Aktionen \(before.goto) → \(after.goto)
            """)
        #expect(after.dests >= 1, """
            libqpdf: Das Zielverzeichnis fehlt in der Ausgabe – ohne die \
            Ziele ist jeder interne Verweis unauflösbar.
            """)
    }

    /// Gegenprobe: Wird die Zielseite NICHT übernommen, DARF der Verweis
    /// verschwinden – er zeigt dann ins Leere. Ohne diesen Nachweis wäre der
    /// Test oben auch mit einer Politik zufrieden, die niemals etwas entfernt.
    @Test(.hangGuard) func linkToRemovedPageIsDropped() async throws {
        let source = try Self.documentWithInternalLink()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembled-partial-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let document = SourceDocument(url: source, pageCount: 2)
        // Nur Seite 1 – die Zielseite bleibt draussen.
        let plan = PageAssemblyPlan(pages: [
            PageItem(source: document, pageIndex: 0).assemblyItem])
        try await PageAssemblyService.assemble(plan: plan, to: output,
                                               progress: { _ in })

        let after = try Self.rawCounts(of: output)
        #expect(after.links == 0, """
            Ein Verweis auf eine nicht übernommene Seite muss entfernt werden \
            (noch \(after.links) vorhanden).
            """)
    }


    /// Die geschärfte Assembly-Politik muss einen Link-Verlust MELDEN.
    ///
    /// Sie war leer (`Policy()`), und deshalb blieb Befund 13 – 187
    /// Link-Annotationen werden zu 2 – im Korpuslauf unsichtbar.
    ///
    /// Den Verlust erzeugte dieser Test früher über den PDFKit-Pfad, der ihn
    /// zuverlässig produzierte. Seit dessen Entfernung wird er direkt gebaut:
    /// dasselbe Dokument einmal MIT und einmal OHNE Link-Annotation. Das ist
    /// ohnehin die sauberere Grundlage – die Prüfung soll den Verlust
    /// erkennen, unabhängig davon, wodurch er entstanden ist.
    @Test(.hangGuard) func policyDetectsLinkLoss() throws {
        let withLink = try Self.documentWithInternalLink()
        let withoutLink = try Self.documentWithoutLink()
        defer {
            try? FileManager.default.removeItem(at: withLink)
            try? FileManager.default.removeItem(at: withoutLink)
        }

        try #require(Self.rawCounts(of: withLink).links == 1,
                     "Referenz trägt keinen Link")
        try #require(Self.rawCounts(of: withoutLink).links == 0,
                     "Vergleichsdokument trägt wider Erwarten einen Link")

        var policy = PDFValidator.Policy.assembly
        policy.expectedPageCount = 2
        policy.pageMapping = [0: 0, 1: 1]
        policy.sourceURL = withLink
        let report = PDFValidator.validate(
            outputURL: withoutLink,
            referenceDocument: PDFDocument(url: withLink),
            policy: policy)

        #expect(report.failures.contains { $0.contains("Links verloren") }, """
            Die Politik meldet den Link-Verlust nicht. Gemeldet wurde: \
            \(report.failures.isEmpty ? "nichts" : report.failures.joined(separator: "; "))
            """)
    }

    /// Dasselbe Dokument wie `documentWithInternalLink`, nur ohne die
    /// Link-Annotation – als Vergleichsstück für die Verlusterkennung.
    static func documentWithoutLink() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let c1 = b.addStream(dictionary: "",
                             content: "BT /F1 12 Tf 72 720 Td (siehe Kapitel 2) Tj ET")
        let c2 = b.addStream(dictionary: "",
                             content: "BT /F1 12 Tf 72 720 Td (Kapitel 2) Tj ET")
        let p1 = b.addPage(parent: pages,
                           resources: "<</Font<</F1 \(font) 0 R>>>>", contents: c1)
        let p2 = b.addPage(parent: pages,
                           resources: "<</Font<</F1 \(font) 0 R>>>>", contents: c2)
        b.fill(pages, "<</Type/Pages/Kids[\(p1) 0 R \(p2) 0 R]/Count 2>>")
        let dests = b.addObject("<</Names[(kapitel2)[\(p2) 0 R/XYZ null null null]]>>")
        let names = b.addObject("<</Dests \(dests) 0 R>>")
        let root = b.addObject(
            "<</Type/Catalog/Pages \(pages) 0 R/Names \(names) 0 R>>")
        return try b.write(rootObject: root, prefix: "nolink")
    }
    /// Gegenprobe: Der Produktionspfad darf KEINEN Verlust melden – sonst
    /// wüsste man nicht, ob die Politik den Fehler erkennt oder pauschal
    /// alles beanstandet.
    @Test(.hangGuard) func policyPassesOnIntactAssembly() async throws {
        let source = try Self.documentWithInternalLink()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("policy-ok-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let document = SourceDocument(url: source, pageCount: 2)
        let plan = PageAssemblyPlan(pages: (0..<2).map {
            PageItem(source: document, pageIndex: $0).assemblyItem
        })
        try await PageAssemblyService.assemble(plan: plan, to: output,
                                               progress: { _ in })

        var policy = PDFValidator.Policy.assembly
        policy.expectedPageCount = 2
        policy.pageMapping = [0: 0, 1: 1]
        let report = PDFValidator.validate(
            outputURL: output,
            referenceDocument: PDFDocument(url: source),
            policy: policy)

        #expect(report.failures.isEmpty, """
            Der Produktionspfad wird beanstandet: \
            \(report.failures.joined(separator: "; "))
            """)
    }

    /// Dokument im PDF-1.1-Stil: Zielverzeichnis als flaches `/Dests`-
    /// Wörterbuch direkt im Katalog, nicht als Namensbaum unter `/Names`.
    ///
    /// Beide Formen sind gültig; `lookup_named_dest` kannte seit jeher beide,
    /// die Ziel-Übertragung beim Assemblieren nur die neuere. Dadurch blieben
    /// die Ziele solcher Dokumente zurück, jeder interne Verweis wurde
    /// unauflösbar, und die dangling-Politik entfernte ihn folgerichtig: An
    /// `1409.1556.pdf` überlebten von 275 Link-Annotationen ganze 3.
    static func documentWithLegacyDests() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let c1 = b.addStream(dictionary: "",
                             content: "BT /F1 12 Tf 72 720 Td (siehe Ziel) Tj ET")
        let c2 = b.addStream(dictionary: "",
                             content: "BT /F1 12 Tf 72 720 Td (Ziel) Tj ET")
        let p1 = b.reserveNumber()
        let p2 = b.addObject("""
        <</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 612 792]\
        /Resources<</Font<</F1 \(font) 0 R>>>>/Contents \(c2) 0 R>>
        """)
        // Link mit /Dest (Name), ohne /A-Aktion – wie in älteren Dokumenten.
        let link = b.addObject("""
        <</Type/Annot/Subtype/Link/Rect[72 700 300 740]/Border[0 0 0]\
        /Dest(ziel)>>
        """)
        b.fillPage(p1, parent: pages,
                   resources: "<</Font<</F1 \(font) 0 R>>>>",
                   contents: c1, extra: "/Annots[\(link) 0 R]")
        b.fill(pages, "<</Type/Pages/Kids[\(p1) 0 R \(p2) 0 R]/Count 2>>")
        // ALTE Form: /Dests direkt im Katalog.
        let dests = b.addObject("<</ziel[\(p2) 0 R/XYZ null null null]>>")
        let root = b.addObject(
            "<</Type/Catalog/Pages \(pages) 0 R/Dests \(dests) 0 R>>")
        return try b.write(rootObject: root, prefix: "legacydests")
    }

    @Test(.hangGuard) func legacyDestsFixtureIsWellFormed() throws {
        let url = try Self.documentWithLegacyDests()
        defer { try? FileManager.default.removeItem(at: url) }
        let counts = try Self.rawCounts(of: url)
        #expect(counts.links == 1, "Fixture ohne Link (\(counts.links))")
        #expect(counts.dests >= 1, "Fixture ohne /Dests im Katalog")
    }

    /// Ein Verweis über das ALTE Zielverzeichnis muss die Assemblierung
    /// genauso überleben wie einer über den Namensbaum.
    @Test(.hangGuard) func legacyDestsSurviveAssembly() async throws {
        let source = try Self.documentWithLegacyDests()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-out-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let document = SourceDocument(url: source, pageCount: 2)
        let plan = PageAssemblyPlan(pages: (0..<2).map {
            PageItem(source: document, pageIndex: $0).assemblyItem
        })
        try await PageAssemblyService.assemble(plan: plan, to: output,
                                               progress: { _ in })

        let before = try Self.rawCounts(of: source)
        let after = try Self.rawCounts(of: output)
        #expect(after.links == before.links, """
            Verweis über das alte /Dests-Wörterbuch verloren: \
            \(before.links) → \(after.links).
            """)
        #expect(after.dests >= 1,
                "Das Zielverzeichnis fehlt in der Ausgabe")
    }
}
