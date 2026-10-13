import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Phase 23c – Platzierungsgeometrie für Bilder in (verschachtelten)
/// Form-XObjects.
///
/// Anlass: Bei stark_v2 hängen drei 4032×3024-Fotos NICHT direkt in den
/// Seiten-Resources, sondern hinter Page → Form → /Image. Der cm/Do-Scan
/// über die Seiten-Content-Bytes sah sie nicht – placed blieb (0,0), die
/// Effective DPI war unbekannt, und der Planner fiel aufs Kantenlimit
/// zurück: Smart schrumpfte 4032 → 2200 px statt auf die 150-DPI-Zielgröße.
/// Der Form-Scan (LIST_FORM_RESOURCES + Scan der Form-Content-Bytes)
/// ergänzt genau die fehlenden Größen.
@Suite struct NestedFormPlacementTests {

    private static func resource(_ resources: [PDFImageResource],
                                 width: Int) throws -> PDFImageResource {
        try #require(resources.first { $0.width == width },
                     "Kein Bild mit Breite \(width) unter \(resources.count) Ressourcen")
    }

    private static func resource(_ resources: [PDFImageResource],
                                 widths: [Int]) throws -> PDFImageResource {
        try #require(resources.first { widths.contains($0.width) },
                     Comment(rawValue: "Kein Bild mit Rung-Breite "
                         + "\(widths) unter \(resources.count) Ressourcen "
                         + "(vorhanden: \(resources.map(\.width)))"))
    }

    // MARK: - Fixture

    @Test(.hangGuard) func fixtureTrägtFormBilderOhneSeitenPlatzierung() throws {
        let url = try PDFFixtures.nestedFormImagesPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let rows = try doc.formResources()
        // Je Seite: die Form selbst plus zwei Bild-Einträge.
        #expect(rows.count == 6, "Form-Ressourcen-Zeilen: \(rows.count) statt 6")
        #expect(rows.filter(\.isImage).count == 4)
        #expect(rows.filter { !$0.isImage }.count == 2)
        #expect(rows.allSatisfy { $0.isImage || $0.parentFormID == nil },
                "Die Form hängt auf beiden Seiten direkt in den Seiten-Resources")
    }

    // MARK: - (a) Platzierungsgeometrie

    @Test(.hangGuard) func formBilderBekommenPlatzierungsgeometrie() throws {
        let url = try PDFFixtures.nestedFormImagesPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let resources = try doc.imageResources()
        #expect(resources.count == 3, "\(resources.count) statt 3 Bildobjekte")

        // 1600 px auf 480 pt (Seite 0) und 240 pt (Seite 1, halbe Form).
        let imageA = try Self.resource(resources, width: 1600)
        #expect(imageA.placements.count == 2,
                "Geteilte Form: \(imageA.placements.count) Platzierungen statt 2")
        let placedA0 = try #require(imageA.placements.first { $0.pageIndex == 0 })
        let placedA1 = try #require(imageA.placements.first { $0.pageIndex == 1 })
        #expect(abs(placedA0.placedWidthPoints - 480) < 1,
                "Breite Seite 0: \(placedA0.placedWidthPoints) statt 480")
        #expect(abs(placedA1.placedWidthPoints - 240) < 1,
                "Breite Seite 1: \(placedA1.placedWidthPoints) statt 240")
        #expect(abs((imageA.effectiveDPI ?? 0) - 240) < 0.5,
                "Effective DPI \(imageA.effectiveDPI ?? -1) statt 240 – die GRÖSSTE Platzierung muss gelten")

        let imageB = try Self.resource(resources, width: 1200)
        let placedB0 = try #require(imageB.placements.first { $0.pageIndex == 0 })
        #expect(abs(placedB0.placedWidthPoints - 360) < 1,
                "Breite \(placedB0.placedWidthPoints) statt 360")
        #expect(abs((imageB.effectiveDPI ?? 0) - 240) < 0.5)

        // Kontrolle: Das direkte Seiten-Bild liefert seine Geometrie
        // unverändert aus dem Seiten-Scan.
        let control = try Self.resource(resources, width: 600)
        let placedC = try #require(control.placements.first { $0.pageIndex == 0 })
        #expect(abs(placedC.placedWidthPoints - 300) < 1,
                "Kontrolle: \(placedC.placedWidthPoints) statt 300")
        #expect(abs((control.effectiveDPI ?? 0) - 144) < 0.5)
    }

    /// Zwei Ebenen (Page → Form → Form → Image): best effort über die
    /// Kettenskala; der Zykel A → B → A darf den Walk nicht lahmlegen.
    @Test(.hangGuard) func zykelWirdAbgeschnittenUndKetteSkaliert() throws {
        let url = try PDFFixtures.cyclicFormImagesPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let resources = try doc.imageResources()
        #expect(resources.count == 1, "\(resources.count) statt 1 Bildobjekt")
        let image = try #require(resources.first)
        let placed = try #require(image.placements.first)
        #expect(abs(placed.placedWidthPoints - 120) < 1,
                "Breite über die Form-Kette: \(placed.placedWidthPoints) statt 120")
        #expect(abs(placed.placedHeightPoints - 60) < 1,
                "Höhe über die Form-Kette: \(placed.placedHeightPoints) statt 60")
    }

    // MARK: - (b) Planner trifft die DPI-Zielgröße

    @Test(.hangGuard) func smartPlannerResampeltFormBilderUndErhaeltKontrolle() throws {
        let url = try PDFFixtures.nestedFormImagesPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        // Geprüft wird der MECHANISMUS (effektive DPI über die Form-Kette →
        // Zielgröße), nicht das Produktziel. Die Fixture liegt bei 240 dpi;
        // seit Smart 220 DPI fährt (2026-10-09), läge sie innerhalb der
        // Toleranz. Deshalb hier ausdrücklich 150 DPI als Ziel.
        var options = CompressionOptions.smart
        options.image.targetDPI = 150

        let doc = try PDFCoreDocument(path: url.path)
        let resources = try doc.imageResources()
        let imageA = try Self.resource(resources, width: 1600)
        let imageB = try Self.resource(resources, width: 1200)
        let control = try Self.resource(resources, width: 600)

        // 240 dpi → Faktor 150/240 = 0,625.
        let targetA = try #require(CompressionPlanner.plannedSize(
            for: imageA, options: options.image))
        #expect(targetA.width == 1000, "Zielbreite \(targetA.width) statt 1000")
        #expect(targetA.height == 750, "Zielhöhe \(targetA.height) statt 750")
        let targetB = try #require(CompressionPlanner.plannedSize(
            for: imageB, options: options.image))
        #expect(targetB.width == 750, "Zielbreite \(targetB.width) statt 750")
        #expect(targetB.height == 563, "Zielhöhe \(targetB.height) statt 563")
        // Kontrolle: 144 dpi liegen im Smart-Budget – kein Eingriff.
        #expect(CompressionPlanner.plannedSize(for: control, options: options.image) == nil,
                "Kontrolle wurde verkleinert, obwohl 144 dpi im Budget liegen")

        // Dieselbe Entscheidung im echten Plan: Die Form-Bilder werden
        // transformiert (nicht am Kantenlimit gehalten), die Kontrolle bleibt.
        let planned = try CompressionPipeline.plan(inputURL: url, options: options)
        for (image, expectedWidth) in [(imageA, 1000), (imageB, 750)] {
            let action = try #require(planned.plan.action(for: image.objectID),
                                      "Keine Aktion für \(image.objectID)")
            #expect(action.transformsImage,
                    "Form-Bild \(image.objectID) blieb stehen: \(action)")
            let target = try #require(action.targetSize)
            // §9.4 – Ziel- oder 0,85×-Rung (der kleinste gate-passende
            // Kandidat gewinnt).
            let rung = Int((Double(expectedWidth) * 0.85).rounded())
            #expect(target.width == expectedWidth || target.width == rung,
                    "Plan-Ziel \(target.width) statt \(expectedWidth)/\(rung)")
        }
        let controlAction = try #require(planned.plan.action(for: control.objectID))
        #expect(!controlAction.transformsImage,
                "144-dpi-JPEG darf ohne Resize nicht erneut verlustbehaftet kodiert werden")
    }

    // MARK: - (c) Klein-Lauf: Renderdiff + echtes Resampling

    @Test(.hangGuard) func kleinLaufResampeltFormBilderUndBleibtAehnlich() throws {
        let url = try PDFFixtures.nestedFormImagesPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let inBytes = Int(Compressor.fileSize(of: url))
        let options = CompressionOptions.make(mode: .small, customConfig: nil,
                                              stripMetadata: false, linearize: false)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("nested-form-small-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try CompressionPipeline.run(inputURL: url, outputURL: out, options: options)

        // Never-Grow auf Dokumentebene.
        let outBytes = Int(Compressor.fileSize(of: out))
        #expect(outBytes < inBytes, "Ausgabe gewachsen: \(inBytes) → \(outBytes)")

        // Die Form-Bilder folgen der DPI-Leiter (Klein: 144/110/96-DPI-
        // Rungs, §9.4) – das Kantenlimit allein hätte 1600 px stehen
        // lassen. Welcher Rung gewinnt, entscheidet der kleinste gate-
        // passende Kandidat; alle drei Rung-Breiten sind DPI-deriviert.
        let after = try PDFCoreDocument(path: out.path).imageResources()
        let imageA = try Self.resource(after, widths: [960, 734, 640])
        #expect(abs(Double(imageA.height) - Double(imageA.width) * 0.75) <= 2,
                "Höhe \(imageA.height) folgt nicht der Seitenratio")
        let imageB = try Self.resource(after, widths: [720, 550, 480])
        #expect(abs(Double(imageB.height) - Double(imageB.width) * 0.75) <= 2,
                "Höhe \(imageB.height) folgt nicht der Seitenratio")

        // Renderdiff Klein: beide Seiten bleiben strukturell erhalten.
        let comparisons = try RenderDifferential.compare(sourceURL: url, outputURL: out)
        #expect(comparisons.count == 2, "\(comparisons.count) Seiten verglichen")
        for comparison in comparisons {
            #expect(comparison.ssim >= 0.9,
                    "SSIM Seite \(comparison.sourcePageIndex): \(comparison.ssim)")
        }
    }

    // MARK: - (d) Never-Grow / KEEP-Regeln

    @Test(.hangGuard) func smartLaufWächstNiemals() throws {
        let url = try PDFFixtures.nestedFormImagesPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let inBytes = Int(Compressor.fileSize(of: url))
        let options = CompressionOptions.make(mode: .smart, customConfig: nil,
                                              stripMetadata: false, linearize: false)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("nested-form-smart-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                        options: options)

        let outBytes = Int(Compressor.fileSize(of: out))
        #expect(outBytes < inBytes, "Smart gewachsen: \(inBytes) → \(outBytes)")

        // Marginale native JPEG-Ersparnisse rechtfertigen keine weitere Generation.
        let rerun = try CompressionPipeline.plan(inputURL: out, options: options)
        #expect(rerun.plan.transformedActions.isEmpty,
                "Zweitlauf transformiert weiter: \(rerun.plan.transformedActions.count) Aktionen")
    }
}
