import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Smart Compression über die Produktionspipeline (Analyzer → Planner →
/// Executor). Früher prüften diese Fälle den `PDFCorePrototypeCompressor`;
/// der ist entfallen, weil er Bilder über Resource-Namen ersetzte und
/// Nicht-DCT-Bilder durch einen Seitenrender austauschte (Findings 13/15).
/// Die fachlichen Erwartungen sind unverändert.
@MainActor
struct PrototypeCompressionTests {

    /// `photoHeavyPDF` legt die Seite in Bildgröße an – das Bild steht dort
    /// also bei exakt 72 dpi und ist NICHT zu hoch aufgelöst. Für den
    /// Downscale-Nachweis braucht es eine Fixture mit echter Platzierung:
    /// 3000 px auf 400 pt sind 540 dpi.
    @Test func photoAboveThresholdShrinksAndStaysDCT() async throws {
        // Foto-typisches Fixture (weiche Textur): der reine NSGradient-
        // Verlauf liest sich auf Stichprobenauflösung als Flachgrafik
        // (flat 1.0) und liefe unter `.v2` bewusst verlustfrei – dieser
        // Test nagelt die FOTO-Route fest.
        let input = try PDFFixtures.placedTexturedPhotoPDF(pixels: 3000,
                                                           placedPoints: 400)
        defer { try? FileManager.default.removeItem(at: input) }
        let inBytes = Compressor.fileSize(of: input)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("p23-shrink-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: out, options: .smart)

        #expect(outcome.replacedImages >= 1)
        #expect(Compressor.fileSize(of: out) > 0)
        #expect(Compressor.fileSize(of: out) <= inBytes)

        let core = try PDFCoreDocument(path: out.path)
        let images = try core.inspectImages()
        #expect(images.count == 1)
        #expect(images[0].filters == ["DCTDecode"])
        // Die Erwartung folgt der KONFIGURATION statt einer eingetragenen
        // Zahl. Hier stand 1222 px – der Wert für die früheren 220 dpi.
        // Als das Ziel auf 150 dpi ging, schlug der Test fehl, obwohl das
        // Verhalten richtig war. V2-11/§9.4: die Auflösungsleiter ergänzt
        // die 0,85×-Zielstufe; der kleinste gate-passende Rung gewinnt.
        let sourceDPI = 3000.0 / (400.0 / 72.0)          // 540 dpi
        let expectedWidth = 3000.0
            * (ImageCompressionOptions.smart.targetDPI / sourceDPI)
        let rungWidth = (expectedWidth * 0.85).rounded()
        #expect(abs(Double(images[0].width) - expectedWidth) <= 20
                    || abs(Double(images[0].width) - rungWidth) <= 20,
                Comment(rawValue: "Zielbreite \(images[0].width) folgt nicht "
                    + "der DPI-Regel (Ziel \(Int(expectedWidth)), "
                    + "Rung \(Int(rungWidth)))"))

        let attrs = (PDFDocument(url: out)?.documentAttributes ?? [:])
            as? [PDFDocumentAttribute: Any]
        #expect(attrs?[.producerAttribute] as? String == "PDFTools")
    }

    @Test func smallPhotoBelowThresholdIsAlreadyOptimized() async throws {
        let input = try PDFFixtures.photoHeavyPDF(pixels: 400)
        defer { try? FileManager.default.removeItem(at: input) }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("p23-small-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try CompressionPipeline.run(
            inputURL: input, outputURL: out, options: .smart)

        // Unter der Schwelle wird nichts ersetzt – und der Plan sagt auch,
        // warum nicht.
        #expect(outcome.replacedImages == 0)
        #expect(!outcome.plan.keepReasons.isEmpty)
    }

    @Test func textPageSemanticsSurvive() async throws {
        let textURL = try PDFFixtures.vectorTextPDF(lines: 12)
        let photoURL = try PDFFixtures.photoHeavyPDF(pixels: 2000)
        defer {
            try? FileManager.default.removeItem(at: textURL)
            try? FileManager.default.removeItem(at: photoURL)
        }
        let docT = try #require(PDFDocument(url: textURL))
        let docP = try #require(PDFDocument(url: photoURL))

        let plan = PageAssemblyPlan(pages: [
            PageItem(source: SourceDocument(url: textURL, pageCount: docT.pageCount),
                     pageIndex: 0).assemblyItem,
            PageItem(source: SourceDocument(url: photoURL, pageCount: docP.pageCount),
                     pageIndex: 0).assemblyItem,
        ])
        let combinedIn = FileManager.default.temporaryDirectory
            .appendingPathComponent("p23-combined-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: combinedIn) }
        try await PageAssemblyService.assemble(plan: plan, to: combinedIn, progress: { _ in })

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("p23-sem-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try CompressionPipeline.run(
            inputURL: combinedIn, outputURL: out, options: .smart)

        let afterDoc = try #require(PDFDocument(url: out))
        #expect(afterDoc.pageCount == 2)
        let afterText = (0..<2).compactMap { afterDoc.page(at: $0)?.string }.joined()
        #expect(afterText.contains("Zeile"), "Vektor-Text muss erhalten bleiben")
    }
}
