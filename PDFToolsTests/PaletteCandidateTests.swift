import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Phase V2-3b (Masterplan §9.6) – Exact Palette / Indexed-Farbraum.
///
/// Festgenagelt:
///   • Nur EXAKTE Palette: Der Scan ist verlustfrei konstruiert – Palette
///     plus Indizes müssen die Pixel BITGENAU rekonstruieren (Gate im
///     PaletteOptimizer, Vollvergleich gegen die Rohpixel).
///   • BitsPerComponent exakt nach Palettengröße: 1/2/4/8.
///   • Indexpackung MSB-first MIT Zeilenbytegrenzen (ISO 32000-1 §8.9.3:
///     „each row of sample data shall begin on a byte boundary") – der
///     Unit-Test liest die gepackten Bytes mit einem unabhängigen
///     Bitleser zurück, auch für Breiten, deren Zeile nicht bytegerade ist.
///   • > 256 Farben → kein Indexed-Kandidat (Stichprobe und Vollscan).
///   • Race (§9.6): indexed konkurriert mit KEEP und Flate – kleinster
///     gewinnt; Palette größer als Flate → kein Kandidat im Plan.
///   • Nur candidateEngine-Pfad: Legacy-Pfad erzeugt keinen Palette-
///     Kandidaten (traceVersion 1, aktionsidentisch zum Bestand).
///   • Bridge-Output: /ColorSpace [/Indexed /DeviceRGB …], BitsPerComponent,
///     /DecodeParms Predictor 15 /Colors 1, RenderDifferential.
@Suite struct PaletteCandidateTests {

    // MARK: Helfer

