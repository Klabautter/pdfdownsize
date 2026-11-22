import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// N14: Punkte, die als „erledigt mit Test“ notiert waren, aber keinen Test
/// hatten – C2 (paralleler Snapshot) und H1 (MRC-DPI-Regel für Papier-Scans).
/// C3 steht in `SampledLadderTests`, C5 in `MapsDecodeCacheTests`
/// (`budgetAusUmgebungLesbar`).
@Suite struct ParallelSnapshotTests {

    /// C2: Ab `parallelPageThreshold` Seiten liest der Snapshot den Seitenteil
    /// auf mehreren PDFKit-Instanzen. Fehlermöglichkeiten: Seiten fehlen,
    /// doppelt, falsche Reihenfolge, anderer Text als seriell.
    @Test func parallelGelesenGleichSeriell() throws {
        let count = PDFSemanticSnapshot.parallelPageThreshold + 20
        let doc = PDFFixtures.document(pages: (1...count).map { PDFFixtures.textPage("C2-SEITE-\($0)") })
        let url = try PDFFixtures.write(doc, name: "c2-parallel")
        defer { try? FileManager.default.removeItem(at: url) }

        let parallel = try #require(PDFSemanticSnapshot.parallelPages(url: url, pageCount: count))
        let reader = try #require(PDFDocument(url: url))
        var serial = PDFSemanticSnapshot.PagePart()
        for i in 0..<count { PDFSemanticSnapshot.collectPage(reader, index: i, into: &serial) }

        #expect(parallel.pages.count == count)
        #expect(parallel.pages.map(\.index) == Array(0..<count), "Reihenfolge oder Vollständigkeit verletzt")
        #expect(parallel.pages == serial.pages)
        #expect(parallel.externalURLs == serial.externalURLs)
    }

    /// Unter der Schwelle bleibt es seriell (nil).
    @Test func kleineDokumenteBleibenSeriell() throws {
        let doc = PDFFixtures.document(pages: [PDFFixtures.textPage("eins")])
        let url = try PDFFixtures.write(doc, name: "c2-seriell")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PDFSemanticSnapshot.parallelPages(url: url, pageCount: 1) == nil)
    }

    /// C2: Große Dateien drosseln die Worker-Anzahl des parallelen Snapshots,
    /// damit PDFKit nicht 6× ein 400-MB-Dokument gleichzeitig im RAM öffnet.
    @Test func workerAnzahlSkaliertMitDateigroesse() {
        #expect(PDFSemanticSnapshot.parallelWorkerCount(pageCount: 400, fileBytes: 250 * 1024 * 1024) == 1)
        #expect(PDFSemanticSnapshot.parallelWorkerCount(pageCount: 400, fileBytes: 80 * 1024 * 1024) <= 2)
        #expect(PDFSemanticSnapshot.parallelWorkerCount(pageCount: 400, fileBytes: 45 * 1024 * 1024) <= 4)
        #expect(PDFSemanticSnapshot.parallelWorkerCount(pageCount: 400, fileBytes: 2 * 1024 * 1024) >= 2)
        #expect(PDFSemanticSnapshot.parallelWorkerCount(pageCount: 400, fileBytes: 2 * 1024 * 1024) <= 6)
    }
}

@Suite struct MRCDPIRuleTests {

    /// Ein JPEG im DPI-Budget (keine Verkleinerung geplant).
    static func jpegWithinBudget() -> PDFImageResource {
        PDFImageResource(
            objectID: PDFObjectID(objectNumber: 7, generation: 0),
            width: 1240, height: 1754, bitsPerComponent: 8,
            colorSpace: .deviceRGB, filters: [.dct], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            decodeArray: [], encodedByteCount: 800_000,
            placements: [PDFImagePlacement(pageIndex: 0, resourceName: "/Im0",
                                           placedWidthPoints: 595, placedHeightPoints: 842)])
    }

