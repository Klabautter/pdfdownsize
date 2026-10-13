import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Konvertieren-Workspace: Routing (§17) + Bilder→PDF-Kern.
@MainActor
struct ConversionTests {

    @Test func busyImportResetAndSecondExportAreIgnored() {
        let vm = ConversionViewModel()
        let original = URL(fileURLWithPath: "/tmp/source-a.pdf")
        vm.accept([original])
        vm.isWorking = true
        vm.progress = 0.5
        vm.accept([URL(fileURLWithPath: "/tmp/source-b.pdf")])
        vm.reset()
        vm.exportPdfToImages(to: URL(fileURLWithPath: "/tmp/unused-export"))
        #expect(vm.pdfURL == original)
        #expect(vm.isWorking)
        #expect(vm.progress == 0.5)
    }

    @Test func pdfInputRoutesToImageExport() async throws {
        let vm = ConversionViewModel()
        let url = try TestFactory.makeTempPDF(pageCount: 2)

        vm.accept([url])
        #expect(vm.direction == .pdfToImages)
        #expect(vm.pdfURL == url)
        #expect(vm.stage == .ready)
    }

    @Test func imageInputsRouteToPdfCreation() throws {
        let vm = ConversionViewModel()
        let png1 = try TestFactory.makeTempPNG()
        let png2 = try TestFactory.makeTempPNG()

        vm.accept([png1, png2])
        #expect(vm.direction == .imagesToPdf)
        #expect(vm.imageURLs.count == 2)
        #expect(vm.stage == .ready)
    }

    // Review P1.2: gemischte Auswahl wird explizit gemeldet, nicht still halbiert.
    @Test func mixedInputIsRejectedWithMessage() async throws {
        let vm = ConversionViewModel()
        let pdf = try TestFactory.makeTempPDF(pageCount: 1)
        let png = try TestFactory.makeTempPNG()

        vm.accept([png, pdf])
        #expect(vm.direction == nil)
        #expect(!vm.hasSource)
        #expect(vm.stage == .choose)
        #expect(vm.errorMessage?.contains("Organisieren") == true)
    }

    // Review P1.1: Karten öffnen typgefilterte Importer.
    @Test func importerTypesFollowCardDirection() {
        let vm = ConversionViewModel()
        #expect(vm.openImporter(forDirection: .pdfToImages) == [.pdf])
        #expect(vm.openImporter(forDirection: .imagesToPdf) == [.image])
    }

    @Test func unsupportedFilesShowError() {
        let vm = ConversionViewModel()
        let txt = FileManager.default.temporaryDirectory
            .appendingPathComponent("x-\(UUID().uuidString).txt")
        try? "hi".write(to: txt, atomically: true, encoding: .utf8)

        vm.accept([txt])
        #expect(vm.stage == .choose)
        #expect(vm.errorMessage != nil)
    }

    @Test func combinedTemporaryPDFHasAllPagesWithCorrectSizes() async throws {
        let pngA = try TestFactory.makeTempPNG(size: CGSize(width: 400, height: 300))
        let pngB = try TestFactory.makeTempPNG(size: CGSize(width: 800, height: 600))

        let out = try await ConversionViewModel.combinedTemporaryPDF(from: [pngA, pngB]) { _ in }
        defer { try? FileManager.default.removeItem(at: out) }

        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 2)
        #expect(abs((doc.page(at: 0)?.bounds(for: .mediaBox).width ?? 0) - 400) < 1)
        #expect(abs((doc.page(at: 1)?.bounds(for: .mediaBox).width ?? 0) - 800) < 1)
    }

    @Test func combinedTemporaryPDFRejectsEmptyInput() async {
        do {
            _ = try await ConversionViewModel.combinedTemporaryPDF(from: []) { _ in }
            Issue.record("hätte werfen müssen")
        } catch {
            // erwartet
        }
    }

    @Test func resetClearsEverything() async throws {
        let vm = ConversionViewModel()
        vm.accept([try TestFactory.makeTempPDF(pageCount: 1)])
        #expect(vm.hasSource)

        vm.reset()
        #expect(!vm.hasSource)
        #expect(vm.stage == .choose)
        #expect(vm.direction == nil)
        #expect(vm.errorMessage == nil)
    }
}
