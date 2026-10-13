import Testing
import Foundation
import PDFKit
import AppKit
import CryptoKit
import Combine
@testable import PDFTools

/// Befund B11 (Review 2026-10-09) – „Abbrechen" greift beim Zusammenführen,
/// Extrahieren und Teilen erst, nachdem die qpdf-Bridge die ganze Datei
/// geschrieben hat.
///
/// Fehlermöglichkeiten, gegen die diese Suite geschrieben ist (AGENTS.md:
/// erst aufschreiben, dann testen, dann Code):
///
///   1. Abbruch wird ignoriert, die Datei wird trotzdem fertig geschrieben.
///   2. Abbruch lässt eine halbe Datei unter dem Zielpfad (oder die
///      `.pdfcore-tmp`-Datei daneben) liegen.
///   3. Abbruch bricht den NÄCHSTEN Lauf – globaler Zustand in der Bridge,
///      nicht freigegebene Prozess-Sperre, hängengebliebene QPDF-Objekte.
///   4. Ohne Abbruch verändert sich das Ergebnis (Byteidentität vorher/nachher).
///   5. Ein Fortschritts-Callback nach dem Abbruch überschreibt UI-Zustand.
///   6. Abbruch während der Schreibphase (QPDFWriter) greift nicht – die
///      Seitenschleife ist schnell, die eigentliche Zeit vergeht beim
///      Schreiben der Streams.
///
/// Die Suite ist E2E: Sie ruft dieselben Einstiegspunkte wie die App
/// (`PageAssemblyService.assemble`, `MergeViewModel`,
/// `ConversionViewModel.combinedTemporaryPDF`) und prüft das Ergebnis auf
/// der Platte. Der Byteidentitäts-Test schreibt ein wiederholbares Artefakt
/// (Hashes + Ausgabedatei), wenn `PDFTOOLS_B11_KEEP_DIR` gesetzt ist.
@Suite(.serialized) struct AssemblyCancellationTests {

    // MARK: - Hilfen

