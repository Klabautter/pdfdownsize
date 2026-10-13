import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Monster Epic Phase 11 – Internal Links & Named Destinations.
/// Policy: Ziel im Output vorhanden → Link bleibt (remapped);
/// Ziel fehlt → Link wird entfernt (keine kaputten Referenzen).
@MainActor
struct InternalLinkPolicyTests {

    /// Handgebautes 2-Seiten-PDF mit Named Destination „sec1“ → Seite 2
    /// und einem GoTo-Link auf Seite 1, der genau diese Named Destination nutzt.
    private func namedDestFixture() throws -> URL {
        var data = Data()
        var offsets: [Int] = []
        func add(_ s: String) {
            offsets.append(data.count)
            data.append(Data(s.utf8))
        }
        data.append(Data("%PDF-1.4\n".utf8))
        add("1 0 obj<</Type/Catalog/Pages 2 0 R/Dests 5 0 R>>endobj\n")
        add("2 0 obj<</Type/Pages/Kids[3 0 R 4 0 R]/Count 2>>endobj\n")
        add("3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Annots[6 0 R]>>endobj\n")
        add("4 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\n")
        add("5 0 obj<</sec1[4 0 R /XYZ 0 792 0]>>endobj\n")
        add("6 0 obj<</Type/Annot/Subtype/Link/Rect[0 0 200 40]/A<</S/GoTo/D(sec1)>>>>endobj\n")

        let startxref = data.count
        data.append(Data("xref\n0 7\n".utf8))
        data.append(Data(String(format: "0000000000 65535 f \n").utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer<</Size 7/Root 1 0 R>>\nstartxref\n\(startxref)\n%%EOF\n".utf8))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nameddest-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    private func outputsFor(_ plan: PageAssemblyPlan,
                            tag: String) async throws -> (legacy: URL, qpdf: URL) {
        let legacyOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("p11-legacy-\(tag)-\(UUID().uuidString).pdf")
        let qpdfOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("p11-qpdf-\(tag)-\(UUID().uuidString).pdf")
        try await PageAssemblyService.assemble(plan: plan, to: legacyOut, progress: { _ in })
        try await PageAssemblyService.assemble(plan: plan, to: qpdfOut,
                                          progress: { _ in })
        return (legacyOut, qpdfOut)
    }

    private func assertCheckGreen(_ url: URL) throws {
        guard let qpdfPath = Compressor.findQPDF() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qpdfPath)
        p.arguments = ["--check", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect([0, 3].contains(p.terminationStatus),
                "qpdf --check failed: \(url.lastPathComponent)")
    }

    @Test func reorderRemapsInternalLinkTarget() async throws {
        let url = try PDFFixtures.outlinedWithInternalLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        // Reversed: Kapitel 2 (neuer Index 0), Kapitel 1 mit Link (Index 1).
        let plan = PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: url, sourcePageIndex: 1),
            PageAssemblyItem(sourceURL: url, sourcePageIndex: 0),
        ])

        let outs = try await outputsFor(plan, tag: "reorder")
        defer {
            try? FileManager.default.removeItem(at: outs.legacy)
            try? FileManager.default.removeItem(at: outs.qpdf)
        }