    /// H1: Die DPI-Regel (Entscheidung 4.11.: ein JPEG im Budget wird nur
    /// verlustfrei umgepackt) sperrt MRC – außer für erkannte Papier-Scans
    /// und bei einem Größenziel. Fehlermöglichkeiten: Papier-Scans bleiben
    /// gesperrt (H1 ohne Wirkung) oder die Sperre fällt für alles.
    @Test func papierScanIstVonDerSperreAusgenommen() {
        let resource = Self.jpegWithinBudget()
        let smart = CompressionOptions.smart
        #expect(CompressionPlanner.plannedSize(for: resource, options: smart.image) == nil,
                "Fixture liegt nicht im DPI-Budget – Test prüft nichts")
        #expect(CompressionPlanner.dpiRuleExcludesMRC(resource: resource, options: smart))
        #expect(!CompressionPlanner.dpiRuleExcludesMRC(resource: resource, options: smart, isPaperScan: true))
        var target = smart
        target.goal = .targetBytes(100_000)
        #expect(!CompressionPlanner.dpiRuleExcludesMRC(resource: resource, options: target))
    }
}

/// N1-Rest: Hinweis nach dem Neuaufbau einer einzelnen Quelle.
@Suite struct RebuildNoticeTests {
    @Test func satzNenntDieVerlorenenMerkmale() {
        let sentence = MergeLossSummary.rebuildSentence(for: [
            .init(feature: .tags, files: ["a.pdf"]), .init(feature: .attachments, files: ["a.pdf"])])
        #expect(sentence?.contains(MergeLossSummary.Feature.tags.label) == true)
        #expect(sentence?.contains(MergeLossSummary.Feature.attachments.label) == true)
        #expect(MergeLossSummary.rebuildSentence(for: []) == nil)
    }

    /// N24: XMP-Metadaten und verschachtelte Lesezeichen gehen beim Neuaufbau
    /// verloren – der Hinweis muss sie nennen.
    @Test func neuaufbauNenntXMPUndVerschachtelteLesezeichen() throws {
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let page = b.addPage(parent: pages)
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let outlines = b.reserveNumber(), top = b.reserveNumber(), child = b.reserveNumber()
        b.fill(child, "<</Title(Kind)/Parent \(top) 0 R/Dest[\(page) 0 R/Fit]>>")
        b.fill(top, "<</Title(Oben)/Parent \(outlines) 0 R/First \(child) 0 R/Last \(child) 0 R/Count 1/Dest[\(page) 0 R/Fit]>>")
        b.fill(outlines, "<</Type/Outlines/First \(top) 0 R/Last \(top) 0 R/Count 2>>")
        let xmp = b.addStream(dictionary: "/Type/Metadata/Subtype/XML", content: "<x:xmpmeta xmlns:x='adobe:ns:meta/'/>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R/Outlines \(outlines) 0 R/Metadata \(xmp) 0 R>>")
        let url = try b.write(rootObject: root, prefix: "n24")
        defer { try? FileManager.default.removeItem(at: url) }
        let features = MergeLossSummary.rebuildLosses(for: url).map(\.feature)
        #expect(features.contains(.metadata) && features.contains(.nestedOutlines), "\(features)")
    }

