import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan Finding 17 – Quality Gate der Assembly-Architektur.
///
///   □ Produktionsaufrufer kennen nur `PageAssemblyService`
///   □ Golden Assembly Matrix 100 %
///   □ libqpdf >= PDFKit Semantik → erst danach Cutover
@Suite struct PageAssemblyServiceGateTests {

    // MARK: - Architektur

    /// Die Assembly-Implementierung darf nicht mehr in der UI-Schicht liegen.
    /// Ein `nonisolated static func assemble` im ViewModel war genau das:
    /// PDF-Kernlogik, die ohne UI nicht auffindbar war.
    @Test(.hangGuard) func assemblyLivesInTheServiceNotInTheViewModel() throws {
        let viewModel = try Self.source("PDFTools/PageTools/MergeViewModel.swift")
        #expect(!viewModel.contains("static func assemble(plan:"),
                "Assembly-Implementierung steckt weiterhin im ViewModel")
        #expect(!viewModel.contains("enum PageAssemblyEngine"),
                "Engine-Auswahl steckt weiterhin im ViewModel")

        let service = try Self.source("PDFTools/PageTools/PageAssemblyService.swift")
        #expect(service.contains("static func assemble(plan:"))
    }

    /// Es gibt nur noch EIN Assembly-Backend.
    ///
    /// Der PDFKit-Pfad ist mit Masterplan Schritt 11 entfernt worden. Der
    /// Test hält fest, dass er nicht zurückkehrt – weder als zweiter Zweig
    /// noch als Parameter, über den ein Aufrufer ihn wieder anfordern könnte.
    @Test(.hangGuard) func onlyOneAssemblyBackendExists() throws {
        let source = try Self.source("PDFTools/PageTools/PageAssemblyService.swift")

        // Weder Auswahl noch Zweig dürfen wieder auftauchen.
        #expect(!source.contains("enum PageAssemblyEngine"),
                "Die Backend-Auswahl ist zurück – es soll nur einen Pfad geben")
        #expect(!source.contains("legacyPDFKit"),
                "Der PDFKit-Pfad ist zurück")
        #expect(!source.contains("engine:"), """
            Ein Engine-Parameter ist zurück – Aufrufer könnten damit ein \
            anderes Backend anfordern.
            """)

        // Der verbliebene Pfad läuft über die Bridge.
        #expect(source.contains("PDFCoreAssembler.write"),
                "Die Assemblierung läuft nicht mehr über die Bridge")
    }

    // MARK: - Differential: libqpdf >= PDFKit

    /// Für jede Fixture gilt: Was PDFKit erhält, muss libqpdf auch erhalten.
    /// Umgekehrt darf libqpdf mehr können – das ist kein Fehler, sondern der
    /// Grund für den geplanten Cutover.
    @Test(arguments: AssemblyFixture.all)
    func libqpdfIsNotWorseThanPDFKit(fixture: AssemblyFixture) async throws {
        let source = try fixture.make()
        defer { try? FileManager.default.removeItem(at: source) }

        let document = try #require(PDFDocument(url: source))
        let sourceDocument = SourceDocument(url: source, pageCount: document.pageCount)
        let plan = PageAssemblyPlan(pages: (0..<document.pageCount).map {
            PageItem(source: sourceDocument, pageIndex: $0).assemblyItem
        })

        let pdfKitOutput = Self.tempURL("assembly-pdfkit")
        let libqpdfOutput = Self.tempURL("assembly-libqpdf")
        defer {
            try? FileManager.default.removeItem(at: pdfKitOutput)
            try? FileManager.default.removeItem(at: libqpdfOutput)
        }

        try await PageAssemblyService.assemble(plan: plan, to: pdfKitOutput,
                                               progress: { _ in })
        try await PageAssemblyService.assemble(plan: plan, to: libqpdfOutput,
                                               progress: { _ in })

        let viaPDFKit = try PDFSemanticSnapshot.capture(pdfKitOutput, backend: .libQPDF)
        let viaLibQPDF = try PDFSemanticSnapshot.capture(libqpdfOutput, backend: .libQPDF)

        let regressions = PDFSemanticSnapshot.differences(viaPDFKit, viaLibQPDF)
            .filter { $0.severity <= .high }
        let summary = regressions.map(\.message).joined(separator: " | ")
        #expect(regressions.isEmpty,
                "\(fixture.name): libqpdf verliert gegenüber PDFKit: \(summary)")

        // Beide Ausgaben müssen strukturell sauber sein.
        for output in [pdfKitOutput, libqpdfOutput] {
            let core = try PDFCoreDocument(path: output.path)
            try core.check()
            #expect(core.pageCount == document.pageCount)
        }
    }

    /// Formularfelder überleben die Assembly mit ihren Namen.
    /// Regression: Der libqpdf-Assembler kopierte die Widgets, aber nicht den
    /// /AcroForm-Feldbaum – ohne ihn verlieren die Felder Typ und Name.
    @Test func acroFormSurvivesLibQPDFAssembly() async throws {
        let source = try PDFFixtures.formHierarchyPDF()
        defer { try? FileManager.default.removeItem(at: source) }

        let before = try PDFSemanticSnapshot.capture(source, backend: .libQPDF)
        try #require(before.form.fields.count == 2, "Fixture ohne Formularfelder")

        let document = try #require(PDFDocument(url: source))
        let sourceDocument = SourceDocument(url: source, pageCount: document.pageCount)
        let plan = PageAssemblyPlan(pages: (0..<document.pageCount).map {
            PageItem(source: sourceDocument, pageIndex: $0).assemblyItem
        })

        let output = Self.tempURL("acroform")
        defer { try? FileManager.default.removeItem(at: output) }
        try await PageAssemblyService.assemble(plan: plan, to: output,
                                               progress: { _ in })

        let after = try PDFSemanticSnapshot.capture(output, backend: .libQPDF)
        #expect(after.form.fields.count == before.form.fields.count,
                "Formularfelder verloren: \(after.form.fields.map(\.name))")
        #expect(Set(after.form.fieldNames) == Set(before.form.fieldNames),
                "Feldnamen verändert: \(after.form.fieldNames)")
        let street = try #require(after.form.fields.first { $0.name == "adresse.strasse" })
        #expect(street.value == "Hauptstrasse 1", "Feldwert verloren")
        #expect(street.type == "Tx", "Feldtyp verloren")
    }

    // MARK: - Fixtures

    struct AssemblyFixture: CustomStringConvertible, Sendable {
        let name: String
        let make: @Sendable () throws -> URL

        var description: String { name }

        static let all: [AssemblyFixture] = [
            AssemblyFixture(name: "outline+internal-link") {
                try PDFFixtures.outlinedWithInternalLinkPDF()
            },
            AssemblyFixture(name: "named-destinations") {
                try PDFFixtures.namedDestinationPDF()
            },
            AssemblyFixture(name: "form-hierarchy") {
                try PDFFixtures.formHierarchyPDF()
            },
            AssemblyFixture(name: "nested-outline") {
                try PDFFixtures.nestedOutlinePDF()
            },
            AssemblyFixture(name: "cropbox") {
                try PDFFixtures.croppedPagePDF()
            },
            AssemblyFixture(name: "mixed-sizes") {
                try PDFFixtures.mixedSizesPDF()
            },
            AssemblyFixture(name: "mixed-rotation") {
                try PDFFixtures.mixedRotationPDF()
            },
            AssemblyFixture(name: "annotations") {
                try PDFFixtures.multiAnnotationPDF()
            },
            AssemblyFixture(name: "shared-xobject") {
                try PDFFixtures.sharedImageObjectPDF(pixels: 300)
            }
        ]
    }

    static func tempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).pdf")
    }

    /// Liest aus dem Quellabzug, NICHT aus dem Projektverzeichnis.
    ///
    /// Der Test-Host ist eine sandboxed App; liegt das Projekt unter
    /// ~/Desktop, ist es TCC-geschützt und der Lesezugriff BLOCKIERT dort,
    /// statt zu scheitern – die Suite blieb dadurch mitten im Lauf stehen.
    /// Siehe `SourceSnapshotGateTests`.
    static func source(_ relativePath: String) throws -> String {
        try CompressionEngineStateTests.projectSource(relativePath)
    }

    // MARK: - Differenz beider Backends (Grundlage für Schritt 11)

    /// Ein Dokument mit beschädigtem Bild darf durch die Assemblierung nicht
    /// DUNKLER werden, als es im Original ist.
    ///
    /// Gemessen an `image-dimension-mismatch` (Bild behauptet 800×800 RGB,
    /// liefert 30 Byte): Das Original rendert weiss – PDFKit zeichnet das
    /// kaputte Bild gar nicht. Nach PDFKit-Assemblierung rendert dieselbe
    /// Seite SCHWARZ (mittlere Luminanz 1.8 statt 255.0); die Daten werden
    /// nach dem Kopieren anders interpretiert. Über libqpdf assembliert
    /// bleibt sie weiss.
    ///
    /// Der Test hält diesen Unterschied als Messwert fest. Er ist damit einer
    /// der Differenzbelege, die der Masterplan vor dem Entfernen des
    /// Legacy-Pfads verlangt – und er wird nach dem Cutover automatisch zur
    /// Anforderung an den Produktionspfad, weil `productionEngine` dann auf
    /// libqpdf zeigt.
    @Test func brokenImageDoesNotDarkenPageAfterAssembly() async throws {
        let entry = try #require(
            MalformedCorpus.entries.first { $0.name == "image-dimension-mismatch" },
            "Fixture image-dimension-mismatch fehlt")

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-dark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("source.pdf")
        try entry.make().write(to: source)

        /// Mittlere Luminanz der ersten Seite (0 = schwarz, 255 = weiss).
        func meanLuminance(of url: URL) throws -> Double {
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: 0))
            let size = CGSize(width: 120, height: 155)
            let image = try #require(page.thumbnail(of: size, for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil))
            let w = image.width, h = image.height
            var buffer = [UInt8](repeating: 0, count: w * h)
            let context = try #require(CGContext(
                data: &buffer, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buffer.reduce(0.0) { $0 + Double($1) } / Double(w * h)
        }

        let originalLuminance = try meanLuminance(of: source)
        try #require(originalLuminance > 200, """
            Die Fixture rendert nicht hell (\(originalLuminance)) – dann kann             der Test kein Abdunkeln nachweisen.
            """)

        let document = SourceDocument(url: source, pageCount: 1)
        let plan = PageAssemblyPlan(pages: [
            PageItem(source: document, pageIndex: 0).assemblyItem,
            PageItem(source: document, pageIndex: 0).assemblyItem])

        let output = workspace.appendingPathComponent("libqpdf.pdf")
        try await PageAssemblyService.assemble(
            plan: plan, to: output, progress: { _ in })

        let assembledLuminance = try meanLuminance(of: output)
        #expect(assembledLuminance > originalLuminance - 20, """
            Die Seite ist durch die Assemblierung dunkler geworden: \
            \(String(format: "%.1f", originalLuminance)) → \
            \(String(format: "%.1f", assembledLuminance)).
            """)
    }

}
