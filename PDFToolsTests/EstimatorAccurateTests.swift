import Testing
import Foundation
import AppKit
@testable import PDFTools

/// Phase V2-10 (§16) – Estimator 2.0: Accurate Estimate (Sample-Encode der
/// größten behaltenen Streams, Frontier-Fit) und das Zielgrößen-Assessment
/// mit Punktangaben („sicher erreichbar ca. X", Actual-Size-Feedback-Muster
/// §12.6). Architektur-Regel bleibt: Der Schätzer trifft KEINE eigene
/// Bildentscheidung – gesampelt wird nur, was der Repack-Pass des Executors
/// mit BEHALTENEN Streams ohnehin tut (dieselbe Bedingung, derselbe Codec).
@Suite struct EstimatorAccurateTests {

    /// Deterministische Fixture mit EINEM GROSSEN BEHALTENEN DCT-Stream:
    /// Gradiente Streifen, als JPEG q0.35 gespeichert und mit 72 DPI
    /// platziert. Jeder Re-Encode der Qualitätsleiter ist GRÖSSER als die
    /// Vorlage – der Planner behält das Bild (noSizeBenefit), der Repack-
    /// Pass des Executors würde es trotzdem nochmal verpacken. Genau die
    /// Stelle, an der der Sample-Encode des §16.2 misst.
    private static func keptDCTFixture(width: Int = 800, height: Int = 600,
                                       name: String = "kept-dct") throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for x in stride(from: 0, to: width, by: 8) {
            NSColor(calibratedRed: CGFloat(x % 255) / 255.0,
                    green: CGFloat((x / 3) % 255) / 255.0,
                    blue: CGFloat((x / 7) % 255) / 255.0,
                    alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: x, y: 0, width: 8, height: height)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage,
              let jpeg = NSBitmapImageRep(cgImage: cg)
                .representation(using: .jpeg,
                                properties: [.compressionFactor: 0.35]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Guard für die Testannahme: Der Stream muss über der Sample-
        // Schwelle liegen, sonst misst der §16.2-Pfad nichts.
        guard jpeg.count > 4096 else {
            throw CocoaError(.fileWriteUnknown)
        }

        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let image = b.addStream(
            dictionary: "/Type/XObject/Subtype/Image/Width \(width)"
                + "/Height \(height)/ColorSpace/DeviceRGB/BitsPerComponent 8"
                + "/Filter/DCTDecode",
            data: jpeg)
        let content = b.addStream(dictionary: "",
                                  content: "q \(width) 0 0 \(height) 50 100 cm /Im0 Do Q")
        let page = b.addObject("<</Type/Page/Parent \(pages) 0 R"
            + "/MediaBox[0 0 612 792]/Resources<</XObject<</Im0 \(image) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let url = PDFFixtures.fixtureURL(prefix: name)
        try b.build(rootObject: root).write(to: url)
        return url
    }

    // MARK: §16.2 – Fast vs. Accurate

    /// Accurate bleibt im Fast-Band ± dokumentierte Toleranz (25 % der
    /// Fast-Bandbreite). Die Toleranz trägt der Tatsache Rechnung, dass der
    /// Frontier-Fit den Punktwert auf GEMESSENE Werte schieben darf – genau
    /// das ist sein Zweck; das Band darf nur nicht aus dem Fast-Band
    /// ausbrechen.
    @Test(.hangGuard) func akkuratBleibtImFastBandMitToleranz() throws {
        let url = try Self.keptDCTFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let fast = try #require(
            CompressionEstimator.estimate(url: url, options: .smart,
                                          mode: .fast))
        let accurate = try #require(
            CompressionEstimator.estimate(url: url, options: .smart,
                                          mode: .accurate))

        // Das Sample hat tatsächlich stattgefunden (kein Stillstand der
        // Funktion); im Fast-Modus wird nie gesampelt.
        #expect(accurate.sampledStreamCount >= 1,
                "Fixture behält einen großen DCT-Stream – der Sample-Encode muss zuschlagen")
        #expect(fast.sampledStreamCount == 0)

