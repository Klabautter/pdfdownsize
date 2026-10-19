import Testing
import Foundation
import AppKit
@testable import PDFTools

/// Sonde vor der Leiter (2026-10-19): Bei verlustbehaftet kodierten Quellen
/// (DCT/JPX) kodiert der Generator die kleinste Stufe EINMAL mit der
/// niedrigsten Qualität. Ist schon sie nicht kleiner als das Original,
/// entfällt die Suche; sonst läuft die Leiter unverändert.
///
/// Festgenagelt:
///   • Ein schon MRC-gepackter Scan (Archive.org: JPX-Hintergrund + JBIG2-
///     Maske, Korpusdatei) bleibt je Bild nach der Sonde – keine Messung,
///     kein Kandidat, keine Ersetzung.
///   • Ein gewöhnliches Foto über dem DPI-Ziel läuft nach der Sonde durch
///     die volle Leiter und wird ersetzt – die Sonde entscheidet nie gegen
///     einen Kandidaten.
///   • Gemischtes Dokument: Textseiten, dann JPEGs, die die Leiter nicht
///     unterbietet, dann Fotos – die Fotos werden ersetzt, jedes Bild wird
///     für sich sondiert.
///   • Schätzer: kompaktes JPX und JBIG2-Masken gelten als unverändert.
@Suite struct LossyProbeTests {

    // MARK: Fixtures

