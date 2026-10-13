import Foundation
import AppKit
import PDFKit

/// PDF → Images (Review §65, Feature 3): rendert Seiten mit Rotation als
/// PNG oder JPEG. Rein funktionale Engine – Progress/Cancel via Task.
enum PageImageExporter {

    enum Format: String, Hashable {
        case png
        case jpeg
    }

    struct Options {
        let format: Format
        /// Rasterung in Punkten pro Zoll; 72 = 1×.
        let dpi: Int
        /// Nur für JPEG (0…1).
        let jpegQuality: CGFloat

        init(format: Format, dpi: Int, jpegQuality: CGFloat = 0.85) {
            self.format = format
            self.dpi = max(36, min(600, dpi))
            self.jpegQuality = min(1, max(0.1, jpegQuality))
        }
    }

    /// Geteilte UI-Einstellungen für PDF → Bilder.
    /// Single Source of Truth für ConvertView UND ImageExportSheet (Organize),
    /// damit Format/DPI/Qualität nicht auseinanderdriften.
    /// Zuständigkeit: Convert = schneller Einzel-Export, Organize = Projekt-Export
    /// mit Auswahl – beide mappen hier auf dieselben `Options`.
    struct Settings: Hashable {
        var usePNG = true
        var dpi = 150
        var quality: Double = 0.85

        static let supportedDPIs = [72, 150, 300]
        static let qualityRange: ClosedRange<Double> = 0.4...1

        var format: Format { usePNG ? .png : .jpeg }
        var options: Options {
            Options(format: format, dpi: dpi, jpegQuality: CGFloat(quality))
        }
    }

    static func fileExtension(for format: Format) -> String {
        format == .png ? "png" : "jpg"
    }

    static func pixelSize(pageBounds: CGRect, dpi: Int) -> CGSize {
        let scale = CGFloat(dpi) / 72.0
        return CGSize(width: (pageBounds.width * scale).rounded(),
                      height: (pageBounds.height * scale).rounded())
    }

