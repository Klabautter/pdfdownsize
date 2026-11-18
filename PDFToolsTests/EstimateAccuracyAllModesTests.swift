import Testing
import Foundation
@testable import PDFTools

/// Masterplan B5: Schätzung bei „Eigene“.
///
/// Befund [G]: irs_form – Smart schätzt 49 %, liefert 47 %; „Eigene“ mit
/// denselben Startwerten schätzt 18 %, liefert 42 %.
///
/// Gemessen wird je Stufe (Klein, Smart, Qualität, Eigene mit den Startwerten
/// der App) an zehn Dateien des Smoke-Satzes – eine je Inhaltsklasse: die
/// Schnellschätzung gegen den echten Lauf, in Prozentpunkten Ersparnis.
/// Abnahme laut Plan: je Stufe mittlere Abweichung ≤ 5 Punkte, keine Datei
/// über 12 Punkte.
///
/// Fehlermöglichkeiten: (1) „Eigene“ nimmt einen anderen Schätzpfad als ihr
/// Lauf; (2) eine Stufe ist im Mittel gut, einzelne Dateien liegen weit weg.
@MainActor
@Suite(.serialized) struct EstimateAccuracyAllModesTests {

    /// Korpusmessung (≈ 7 min): nur mit TEST_RUNNER_PDFTOOLS_ESTIMATE_ACCURACY=1,
    /// wie die übrigen Korpusläufe.
    nonisolated static var corpus: URL? {
        let env = ProcessInfo.processInfo.environment
        guard env["PDFTOOLS_ESTIMATE_ACCURACY"] == "1",
              let path = env["PDFTOOLS_SMOKE_CORPUS"], FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Erste Datei (alphabetisch) je Klasse, ohne „bereits optimiert“-Sonderfall.
    nonisolated static func sample(_ root: URL) -> [URL] {
        let classes = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".profraw") }.sorted()
        return classes.compactMap { name in
            let dir = root.appendingPathComponent(name)
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".pdf") }.sorted().first
                .map { dir.appendingPathComponent($0) }
        }.prefix(10).map { $0 }
    }

    @Test(.enabled(if: EstimateAccuracyAllModesTests.corpus != nil, "Korpusmessung: PDFTOOLS_ESTIMATE_ACCURACY=1"))
    func schaetzungTrifftJedeStufe() async throws {
        let files = Self.sample(try #require(Self.corpus))
        #expect(files.count == 10)
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        let modes: [(String, CompressionMode, CompressionOptions)] = [
            ("Klein", .small, CompressionOptions.make(mode: .small, customConfig: nil, stripMetadata: true, linearize: false)),
            ("Smart", .smart, CompressionOptions.make(mode: .smart, customConfig: nil, stripMetadata: true, linearize: false)),
            ("Qualität", .quality, CompressionOptions.make(mode: .quality, customConfig: nil, stripMetadata: true, linearize: false)),
            ("Eigene", .custom, vm.customOptions),
        ]
        var report: [String] = []
        for (name, mode, options) in modes {
            var deviations: [Double] = []
            for url in files {
                let estimate = try #require(CompressionEstimator.quickEstimate(url: url, options: options))
                let result = mode == .custom
                    ? try Compressor().compress(inputURL: url, options: options)
                    : try Compressor().compress(inputURL: url, mode: mode)
                defer { if result.outputURL != url { try? FileManager.default.removeItem(at: result.outputURL) } }
                let real = 100 * (1 - Double(result.outputBytes) / Double(max(result.inputBytes, 1)))
                let guessed = 100 * estimate.savingsRatio
                deviations.append(abs(real - guessed))
                report.append(String(format: "%@ %@ geschätzt %.1f real %.1f", name, url.lastPathComponent, guessed, real))
            }
            let mean = deviations.reduce(0, +) / Double(deviations.count)
            report.append(String(format: "%@: Mittel %.1f, Max %.1f", name, mean, deviations.max() ?? 0))
            #expect(mean <= 5, "\(name): mittlere Abweichung \(mean)")
            #expect((deviations.max() ?? 0) <= 12, "\(name): größte Abweichung \(deviations.max() ?? 0)")
        }
        print("B5-BERICHT\n" + report.joined(separator: "\n"))
    }
}
