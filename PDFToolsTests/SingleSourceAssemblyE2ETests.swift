import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan E1: Ein-Quellen-Operationen behalten das Dokument.
///
/// Befund: Organisieren baute IMMER ein neues Dokument und kopierte nur
/// Seiten, Formularfelder und Ziele – Tags, Anhänge, XMP, Ebenen und
/// Verschlüsselung gingen verloren, auch wenn nur eine Seite gelöscht oder
/// gedreht wurde.
///
/// Fehlermöglichkeiten: (1) Katalogeinträge fehlen in der Ausgabe;
/// (2) die Verschlüsselung fällt weg; (3) Reihenfolge/Drehung stimmen nicht;
/// (4) ein Lesezeichen auf die gelöschte Seite bleibt als toter Verweis.
@Suite(.serialized) struct SingleSourceAssemblyE2ETests {

    static func qpdf(_ args: [String]) throws -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("qpdf-out-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        let handle = try FileHandle(forWritingTo: out)
        let process = Process()
        process.executableURL = Compressor.bundledQPDFURL()
        process.arguments = args
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try handle.close()
        return String(decoding: try Data(contentsOf: out), as: UTF8.self)
    }

    /// Drei Seiten; Katalog mit Struktur, XMP, Anhang, Ebene, zwei Lesezeichen
    /// (auf Seite 1 und 2); danach mit Besitzerpasswort (AES-256) verschlüsselt.
    static func richDocument() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        var pageIDs: [Int] = []
        for n in 1...3 {
            let content = b.addStream(dictionary: "", content: "BT /F1 24 Tf 72 700 Td (Seite \(n)) Tj ET")
            pageIDs.append(b.addPage(parent: pages, resources: "<</Font<</F1 \(font) 0 R>>>>", contents: content))
        }
        b.fill(pages, "<</Type/Pages/Kids[\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))]/Count 3>>")
        let xmp = b.addStream(dictionary: "/Type/Metadata/Subtype/XML",
                              content: "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"/></x:xmpmeta>")
        let file = b.addStream(dictionary: "/Type/EmbeddedFile", content: "Anhang")
        let spec = b.addObject("<</Type/Filespec/F(anhang.txt)/UF(anhang.txt)/EF<</F \(file) 0 R>>>>")
        let ocg = b.addObject("<</Type/OCG/Name(Ebene)>>")
        let outlines = b.reserveNumber()
        let o1 = b.reserveNumber()
        let o2 = b.reserveNumber()
        b.fill(o1, "<</Title(Kapitel 1)/Parent \(outlines) 0 R/Next \(o2) 0 R/Dest[\(pageIDs[0]) 0 R/Fit]>>")
        b.fill(o2, "<</Title(Kapitel 2)/Parent \(outlines) 0 R/Prev \(o1) 0 R/Dest[\(pageIDs[1]) 0 R/Fit]>>")
        b.fill(outlines, "<</Type/Outlines/First \(o1) 0 R/Last \(o2) 0 R/Count 2>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R/Metadata \(xmp) 0 R"
            + "/StructTreeRoot<</Type/StructTreeRoot>>/MarkInfo<</Marked true>>"
            + "/Names<</EmbeddedFiles<</Names[(anhang.txt) \(spec) 0 R]>>>>"
            + "/OCProperties<</OCGs[\(ocg) 0 R]/D<<>>>>/Outlines \(outlines) 0 R>>")
        let plain = try b.write(rootObject: root, prefix: "e1-rich")
        defer { try? FileManager.default.removeItem(at: plain) }
        let locked = PDFFixtures.fixtureURL(prefix: "e1-rich-enc")
        _ = try qpdf(["--encrypt", "--user-password=", "--owner-password=besitzer", "--bits=256",
                      "--", plain.path, locked.path])
        try #require(FileManager.default.fileExists(atPath: locked.path))
        return locked
    }

