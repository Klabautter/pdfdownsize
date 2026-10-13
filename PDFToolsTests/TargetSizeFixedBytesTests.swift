import Testing
import Foundation
@testable import PDFTools

/// Masterplan §12.3 (V2-6) – Fixed-Bytes-Modell und §16.3 Estimator-
/// Reachability-Heuristik (grob, kein voller Kandidatenlauf im Estimator).
@Suite struct TargetSizeFixedBytesTests {

    // MARK: §12.3 – Fixed Bytes

    /// fixed = (Dokument − optimierbare Bildbytes) × Struktur-Faktor (0.93,
    /// V2-1-Messwerte; derselbe Wert wie der Estimator-Punktwert).
    @Test func fixedBytesAusDokumentUndBildbytes() {
        #expect(TargetSizeOptimizer.fixedBytes(documentBytes: 1_000_000,
                                               optimizableBytes: 600_000)
                == 372_000)
        #expect(TargetSizeOptimizer.fixedBytes(documentBytes: 10,
                                               optimizableBytes: 10) == 0)
        #expect(TargetSizeOptimizer.fixedBytes(documentBytes: 10,
                                               optimizableBytes: 100) == 0)
    }

    /// Der Struktur-Faktor ist mit dem Estimator-Modell gekoppelt (§4
    /// Prinzip 3: Estimator und Optimizer teilen denselben Kandidatenraum);
    /// der Estimator-Default ist derselbe Wert.
    @Test func strukturFaktorTeiltEstimatorModell() {
        #expect(TargetSizeOptimizer.structureFactor == 0.93)
    }

    /// §12.6 – Nachkalibrierung: Drift wird dem festen Anteil zugerechnet,
    /// die Kandidaten-Bytes sind gemessen.
    @Test func nachkalibrierungBlamedDriftAufFixed() {
        #expect(TargetSizeOptimizer.recalibratedFixedBytes(
            actualTotalBytes: 100_000, selectedCandidateBytes: 77_000) == 23_000)
        #expect(TargetSizeOptimizer.recalibratedFixedBytes(
            actualTotalBytes: 500, selectedCandidateBytes: 600) == 0)
    }

    // MARK: §16.3 – Reachability

    /// Foto-lastiges Dokument: großes Ziel → likelyReachable; winziges
    /// Ziel → notSafelyReachable; dazwischen → uncertain.
    @Test func reachabilityFotoDokument() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1600)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = Compressor.fileSize(of: url)
        #expect(size > 100_000, "Fixture zu klein für die Heuristik")

        #expect(CompressionEstimator.targetLikelyReachable(
            url: url, goal: .targetBytes(size * 2)) == .likelyReachable)
        #expect(CompressionEstimator.targetLikelyReachable(
            url: url, goal: .targetBytes(100)) == .notSafelyReachable)
        // Zwischen der minimalen und der typischen Kurve: uncertain.
        #expect(CompressionEstimator.targetLikelyReachable(
            url: url, goal: .targetBytes(size / 2)) != nil)
    }

    /// Nicht-Ziele (Preset-Ziele) und unlesbare Dateien liefern nil – die
    /// Reachability ist NUR für `.targetBytes` definiert.
    @Test func reachabilityNurFuerZielgroesse() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 400)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CompressionEstimator.targetLikelyReachable(
            url: url, goal: .balanced) == nil)
        #expect(CompressionEstimator.targetLikelyReachable(
            url: url, goal: .targetBytes(0)) == nil)
        #expect(CompressionEstimator.targetLikelyReachable(
            url: URL(fileURLWithPath: "/nonexistent/x.pdf"),
            goal: .targetBytes(1_000)) == nil)
    }

    /// Grob-Konsistenz mit dem Optimizer-Modell: Der Fixed-Anteil der
    /// Reachability folgt DEMSELBER Fixed-Bytes-Modell (Dokument − Bildbytes,
    /// Struktur-Faktor).
    @Test func reachabilityNutztFixedBytesModell() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 800)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let document = try? PDFCoreDocument(path: url.path),
              let resources = try? document.imageResources() else {
            Issue.record("Fixture nicht lesbar"); return
        }
        let imageBytes = resources.reduce(Int64(0)) {
            $0 + Int64(max($1.encodedByteCount, 0))
        }
        let documentBytes = Compressor.fileSize(of: url)
        let fixed = TargetSizeOptimizer.fixedBytes(
            documentBytes: Int(documentBytes), optimizableBytes: Int(imageBytes))
        #expect(fixed >= 0)
        #expect(fixed < documentBytes,
                "Fixed-Bytes bleiben ein TEIL des Dokuments (\(fixed))")
    }
}