    static func workspace(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("b11-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Mehrseitiges Dokument, dessen Seiten sich unterscheiden (Text je Seite).
    static func multiPageSource(pages: Int, name: String) throws -> URL {
        let doc = PDFFixtures.document(
            pages: (0..<pages).map { PDFFixtures.textPage("B11 Seite \($0 + 1)") })
        return try PDFFixtures.write(doc, name: name)
    }

    static func items(for url: URL, repeatPages times: Int = 1) throws -> [PageItem] {
        let doc = try #require(PDFDocument(url: url))
        let source = SourceDocument(url: url, pageCount: doc.pageCount)
        var result: [PageItem] = []
        for _ in 0..<times {
            for i in 0..<doc.pageCount { result.append(PageItem(source: source, pageIndex: i)) }
        }
        return result
    }

    /// Inhalt eines Ordners, ohne zu werfen (für Diagnosetexte in #expect).
    static func leftovers(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["<nicht lesbar>"]
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash der Datei OHNE den /ID-Trailer-Eintrag.
    ///
    /// qpdf bildet das zweite /ID-Wort aus Uhrzeit und Dateinamen
    /// (`QPDFWriter::generateID`, ohne `setDeterministicID`). Alles andere –
    /// Objekte, Streams, Offsets, der Producer-Stempel – ist deterministisch.
    /// Beide /ID-Strings sind gleich lang (16 Byte hex), die xref-Offsets
    /// ändern sich dadurch nicht.
    static func normalizedSHA256(of url: URL) throws -> (hash: String, idRanges: Int) {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        // Robust über Bytes: Suche "/ID [" ... "]" und ersetze den Inhalt.
        var bytes = [UInt8](data)
        let needle = Array("/ID [".utf8)
        var replaced = 0
        var i = 0
        while i + needle.count <= bytes.count {
            if Array(bytes[i..<i + needle.count]) == needle {
                var j = i + needle.count
                while j < bytes.count, bytes[j] != UInt8(ascii: "]") { j += 1 }
                for k in (i + needle.count)..<j { bytes[k] = UInt8(ascii: "0") }
                replaced += 1
                i = j
            }
            i += 1
        }
        _ = text
        return (Self.sha256(Data(bytes)), replaced)
    }

    /// Positionen, an denen sich zwei gleich lange Dateien unterscheiden.
    static func differingOffsets(_ a: Data, _ b: Data) -> [Int] {
        guard a.count == b.count else { return [-1] }
        var out: [Int] = []
        for i in 0..<a.count where a[i] != b[i] { out.append(i) }
        return out
    }

    // MARK: - (4) Byteidentität ohne Abbruch

    /// Ein Merge aus zwei Quellen (mehrere Quellen → kein PDFKit-Outline-Schritt)
    /// und ein Extract mit Rotation aus EINER Quelle. Das Ergebnis muss nach dem
    /// Bridge-Umbau Byte für Byte dasselbe sein wie davor – bis auf das
    /// zeitabhängige zweite /ID-Wort.
    ///
    /// Wiederholbares Artefakt: Mit `PDFTOOLS_B11_KEEP_DIR=<Ordner>` und
    /// `PDFTOOLS_B11_TAG=before|after` legt der Test Quellen und Ausgaben
    /// dort ab; beim zweiten Lauf werden die Quellen des ersten Laufs
    /// wiederverwendet (PDFKit stempelt sonst ein neues Erstelldatum).
    @Test(.hangGuard) func uncancelledRunIsByteIdenticalBeforeAndAfter() async throws {
        let env = ProcessInfo.processInfo.environment
        let keepDir = env["PDFTOOLS_B11_KEEP_DIR"].map { URL(fileURLWithPath: $0) }
        let tag = env["PDFTOOLS_B11_TAG"] ?? "run"
        if let keepDir {
            try FileManager.default.createDirectory(at: keepDir, withIntermediateDirectories: true)
        }

        let ws = try Self.workspace("identity")
        defer { try? FileManager.default.removeItem(at: ws) }

        func source(_ name: String, make: () throws -> URL) throws -> URL {
            let local = ws.appendingPathComponent("\(name).pdf")
            if let keepDir {
                let kept = keepDir.appendingPathComponent("\(name).pdf")
                if FileManager.default.fileExists(atPath: kept.path) {
                    try FileManager.default.copyItem(at: kept, to: local)
                    return local
                }
                let fresh = try make()
                try FileManager.default.copyItem(at: fresh, to: kept)
                try FileManager.default.copyItem(at: fresh, to: local)
                return local
            }
            try FileManager.default.copyItem(at: try make(), to: local)
            return local
        }

        let a = try source("source-a") { try PDFFixtures.mixedSizesPDF() }
        let b = try source("source-b") { try PDFFixtures.multiAnnotationPDF() }
        let c = try source("source-c") { try Self.multiPageSource(pages: 12, name: "b11-twelve") }

        // Merge: alle Seiten von a, dann b.
        let mergePlan = try Self.items(for: a) + Self.items(for: b)
        // Extract: jede zweite Seite von c, rückwärts, um 90° gedreht.
        var extractPlan: [PageItem] = []
        for item in try Self.items(for: c).reversed() where item.sourcePageIndex % 2 == 0 {
            var rotated = item
            rotated.rotation = 90
            extractPlan.append(rotated)
        }

        var report: [String] = []
        for (label, plan) in [("merge", mergePlan), ("extract", extractPlan)] {
            // Fester Dateiname, damit nur die Uhrzeit ins /ID eingeht.
            let out = ws.appendingPathComponent("\(label)-output.pdf")
            var callbacks = 0
            try await PageAssemblyService.assemble(pages: plan, to: out) { _ in callbacks += 1 }
            #expect(callbacks == plan.count, "\(label): \(callbacks) Fortschrittsmeldungen für \(plan.count) Seiten")
            let doc = try #require(PDFDocument(url: out))
            #expect(doc.pageCount == plan.count)

            let (hash, ids) = try Self.normalizedSHA256(of: out)
            #expect(ids >= 1, "\(label): kein /ID-Trailer gefunden – Normalisierung greift nicht")
            let raw = try Self.sha256(Data(contentsOf: out))
            let size = try Data(contentsOf: out).count
            report.append("\(label) bytes=\(size) sha256(raw)=\(raw) sha256(ohne /ID)=\(hash)")
            print("B11-IDENTITY[\(tag)] \(report.last!)")

            if let keepDir {
                let kept = keepDir.appendingPathComponent("\(label)-\(tag).pdf")
                try? FileManager.default.removeItem(at: kept)
                try FileManager.default.copyItem(at: out, to: kept)
            }
        }

        if let keepDir {
            try report.joined(separator: "\n").appending("\n")
                .write(to: keepDir.appendingPathComponent("hashes-\(tag).txt"),
                       atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Bridge-Ebene: Abbruch zwischen den Seiten (1, 2, 3)

    /// Abbruch nach der fünften Seite eines 180-Seiten-Plans: Die Bridge
    /// darf danach KEINE weitere Seite mehr melden (1), keine Datei und keine
    /// `.pdfcore-tmp` hinterlassen (2), und der nächste Lauf mit demselben
    /// Plan muss vollständig und mit demselben Inhalt gelingen (3).
    @Test(.hangGuard) func cancelBetweenPagesStopsPromptlyAndLeavesNothing() async throws {
        let ws = try Self.workspace("between-pages")
        defer { try? FileManager.default.removeItem(at: ws) }
        let source = try Self.multiPageSource(pages: 60, name: "b11-sixty")
        let plan = try Self.items(for: source, repeatPages: 3).assemblyPlan
        #expect(plan.pages.count == 180)

        let out = ws.appendingPathComponent("cancelled.pdf")
        let tmp = ws.appendingPathComponent("cancelled.pdf.pdfcore-tmp")
        var reported: [Int] = []
        var polls = 0
        var thrown: Error?
        do {
            try PDFCoreAssembler.write(
                plan: plan, to: out,
                onPage: { done, _ in reported.append(done) },
                shouldContinue: { polls += 1; return reported.count < 5 })
        } catch { thrown = error }

        #expect(thrown is CancellationError, "erwartet CancellationError, bekam \(String(describing: thrown))")
        #expect(reported == [1, 2, 3, 4, 5], "Bridge hat nach dem Abbruch weitergemacht: \(reported)")
        #expect(polls >= 5, "Abbruch-Abfrage wurde nicht pro Seite gestellt (\(polls) Abfragen)")
        #expect(!FileManager.default.fileExists(atPath: out.path), "halbe Datei unter dem Zielpfad")
        #expect(!FileManager.default.fileExists(atPath: tmp.path), "Temp-Datei liegt noch da")
        #expect(Self.leftovers(ws).isEmpty, "Reste im Zielordner: \(Self.leftovers(ws))")

        // (3) Der nächste Lauf im selben Prozess – gleicher Plan, ohne Abbruch.
        let next = ws.appendingPathComponent("next.pdf")
        var nextReported = 0
        try PDFCoreAssembler.write(plan: plan, to: next,
                                   onPage: { _, _ in nextReported += 1 },
                                   shouldContinue: { true })
        #expect(nextReported == 180)
        let doc = try #require(PDFDocument(url: next))
        #expect(doc.pageCount == 180)
        // Letzte Ausgabeseite = Quellseite 60 (Bildseite, deshalb über die
        // MediaBox statt über Text).
        let lastOut = try #require(doc.page(at: 179)).bounds(for: .mediaBox)
        let lastSrc = try #require(PDFDocument(url: source)?.page(at: 59)).bounds(for: .mediaBox)
        #expect(lastOut == lastSrc)

        // Und ein Lauf OHNE Abbruch-Callback (Standardpfad) liefert dieselben
        // Bytes (ohne /ID) – auf denselben Pfad geschrieben, Hash vorher gesichert.
        let (h1, _) = try Self.normalizedSHA256(of: next)
        try PDFCoreAssembler.write(plan: plan, to: next, onPage: nil, shouldContinue: nil)
        let (h2, _) = try Self.normalizedSHA256(of: next)
        #expect(h1 == h2, "Abbruch-Pfad und Standardpfad schreiben unterschiedliche Dateien")
    }

    // MARK: - Bridge-Ebene: Abbruch in der Schreibphase (6, 2, 3)

    /// Die Seitenschleife läuft durch (alle 180 Seiten gemeldet), erst beim
    /// Schreiben verneint der Aufrufer. Ohne die Prüfung in der
    /// Writer-Pipeline käme hier eine fertige Datei heraus.
    @Test(.hangGuard) func cancelDuringWritePhaseLeavesNothing() async throws {
        let ws = try Self.workspace("write-phase")
        defer { try? FileManager.default.removeItem(at: ws) }
        let source = try Self.multiPageSource(pages: 60, name: "b11-sixty")
        let plan = try Self.items(for: source, repeatPages: 3).assemblyPlan

        let out = ws.appendingPathComponent("cancelled.pdf")
        var reported = 0
        var pollsAfterLoop = 0
        var thrown: Error?
        do {
            try PDFCoreAssembler.write(
                plan: plan, to: out,
                onPage: { done, _ in reported = done },
                shouldContinue: {
                    guard reported >= plan.pages.count else { return true }
                    // Erste Abfrage nach der Schleife (vor dem Öffnen der
                    // Temp-Datei) passieren lassen – der Abbruch soll aus der
                    // Writer-Pipeline kommen, nachdem schon Bytes geschrieben wurden.
                    pollsAfterLoop += 1
                    return pollsAfterLoop < 2
                })
        } catch { thrown = error }

        #expect(thrown is CancellationError)
        #expect(reported == 180, "Schleife wurde vorzeitig verlassen – Test prüft die Schreibphase nicht")
        #expect(pollsAfterLoop >= 2, "Writer-Pipeline hat nie nach dem Abbruch gefragt (\(pollsAfterLoop) Abfragen)")
        #expect(Self.leftovers(ws).isEmpty, "Reste im Zielordner: \(Self.leftovers(ws))")

        // (3) Danach ein kompletter Lauf.
        let next = ws.appendingPathComponent("next.pdf")
        try PDFCoreAssembler.write(plan: plan, to: next, onPage: nil, shouldContinue: { true })
        #expect(PDFDocument(url: next)?.pageCount == 180)
    }

    /// Abbruch vor der ERSTEN Seite: nichts angefasst, kein Fortschritt gemeldet.
    @Test(.hangGuard) func cancelBeforeFirstPageTouchesNothing() async throws {
        let ws = try Self.workspace("before-first")
        defer { try? FileManager.default.removeItem(at: ws) }
        let source = try Self.multiPageSource(pages: 3, name: "b11-three")
        let plan = try Self.items(for: source).assemblyPlan
        let out = ws.appendingPathComponent("never.pdf")
        var reported = 0
        var thrown: Error?
        do {
            try PDFCoreAssembler.write(plan: plan, to: out,
                                       onPage: { _, _ in reported += 1 },
                                       shouldContinue: { false })
        } catch { thrown = error }
        #expect(thrown is CancellationError)
        #expect(reported == 0)
        #expect(Self.leftovers(ws).isEmpty, "Reste im Zielordner: \(Self.leftovers(ws))")
    }

    // MARK: - Service-Ebene: Task-Abbruch wird durchgereicht

    /// `PageAssemblyService.assemble` reicht `Task.isCancelled` an die Bridge
    /// durch: Der Task wird aus dem Fortschritts-Rückruf heraus abgebrochen,
    /// `assemble` wirft `CancellationError`, es liegt keine Datei unter dem
    /// Zielpfad, und der nächste Service-Aufruf (mit Nachsorge-Schritten,
    /// Producer-Stempel, PDFCoreDocument-Prozess-Sperre) gelingt.
    @Test(.hangGuard) func serviceForwardsTaskCancellationToTheBridge() async throws {
        let ws = try Self.workspace("service")
        defer { try? FileManager.default.removeItem(at: ws) }
        let source = try Self.multiPageSource(pages: 60, name: "b11-sixty")
        let pages = try Self.items(for: source, repeatPages: 5)   // 300 Seiten
        let out = ws.appendingPathComponent("service-cancelled.pdf")

        final class Handle: @unchecked Sendable { var task: Task<Void, Error>? }
        let handle = Handle()
        let fractions = Counter()
        handle.task = Task {
            try await PageAssemblyService.assemble(pages: pages, to: out) { fraction in
                fractions.append(fraction)
                if fraction >= 0.05 { handle.task?.cancel() }
            }
        }
        var thrown: Error?
        do { try await handle.task?.value } catch { thrown = error }

        #expect(thrown is CancellationError, "erwartet CancellationError, bekam \(String(describing: thrown))")
        let seen = fractions.values
        #expect(!seen.isEmpty)
        #expect((seen.max() ?? 1) < 0.5, "Bridge hat nach dem Abbruch weitergearbeitet: max \(seen.max() ?? -1)")
        #expect(Self.leftovers(ws).isEmpty, "Reste im Zielordner: \(Self.leftovers(ws))")

        // (3) Nächster Lauf über den Service – inklusive Prozess-Sperre.
        let next = ws.appendingPathComponent("service-next.pdf")
        try await PageAssemblyService.assemble(pages: pages, to: next) { _ in }
        #expect(PDFDocument(url: next)?.pageCount == 300)
        let core = try PDFCoreDocument(path: next.path)
        #expect(core.pageCount == 300)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ v: Double) { lock.lock(); storage.append(v); lock.unlock() }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    // MARK: - App-Ebene: MergeViewModel (Merge, Extract) und Abbrechen-Knopf (5)

    /// Wie in der App: Seiten geladen, „PDF erstellen", dann „Abbrechen",
    /// sobald der erste Fortschritt sichtbar ist. Danach: kein Ergebnis,
    /// keine Fehlermeldung, `isProcessing` aus – und KEIN Fortschritts-
    /// Rückruf, der den beendeten Zustand nachträglich übermalt (5).
    @MainActor
    @Test(.hangGuard) func mergeViewModelCancelStopsRunWithoutLateProgressUpdates() async throws {
        let source = try Self.multiPageSource(pages: 60, name: "b11-sixty")
        let vm = MergeViewModel()
        vm.attachUndoManager(UndoManager())
        let doc = try #require(PDFDocument(url: source))
        let sourceDoc = SourceDocument(url: source, pageCount: doc.pageCount)
        vm.project.documents = [sourceDoc]
        var pages: [PageItem] = []
        for _ in 0..<20 { for i in 0..<doc.pageCount { pages.append(PageItem(source: sourceDoc, pageIndex: i)) } }
        vm.project.pages = pages   // 1200 Seiten

        var cancelledAt: Double?
        var progressAfterStop: [Double] = []
        var stopped = false
        let sink = vm.$progress.sink { value in
            if stopped { progressAfterStop.append(value); return }
            if value > 0, cancelledAt == nil {
                cancelledAt = value
                MainActor.assumeIsolated { vm.cancelProcessing() }
            }
        }
        defer { sink.cancel() }

        vm.mergeAndPrepare()
        #expect(vm.isProcessing)
        var waited = 0
        while vm.isProcessing, waited < 20_000 {
            try await Task.sleep(for: .milliseconds(5)); waited += 5
        }
        stopped = true
        let progressAtStop = vm.progress
        let labelAtStop = vm.processingLabel

        #expect(!vm.isProcessing, "Lauf nicht beendet (Abbruch bei \(String(describing: cancelledAt)))")
        #expect(cancelledAt != nil, "Abbrechen kam nie zum Zug – Lauf war vorher fertig")
        #expect(vm.outcome == nil, "Abbruch ignoriert: Ergebnis liegt vor")
        #expect(vm.errorMessage == nil, "Abbruch wird als Fehler gezeigt: \(vm.errorMessage ?? "")")
        #expect(vm.progress < 1)

        // (5) Verspätete Fortschrittsmeldungen dürfen den Zustand nicht mehr ändern.
        try await Task.sleep(for: .milliseconds(300))
        #expect(progressAfterStop.isEmpty, "Fortschritt nach Abbruch verändert: \(progressAfterStop)")
        #expect(vm.progress == progressAtStop)
        #expect(vm.processingLabel == labelAtStop)
        #expect(!vm.isProcessing)
        #expect(vm.outcome == nil)

        // (3) Extract im selben ViewModel danach – muss sauber durchlaufen.
        vm.selectedPageIDs = Set(pages.prefix(7).map(\.id))
        vm.extractSelectedPages()
        waited = 0
        while vm.isProcessing, waited < 60_000 {
            try await Task.sleep(for: .milliseconds(10)); waited += 10
        }
        #expect(vm.errorMessage == nil, "Extract nach Abbruch scheitert: \(vm.errorMessage ?? "")")
        let outcome = try #require(vm.outcome)
        #expect(outcome.pageCount == 7)
        #expect(PDFDocument(url: outcome.url)?.pageCount == 7)
        try? FileManager.default.removeItem(at: outcome.url)
    }

    // MARK: - App-Ebene: Teilen (Split) bricht innerhalb eines Teils ab

    @MainActor
    @Test(.hangGuard) func splitCancelLeavesTargetFolderEmpty() async throws {
        let folder = try Self.workspace("split")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.multiPageSource(pages: 60, name: "b11-sixty")
        let vm = MergeViewModel()
        let doc = try #require(PDFDocument(url: source))
        let sourceDoc = SourceDocument(url: source, pageCount: doc.pageCount)
        var pages: [PageItem] = []
        for _ in 0..<20 { for i in 0..<doc.pageCount { pages.append(PageItem(source: sourceDoc, pageIndex: i)) } }
        let chunks = [Array(pages[0..<600]), Array(pages[600..<1200])]

        final class Handle: @unchecked Sendable { var task: Task<[URL], Error>? }
        let handle = Handle()
        let sink = vm.$progress.sink { value in
            if value > 0 { handle.task?.cancel() }
        }
        defer { sink.cancel() }
        handle.task = Task { @MainActor in
            try await vm.writeChunks(chunks, to: folder, baseName: "b11")
        }
        var thrown: Error?
        do { _ = try await handle.task?.value } catch { thrown = error }
        #expect(thrown is CancellationError, "erwartet CancellationError, bekam \(String(describing: thrown))")
        #expect(Self.leftovers(folder).isEmpty, "Zielordner nicht leer: \(Self.leftovers(folder))")
        #expect(!vm.isProcessing)

        // (3) Danach ein kompletter Split im selben ViewModel.
        let small = [Array(pages[0..<3]), Array(pages[3..<6])]
        let written = try await vm.writeChunks(small, to: folder, baseName: "b11")
        #expect(written.count == 2)
        #expect(PDFDocument(url: written[0])?.pageCount == 3)
    }

    // MARK: - App-Ebene: Bilder → PDF bricht beim Zusammensetzen ab

    @Test(.hangGuard) func imagesToPDFCancelDuringAssemblyLeavesNoResult() async throws {
        let ws = try Self.workspace("images")
        defer { try? FileManager.default.removeItem(at: ws) }
        // 40 kleine PNGs.
        var images: [URL] = []
        for i in 0..<40 {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(calibratedHue: CGFloat(i) / 40, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 64, height: 64).fill()
            NSGraphicsContext.restoreGraphicsState()
            let url = ws.appendingPathComponent("img-\(i).png")
            try #require(rep.representation(using: .png, properties: [:])).write(to: url)
            images.append(url)
        }

        let scratchBefore = Set((try? FileManager.default.contentsOfDirectory(
            atPath: SessionScratch.directory.path)) ?? [])

        final class Handle: @unchecked Sendable { var task: Task<URL, Error>? }
        let handle = Handle()
        let fractions = Counter()
        handle.task = Task {
            try await ConversionViewModel.combinedTemporaryPDF(from: images) { fraction in
                fractions.append(fraction)
                // Ab 0.7 läuft das Zusammensetzen (Bridge); dort abbrechen.
                if fraction > 0.7 { handle.task?.cancel() }
            }
        }
        var thrown: Error?
        do { _ = try await handle.task?.value } catch { thrown = error }
        #expect(thrown is CancellationError, "erwartet CancellationError, bekam \(String(describing: thrown))")
        #expect((fractions.values.max() ?? 1) < 1, "Fortschritt lief bis zum Ende durch")

        let scratchAfter = Set((try? FileManager.default.contentsOfDirectory(
            atPath: SessionScratch.directory.path)) ?? [])
        #expect(scratchAfter.subtracting(scratchBefore).isEmpty,
                "Abbruch hat ein Ergebnis im Sitzungsordner hinterlassen: \(scratchAfter.subtracting(scratchBefore))")

        // (3) Danach ohne Abbruch.
        let result = try await ConversionViewModel.combinedTemporaryPDF(from: Array(images.prefix(5))) { _ in }
        defer { try? FileManager.default.removeItem(at: result) }
        #expect(PDFDocument(url: result)?.pageCount == 5)
    }
}