    @Test func seiteLoeschenUndDrehenBehaeltDasDokument() async throws {
        let input = try Self.richDocument()
        defer { try? FileManager.default.removeItem(at: input) }
        let source = SourceDocument(url: input, pageCount: 3)
        var first = PageItem(source: source, pageIndex: 0)
        first.rotation = 90
        let pages = [first, PageItem(source: source, pageIndex: 2)]
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("e1-out-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(pages: pages, to: out) { _ in }

        let encryption = try Self.qpdf(["--show-encryption", out.path])
        #expect(encryption.contains("R = 6"), "Verschlüsselung fehlt: \(encryption)")
        let qdf = FileManager.default.temporaryDirectory.appendingPathComponent("e1-qdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: qdf) }
        _ = try Self.qpdf(["--qdf", "--object-streams=disable", out.path, qdf.path])
        let text = String(decoding: try Data(contentsOf: qdf), as: UTF8.self)
        for key in ["/StructTreeRoot", "/EmbeddedFiles", "/Metadata", "/OCProperties", "/MarkInfo"] {
            #expect(text.contains(key), "\(key) fehlt nach der Operation")
        }

        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 2)
        #expect(doc.page(at: 0)?.string?.contains("Seite 1") == true)
        #expect(doc.page(at: 1)?.string?.contains("Seite 3") == true)
        #expect(doc.page(at: 0)?.rotation == 90)
        // Lesezeichen „Kapitel 2“ zeigte auf die gelöschte Seite 2.
        let titles = (0..<(doc.outlineRoot?.numberOfChildren ?? 0)).compactMap { doc.outlineRoot?.child(at: $0)?.label }
        #expect(titles.contains("Kapitel 1"))
        let deadTarget = (0..<(doc.outlineRoot?.numberOfChildren ?? 0)).compactMap { doc.outlineRoot?.child(at: $0) }
            .contains { $0.label == "Kapitel 2" && $0.destination?.page != nil
                && doc.index(for: $0.destination!.page!) == NSNotFound }
        #expect(!deadTarget, "Lesezeichen auf gelöschte Seite zeigt ins Leere")
    }

    // MARK: - Masterplan N1: gelöschte Seiten verlassen die Datei wirklich

    /// Fünf Seiten, und ALLES, was im Katalog auf Seiten zeigen kann, zeigt
    /// auf sie: Namensbaum und altes /Dests-Wörterbuch, /OpenAction,
    /// Strukturbaum (/Pg, ParentTree, IDTree), ein hierarchisches
    /// Formularfeld, Links. Jede Seite trägt eigene Erkennungstexte und ein
    /// nicht komprimierbares Bild (für die Größenprüfung).
    static func leakyDocument() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let pageIDs = (0..<5).map { _ in b.reserveNumber() }
        let elemIDs = (0..<5).map { _ in b.reserveNumber() }
        let docElem = b.reserveNumber()
        let structRoot = b.reserveNumber()
        let fieldParent = b.reserveNumber()
        let fieldChild = b.reserveNumber()

        // Seite 1: drei Links – auf sich selbst (bleibt), auf Seite 4
        // (ausdrückliches Ziel) und auf „sec.5“ (benanntes Ziel).
        let linkSelf = b.addObject("<</Type/Annot/Subtype/Link/Rect[10 10 60 30]/Dest[\(pageIDs[0]) 0 R/Fit]>>")
        let linkDead = b.addObject("<</Type/Annot/Subtype/Link/Rect[70 10 120 30]/Dest[\(pageIDs[3]) 0 R/Fit]>>")
        let linkNamed = b.addObject("<</Type/Annot/Subtype/Link/Rect[130 10 180 30]/Dest(sec.5)>>")
        // Seite 2: eine Notiz, deren Text mit der Seite gehen muss.
        let note = b.addObject("<</Type/Annot/Subtype/Text/Rect[10 10 30 30]/Contents(GEHEIM-NOTIZ-2)>>")

        var seed: UInt32 = 20261119
        for n in 0..<5 {
            var noise = Data(capacity: 30_000)
            for _ in 0..<30_000 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                noise.append(UInt8(truncatingIfNeeded: seed >> 24))
            }
            let image = b.addStream(
                dictionary: "/Type/XObject/Subtype/Image/Width 100/Height 100/ColorSpace/DeviceRGB/BitsPerComponent 8",
                data: noise)
            let content = b.addStream(dictionary: "", content:
                "BT /F1 24 Tf 72 700 Td (GEHEIM-INHALT-\(n + 1)) Tj ET q 100 0 0 100 72 500 cm /Im1 Do Q")
            var extra = "/StructParents \(n)"
            if n == 0 { extra += "/Annots[\(linkSelf) 0 R \(linkDead) 0 R \(linkNamed) 0 R]" }
            if n == 1 { extra += "/Annots[\(note) 0 R]" }
            if n == 2 { extra += "/Annots[\(fieldChild) 0 R]" }
            b.fillPage(pageIDs[n], parent: pages,
                       resources: "<</Font<</F1 \(font) 0 R>>/XObject<</Im1 \(image) 0 R>>>>",
                       contents: content, extra: extra)
            b.fill(elemIDs[n], "<</Type/StructElem/S/P/P \(docElem) 0 R/Pg \(pageIDs[n]) 0 R/K 0"
                + "/ActualText(GEHEIM-TAG-\(n + 1))>>")
        }
        b.fill(pages, "<</Type/Pages/Kids[\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))]/Count 5>>")
        b.fill(docElem, "<</Type/StructElem/S/Document/P \(structRoot) 0 R"
            + "/K[\(elemIDs.map { "\($0) 0 R" }.joined(separator: " "))]>>")
        b.fill(structRoot, "<</Type/StructTreeRoot/K \(docElem) 0 R"
            + "/ParentTree<</Nums[\((0..<5).map { "\($0) [\(elemIDs[$0]) 0 R]" }.joined(separator: " "))]>>"
            + "/IDTree<</Names[(id3) \(elemIDs[2]) 0 R]>>>>")
        // Hierarchisches Feld: Elternknoten ohne Wert, Kind = Feld + Widget auf Seite 3.
        b.fill(fieldParent, "<</T(gruppe)/Kids[\(fieldChild) 0 R]>>")
        b.fill(fieldChild, "<</Type/Annot/Subtype/Widget/FT/Tx/T(feld)/V(GEHEIM-FELD-3)"
            + "/Parent \(fieldParent) 0 R/Rect[100 100 300 130]/P \(pageIDs[2]) 0 R>>")
        let destLeaf = b.addObject("<</Limits[(sec.1)(sec.5)]/Names["
            + "(sec.1)[\(pageIDs[0]) 0 R/Fit] (sec.2)<</D[\(pageIDs[1]) 0 R/Fit]>> "
            + "(sec.3)[\(pageIDs[2]) 0 R/Fit] (sec.4)[\(pageIDs[3]) 0 R/Fit] (sec.5)[\(pageIDs[4]) 0 R/Fit]]>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R"
            + "/StructTreeRoot \(structRoot) 0 R/MarkInfo<</Marked true>>"
            + "/Names<</Dests<</Kids[\(destLeaf) 0 R]>>>>"
            + "/Dests<</alt1[\(pageIDs[0]) 0 R/Fit]/alt3[\(pageIDs[2]) 0 R/Fit]>>"
            + "/OpenAction[\(pageIDs[1]) 0 R/Fit]"
            + "/AcroForm<</Fields[\(fieldParent) 0 R]>>>>")
        return try b.write(rootObject: root, prefix: "n1-leaky")
    }

    /// Ausgabe als QDF-Text: Ströme unkomprimiert, keine Objektströme –
    /// jeder Erkennungstext, der noch in der Datei steckt, ist darin lesbar.
    static func qdfText(of url: URL) throws -> String {
        let qdf = FileManager.default.temporaryDirectory.appendingPathComponent("n1-qdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: qdf) }
        _ = try qpdf(["--qdf", "--object-streams=disable", url.path, qdf.path])
        // Latin-1: Die Datei enthält Binärdaten, jedes Byte bleibt ein Zeichen.
        return String(decoding: try Data(contentsOf: qdf), as: Unicode.ASCII.self)
    }

    static func pageObjectCount(in qdf: String) -> Int {
        qdf.components(separatedBy: "/Type /Page\n").count - 1
    }

    /// Befund (Prüfung 19.11.): Der Umbau im Quelldokument nahm Seiten nur
    /// aus dem Seitenbaum. Alles, was im Katalog noch auf sie zeigte, hielt
    /// sie erreichbar – der Schreiber gab sie samt Inhalt wieder aus. Aus
    /// einem 15-Seiten-PDF blieb nach „eine Seite behalten“ 2,1 MB statt 95 KB.
    ///
    /// Fehlermöglichkeiten: (1) Inhaltsströme entfernter Seiten bleiben;
    /// (2) Texte in Strukturelementen (/ActualText) bleiben; (3) Feldwerte
    /// hierarchischer Felder bleiben; (4) Notizen der Seite bleiben;
    /// (5) Ziele/Links/OpenAction zeigen ins Leere; (6) beim Aufräumen geht
    /// etwas verloren, das zu einer BEHALTENEN Seite gehört.
    @Test(arguments: [[0], [1, 2], [4, 0], [2]])
    func entfernteSeitenVerlassenDieDatei(kept: [Int]) async throws {
        let input = try Self.leakyDocument()
        defer { try? FileManager.default.removeItem(at: input) }
        let source = SourceDocument(url: input, pageCount: 5)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("n1-out-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(pages: kept.map { PageItem(source: source, pageIndex: $0) },
                                               to: out) { _ in }

        let text = try Self.qdfText(of: out)
        #expect(Self.pageObjectCount(in: text) == kept.count,
                "Seitenobjekte in der Datei: \(Self.pageObjectCount(in: text)), behalten: \(kept.count)")
        for page in 0..<5 {
            let stays = kept.contains(page)
            for marker in ["GEHEIM-INHALT-\(page + 1)", "GEHEIM-TAG-\(page + 1)"] {
                #expect(text.contains(marker) == stays,
                        "\(marker) \(stays ? "fehlt, obwohl die Seite bleibt" : "steht noch in der Datei")")
            }
        }
        #expect(text.contains("GEHEIM-FELD-3") == kept.contains(2), "Feldwert von Seite 3")
        #expect(text.contains("GEHEIM-NOTIZ-2") == kept.contains(1), "Notiz von Seite 2")
        // Ziele: nur die der behaltenen Seiten bleiben.
        for page in 0..<5 {
            #expect(text.contains("(sec.\(page + 1))") == kept.contains(page), "benanntes Ziel sec.\(page + 1)")
        }
        #expect(text.contains("/alt3") == kept.contains(2), "altes /Dests-Ziel alt3")
        #expect(text.contains("/alt1") == kept.contains(0), "altes /Dests-Ziel alt1")
        #expect(text.contains("/OpenAction") == kept.contains(1), "/OpenAction auf Seite 2")
        // Der Katalog bleibt – das war der Sinn von E1.
        #expect(text.contains("/StructTreeRoot"))
        // Größe: je Seite 30 KB nicht komprimierbares Bild.
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        #expect(size < kept.count * 30_000 + 20_000, "Ausgabe \(size) Byte für \(kept.count) Seite(n)")

        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == kept.count)
        for (position, page) in kept.enumerated() {
            #expect(doc.page(at: position)?.string?.contains("GEHEIM-INHALT-\(page + 1)") == true)
        }
    }

    /// Links der behaltenen Seite 1: der auf sich selbst bleibt, die beiden
    /// auf entfernte Seiten (ausdrücklich und benannt) verschwinden.
    @Test func linksAufEntfernteSeitenVerschwindenDieUebrigenBleiben() async throws {
        let input = try Self.leakyDocument()
        defer { try? FileManager.default.removeItem(at: input) }
        let source = SourceDocument(url: input, pageCount: 5)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("n1-links-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(pages: [PageItem(source: source, pageIndex: 0)], to: out) { _ in }
        let text = try Self.qdfText(of: out)
        #expect(text.components(separatedBy: "/Subtype /Link").count - 1 == 1)

        // Alle fünf behalten: nichts darf verschwinden.
        let all = FileManager.default.temporaryDirectory.appendingPathComponent("n1-all-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: all) }
        try await PageAssemblyService.assemble(pages: (0..<5).map { PageItem(source: source, pageIndex: $0) },
                                               to: all) { _ in }
        let full = try Self.qdfText(of: all)
        #expect(full.components(separatedBy: "/Subtype /Link").count - 1 == 3)
        #expect(Self.pageObjectCount(in: full) == 5)
        #expect(full.contains("GEHEIM-FELD-3") && full.contains("GEHEIM-NOTIZ-2") && full.contains("/OpenAction"))
    }

    /// Echte Datei (pdfLaTeX mit hyperref, 15 Seiten): eine Seite behalten.
    /// Vor der Korrektur 2.138.457 Byte bei 2.215.244 Byte Eingabe.
    static let latexFile = "tmp/pdfs/n1/latex-hyperref-15-seiten.pdf"
    @Test(.needsLocalFiles(latexFile)) func latexDateiSchrumpftAufDieBehalteneSeite() async throws {
        let input = LocalTestData.repoRoot.appendingPathComponent(Self.latexFile)
        let source = SourceDocument(url: input, pageCount: 15)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("n1-latex-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let report = try await PageAssemblyService.assemble(pages: [PageItem(source: source, pageIndex: 0)], to: out) { _ in }
        #expect(!report.rebuiltSingleSource)
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        // Der qpdf-Neuaufbau derselben Seite hat 95.185 Byte.
        #expect(size < 125_000, "Ausgabe \(size) Byte – gelöschte Seiten stecken noch in der Datei")
        #expect(Self.pageObjectCount(in: try Self.qdfText(of: out)) == 1)
        #expect(PDFDocument(url: out)?.pageCount == 1)
    }

    /// Nachbedingung im Kern: Enthält die Quelle selbst ein erreichbares
    /// Seitenobjekt AUSSERHALB des Seitenbaums (hier über /Dests), kann der
    /// Umbau im Quelldokument es nicht loswerden. Der Kern meldet das, und
    /// der Dienst baut neu auf – die Ausgabe enthält nur die gewählten Seiten.
    @Test func seitenobjektAusserhalbDesBaumsErzwingtDenNeuaufbau() async throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        var pageIDs: [Int] = []
        for n in 1...2 {
            let content = b.addStream(dictionary: "", content: "BT /F1 24 Tf 72 700 Td (SICHTBAR-\(n)) Tj ET")
            pageIDs.append(b.addPage(parent: pages, resources: "<</Font<</F1 \(font) 0 R>>>>", contents: content))
        }
        let ghostContent = b.addStream(dictionary: "", content: "BT /F1 24 Tf 72 700 Td (GEHEIM-GEIST) Tj ET")
        let ghost = b.addPage(parent: pages, resources: "<</Font<</F1 \(font) 0 R>>>>", contents: ghostContent)
        // Die Geisterseite steht NICHT in /Kids.
        b.fill(pages, "<</Type/Pages/Kids[\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))]/Count 2>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R/Dests<</geist[\(ghost) 0 R/Fit]>>>>")
        let input = try b.write(rootObject: root, prefix: "n1-geist")
        defer { try? FileManager.default.removeItem(at: input) }

        // Der Kern allein verweigert: nichts geschrieben, Neuaufbau verlangt.
        let direct = FileManager.default.temporaryDirectory.appendingPathComponent("n1-geist-kern-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: direct) }
        let source = SourceDocument(url: input, pageCount: 2)
        let plan = PageAssemblyPlan(pages: [.init(sourceURL: input, sourcePageIndex: 0, rotation: 0)])
        #expect(throws: PDFCoreAssemblerError.needsRebuild) {
            try PDFCoreAssembler.writeSingleSource(plan: plan, to: direct)
        }
        #expect(!FileManager.default.fileExists(atPath: direct.path))
        #expect(!FileManager.default.fileExists(atPath: direct.path + ".pdfcore-tmp"))

        // Der Dienst fällt auf den Neuaufbau zurück.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("n1-geist-out-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let report = try await PageAssemblyService.assemble(pages: [PageItem(source: source, pageIndex: 0)], to: out) { _ in }
        // N1-Rest: Der Rückfall wird gemeldet, damit die Oberfläche es sagt.
        #expect(report.rebuiltSingleSource)
        let text = try Self.qdfText(of: out)
        #expect(Self.pageObjectCount(in: text) == 1)
        #expect(!text.contains("GEHEIM-GEIST") && !text.contains("SICHTBAR-2"))
        #expect(text.contains("SICHTBAR-1"))
        #expect(PDFDocument(url: out)?.pageCount == 1)
    }

    // MARK: - Masterplan N2: dieselbe Seite mehrfach

    /// Zwei Seiten ohne eigene /MediaBox, /Resources und /Rotate – alles
    /// steht nur am /Pages-Knoten (so schreibt es z. B. FPDF).
    static func inheritingDocument() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        var pageIDs: [Int] = []
        for word in ["EINS", "ZWEI"] {
            let content = b.addStream(dictionary: "", content: "BT /F1 24 Tf 40 300 Td (\(word)) Tj ET")
            pageIDs.append(b.addObject("<</Type/Page/Parent \(pages) 0 R/Contents \(content) 0 R>>"))
        }
        b.fill(pages, "<</Type/Pages/Kids[\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))]/Count 2"
            + "/MediaBox[0 0 300 400]/Resources<</Font<</F1 \(font) 0 R>>>>/Rotate 90>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        return try b.write(rootObject: root, prefix: "n2-erben")
    }

    /// Befund (Prüfung 19.11.): Plan „Seite 1 um 90° gedreht, Seite 1
    /// ungedreht" ergab zweimal 90° – die zweite Nutzung wurde vom bereits
    /// gedrehten Original kopiert.
    ///
    /// Fehlermöglichkeiten: (1) die Kopie erbt die Drehung des Originals;
    /// (2) die Reihenfolge der Nutzungen entscheidet über das Ergebnis;
    /// (3) eine dritte Nutzung zählt die Drehungen zusammen.
    @Test(arguments: [[90, 0], [0, 90], [90, 180, 0], [270, 270]])
    func mehrfachGenutzteSeiteBehaeltJeExemplarIhreDrehung(rotations: [Int]) async throws {
        let input = try Self.leakyDocument()
        defer { try? FileManager.default.removeItem(at: input) }
        let source = SourceDocument(url: input, pageCount: 5)
        let items = rotations.map { rotation -> PageItem in
            var item = PageItem(source: source, pageIndex: 0)
            item.rotation = rotation
            return item
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("n2-out-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(pages: items, to: out) { _ in }
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == rotations.count)
        #expect((0..<doc.pageCount).map { doc.page(at: $0)?.rotation ?? -1 } == rotations)
        for index in 0..<doc.pageCount {
            #expect(doc.page(at: index)?.string?.contains("GEHEIM-INHALT-1") == true)
        }
    }

    /// Geerbte Angaben: Die Kopie einer Seite darf /MediaBox, /Resources und
    /// /Rotate nicht verlieren, nur weil sie am /Pages-Knoten standen.
    @Test func kopieEinerSeiteBehaeltGeerbteAngaben() async throws {
        let input = try Self.inheritingDocument()
        defer { try? FileManager.default.removeItem(at: input) }
        let source = SourceDocument(url: input, pageCount: 2)
        var turned = PageItem(source: source, pageIndex: 0)
        turned.rotation = 90
        let items = [turned, PageItem(source: source, pageIndex: 0), PageItem(source: source, pageIndex: 1)]
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("n2-erben-out-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(pages: items, to: out) { _ in }

        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 3)
        // Geerbt waren 90°; das erste Exemplar ist zusätzlich um 90° gedreht.
        #expect((0..<3).map { doc.page(at: $0)?.rotation ?? -1 } == [180, 90, 90])
        for index in 0..<3 {
            let page = try #require(doc.page(at: index))
            let box = page.bounds(for: .mediaBox)
            #expect(box.width == 300 && box.height == 400, "Seite \(index + 1): MediaBox \(box)")
            // Ohne /Resources findet PDFKit die Schrift nicht und liefert keinen Text.
            #expect(page.string?.contains(index == 2 ? "ZWEI" : "EINS") == true,
                    "Seite \(index + 1): Text fehlt – /Resources verloren")
        }
        // Jede Seite der Ausgabe trägt ihre Angaben selbst oder erbt sie gültig.
        let text = try Self.qdfText(of: out)
        #expect(Self.pageObjectCount(in: text) == 3)
        #expect(text.components(separatedBy: "/MediaBox").count - 1 >= 1)
    }

    // MARK: Masterplan N11 – interne Links mit benannten Zielen

    /// Vier Seiten; Seite 1 trägt drei interne Links über benannte Ziele:
    /// (1) /Dest als Zeichenkette im Namensbaum, im ZWEITEN Kind und als
    /// `<< /D [...] >>`; (2) dasselbe über eine GoTo-Aktion; (3) /Dest als Name
    /// im alten /Dests-Wörterbuch. Das erste Kind des Namensbaums ist ein
    /// Zyklus (zeigt auf sich selbst) – die Suche darf daran weder hängen
    /// noch abstürzen.
    static func namedDestDocument() throws -> URL {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        var ids: [Int] = []
        let first = b.reserveNumber()
        ids.append(first)
        for _ in 1...3 { ids.append(b.addPage(parent: pages)) }
        let cycle = b.reserveNumber()
        b.fill(cycle, "<</Kids[\(cycle) 0 R]>>")
        let kidA = b.addObject("<</Names[(aaa)[\(ids[1]) 0 R/Fit]]/Limits[(aaa)(aaa)]>>")
        let kidB = b.addObject("<</Names[(zielB)<</D[\(ids[2]) 0 R/Fit]>>]/Limits[(zielB)(zielB)]>>")
        let tree = b.addObject("<</Kids[\(cycle) 0 R \(kidA) 0 R \(kidB) 0 R]>>")
        let rect = "/Rect[72 600 200 620]/Border[0 0 0]"
        let link1 = b.addObject("<</Type/Annot/Subtype/Link\(rect)/Dest(zielB)>>")
        let link2 = b.addObject("<</Type/Annot/Subtype/Link\(rect)/A<</S/GoTo/D(zielB)>>>>")
        let link3 = b.addObject("<</Type/Annot/Subtype/Link\(rect)/Dest/alt>>")
        b.fillPage(first, parent: pages,
                   extra: "/Annots[\(link1) 0 R \(link2) 0 R \(link3) 0 R]")
        b.fill(pages, "<</Type/Pages/Kids[\(ids.map { "\($0) 0 R" }.joined(separator: " "))]/Count 4>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R"
            + "/Names<</Dests \(tree) 0 R>>/Dests<</alt[\(ids[3]) 0 R/Fit]>>>>")
        return try b.write(rootObject: root, prefix: "n11-namedest")
    }

    static func linkCount(_ url: URL, page: Int) -> Int {
        PDFDocument(url: url)?.page(at: page)?.annotations
            .filter { $0.type == "Link" }.count ?? -1
    }

    /// Masterplan N11: Seite drehen, alles behalten – kein Link darf als
    /// „tot“ entfernt werden.
    @Test func benannteZieleUeberlebenDasDrehen() async throws {
        let input = try Self.namedDestDocument()
        defer { try? FileManager.default.removeItem(at: input) }
        #expect(Self.linkCount(input, page: 0) == 3)
        let source = SourceDocument(url: input, pageCount: 4)
        var items = (0..<4).map { PageItem(source: source, pageIndex: $0) }
        items[1].rotation = 90
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("n11-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(pages: items, to: out) { _ in }
        #expect(Self.linkCount(out, page: 0) == 3, "Links nach dem Drehen: \(Self.linkCount(out, page: 0))")
        // Ziele zeigen weiter auf dieselben Seiten wie in der Quelle. (PDFKit
        // löst das alte /Dests-Wörterbuch nicht auf – deshalb der Vergleich
        // mit der Quelle statt fester Seitenzahlen; die Zahl der Links oben
        // prüft, dass auch dieser Link bleibt.)
        func targets(_ url: URL) throws -> [Int] {
            let doc = try #require(PDFDocument(url: url))
            let links = doc.page(at: 0)?.annotations.filter { $0.type == "Link" } ?? []
            return links.compactMap { a -> Int? in
                guard let page = a.destination?.page ?? (a.action as? PDFActionGoTo)?.destination.page
                else { return nil }
                return doc.index(for: page)
            }.sorted()
        }
        let before = try targets(input)
        #expect(before.contains(2), "PDFKit löst den Namensbaum nicht auf – Test misst nichts")
        #expect(try targets(out) == before)
    }

    /// Masterplan N25: Namensbaum mit einem Knoten `/Kids [selbst selbst]`
    /// (ohne Besucht-Set verdoppeln sich die Aufrufe je Ebene, 2³³ bis Tiefe
    /// 32) und 2000 Links über 2000 benannte Ziele (ohne Index läuft jede
    /// Auflösung den ganzen Baum ab). Seite 4 wird entfernt: genau der eine
    /// Link auf sie fällt weg, alle anderen bleiben – und der Lauf endet
    /// zügig, statt zu hängen.
    @Test(.timeLimit(.minutes(1))) func vieleBenannteZieleUndZyklischerBaumEndenZuegig() async throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let first = b.reserveNumber()
        var ids = [first]
        for _ in 1...3 { ids.append(b.addPage(parent: pages)) }
        let n = 2000
        let pairs = (0..<n).map { i in "(z\(String(format: "%05d", i)))[\(ids[1 + i % 2]) 0 R/Fit]" }
        let leaf = b.addObject("<</Names[\(pairs.joined()) (zEntfernt)[\(ids[3]) 0 R/Fit]]>>")
        let doubling = b.reserveNumber()
        b.fill(doubling, "<</Kids[\(doubling) 0 R \(doubling) 0 R]>>")
        let tree = b.addObject("<</Kids[\(doubling) 0 R \(leaf) 0 R]>>")
        let rect = "/Rect[72 600 200 620]/Border[0 0 0]"
        var links = (0..<n).map { i in
            b.addObject("<</Type/Annot/Subtype/Link\(rect)/Dest(z\(String(format: "%05d", i)))>>")
        }
        links.append(b.addObject("<</Type/Annot/Subtype/Link\(rect)/Dest(zEntfernt)>>"))
        b.fillPage(first, parent: pages, extra: "/Annots[\(links.map { "\($0) 0 R" }.joined(separator: " "))]")
        b.fill(pages, "<</Type/Pages/Kids[\(ids.map { "\($0) 0 R" }.joined(separator: " "))]/Count 4>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R/Names<</Dests \(tree) 0 R>>>>")
        let input = try b.write(rootObject: root, prefix: "n25-viele-ziele")
        defer { try? FileManager.default.removeItem(at: input) }
        #expect(Self.linkCount(input, page: 0) == n + 1)

        let source = SourceDocument(url: input, pageCount: 4)
        let items = (0..<3).map { PageItem(source: source, pageIndex: $0) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("n25-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let start = Date()
        try await PageAssemblyService.assemble(pages: items, to: out) { _ in }
        let seconds = Date().timeIntervalSince(start)
        #expect(Self.linkCount(out, page: 0) == n, "Links nach dem Entfernen: \(Self.linkCount(out, page: 0))")
        #expect(seconds < 20, "Zusammenstellen dauerte \(seconds) s")
        // Die Validierung liest Ziele über den Snapshot – dieser Weg zählt und
        // sammelt den Namensbaum der QUELLE samt Zyklus.
        let snapshot = try PDFSemanticSnapshot.capture(input)
        #expect(snapshot.navigation.namedDestinations.count == n + 1)
    }

    /// Echte pdfLaTeX-Datei mit hyperref: Seite 1 drehen, alle Seiten
    /// behalten – Zahl der Links je Seite unverändert.
    @Test(.needsLocalFiles(latexFile)) func latexLinksUeberlebenDasDrehen() async throws {
        let input = LocalTestData.repoRoot.appendingPathComponent(Self.latexFile)
        let source = SourceDocument(url: input, pageCount: 15)
        var items = (0..<15).map { PageItem(source: source, pageIndex: $0) }
        items[0].rotation = 90
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("n11-latex-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(pages: items, to: out) { _ in }
        let before = (0..<15).map { Self.linkCount(input, page: $0) }
        let after = (0..<15).map { Self.linkCount(out, page: $0) }
        #expect(before.reduce(0, +) > 0, "Vorlage ohne Links – Test misst nichts")
        #expect(after == before)
    }

    // MARK: N1-Rest – Artikel-Threads

    /// Drei Seiten; Thread A läuft über alle drei, Thread B nur über Seite 3.
    /// Nur Seite 1 behalten: Thread A bleibt mit einem Bead, Thread B und die
    /// Beads der entfernten Seiten verschwinden (vorher leere Hüllen).
    @Test func artikelThreadsEntfernterSeitenVerschwinden() async throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let p = (0..<3).map { _ in b.reserveNumber() }
        let threadA = b.reserveNumber(), threadB = b.reserveNumber()
        let beads = (0..<3).map { _ in b.reserveNumber() }
        let beadB = b.reserveNumber()
        for i in 0..<3 {
            b.fill(beads[i], "<</T \(threadA) 0 R/N \(beads[(i + 1) % 3]) 0 R/V \(beads[(i + 2) % 3]) 0 R"
                   + "/P \(p[i]) 0 R/R[\(i + 1)11 \(i + 1)11 \(i + 1)222 \(i + 1)222]>>")
        }
        b.fill(beadB, "<</T \(threadB) 0 R/N \(beadB) 0 R/V \(beadB) 0 R/P \(p[2]) 0 R/R[9 9 99 99]>>")
        b.fill(threadA, "<</F \(beads[0]) 0 R/I<</Title(THREAD-A)>>>>")
        b.fill(threadB, "<</F \(beadB) 0 R/I<</Title(NUR-SEITE-3)>>>>")
        for i in 0..<3 {
            let bList = i == 2 ? "[\(beads[i]) 0 R \(beadB) 0 R]" : "[\(beads[i]) 0 R]"
            b.fillPage(p[i], parent: pages, extra: "/B\(bList)")
        }
        b.fill(pages, "<</Type/Pages/Kids[\(p.map { "\($0) 0 R" }.joined(separator: " "))]/Count 3>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R/Threads[\(threadA) 0 R \(threadB) 0 R]>>")
        let input = try b.write(rootObject: root, prefix: "n1-threads")
        defer { try? FileManager.default.removeItem(at: input) }

        let source = SourceDocument(url: input, pageCount: 3)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("n1-threads-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let report = try await PageAssemblyService.assemble(pages: [PageItem(source: source, pageIndex: 0)], to: out) { _ in }
        #expect(!report.rebuiltSingleSource, "Umbau im Original erwartet – Test misst sonst den Neuaufbau")
        let text = try Self.qdfText(of: out)
        #expect(text.contains("THREAD-A"))
        #expect(!text.contains("NUR-SEITE-3"), "Thread nur auf einer entfernten Seite blieb stehen")
        #expect(text.contains("1222"))
        #expect(!text.contains("2222") && !text.contains("3222"), "Beads entfernter Seiten blieben stehen")
        #expect(Self.pageObjectCount(in: text) == 1)
    }
}
