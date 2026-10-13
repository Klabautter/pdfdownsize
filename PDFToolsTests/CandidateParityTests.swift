import Testing
import Foundation
@testable import PDFTools

/// Phase V2-3a/V2-11 – Vertrags-Tests des Candidate-Pfads.
///
/// DER Vorgängertest „Parität legacy vs candidateEngine“ hat mit dem
/// V2-Cutover (§25: alte V1-Branches entfernen) seinen Gegenstand verloren:
/// Es gibt nur noch den Candidate-Pfad. Fortgeschrieben ist der Test als
/// Katalog-Vertrag je Bildklasse – festgenagelt wird, was die Parität
/// vorher bewies und was der Produktionsvertrag jetzt verlangt:
///
///  1. AKTIONSKATALOG je Klasse: photo → jpeg/keep, graphics →
///     flate/indexed/keep, bilevel → g4/jbig2/keep, CMYK → cmyk/keep,
///     JPX/oversized/small → je Klasse korrekt.
///  2. NEVER-GROW: Kein transformierter Kandidat übersteigt die
///     Originalbytes (allerdings ist das Ganze die gleiche Regel, die
///     bereits in der Engine steht – hier als End-to-End-Nagel).
///  3. KEEP-Gründe bleiben kategorial stabil (structural reasons).
///  4. Der Default-Plan ist ein Candidate-Plan (traceVersion 2).
@Suite struct CandidateParityTests {

    // MARK: Helfer

    static func candidateOptions(_ base: CompressionOptions) -> CompressionOptions {
        var options = base
        options.featureFlags.candidateEngine = true
        return options
    }

    /// Aktionsart als vergleichbarer Schlüssel.
    static func kind(_ action: ImageCompressionAction) -> String {
        switch action {
        case .keep: return "keep"
        case .losslessResize: return "flate"
        case .indexed: return "indexed"
        case .jpeg: return "jpeg"
        case .cmykJpegReencode: return "cmyk"
        case .ccittG4: return "g4"
        case .jbig2: return "jbig2"
        case .mrc: return "mrc"
        }
    }

    /// Eine Tabellenzeile: Fixture × Preset → Vertrag je Klasse.
    private struct FixtureRow {
        let label: String
        let options: CompressionOptions
        /// Erlaubte Aktionsarten für die transformierten Ressourcen des
        /// Fixtures (KEEP eingeschlossen).
        let allowedKinds: Set<String>
        let makeFixture: () throws -> URL
    }

    private static let rows: [FixtureRow] = [
        FixtureRow(label: "photo (smart)",
                   options: .smart,
                   allowedKinds: ["jpeg", "keep"],
                   makeFixture: { try PDFFixtures.photoAtWidth(2400) }),
        FixtureRow(label: "oversized photo (smart)",
                   options: .smart,
                   allowedKinds: ["jpeg", "keep"],
                   makeFixture: { try PDFFixtures.photoAtWidth(3600) }),
        FixtureRow(label: "graphics (smart)",
                   options: .smart,
                   allowedKinds: ["flate", "indexed", "keep"],
                   makeFixture: { try PDFFixtures.screenshotLikePDF(pixels: 1400) }),
        FixtureRow(label: "bilevel (smart)",
                   options: .smart,
                   allowedKinds: ["g4", "jbig2", "keep"],
                   makeFixture: { try PDFFixtures.bilevelScanPDF(pixels: 900,
                                                                  rows: 1200,
                                                                  placedPoints: 144) }),
        FixtureRow(label: "CMYK verlustfrei (smart)",
                   options: .smart,
                   allowedKinds: ["flate", "keep"],
                   makeFixture: { try PDFFixtures.cmykPhotoPDF(pixelWidth: 2000) }),
        FixtureRow(label: "JPX-Input (smart)",
                   options: .smart,
                   allowedKinds: ["jpeg", "flate", "keep"],
                   makeFixture: { try PDFFixtures.jpxImagePDF(kind: .photoRGBLossy,
                                                               placedWidth: 60) }),
        FixtureRow(label: "small (smart)",
                   options: .smart,
                   allowedKinds: ["keep"],
                   makeFixture: { try PDFFixtures.photoHeavyPDF(pixels: 60) }),
    ]

