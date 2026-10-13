import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Phase V2-8 (Masterplan §14.5) – ICC-Dedup: byteidentische /ICCBased-
/// Farbraumprofile, die der Content-Hash-Dedup wegen der Dict-Whitelist
/// bisher NICHT zusammenführte.
///
/// Festgenagelt werden der /N-/Range-/Alternate-Vertrag:
///   1. Identische Profilbytes + identischer Vertrag → Merge (die zweite
///      /ColorSpace-Referenz zeigt danach auf EIN Profilobjekt).
///   2. Verschiedene Profilbytes → kein Merge.
///   3. Verschiedene /N (Komponentenzahl) → kein Merge.
///   4. Verschiedenes /Alternate (Fallback-Farbraum) → kein Merge.
/// Jeder Merge ist verlustfrei; die verwaisten Objekte verwirft der Writer.
@Suite struct ICCDedupTests {

    // MARK: - Helfer

    static func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iccdedup-\(label)-\(UUID().uuidString).pdf")
    }

    // MARK: 1 – Merge bei identischem Vertrag

    @Test(.hangGuard) func byteidentischeProfileWerdenGemergt() throws {
        let url = try PDFFixtures.duplicateICCProfilesPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)

        let stats = try doc.deduplicate()
        #expect(stats.mergedStreams == 1,
                "Genau das zweite Profilobjekt muss absorbiert werden: \(stats)")
        #expect(stats.estimatedBytesSaved > 0,
                "Ein sRGB-Profil trägt messbare Rohbytes")

        // Die Referenzen zeigen auf EIN Objekt; Struktur bleibt grün.
        let out = Self.tempURL("merged")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        try PDFCoreDocument(path: out.path).check()
        let render = try RenderDifferential.compare(sourceURL: url,
                                                    outputURL: out)
        #expect(render.allSatisfy { $0.changedAreaRatio == 0 },
                "Farbwelt darf sich nicht ändern: \(render.map(\.changedAreaRatio))")
    }

    // MARK: 2–4 – Vertrag verhindert den Merge

    @Test(.hangGuard) func verschiedeneProfilbytesBleibenGetrennt() throws {
        let url = try PDFFixtures.duplicateICCProfilesPDF(identicalBytes: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.deduplicate()
        #expect(stats.mergedStreams == 0,
                "Verschiedene Profilbytes sind verschiedene Profile: \(stats)")
    }

    @Test(.hangGuard) func verschiedeneKomponentenzahlVerhindertMerge()
        throws {
        // /N 3 gegen /N 4: gleiche Bytes, aber der Komponentenvertrag des
        // Profils unterscheidet sich – austauschbar wären sie nie.
        let url = try PDFFixtures.duplicateICCProfilesPDF(secondN: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.deduplicate()
        #expect(stats.mergedStreams == 0,
                "/N-Vertrag verletzt – kein Merge: \(stats)")
    }

    @Test(.hangGuard) func verschiedenesAlternateVerhindertMerge() throws {
        // /Alternate ist der Fallback nicht-ICC-fähiger Leser – ein Merge
        // würde die Fallback-Farbwelt der Duplikate still umschreiben.
        let url = try PDFFixtures.duplicateICCProfilesPDF(
            secondAlternate: "/DeviceCMYK")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let stats = try doc.deduplicate()
        #expect(stats.mergedStreams == 0,
                "/Alternate-Vertrag verletzt – kein Merge: \(stats)")
    }
}
