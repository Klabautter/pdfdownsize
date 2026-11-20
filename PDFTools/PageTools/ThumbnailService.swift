import Foundation
import PDFKit
import AppKit

actor PDFDocumentPool {
    private var cache: [URL: PDFDocument] = [:]
    private var order: [URL] = []
    private let limit = 6

    private func document(for url: URL) -> PDFDocument? {
        if let doc = cache[url] { return doc }
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        cache[url] = doc
        order.append(url)
        if order.count > limit {
            let evict = order.removeFirst()
            cache[evict] = nil
        }
        return doc
    }

    /// G6: Eine eigene Kopie der Seite, im Actor erzeugt. Vorher gab der Pool
    /// das geteilte `PDFDocument` heraus, und parallele Vorschau-Aufrufe
    /// griffen gleichzeitig darauf zu – PDFKit ist dafür nicht threadsicher.
    /// Die Kopie gehört danach allein dem Aufrufer.
    func detachedPage(for url: URL, pageIndex: Int) -> DetachedPage? {
        guard let page = document(for: url)?.page(at: pageIndex),
              let copy = page.copy() as? PDFPage else { return nil }
        return DetachedPage(page: copy, rotation: page.rotation)
    }

    /// Eigene Drehung der Seite – genug für den Cache-Schlüssel, ohne die
    /// Seite zu kopieren (N28).
    func rotation(for url: URL, pageIndex: Int) -> Int? {
        document(for: url)?.page(at: pageIndex)?.rotation
    }

    func evictAll() {
        cache.removeAll()
        order.removeAll()
    }
}

/// Eine Seitenkopie, die genau ein Aufrufer benutzt (siehe `detachedPage`).
struct DetachedPage: @unchecked Sendable {
    let page: PDFPage
    let rotation: Int
}

struct ThumbnailKey: Hashable {
    let sourceID: UUID
    let pageIndex: Int
    let absoluteRotation: Int
    let pixelHeight: CGFloat
}

final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()
    let pool = PDFDocumentPool()

    /// Masterplan C6: begrenzter Cache. Vorher wuchs ein Dictionary ohne
    /// Grenze – bei 1000 Seiten in drei Rotationen über Hunderte MB. NSCache
    /// ist threadsicher und gibt unter Speicherdruck selbst frei.
    static let cacheCostLimit = 200 << 20
    private let cache: NSCache<KeyBox, NSImage> = {
        let cache = NSCache<KeyBox, NSImage>()
        cache.totalCostLimit = ThumbnailService.cacheCostLimit
        return cache
    }()

    final class KeyBox: NSObject {
        let key: ThumbnailKey
        init(_ key: ThumbnailKey) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
    }

    func cached(key: ThumbnailKey) -> NSImage? {
        cache.object(forKey: KeyBox(key))
    }

    func store(_ image: NSImage, key: ThumbnailKey) {
        // Kosten = Breite × Höhe × 4 Byte.
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: KeyBox(key), cost: cost)
    }

    /// Liefert das Thumbnail inkl. absoluter Rotation (Quell-Rotation + Nutzer-Drehung).
    /// Masterplan C6: `@concurrent` – mit SWIFT_APPROACHABLE_CONCURRENCY lief
    /// das Rendern sonst auf dem Hauptthread des Aufrufers.
    @concurrent
    func thumbnail(sourceID: UUID, url: URL, pageIndex: Int,
                   additionalRotation: Int, pixelHeight: CGFloat = 320) async -> NSImage? {

        // N28: Erst den Cache fragen, dann die Seite kopieren – vorher kostete
        // jeder Treffer eine Seitenkopie im Actor.
        guard let rotation = await pool.rotation(for: url, pageIndex: pageIndex) else { return nil }
        let absolute = RotationNormalizer.normalized(rotation + additionalRotation)
        let key = ThumbnailKey(sourceID: sourceID, pageIndex: pageIndex,
                               absoluteRotation: absolute, pixelHeight: pixelHeight)

        if let hit = cached(key: key) { return hit }
        // Weggescrollt, während das Dokument geöffnet wurde: nicht rendern.
        if Task.isCancelled { return nil }
        guard let detached = await pool.detachedPage(for: url, pageIndex: pageIndex) else { return nil }

        let pageCopy = detached.page
        pageCopy.rotation = absolute

        // CropBox statt MediaBox: Das Vorschaubild zeigt, was der Betrachter
        // zeigt (Befund B10, Review 2026-10-09).
        let bounds = pageCopy.bounds(for: .cropBox)
        let scale = pixelHeight / max(bounds.height, 1)
        let pxSize = CGSize(width: max(40, PixelExtent.edge(Double(bounds.width), scale: Double(scale)) ?? 40),
                            height: max(40, Int(pixelHeight)))

        let thumb = pageCopy.thumbnail(of: pxSize, for: .cropBox)
        store(thumb, key: key)
        return thumb
    }
}