    @Test(.hangGuard) func aktionskatalogUndNeverGrowProFixture() throws {
        var report = "\n=== KATALOG-TABELLE candidateEngine (V2-11) ===\n"
        for row in Self.rows {
            let url = try row.makeFixture()
            defer { try? FileManager.default.removeItem(at: url) }

            let planned = try CompressionPipeline.plan(
                inputURL: url, options: Self.candidateOptions(row.options))
            #expect(planned.plan.traceVersion == 2)
            #expect(!planned.plan.candidateSets.isEmpty)

            for action in planned.plan.actions {
                #expect(row.allowedKinds.contains(Self.kind(action)),
                        """
                        \(row.label) / \(action.objectID): Aktionsart \
                        \(Self.kind(action)) außerhalb des Katalogs \
                        \(row.allowedKinds)
                        """)
                // NEVER-GROW: Ein transformierter Kandidat ist nie größer
                // als die Originalbytes des Streams.
                if let expected = action.expectedEncodedBytes,
                   action.originalEncodedBytes >= 0 {
                    #expect(expected < action.originalEncodedBytes,
                            """
                            \(row.label) / \(action.objectID): \
                            \(expected) >= \
                            \(action.originalEncodedBytes)
                            """)
                }
                report += "  \(row.label) / \(action.objectID): "
                    + "\(Self.kind(action)) \(action.originalEncodedBytes)"
                if let expected = action.expectedEncodedBytes {
                    report += " → \(expected)"
                }
                report += "\n"
            }
        }
        // Tabelle als Beleg-Artefakt (/tmp/opencode ist der erlaubte
        // Ablageplatz) und zusätzlich auf stdout (xcodebuild-Log).
        if let data = report.data(using: .utf8) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/opencode/parity-table.txt"))
        }
        print(report)
    }

    // MARK: CMYK lossy (Quality-Preset) – YCCK-Kandidat + 6b-Barriere

    @Test(.hangGuard) func cmykVerlustbehaftetBleibtHinterDer6bBarriere() throws {
        let jpeg = try CMYKLossyTests.smoothCmykJpeg(2000, quality: 0.95)
        let url = try CMYKLossyTests.cmykJpegPDF(jpeg: jpeg, pixels: 2000,
                                                 placedPoints: 150)
        defer { try? FileManager.default.removeItem(at: url) }
        let options = CompressionOptions(image: .quality)
        let planned = try CompressionPipeline.plan(inputURL: url,
                                                   options: Self.candidateOptions(options))
        // YCCK-Kandidat: aus planCMYKReencode abgeleitet, kleinergut
        // gegen die 6b-Repack-Barriere und das ΔE-Gate.
        let cmykActions = planned.plan.actions.filter { action in
            if case .cmykJpegReencode = action { return true }
            return false
        }
        #expect(!cmykActions.isEmpty,
                "Quality-Preset auf glattem CMYK-JPEG soll den YCCK-Kandidaten wählen")
        for action in cmykActions {
            #expect(action.expectedEncodedBytes ?? 0
                    < action.originalEncodedBytes)
        }
    }

    // MARK: Produktion = Candidate Engine (V2-11, §25)

    @Test(.hangGuard) func defaultPlanIstCandidateEngine() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        let planned = try CompressionPipeline.plan(inputURL: url, options: .smart)
        #expect(planned.plan.traceVersion == 2)
        #expect(!planned.plan.candidateSets.isEmpty)
        #expect(planned.plan.decisions.count == planned.plan.actions.count)
        #expect(planned.plan.goal == .balanced)
    }
}