    /// N23: Eine Quelle nur mit Besitzer-Passwort öffnet ohne Entsperren; nach
    /// einem Neuaufbau ist sie unverschlüsselt – der Hinweis nennt das. Eine
    /// entsperrte Quelle (Arbeitskopie) wird beim Sichern neu verschlüsselt.
    @Test func neuaufbauNenntVerschluesselungNurOhneEntsperren() throws {
        let doc = PDFFixtures.document(pages: [PDFFixtures.textPage("N23")])
        let plain = try PDFFixtures.write(doc, name: "n23-plain")
        defer { try? FileManager.default.removeItem(at: plain) }
        let locked = FileManager.default.temporaryDirectory.appendingPathComponent("n23-owner-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: locked) }
        let process = Process()
        process.executableURL = Compressor.bundledQPDFURL()
        process.arguments = ["--encrypt", "--user-password=", "--owner-password=besitzer", "--bits=256", "--",
                             plain.path, locked.path]
        try process.run(); process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        #expect(MergeLossSummary.rebuildLosses(for: locked).contains { $0.feature == .encryption })
        #expect(!MergeLossSummary.rebuildLosses(for: locked, displayName: "orig.pdf").contains { $0.feature == .encryption })
    }

    /// N35: Mehr-Quellen-Merge übernimmt verschachtelte Lesezeichen (E2) –
    /// `losses(for:)` darf `.nestedOutlines` daher nicht mehr als Verlust melden,
    /// während der Ein-Quellen-Neuaufbau (`rebuildLosses`) es weiterhin meldet.
    @Test func mehrQuellenMeldetKeineVerschachteltenLesezeichen() throws {
        let nested = try PDFFixtures.nestedOutlinePDF()
        let plain = try PDFFixtures.vectorTextPDF(lines: 2)
        defer { try? FileManager.default.removeItem(at: nested); try? FileManager.default.removeItem(at: plain) }

        let multi = MergeLossSummary.losses(for: [nested, plain]).map(\.feature)
        #expect(!multi.contains(.nestedOutlines), "Mehr-Quellen meldete fälschlich verschachtelte Lesezeichen: \(multi)")
        let rebuild = MergeLossSummary.rebuildLosses(for: nested).map(\.feature)
        #expect(rebuild.contains(.nestedOutlines), "Ein-Quellen-Neuaufbau meldete verschachtelte Lesezeichen nicht")
    }
}

/// Prüfungen für N36 (SessionScratch), N37 (Abbruch/Drosselung) und UI/UX-Helfer.
@Suite struct PolishingAndHardeningTests {

    /// N36: `CandidateStore` legt ausgelagerte Payloads im Sitzungsordner ab,
    /// nicht lose im Wurzel-Temp-Verzeichnis.
    @Test func candidateStoreSpilltInSessionScratch() {
        var config = CandidateStore.Config()
        config.ramPayloadLimitBytes = 0
        let store = CandidateStore(config: config)
        defer { store.cancel() }
        let payload = store.store(Data(repeating: 0xAB, count: 1024),
                                  resource: PDFObjectID(objectNumber: 1, generation: 0),
                                  candidate: CandidateID("c1"),
                                  kind: .keep)
        guard case .file(let url, _) = payload else {
            Issue.record("Erwartete Dateiauslagerung, bekam \(payload)")
            return
        }
        let actualPath: String = url.path
        let expectedPrefix: String = SessionScratch.directory.path
        #expect(actualPath.hasPrefix(expectedPrefix),
                "CandidateStore schrieb außerhalb von SessionScratch: \(actualPath)")
    }

    /// N37 / Abbruch: Ein bereits abgebrochener Validator überspringt die
    /// teure Render-Stichprobe ohne Absturz.
    @Test func validatorBrichtBeiAbbruchVorStichprobeAb() throws {
        let doc = PDFFixtures.document(pages: [PDFFixtures.textPage("Abbruch")])
        let url = try PDFFixtures.write(doc, name: "validator-cancel")
        defer { try? FileManager.default.removeItem(at: url) }
        var policy = PDFValidator.Policy.compression
        policy.expectedPageCount = 1
        policy.renderSamplePages = [0]
        let report = PDFValidator.validate(outputURL: url, referenceURL: url,
                                           policy: policy, isCancelled: { true })
        #expect(report.isValid)
    }

