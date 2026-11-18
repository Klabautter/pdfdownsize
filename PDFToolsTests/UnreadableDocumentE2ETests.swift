import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan B1 (18.11.2026): Nicht verarbeitbare Dateien enden in höchstens
/// 1 s in einem benannten, lokalisierten Zustand – in jedem Werkzeug.
///
/// Befund an 1.0.9: Passwortgeschützte, leere und abgeschnittene PDFs wurden
/// wie Dokumente geladen; „Wird geschätzt …“ blieb stehen, nach einem Klick
/// erschien „PDFTools.PDFCoreError-Fehler 0.“.
///
/// Vorher aufgeschriebene Fehlermöglichkeiten:
///  1. Die Vorprüfung fehlt in einem Werkzeug (je Werkzeug geprüft).
///  2. Sie läuft, aber der Zustand bleibt „bereit“ – Hauptknopf aktiv.
///  3. Sie kommt zu spät (Spinner länger als 1 s).
///  4. Der Text ist roh („PDFCoreError“, „Fehler 0“) oder unlokalisiert.
///  5. Im Stapel läuft die Datei mit und zählt als „fehlgeschlagen“ statt
///     als übersprungen.
///  6. Gegenprobe: Eine gesunde PDF wird NICHT abgelehnt.
@MainActor
@Suite(.serialized) struct UnreadableDocumentE2ETests {

    enum Kind: String, CaseIterable {
        case zeroBytes = "zero-bytes"
        case truncated
        case notAPDF = "not-a-pdf"
        case userPassword = "enc-user-aes256"

        var expected: DocumentProbe.Verdict {
            switch self {
            case .zeroBytes: return .empty
            case .truncated, .notAPDF: return .unreadable
            case .userPassword: return .locked
            }
        }
    }

    static let dir: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unreadable-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func healthyPDF() throws -> URL {
        let url = dir.appendingPathComponent("healthy.pdf")
        if !FileManager.default.fileExists(atPath: url.path) {
            let doc = PDFFixtures.textPage("Gesund")
            let pdf = PDFDocument()
            pdf.insert(doc, at: 0)
            #expect(pdf.write(to: url))
        }
        return url
    }