    /// Exportiert alle Seiten in `folder`. Bei Abbruch werden bereits
    /// geschriebene Dateien entfernt und der Fehler weitergereicht.
    /// Legt im gewählten Ordner einen Unterordner mit dem Dokumentnamen an
    /// („Bericht", bei Kollision „Bericht 2", „Bericht 3" …) und liefert ihn.
    /// Die Bilder heißen darin nur noch 01.png, 02.png … (Sichtabnahme
    /// 2026-10-12: „so wie die PDF heißt kriegt man einen Ordner").
    nonisolated static func makeExportFolder(in parent: URL, named name: String) throws -> URL {
        let fm = FileManager.default
        var stem = (name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty { stem = String(localized: "Seiten") }
        var candidate = parent.appendingPathComponent(stem, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(stem) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    @concurrent nonisolated static func export(pages: [PageItem],
                                   options: Options,
                                   to folder: URL,
                                   progress: @escaping (Double) -> Void) async throws -> [URL] {
        guard !pages.isEmpty else { return [] }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var written: [URL] = []
        let total = pages.count
        let ext = fileExtension(for: options.format)
        // Mindestens zweistellig („01.png"), damit die Namen auch bei wenigen
        // Seiten so aussehen wie zugesagt (Sichtabnahme 2026-10-12, L9).
        let width = max(2, String(total).count)
        let pad = { (i: Int) in String(format: "%0\(width)d", i) }

        // Lokaler Quell-Dokument-Pool (gleiche Logik wie im Assembler).
        var cache: [URL: PDFDocument] = [:]
        var lru: [URL] = []
        let cacheLimit = 4

        func document(for url: URL) throws -> PDFDocument {
            if let doc = cache[url] {
                lru.removeAll { $0 == url }
                lru.append(url)
                return doc
            }
            guard let doc = PDFDocument(url: url), !doc.isLocked else {
                throw MergeError.missingSource(url.lastPathComponent)
            }
            cache[url] = doc
            lru.append(url)
            if lru.count > cacheLimit {
                cache[lru.removeFirst()] = nil
            }
            return doc
        }

        do {
            for (i, item) in pages.enumerated() {
                if Task.isCancelled { throw CancellationError() }

                let doc = try document(for: item.sourceURL)
                guard let page = doc.page(at: item.sourcePageIndex) else {
                    throw MergeError.missingSource(item.sourceURL.lastPathComponent)
                }

                // Nutzer-Rotation temporär auf die gecachte Seite anwenden –
                // das Rendering folgt dann automatisch. Nach dem Rendern
                // ZURÜCKSETZEN: Das Dokument lebt im Pool, dieselbe Seite kann
                // im selben Export noch einmal kommen (gleiche Datei zweimal
                // importiert). Ohne Rücksetzen addierte sich die Rotation
                // beim zweiten Treffer (Befund A1, Review 2026-10-09).
                let baseRotation = RotationNormalizer.normalized(page.rotation)
                page.rotation = RotationNormalizer.normalized(baseRotation + item.rotation)
                defer { page.rotation = baseRotation }

                // Achtung: bounds() spiegelt die Rotation nicht wider –
                // gedrehte Zielgröße daher explizit berechnen. Gerendert
                // wird die CropBox – das, was jeder Betrachter zeigt; die
                // MediaBox kann größer sein (Befund B10, Review 2026-10-09).
                let rawBounds = page.bounds(for: .cropBox)
                let rotatedSize = RotationNormalizer.rotatedSize(width: rawBounds.width,
                                                                 height: rawBounds.height,
                                                                 rotation: page.rotation)
                let pixels = pixelSize(pageBounds: CGRect(origin: .zero, size: rotatedSize),
                                       dpi: options.dpi)
                let nsImage = page.thumbnail(of: pixels, for: .cropBox)

                let data = try encode(nsImage,
                                      pixels: pixels,
                                      options: options)

                // Nur die Nummer: Der Ordner trägt den Dokumentnamen
                // (Sichtabnahme 2026-10-12), z. B. „Bericht/01.png".
                let name = "\(pad(i + 1)).\(ext)"
                let staging = folder.appendingPathComponent(".pdftools-image-\(UUID().uuidString).tmp")
                defer { try? fm.removeItem(at: staging) }
                try data.write(to: staging, options: .atomic)
                try Task.checkCancellation()
                var dest = folder.appendingPathComponent(name)
                var bump = 1
                while true {
                    if !fm.fileExists(atPath: dest.path) {
                        do {
                            // Same-folder move publishes a complete image and refuses
                            // to replace an existing destination, including a late collision.
                            try fm.moveItem(at: staging, to: dest)
                            break
                        } catch let error as NSError {
                            guard error.domain == NSCocoaErrorDomain,
                                  error.code == NSFileWriteFileExistsError else { throw error }
                        }
                    }
                    dest = folder.appendingPathComponent("\(pad(i + 1))_\(bump).\(ext)")
                    bump += 1
                    try Task.checkCancellation()
                }
                written.append(dest)

                progress(Double(i + 1) / Double(total))
            }
            try Task.checkCancellation()
            return written
        } catch {
            for url in written { try? fm.removeItem(at: url) }
            throw error
        }
    }

    // MARK: - Encoding

    private nonisolated static func encode(_ image: NSImage,
                                           pixels: CGSize,
                                           options: Options) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(max(1, pixels.width)),
            pixelsHigh: Int(max(1, pixels.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0) else {
            throw MergeError.assemblyFailed
        }
        rep.size = NSSize(width: pixels.width, height: pixels.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // JPEG kennt keine Transparenz → weißer Grund.
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: rep.size)).fill()
        image.draw(in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()

        // Auflösung in die Datei schreiben (pHYs/JFIF): Punktgröße =
        // Pixel × 72 / DPI. Vorher stand 72 dpi in jeder Datei, und „300 dpi ·
        // Druck" bot Vorschau/Druckdialog 4× zu groß an (Befund B9).
        // Erst NACH dem Zeichnen setzen – das Zeichnen lief in Pixeleinheiten.
        rep.size = NSSize(width: pixels.width * 72 / CGFloat(options.dpi),
                          height: pixels.height * 72 / CGFloat(options.dpi))
        let type: NSBitmapImageRep.FileType = options.format == .png ? .png : .jpeg
        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if options.format == .jpeg {
            properties[.compressionFactor] = options.jpegQuality
        }
        guard let data = rep.representation(using: type, properties: properties) else {
            throw MergeError.assemblyFailed
        }
        return data
    }
}
