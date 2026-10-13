import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan §11.2 – maschinenlesbare ValidationFindings.
///
/// Der String-Report bleibt die Menschen-Sicht; diese Suite nagelt fest,
/// dass die ADDITIVEN Findings dieselben Befunde tragen:
///   • Text-Fingerprint-Diff → .text mit severity .error und den Seiten.
///   • Seitenzahl-Mismatch → .pageCount.
///   • Geometrie-Verstoß → .geometry mit Seite.
///   • Nur error/fatal zählen als blockierend (§11.5) – info/warning nicht.
@Suite struct StructuredValidationFindingTests {

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("finding-\(label)-\(UUID().uuidString).pdf")
    }

    /// policy wie PDFValidator.Policy.compression, aber ohne qpdf-Check
    /// (der Fixture-Output ist raw gebaut; geprüft wird die Semantik).
    static var semanticPolicy: PDFValidator.Policy {
        var policy = PDFValidator.Policy(
            preservesText: true,
            preservesAnnotations: true,
            preservesLinks: true,
            preservesForms: true)
        policy.failsOnSemanticSeverity = .high
        policy.expectedDifferences = []
        policy.preservesGeometry = true
        return policy
    }

    // MARK: Text-Diff → .text / .error mit Seite

    @Test(.hangGuard) func textDiffErzeugtTextFindingMitSeite() throws {
        let reference = try PDFFixtures.textPDF(text: "HALLO WELT", name: "ref")
        let output = try PDFFixtures.textPDF(text: "ANDERER TEXT", name: "out")
        defer {
            try? FileManager.default.removeItem(at: reference)
            try? FileManager.default.removeItem(at: output)
        }
        // Sanity: die Fixtures tragen auch wirklich extrahierbaren,
        // verschiedenen Text.
        let before = try PDFSemanticSnapshot.capture(reference)
        let after = try PDFSemanticSnapshot.capture(output)
        #expect(before.pages[0].textCharacterCount > 0)
        #expect(before.pages[0].textFingerprint != after.pages[0].textFingerprint)

        let report = PDFValidator.validate(outputURL: output,
                                           referenceURL: reference,
                                           policy: Self.semanticPolicy)
        #expect(!report.isValid, "Abweichender Text muss scheitern")

        let textFindings = report.findings.filter { $0.kind == .text }
        #expect(!textFindings.isEmpty,
                "Der Text-Diff erzeugte kein maschinenlesbares Finding")
        #expect(textFindings.allSatisfy { $0.severity == .error },
                "Text-Abweichungen sind .error (blockierend, §11.5)")
        #expect(textFindings.contains { $0.pages == [1] },
                "Die betroffene Seite fehlt: \(textFindings.map(\.pages))")
        #expect(textFindings.allSatisfy { !$0.message.isEmpty })

        // ADDITIV: der String-Report bleibt unverändert sichtbar.
        #expect(!report.failures.isEmpty)
        #expect(report.failures.contains { $0.contains("Textinhalt") })
    }

    // MARK: Seitenzahl-Mismatch → .pageCount

    @Test(.hangGuard) func seitenzahlMismatchErzeugtPageCountFinding() throws {
        let output = try PDFFixtures.textPDF(text: "HALLO", name: "pages")
        defer { try? FileManager.default.removeItem(at: output) }

        let policy = PDFValidator.Policy.pageOperation(expectedPageCount: 2)
        let report = PDFValidator.validate(outputURL: output, policy: policy)

        #expect(!report.isValid)
        let pageCountFindings = report.findings.filter { $0.kind == .pageCount }
        #expect(pageCountFindings.count == 1,
                "Genau ein pageCount-Finding erwartet: \(report.findings)")
        #expect(pageCountFindings.first?.severity == .error)
        #expect(report.failures.contains { $0.contains("Seitenzahl") })
    }

    // MARK: Geometrie → .geometry mit Seite

    @Test(.hangGuard) func geometrieAbweichungErzeugtGeometryFindingMitSeite()
        throws {
        // Zwei Seiten Referenz (dieselbe Seite zweimal über das Pages-Array),
        // eine Seite Output mit anderer MediaBox → Geometry-Verstoß Seite 1.
        let reference = try PDFFixtures.textPDF(text: "HALLO", name: "geo-ref")
        var b = RawPDFBuilder()
        let pages = b.reserveNumber()
        let font = b.addObject("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let content = b.addStream(
            dictionary: "",
            content: "BT /F1 24 Tf 72 700 Td (HALLO) Tj ET")
        let page = b.addObject(
            "<</Type/Page/Parent \(pages) 0 R/MediaBox[0 0 500 700]"
            + "/Resources<</Font<</F1 \(font) 0 R>>>>"
            + "/Contents \(content) 0 R>>")
        b.fill(pages, "<</Type/Pages/Kids[\(page) 0 R]/Count 1>>")
        let root = b.addObject("<</Type/Catalog/Pages \(pages) 0 R>>")
        let outputURL = PDFFixtures.fixtureURL(prefix: "geo-out-\(UUID().uuidString)")
        try b.build(rootObject: root).write(to: outputURL)
        defer {
            try? FileManager.default.removeItem(at: reference)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let report = PDFValidator.validate(outputURL: outputURL,
                                           referenceURL: reference,
                                           policy: Self.semanticPolicy)
        #expect(!report.isValid)
        let geometryFindings = report.findings.filter { $0.kind == .geometry }
        #expect(!geometryFindings.isEmpty)
        #expect(geometryFindings.contains { $0.pages == [1] },
                "Geometrie-Finding ohne Seite: \(geometryFindings.map(\.pages))")
    }

    // MARK: blockingFindings (§11.5 – nur error/fatal)

    @Test(.hangGuard) func nurErrorUndFatalSindBlockierend() {
        let findings = [
            ValidationFinding(kind: .text, severity: .error, pages: [3],
                              message: "a"),
            ValidationFinding(kind: .structure, severity: .fatal, pages: [],
                              message: "b"),
            ValidationFinding(kind: .size, severity: .warning, pages: [],
                              message: "c"),
            ValidationFinding(kind: .render, severity: .info, pages: [],
                              message: "d"),
        ]
        var report = PDFValidator.Report()
        report.findings = findings
        let blocking = report.blockingFindings
        #expect(blocking.count == 2)
        #expect(blocking.allSatisfy { $0.severity == .error || $0.severity == .fatal })
        // Severity-Ordnung: fatal > error > warning > info.
        #expect(ValidationFinding.Severity.fatal > .error)
        #expect(ValidationFinding.Severity.error > .warning)
        #expect(ValidationFinding.Severity.warning > .info)
    }

    // MARK: Codable-Rundlauf

    @Test func findingIstCodableUndSendable() throws {
        let finding = ValidationFinding(kind: .text, severity: .fatal,
                                        pages: [12],
                                        message: "Seite 12 Textinhalt: aa → bb")
        let data = try JSONEncoder().encode(finding)
        let decoded = try JSONDecoder().decode(ValidationFinding.self, from: data)
        #expect(decoded == finding)
        #expect(decoded.kind.rawValue == "text")
        #expect(decoded.pages == [12])
    }
}
