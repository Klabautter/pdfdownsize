import Testing
import CoreGraphics
@testable import PDFTools

/// Regression für den ImageClassifier-Bug (seit Initial-Commit, V2-3b-Fund):
/// `analyze` las nur die erste Pixelzeile (sampleSize*4 statt
/// sampleSize*sampleSize*4). Ein Bild mit weißer Top-Zeile und farbigem
/// Körper wurde fälschlich als Graustufe eingestuft → Farbverlust-Pfad.
@Suite struct ImageClassifierRegressionTests {

    @Test func bunteFlaecheMitWeisserTopZeileIstKeineGraustufe() {
        let size = 64
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Memory-Zeile 0 (CG oben) weiß, Rest kräftig rot/blau – der
        // Vor-Fix hätte genau diese eine Zeile gelesen.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: size - 8, width: size, height: 8))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size - 8))
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size - 8))
        let image = ctx.makeImage()!

        let stats = ImageClassifier.analyze(image)
        #expect(!stats.isGrayscale, "Farbiges Bild darf nicht als Graustufe gelten")
        #expect(stats.chromaMean > 10, "Chroma muss über der gesamten Fläche gemessen werden: \(stats.chromaMean)")
    }

    @Test func echteGraustufenFlaecheBleibtGraustufe() {
        let size = 64
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<size {
            let v = Double(y) / Double(size - 1)
            ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: 0, y: CGFloat(y), width: CGFloat(size), height: 1))
        }
        let image = ctx.makeImage()!
        let stats = ImageClassifier.analyze(image)
        #expect(stats.isGrayscale, "Verlauf aus Grauwerten bleibt Graustufe")
        #expect(stats.chromaMean < 4, "Chroma eines Grauverlaufs ist nahe 0: \(stats.chromaMean)")
    }
}
