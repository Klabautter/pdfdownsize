import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan E3: Sichern über eine Quelldatei.
///
/// Befund: OCR lehnte den Namen des Originals ab, Komprimieren (Stapel) und
/// Organisieren überschrieben die Quelle ohne Rückfrage – das Original war
/// weg, das Ergebnis stand an seiner Stelle.
///
/// Fehlermöglichkeiten: (1) das Ziel ist die Quelle und wird überschrieben;
/// (2) die Prüfung greift nur bei exakt gleicher Schreibweise – ein anderer
/// Pfad zur selben Datei (Symlink, `..`, Groß/klein) rutscht durch;
/// (3) die Prüfung blockiert auch harmlose Ziele.
@MainActor
@Suite(.serialized) struct SaveOverSourceTests {

    static func workDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func pdf(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let doc = PDFDocument()
        doc.insert(PDFFixtures.textPage(name), at: 0)
        #expect(doc.write(to: url))
        return url
    }

    @Test func pruefungErkenntAndereSchreibweisenDerselbenDatei() throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.pdf("Quelle.pdf", in: dir)
        let link = dir.appendingPathComponent("verweis.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let dotted = dir.appendingPathComponent("sub/../Quelle.pdf")
        let upper = dir.appendingPathComponent("QUELLE.pdf")

        #expect(SourceOverwrite.isSource(source, among: [source]))
        #expect(SourceOverwrite.isSource(link, among: [source]))
        #expect(SourceOverwrite.isSource(dotted, among: [source]))
        #expect(SourceOverwrite.isSource(upper, among: [source]))
        #expect(!SourceOverwrite.isSource(dir.appendingPathComponent("Quelle_klein.pdf"), among: [source]))
    }

    @Test func stapelErgebnisUeberschreibtDieQuelleNicht() async throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = try (1...2).map { try Self.pdf("brief-\($0).pdf", in: dir) }
        let before = try Data(contentsOf: inputs[0])

        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.selectMany(inputs)
        _ = try await vm.runBulkCompression(vm.bulkInputs)
        let first = try #require(vm.bulkResultInputs.first { $0 == inputs[0] })

        #expect(throws: SourceOverwriteError.self) {
            try vm.saveBulkResult(for: first, to: inputs[0])
        }
        #expect(try Data(contentsOf: inputs[0]) == before, "Quelle wurde überschrieben")
        #expect(!vm.isBulkResultSaved(for: first))
    }

    @Test func organisierenUeberschreibtKeineQuelle() throws {
        let dir = try Self.workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Self.pdf("a.pdf", in: dir)
        let b = try Self.pdf("b.pdf", in: dir)
        let before = try Data(contentsOf: b)

        let vm = MergeViewModel()
        let docs = [SourceDocument(url: a, pageCount: 1), SourceDocument(url: b, pageCount: 1)]
        vm.project.documents = docs
        vm.project.pages = docs.map { PageItem(source: $0, pageIndex: 0) }
        let temp = dir.appendingPathComponent("ergebnis-temp.pdf")
        try FileManager.default.copyItem(at: a, to: temp)
        let outcome = MergeViewModel.MergeOutcome(url: temp, pageCount: 2, outputBytes: 1,
                                                  combinedInputBytes: 2, kind: .merged)

        #expect(throws: SourceOverwriteError.self) {
            try vm.saveOutcome(outcome, to: b)
        }
        #expect(try Data(contentsOf: b) == before, "Quelle wurde überschrieben")
        #expect(FileManager.default.fileExists(atPath: temp.path), "Ergebnis ging beim Ablehnen verloren")

        // Ein freier Name geht weiter.
        let free = dir.appendingPathComponent("zusammen.pdf")
        try vm.saveOutcome(outcome, to: free)
        #expect(FileManager.default.fileExists(atPath: free.path))
    }
}
