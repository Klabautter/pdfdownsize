import Testing
import Foundation
@testable import PDFTools

/// Was mit einem Bild passiert, hängt an seiner TATSÄCHLICHEN Auflösung.
///
/// Ein Dokument pauschal auf eine Zielauflösung zu bringen wäre falsch in
/// beide Richtungen: Ein 600-dpi-Scan spart enorm, ein Bild, das schon in
/// Zielauflösung vorliegt, verlöre nur Qualität ohne Gegenwert. Diese Suite
/// hält beide Enden fest.
@Suite struct ResolutionPolicyTests {

    /// Wie der Planner ein Bild bei gegebener Platzierungsgröße behandelt.
    /// Die Seite ist immer 612 pt breit; über die Bildbreite in Pixeln
    /// stellen wir die effektive Auflösung ein.
    static func outcome(pixelWidth: Int, options: CompressionOptions)
        throws -> (transformed: Bool, reason: String) {
        let url = try PDFFixtures.photoAtWidth(pixelWidth)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try PDFCoreDocument(path: url.path)
        let res = try doc.imageResources()
        try #require(res.count == 1, "Fixture trägt \(res.count) Bilder")
        let planned = try CompressionPlanner.plan(
            resources: res, options: options, documentID: "res",
            documentBytes: Int(Compressor.fileSize(of: url)),
            pixels: LibQPDFPixelSource(document: doc))
        guard let action = planned.plan.actions.first else {
            return (false, "keine Aktion")
        }
        if case .keep(_, let reason, _) = action {
            return (false, reason.explanation)
        }
        return (true, "umgewandelt")
    }

    /// Hohe Auflösung allein darf den Sicherheits-Floor nicht aushebeln.
    @Test(.hangGuard) func farAboveTargetIsResampledOrSafelyKept() throws {
        // 612 pt Seitenbreite = 8,5 Zoll. 5100 px ≙ 600 dpi.
        let r = try Self.outcome(pixelWidth: 5100, options: .smart)
        #expect(r.transformed || r.reason.contains("Katastrophen-Floor"),
                "600 dpi bleiben ohne Qualitätsbegründung unangetastet: \(r.reason)")
    }

    /// Bereits in Zielauflösung: Finger weg.
    ///
    /// Ein Bild neu zu kodieren, das ohnehin passt, kostet Qualität und
    /// bringt nichts – bei JPEG-Quellen sogar doppelt, weil sich der
    /// Kodierungsverlust aufaddiert.
    @Test(.hangGuard) func atTargetIsLeftAlone() throws {
        // 8,5 Zoll × Ziel-DPI – exakt die Zielauflösung von Smart (die Zahl
        // kommt aus der Konfiguration, nicht aus einer Konstanten).
        let r = try Self.outcome(pixelWidth: Int(8.5 * ImageCompressionOptions.smart.targetDPI),
                                 options: .smart)
        #expect(!r.transformed, "Bild in Zielauflösung wurde angefasst")
    }

    /// Knapp darüber: Die Toleranz von 15 % verhindert Eingriffe für
    /// Kleinigkeiten.
    @Test(.hangGuard) func slightlyAboveTargetIsLeftAlone() throws {
        // 13 % über dem Ziel – innerhalb der Toleranz von 15 %.
        let r = try Self.outcome(pixelWidth: Int(8.5 * ImageCompressionOptions.smart.targetDPI * 1.13),
                                 options: .smart)
        #expect(!r.transformed, "13 % über dem Ziel wurde angefasst: \(r.reason)")
    }

    /// Unterhalb der Zielauflösung wird niemals vergrößert.
    @Test(.hangGuard) func belowTargetIsNeverUpscaled() throws {
        // 850 px ≙ 100 dpi.
        let r = try Self.outcome(pixelWidth: 850, options: .smart)
        #expect(!r.transformed, "Ein zu kleines Bild wurde verändert: \(r.reason)")
    }

    /// Die Stufe entscheidet, ab wann eingegriffen wird – nicht die Datei.
    ///
    /// Dasselbe Bild mit 300 dpi ist für „Qualität" genau richtig und für
    /// „Klein" viel zu fein.
    @Test(.hangGuard) func theStageDecidesTheThreshold() throws {
        // 2550 px ≙ 300 dpi.
        let forPrint = try Self.outcome(pixelWidth: 2550,
                                        options: CompressionOptions(image: .quality))
        #expect(!forPrint.transformed,
                "Qualität rechnet ein 300-dpi-Bild herunter: \(forPrint.reason)")

        let forMail = try Self.outcome(pixelWidth: 2550,
                                       options: CompressionOptions(image: .small))
        #expect(forMail.transformed,
                "Klein lässt ein 300-dpi-Bild unangetastet: \(forMail.reason)")
    }

    /// Und dieselbe Regel gilt für JEDE Einstellung, auch selbstgewählte.
    ///
    /// Wer im Custom-Bereich 200 dpi einstellt, erwartet dasselbe Verhalten:
    /// darüber wird gerechnet, darunter nicht, und dazwischen liegt die
    /// Toleranz. Eine Regel, die nur für die Voreinstellungen gilt, wäre
    /// keine.
    @Test(.hangGuard, arguments: [100.0, 200.0, 400.0])
    func theRuleHoldsForEveryChosenResolution(targetDPI: Double) throws {
        let options = CompressionPresetFactory.custom(
            dpi: targetDPI, quality: 0.85, maxPixelEdge: 6000)

        // Genau in Zielauflösung: unangetastet.
        let atTarget = Int((targetDPI * 8.5).rounded())
        let same = try Self.outcome(pixelWidth: atTarget, options: options)
        #expect(!same.transformed, """
            Bei \(Int(targetDPI)) dpi Ziel wurde ein Bild in genau dieser \
            Auflösung angefasst: \(same.reason)
            """)

        // Deutlich darunter: niemals vergrössern.
        let below = try Self.outcome(pixelWidth: max(200, atTarget / 2),
                                     options: options)
        #expect(!below.transformed, """
            Bei \(Int(targetDPI)) dpi Ziel wurde ein zu kleines Bild \
            verändert: \(below.reason)
            """)

        // Deutlich darüber: die Auflösung erlaubt Kandidaten, aber der
        // Katastrophen-Floor darf sie nach der Qualitätsprüfung ablehnen.
        //
        // Der Faktor ist bewusst zwei und nicht drei: Bei 400 dpi Ziel wären
        // das 10200 × 7650 Bildpunkte, also 78 Megapixel – die lehnt die
        // Engine aus Speichergründen ab, und das zu Recht. Ein Testfall, den
        // kein Dokument enthält, prüft nichts über die Auflösungsregel.
        let above = try Self.outcome(pixelWidth: atTarget * 2, options: options)
        #expect(above.transformed || above.reason.contains("Katastrophen-Floor"), """
            Bei \(Int(targetDPI)) dpi Ziel blieb ein doppelt zu feines Bild \
            ohne Qualitätsbegründung liegen: \(above.reason)
            """)
    }
}
