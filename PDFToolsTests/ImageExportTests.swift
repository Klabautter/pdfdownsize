import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// PDF → Images (Review §65, Feature 3): Dimensionen, Rotation, Formate, Cancel.
@MainActor
struct ImageExportTests {

    private func tempFolder(_ tag: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("img-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func pixelDimensions(of url: URL) -> (Int, Int) {
        guard let image = NSImage(contentsOf: url),
              let rep = image.representations.first else { return (0, 0) }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    @Test func pngExportMatchesDpiDimensions() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 2)   // 612×792 pt
        let folder = try tempFolder("png")
        defer { try? FileManager.default.removeItem(at: folder) }

        // 612 pt × 150/72 = 1275 px; 792 pt × 150/72 = 1650 px
        let urls = try await vm.exportImages(vm.project.pages,
                                             options: .init(format: .png, dpi: 150),
                                             to: folder)
        #expect(urls.count == 2)
        #expect(urls.map(\.lastPathComponent) == ["01.png", "02.png"])
        #expect(pixelDimensions(of: urls[0]) == (1275, 1650))
        #expect(!vm.isProcessing)
    }

    @Test func rotationSwapsPixelDimensions() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 2)
        vm.selectAll()
        vm.rotateSelectedPages(by: 90)
        let folder = try tempFolder("rot")
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = try await vm.exportImages(vm.project.pages,
                                             options: .init(format: .png, dpi: 72),
                                             to: folder)
        // ungedreht wäre 612×792 → nach 90°: 792×612
        #expect(pixelDimensions(of: urls[0]) == (792, 612))
    }

    /// Befund A1 (Review 2026-10-09): Der Exporter schrieb die Nutzer-
    /// Rotation auf die Seite des per URL gecachten `PDFDocument` und setzte
    /// sie nie zurück. Taucht dieselbe Quellseite im Export zweimal auf
    /// (dieselbe Datei zweimal importiert, alles um 90° gedreht), addierte
    /// der zweite Treffer die Rotation erneut: 180° statt 90°, Maße nicht
    /// vertauscht.
    ///
    /// Vorher aufgeschriebene Fehlermöglichkeiten:
    ///  1. Zweite Kopie um 180° (Maße wie ungedreht) – der eigentliche Befund.
    ///  2. Erste Kopie korrekt, zweite anders: Pixel der beiden Kopien
    ///     unterscheiden sich, obwohl Quelle und Rotation gleich sind.
    ///  3. Rücksetzen vergessen → auch das Quelldokument im Cache bleibt
    ///     gedreht; ein ungedrehter Export derselben Seite danach wäre falsch.
    @Test func sameSourceTwiceRotatesEachCopyOnce() async throws {
        let vm = MergeViewModel()
        let url = try TestFactory.makeTempPDF(name: "twice-\(UUID().uuidString)", pageCount: 2)
        vm.importDocuments([url, url])
        try await TestFactory.waitFor { vm.project.pages.count == 4 && !vm.hasChanges }
        vm.selectAll()
        vm.rotateSelectedPages(by: 90)
        let folder = try tempFolder("twice")
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = try await vm.exportImages(vm.project.pages,
                                             options: .init(format: .png, dpi: 72),
                                             to: folder)
        #expect(urls.count == 4)
        // 612×792 pt um 90° → 792×612 px, für BEIDE Kopien.
        for u in urls {
            #expect(pixelDimensions(of: u) == (792, 612), "\(u.lastPathComponent)")
        }
        // Gleiche Quelle, gleiche Rotation → gleiche Pixel.
        #expect(try Data(contentsOf: urls[0]) == Data(contentsOf: urls[2]))
        #expect(try Data(contentsOf: urls[1]) == Data(contentsOf: urls[3]))

        // 3: Ein anschließender ungedrehter Export derselben Seiten ist ungedreht.
        vm.rotateSelectedPages(by: -90)
        let plain = try tempFolder("twice-plain")
        defer { try? FileManager.default.removeItem(at: plain) }
        let again = try await vm.exportImages(vm.project.pages,
                                              options: .init(format: .png, dpi: 72),
                                              to: plain)
        for u in again {
            #expect(pixelDimensions(of: u) == (612, 792), "\(u.lastPathComponent)")
        }
    }

    /// Befund B9 (Review 2026-10-09): „300 dpi · Druck", aber die Datei trug
    /// 72 dpi. Fehlermöglichkeiten: (1) Metadaten weiter 72 dpi; (2) Pixel-
    /// zahl verändert sich durch die Punktgröße; (3) Bild leer/weiß, weil
    /// in Punkten statt Pixeln gezeichnet wurde.
    @Test func exportCarriesTheChosenDpi() async throws {
        let vm = MergeViewModel()
        let url = try PDFFixtures.vectorTextPDF(lines: 8)   // 612×792 pt mit Text
        defer { try? FileManager.default.removeItem(at: url) }
        vm.importDocuments([url])
        try await TestFactory.waitFor { vm.project.pages.count == 1 && !vm.hasChanges }
        let folder = try tempFolder("dpi")
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try await vm.exportImages(vm.project.pages,
                                             options: .init(format: .png, dpi: 300),
                                             to: folder)
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: urls[0])))
        #expect(rep.pixelsWide == 2550 && rep.pixelsHigh == 3300)
        // Punktgröße = Pixel × 72 / 300 → 612 × 792 pt ⇒ 300 dpi.
        #expect(abs(rep.size.width - 612) < 0.5 && abs(rep.size.height - 792) < 0.5,
                "Punktgröße \(rep.size)")
        // Nicht leer: die Testseite trägt Text.
        var nonWhite = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 6) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 6) {
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.5 { nonWhite += 1 }
            }
        }
        #expect(nonWhite > 0, "Export ist leer")
    }

    /// Befund B10: Export rendert die CropBox (was jeder Betrachter zeigt),
    /// nicht die MediaBox. Fixture: MediaBox 612×792, CropBox 540×648 pt.
    @Test func exportRendersTheCropBox() async throws {
        let vm = MergeViewModel()
        let url = try PDFFixtures.croppedPagePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        vm.importDocuments([url])
        try await TestFactory.waitFor { vm.project.pages.count == 1 && !vm.hasChanges }
        let folder = try tempFolder("crop")
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try await vm.exportImages(vm.project.pages,
                                             options: .init(format: .png, dpi: 72),
                                             to: folder)
        #expect(pixelDimensions(of: urls[0]) == (540, 648))
    }

    /// Sichtabnahme 2026-10-12: Export in einen Ordner mit Dokumentnamen,
    /// Bilder nur nummeriert. Fehlermöglichkeiten: (1) Kollision überschreibt
    /// einen vorhandenen Ordner; (2) Endung bleibt im Ordnernamen hängen;
    /// (3) leerer Name ergibt einen leeren Ordnernamen.
    @Test func exportFolderIsNamedAfterTheDocumentWithoutCollisions() throws {
        let parent = try tempFolder("named")
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try PageImageExporter.makeExportFolder(in: parent, named: "Bericht.pdf")
        #expect(first.lastPathComponent == "Bericht")
        let marker = first.appendingPathComponent("01.png")
        try Data([0x89]).write(to: marker)
        let second = try PageImageExporter.makeExportFolder(in: parent, named: "Bericht.pdf")
        #expect(second.lastPathComponent == "Bericht 2")
        #expect(FileManager.default.fileExists(atPath: marker.path), "vorhandener Ordner wurde angetastet")
        let third = try PageImageExporter.makeExportFolder(in: parent, named: "")
        #expect(third.lastPathComponent == "Seiten")
    }

    @Test func selectionOnlyExportsSelectedPages() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 4)
        vm.tapSelect(page(in: vm, at: 1))
        vm.cmdToggle(page(in: vm, at: 3))
        let folder = try tempFolder("sel")
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = try await vm.exportImages(vm.orderedSelection,
                                             options: .init(format: .jpeg, dpi: 72),
                                             to: folder)
        #expect(urls.count == 2)
        #expect(urls.allSatisfy { $0.pathExtension == "jpg" })
    }

    @Test func cancelledExportLeavesFolderEmpty() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 6)
        let folder = try tempFolder("cancel")
        defer { try? FileManager.default.removeItem(at: folder) }

        let task = Task {
            try await vm.exportImages(vm.project.pages,
                                      options: .init(format: .png, dpi: 300),
                                      to: folder)
        }
        task.cancel()

        do {
            let urls = try await task.value
            #expect(urls.isEmpty)
        } catch is CancellationError {
            // erwarteter Abbruch
        } catch {
            Issue.record("Unerwarteter Fehler: \(error)")
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true)
    }

    @Test func existingImageSurvivesExportAndLaterFailure() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 2)
        let folder = try tempFolder("collision-rollback")
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appendingPathComponent("01.png")
        let sentinel = Data("existing-user-file".utf8)
        try sentinel.write(to: existing)

        let urls = try await vm.exportImages(vm.project.pages,
                                             options: .init(format: .png, dpi: 72),
                                             to: folder)
        #expect(urls.map(\.lastPathComponent) == ["01_1.png", "02.png"])
        #expect(pixelDimensions(of: urls[0]) == (612, 792))
        #expect(try Data(contentsOf: existing) == sentinel)
        for url in urls { try FileManager.default.removeItem(at: url) }

        let ghost = SourceDocument(url: folder.appendingPathComponent("missing.pdf"), pageCount: 1)
        let pages = [vm.project.pages[0], PageItem(source: ghost, pageIndex: 0)]
        do {
            _ = try await PageImageExporter.export(pages: pages,
                                                   options: .init(format: .png, dpi: 72),
                                                   to: folder) { _ in }
            Issue.record("Second missing source must fail after first image is written")
        } catch let error as MergeError {
            guard case .missingSource = error else { throw error }
        }
        #expect(try Data(contentsOf: existing) == sentinel)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["01.png"])
    }

    @Test func missingSourceThrowsAndCleansUp() async throws {
        let ghost = SourceDocument(
            url: URL(fileURLWithPath: "/tmp/pdftools-ghost-\(UUID().uuidString).pdf"),
            pageCount: 1)
        var item = PageItem(source: ghost, pageIndex: 0)
        item.rotation = 0

        let folder = try tempFolder("ghost")
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            _ = try await PageImageExporter.export(pages: [item],
                                                   options: .init(format: .png, dpi: 72),
                                                   to: folder) { _ in }
            Issue.record("Export hätte fehlschlagen müssen")
        } catch let error as MergeError {
            guard case .missingSource = error else {
                Issue.record("Falscher Fehler: \(error)")
                return
            }
        }
    }
}
