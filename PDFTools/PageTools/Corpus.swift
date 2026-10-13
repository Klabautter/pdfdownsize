import Foundation

/// Monster Epic Phase 1 – Corpus Infrastructure.
/// Verwaltet Fixtures (im Repo), externen Corpus (~/PDF_Tools-Testcorpus)
/// und Manifest-basierte Integritätsprüfung.
enum Corpus {

    // MARK: - Root Resolution

    /// Repo-Fixtures: immer vorhanden, klein.
    static var repoFixturesRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-fixtures", isDirectory: true)
    }

    /// Externer Corpus: konfigurierbar über Umgebungsvariable,
    /// Default: ~/PDF_Tools-Testcorpus
    static var externalCorpusRoot: URL {
        if let env = ProcessInfo.processInfo.environment["PDFTOOLS_CORPUS_ROOT"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("PDF_Tools-Testcorpus", isDirectory: true)
    }

    static var externalCorpusExists: Bool {
        FileManager.default.fileExists(atPath: externalCorpusRoot.path, isDirectory: nil)
    }

    // MARK: - Kategorien

    enum Category: String, CaseIterable {
        case synthetic = "Synthetic"
        case golden = "Golden"
        case malformed = "Malformed"
        case realWorld = "RealWorld"
        case stress = "Stress"
        case ocr = "OCR"
        case editor = "Editor"
        case results = "Results"

        var directoryName: String { rawValue }
    }

    // MARK: - Bootstrap

    /// Erzeugt die externe Corpus-Verzeichnisstruktur (idempotent).
    static func bootstrapExternalCorpus() throws {
        let fm = FileManager.default
        let root = externalCorpusRoot
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        for category in Category.allCases {
            let dir = root.appendingPathComponent(category.directoryName,
                                                  isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // RealWorld-Unterkategorien:
            if category == .realWorld {
                for sub in ["Office", "Academic", "Government", "Forms",
                            "Scans", "Special"] {
                    try fm.createDirectory(
                        at: dir.appendingPathComponent(sub, isDirectory: true),
                        withIntermediateDirectories: true)
                }
            }
        }

        let readme = root.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            try """
            # PDFTools TestCorpus

            Externer PDF-Testcorpus für PDFTools.
            Wird NICHT in das Git-Repository committet.

            Struktur:
            - Synthetic/ – reproduzierbar erzeugte Fixtures
            - Golden/ – wichtigste Regression-Dateien
            - Malformed/ – absichtlich defekte PDFs
            - RealWorld/ – öffentliche reale PDFs (nach Kategorie)
            - Stress/ – große Dateien für Memory/Runtime-Tests
            - Results/ – Benchmark- und Testergebnisse

            Konfigurierbar via PDFTOOLS_CORPUS_ROOT.
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Entry

    struct Entry {
        let id: String
        let url: URL
        let category: Category
        let sha256: String
        let pageCount: Int
        let hasText: Bool
        let hasImages: Bool
        let hasAnnotations: Bool
        let hasForms: Bool
        let fileSizeBytes: Int64
    }

    /// Listet alle PDF-Dateien in einer Kategorie auf.
    static func entries(category: Category) -> [Entry] {
        let dir = externalCorpusRoot.appendingPathComponent(
            category.directoryName, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }

        return contents.filter { $0.pathExtension.lowercased() == "pdf" }
            .compactMap { url -> Entry? in
                guard let core = try? PDFCoreDocument(path: url.path),
                      core.pageCount > 0 else { return nil }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?
                    .fileSize ?? 0
                let images = (try? core.inspectImages()) ?? []
                return Entry(id: url.deletingPathExtension().lastPathComponent,
                             url: url, category: category,
                             sha256: "", pageCount: core.pageCount,
                             hasText: false, hasImages: !images.isEmpty,
                             hasAnnotations: false, hasForms: false,
                             fileSizeBytes: Int64(size))
            }
    }
}
