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
}
