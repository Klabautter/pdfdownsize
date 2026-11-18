import Testing
import CoreGraphics
@testable import PDFTools

/// Masterplan A1, „Zuerst“ Punkt 3: Fehlerwege der neuen Grau/Farbe-
/// Entscheidung, vor der Umsetzung aufgeschrieben. Die E2E-Prüfung
/// (`ColorInkSurvivesCompressionE2ETests`) deckt nur die Richtung „Farbe
/// bleibt“ ab; diese Fälle prüfen die Gegenrichtung, die dort keiner sieht:
///
///  1. Farbsaum an schwarzer Schrift (Scanner-Fehlregistrierung) darf weiter
///     als grau gelten – sonst bleibt jeder Schwarzweiß-Scan in Farbe.
///  2. Vereinzelte Farbpixel aus JPEG-Rauschen dürfen nicht „farbig“ machen.
///  3. Vergilbtes Papier war schon bisher farbig (Mittelwert ≥ 1,5) und
///     bleibt es – die Entscheidung darf hier nichts ändern.
///  4. Gegenprobe: dünne Unterschrift und ein Stempel in einer Ecke sind
///     farbig, obwohl der Mittelwert unter 1,5 liegt.
struct ChromaCensusTests {

    static let w = 1000, h = 1400

    /// Weißes Blatt, schwarze Textzeilen; `extra` malt zusätzlich hinein.
    static func page(paper: (UInt8, UInt8, UInt8) = (250, 250, 250),
                     extra: (inout [UInt8]) -> Void = { _ in }) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            px[i * 4] = paper.0; px[i * 4 + 1] = paper.1; px[i * 4 + 2] = paper.2
        }
        // 30 Textzeilen à 6 px Höhe als schwarze Balken mit Lücken.
        for line in 0..<30 {
            let y0 = 100 + line * 40
            for y in y0..<(y0 + 6) {
                for x in stride(from: 100, to: 900, by: 1) where (x / 7) % 3 != 0 {
                    let o = (y * w + x) * 4
                    px[o] = 10; px[o + 1] = 10; px[o + 2] = 10
                }
            }
        }
        extra(&px)
        return px
    }

    static func set(_ px: inout [UInt8], _ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        guard x >= 0, y >= 0, x < w, y < h else { return }
        let o = (y * w + x) * 4
        px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2
    }

    @Test func farbsaumAnSchwarzerSchriftBleibtGrau() {
        // Rot links, Cyan rechts neben jedem Balken, je 1 px breit.
        let px = Self.page { px in
            for line in 0..<30 {
                let y0 = 100 + line * 40
                for y in y0..<(y0 + 6) {
                    Self.set(&px, 99, y, (200, 60, 60))
                    Self.set(&px, 900, y, (60, 200, 200))
                }
            }
        }
        let census = ChromaCensus.measure(rgba: px, width: Self.w, height: Self.h)
        #expect(census.isNeutral, "Farbsaum kippt die Seite auf farbig: \(census)")
    }

    @Test func jpegRauschenBleibtGrau() {
        // 200 einzelne Farbpixel, über die Seite verstreut (deterministisch).
        let px = Self.page { px in
            for k in 0..<200 {
                Self.set(&px, (k * 7919) % Self.w, (k * 104_729) % Self.h, (230, 120, 120))
            }
        }
        let census = ChromaCensus.measure(rgba: px, width: Self.w, height: Self.h)
        #expect(census.isNeutral, "Einzelne Rauschpixel kippen die Seite: \(census)")
    }

    @Test func vergilbtesPapierBleibtFarbig() {
        let px = Self.page(paper: (242, 232, 205))
        let census = ChromaCensus.measure(rgba: px, width: Self.w, height: Self.h)
        #expect(census.meanChroma >= ChromaCensus.maxNeutralMeanChroma)
        #expect(!census.isNeutral)
    }

    @Test func duenneUnterschriftIstFarbig() {
        // Blaue Linie, 3 px stark, 600 px lang – unter 0,2 % der Fläche.
        let px = Self.page { px in
            for x in 200..<800 {
                let y = 1300 + Int(20 * sin(Double(x) / 30))
                for dy in 0..<3 { Self.set(&px, x, y + dy, (30, 60, 190)) }
            }
        }
        let census = ChromaCensus.measure(rgba: px, width: Self.w, height: Self.h)
        #expect(census.meanChroma < ChromaCensus.maxNeutralMeanChroma,
                "Fixture prüft den alten blinden Fleck nicht mehr: \(census)")
        #expect(!census.isNeutral, "Unterschrift wird als grau eingestuft: \(census)")
    }

    @Test func stempelInDerEckeIstFarbig() {
        // Roter Ring, Durchmesser 50 px, Strich 2 px.
        let px = Self.page { px in
            for a in 0..<720 {
                let t = Double(a) * .pi / 360
                for r in 24...25 {
                    Self.set(&px, 940 + Int(Double(r) * cos(t)), 60 + Int(Double(r) * sin(t)), (200, 30, 40))
                }
            }
        }
        let census = ChromaCensus.measure(rgba: px, width: Self.w, height: Self.h)
        #expect(census.meanChroma < ChromaCensus.maxNeutralMeanChroma)
        #expect(!census.isNeutral, "Stempel wird als grau eingestuft: \(census)")
    }
}
