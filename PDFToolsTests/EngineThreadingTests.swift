import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Nutzerbefund 2026-10-01: Beim OCR bleibt die weiße Scan-Linie stehen.
/// Ursache: `SWIFT_APPROACHABLE_CONCURRENCY = YES` – `nonisolated async`-
/// Funktionen laufen dann auf dem Actor des AUFRUFERS. Die ViewModels
/// starten die Engines aus `Task { @MainActor … }`, also lief die gesamte
/// Erkennung/Montage auf dem Hauptthread und blockierte die Oberfläche.
///
/// Fehlermöglichkeiten: Eine Engine läuft weiter auf dem Hauptthread (Fort-
/// schritt wird dort gemeldet); der Fix bricht das Ergebnis.
@MainActor
@Suite(.serialized) struct EngineThreadingTests {

    final class ThreadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        private(set) var onMain = 0
        func record() {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if Thread.isMainThread { onMain += 1 }
        }
    }

    @Test func ocrLaeuftNichtAufDemHauptthread() async throws {
        let url = try TestFactory.makeTempPDF(pageCount: 2)
        let probe = ThreadProbe()
        let output = try await OCREngine.run(sourceURL: url, languages: ["de-DE"]) { _ in probe.record() }
        defer { try? FileManager.default.removeItem(at: output.outputURL) }
        #expect(probe.calls > 0)
        #expect(probe.onMain == 0, "\(probe.onMain) von \(probe.calls) Fortschrittsmeldungen auf dem Hauptthread")
    }

    @Test func seitenmontageLaeuftNichtAufDemHauptthread() async throws {
        let url = try TestFactory.makeTempPDF(pageCount: 3)
        let source = SourceDocument(url: url, pageCount: 3)
        let pages = (0..<3).map { PageItem(source: source, pageIndex: $0) }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let probe = ThreadProbe()
        try await PageAssemblyService.assemble(pages: pages, to: out) { _ in probe.record() }
        #expect(probe.calls > 0)
        #expect(probe.onMain == 0, "\(probe.onMain) von \(probe.calls) Meldungen auf dem Hauptthread")
        #expect(PDFDocument(url: out)?.pageCount == 3)
    }

    @Test func bildexportLaeuftNichtAufDemHauptthread() async throws {
        let url = try TestFactory.makeTempPDF(pageCount: 2)
        let source = SourceDocument(url: url, pageCount: 2)
        let pages = (0..<2).map { PageItem(source: source, pageIndex: $0) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = ThreadProbe()
        let files = try await PageImageExporter.export(pages: pages, options: .init(format: .png, dpi: 72), to: folder) { _ in probe.record() }
        #expect(files.count == 2)
        #expect(probe.onMain == 0, "\(probe.onMain) von \(probe.calls) Meldungen auf dem Hauptthread")
    }

    @Test func bilderZuPDFLaeuftNichtAufDemHauptthread() async throws {
        let images = try (0..<2).map { _ in try TestFactory.makeTempPNG() }
        let probe = ThreadProbe()
        let pdf = try await ConversionViewModel.combinedTemporaryPDF(from: images) { _ in probe.record() }
        defer { try? FileManager.default.removeItem(at: pdf) }
        #expect(probe.calls > 0)
        #expect(probe.onMain == 0, "\(probe.onMain) von \(probe.calls) Meldungen auf dem Hauptthread")
    }
}
