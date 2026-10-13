import Foundation
import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// PageItem zu einer UUID – die Selection-API arbeitet mit Items, Tests mit IDs.
@MainActor
func p(_ vm: MergeViewModel, _ id: UUID) -> PageItem {
    vm.project.pages.first { $0.id == id }!
}

/// Prozessweiter Mutex für Tests, die Prozess-ENV mutieren (Trace-Regal).
/// `PDFTOOLS_COMPRESSION_TRACE` ist prozessglobal; Swift Testing führt Tests
/// koncurrent aus – ohne Sperre kann ein parallel laufender Test den Flag
/// wegunsetzen, während ein anderer gerade komprimiert (Flake).
enum EnvironmentMutex {
    static let lock = NSLock()

    static func with<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// PageItem an Position im aktuellen Projekt.
@MainActor
func page(in vm: MergeViewModel, at index: Int) -> PageItem {
    vm.project.pages[index]
}

/// Hilfsfunktionen für die Organizer-Interaktionstests (Review §55).
enum TestFactory {

    /// Erzeugt eine minimale, gültige PDF mit `pageCount` weißen Seiten
    /// definierter Punktgröße im Temp-Ordner.
    @discardableResult
    static func makeTempPDF(name: String = UUID().uuidString,
                            pageCount: Int,
                            pageSize: CGSize = CGSize(width: 612, height: 792)) throws -> URL {
        let doc = PDFDocument()
        for i in 0..<max(1, pageCount) {
            doc.insert(Self.makeBlankPage(size: pageSize), at: i)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).pdf")
        try? FileManager.default.removeItem(at: url)
        guard doc.write(to: url) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// Weiße Einzelseite mit exakter Punktgröße (image-backed → deterministische Bounds).
    static func makeBlankPage(size: CGSize) -> PDFPage {
        let rep = makeRep(size: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(cgImage: rep.cgImage!, size: size)
        return PDFPage(image: image)!
    }

    /// Farbige PNG-Datei für Bild-Import-Tests.
    /// `pixels != size` erzeugt DPI-Metadaten (pHYs) – Regressionstest für P0.3.
    @discardableResult
    static func makeTempPNG(size: CGSize = CGSize(width: 400, height: 300),
                            pixels: CGSize? = nil,
                            name: String = UUID().uuidString) throws -> URL {
        let pixelSize = pixels ?? size
        let rep = makeRep(size: pixelSize)
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        try data.write(to: url)
        return url
    }

    private static func makeRep(size: CGSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: max(1, Int(size.width)),
                                   pixelsHigh: max(1, Int(size.height)),
                                   bitsPerSample: 8,
                                   samplesPerPixel: 4,
                                   hasAlpha: true,
                                   isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0,
                                   bitsPerPixel: 0)!
        rep.size = size
        return rep
    }

    /// VM mit synthetischem Projekt (keine echten Dateien nötig) + IDs pro Dokument.
    /// Der UndoManager wird zusätzlich stark zurückgegeben – die VM hält ihn nur weak,
    /// ohne starke Referenz würde er sofort freigegeben und ⌘Z wäre im Test tot.
    @MainActor
    static func makeVM(docPageCounts: [Int]) -> (vm: MergeViewModel,
                                                 ids: [[UUID]],
                                                 undo: UndoManager) {
        let vm = MergeViewModel()
        let undo = UndoManager()
        vm.attachUndoManager(undo)

        var documents: [SourceDocument] = []
        var pages: [PageItem] = []
        var ids: [[UUID]] = []

        for (d, count) in docPageCounts.enumerated() {
            let doc = SourceDocument(url: URL(fileURLWithPath: "/tmp/pdftools-src-\(d).pdf"),
                                     pageCount: count)
            documents.append(doc)
            var docIDs: [UUID] = []
            for p in 0..<count {
                let item = PageItem(source: doc, pageIndex: p)
                docIDs.append(item.id)
                pages.append(item)
            }
            ids.append(docIDs)
        }
        vm.project.documents = documents
        vm.project.pages = pages
        return (vm, ids, undo)
    }

    /// Aktuelle Seitenreihenfolge als lesbare Labels „doc-a.pdf:2“.
    @MainActor
    static func order(_ vm: MergeViewModel) -> [String] {
        let names = Dictionary(uniqueKeysWithValues:
            vm.project.documents.map { ($0.id, $0.fileName) })
        return vm.project.pages.map {
            "\(names[$0.sourceDocumentID] ?? "?"):\($0.sourcePageIndex)"
        }
    }

    /// Rotations-Winkel der Seiten in Reihenfolge.
    @MainActor
    static func rotations(_ vm: MergeViewModel) -> [Int] {
        vm.project.pages.map(\.rotation)
    }

    /// Wartet (Main-actor-freundlich) bis eine Bedingung erfüllt ist oder Timeout.
    @MainActor
    static func waitFor(_ condition: () -> Bool,
                        timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timeout beim Warten auf Bedingung")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
