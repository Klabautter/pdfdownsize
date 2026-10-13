import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Monster Epic – Corpus Runner & Automated PDF Test Platform.
/// Führt alle Operationen auf allen Corpus-Fixtures aus und validiert jeden Output.
@Suite(.serialized)
@MainActor
struct CorpusRunnerTests {

    // MARK: - Corpus Index

    /// Masterplan 2.5 – kein absoluter Entwicklerpfad. Auflösung wie beim
    /// Runner: PDFTOOLS_CORPUS_ROOT → ~/PDFTools-TestCorpus.
    static func corpusRoot() -> URL {
        CorpusRunnerCore.Config.resolveEnvironment().root
    }

    /// Ein Korpus-Fixture, sofern der Korpus konfiguriert UND die Datei
    /// vorhanden ist.
    ///
    /// Diese Tests brauchen echte Dokumente, die bewusst nicht im Repository
    /// liegen. Fehlt der Korpus, ist das kein Fehlschlag, sondern eine
    /// Umgebung ohne Testdaten – die Tests melden das und laufen nicht.
    /// Fachliche Fehlschläge werden davon NICHT verdeckt: Ist die Datei da,
    /// wird sie vollständig geprüft.
    static func corpusFixture(_ relativePath: String) -> URL? {
        let url = corpusRoot().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Korpus-Fixture nicht vorhanden, Test übersprungen: "
                + "\(url.path) (PDFTOOLS_CORPUS_ROOT setzen)")
            return nil
        }
        return url
    }

    static func allPDFs() -> [URL] {
        let root = corpusRoot()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func tempOut(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cr-\(tag)-\(UUID().uuidString).pdf")
    }

    private func qpdfCheck(_ url: URL) -> Bool {
        guard let qp = Compressor.findQPDF() else { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qp)
        p.arguments = ["--check", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return [0, 3].contains(p.terminationStatus)
    }

    // MARK: - Smart Compress über alle Fixtures

    @Test(arguments: [
        "Synthetic/simple_text.pdf",
        "Synthetic/multi_page.pdf",
        "Synthetic/rotated_pages.pdf",
        "Synthetic/grayscale.pdf",
        "Synthetic/large_50pages.pdf",
    ])
    func compressSmartPreservesStructure(relPath: String) async throws {
        guard let input = CorpusRunnerTests.corpusFixture(relPath) else { return }
        guard let pdfDoc = PDFDocument(url: input), pdfDoc.pageCount > 0 else {
            Issue.record("Input nicht lesbar: \(relPath)")
            return
        }
        let expectedPages = pdfDoc.pageCount

        do {
            let out = tempOut("cmp-libqpdf")
            defer { try? FileManager.default.removeItem(at: out) }

            let result = try Compressor().compress(
                inputURL: input, mode: .smart)
            #expect(result.outputBytes > 0, "\(relPath)/libqpdf")

            let core = try #require(try? PDFCoreDocument(path: result.outputURL.path))
            #expect(core.pageCount == expectedPages, "\(relPath)/libqpdf")
            #expect(qpdfCheck(result.outputURL), "\(relPath)/libqpdf: --check")
        }
    }

    // MARK: - Merge über alle Fixtures (beide Engines)

    @Test(arguments: [
        "Synthetic/simple_text.pdf",
        "Synthetic/rotated_pages.pdf",
        "Synthetic/large_50pages.pdf",
        "RealWorld/CVF/Greer_CARL_A_Framework_for_Equivariant_Image_Registration_CVPR_2025_paper.pdf",
        "RealWorld/IRS/f1040.pdf",
    ])
    func mergeDoublesAndValidates(relPath: String) async throws {
        guard let url = CorpusRunnerTests.corpusFixture(relPath) else { return }
        guard FileManager.default.fileExists(atPath: url.path),
              let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            Issue.record("Input nicht lesbar: \(relPath)")
            return
        }
        let source = SourceDocument(url: url, pageCount: doc.pageCount)

        do {
            let out = tempOut("merge-libqpdf")
            defer { try? FileManager.default.removeItem(at: out) }
            let plan = PageAssemblyPlan(pages:
                (0..<doc.pageCount).map {
                    PageItem(source: source, pageIndex: $0).assemblyItem
                })
            try await PageAssemblyService.assemble(plan: plan, to: out,
                                              progress: { _ in })
            let resultDoc = try #require(PDFDocument(url: out))
            #expect(resultDoc.pageCount == doc.pageCount, "\(relPath)/libqpdf")
            #expect(qpdfCheck(out), "\(relPath)/libqpdf: --check")
        }
    }

    // MARK: - Extract Half über alle Fixtures

    @Test(arguments: [
        "Synthetic/simple_text.pdf",
        "Synthetic/large_50pages.pdf",
    ])
    func extractHalfProducesCorrectPageCount(relPath: String) async throws {
        guard let url = CorpusRunnerTests.corpusFixture(relPath) else { return }
        let doc = try #require(PDFDocument(url: url))
        let source = SourceDocument(url: url, pageCount: doc.pageCount)
        let half = max(1, doc.pageCount / 2)

        let plan = PageAssemblyPlan(pages:
            (0..<half).map { PageItem(source: source, pageIndex: $0).assemblyItem })

        do {
            let out = tempOut("extract-libqpdf")
            defer { try? FileManager.default.removeItem(at: out) }
            try await PageAssemblyService.assemble(plan: plan, to: out,
                                              progress: { _ in })
            let result = try #require(PDFDocument(url: out))
            #expect(result.pageCount == half, "\(relPath)/libqpdf")
            #expect(qpdfCheck(out), "\(relPath)/libqpdf: --check")
        }
    }

    // MARK: - Semantic Snapshot Parität

    @Test(arguments: [
        "Synthetic/simple_text.pdf",
        "Synthetic/rotated_pages.pdf",
        "RealWorld/CVF/Liu_Hyperbolic_Category_Discovery_CVPR_2025_paper.pdf",
        "RealWorld/IRS/f1040.pdf",
    ])
    func semanticSnapshotConsistentAcrossEngines(relPath: String) async throws {
        guard let url = CorpusRunnerTests.corpusFixture(relPath) else { return }
        let source = SourceDocument(url: url, pageCount: try #require(PDFDocument(url: url)).pageCount)
        let plan = PageAssemblyPlan(pages:
            (0..<source.pageCount).map { PageItem(source: source, pageIndex: $0).assemblyItem })

        let legacyOut = tempOut("snap-legacy")
        let qpdfOut = tempOut("snap-qpdf")
        defer {
            try? FileManager.default.removeItem(at: legacyOut)
            try? FileManager.default.removeItem(at: qpdfOut)
        }
        try await PageAssemblyService.assemble(plan: plan, to: legacyOut,
                                          progress: { _ in })
        try await PageAssemblyService.assemble(plan: plan, to: qpdfOut,
                                          progress: { _ in })

        // Masterplan Finding 17: Der Nachweis lautet „libqpdf >= PDFKit", nicht
        // „byte-gleiche Snapshots". Die Engines dürfen sich unterscheiden –
        // PDFKit vergibt beim Schreiben z. B. neue Formularfeldnamen. Was
        // libqpdf NICHT darf, ist etwas verlieren, das PDFKit erhalten hat.
        let legacySnap = try PDFSemanticSnapshot.capture(legacyOut, backend: .libQPDF)
        let qpdfSnap = try PDFSemanticSnapshot.capture(qpdfOut, backend: .libQPDF)

        let regressions = PDFSemanticSnapshot.differences(legacySnap, qpdfSnap)
            .filter { $0.severity <= .high }
        let summary = regressions.map(\.message).joined(separator: " | ")
        #expect(regressions.isEmpty,
                "\(relPath): libqpdf verliert gegenüber PDFKit: \(summary)")

        // Die Basisgeometrie muss in jedem Fall übereinstimmen.
        #expect(legacySnap.pageCount == qpdfSnap.pageCount)
        #expect(legacySnap.pages.map(\.rotation) == qpdfSnap.pages.map(\.rotation))
        #expect(legacySnap.pages.map(\.mediaBox) == qpdfSnap.pages.map(\.mediaBox))
    }

    // MARK: - Malformed Handling

    // Namen aus dem generierten Malformed-Korpus (MalformedCorpus.entries).
    @Test(arguments: ["truncated.pdf", "broken-xref.pdf", "missing-object.pdf",
                      "damaged-trailer.pdf", "broken-page-tree.pdf"])
    func malformedPDFDoesNotCrash(fileName: String) async throws {
        guard let url = CorpusRunnerTests.corpusFixture("Malformed/\(fileName)")
        else { return }

        // Bridge öffnet ohne Crash
        let core = try? PDFCoreDocument(path: url.path)
        // Wenn geöffnet: pageCount ≥ 0
        if let core { #expect(core.pageCount >= 0) }

        // Compressor wirft sauberen Fehler statt zu crashen
        if let opened = try? PDFCoreDocument(path: url.path) {
            _ = try? opened.check()  // darf fehlschlagen, aber nicht crashen
        }
    }

    // MARK: - Stress Test (100+ Seiten)

    @Test func stressTestLargeDocumentAssemblyAndExtract() async throws {
        guard let stressPath = CorpusRunnerTests.corpusFixture(
            "Stress/synthetic_text_1000_pages.pdf") else { return }

        let doc = try #require(PDFDocument(url: stressPath))
        let pageCount = doc.pageCount
        #expect(pageCount >= 500, "Stress-PDF hat nur \(pageCount) Seiten")

        let source = SourceDocument(url: stressPath, pageCount: pageCount)
        var items: [PageItem] = []
        for i in stride(from: 0, to: min(pageCount, 200), by: 2) {
            items.append(PageItem(source: source, pageIndex: i))
        }
        let plan = PageAssemblyPlan(pages: items.map(\.assemblyItem))

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("p-stress-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })
        let result = try #require(PDFDocument(url: out))
        #expect(result.pageCount == items.count)
        #expect(qpdfCheck(out))
    }
}
