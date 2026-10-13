import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Epic Phase 5 – Compression-Regression über die zentrale Pipeline.
/// Regel: Smart liefert niemals eine größere Datei als erfolgreichen Output.
@MainActor
@Suite(.serialized)
struct CompressionRegressionTests {

    @Test func symbolicLinkUsesDocumentSize() throws {
        let input = try PDFFixtures.vectorTextPDF(lines: 40)
        let link = input.deletingLastPathComponent()
            .appendingPathComponent("linked-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: input)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
        let expected = try FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int64
        #expect(Compressor.fileSize(of: link) == expected)
        let result = try compress(link)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.inputBytes == expected)
        #expect(result.outputBytes <= result.inputBytes)
        #expect(PDFDocument(url: result.outputURL)?.pageCount == 1)
    }

    private func compress(_ url: URL, linearize: Bool = false) throws -> CompressionResult {
        try Compressor().compress(inputURL: url,
                                  mode: .smart,
                                  linearize: linearize)
    }

    @Test func textPDFNeverGrowsAndValidates() async throws {
        let input = try PDFFixtures.vectorTextPDF(lines: 40)
        defer { try? FileManager.default.removeItem(at: input) }

        let result = try compress(input)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.outputBytes <= result.inputBytes)
        let report = PDFValidator.validate(outputURL: result.outputURL,
                                           referenceURL: input,
                                           policy: .compression)
        #expect(report.isValid, "\(report.failures)")
    }

    @Test func photoHeavyShrinksOrStaysEqual() async throws {
        let input = try PDFFixtures.photoHeavyPDF(pixels: 1000)
        defer { try? FileManager.default.removeItem(at: input) }
        let inBytes = Compressor.fileSize(of: input)

        let result = try compress(input)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.outputBytes <= inBytes)
        let outDoc = try #require(PDFDocument(url: result.outputURL))
        #expect(outDoc.pageCount == 1)
    }

    @Test func transparentPageSurvivesPipeline() async throws {
        let input = try PDFFixtures.transparentPDF()
        defer { try? FileManager.default.removeItem(at: input) }

        let result = try compress(input)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.outputBytes <= result.inputBytes)
        let report = PDFValidator.validate(outputURL: result.outputURL,
                                           referenceURL: input,
                                           policy: .compression)
        #expect(report.isValid, "\(report.failures)")
    }

    // Bereits optimierte Datei: zweiter Lauf darf weder wachsen noch als
    // „Ersparnis“ verkauft werden.
    @Test func secondPassOnOptimizedOutputIsStable() async throws {
        let input = try PDFFixtures.photoHeavyPDF(pixels: 800)
        defer { try? FileManager.default.removeItem(at: input) }

        let first = try compress(input)
        defer { try? FileManager.default.removeItem(at: first.outputURL) }

        let second = try compress(first.outputURL)
        defer { try? FileManager.default.removeItem(at: second.outputURL) }

        #expect(second.outputBytes <= first.outputBytes + 1024)   // Toleranz 1 KB
        if second.outputBytes > second.inputBytes - second.inputBytes / 100 {
            #expect(second.alreadyOptimized)
        }
    }

    // Rotierte/gemischte Größen: Struktur-Optimierung darf Geometrie nicht ändern.
    @Test func rotatedMixedInputKeepsGeometry() async throws {
        let rotated = try PDFFixtures.rotatedPDF()
        let mixed = try PDFFixtures.mixedSizesPDF()
        defer {
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.removeItem(at: mixed)
        }

        // Beide Quellen zu einer Datei vereinen → dann komprimieren.
        let doc = PDFDocument()
        for url in [rotated, mixed] {
            guard let part = PDFDocument(url: url) else { return }
            for i in 0..<part.pageCount {
                doc.insert(part.page(at: i)!, at: doc.pageCount)
            }
        }
        let combined = try PDFFixtures.write(doc, name: "combined")
        defer { try? FileManager.default.removeItem(at: combined) }

        let result = try compress(combined)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        let report = PDFValidator.validate(outputURL: result.outputURL,
                                           referenceURL: combined,
                                           policy: .compression)
        #expect(report.isValid, "\(report.failures)")

        let out = try #require(PDFDocument(url: result.outputURL))
        #expect(out.pageCount == 6)
        #expect(out.page(at: 1)?.rotation == 90)      // Rotationen unangetastet
    }

    /// Phase 8 – großer Rasterbild-Fall (24 MP, unter dem 36-MP-Guard):
    /// Pipeline muss ohne Crash/Explosion durchlaufen.
    @Test func largeImageUnderGuardCompletes() async throws {
        let input = try PDFFixtures.photoHeavyPDF(pixels: 4800)   // 4800² ≈ 23 MP
        defer { try? FileManager.default.removeItem(at: input) }

        let result = try compress(input)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.outputBytes > 0)
    }
}
