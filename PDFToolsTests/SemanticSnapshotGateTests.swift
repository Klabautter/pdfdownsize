import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Masterplan Finding 6 – Quality Gate des zentralen Snapshots.
///
/// Gate-Kriterien:
///   □ Snapshot deterministisch
///   □ alle Golden-Eigenschaften modelliert
///   □ Snapshot kann serialisiert werden
@Suite struct SemanticSnapshotGateTests {

    // MARK: - Determinismus

    @Test func snapshotIsDeterministicAcrossBackends() throws {
        let url = try PDFFixtures.multiAnnotationPDF()
        for backend in [PDFSemanticSnapshot.Backend.pdfKit, .libQPDF, .merged] {
            let a = try PDFSemanticSnapshot.capture(url, backend: backend)
            let b = try PDFSemanticSnapshot.capture(url, backend: backend)
            #expect(a == b, "Snapshot nicht deterministisch für \(backend.rawValue)")
        }
    }

    @Test func snapshotIsSerializableAndRoundtrips() throws {
        let url = try PDFFixtures.outlineLinkPDF()
        let snapshot = try PDFSemanticSnapshot.capture(url)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let decoded = try JSONDecoder().decode(PDFSemanticSnapshot.self, from: data)

        #expect(decoded == snapshot, "Codable-Roundtrip verändert den Snapshot")
        // Zweimaliges Kodieren muss byte-identisch sein (Report-Stabilität).
        #expect(try encoder.encode(decoded) == data)
    }

    // MARK: - Vollständigkeit der Golden-Eigenschaften

    @Test func cropBoxIsCapturedCompletely() throws {
        // Verschobener CropBox-Ursprung: Breite/Höhe allein würden das
        // nicht sehen – deshalb prüft der Snapshot alle vier Koordinaten.
        let url = try PDFFixtures.croppedPagePDF()
        let snapshot = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)
        let page = try #require(snapshot.pages.first)

