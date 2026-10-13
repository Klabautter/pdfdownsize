import Foundation

struct SourceDocument: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let fileName: String
    let fileSize: Int64
    let pageCount: Int

    /// `displayFileName`: für konvertierte Bilder – die Quelle ist eine
    /// Temp-PDF, angezeigt werden soll trotzdem der Bildname.
    init(url: URL, pageCount: Int, displayFileName: String? = nil) {
        self.id = UUID()
        self.url = url
        self.fileName = displayFileName ?? url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.fileSize = Int64((attrs?[.size] as? Int) ?? 0)
        self.pageCount = pageCount
    }
}

struct PageItem: Identifiable, Hashable {
    let id: UUID
    let sourceDocumentID: UUID
    let sourceURL: URL
    let sourcePageIndex: Int
    var rotation: Int = 0

    init(source: SourceDocument, pageIndex: Int) {
        self.id = UUID()
        self.sourceDocumentID = source.id
        self.sourceURL = source.url
        self.sourcePageIndex = pageIndex
    }
}

struct PageProject: Equatable {
    var documents: [SourceDocument] = []
    var pages: [PageItem] = []

    var totalPages: Int { pages.count }

    func document(for id: UUID) -> SourceDocument? {
        documents.first { $0.id == id }
    }

    var totalSourceBytes: Int64 {
        documents.reduce(0) { $0 + $1.fileSize }
    }
}

enum RotationNormalizer {
    static func normalized(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    static func rotatedSize(width: CGFloat, height: CGFloat, rotation: Int) -> CGSize {
        switch normalized(rotation) {
        case 90, 270: return CGSize(width: height, height: width)
        default: return CGSize(width: width, height: height)
        }
    }
}

/// Split-Logik (Review §65, Feature 2): zerlegt die aktuelle Seitenfolge in Teile.
/// Rein funktional – keine UI-, kein Datei-Zugriff.
enum PageSplitter {

    enum Mode: Hashable {
        /// Jede Seite wird ein eigenes PDF.
        case perPage
        /// Alle `n` Seiten ein PDF (letzter Teil darf kleiner sein).
        case everyN(Int)
        /// Vor jeder ausgewählten Seite beginnt ein neuer Teil.
        case atSelection
    }

    static func chunks(from pages: [PageItem],
                       mode: Mode,
                       selection: Set<UUID> = []) -> [[PageItem]] {
        switch mode {
        case .perPage:
            return pages.map { [$0] }

        case .everyN(let n):
            guard n > 0 else { return [] }
            return stride(from: 0, to: pages.count, by: n).map {
                Array(pages[$0..<min($0 + n, pages.count)])
            }

        case .atSelection:
            var result: [[PageItem]] = []
            var current: [PageItem] = []
            var previousSelected = false
            for page in pages {
                let isSelected = selection.contains(page.id)
                // Neue Trennstelle nur am Anfang eines zusammenhängend
                // selektierten Blocks – der Block selbst bleibt ein Teil.
                if isSelected, !previousSelected, !current.isEmpty {
                    result.append(current)
                    current = []
                }
                current.append(page)
                previousSelected = isSelected
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
    }

    /// „Bericht_Teil_03.pdf“ – Nullen passend zur Gesamtanzahl.
    static func fileName(base: String, index: Int, total: Int) -> String {
        let width = max(1, String(max(1, total)).count)
        return "\(base)_\(String(localized: "Teil", comment: "Dateiname"))_\(String(format: "%0\(width)d", index)).pdf"
    }
}
