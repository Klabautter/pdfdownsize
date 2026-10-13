import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

// macOS-Raster: 824-pt-Squircle in 1024er Fläche, Eckradius ≈ 185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Schatten unter dem Körper (wie Systemicons)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: c(0, 0, 0, 0.28))
ctx.addPath(squircle); ctx.setFillColor(c(0.2, 0.4, 0.95)); ctx.fillPath()
ctx.restoreGState()

// Hintergrund: tiefes Blau, oben heller
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [c(0.36, 0.62, 1.0), c(0.12, 0.33, 0.92)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// weicher Glanz oben
let gloss = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.22), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(gloss, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])

// Blatt
let pageW: CGFloat = 380, pageH: CGFloat = 500
let page = CGRect(x: 512 - pageW / 2, y: 512 - pageH / 2 - 6, width: pageW, height: pageH)
let fold: CGFloat = 96
let pagePath = CGMutablePath()
pagePath.move(to: CGPoint(x: page.minX + 26, y: page.minY))
pagePath.addLine(to: CGPoint(x: page.maxX - 26, y: page.minY))
pagePath.addQuadCurve(to: CGPoint(x: page.maxX, y: page.minY + 26), control: CGPoint(x: page.maxX, y: page.minY))
pagePath.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
pagePath.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
pagePath.addLine(to: CGPoint(x: page.minX + 26, y: page.maxY))
pagePath.addQuadCurve(to: CGPoint(x: page.minX, y: page.maxY - 26), control: CGPoint(x: page.minX, y: page.maxY))
pagePath.addLine(to: CGPoint(x: page.minX, y: page.minY + 26))
pagePath.addQuadCurve(to: CGPoint(x: page.minX + 26, y: page.minY), control: CGPoint(x: page.minX, y: page.minY))
pagePath.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: c(0.02, 0.08, 0.35, 0.45))
ctx.addPath(pagePath); ctx.setFillColor(c(1, 1, 1)); ctx.fillPath()
ctx.restoreGState()
// Eselsohr
let foldPath = CGMutablePath()
foldPath.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
foldPath.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 18))
foldPath.addQuadCurve(to: CGPoint(x: page.maxX - fold + 18, y: page.maxY - fold), control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
foldPath.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
foldPath.closeSubpath()
ctx.addPath(foldPath); ctx.setFillColor(c(0.80, 0.86, 0.97)); ctx.fillPath()

// Textzeilen
ctx.setFillColor(c(0.78, 0.83, 0.92))
let lines: [(CGFloat, CGFloat)] = [(0.62, 1), (0.50, 1), (0.38, 0.82), (0.26, 1), (0.14, 0.6)]
for (i, (fy, fw)) in lines.enumerated() {
    let w = (pageW - 110) * fw * (i == 0 ? 0.7 : 1)
    let r = CGRect(x: page.minX + 55, y: page.minY + pageH * fy, width: w, height: 22)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 11, cornerHeight: 11, transform: nil)); ctx.fillPath()
}
// Akzentblock (Bild) oben links
let img = CGRect(x: page.minX + 55, y: page.minY + pageH * 0.74, width: 120, height: 70)
ctx.addPath(CGPath(roundedRect: img, cornerWidth: 12, cornerHeight: 12, transform: nil))
ctx.setFillColor(c(0.24, 0.50, 1.0)); ctx.fillPath()

// Pfeile, die von links und rechts auf das Blatt drücken
func chevron(tipX: CGFloat, dir: CGFloat) {
    let p = CGMutablePath()
    let y: CGFloat = 512 - 6, h: CGFloat = 70, d: CGFloat = 52
    p.move(to: CGPoint(x: tipX - dir * d, y: y + h))
    p.addLine(to: CGPoint(x: tipX, y: y))
    p.addLine(to: CGPoint(x: tipX - dir * d, y: y - h))
    ctx.addPath(p)
}
ctx.setStrokeColor(c(1, 1, 1, 0.95)); ctx.setLineWidth(30); ctx.setLineCap(.round); ctx.setLineJoin(.round)
chevron(tipX: page.minX - 34, dir: 1); ctx.strokePath()
chevron(tipX: page.maxX + 34, dir: -1); ctx.strokePath()
ctx.restoreGState()

// Feine Innenkante
ctx.addPath(squircle); ctx.setStrokeColor(c(1, 1, 1, 0.18)); ctx.setLineWidth(3); ctx.strokePath()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: "icon_1024x1024.png")
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
