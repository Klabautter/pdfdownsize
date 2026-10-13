import Foundation
import CoreGraphics

// MARK: - Masterplan §13.6/§13.8/§13.9 – MRC-Layer-Kodierung
//
// Layer-Formate (§13.6):
//
//   • Foreground-Maske: 1-bit, volle Rasterauflösung, lossless JBIG2
//     (Refinement im Shim hart aus) – verifiziert über den echten Dekodierer
//     (PDFKit-Render, Bitvergleich wie im Bilevel-Pfad). Fällt das Gate durch,
//     CCITT G4 (libtiff-Rückweg). Kein Lossy-JBIG2 (§13.11 hartkodiert).
//   • Background: RGB/Gray → auf backgroundDPI resampelt → mozjpeg.
//   • Photo-Regionen: Ausschnitte des ORIGINAL-Rasters, höhere DPI/Qualität
//     als der Hintergrund → mozjpeg.
//
// Die Ladder (§13.9) nutzt die dokumentierten MITTELWERT-Parameter:
//   conservative  BG 200 DPI / Q90    Photo 220 DPI / Q90
//   balanced      BG 135 DPI / Q85    Photo 200 DPI / Q87.5
//   small         BG 108 DPI / Q80    Photo 162 DPI / Q85
// (Textmasken bleiben in ALLEN Stufen lossless und auflösungstreu.)
enum MRCEncoder {

    // MARK: Ladder (§13.9)

    struct Rung {
        let name: String
        let backgroundDPI: Double
        let backgroundQuality: Double
        let photoDPI: Double
        let photoQuality: Double
    }

    /// Konservativste Stufe (höchste Qualität, §13.9).
    static let conservative = Rung(name: "conservative",
                                   backgroundDPI: 200, backgroundQuality: 0.90,
                                   photoDPI: 220, photoQuality: 0.90)
    /// Mittlere Stufe (§13.9 „balanced").
    static let balanced = Rung(name: "balanced",
                               backgroundDPI: 135, backgroundQuality: 0.85,
                               photoDPI: 200, photoQuality: 0.875)
    /// Kleinste Stufe (§13.9 „small").
    static let small = Rung(name: "small",
                            backgroundDPI: 108, backgroundQuality: 0.80,
                            photoDPI: 162, photoQuality: 0.85)

    /// Stufen je Preset – max. ZWEI Rendervergleiche je Seite (dokumentiertes
    /// Budget §13.10): konservativ zuerst (höchste Sicherheit), dann die
    /// preset-gemäße Stufe. Quality-Preset fährt nur konservativ; Custom
    /// erhält dieselbe Politik wie Smart (die Seiten-QA bleibt die Schranke).
    static func ladder(for preset: QualityGatePreset) -> [Rung] {
        switch preset {
        case .quality:
            return [conservative]
        case .small:
            return [conservative, small]
        case .smart, .custom:
            return [conservative, balanced]
        }
    }

    // MARK: Masken-Kodierung (einmal je Seite, rung-unabhängig)

    struct MaskEncoding {
        let codec: MRCMaskCodec
        let data: Data
        let globals: Data
        var totalBytes: Int { data.count + globals.count }
    }

    /// Lossless-Maske: JBIG2 (Render-Gate über PDFKit = echter Dekodierer),
    /// Fallback CCITT G4 (libtiff-Rückweg). Beide werden gegen den
    /// Ausgangspuffer bitidentisch verifiziert; sonst nil (kein MRC).
    static func encodeMask(_ mask: BilevelBuffer) -> MaskEncoding? {
        if let jbig2 = BilevelCodec.encodeJBIG2(mask) {
            let rendered = BilevelRenderGate.decodedBuffer(
                page: jbig2.page, globals: jbig2.globals.isEmpty
                    ? nil : jbig2.globals,
                width: mask.width, height: mask.height)
            if let rendered, rendered.bitIdentical(to: mask) {
                return MaskEncoding(codec: .jbig2, data: jbig2.page,
                                    globals: jbig2.globals)
            }
        }
        // G4-Fallback: Rückweg über denselben Fax-Codec (libtiff) –
        // bitidentisch oder verworfen.
        if let g4 = BilevelCodec.encodeG4(mask),
           let back = BilevelCodec.decodeG4(g4, width: mask.width,
                                            height: mask.height),
           back.bitIdentical(to: mask) {
            return MaskEncoding(codec: .ccittG4, data: g4, globals: Data())
        }
        return nil
    }