        // Band-Disziplin: engeres accurate-Band, ± Toleranz um das Fast-Band.
        let tolerance = Int64((Double(fast.highBytes - fast.lowBytes) * 0.25)
            .rounded(.up))
        #expect(accurate.lowBytes >= fast.lowBytes - tolerance,
                "accurate.low \(accurate.lowBytes) < fast.low \(fast.lowBytes) − Toleranz \(tolerance)")
        #expect(accurate.highBytes <= fast.highBytes + tolerance,
                "accurate.high \(accurate.highBytes) > fast.high \(fast.highBytes) + Toleranz \(tolerance)")
        #expect(accurate.highBytes - accurate.lowBytes
                <= fast.highBytes - fast.lowBytes,
                "Das „hohe Sicherheit“-Band muss enger sein als das Fast-Band")
        #expect(accurate.lowBytes <= accurate.pointBytes)
        #expect(accurate.highBytes >= accurate.pointBytes)
    }

    /// Dieselbe Datei, dieselbe Accurate-Schätzung – die Messwerte dürfen
    /// nicht von Aufruf zu Aufruf wandern.
    @Test(.hangGuard) func akkuratIstDeterministisch() throws {
        let url = try Self.keptDCTFixture(width: 640, height: 480,
                                          name: "kept-dct-determinism")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try #require(
            CompressionEstimator.estimate(url: url, options: .smart,
                                          mode: .accurate))
        let second = try #require(
            CompressionEstimator.estimate(url: url, options: .smart,
                                          mode: .accurate))
        #expect(first.pointBytes == second.pointBytes)
        #expect(first.lowBytes == second.lowBytes)
        #expect(first.highBytes == second.highBytes)
        #expect(first.sampledStreamCount == second.sampledStreamCount)
    }

    /// Ohne sampelbaren behaltenen Stream (unter der Sample-Schwelle) misst
    /// der Accurate-Modus nichts – dann bildet er sich keine Genauigkeit
    /// ein: Das Ergebnis bleibt exakt die Fast-Schätzung.
    @Test(.hangGuard) func akkuratOhneSampleBleibtFast() throws {
        // Winzige behaltene Bilder (64 px < 96 px-Kante → tooSmall, JPEG
        // weit unter der Sample-Schwelle von 4 KB).
        let url = try PDFFixtures.dedupStreamsPDF(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let fast = try #require(
            CompressionEstimator.estimate(url: url, options: .smart,
                                          mode: .fast))
        let accurate = try #require(
            CompressionEstimator.estimate(url: url, options: .smart,
                                          mode: .accurate))
        #expect(accurate.sampledStreamCount == 0)
        #expect(accurate.pointBytes == fast.pointBytes)
        #expect(accurate.lowBytes == fast.lowBytes)
        #expect(accurate.highBytes == fast.highBytes)
    }

    /// Der Modus ändert NIE den Plan: Fast und accurate lesen dieselben
    /// Planentscheidungen (Architektur: der Schätzer entscheidet nichts).
    @Test(.hangGuard) func modusAendertKeinenPlan() throws {
        let url = try Self.keptDCTFixture(name: "kept-dct-plan")
        defer { try? FileManager.default.removeItem(at: url) }

        var options = CompressionOptions.smart
        options.goal = .targetBytes(500_000)
        let document = try #require(try? PDFCoreDocument(path: url.path))
        let resources = try #require(try? document.imageResources())
        let planned = try CompressionPlanner.plan(
            resources: resources, options: options,
            documentID: url.lastPathComponent,
            documentBytes: Int(Compressor.fileSize(of: url)),
            pixels: LibQPDFPixelSource(document: document))
        #expect(planned.plan.traceVersion == 2,
                "Ziel aktiviert die Candidate-Engine (§25)")

        _ = try #require(
            CompressionEstimator.estimate(url: url, options: options,
                                          mode: .accurate))
        // Der Schätzer läuft auf dem WEGWERF-Handle: Die Datei bleibt
        // unangetastet, ein erneuter Plan ist identisch.
        let document2 = try #require(try? PDFCoreDocument(path: url.path))
        let resources2 = try #require(try? document2.imageResources())
        let planned2 = try CompressionPlanner.plan(
            resources: resources2, options: options,
            documentID: url.lastPathComponent,
            documentBytes: Int(Compressor.fileSize(of: url)),
            pixels: LibQPDFPixelSource(document: document2))
        #expect(planned.plan.actions == planned2.plan.actions)
        #expect(planned.plan.decisions == planned2.plan.decisions)
        #expect(planned.plan.candidateSets.map { $0.candidates.map(\.id) }
                == planned2.plan.candidateSets.map { $0.candidates.map(\.id) })
    }

    // MARK: §16.3 – Zielgrößen-Assessment (Punkt-Range)

    /// Alle drei Zweige tragen die Punktangaben: nicht sicher erreichbare
    /// Ziele nennen das §12.8-Minimum ÜBER dem Ziel – genau die Range, die
    /// die UI als „Ziel X → sicher erreichbar ca. Y" zeigt; erreichbare
    /// Ziele liegen unter der typischen Kurve.
    @Test(.hangGuard) func assessmentTraegtPunktangaben() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1600)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = Compressor.fileSize(of: url)

        // Unerreichbar: der „sicher erreichbar"-Punkt liegt ÜBER dem Ziel.
        let impossible = try #require(
            CompressionEstimator.assessTargetSize(url: url,
                                                  goal: .targetBytes(100)))
        #expect(impossible.reachability == .notSafelyReachable)
        #expect(impossible.safelyReachableBytes > impossible.targetBytes)
        #expect(impossible.typicalBytes >= impossible.safelyReachableBytes)

        // Über dem Dokument: erreichbar, Punkte liegen unter dem Ziel.
        let easy = try #require(
            CompressionEstimator.assessTargetSize(url: url,
                                                  goal: .targetBytes(size * 2)))
        #expect(easy.reachability == .likelyReachable)
        #expect(easy.safelyReachableBytes <= easy.targetBytes)
        #expect(easy.typicalBytes <= easy.targetBytes)

        // Zwischen den Kurven: unsicher – der Lauf entscheidet.
        let mid = try #require(
            CompressionEstimator.assessTargetSize(url: url,
                                                  goal: .targetBytes(size / 2)))
        #expect(mid.reachability == .uncertain)
        #expect(mid.typicalBytes >= mid.targetBytes,
                "Ziel zwischen minimum und typisch: die typische Kurve liegt über dem Ziel")
    }

    /// Beide APIs antworten identisch – `targetLikelyReachable` liest dieselbe
    /// Modellstelle wie `assessTargetSize` (keine zweite Meinung, §4).
    @Test(.hangGuard) func reachabilityUndAssessmentSprechenGleich() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1200)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = Compressor.fileSize(of: url)
        for target in [Int64(100), size / 3, size / 2, size * 2] {
            let reachability = CompressionEstimator.targetLikelyReachable(
                url: url, goal: .targetBytes(target))
            let assessment = CompressionEstimator.assessTargetSize(
                url: url, goal: .targetBytes(target))
            #expect(reachability == assessment?.reachability)
            #expect(assessment?.targetBytes == target)
        }
        // Nicht-Ziele bleiben für beide APIs undefiniert (nil).
        #expect(CompressionEstimator.targetLikelyReachable(
            url: url, goal: .balanced) == nil)
        #expect(CompressionEstimator.assessTargetSize(
            url: url, goal: .bestQuality) == nil)
        #expect(CompressionEstimator.assessTargetSize(
            url: url, goal: .targetBytes(0)) == nil)
    }
}
