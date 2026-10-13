import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Bilder mit ICC-Profil werden verkleinert – das Profil bleibt.
///
/// Sie waren ausgeschlossen, weil sich aus dem Namen „ICCBased" allein die
/// Komponentenzahl nicht ablesen lässt; sie steht im Profil (`/N`). Über den
/// Korpus gemessen sind das 11,5 MB.
///
/// Das Profil beschreibt, wie die Farbwerte zu deuten sind. Ghostscript
/// wirft es weg und schreibt DeviceRGB; wir behalten es. Die Ersparnis kommt
/// aus der Auflösung, nicht aus dem Weglassen des Profils.
@Suite struct ICCProfileTests {

    @Test(.hangGuard) func fixtureUsesAnICCProfile() throws {
        let url = try PDFFixtures.iccProfilePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try #require(try PDFCoreDocument(path: url.path).imageResources().first)
        guard case .iccBased(let n) = r.colorSpace else {
            Issue.record("Farbraum ist \(r.colorSpace) statt ICCBased")
            return
        }
        #expect(n == 3, "Komponentenzahl aus dem Profil: \(n)")
    }

    @Test(.hangGuard) func iccIsTransformable() throws {
        let url = try PDFFixtures.iccProfilePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try #require(try PDFCoreDocument(path: url.path).imageResources().first)
        #expect(r.transformCapability.isSafe, """
            ICC gilt weiterhin als untransformierbar: \
            \(r.transformCapability.reason)
            """)
    }

    /// Kleiner werden – und das Profil behalten.
    @Test(.hangGuard) func shrinksAndKeepsTheProfile() throws {
        let url = try PDFFixtures.iccProfilePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let inBytes = Compressor.fileSize(of: url)

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.outputBytes < inBytes, """
            Nicht kleiner: \(inBytes) → \(result.outputBytes)
            """)

        let out = try PDFCoreDocument(path: result.outputURL.path)
        let r = try #require(try out.imageResources().first)
        guard case .iccBased = r.colorSpace else {
            Issue.record("""
                Das Profil wurde weggeworfen, Farbraum ist jetzt \
                \(r.colorSpace). Das ist eine Farbveränderung, keine \
                Kompression.
                """)
            return
        }
        #expect(r.width < 1800, "Nicht verkleinert: \(r.width)")
    }

    /// Und die Seite sieht aus wie vorher.
    @Test(.hangGuard) func coloursAreUnchanged() throws {
        let url = try PDFFixtures.iccProfilePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try #require(PDFDocument(url: url)?.page(at: 0)?
            .thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox))
        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let after = try #require(PDFDocument(url: result.outputURL)?.page(at: 0)?
            .thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox))

        let a = try #require(before.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let b = try #require(after.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let ssim = QualityMetrics.ssim(original: a, candidate: b)
        #expect(ssim > 0.95, """
            Die Seite sieht anders aus (SSIM \(String(format: "%.4f", ssim))).
            """)
    }
}