    /// Fotoartiges Rauschbild (Muster wie `photoHeavyPDF`) als JPEG mit
    /// wählbarer Qualität; `seed` variiert das Muster, damit der Inhalts-
    /// Hash-Dedup gleiche Seiten nicht zusammenlegt.
    static func noisyJPEG(pixels: Int, quality: CGFloat, seed: Int = 0) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        if let base = rep.bitmapData {
            let bpr = rep.bytesPerRow
            for y in 0..<pixels {
                let row = base + y * bpr
                for x in 0..<pixels {
                    let p = row + x * 4
                    p[0] = UInt8(truncatingIfNeeded: (x + seed * 97) * 255 / max(1, pixels))
                    p[1] = UInt8(truncatingIfNeeded: (y + seed * 31) * 255 / max(1, pixels))
                    p[2] = UInt8(truncatingIfNeeded: ((x ^ y) + seed * 13) * 255 / max(1, pixels))
                    p[3] = 255
                }
            }
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])!
    }

    struct Page {
        enum Kind { case text, image(quality: CGFloat, seed: Int) }
        let kind: Kind
    }

    /// Dokument aus Text- und Bildseiten. Jedes Bild: `pixels` Pixel auf
    /// `placedPoints` Punkten – 1200 px auf 330 pt sind 262 DPI, knapp über
    /// der Smart-Toleranz (220 × 1,15 = 253), also eine milde Verkleinerung.
    static func documentPDF(pages: [Page], pixels: Int = 1200,
                            placedPoints: Int = 330, name: String) throws -> URL {
        var b = RawPDFBuilder()
        let pagesNumber = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        var kids: [Int] = []
        for (index, page) in pages.enumerated() {
            let resources: Int
            let content: Int
            switch page.kind {
            case .text:
                resources = b.addObject("<</Font<</F1 \(font) 0 R>>>>")
                let lines = (1...25).map { line in
                    "BT /F1 12 Tf 1 0 0 1 60 \(760 - line * 26) Tm (Seite \(index + 1), Zeile \(line) des Textes.) Tj ET"
                }
                content = b.addStream(dictionary: "", content: lines.joined(separator: " "))
            case .image(let quality, let seed):
                let image = b.addStream(
                    dictionary: "/Type/XObject/Subtype/Image/Width \(pixels)"
                        + "/Height \(pixels)/BitsPerComponent 8/ColorSpace/DeviceRGB"
                        + "/Filter/DCTDecode",
                    data: noisyJPEG(pixels: pixels, quality: quality, seed: seed))
                resources = b.addObject("<</XObject<</Im0 \(image) 0 R>>"
                    + "/Font<</F1 \(font) 0 R>>>>")
                content = b.addStream(
                    dictionary: "",
                    content: "q \(placedPoints) 0 0 \(placedPoints) 100 300 cm /Im0 Do Q "
                        + "BT /F1 12 Tf 1 0 0 1 60 60 Tm (Seite \(index + 1)) Tj ET")
            }
            kids.append(b.addObject("<</Type/Page/Parent \(pagesNumber) 0 R"
                + "/MediaBox[0 0 612 792]/Resources \(resources) 0 R/Contents \(content) 0 R>>"))
        }
        b.fill(pagesNumber, "<</Type/Pages/Kids[\(kids.map { "\($0) 0 R" }.joined(separator: " "))]"
            + "/Count \(kids.count)>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pagesNumber) 0 R>>")
        return try b.write(rootObject: root, prefix: name)
    }

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(label)-\(UUID().uuidString).pdf")
    }

    static let euklidURL = CorpusRootResolver.resolve().root
        .appendingPathComponent("RealWorld/Archive/byrne_euclid_1847.pdf")
    /// Korpusdatei vorhanden? Sonst werden die Korpus-Tests übersprungen,
    /// nicht gebrochen (Konvention wie `needsLocalFiles`).
    static var hasEuklid: Bool { FileManager.default.fileExists(atPath: euklidURL.path) }

    /// Die ersten Seiten des Euklid-Scans als eigene Datei (qpdf aus dem
    /// Vendor-Ordner); nil, wenn Korpus oder qpdf fehlen.
    static func euklidExcerpt(pages: Int) throws -> URL? {
        guard FileManager.default.fileExists(atPath: euklidURL.path),
              let qpdf = Compressor.findQPDF() else { return nil }
        let out = tempURL("euklid-\(pages)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdf)
        process.arguments = ["--pages", euklidURL.path, "1-\(pages)", "--",
                             euklidURL.path, out.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 3 else { return nil }
        return out
    }

    /// Lauf mit eingeschaltetem JPEG-Suchtrace; liefert die Dispositionen
    /// je Bildobjekt (Objektnummer → Liste).
    static func runTraced(_ input: URL, options: CompressionOptions = .smart)
        throws -> (outcome: CompressionPipeline.Outcome, dispositions: [String: [String]]) {
        let traceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-trace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: traceDir) }
        setenv("PDFTOOLS_JPEG_SEARCH_TRACE", traceDir.path, 1)
        defer { unsetenv("PDFTOOLS_JPEG_SEARCH_TRACE") }
        let out = tempURL("out")
        defer { try? FileManager.default.removeItem(at: out) }
        let outcome = try CompressionPipeline.run(inputURL: input, outputURL: out,
                                                  options: options)
        var dispositions: [String: [String]] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: traceDir.path)) ?? []
        for file in files where file.hasPrefix("jpeg-") {
            let text = (try? String(contentsOf: traceDir.appendingPathComponent(file),
                                    encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let object = row["object"] as? String,
                      let disposition = row["disposition"] as? String else { continue }
                dispositions[object, default: []].append(disposition)
            }
        }
        return (outcome, dispositions)
    }

    /// Dispositionen, die eine gelaufene Suche oder Messung bedeuten.
    static let searchDispositions: Set<String> = [
        "candidate", "quality-rejected", "no-size-benefit", "marginal-native-saving",
        "graphics-gate-pass", "graphics-quality-rejected",
    ]

    // MARK: Sonde

    /// Korpusdatei: je Seite ein JPX-Hintergrund (300 ppi, ~20 KB) und ein
    /// JPX-Vorschaubild (100 ppi, ~36 KB), beide schon kompakter als jede
    /// JPEG-Stufe. Vorher: zehn bzw. fünf Kodierungen samt Messung je Bild
    /// für denselben Befund „Behalten“.
    @Test(.hangGuard, .enabled(if: LossyProbeTests.hasEuklid, "Korpusdatei fehlt"))
    func euklidScanBleibtNachEinerSondeJeBild() throws {
        let input = try #require(try Self.euklidExcerpt(pages: 3), "qpdf-Auszug fehlgeschlagen")
        defer { try? FileManager.default.removeItem(at: input) }

        let (outcome, dispositions) = try Self.runTraced(input)

        #expect(outcome.replacedImages == 0)
        #expect(outcome.plan.actions.count == 6)
        for action in outcome.plan.actions {
            guard case .keep(_, let reason, _) = action else {
                Issue.record("Erwartete KEEP, war: \(action)")
                continue
            }
            #expect(reason == .noSizeBenefit)
        }
        #expect(dispositions.count == 6, "Trace je Bild: \(dispositions.keys.sorted())")
        for (object, rows) in dispositions {
            let probed = rows.contains("probe-no-size-benefit")
                || rows.contains("graphics-probe-no-leverage")
            #expect(probed, "\(object): keine Sonde in \(rows)")
            let searched = rows.filter { Self.searchDispositions.contains($0) }
            #expect(searched.isEmpty, "\(object): Suche lief trotz Sonde: \(rows)")
        }
    }

    @Test(.hangGuard) func gewoehnlichesFotoLaeuftNachDerSondeDurchDieLeiter() throws {
        let input = try Self.documentPDF(pages: [Page(kind: .image(quality: 0.95, seed: 0))],
                                         name: "probe-photo")
        defer { try? FileManager.default.removeItem(at: input) }

        let (outcome, dispositions) = try Self.runTraced(input)

        #expect(outcome.replacedImages == 1)
        guard case .jpeg? = outcome.plan.actions.first else {
            Issue.record("Erwartete JPEG-Aktion, war: \(String(describing: outcome.plan.actions.first))")
            return
        }
        let rows = try #require(dispositions.values.first)
        #expect(rows.contains("probe-continue"), "Sonde fehlt: \(rows)")
        #expect(rows.contains("candidate"), "Leiter lief nicht: \(rows)")
    }

    /// Bilder, die die Leiter nicht unterbietet (JPEG q0,1, milde
    /// Verkleinerung), und Fotos im selben Dokument: Die Sonde entscheidet
    /// je Bild – die Fotos werden ersetzt, die anderen bleiben, und JEDES
    /// Bild wurde sondiert.
    @Test(.hangGuard) func gemischtesDokumentErsetztNurDieFotos() throws {
        var pages = [Page(kind: .text), Page(kind: .text)]
        pages += (1...3).map { Page(kind: .image(quality: 0.1, seed: $0)) }
        pages += (4...5).map { Page(kind: .image(quality: 0.95, seed: $0)) }
        let input = try Self.documentPDF(pages: pages, name: "probe-mixed")
        defer { try? FileManager.default.removeItem(at: input) }

        let (outcome, dispositions) = try Self.runTraced(input)

        #expect(outcome.replacedImages == 2, "\(dispositions)")
        #expect(outcome.plan.actions.count == 5)
        let kept = outcome.plan.actions.filter { if case .keep = $0 { return true } else { return false } }
        #expect(kept.count == 3)
        #expect(dispositions.count == 5, "Trace je Bild: \(dispositions.keys.sorted())")
        for (object, rows) in dispositions {
            #expect(rows.contains { $0.hasPrefix("probe-") }, "\(object): keine Sonde in \(rows)")
        }
    }

    // MARK: Schätzer

    static func jpxResource(bytes: Int) -> PDFImageResource {
        PDFImageResource(objectID: PDFObjectID(objectNumber: 10, generation: 0),
            width: 2214, height: 2848, bitsPerComponent: 8, colorSpace: .deviceRGB,
            filters: [.jpx], unknownFilters: [], hasSoftMask: true,
            hasExplicitMask: false, isImageMask: false, encodedByteCount: bytes,
            placements: [PDFImagePlacement(pageIndex: 0, resourceName: "Im0",
                                           placedWidthPoints: 531, placedHeightPoints: 683)])
    }

    @Test func kompaktesJPXWirdAlsUnveraendertGeschaetzt() {
        let floor = CompressionPlanner.qualityFloor(for: .smart)
        // Euklid-Hintergrund: 20 KB auf 6,3 MP, Ziel 220 DPI (Faktor 0,54).
        #expect(CompressionEstimator.quickRetention(resource: Self.jpxResource(bytes: 20_171),
                                                    ratio: 0.54, qualityFloor: floor) == 1)
        // Ein JPX-Foto mit 2 MB bleibt beim bisherigen Modell.
        #expect(CompressionEstimator.quickRetention(resource: Self.jpxResource(bytes: 2_000_000),
                                                    ratio: 0.54, qualityFloor: floor)
                == CompressionEstimator.QuickModel.otherRetention)
    }

    /// Korpusdatei (JPX + 2,9 MB JBIG2-Masken): Die Schätzung darf nicht mehr
    /// versprechen als der Lauf liefert (1,2 %). Vorher 12 %: die Masken
    /// galten als „Struktur“ mit 62 % Rest.
    @Test(.hangGuard, .enabled(if: LossyProbeTests.hasEuklid, "Korpusdatei fehlt"))
    func euklidScanWirdKaumKleinerGeschaetzt() throws {
        let input = Self.euklidURL
        let quick = try #require(CompressionEstimator.quickEstimate(url: input, options: .smart))
        #expect(quick.savingsRatio < 0.03,
                "Schnellschätzung \(Int(quick.savingsRatio * 100)) %, Lauf liefert 1 %")
        #expect(quick.lowBytes <= quick.pointBytes && quick.pointBytes <= quick.highBytes)
    }
}
