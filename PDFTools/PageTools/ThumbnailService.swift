import Foundation
import PDFKit
import AppKit

actor PDFDocumentPool {
    private var cache: [URL: PDFDocument] = [:]
    private var order: [URL] = []
    private let limit = 6

    func document(for url: URL) -> PDFDocument? {
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

    func evictAll() {
        cache.removeAll()
        order.removeAll()
    }
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

    private var cache: [ThumbnailKey: NSImage] = [:]
    private let lock = NSLock()

    func cached(key: ThumbnailKey) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    func store(_ image: NSImage, key: ThumbnailKey) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = image
    }

    /// Liefert das Thumbnail inkl. absoluter Rotation (Quell-Rotation + Nutzer-Drehung).
    func thumbnail(sourceID: UUID, url: URL, pageIndex: Int,
                   additionalRotation: Int, pixelHeight: CGFloat = 320) async -> NSImage? {

        guard let doc = await pool.document(for: url),
              let page = doc.page(at: pageIndex) else { return nil }

        let absolute = RotationNormalizer.normalized(page.rotation + additionalRotation)
        let key = ThumbnailKey(sourceID: sourceID, pageIndex: pageIndex,
                               absoluteRotation: absolute, pixelHeight: pixelHeight)

        if let hit = cached(key: key) { return hit }

        let pageCopy = page.copy() as! PDFPage
        pageCopy.rotation = absolute

        // CropBox statt MediaBox: Das Vorschaubild zeigt, was der Betrachter
        // zeigt (Befund B10, Review 2026-10-09).
        let bounds = pageCopy.bounds(for: .cropBox)
        let scale = pixelHeight / max(bounds.height, 1)
        let pxSize = CGSize(width: max(40, Int(bounds.width * scale)),
                            height: max(40, Int(pixelHeight)))

        let thumb = pageCopy.thumbnail(of: pxSize, for: .cropBox)
        store(thumb, key: key)
        return thumb
    }
}
