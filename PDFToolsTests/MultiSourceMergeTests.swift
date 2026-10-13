import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Final Core Hardening, Phase 3 – echte Multi-Source-Merges.
///
/// Geprüft wird gegen das Manifest aus `MultiSourceScenarios`: Ausgabeseite
/// *i* muss die Seite zeigen, die das Szenario dort vorsieht. Ein Vergleich
/// über Seitenzahlen allein würde eine vertauschte Reihenfolge nicht
/// bemerken – dieselbe Lücke, die beim Render-Vergleich und in der
/// Differenzmatrix aufgefallen ist.
@Suite struct MultiSourceMergeTests {

    static var corpusRoot: URL {
        CorpusRunnerCore.Config.fromEnvironment().corpusRoot
    }

    /// Rendert eine Seite klein und liefert den Luminanzpuffer.
    static func fingerprint(_ page: PDFPage) -> [UInt8]? {
        let size = CGSize(width: 120, height: 155)
        guard let cg = page.thumbnail(of: size, for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        var buffer = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buffer, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }

    /// Anteil deutlich abweichender Pixel.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }
        var changed = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 15 { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    /// Der Kern: Jede Ausgabeseite muss die im Manifest genannte Quellseite
    /// zeigen.
    @Test(.hangGuard, arguments: MultiSourceScenarios.all)
    func scenarioMatchesManifest(scenario: MultiSourceScenarios.Scenario) async throws {
        let root = Self.corpusRoot
        // Fehlt eine Quelle, ist das ein Infrastrukturproblem – es wird
        // gemeldet, nicht still übersprungen.
        var sourceURLs: [URL] = []
        for spec in scenario.sources {
            let url = root.appendingPathComponent(spec.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record("""
                    Szenario \(scenario.name): Quelle fehlt im Korpus – \
                    \(spec.relativePath)
                    """)
                return
            }
            sourceURLs.append(url)
        }

        // Plan aus dem Manifest bauen.
        var items: [PageAssemblyItem] = []
        for (index, spec) in scenario.sources.enumerated() {
            for page in spec.pages {
                items.append(PageAssemblyItem(sourceURL: sourceURLs[index],
                                              sourcePageIndex: page))
            }
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-\(scenario.name)-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        try await PageAssemblyService.assemble(plan: PageAssemblyPlan(pages: items),
                                               to: output, progress: { _ in })

        let result = try #require(PDFDocument(url: output),
                                  "\(scenario.name): Ausgabe nicht lesbar")
        let expected = scenario.expectedOrigin
        #expect(result.pageCount == expected.count, """
            \(scenario.name): \(result.pageCount) Seiten statt \(expected.count)
            """)

        // Jede Seite gegen ihre Herkunft prüfen.
        for (outIndex, origin) in expected.enumerated() {
            guard outIndex < result.pageCount,
                  let outPage = result.page(at: outIndex),
                  let sourceDoc = PDFDocument(url: sourceURLs[origin.source]),
                  let srcPage = sourceDoc.page(at: origin.page) else { continue }
            guard let a = Self.fingerprint(srcPage), let b = Self.fingerprint(outPage)
            else { continue }
            let diff = Self.difference(a, b)
            #expect(diff < 0.02, """
                \(scenario.name): Ausgabeseite \(outIndex) zeigt nicht \
                \(scenario.sources[origin.source].relativePath) Seite \
                \(origin.page) (Abweichung \(String(format: "%.4f", diff)))
                """)
        }

        // Struktur muss sauber sein.
        let core = try PDFCoreDocument(path: output.path)
        #expect(throws: Never.self) { try core.check() }
    }

    /// Formularfelder dürfen beim Zusammenführen nicht verschwinden.
    ///
    /// Getrennt geprüft, weil ein Renderfingerabdruck ein fehlendes Feld
    /// nicht bemerkt: Ein Widget ohne Erscheinungsbild sieht auf der Seite
    /// aus wie keines.
    @Test(.hangGuard)
    func formFieldsSurviveMultiSourceMerge() async throws {
        let root = Self.corpusRoot
        let scenarios = MultiSourceScenarios.all.filter {
            $0.category.contains("form collision")
        }
        try #require(!scenarios.isEmpty, "Keine Formular-Szenarien definiert")

        for scenario in scenarios {
            var urls: [URL] = []
            var expectedFields = 0
            var missing = false
            for spec in scenario.sources {
                let url = root.appendingPathComponent(spec.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    missing = true; break
                }
                urls.append(url)
                // Nur die Widgets der ÜBERNOMMENEN Seiten zählen.
                //
                // Zuerst stand hier die Feldzahl des ganzen Dokuments – bei
                // einem Szenario, das nur Seite 0 übernimmt, war das eine
                // Erwartung an Seiten, die gar nicht im Ergebnis stehen. Der
                // Test meldete daraufhin einen Verlust, den es nicht gab.
                // Dieselbe Lehre wie beim Render-Vergleich: Ein Vergleich
                // ohne Seitenzuordnung misst etwas anderes, als er zu messen
                // vorgibt.
                if let document = PDFDocument(url: url) {
                    for page in spec.pages where page < document.pageCount {
                        expectedFields += document.page(at: page)?
                            .annotations.filter { $0.type == "Widget" }.count ?? 0
                    }
                }
            }
            if missing { continue }

            var items: [PageAssemblyItem] = []
            for (index, spec) in scenario.sources.enumerated() {
                for page in spec.pages {
                    items.append(PageAssemblyItem(sourceURL: urls[index],
                                                  sourcePageIndex: page))
                }
            }
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("msform-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: output) }

            try await PageAssemblyService.assemble(
                plan: PageAssemblyPlan(pages: items), to: output, progress: { _ in })

            // Gezählt werden ebenfalls Widgets, nicht AcroForm-Einträge:
            // Mehrere Widgets können zu EINEM Feld gehören (ein Feld mit
            // Erscheinungsstellen auf mehreren Seiten). Die Frage ist, ob
            // eine Eingabestelle verschwindet – nicht, wie sie gruppiert ist.
            let merged = try #require(PDFDocument(url: output))
            var widgets = 0
            for index in 0..<merged.pageCount {
                widgets += merged.page(at: index)?
                    .annotations.filter { $0.type == "Widget" }.count ?? 0
            }
            #expect(widgets >= expectedFields, """
                \(scenario.name): \(expectedFields) Eingabestellen in den \
                übernommenen Seiten, \(widgets) in der Ausgabe – \
                \(expectedFields - widgets) verloren.
                """)
        }
    }

    /// Die Szenarien müssen die geforderten Kategorien wirklich abdecken.
    ///
    /// Ohne diese Probe könnte die Liste wachsen, ohne dass eine Kategorie
    /// je geprüft wird.
    @Test(.hangGuard) func scenariosCoverRequiredCategories() {
        let categories = Set(MultiSourceScenarios.all.map(\.category))
        let joined = categories.joined(separator: " ")

        for required in ["form collision", "navigation", "page labels",
                         "geometry", "fonts", "producer mix",
                         "annotations", "structure"] {
            #expect(joined.contains(required),
                    "Kategorie fehlt in den Szenarien: \(required)")
        }
        #expect(MultiSourceScenarios.all.count >= 20, """
            Nur \(MultiSourceScenarios.all.count) Szenarien – gefordert sind 20
            """)
        let threeSource = MultiSourceScenarios.all.filter { $0.sources.count >= 3 }
        #expect(threeSource.count >= 3, """
            Nur \(threeSource.count) Szenarien mit drei Quellen
            """)
    }
}
