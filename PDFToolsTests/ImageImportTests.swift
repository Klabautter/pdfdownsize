import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Images → PDF (Review §65, Feature 4): Bild-Import in den Organizer.
@MainActor
struct ImageImportTests {

    /// Befund A8 (Review 2026-10-09): Der 36-MP-Deckel galt nur in der
    /// Kompression, nicht beim Bildimport. Fehlermöglichkeiten:
    ///  1. Seite trägt mehr Pixel als `maximumDecodablePixels`.
    ///  2. Seitenverhältnis verändert.
    ///  3. Kleine Bilder werden mitverkleinert.
    @Test func importCapsVeryLargeImages() throws {
        let w = 7000, h = 6000   // 42 MP
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("huge-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let pdf = try ImageImporter.singlePagePDF(from: url)
        defer { try? FileManager.default.removeItem(at: pdf) }
        let resource = try #require(try PDFCoreDocument(path: pdf.path).imageResources().first)
        #expect(resource.width * resource.height <= ImageImporter.maximumPixels,
                "\(resource.width)×\(resource.height)")
        #expect(abs(Double(resource.width) / Double(resource.height) - 7.0 / 6.0) < 0.01)

        // 3: ein kleines Bild bleibt unverändert.
        let small = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200,
                                                  bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 0))
        let cg = try #require(small.cgImage)
        #expect(try ImageImporter.capped(cg, name: "klein").width == 300)
    }

    @Test func importingImagesCreatesSinglePages() async throws {
        let (vm, undo) = try await EditTests.makeImportedVM(pageCountPerFile: 1)   // A.pdf
        let png1 = try TestFactory.makeTempPNG(size: CGSize(width: 400, height: 300))
        let png2 = try TestFactory.makeTempPNG(size: CGSize(width: 800, height: 600))

        vm.importDocuments([png1, png2])
        try await TestFactory.waitFor { vm.project.pages.count == 3 && !vm.hasChanges }

        #expect(vm.project.documents.count == 3)
        let imageDocs = vm.project.documents.suffix(2)
        #expect(imageDocs.allSatisfy { $0.fileName.hasSuffix(".png") })
        #expect(imageDocs.allSatisfy { $0.pageCount == 1 })
        _ = undo
    }

    @Test func mixedImportKeepsPdfAndImagePages() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 2)
        let png = try TestFactory.makeTempPNG()

        vm.importDocuments([png])
        try await TestFactory.waitFor { vm.project.pages.count == 3 && !vm.hasChanges }

        // PDF-Seiten zuerst (Reihenfolge des Imports), Bildseite am Ende.
        let last = vm.project.pages[2]
        let doc = vm.project.document(for: last.sourceDocumentID)
        #expect(doc?.fileName.hasSuffix(".png") == true)
    }

    @Test func mergedOutputContainsImagePageWithCorrectDimensions() async throws {
        let (vm, _) = try await EditTests.makeImportedVM(pageCountPerFile: 1)
        let png = try TestFactory.makeTempPNG(size: CGSize(width: 400, height: 300))
        vm.importDocuments([png])
        try await TestFactory.waitFor { vm.project.pages.count == 2 && !vm.hasChanges }

        vm.mergeAndPrepare()
        try await TestFactory.waitFor { vm.outcome != nil && !vm.isProcessing }
        let outcome = try #require(vm.outcome)

        let result = try #require(PDFDocument(url: outcome.url))
        #expect(result.pageCount == 2)
        let bounds = result.page(at: 1)?.bounds(for: .mediaBox) ?? .zero
        #expect(abs(bounds.width - 400) < 1)
        #expect(abs(bounds.height - 300) < 1)

        try? FileManager.default.removeItem(at: outcome.url)
    }

    @Test func unsupportedFilesAreIgnored() async throws {
        let (vm, undo) = try await EditTests.makeImportedVM(pageCountPerFile: 1)
        let txt = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-\(UUID().uuidString).txt")
        try "kein PDF".write(to: txt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: txt) }

        vm.importDocuments([txt])
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.project.pages.count == 1)
        #expect(vm.project.documents.count == 1)
        #expect(vm.errorMessage == nil)
        _ = undo
    }

    @Test func imageImportIsUndoable() async throws {
        let vm = MergeViewModel()
        let undo = UndoManager()
        vm.attachUndoManager(undo)

        let png = try TestFactory.makeTempPNG()
        vm.importDocuments([png])
        try await TestFactory.waitFor { vm.project.pages.count == 1 && !vm.hasChanges }

        undo.undo()
        #expect(vm.project.pages.isEmpty)
        #expect(vm.project.documents.isEmpty)

        undo.redo()
        #expect(vm.project.pages.count == 1)
    }
}