        #expect(page.cropBox.count == 4)
        #expect(page.cropBox != page.mediaBox, "CropBox-Fixture ohne Abweichung")
        #expect(page.cropBox[0] > page.mediaBox[0], "CropBox-Ursprung nicht erfasst")
    }

    @Test func namedDestinationsAreCapturedWithTargets() throws {
        let url = try PDFFixtures.namedDestinationPDF()
        let snapshot = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)

        #expect(!snapshot.navigation.namedDestinations.isEmpty,
                "Named Destinations nicht erfasst")
        let dest = try #require(
            snapshot.navigation.namedDestinations.first { $0.name == "kapitel2" })
        #expect(dest.targetPage == 1, "Named Destination zeigt auf falsche Seite")
    }

    @Test func pageLabelsAreCaptured() throws {
        let url = try PDFFixtures.pageLabelPDF()
        let snapshot = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)

        #expect(snapshot.document.hasPageLabels)
        #expect(!snapshot.document.pageLabelRanges.isEmpty, "Label-Ranges leer")
    }

    @Test func attachmentsAreCapturedWithNames() throws {
        let url = try PDFFixtures.attachmentPDF()
        let snapshot = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)

        #expect(snapshot.attachments.count == 1)
        #expect(snapshot.attachments.first?.name.isEmpty == false,
                "Attachment ohne Namen erfasst")
    }

    @Test func formFieldValuesAndHierarchyAreCaptured() throws {
        let url = try PDFFixtures.formHierarchyPDF()
        let snapshot = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)

        let names = snapshot.form.fields.map(\.name)
        #expect(names.contains("adresse.strasse"),
                "Voll qualifizierter Feldname fehlt: \(names)")
        let field = try #require(
            snapshot.form.fields.first { $0.name == "adresse.strasse" })
        #expect(field.value == "Hauptstrasse 1", "Feldwert nicht erfasst")
        #expect(field.type == "Tx")
    }

    /// Regression: PDF-Textstrings sind häufig UTF-16BE und enthalten dann
    /// NUL-Bytes. Die NUL-terminierte Bridge-Listen-API schnitt sie nach dem
    /// BOM ab – aus 199 Formularfeldern eines IRS-Formulars wurden 0.
    @Test func utf16FormFieldsSurviveTheBridge() throws {
        let url = try PDFFixtures.utf16FormFieldPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)
        let field = try #require(snapshot.form.fields.first,
                                 "UTF-16-Feld ging verloren")
        #expect(field.name == "Straße", "Feldname verstümmelt: \(field.name)")
        #expect(field.value == "Grüße aus München",
                "Feldwert verstümmelt: \(field.value)")
    }

    @Test func internalDestinationsAreCaptured() throws {
        let url = try PDFFixtures.outlineLinkPDF()
        let snapshot = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)

        #expect(!snapshot.navigation.internalLinkTargets.isEmpty,
                "Interne Link-Ziele nicht erfasst")
        #expect(!snapshot.navigation.outline.isEmpty, "Outline nicht erfasst")
        // Outline-Einträge müssen ihr Ziel kennen, nicht nur ihr Label.
        #expect(snapshot.navigation.outline.allSatisfy { $0.targetPage >= 0 },
                "Outline-Ziel unauflösbar: \(snapshot.navigation.outline)")
    }

    @Test func outlineHierarchyDepthIsCaptured() throws {
        let url = try PDFFixtures.nestedOutlinePDF()
        let snapshot = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)

        #expect(snapshot.navigation.outlineDepth >= 2,
                "Verschachtelte Outline nicht als Hierarchie erfasst")
        #expect(snapshot.navigation.outline.contains { $0.depth == 1 })
    }

    @Test func signaturesAreCaptured() throws {
        let url = try PDFFixtures.signatureFieldPDF()
        let snapshot = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)

        #expect(snapshot.form.signatures.count == 1,
                "Signaturfeld nicht erfasst: \(snapshot.form.signatures)")
        #expect(snapshot.form.signatures.first?.fieldName == "sig1")
    }

    // MARK: - Diagnosen

    @Test func identicalDocumentsProduceNoDifferences() throws {
        let url = try PDFFixtures.multiAnnotationPDF()
        let a = try PDFSemanticSnapshot.capture(url)
        let b = try PDFSemanticSnapshot.capture(url)
        #expect(PDFSemanticSnapshot.differences(a, b).isEmpty)
    }

    @Test func lostCropBoxIsReportedAsCritical() throws {
        let url = try PDFFixtures.croppedPagePDF()
        var before = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)
        var after = before
        after.pages[0].cropBox = after.pages[0].mediaBox

        let diffs = PDFSemanticSnapshot.differences(before, after)
        let cropDiff = try #require(diffs.first { $0.field.contains("CropBox") })
        #expect(cropDiff.severity == .critical)

        // Gegenprobe: unverändert = keine Meldung.
        before.pages[0].cropBox = after.pages[0].cropBox
        #expect(PDFSemanticSnapshot.differences(before, after).isEmpty)
    }

    @Test func changedFormValueIsReported() throws {
        let url = try PDFFixtures.formHierarchyPDF()
        let before = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)
        var after = before
        let index = try #require(
            after.form.fields.firstIndex { $0.name == "adresse.strasse" })
        after.form.fields[index].value = "Etwas anderes"

        let diffs = PDFSemanticSnapshot.differences(before, after)
        #expect(diffs.contains { $0.field.contains("Feldwert") && $0.severity == .high })
    }

    @Test func lostAttachmentIsReported() throws {
        let url = try PDFFixtures.attachmentPDF()
        let before = try PDFSemanticSnapshot.capture(url, backend: .libQPDF)
        var after = before
        after.attachments = []

        #expect(PDFSemanticSnapshot.differences(before, after)
            .contains { $0.field == "Attachments" })
    }

    @Test func textCorruptionIsDetectedByFingerprint() throws {
        let url = try PDFFixtures.vectorTextPDF(lines: 10)
        let before = try PDFSemanticSnapshot.capture(url, backend: .pdfKit)
        var after = before
        // Gleiche Zeichenzahl, anderer Inhalt – nur der Fingerprint sieht das.
        after.pages[0].textFingerprint = "deadbeef"

        let diffs = PDFSemanticSnapshot.differences(before, after)
        #expect(diffs.contains { $0.field.contains("Textinhalt") },
                "Textverfälschung bei gleicher Zeichenzahl nicht erkannt")
    }
}