    /// Masken-Kodierung aus bereits kodierten Bytes (Executor-Regeneration).
    static func maskEncoding(codec: MRCMaskCodec, data: Data,
                             globals: Data) -> MaskEncoding {
        MaskEncoding(codec: codec, data: data, globals: globals)
    }

    // MARK: Layer je Stufe

    struct PhotoLayer {
        let data: Data
        let width: Int
        let height: Int
        let components: Int
        /// Sub-Rect im BILDPIXELRAUM, oben-links (Pixel).
        let rect: CGRect
    }

    struct EncodedLayers {
        let background: (data: Data, width: Int, height: Int, components: Int)
        let photos: [PhotoLayer]
        let mask: MaskEncoding
        var totalBytes: Int {
            mask.totalBytes + background.data.count
                + photos.reduce(0) { $0 + $1.data.count }
        }
    }

    /// Kodiert die Layer EINER Stufe. Deterministisch: dieselben Eingaben
    /// (Segmentierung + Stufe) erzeugen dieselben Bytes – Planung und
    /// Executor-Regeneration laufen über denselben Aufruf.
    ///
    /// `sourceDPI` ist die Scan-Auflösung des dominierenden Rasters (aus der
    /// Platzierung); die Zielmaße werden daraus abgeleitet und NIE höher als
    /// das Original gewählt (Never Upscale).
    static func encodeLayers(segmentation: MRCSegmenter.Segmentation,
                             mask: MaskEncoding,
                             rung: Rung,
                             sourceDPI: Double) -> EncodedLayers? {
        guard sourceDPI > 0 else { return nil }
        let rasterWidth = segmentation.mask.width
        let rasterHeight = segmentation.mask.height
        let gray = segmentation.backgroundIsGray

        // Hintergrund auf backgroundDPI.
        let bgWidth = max(1, min(rasterWidth,
            Int((Double(rasterWidth) * rung.backgroundDPI / sourceDPI).rounded())))
        let bgHeight = max(1, min(rasterHeight,
            Int((Double(rasterHeight) * rung.backgroundDPI
                / sourceDPI).rounded())))
        guard let bgImage = ImageResampler.resize(
            segmentation.background,
            to: PixelSize(width: bgWidth, height: bgHeight),
            grayscale: gray),
            let bgData = ImageResampler.encodeJPEG(bgImage,
                                                   quality: rung.backgroundQuality)
        else { return nil }

        // Photo-Regionen: höhere DPI/Qualität als der Hintergrund (§13.6),
        // Ausschnitt maßstabsgetreu zum Rect, Never Upscale gegen den Ausschnitt.
        var photos: [PhotoLayer] = []
        for region in segmentation.photoRegions {
            let width = max(1, min(Int(region.rect.width),
                Int((region.rect.width * rung.photoDPI / sourceDPI).rounded())))
            let height = max(1, min(Int(region.rect.height),
                Int((region.rect.height * rung.photoDPI / sourceDPI).rounded())))
            guard let resized = ImageResampler.resize(
                    region.crop,
                    to: PixelSize(width: width, height: height),
                    grayscale: gray),
                  let data = ImageResampler.encodeJPEG(
                    resized, quality: rung.photoQuality)
            else { return nil }
            photos.append(PhotoLayer(data: data, width: width, height: height,
                                     components: gray ? 1 : 3,
                                     rect: region.rect))
        }

        return EncodedLayers(
            background: (bgData, bgWidth, bgHeight, gray ? 1 : 3),
            photos: photos,
            mask: mask)
    }

    // MARK: Bundle-Container (§13.8: Gesamtbytes aller Layer)

    /// Deterministischer Binärcontainer aller Layer EINES Kandidaten.
    /// Reihenfolge = Zeichnungsreihenfolge: [Hintergrund, Photos…, Maske].
    /// Selbstbeschreibend (Maße/Rects je Layer); die Strukturinformation
    /// (Reihenfolge, Rect-Konvention) liegt im Deskriptor bzw. hier.
    enum Bundle {

