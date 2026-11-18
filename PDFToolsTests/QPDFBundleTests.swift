import Testing
import AppKit
import PDFKit
@testable import PDFTools

/// Release-Robustheit: qpdf-Bundle-Lookup (Review P0.1) und
/// echte Pixelmaße beim Bildimport (P0.3).
struct QPDFBundleTests {

    // Der gebaute Test-Host enthält Contents/Helpers/qpdf – der Lookup muss
    // ihn finden, sonst greift stillschweigend der Homebrew-Fallback.
    @Test func bundledHelperIsFoundAtContentsHelpers() throws {
        let bundled = Compressor.bundledQPDFURL()
        #expect(bundled.path.hasSuffix("Contents/Helpers/qpdf"))
        try #require(FileManager.default.isExecutableFile(atPath: bundled.path))

        let found = Compressor.findQPDF()
        let resolved = try #require(found)
        #expect(resolved == bundled.path)
    }

    /// Nur arm64 (Entscheidung 18.11.2026): Ein Fat-Binary mit Intel-Anteil
    /// beginnt mit der Fat-Magic 0xCAFEBABE, ein reines arm64-Binary mit
    /// MH_MAGIC_64 und CPU_TYPE_ARM64.
    @Test func bundledHelperIsArm64OnlyAndRuns() throws {
        let bundled = Compressor.bundledQPDFURL()
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
            Issue.record("Vendored qpdf fehlt – Scripts/vendor-qpdf.sh ausführen")
            return
        }
        let header = try FileHandle(forReadingFrom: bundled).read(upToCount: 8) ?? Data()
        let words = header.withUnsafeBytes { raw in
            (raw.load(fromByteOffset: 0, as: UInt32.self), raw.load(fromByteOffset: 4, as: UInt32.self))
        }
        #expect(words.0 == 0xFEED_FACF, "qpdf-Helfer ist kein reines 64-Bit-Mach-O (Fat-Binary?)")
        #expect(words.1 == 0x0100_000C, "qpdf-Helfer ist nicht arm64")
        let process = Process()
        process.executableURL = bundled
        process.arguments = ["--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    // Review P0.3: DPI-Metadaten dürfen die Seitenpunkte nicht bestimmen.
    // 1200×900 px mit 300-dpi-Metadaten (NSImage.size wäre 400×300 pt) →
    // die PDF-Seite muss 1200×900 pt haben.
    @Test func imageImportKeepsTruePixelDimensions() async throws {
        let url = try TestFactory.makeTempPNG(size: CGSize(width: 400, height: 300),
                                              pixels: CGSize(width: 1200, height: 900))

        let info = ImageImporter.pixelInfo(of: url)
        #expect(info?.width == 1200)
        #expect(info?.height == 900)

        let pdfURL = try ImageImporter.singlePagePDF(from: url)
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let doc = try #require(PDFDocument(url: pdfURL))
        let bounds = doc.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
        #expect(abs(bounds.width - 1200) < 1)
        #expect(abs(bounds.height - 900) < 1)
    }

    // Temp-Lifecycle P0.4: Launch-Cleanup leert den Session-Ordner.
    @Test func staleImportCleanupRemovesLeftovers() async throws {
        // Das Verzeichnis selbst anlegen, statt es von einem anderen Aufruf
        // zu erwarten: `cleanupStaleImports()` aus einem parallel laufenden
        // Test entfernt es sonst zwischen Anlegen und Schreiben.
        let dir = ImageImporter.sessionDirectory
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let leftover = dir.appendingPathComponent("stale-\(UUID().uuidString).pdf")
        try Data([0x25]).write(to: leftover)   // "%"
        #expect(FileManager.default.fileExists(atPath: leftover.path))

        ImageImporter.cleanupStaleImports()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }
}