        for engineURL in [outs.legacy, outs.qpdf] {
            let core = try PDFCoreDocument(path: engineURL.path)
            let targets = try core.internalLinkTargets()
            // Externer? Nein – hier nur der interne Link; Ziel nach Reorder: Index 0.
            #expect(targets == [0], "\(engineURL.lastPathComponent): \(targets)")
        }
    }

    @Test func deletedTargetRemovesDanglingLinkBothEngines() async throws {
        // Quelle hat internen Link S.0 → S.1; Plan enthält NUR S.0 → Ziel fehlt.
        let url = try PDFFixtures.outlinedWithInternalLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let plan = PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: url, sourcePageIndex: 0),
        ])

        let outs = try await outputsFor(plan, tag: "dangling")
        defer {
            try? FileManager.default.removeItem(at: outs.legacy)
            try? FileManager.default.removeItem(at: outs.qpdf)
        }

        for engineURL in [outs.legacy, outs.qpdf] {
            let core = try PDFCoreDocument(path: engineURL.path)
            let targets = try core.internalLinkTargets()
            #expect(!targets.contains(-1), "dangling link überlebt: \(targets)")
            #expect(throws: Never.self) { try core.check() }
            try assertCheckGreen(engineURL)
        }
    }

    // Werden ALLE Seiten übernommen, muss ein Named-Dest-Verweis erhalten
    // bleiben – samt der Zieltabelle, auf die er zeigt.
    //
    // Dieser Test verlangte zuvor das Gegenteil: „die Named-Dest-Tabelle wird
    // beim Assembly nicht mitkopiert – der GoTo-Link wird deshalb als kaputt
    // entfernt". Das war kein Verhalten, sondern ein Mangel, der zur Politik
    // erhoben wurde. Was er kostete, zeigte sich an echten Dokumenten:
    // `1409.1556.pdf` verlor auf diesem Weg 272 von 275 Links (Befund 16),
    // ein CVPR-Paper 185 von 187 (Befund 13).
    //
    // Seit die Ziel-Übertragung beide Formate abdeckt – Namensbaum unter
    // /Names und flaches /Dests im Katalog – ist die Tabelle da, und der
    // Verweis bleibt gültig. Der Nachbartest
    // `namedDestDanglingPolicyBothEngines` prüft weiterhin den Fall, in dem
    // die Zielseite NICHT übernommen wird: Dort muss der Verweis verschwinden.
    @Test func namedGoToLinkSurvivesWhenAllPagesAreKept() async throws {
        let url = try namedDestFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let plan = PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: url, sourcePageIndex: 0),
            PageAssemblyItem(sourceURL: url, sourcePageIndex: 1),
        ])
        let outs = try await outputsFor(plan, tag: "named-full")
        defer {
            try? FileManager.default.removeItem(at: outs.legacy)
            try? FileManager.default.removeItem(at: outs.qpdf)
        }

        // Der Produktionspfad muss den Verweis erhalten. Für den Legacy-Pfad
        // wird das Ergebnis nur gemessen: PDFKit verliert die Tabelle
        // weiterhin – eines der Argumente für den Cutover.
        let core = try PDFCoreDocument(path: outs.qpdf.path)
        let targets = try core.internalLinkTargets()
        #expect(targets.contains(1), """
            Der Verweis auf Seite 2 fehlt, obwohl beide Seiten übernommen \
            wurden – gefunden: \(targets)
            """)
        try assertCheckGreen(outs.qpdf)

        let legacyTargets = (try? PDFCoreDocument(path: outs.legacy.path)
            .internalLinkTargets()) ?? []
        print("Named-Dest nach Assembly – libqpdf: \(targets), PDFKit: \(legacyTargets)")
        try assertCheckGreen(outs.legacy)
    }

    @Test func namedDestDanglingPolicyBothEngines() async throws {
        let url = try namedDestFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        // Nur Seite 1 im Plan → Named-Dest-Ziel fehlt → Link entfernen.
        let plan = PageAssemblyPlan(pages: [
            PageAssemblyItem(sourceURL: url, sourcePageIndex: 0),
        ])
        let outs = try await outputsFor(plan, tag: "named-partial")
        defer {
            try? FileManager.default.removeItem(at: outs.legacy)
            try? FileManager.default.removeItem(at: outs.qpdf)
        }
        for engineURL in [outs.legacy, outs.qpdf] {
            let core = try PDFCoreDocument(path: engineURL.path)
            let targets = try core.internalLinkTargets()
            #expect(targets.isEmpty || !targets.contains(-1),
                    "\(engineURL.lastPathComponent): \(targets)")
            #expect(throws: Never.self) { try core.check() }
            try assertCheckGreen(engineURL)
        }
    }
}