    static func file(_ kind: Kind) throws -> URL {
        let url = dir.appendingPathComponent("\(kind.rawValue).pdf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        switch kind {
        case .zeroBytes:
            try Data().write(to: url)
        case .truncated:
            let entry = try #require(MalformedCorpus.entries.first { $0.name == "truncated" })
            try entry.make().write(to: url)
        case .notAPDF:
            try Data("Das ist ein Einkaufszettel, keine PDF.\n".utf8).write(to: url)
        case .userPassword:
            let qpdf = Compressor.bundledQPDFURL()
            try #require(FileManager.default.isExecutableFile(atPath: qpdf.path))
            let process = Process()
            process.executableURL = qpdf
            process.arguments = ["--encrypt", "--user-password=geheim", "--owner-password=owner",
                                 "--bits=256", "--", try healthyPDF().path, url.path]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        return url
    }

    /// Wartet höchstens 1 s auf die Bedingung.
    static func within1s(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    static func assertClean(_ text: String, _ context: String) {
        #expect(!text.isEmpty, "\(context): leerer Text")
        for raw in ["PDFCoreError", "Fehler 0", "error 0", "Error Domain"] {
            #expect(!text.contains(raw), "\(context): roher Fehlertext „\(text)“")
        }
    }

    @Test(arguments: Kind.allCases) func vorpruefungBenenntDenFall(_ kind: Kind) throws {
        #expect(DocumentProbe.inspect(try Self.file(kind)) == kind.expected)
        #expect(DocumentProbe.inspect(try Self.healthyPDF()) == .ok(pageCount: 1))
    }

    @Test(arguments: Kind.allCases) func komprimierenZeigtZustandStattSpinner(_ kind: Kind) async throws {
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.select(try Self.file(kind))
        let rejected = await Self.within1s { vm.rejection != nil }
        #expect(rejected, "\(kind.rawValue): nach 1 s nicht abgelehnt (\(vm.documentStatus))")
        #expect(vm.rejection == kind.expected)
        #expect(!vm.canCompress)
        #expect(!vm.estimateRefreshing, "Schätz-Spinner läuft weiter")
        Self.assertClean(kind.expected.title + " " + kind.expected.detail, kind.rawValue)
    }

    @Test func gesundePDFWirdNichtAbgelehnt() async throws {
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.select(try Self.healthyPDF())
        let ready = await Self.within1s { vm.documentStatus == .ready(pageCount: 1) }
        #expect(ready, "\(vm.documentStatus)")
        #expect(vm.canCompress)
    }

    /// Klick vor dem Ende der Vorprüfung: Die Meldung ist lokalisiert, nicht roh.
    @Test(arguments: Kind.allCases) func kernFehlerIstLokalisiert(_ kind: Kind) throws {
        do {
            _ = try Compressor().compress(inputURL: try Self.file(kind), mode: .smart)
            Issue.record("\(kind.rawValue) wurde komprimiert")
        } catch {
            Self.assertClean(CompressionViewModel.userFacingMessage(for: error), kind.rawValue)
        }
    }

    @Test func stapelUeberspringtUndZaehlt() async throws {
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        let healthy = try Self.healthyPDF()
        let second = Self.dir.appendingPathComponent("healthy-2.pdf")
        if !FileManager.default.fileExists(atPath: second.path) {
            try FileManager.default.copyItem(at: healthy, to: second)
        }
        let urls = [healthy, second] + (try Kind.allCases.map(Self.file))
        vm.selectMany(urls)
        let probed = await Self.within1s { vm.bulkRejected.count == Kind.allCases.count }
        #expect(probed, "Stapelzeilen nach 1 s ohne Urteil: \(vm.bulkVerdicts)")
        for kind in Kind.allCases {
            let label = vm.bulkVerdicts[try Self.file(kind)]?.shortLabel ?? ""
            Self.assertClean(label, "Stapel \(kind.rawValue)")
        }
        let results = try await vm.runBulkCompression(vm.bulkInputs)
        #expect(results.count == 2)
        #expect(vm.bulkErrors.isEmpty, "Übersprungene zählen als Fehler: \(vm.bulkErrors)")
        #expect(vm.progressLabel.contains("2 von 6"), "\(vm.progressLabel)")
        #expect(vm.progressLabel.contains("4 übersprungen"), "\(vm.progressLabel)")
        vm.clearBulk()
    }

    @Test(arguments: Kind.allCases) func ocrZeigtZustand(_ kind: Kind) async throws {
        let vm = OCRViewModel()
        vm.accept([try Self.file(kind)])
        let rejected = await Self.within1s { vm.stage == .rejected(kind.expected) }
        #expect(rejected, "\(kind.rawValue): \(vm.stage)")
        #expect(vm.errorMessage == nil, "Zusätzlicher Rohtext: \(vm.errorMessage ?? "")")
    }

    @Test(arguments: Kind.allCases) func konvertierenZeigtZustand(_ kind: Kind) async throws {
        let vm = ConversionViewModel()
        vm.accept([try Self.file(kind)])
        let rejected = await Self.within1s { vm.stage == .rejected(kind.expected) }
        #expect(rejected, "\(kind.rawValue): \(vm.stage)")
    }

    @Test(arguments: Kind.allCases) func organisierenNenntDenGrund(_ kind: Kind) async throws {
        let vm = MergeViewModel()
        vm.importDocuments([try Self.file(kind)])
        let reported = await Self.within1s { vm.errorMessage != nil }
        #expect(reported, "\(kind.rawValue)")
        Self.assertClean(vm.errorMessage ?? "", "Organisieren \(kind.rawValue)")
        #expect(vm.errorMessage?.contains(kind.expected.title) == true, "\(vm.errorMessage ?? "")")
        #expect(vm.project.pages.isEmpty)
    }
}