    /// C5: Große Dateien (≥ 50 MB bzw. ≥ 15 MB auf 8-GB-Macs) drosseln den
    /// Stapel automatisch auf 1 Datei gleichzeitig; explizite Limits bleiben.
    @Test func bulkLimitDrosseltGrosseDateien() {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        #expect(CompressionConcurrency.effectiveBulkLimit(
            largestBytes: 60 * 1024 * 1024, physicalMemory: sixteenGB) == 1)
        #expect(CompressionConcurrency.effectiveBulkLimit(
            largestBytes: 20 * 1024 * 1024, physicalMemory: eightGB) == 1)
        #expect(CompressionConcurrency.effectiveBulkLimit(
            largestBytes: 60 * 1024 * 1024, physicalMemory: sixteenGB, explicitLimit: 2) == 2)
    }

    /// Cold-Launch-Puffer: Dateien aus `application(_:open:)` vor
    /// `RootView.onAppear` gehen nicht verloren, sondern werden einmalig geleert.
    @Test @MainActor func openFilesDelegatePuffertKaltstartDateien() {
        let delegate = OpenFilesDelegate()
        let u1 = URL(fileURLWithPath: "/tmp/a.pdf")
        let u2 = URL(fileURLWithPath: "/tmp/b.pdf")
        delegate.application(NSApp, open: [u1])
        delegate.application(NSApp, open: [u2])
        #expect(delegate.drainBufferedOpenURLs() == [u1, u2])
        #expect(delegate.drainBufferedOpenURLs().isEmpty)
    }

    /// `ProgressText` bildet bekannte Stufen lokalisiert ab und ersetzt keine
    /// beliebigen „ / “-Zeichenketten mit hartem deutschem „ von “.
    @Test func progressTextVermeidetDeutschenFallback() {
        #expect(ProgressText.stage(for: "Analysiere …") != nil)
        #expect(ProgressText.stage(for: "Seite 2 / 5") != nil)
        #expect(ProgressText.userFacing("A / B") == "A / B")
        #expect(ProgressText.userFacing("") == "")
    }

    /// UI-Hilfszustände: gecachte OCR-Wortzahl/Dateigröße und Sheet-Flag im MergeVM.
    @Test @MainActor func viewModelCachesUndSheetZustand() {
        let ocr = OCRViewModel()
        #expect(ocr.totalWords == 0)
        #expect(ocr.fileSize == 0)
        let merge = MergeViewModel()
        #expect(!merge.isSheetPresented)
    }

    /// Masterplan H1/H2: Smart-Auflösungsleiter testet bis 150 DPI herunter,
    /// verschwenderische JPEGs greifen ab 2,0 bpp und MRC-Bedarfsschwelle
    /// deckt typische 60-KB-Scans ab.
    @Test func smartH2LeiterUndSchwellen() {
        let photo = PDFImageResource(
            objectID: PDFObjectID(objectNumber: 10, generation: 0),
            width: 2400, height: 1800, bitsPerComponent: 8,
            colorSpace: .deviceRGB, filters: [.dct], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            decodeArray: [], encodedByteCount: 1_200_000,
            placements: [PDFImagePlacement(pageIndex: 0, resourceName: "/Im0",
                                           placedWidthPoints: 576, placedHeightPoints: 432)])
        let smart = CompressionOptions.smart.image
        let target = CompressionPlanner.plannedSize(for: photo, options: smart)!
        let rungs = CandidateGenerator.resolutionLadder(resource: photo, target: target, options: smart)
        let minWidth = rungs.map(\.width).min() ?? Int.max
        #expect(minWidth <= 1250, "Smart-Leiter fehlt 150-DPI-Stufe: \(rungs)")
        #expect(rungs.contains(target), "Zielstufe 220 DPI muss in der Leiter stehen")

        let wasteful = PDFImageResource(
            objectID: PDFObjectID(objectNumber: 11, generation: 0),
            width: 1000, height: 1000, bitsPerComponent: 8,
            colorSpace: .deviceRGB, filters: [.dct], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            decodeArray: [], encodedByteCount: 280_000, // 2,24 bpp
            placements: [PDFImagePlacement(pageIndex: 0, resourceName: "/Im1",
                                           placedWidthPoints: 500, placedHeightPoints: 500)])
        let compact = PDFImageResource(
            objectID: PDFObjectID(objectNumber: 12, generation: 0),
            width: 1000, height: 1000, bitsPerComponent: 8,
            colorSpace: .deviceRGB, filters: [.dct], unknownFilters: [],
            hasSoftMask: false, hasExplicitMask: false, isImageMask: false,
            decodeArray: [], encodedByteCount: 200_000, // 1,60 bpp
            placements: [PDFImagePlacement(pageIndex: 0, resourceName: "/Im2",
                                           placedWidthPoints: 500, placedHeightPoints: 500)])
        #expect(CandidateGenerator.isWastefullyEncodedJPEG(wasteful, options: smart))
        #expect(!CandidateGenerator.isWastefullyEncodedJPEG(compact, options: smart))
        #expect(MRCProvisionBudget.oneClick.provisionIfCandidateExceedsBytes <= 48 * 1024)
    }
}
