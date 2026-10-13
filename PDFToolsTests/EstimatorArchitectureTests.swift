import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Final Core Hardening, Phase 7.6 – der Schätzer liest den Plan und
/// entscheidet nichts selbst.
///
/// Es gab hier schon einmal zwei Entscheidungsmaschinen: Der Schätzer rechnete
/// mit `targetDPI * tolerance`, der Kompressor mit `targetDPI * 1.5`. Schätzung
/// und Ergebnis MUSSTEN auseinanderlaufen – kein Feinabgleich hätte das je
/// eingeholt.
///
/// Was der Schätzer zusätzlich modellieren darf, ist Overhead: Container,
/// Objektströme, Metadaten. Was er nicht darf, ist eine eigene Meinung über
/// DPI oder Qualität.
@Suite struct EstimatorArchitectureTests {

    /// Strukturell: Im Schätzer steht kein Entscheidungs-Vokabular.
    ///
    /// Kommentarzeilen sind ausgenommen – der Kopf der Datei beschreibt genau
    /// diesen alten Fehler, und ihn zu erwähnen ist erlaubt.
    @Test(.hangGuard) func estimatorHoldsNoImageDecisionOfItsOwn() throws {
        let source = try CompressionEngineStateTests
            .projectSource("PDFTools/CompressionEstimator.swift")
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        for term in ["targetDPI", "qualityLadder", "ssimThreshold", "jpegQuality",
                     "maxPixelEdge", "forceGrayscale"] {
            #expect(!code.contains(term), """
                Der Schätzer greift auf „\(term)“ zu und trifft damit eine \
                eigene Bildentscheidung. Diese Entscheidung gehört \
                ausschließlich in den CompressionPlanner – zwei Meinungen \
                laufen zwangsläufig auseinander.
                """)
        }
    }

    /// Befund B5 (Review 2026-10-09): Der Schnellschätzer rechnete das
    /// MRC-Scan-Modell auch für „Eigene" ein, wo MRC aus ist – die Schätzung
    /// für graue Scans war dort zu optimistisch. Fehlermöglichkeiten:
    /// (1) Custom-Schätzung ≤ Smart-Schätzung auf einem Scan (MRC
    /// eingerechnet); (2) Smart verliert das Scan-Modell (Regression).
    @Test(.hangGuard) func schaetzerRechnetMrcNurEinWennDerLaufEsDarf() throws {
        let url = try PDFFixtures.mrcScanPagePDF(withPhoto: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let smart = try #require(CompressionEstimator.quickEstimate(url: url, options: .smart))
        let custom = try #require(CompressionEstimator.quickEstimate(
            url: url, options: CompressionPresetFactory.custom(dpi: 220, quality: 0.75)))
        #expect(custom.pointBytes >= smart.pointBytes,
                "Eigene (ohne MRC) schätzt kleiner als Smart: \(custom.pointBytes) < \(smart.pointBytes)")
    }

    /// Verhaltensmäßig, und das ist der eigentliche Beweis: Für JEDE
    /// ausgelieferte Voreinstellung plant der Schätzer exakt so wie der
    /// Ausführende.
    @Test(.hangGuard, arguments: CompressionPresetFactory.CustomPreset.allCases)
    func estimatorAndExecutorPlanAlike(preset: CompressionPresetFactory.CustomPreset)
        throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1600)
        defer { try? FileManager.default.removeItem(at: url) }

        let options = preset.options
        let document = try #require(try? PDFCoreDocument(path: url.path))
        let resources = try #require(try? document.imageResources())
        let estimatorPlan = try CompressionPlanner.plan(
            resources: resources, options: options,
            documentID: url.lastPathComponent,
            documentBytes: Int(Compressor.fileSize(of: url)),
            pixels: LibQPDFPixelSource(document: document))

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("est-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let executed = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                   options: options)

        // V2-11 – semantic Equality: die Kandidaten-Metriken tragen
        // gemessene Laufzeiten (ms-Streuung). Die Paritätsaussage trägt
        // die Semantik: Aktionen und Wahl.
        #expect(estimatorPlan.plan.actions == executed.plan.actions, """
            \(preset.rawValue): Schätzer und Ausführender planen verschieden.
            """)
        #expect(estimatorPlan.plan.decisions.map(\.selectedCandidateID)
                    == executed.plan.decisions.map(\.selectedCandidateID),
                Comment(rawValue: "\(preset.rawValue): unterschiedliche Wahl"))
    }

    /// Und Smart ebenso – die Voreinstellung, die die meisten Nutzer sehen.
    @Test(.hangGuard) func estimatorAndExecutorPlanAlikeForSmart() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1600)
        defer { try? FileManager.default.removeItem(at: url) }
        let options = CompressionOptions.smart

        let document = try #require(try? PDFCoreDocument(path: url.path))
        let resources = try #require(try? document.imageResources())
        let estimatorPlan = try CompressionPlanner.plan(
            resources: resources, options: options,
            documentID: url.lastPathComponent,
            documentBytes: Int(Compressor.fileSize(of: url)),
            pixels: LibQPDFPixelSource(document: document))

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("est-smart-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let executed = try CompressionPipeline.run(inputURL: url, outputURL: out,
                                                   options: options)
        // V2-11 – semantic Equality wie oben (Laufzeiten streuen).
        #expect(estimatorPlan.plan.actions == executed.plan.actions)
        #expect(estimatorPlan.plan.decisions.map(\.selectedCandidateID)
                == executed.plan.decisions.map(\.selectedCandidateID))
    }

    /// Dieselbe Datei, dieselbe Zahl. Eine Schätzung, die zwischen zwei
    /// Aufrufen springt, kann keine Anzeige tragen.
    @Test(.hangGuard) func estimateIsDeterministic() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1400)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try #require(CompressionEstimator.estimate(
            url: url, options: .smart))
        let second = try #require(CompressionEstimator.estimate(
            url: url, options: .smart))
        #expect(first.pointBytes == second.pointBytes)
        #expect(first.lowBytes == second.lowBytes)
        #expect(first.highBytes == second.highBytes)
    }

    /// Die vier Voreinstellungen müssen sich in der Schätzung unterscheiden –
    /// sonst misst das Labor viermal dasselbe.
    @Test(.hangGuard) func presetsProduceDistinctEstimates() throws {
        // Eine grosse Bilddatei: Erst dort greifen die Kantengrenzen der
        // Voreinstellungen (3300 gegen 1400 Bildpunkte) überhaupt. Auf einem
        // kleineren Bild schätzen High, Balanced und Aggressive dasselbe –
        // gemessen 297842 Bytes für alle drei –, weil keine von ihnen etwas
        // zu tun findet. Der Test bewiese dann nichts über die
        // Unterscheidbarkeit, sondern nur über die Fixture.
        let url = try PDFFixtures.hugeImagePDF(pixels: 4000)
        defer { try? FileManager.default.removeItem(at: url) }

        var seen: [String: Int64] = [:]
        for preset in CompressionPresetFactory.CustomPreset.allCases {
            let estimate = try #require(
                CompressionEstimator.estimate(url: url, options: preset.options),
                "\(preset.rawValue) liefert keine Schätzung")
            seen[preset.rawValue] = estimate.pointBytes
        }
        #expect(Set(seen.values).count == seen.count, """
            Zwei Voreinstellungen schätzen identisch: \(seen)
            """)
    }
}
