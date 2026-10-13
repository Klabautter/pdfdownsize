import Foundation
import PDFKit

/// Monster Epic Phase 8 – neutrales Assembly-Modell.
/// Bewusst frei von PDFKit-/qpdf-/AppKit-Typen: jede Engine (PDFKit heute,
/// libqpdf später) kann denselben Plan ausführen.
struct PageAssemblyItem: Equatable, Codable {
    let sourceURL: URL
    let sourcePageIndex: Int
    /// Zusätzliche Rotation in 90°-Schritten (0/90/180/270), normalisiert.
    let rotation: Int

    init(sourceURL: URL, sourcePageIndex: Int, rotation: Int = 0) {
        self.sourceURL = sourceURL
        self.sourcePageIndex = sourcePageIndex
        self.rotation = RotationNormalizer.normalized(rotation)
    }
}

struct PageAssemblyPlan: Equatable, Codable {
    var pages: [PageAssemblyItem]

    init(pages: [PageAssemblyItem]) {
        self.pages = pages
    }

    static let empty = PageAssemblyPlan(pages: [])
}

// MARK: - Brücke zum bestehenden Organizer-Modell

extension PageItem {
    /// Neutraler Plan-Eintrag für diese Organizer-Seite.
    var assemblyItem: PageAssemblyItem {
        PageAssemblyItem(sourceURL: sourceURL,
                         sourcePageIndex: sourcePageIndex,
                         rotation: rotation)
    }
}

extension Sequence where Element == PageItem {
    var assemblyPlan: PageAssemblyPlan {
        PageAssemblyPlan(pages: map(\.assemblyItem))
    }
}

// MARK: - Epic Phase 12 – Outline Preservation (engine-agnostisch)

struct TopLevelOutlineEntry: Equatable {
    let title: String
    let sourcePageIndex: Int
}

extension URL {
    /// Top-Level-Outline-Einträge einer Quelldatei (Titel + Quellseitenindex).
    func topLevelOutlineEntries() -> [TopLevelOutlineEntry] {
        guard let doc = PDFDocument(url: self), let root = doc.outlineRoot else {
            return []
        }
        var out: [TopLevelOutlineEntry] = []
        for i in 0..<root.numberOfChildren {
            if let child = root.child(at: i) {
                let pageIndex: Int
                if let dest = child.destination, let target = dest.page {
                    pageIndex = doc.index(for: target)
                } else {
                    pageIndex = -1
                }
                out.append(TopLevelOutlineEntry(title: child.label ?? "",
                                                sourcePageIndex: pageIndex))
            }
        }
        return out
    }
}
