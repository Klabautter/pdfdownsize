import Testing
import Foundation
@testable import PDFTools

/// Regressionstests für den Content-Stream-Scanner, der die sichtbare
/// Platzierungsgröße eines Bildes liefert (Grundlage der Effective DPI).
///
/// Anlass: `applyCM` las die sechs `cm`-Operanden rückwärts. Bei
/// `2000 0 0 2000 0 0 cm` wurde `a` der Wert von `f` (= 0) zugewiesen, die
/// Platzierungsbreite war 0 und damit die Effective DPI unbekannt. Die
/// gesamte DPI-Politik lief dadurch faktisch nie – sichtbar wurde das erst,
/// weil das Kantenlimit die Bilder trotzdem verkleinerte.
@Suite struct CMDoScannerTests {

    private func scan(_ content: String) -> [(name: String, placedW: Double, placedH: Double)] {
        var scanner = CMDoScanner(bytes: Array(content.utf8))
        return scanner.scan().map { ($0.name, $0.placedW, $0.placedH) }
    }

    /// OCR eingebetteter Fotos braucht die LAGE (2026-10-01): verschachtelte
    /// cm-Operatoren werden zur vollen CTM [a b c d e f] verrechnet.
    @Test func liefertLageUndSkalierungDerPlatzierung() {
        var scanner = CMDoScanner(bytes: Array("q 1 0 0 1 40 520 cm 280 0 0 210 0 0 cm /Im1 Do Q".utf8))
        let result = scanner.scan()
        #expect(result.count == 1)
        #expect(result.first?.transform == [280, 0, 0, 210, 40, 520])
    }

    @Test func readsPlacementFromSimpleTransform() {
        let results = scan("q 2000 0 0 2000 0 0 cm /Im1 Do Q")
        #expect(results.count == 1)
        #expect(results.first?.name == "Im1")
        #expect(abs((results.first?.placedW ?? 0) - 2000) < 0.01,
                "Breite \(results.first?.placedW ?? -1) statt 2000")
        #expect(abs((results.first?.placedH ?? 0) - 2000) < 0.01)
    }

    /// Nicht quadratisch: deckt die Verwechslung von Breite und Höhe auf,
    /// die ein symmetrischer Fall verstecken würde.
    @Test func distinguishesWidthFromHeight() {
        let results = scan("q 400 0 0 300 50 100 cm /Im0 Do Q")
        let placement = results.first
        #expect(abs((placement?.placedW ?? 0) - 400) < 0.01,
                "Breite \(placement?.placedW ?? -1) statt 400")
        #expect(abs((placement?.placedH ?? 0) - 300) < 0.01,
                "Höhe \(placement?.placedH ?? -1) statt 300")
    }

    /// Der reale Fall aus der PDFKit-Fixture: Clipping-Rechteck und ein
    /// `ri`-Operator vor der Transformation.
    @Test func ignoresPrecedingOperatorsAndClipPath() {
        let results = scan("q Q q 0 0 2000 2000 re W n /Perceptual ri "
            + "q 2000 0 0 2000 0 0 cm /Im1 Do Q Q")
        #expect(results.count == 1)
        let width = results.first?.placedW ?? -1
        #expect(abs(width - 2000) < 0.01,
                "Breite \(width) – Operanden des Clip-Rechtecks in der Matrix")
    }

    /// Ein Operator, der nicht auf einer festen Liste steht, muss trotzdem
    /// seine Operanden konsumieren.
    @Test func unknownOperatorDoesNotLeakOperands() {
        // `zz` gibt es nicht; seine Operanden dürfen den cm nicht verfälschen.
        let results = scan("q 1 2 3 zz 400 0 0 300 0 0 cm /Im0 Do Q")
        #expect(abs((results.first?.placedW ?? 0) - 400) < 0.01,
                "Breite \(results.first?.placedW ?? -1) statt 400")
    }

    @Test func nestedTransformsMultiply() {
        // Zwei verschachtelte Skalierungen: 2 × 200 = 400 pt Breite.
        let results = scan("q 2 0 0 2 0 0 cm q 200 0 0 100 0 0 cm /Im0 Do Q Q")
        #expect(abs((results.first?.placedW ?? 0) - 400) < 0.01,
                "Breite \(results.first?.placedW ?? -1) statt 400")
        #expect(abs((results.first?.placedH ?? 0) - 200) < 0.01)
    }

    @Test func graphicsStateIsRestoredAfterQ() {
        let results = scan("q 4 0 0 4 0 0 cm Q q 100 0 0 100 0 0 cm /Im0 Do Q")
        #expect(abs((results.first?.placedW ?? 0) - 100) < 0.01,
                "Zustand nach Q nicht wiederhergestellt: \(results.first?.placedW ?? -1)")
    }

    @Test func rotatedPlacementUsesVectorLength() {
        // 90°-Rotation mit Skalierung 300: beide Kanten messen 300 pt.
        let results = scan("q 0 300 -300 0 0 0 cm /Im0 Do Q")
        #expect(abs((results.first?.placedW ?? 0) - 300) < 0.01)
        #expect(abs((results.first?.placedH ?? 0) - 300) < 0.01)
    }

    @Test func multiplePlacementsOfDifferentImages() {
        let results = scan("q 100 0 0 100 0 0 cm /ImA Do Q "
            + "q 500 0 0 500 0 0 cm /ImB Do Q")
        #expect(results.count == 2)
        #expect(results.map(\.name) == ["ImA", "ImB"])
        #expect(abs(results[0].placedW - 100) < 0.01)
        #expect(abs(results[1].placedW - 500) < 0.01)
    }

    @Test func inlineImagesAreSkipped() {
        // Inline-Bilddaten dürfen nicht als Operatoren gelesen werden.
        let results = scan("BI /W 4 /H 4 ID xxxxq 9 9 9 cm EI "
            + "q 250 0 0 250 0 0 cm /Im0 Do Q")
        #expect(results.count == 1)
        #expect(abs((results.first?.placedW ?? 0) - 250) < 0.01,
                "Inline-Bilddaten haben den Scanner gestört")
    }

    /// End-to-End: Die korrigierte Platzierung muss auch als Effective DPI
    /// im Domänenmodell ankommen.
    @Test func effectiveDPIIsDerivedFromRealPlacement() throws {
        let url = try PDFFixtures.flateImagePDF(pixels: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        let core = try PDFCoreDocument(path: url.path)
        let resource = try #require(try core.imageResources().first)
        // Fixture: 400 px auf 100 pt platziert → 288 dpi.
        let dpi = try #require(resource.effectiveDPI, "Effective DPI unbekannt")
        #expect(abs(dpi - 288) < 1, "Effective DPI \(dpi) statt 288")
    }
}
