import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Memory Regression Tests – stellt sicher dass keine Operation RAM akkumuliert.
@Suite(.serialized)
@MainActor
struct MemoryRegressionTests {

    static let maxDeltaMB: Int64 = 500

    // MARK: - RSS Helper

    nonisolated static func currentRSS() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    private func findFile(_ name: String) -> URL? {
        // Ohne konfigurierten Korpus gibt es hier nichts zu messen –
        // die Aufrufer behandeln das leere Ergebnis als „übersprungen".
        let root = CorpusRunnerTests.corpusRoot()
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    // MARK: - Wachstumsmessung

    /// Misst, ob wiederholte Ausführung den Speicher WEITER wachsen lässt.
    ///
    /// Ein absolutes RSS-Delta ist hier untauglich: `task_info` liefert den
    /// Verbrauch des GESAMTEN Prozesses, und Swift Testing führt Suites
    /// parallel aus. Ein solcher Test misst dann fremde Last mit – er war
    /// isoliert grün und in der vollen Suite rot, also wertlos.
    ///
    /// Stattdessen wird die STEIGUNG betrachtet: Nach dem Aufwärmen läuft die
    /// Arbeit zweimal in gleich großen Blöcken. Ein Leck wächst in beiden
    /// Blöcken ähnlich weiter; ohne Leck pendelt sich der zweite Block ein.
    /// Ein konstanter Offset durch fremde Tests verschiebt beide Blöcke
    /// gleichermaßen und verfälscht die Steigung nicht.
    ///
    /// Das gilt aber nur, solange die Fremdlast KONSTANT ist. In der vollen
    /// Suite ist sie das nicht: Belegt ein anderer Test während des zweiten
    /// Blocks Speicher, geht das in die Steigung ein. Gemessen wurden so
    /// 878 MB „Wachstum" an einem Code, der isoliert 26 von 26 Prüfungen
    /// besteht.
    ///
    /// Diese Suite läuft deshalb NICHT in der Standardsuite mit, sondern über
    /// `Scripts/memory-check.sh` – allein im Prozess. Ein Speichertest
    /// zwischen 363 fremden Tests misst die Suite, nicht die Software.
    static func growthPerBlock(warmup: Int = 2, blockSize: Int = 4,
                               _ work: () throws -> Void) rethrows -> Int64 {
        for _ in 0..<warmup { try work() }

        let start = currentRSS()
        for _ in 0..<blockSize { try work() }
        let afterFirst = currentRSS()
        for _ in 0..<blockSize { try work() }
        let afterSecond = currentRSS()

        // Wachstum des ZWEITEN Blocks: Was hier noch dazukommt, wurde vom
        // ersten Block nicht freigegeben.
        _ = afterFirst - start
        return afterSecond - afterFirst
    }

    /// Asynchrone Variante der Steigungsmessung – für Arbeit, die über
    /// Task-Gruppen läuft (Phase 8: parallele Mehr-Dokument-Läufe).
    /// Gleiche Methodik wie die synchrone Fassung: Aufwärmen, dann zwei
    /// gleich große Blöcke; gezählt wird nur das Wachstum des zweiten.
    static func growthPerBlockAsync(warmup: Int = 1, blockSize: Int = 2,
                                    _ work: () async throws -> Void) async rethrows -> Int64 {
        for _ in 0..<warmup { try await work() }

        let start = currentRSS()
        for _ in 0..<blockSize { try await work() }
        let afterFirst = currentRSS()
        for _ in 0..<blockSize { try await work() }
        _ = afterFirst - start
        return currentRSS() - afterFirst
    }

    // MARK: - Phase 8 – file-backed Eingang & Parallelität

    /// Große synthetische Roh-PDF: EINE unkomprimierte Graustufen-Seite,
    /// deren Bildstream die Zielgröße trägt. Direkt auf die Platte
    /// gestreamt – die Generierung hält die Bytes nie komplett im Speicher
    /// (sonst würde die Messung die Erzeugung mitzählen).
    private static func makeLargeRawPDF(targetBytes: Int64) throws -> URL {
        let dim = Int(Double(targetBytes).squareRoot())
        let streamLength = dim * dim
        let content = "q \(dim) 0 0 \(dim) 0 0 cm /Im0 Do Q"
        let contentBytes = Data(content.utf8)

        let url = PDFFixtures.fixtureURL(prefix: "mem-large-raw")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var offsets: [Int] = []
        func append(_ data: Data) throws { try handle.write(contentsOf: data) }
        func beginObject(_ n: Int) throws {
            offsets.append(Int(handle.offsetInFile))
            try append(Data("\(n) 0 obj\n".utf8))
        }

        try append(Data("%PDF-1.4\n".utf8))
        try beginObject(1)
        try append(Data("<</Type/Catalog/Pages 2 0 R>>\nendobj\n".utf8))
        try beginObject(2)
        try append(Data("<</Type/Pages/Kids[5 0 R]/Count 1>>\nendobj\n".utf8))
        try beginObject(3)
        try append(Data(("<</Type/XObject/Subtype/Image/Width \(dim)"
            + "/Height \(dim)/BitsPerComponent 8/ColorSpace/DeviceGray"
            + "/Length \(streamLength)>>\nstream\n").utf8))
        // Zeilenweise schreiben: Eine Zeile im Speicher, nicht das Bild.
        var row = Data(count: dim)
        for y in 0..<dim {
            for x in 0..<dim {
                row[x] = UInt8(min(255, 40 + (x * 180 / max(dim, 1)) + (y % 32)))
            }
            try append(row)
        }
        try append(Data("\nendstream\nendobj\n".utf8))
        try beginObject(4)
        try append(Data("<</Length \(contentBytes.count)>>\nstream\n".utf8))
        try append(contentBytes)
        try append(Data("\nendstream\nendobj\n".utf8))
        try beginObject(5)
        try append(Data(("<</Type/Page/Parent 2 0 R/MediaBox[0 0 \(dim) \(dim)]"
            + "/Resources<</XObject<</Im0 3 0 R>>>>/Contents 4 0 R>>\nendobj\n").utf8))

        let xref = Int(handle.offsetInFile)
        var table = Data("xref\n0 6\n".utf8)
        table.append(Data("0000000000 65535 f \n".utf8))
        for offset in offsets {
            table.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        table.append(Data("trailer\n<</Size 6/Root 1 0 R>>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try append(table)
        return url
    }

    /// Phase 8 – Large-Document: Kompression ohne Steigung, Eingang
    /// file-backed. Zwei Prüfungen an EINEM rund 48-MB-Dokument (eine
    /// unkomprimierte Graustufenseite, generiert direkt auf die Platte):
    ///
    /// 1. File-backed Eingang: Beim Parsen – der Scan berührt JEDES Byte
    ///    der Datei, der Worst Case der alten Ganzdatei-Haltung – darf der
    ///    Fußabdruck nicht mit der Dateigröße skalieren. Kalibriert gegen
    ///    die alte Fassung: `Data(contentsOf:)` wuchs um ~100 % der
    ///    Dateigröße (anonymer Speicher), `mappedIfSafe` liegt nahe 0
    ///    (cleanes Mapping, im phys_footprint nicht gezählt).
    /// 2. Kompression ohne Steigung: Der volle Produktionspfad (Analyzer,
    ///    Planner, Executor, Struktur-Pass, Validierung) über wiederholte
    ///    Durchläufe. Ein Restbestand von Bild- oder Planartefakten würde
    ///    als weiteres Wachstum im zweiten Block sichtbar.
    @Test func largeDocumentCompressionDoesNotGrowMemory() throws {
        let fixture = try Self.makeLargeRawPDF(targetBytes: 48 * 1_048_576)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let size = (try FileManager.default.attributesOfItem(
            atPath: fixture.path)[.size] as? Int64) ?? 0
        #expect(size > 40 * 1_048_576, "Fixture zu klein für die Aussage: \(size) Bytes")

        // 1) File-backed Eingang – Grenze: ein Viertel der Dateigröße.
        //    Die alte Ganzdatei-Haltung misst hier ~100 % und fällt klar durch.
        let parseBefore = Self.currentRSS()
        let document = try PDFDocumentFile(url: fixture)
        #expect(!document.imageObjectNumbers().isEmpty)
        let parseDelta = Self.currentRSS() - parseBefore
        let parseBound = max(12_000_000, size / 4)
        #expect(parseDelta < parseBound, Comment(rawValue: String(format:
            "Fußabdruck beim Parsen einer %.0f-MB-Datei: %.1f MB (Grenze %.1f MB)",
            Self.asMegabytes(size), Self.asMegabytes(parseDelta),
            Self.asMegabytes(parseBound))))

        // 2) Steigung über wiederholte Kompressionen desselben Dokuments.
        let growth = try Self.growthPerBlock(warmup: 1, blockSize: 2) {
            let result = try Compressor().compress(inputURL: fixture, mode: .smart)
            try? FileManager.default.removeItem(at: result.outputURL)
        }
        #expect(Self.asMegabytes(growth) < 120, Comment(rawValue: String(format:
            "Weiteres Wachstum im zweiten Block (2 Kompressionen eines %.0f-MB-Dokuments): %.1f MB",
            Self.asMegabytes(size), Self.asMegabytes(growth))))
    }

    /// Phase 8 – parallele Mehr-Dokument-Läufe dürfen nicht wachsen.
    /// Mehrere unabhängige Dokumente laufen gleichzeitig (Limit 2), je eines
    /// über den vollständigen Produktionspfad. Ein Leck – z. B. eine
    /// Instanz-Sperre, die Transienten überlebt, oder Dokumentzustand, der
    /// im Runner hängen bleibt – zeigt sich als Steigung über die Blöcke.
    @Test func parallelDocumentCompressionDoesNotGrowMemory() async throws {
        CompressionConcurrency.maxConcurrentDocuments = 2
        defer { CompressionConcurrency.resetLimit() }

        let inputs = try (0..<3).map { index in
            try PDFFixtures.photoHeavyPDF(pixels: 1100, name: "mem-par-\(index)")
        }
        defer { for url in inputs { try? FileManager.default.removeItem(at: url) } }

        func onePassOverAllDocuments() async throws {
            let results = try await CompressionConcurrency.compressDocuments(
                inputURLs: inputs, mode: .smart)
            for result in results {
                try? FileManager.default.removeItem(at: result.outputURL)
            }
        }

        let growth = try await Self.growthPerBlockAsync(warmup: 1, blockSize: 2) {
            try await onePassOverAllDocuments()
        }

        let message = String(format:
            "Weiteres Wachstum im zweiten Block (2 parallele Läufe über 3 Dokumente): %.1f MB",
            Self.asMegabytes(growth))
        #expect(Self.asMegabytes(growth) < 120, "\(message)")
    }

    // MARK: - Compress

    @Test func compressDoesNotLeak() async throws {
        let input = try PDFFixtures.photoHeavyPDF(pixels: 2000)
        defer { try? FileManager.default.removeItem(at: input) }

        let growth = try Self.growthPerBlock {
            let result = try Compressor().compress(inputURL: input, mode: .smart)
            try? FileManager.default.removeItem(at: result.outputURL)
        }
        for _ in 0..<5 { await Task.yield() }

        let message = String(format:
            "Weiteres Wachstum im zweiten Block (4 Kompressionen): %.1f MB",
            Self.asMegabytes(growth))
        #expect(Self.asMegabytes(growth) < 150, "\(message)")
    }

    // MARK: - Assembly

    @Test func assemblyDoesNotLeak() async throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))
        let source = SourceDocument(url: url, pageCount: doc.pageCount)

        let plan = PageAssemblyPlan(pages:
            (0..<doc.pageCount).map {
                PageItem(source: source, pageIndex: $0).assemblyItem
            })

        let rssBefore = Self.currentRSS()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-asm-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        for _ in 0..<3 {
            try await PageAssemblyService.assemble(plan: plan, to: out,
                                              progress: { _ in })
            try? FileManager.default.removeItem(at: out)
        }
        for _ in 0..<5 { await Task.yield() }
        let delta = Self.currentRSS() - rssBefore
        #expect(delta < Self.maxDeltaMB * 1_048_576,
                "RAM-Delta nach Assembly: \(delta / 1_048_576) MB")
    }

    // MARK: - Image Export

    @Test func imageExportDoesNotLeak() async throws {
        let input = try PDFFixtures.photoHeavyPDF(pixels: 1500)
        defer { try? FileManager.default.removeItem(at: input) }
        let doc = try #require(PDFDocument(url: input))
        let source = SourceDocument(url: input, pageCount: doc.pageCount)
        let items = (0..<doc.pageCount).map { PageItem(source: source, pageIndex: $0) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-img-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let rssBefore = Self.currentRSS()
        for _ in 0..<3 {
            let urls = try await PageImageExporter.export(
                pages: items, options: .init(format: .png, dpi: 72),
                to: folder.appendingPathComponent("run-\(UUID())")) { _ in }
            for u in urls { try? FileManager.default.removeItem(at: u) }
        }
        for _ in 0..<10 { await Task.yield() }
        let delta = Self.currentRSS() - rssBefore
        #expect(delta < Self.maxDeltaMB * 1_048_576,
                "RAM-Delta nach Export: \(delta / 1_048_576) MB")
    }

    // MARK: - Large Document Stress

    @Test func stressLargeDocumentMemory() async throws {
        guard let stressPath = findFile("stress_300pages.pdf") else {
            // Ohne Korpus keine Messung – kein Fehlschlag, aber sichtbar.
            print("stress_300pages.pdf nicht gefunden – Test übersprungen "
                + "(PDFTOOLS_CORPUS_ROOT setzen)")
            return
        }
        let rssBefore = Self.currentRSS()

        let doc = try #require(PDFDocument(url: stressPath))
        #expect(doc.pageCount >= 300)
        let source = SourceDocument(url: stressPath, pageCount: doc.pageCount)

        var items: [PageAssemblyItem] = []
        for i in 0..<min(doc.pageCount, 100) {
            items.append(PageItem(source: source, pageIndex: i).assemblyItem)
        }
        let plan = PageAssemblyPlan(pages: items)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("p-mem-stress-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        try await PageAssemblyService.assemble(plan: plan, to: out, progress: { _ in })
        let result = try #require(PDFDocument(url: out))
        #expect(result.pageCount == items.count)

        for _ in 0..<10 { await Task.yield() }
        let delta = Self.currentRSS() - rssBefore
        #expect(delta < Self.maxDeltaMB * 1_048_576,
                "RAM-Delta bei 100-Seiten Assembly: \(delta / 1_048_576) MB")
    }

    // MARK: - Langläufer
    //
    // Diese Fälle stammen aus einer eigenen Suite und liegen jetzt hier.
    // Grund: `@Suite(.serialized)` serialisiert nur INNERHALB einer Suite –
    // zwei getrennte Speicher-Suites liefen parallel und maßen sich
    // gegenseitig den Verbrauch zu. Speichertests gehören an EINEN Ort.

    static func asMegabytes(_ bytes: Int64) -> Double {
        Double(bytes) / 1_048_576
    }

    /// Wiederholte Kompression darf den Speicher nicht monoton wachsen lassen.
    @Test func repeatedCompressionDoesNotGrowMemory() throws {
        let fixture = try PDFFixtures.placedPhotoPDF(pixels: 1400, placedPoints: 400)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let growth = Self.growthPerBlock(blockSize: 6) {
            let output = PDFFixtures.fixtureURL(prefix: "memtest")
            _ = try? CompressionPipeline.run(inputURL: fixture, outputURL: output,
                                             options: .smart)
            try? FileManager.default.removeItem(at: output)
        }

        let message = String(format:
            "Weiteres Wachstum im zweiten Block (6 Kompressionen): %.1f MB",
            Self.asMegabytes(growth))
        #expect(Self.asMegabytes(growth) < 60, "\(message)")
    }

    /// Der Render-Diff ist die speicherintensivste Einzeloperation des
    /// Korpuslaufs: Er rastert zwei Seiten auf eine 1400-px-Leinwand.
    @Test func repeatedRenderComparisonDoesNotGrowMemory() throws {
        let source = try PDFFixtures.densePagePDF(rotation: 0)
        defer { try? FileManager.default.removeItem(at: source) }

        // Blockweise statt in einem Rutsch: Ein Render-Vergleich hält
        // kurzzeitig rund 30 MB. Vierzig davon am Stück brachten den
        // Testprozess neben den parallel laufenden Suites zum Absturz –
        // der Test maß dann nichts mehr, sondern beendete den Lauf.
        let growth = Self.growthPerBlock(blockSize: 5) {
            _ = try? RenderDifferential.compare(sourceURL: source, outputURL: source)
        }

        let message = String(format:
            "Weiteres Wachstum im zweiten Block (5 Render-Vergleiche): %.1f MB",
            Self.asMegabytes(growth))
        #expect(Self.asMegabytes(growth) < 60, "\(message)")
    }

    /// Der Snapshot liest jede Seite – bei vielen Seiten summiert sich das.
    @Test func repeatedSnapshotCaptureDoesNotGrowMemory() throws {
        let fixture = try PDFFixtures.rawMultiParagraphPDF(pages: 8)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let growth = Self.growthPerBlock(blockSize: 10) {
            _ = try? PDFSemanticSnapshot.capture(fixture)
        }

        let message = String(format:
            "Weiteres Wachstum im zweiten Block (10 Snapshots): %.1f MB",
            Self.asMegabytes(growth))
        #expect(Self.asMegabytes(growth) < 40, "\(message)")
    }

    /// Ein vielseitiges Dokument in EINEM Durchlauf: Hier darf der Verbrauch
    /// nicht mit der Seitenzahl skalieren.
    @Test func manyPageDocumentDoesNotAccumulate() throws {
        let fixture = try PDFFixtures.scanLikePDF(pages: 12, pixels: 900)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let baseline = Self.currentRSS()
        let output = PDFFixtures.fixtureURL(prefix: "manypage")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try CompressionPipeline.run(inputURL: fixture, outputURL: output,
                                        options: ImageIdentitySafetyTests.forceTransformOptions)
        let growth = Self.currentRSS() - baseline

        let message = String(format:
            "Speicherwachstum bei 12 Seiten mit Bildern: %.1f MB (Grenze 250 MB)",
            Self.asMegabytes(growth))
        #expect(Self.asMegabytes(growth) < 250, "\(message)")
    }

    // MARK: - Assembly-Backends im Speichervergleich

    /// Belegt den Speichervorteil des libqpdf-Assemblers.
    ///
    /// Gemessen an einer 126-seitigen IRS-Anleitung, je sechs Durchläufe:
    ///
    ///     PDFKit:  34 → 449 → 1777 → 1833 → 1673 → 2518 → 2938 MB
    ///     libqpdf: 34 →  69 →   71 →   71 →   71 →   71 →   71 MB
    ///
    /// Der frühere PDFKit-Assembler hielt Seiteninhalte über den Aufruf
    /// hinaus – gemessen 2938 MB gegen 71 MB am selben Dokument, im
    /// Korpuslauf eine Spitze von 20.8 GB. Daran scheiterten mehrere Läufe
    /// über den vollen Bestand, und es war eines der Argumente für den
    /// Cutover (Masterplan Schritt 11).
    ///
    /// Seit der Legacy-Pfad entfernt ist, prüft dieser Test die verbliebene
    /// Anforderung: Die Assemblierung darf über wiederholte Durchläufe nicht
    /// wachsen. Nach dem Cutover lag die Korpusspitze bei 450 MB.
    @Test func assemblyDoesNotAccumulateMemory() async throws {
        let source = try PDFFixtures.rawMultiParagraphPDF(pages: 60)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try #require(PDFDocument(url: source))

        func assemble() async throws {
            let origin = SourceDocument(url: source, pageCount: document.pageCount)
            let plan = PageAssemblyPlan(pages: (0..<document.pageCount).map {
                PageItem(source: origin, pageIndex: $0).assemblyItem
            })
            let output = PDFFixtures.fixtureURL(prefix: "asmmem")
            try await PageAssemblyService.assemble(plan: plan, to: output,
                                                   progress: { _ in })
            try? FileManager.default.removeItem(at: output)
        }

        // Aufwärmen, dann drei Durchläufe je Backend messen.
        try await assemble()
        let libqpdfBefore = Self.currentRSS()
        for _ in 0..<3 { try await assemble() }
        let libqpdfGrowth = Self.asMegabytes(Self.currentRSS() - libqpdfBefore)

        let message = String(format:
            "libqpdf-Assembly wächst über 3 Durchläufe um %.1f MB", libqpdfGrowth)
        #expect(libqpdfGrowth < 50, "\(message)")
    }
}
