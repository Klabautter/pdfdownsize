import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Der Korpuslauf vergleicht jede Ausgabeseite mit der Quellseite, die
/// `PrimaryOutput.pageMapping` nennt. Stimmt diese Zuordnung nicht mit dem
/// überein, was der Assembler tatsächlich baut, misst der gesamte
/// Render-Vergleich das Falsche – und zwar unbemerkt, weil er dann eben
/// nicht das Dokument prüft, sondern die Zuordnung.
///
/// Genau das war der Fall: `merge` baut [0,0,1,1,2,2,…], die Zuordnung
/// behauptete `outIdx % pageCount`, also [0…n,0…n]. An einem 85-seitigen
/// Dokument verglich Ausgabeseite 85 dadurch Quellseite 0 statt 42
/// (CAR 0.3651 statt 0.0007). Unentdeckt blieb es, weil die Stichprobe
/// erste und letzte Seite nimmt – die einzigen beiden, bei denen sich
/// richtige und falsche Zuordnung decken.
///
/// Diese Suite prüft die Zuordnung deshalb an JEDER Seite und an einem
/// Dokument, dessen Seiten sich sichtbar unterscheiden.
@Suite struct PageMappingGateTests {

    /// Fixture, bei dem Seite *i* eine an Position *i* liegende schwarze
    /// Fläche zeigt. Zwei verschiedene Seiten sind damit renderseitig immer
    /// klar unterscheidbar – eine falsche Zuordnung kann nicht zufällig
    /// „ähnlich genug" aussehen.
    static func makeDistinguishablePages(_ count: Int) throws -> URL {
        var builder = RawPDFBuilder()
        let catalog = builder.reserveNumber()
        let pagesNode = builder.reserveNumber()
        var pageIDs: [Int] = []

        for index in 0..<count {
            // Balken wandert je Seite um 90 pt nach unten.
            let y = 700 - index * 90
            let stream = "0 0 0 rg 60 \(y) 480 70 re f"
            let contents = builder.addObject(
                "<</Length \(stream.utf8.count)>>\nstream\n\(stream)\nendstream")
            pageIDs.append(builder.addPage(parent: pagesNode, contents: contents))
        }

        builder.fill(pagesNode, "<</Type/Pages/Count \(count)/Kids ["
            + pageIDs.map { "\($0) 0 R" }.joined(separator: " ") + "]>>")
        builder.fill(catalog, "<</Type/Catalog/Pages \(pagesNode) 0 R>>")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-mapping-\(UUID().uuidString).pdf")
        try builder.build(rootObject: catalog).write(to: url)
        return url
    }

    /// Anteil deutlich abweichender Pixel zweier Seiten (wie im Render-Diff).
    static func changedRatio(_ a: PDFPage, _ b: PDFPage) -> Double {
        let size = CGSize(width: 200, height: 260)
        func luma(_ page: PDFPage) -> [UInt8]? {
            guard let cg = page.thumbnail(of: size, for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let w = Int(size.width), h = Int(size.height)
            var buf = [UInt8](repeating: 0, count: w * h)
            guard let ctx = CGContext(data: &buf, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        guard let la = luma(a), let lb = luma(b) else { return 1.0 }
        var changed = 0
        for i in 0..<la.count where abs(Int(la[i]) - Int(lb[i])) > 15 { changed += 1 }
        return Double(changed) / Double(la.count)
    }

    /// Die Fixture muss ihren Zweck erfüllen: verschiedene Seiten müssen sich
    /// messbar unterscheiden. Sonst könnte der Test unten nichts beweisen.
    @Test func fixturePagesAreActuallyDistinguishable() throws {
        let url = try Self.makeDistinguishablePages(6)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try #require(PDFDocument(url: url))

        for index in 1..<doc.pageCount {
            let ratio = Self.changedRatio(try #require(doc.page(at: 0)),
                                          try #require(doc.page(at: index)))
            #expect(ratio > 0.05,
                    "Seite 0 und \(index) sind nicht unterscheidbar (CAR \(ratio))")
        }
    }

    /// Der eigentliche Gate: Für JEDE Ausgabeseite muss die vom Runner
    /// gemeldete Quellseite auch die sein, die dort steht.
    @Test(arguments: [CorpusRunnerCore.Operation.merge,
                      .reorder,
                      .deleteMiddle,
                      .extractFirstHalf])
    func mappingMatchesAssembledPages(operation: CorpusRunnerCore.Operation) async throws {
        let source = try Self.makeDistinguishablePages(6)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-mapping-ws-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: workspace)
        }

        let output = try await CorpusRunnerCore.execute(
            operation: operation, fixture: source, pageCount: 6, workspace: workspace)

        let srcDoc = try #require(PDFDocument(url: source))
        let outDoc = try #require(PDFDocument(url: output.url))

        #expect(outDoc.pageCount == output.expectedPages,
                "\(operation): Seitenzahl weicht ab")

        for (outIndex, srcIndex) in output.pageMapping.sorted(by: { $0.key < $1.key }) {
            let outPage = try #require(outDoc.page(at: outIndex),
                                       "\(operation): Ausgabeseite \(outIndex) fehlt")
            let srcPage = try #require(srcDoc.page(at: srcIndex),
                                       "\(operation): Quellseite \(srcIndex) fehlt")
            let ratio = Self.changedRatio(srcPage, outPage)
            #expect(ratio < 0.02, """
                \(operation): Ausgabeseite \(outIndex) zeigt nicht Quellseite \
                \(srcIndex) (CAR \(String(format: "%.4f", ratio))) – die \
                Zuordnung passt nicht zu den gebauten Seiten.
                """)
        }
    }

    /// Gegenprobe: Die alte Merge-Zuordnung (`outIdx % pageCount`) MUSS von
    /// dieser Prüfung als falsch erkannt werden. Ohne diesen Nachweis wüsste
    /// man nicht, ob der Test oben überhaupt etwas messen kann.
    @Test func previousMergeMappingWouldBeRejected() async throws {
        let source = try Self.makeDistinguishablePages(6)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-mapping-neg-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: workspace)
        }

        let output = try await CorpusRunnerCore.execute(
            operation: .merge, fixture: source, pageCount: 6, workspace: workspace)
        let srcDoc = try #require(PDFDocument(url: source))
        let outDoc = try #require(PDFDocument(url: output.url))

        // Die frühere Behauptung, wörtlich.
        var legacyMapping: [Int: Int] = [:]
        for outIdx in 0..<(6 * 2) { legacyMapping[outIdx] = outIdx % 6 }

        var mismatches = 0
        for (outIndex, srcIndex) in legacyMapping {
            guard let outPage = outDoc.page(at: outIndex),
                  let srcPage = srcDoc.page(at: srcIndex) else { continue }
            if Self.changedRatio(srcPage, outPage) >= 0.02 { mismatches += 1 }
        }

        #expect(mismatches > 0, """
            Die alte Zuordnung wird nicht als falsch erkannt – dann kann auch \
            die neue nicht verifiziert werden.
            """)
        // Erste und letzte Seite decken sich in beiden Zuordnungen; genau
        // deshalb blieb der Fehler unter der Stichprobe verborgen.
        #expect(Self.changedRatio(try #require(srcDoc.page(at: 0)),
                                  try #require(outDoc.page(at: 0))) < 0.02)
        #expect(Self.changedRatio(try #require(srcDoc.page(at: 5)),
                                  try #require(outDoc.page(at: 11))) < 0.02)
    }
}
