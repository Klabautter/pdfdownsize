import Foundation
import PDFKit

/// Monster Epic Phase 6 – Backend-Abstraktion.
/// Produktionspfade bleiben weiterhin auf der Legacy-Pipeline; diese API ist die
/// Basis für den gesteuerten Cutover (Phase 19) und Differential-Tests (Phase 18).
protocol PDFCore {
    func inspect(_ url: URL) throws -> PDFDocumentInfo
    func validate(_ url: URL, policy: PDFValidationPolicy) throws -> PDFValidationReport
}

struct PDFDocumentInfo {
    let pageCount: Int
    /// qpdf-Version bei libqpdf-Core, nil bei PDFKit.
    let engineVersion: String?
}

struct PDFValidationPolicy {
    /// Strukturprüfung im Sinne von `qpdf --check` verlangen.
    var requiresCleanCheck = true

    static let standard = PDFValidationPolicy()
}

struct PDFValidationReport {
    let pageCount: Int
    let checkPassed: Bool
    let engineVersion: String?

    var isValid: Bool { pageCount >= 0 && checkPassed }
}

// MARK: - Implementierungen

/// Neue Engine: libqpdf über die pdfcore-C-Bridge.
struct LibQPDFCore: PDFCore {
    func inspect(_ url: URL) throws -> PDFDocumentInfo {
        let doc = try PDFCoreDocument(path: url.path)
        return PDFDocumentInfo(pageCount: doc.pageCount,
                               engineVersion: PDFCoreDocument.version)
    }

    func validate(_ url: URL, policy: PDFValidationPolicy) throws -> PDFValidationReport {
        let doc = try PDFCoreDocument(path: url.path)
        let pageCount = doc.pageCount
        var checkPassed = pageCount > 0
        if policy.requiresCleanCheck, checkPassed {
            do { try doc.check() } catch { checkPassed = false }
        }
        return PDFValidationReport(pageCount: pageCount,
                                   checkPassed: checkPassed,
                                   engineVersion: PDFCoreDocument.version)
    }
}

/// Referenz-/Legacy-Sicht über PDFKit – Grundlage für Differential-Tests.
struct PDFKitCore: PDFCore {
    func inspect(_ url: URL) throws -> PDFDocumentInfo {
        guard let doc = PDFDocument(url: url), !doc.isLocked else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return PDFDocumentInfo(pageCount: doc.pageCount, engineVersion: nil)
    }

    func validate(_ url: URL, policy: PDFValidationPolicy) throws -> PDFValidationReport {
        guard let doc = PDFDocument(url: url), !doc.isLocked else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // PDFKit kann kein qpdf-Äquivalent; Check gilt als erfüllt, wenn das
        // Dokument vollständig geladen wurde und Seiten zählbar sind.
        _ = policy
        return PDFValidationReport(pageCount: doc.pageCount,
                                   checkPassed: doc.pageCount > 0,
                                   engineVersion: nil)
    }
}