    static func candidateOptions(_ base: CompressionOptions = .smart)
        -> CompressionOptions {
        var options = base
        options.featureFlags.candidateEngine = true
        return options
    }

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-\(label)-\(UUID().uuidString).pdf")
    }

    /// Baut ein RGB-CGImage aus einer Farbformel (RGBA-Bitmap, RGBX).
    static func makeImage(width: Int, height: Int,
                          color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = (y * width + x) * 4
                buffer[i] = r; buffer[i + 1] = g; buffer[i + 2] = b
                buffer[i + 3] = 255
            }
        }
        return buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }

    /// Unabhängiger Bitleser: MSB-first, Zeilenbeginn auf Bytegrenze.
    static func readIndex(_ packed: [UInt8], row: Int, column: Int,
                          width: Int, bitsPerComponent: Int) -> Int {
        let rowBytes = (width * bitsPerComponent + 7) / 8
        let bitStart = row * rowBytes * 8 + column * bitsPerComponent
        var value = 0
        for b in 0..<bitsPerComponent {
            let bitIndex = bitStart + b
            let bit = (packed[bitIndex / 8] >> (7 - bitIndex % 8)) & 1
            value = (value << 1) | Int(bit)
        }
        return value
    }

    // MARK: Optimizer – Packung und Gate (Unit)

    @Test func packtUngeradeBreitenMitZeilenbytegrenzen() throws {
        // 123 px × bpc 4 → 62 Byte je Zeile (123·4 = 492 Bits, 4 Bits
        // Auffüllung am Zeilenende). Die Packung muss zeilenweise
        // bytegerade bleiben und MSB-first lesen lassen.
        let width = 123, height = 77, bpc = 4
        var indices = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                indices[row * width + column] = UInt8((column * 7 + row * 5) % 5)
            }
        }
        let packed = try #require(PaletteOptimizer.pack(
            indices: indices, width: width, height: height,
            bitsPerComponent: bpc))
        let rowBytes = (width * bpc + 7) / 8
        #expect(rowBytes == 62, "Zeilenlänge 123·4 Bits = 62 Byte")
        #expect(packed.count == rowBytes * height)

        // Auffüllbits der letzten Bytes je Zeile bleiben Null.
        let usedBits = (width * bpc) % 8   // 4
        let paddingMask = UInt8(0xFF >> usedBits)
        for row in 0..<height {
            #expect(packed[row * rowBytes + rowBytes - 1] & paddingMask == 0,
                    "Zeile \(row): Auffüllbits nicht null")
        }

        // Unabhängiges Zurücklesen je Pixel (MSB-first, Zeilengrenze).
        for row in 0..<height {
            for column in 0..<width {
                let value = Self.readIndex(packed, row: row, column: column,
                                           width: width, bitsPerComponent: bpc)
                #expect(value == indices[row * width + column],
                        """
                        Pixel (\(column), \(row)): \(value) != \
                        \(indices[row * width + column])
                        """)
            }
        }
    }

    @Test func packtEinBitZeilenMitSiebenFuellbits() throws {
        // 97 px × bpc 1 → 13 Byte je Zeile, 7 Auffüllbits.
        let width = 97, height = 33, bpc = 1
        var indices = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                indices[row * width + column] = UInt8((column + row) % 2)
            }
        }
        let packed = try #require(PaletteOptimizer.pack(
            indices: indices, width: width, height: height,
            bitsPerComponent: bpc))
        let rowBytes = (width * bpc + 7) / 8
        #expect(rowBytes == 13)
        for row in 0..<height {
            #expect(packed[row * rowBytes + rowBytes - 1] & 0x7F == 0,
                    "Zeile \(row): Auffüllbits nicht null")
        }
        for row in 0..<height {
            for column in 0..<width {
                #expect(Self.readIndex(packed, row: row, column: column,
                                       width: width, bitsPerComponent: bpc)
                        == indices[row * width + column])
            }
        }
    }

    @Test func zweiFarbenBekommenEinBitProPixel() throws {
        let width = 97, height = 33   // 97 Bits je Zeile → 13 Byte (7 Füllbits)
        let image = try #require(Self.makeImage(width: width, height: height) {
            x, y in (x + y) % 2 == 0 ? (255, 255, 255) : (0, 0, 0)
        })
        guard case .success(let encoded) =
                PaletteOptimizer.encodeExact(image, components: 3) else {
            Issue.record("Exact-Palette-Kodierung fehlgeschlagen")
            return
        }
        #expect(encoded.paletteEntries == 2)
        #expect(encoded.bitsPerComponent == 1)
        #expect(encoded.palette.count == 6)
        // Gate hat bitgenau bestanden – Rekonstruktion == Original.
    }

    @Test func drittelPaletteBekommtZweiBits() throws {
        let image = try #require(Self.makeImage(width: 65, height: 41) {
            x, y in [(255, 0, 0), (0, 255, 0), (0, 0, 255)][(x + y) % 3]
        })
        guard case .success(let encoded) =
                PaletteOptimizer.encodeExact(image, components: 3) else {
            Issue.record("Exact-Palette-Kodierung fehlgeschlagen")
            return
        }
        #expect(encoded.paletteEntries == 3)
        #expect(encoded.bitsPerComponent == 2)
    }

    @Test func graustufenBekommenDeviceGrayPalette() throws {
        // Graues CGImage über DeviceGray-Kontext.
        let width = 65, height = 41
        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                gray[y * width + x] = [0, 85, 170, 255][(x + y) % 4]
            }
        }
        let image: CGImage? = gray.withUnsafeBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: raw.baseAddress),
                                      width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
        guard let image,
              case .success(let encoded) =
                PaletteOptimizer.encodeExact(image, components: 1) else {
            Issue.record("Graustufen-Kodierung fehlgeschlagen")
            return
        }
        #expect(encoded.components == 1)
        #expect(encoded.paletteEntries == 4)
        #expect(encoded.bitsPerComponent == 2)
        #expect(encoded.palette.count == 4)
    }

    @Test func ueber256FarbenWirdVerweigert() throws {
        // Kleines Bild (12000 Pixel < Stichprobendeckel → der Scan IST der
        // Vollscan) mit deutlich mehr als 256 distinkten Farben.
        let image = try #require(Self.makeImage(width: 300, height: 40) {
            x, y in (UInt8(x % 256), UInt8(y % 256), UInt8((x + y) % 256))
        })
        guard case .tooManyColors = PaletteOptimizer.encodeExact(image,
                                                                 components: 3) else {
            Issue.record("Erwartete Verweigerung: > 256 Farben")
            return
        }
    }

    @Test func stichprobeEntscheidetVorDemVollscan() throws {
        // Großes Bild (> 128k Pixel): Die Stichprobe allein sieht bereits
        // > 256 Farben → kein vollständiger Scan nötig, Verweigerung bleibt.
        let image = try #require(Self.makeImage(width: 600, height: 400) {
            x, y in (UInt8((x * 13) % 256), UInt8((y * 7) % 256), UInt8((x + y) % 256))
        })
        guard case .tooManyColors = PaletteOptimizer.encodeExact(image,
                                                                 components: 3) else {
            Issue.record("Erwartete Verweigerung durch die Stichprobe")
            return
        }
    }

    // MARK: Pipeline – Kandidat, Race und Output

    @Test(.hangGuard) func palettenKandidatGewinntGegenFlateUndBleibtBitgenau()
        throws {
        let input = try PDFFixtures.limitedPalettePDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let out = Self.tempURL("indexed")
        defer { try? FileManager.default.removeItem(at: out) }

        // Single-Write (V2-11-Default) packt Dictionaries in Objekt-Streams;
        // der rohe Text-Scan unten braucht ein unkomprimiertes Dict-Layout –
        // für diese Struktur-Lupe wird der Zwei-Write-Pfad genutzt.
        var runOptions = Self.candidateOptions()
        runOptions.featureFlags.singleWrite = false
        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: runOptions)
        let set = try #require(outcome.plan.candidateSets.first)
        let indexed = set.candidates.first {
            if case .indexedFlate = $0.kind { return true }
            return false
        }
        let flate = set.candidates.first {
            if case .flate = $0.kind { return true }
            return false
        }
        let indexedCandidate = try #require(indexed,
                                            "Kein Indexed-Kandidat erzeugt")
        let flateCandidate = try #require(flate, "Kein Flate-Konkurrent erzeugt")

        // Race §9.6: kleinster verlustfreier Kandidat gewinnt.
        #expect(indexedCandidate.metrics.encodedBytes
                    < flateCandidate.metrics.encodedBytes,
                """
                Indexed (\(indexedCandidate.metrics.encodedBytes)) gewinnt \
                nicht gegen Flate (\(flateCandidate.metrics.encodedBytes))
                """)
        #expect(!indexedCandidate.isLossless)
        #expect(indexedCandidate.metrics.globalSSIM != nil)

        // Die Wahl trägt die Palette in der Action (Plan bleibt selbst-
        // beschreibend); Entscheidungen/Trace sehen den Kandidaten. Die
        // Einträgezahl enthält die Interpolations-Mischfarben der 2:1-
        // Verkleinerung – die BitsPerComponent-Zusage folgt exakt der
        // Einträgezahl (§9.6), nicht der Kachelzahl der Fixture.
        guard case .indexed(_, let target, let bpc, let paletteComponents,
                            let palette, let original, let expected,
                            let quantized, _) =
                try #require(outcome.plan.transformedActions.first) else {
            Issue.record("Erwartete Indexed-Aktion, war: \(outcome.plan.actions)")
            return
        }
        #expect(!quantized, "Exakt-Pfad darf nicht als quantisiert gelten")
        let entries = palette.count / 3
        #expect(entries > 6 && entries <= 256,
                "Palette \(entries) Einträge – Kacheln + Mischfarben")
        #expect(bpc == (entries <= 2 ? 1 : (entries <= 4 ? 2
                    : (entries <= 16 ? 4 : 8))),
                "BitsPerComponent folgt exakt der Einträgezahl")
        #expect(paletteComponents == 3)
        #expect(expected == indexedCandidate.metrics.encodedBytes)
        #expect(expected < original)
        let decision = try #require(outcome.plan.decisions.first)
        #expect(decision.selectedCandidateID == indexedCandidate.id)

        // Output-Struktur: /Indexed-Farbraum, bpc, Prädiktor-DecodeParms.
        let core = try PDFCoreDocument(path: out.path)
        let info = try #require(try core.inspectImages().first)
        #expect(info.colorspace.hasPrefix("Indexed"),
                "Farbraum ist kein /Indexed: \(info.colorspace)")
        #expect(info.bitsPerComponent == bpc)
        #expect(info.width == target.width && info.height == target.height)
        let raw = try String(decoding: Data(contentsOf: out), as: UTF8.self)
        #expect(raw.contains("/Indexed"))
        #expect(raw.contains("/DeviceRGB"))
        #expect(raw.contains("/Predictor 15"))
        #expect(raw.contains("/Colors 1"))

        // Bitgenau-Nachweis auf Objektebene: dekodierte Indizes → Palette
        // → Pixelvergleich gegen die Zielpixel der Quelle.
        let sourceCore = try PDFCoreDocument(path: input.path)
        let sourceResource = try #require(try sourceCore.imageResources().first)
        let sourcePixels = LibQPDFPixelSource(document: sourceCore)
        let sourceImage = try #require(
            sourcePixels.decodedImage(for: sourceResource, target: target))
        let resized = try #require(
            ImageResampler.resize(sourceImage, to: target, components: 3))
        let expectedPixels = try #require(ImageResampler.rawBitmap(resized,
                                                                   components: 3))
        let indexData = try #require(
            core.imageStreamData(objectID: info.objectID, decoded: true))
        let rowBytes = (target.width * bpc + 7) / 8
        #expect(indexData.count == rowBytes * target.height,
                "Indexstrom trägt nicht die erwartete Zeilenpackung")
        let packed = [UInt8](indexData)
        let paletteBytes = [UInt8](palette)
        for row in 0..<target.height {
            for column in 0..<target.width {
                let value = Self.readIndex(packed, row: row, column: column,
                                           width: target.width,
                                           bitsPerComponent: bpc)
                #expect(value < entries, "Index \(value) hinter hival")
                let o = (row * target.width + column) * 3
                #expect(paletteBytes[value * 3] == expectedPixels[o]
                        && paletteBytes[value * 3 + 1] == expectedPixels[o + 1]
                        && paletteBytes[value * 3 + 2] == expectedPixels[o + 2],
                        "Pixel (\(column), \(row)) rekonstruiert nicht bitgenau")
            }
        }

        // PDFKit-Rendervergleich: Das Zielraster ist bereits die Zielgröße,
        // der Quell-Render skaliert herauf – nahezu, aber nicht exakt
        // derselbe Resampling-Pfad.
        let comparison = try #require(
            RenderDifferential.compare(sourceURL: input, outputURL: out,
                                       dpi: 150).first)
        #expect(comparison.ssim > 0.995,
                "SSIM \(comparison.ssim) unterhalb der Bilevel-Nähe")
        #expect(comparison.changedAreaRatio < 0.01,
                "CAR \(comparison.changedAreaRatio)")

        // Beleg-Artefakt: Fixture-Zahlen Indexed vs Flate (stdout → Log).
        let report = """
            === PALETTEN-RACE limitedPalettePDF ===
            original=\(original)B indexed=\(expected)B flate=\
            \(flateCandidate.metrics.encodedBytes)B \
            entries=\(entries) bpc=\(bpc) \
            target=\(target.width)x\(target.height) \
            ssim=\(comparison.ssim) car=\(comparison.changedAreaRatio)
            """
        print(report)
    }

    @Test(.hangGuard) func ueber256FarbenBekommtKeinenPalettenKandidaten()
        throws {
        let input = try PDFFixtures.manyColorsPDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let planned = try CompressionPipeline.plan(inputURL: input,
                                                   options: Self.candidateOptions())
        let set = try #require(planned.plan.candidateSets.first)
        let kinds = set.candidates.map(\.kind)
        #expect(!kinds.contains { if case .indexedFlate = $0 { return true }
                                  ; return false },
                "> 256 Farben dürfen keinen Indexed-Kandidaten erzeugen")
        #expect(kinds.contains { if case .flate = $0 { return true }; return false },
                "Der Flate-Konkurrent sollte trotzdem entstehen")
    }

    @Test(.hangGuard) func paletteGroesserAlsFlateVerliertDenRace() throws {
        let input = try PDFFixtures.tinyGradientPalettePDF()
        defer { try? FileManager.default.removeItem(at: input) }
        let planned = try CompressionPipeline.plan(inputURL: input,
                                                   options: Self.candidateOptions())
        let set = try #require(planned.plan.candidateSets.first)
        let kinds = set.candidates.map(\.kind)
        // Der Verlauf erzeugt eine (graue) Palette, deren Indexstrom
        // byteidentisch zum Flate-Konkurrenten ist – die Palette kostet
        // zusätzlich und gewinnt den Race nie.
        #expect(!kinds.contains { if case .indexedFlate = $0 { return true }
                                  ; return false },
                "Palette-Kandidat größer als Flate darf nicht im Set stehen")
        guard let action = planned.plan.actions.first else {
            Issue.record("Keine Aktion im Plan")
            return
        }
        if case .keep(_, let reason, _) = action {
            // Beide Kandidaten am Never-Grow gescheitert → KEEP. Seit Smart
            // 220 DPI (2026-10-09) liegt der graue Verlauf im Budget und
            // endet am Grau-Frühabsprung (`alreadyGrayscale`) – ebenfalls KEEP.
            #expect(reason == .noSizeBenefit || reason == .withinBudget
                        || reason == .alreadyGrayscale,
                    "Unerwarteter KEEP-Grund: \(reason)")
        } else if case .losslessResize = action {
            // Flate hat das Original unterboten – Indexed war trotzdem nie
            // im Set (oben geprüft).
        } else if case .jpeg = action {
            // Kalibrierung nach dem Classifier-Fix (V2-3b): Der glatte
            // Grau-Verlauf ist kontinuierliche Tönung (dominantColorShare
            // 0.25, gemessen) → photo → der quality-gegate JPEG-Kandidat
            // ist legitim im Rennen und schlägt Flate/Palette. Festgenagelt
            // bleibt die Kernaussage: KEIN Indexed-Kandidat (oben).
        } else {
            Issue.record("Unerwartete Aktion: \(action)")
        }
    }

    // MARK: Pfad-Trennung

    /// V2-11 – der frühere „Legacy-Pfad bleibt ohne Palettenkandidat“-Fall
    /// hat seinen Gegenstand verloren: Es gibt nur den Candidate-Pfad (§25).
    /// Fortgeschrieben: Der Palette-Kandidat hängt an der graphics-ROUTE,
    /// nicht an der classifierPolicy – auch mit `.legacy` entsteht er und
    /// gewinnt hier den Race (210-Farb-Kachel, Indexed 1948 < Flate 3167).
    @Test(.hangGuard) func palettenKandidatEntstehtAuchOhneV2Klassifikator() throws {
        let input = try PDFFixtures.limitedPalettePDF()
        defer { try? FileManager.default.removeItem(at: input) }
        var options = CompressionOptions.smart
        options.classifierPolicy = .legacy
        let planned = try CompressionPipeline.plan(inputURL: input,
                                                   options: options)
        #expect(planned.plan.traceVersion == 2)
        let set = try #require(planned.plan.candidateSets.first)
        #expect(set.candidates.contains { candidate in
            if case .indexedFlate = candidate.kind { return true }
            return false
        }, "Palette-Familie hängt an der Route, nicht am Klassifikator")
        // verlustfreie Aktionsarten only (KEEP/Flate/Indexed).
        for action in planned.plan.actions {
            switch action {
            case .keep, .losslessResize, .indexed: continue
            default:
                Issue.record("Unerwartete Aktionsart: \(action)")
            }
        }
    }

    /// Never-Grow als Set-Invariante über alle Palette-Fixtures: Kein
    /// Kandidat im Set darf die Originalbytes erreichen.
    @Test(.hangGuard) func nieEinKandidatUeberOriginalgroesse() throws {
        let urls = [
            try PDFFixtures.limitedPalettePDF(),
            try PDFFixtures.manyColorsPDF(),
            try PDFFixtures.tinyGradientPalettePDF(),
            try PDFFixtures.screenshotLikePDF(pixels: 1400),
        ]
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        for url in urls {
            let planned = try CompressionPipeline.plan(
                inputURL: url, options: Self.candidateOptions())
            for set in planned.plan.candidateSets {
                let original = set.keepCandidate?.metrics.encodedBytes ?? 0
                for candidate in set.candidates where !candidate.kind.isKeep {
                    #expect(candidate.metrics.encodedBytes < original,
                            """
                            \(set.resourceID): Kandidat \(candidate.id) \
                            \(candidate.metrics.encodedBytes) >= \
                            Original \(original)
                            """)
                }
            }
        }
    }
}