        struct Entry {
            var kind: Int        // 0 JPEG, 1 JBIG2, 2 CCITT
            var isMask: Bool
            var components: Int
            var width: Int
            var height: Int
            var rect: CGRect?    // Bildpixelraum, oben-links
            var globals: Data
            var data: Data
        }

        static let magic: [UInt8] = [0x4D, 0x52, 0x43, 0x42]  // "MRCB"
        static let version: UInt8 = 1

        static func encode(_ entries: [Entry]) -> Data {
            var out = Data(capacity: 64)
            out.append(contentsOf: magic)
            out.append(version)
            out.append(UInt8(entries.count))
            func appendU32(_ value: UInt32) {
                var v = value.littleEndian
                withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
            }
            func appendF64(_ value: Double) {
                var v = value.bitPattern.littleEndian
                withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
            }
            for entry in entries {
                out.append(UInt8(entry.kind))
                out.append(entry.isMask ? 1 : 0)
                out.append(UInt8(clamping: entry.components))
                out.append(0)
                appendU32(UInt32(clamping: entry.width))
                appendU32(UInt32(clamping: entry.height))
                appendU32(UInt32(clamping: entry.globals.count))
                appendU32(UInt32(clamping: entry.data.count))
                let rect = entry.rect
                appendF64(rect.map { Double($0.minX) } ?? 0)
                appendF64(rect.map { Double($0.minY) } ?? 0)
                appendF64(rect.map { Double($0.maxX) } ?? 0)
                appendF64(rect.map { Double($0.maxY) } ?? 0)
                out.append(entry.globals)
                out.append(entry.data)
            }
            return out
        }

        static func decode(_ data: Data) -> [Entry]? {
            let bytes = [UInt8](data)
            guard bytes.count >= 6,
                  Array(bytes[0..<4]) == magic,
                  bytes[4] == version else { return nil }
            let layerCount = Int(bytes[5])
            var offset = 6
            // Kleinst_ENDIAN-Konsistenz zum Encoder: u32/u64 little-endian.
            func readLE32() -> UInt32? {
                guard offset + 4 <= bytes.count else { return nil }
                var value: UInt32 = 0
                for shift in stride(from: 0, to: 32, by: 8) {
                    value |= UInt32(bytes[offset]) << UInt32(shift)
                    offset += 1
                }
                return value
            }
            func readLE64() -> UInt64? {
                guard offset + 8 <= bytes.count else { return nil }
                var value: UInt64 = 0
                for shift in stride(from: 0, to: 64, by: 8) {
                    value |= UInt64(bytes[offset]) << UInt64(shift)
                    offset += 1
                }
                return value
            }
            var entries: [Entry] = []
            for _ in 0..<layerCount {
                guard offset + 8 <= bytes.count else { return nil }
                let kind = Int(bytes[offset])
                let isMask = bytes[offset + 1] == 1
                let components = Int(bytes[offset + 2])
                offset += 4
                guard let width = readLE32(), let height = readLE32(),
                      let globalsLen = readLE32(), let dataLen = readLE32(),
                      offset + 32 <= bytes.count else { return nil }
                func readF64() -> Double? {
                    guard let bits = readLE64() else { return nil }
                    return Double(bitPattern: bits)
                }
                guard let x0 = readF64(), let y0 = readF64(),
                      let x1 = readF64(), let y1 = readF64() else { return nil }
                var rect: CGRect?
                if x0 != 0 || y0 != 0 || x1 != 0 || y1 != 0 {
                    rect = CGRect(x: x0, y: y0,
                                  width: max(0, x1 - x0), height: max(0, y1 - y0))
                }
                guard globalsLen <= bytes.count - offset,
                      dataLen <= bytes.count - offset - Int(globalsLen)
                else { return nil }
                let globals = bytes.count >= offset + Int(globalsLen)
                    ? Data(bytes[offset..<(offset + Int(globalsLen))]) : Data()
                offset += Int(globalsLen)
                let payload = Data(bytes[offset..<(offset + Int(dataLen))])
                offset += Int(dataLen)
                entries.append(Entry(kind: kind, isMask: isMask,
                                     components: components,
                                     width: Int(width), height: Int(height),
                                     rect: rect, globals: globals,
                                     data: payload))
            }
            return entries
        }
    }
}
