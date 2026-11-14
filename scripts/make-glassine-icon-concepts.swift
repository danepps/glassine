// make-glassine-icon-concepts.swift — exploratory Glassine app-icon directions.
//
// Six light/dark concept pairs plus a review board. Like make-icon-concepts.swift
// these are deliberately outside the shipping icon pipeline until a direction is
// picked; nothing here writes into Support/.
//
// Usage: swift scripts/make-glassine-icon-concepts.swift <output-directory>
//
// Every direction is built from the same idea: glassine is translucent paper, so
// the mark is overlapping semi-transparent sheets whose intersections read denser
// than either sheet alone. That also happens to be what View > Window Opacity does
// to a page, so the icon and the feature describe each other.
//
// Note on the dark appearance. Folio's icon used black paper with white type in
// dark mode, which is the right call for a page metaphor. It is the wrong call
// here: a dark translucent sheet on a dark ground has nothing to be translucent
// against, and the overlaps vanish. So dark mode keeps the sheets light and drops
// their alpha instead — frosted panes lit from behind. If that reads as too much
// of a departure, the alternative is to invert and accept a quieter overlap.

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: a)
}

func context(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

func superellipse(in rect: CGRect, exponent n: CGFloat = 5.6) -> CGPath {
    let path = CGMutablePath()
    let p = 2 / n
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(
            x: rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), p),
            y: rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), p)
        )
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func fill(_ path: CGPath, _ color: CGColor, in ctx: CGContext) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat, in ctx: CGContext) {
    ctx.addPath(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.strokePath()
}

func pill(_ rect: CGRect, color: CGColor, in ctx: CGContext) {
    fill(CGPath(roundedRect: rect, cornerWidth: rect.height / 2,
                cornerHeight: rect.height / 2, transform: nil), color, in: ctx)
}

func sheetPath(_ rect: CGRect, radius: CGFloat = 26) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func transformed(_ path: CGPath, around center: CGPoint, angle: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: angle)
        .translatedBy(x: -center.x, y: -center.y)
    return path.copy(using: &t)!
}

func background(in ctx: CGContext, top: CGColor, bottom: CGColor) {
    let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let shape = superellipse(in: bounds)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [top, bottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 220, y: canvas),
                           end: CGPoint(x: 800, y: 0), options: [])
    ctx.restoreGState()

    stroke(shape, rgb(255, 255, 255, 0.10), width: 5, in: ctx)
}

func dropShadow(_ path: CGPath, _ color: CGColor, in ctx: CGContext,
                blur: CGFloat = 34, alpha: CGFloat = 0.38) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: blur,
                  color: rgb(0, 0, 0, alpha))
    fill(path, color, in: ctx)
    ctx.restoreGState()
}

// Body text suggested as pills, drawn top-down inside a sheet.
func rules(in rect: CGRect, count: Int, color: CGColor, in ctx: CGContext,
           heading: Bool = true) {
    let inset = rect.width * 0.15
    let width = rect.width - inset * 2
    let thickness = rect.height * 0.028
    let gap = rect.height * 0.068
    var y = rect.maxY - rect.height * 0.20

    if heading {
        pill(CGRect(x: rect.minX + inset, y: y, width: width * 0.62,
                    height: thickness * 1.9), color: color, in: ctx)
        y -= gap * 1.45
    }
    for i in 0..<count {
        guard y > rect.minY + inset else { break }
        let w = (i == count - 1) ? width * 0.55 : width
        pill(CGRect(x: rect.minX + inset, y: y, width: w, height: thickness),
             color: color, in: ctx)
        y -= gap
    }
}

struct Palette {
    let bgTop: CGColor
    let bgBottom: CGColor
    let sheetSolid: CGColor   // the backmost, near-opaque sheet
    let sheetGlass: CGColor   // a translucent sheet laid over it
    let rule: CGColor         // type on the solid sheet
    let ruleGlass: CGColor    // type on a translucent sheet
    let edge: CGColor         // the lit edge of a glass sheet
}

func palette(dark: Bool) -> Palette {
    dark
        ? Palette(bgTop: rgb(48, 56, 67), bgBottom: rgb(15, 18, 23),
                  sheetSolid: rgb(214, 224, 234, 0.88),
                  sheetGlass: rgb(220, 230, 240, 0.34),
                  rule: rgb(20, 26, 34, 0.62),
                  ruleGlass: rgb(255, 255, 255, 0.50),
                  edge: rgb(255, 255, 255, 0.42))
        : Palette(bgTop: rgb(128, 155, 179), bgBottom: rgb(54, 82, 108),
                  sheetSolid: rgb(255, 255, 255),
                  sheetGlass: rgb(255, 255, 255, 0.52),
                  rule: rgb(52, 78, 104, 0.58),
                  ruleGlass: rgb(38, 60, 84, 0.52),
                  edge: rgb(255, 255, 255, 0.85))
}

// 1. Two sheets offset on the diagonal; the upper one is glassine, so the lower
//    sheet's type stays readable straight through the overlap.
func drawInterleaf(dark: Bool) -> CGImage {
    let p = palette(dark: dark)
    let ctx = context(width: Int(canvas), height: Int(canvas))
    background(in: ctx, top: p.bgTop, bottom: p.bgBottom)

    let back = CGRect(x: 244, y: 296, width: 372, height: 496)
    let front = CGRect(x: 408, y: 232, width: 372, height: 496)

    dropShadow(sheetPath(back), p.sheetSolid, in: ctx)
    rules(in: back, count: 5, color: p.rule, in: ctx)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30,
                  color: rgb(0, 0, 0, 0.30))
    fill(sheetPath(front), p.sheetGlass, in: ctx)
    ctx.restoreGState()
    stroke(sheetPath(front), p.edge, width: 4, in: ctx)
    rules(in: front, count: 5, color: p.ruleGlass, in: ctx)

    return ctx.makeImage()!
}

// 2. Three sheets fanned from a common pivot, each one translucent, so density
//    builds toward the middle of the stack.
func drawSheaf(dark: Bool) -> CGImage {
    let p = palette(dark: dark)
    let ctx = context(width: Int(canvas), height: Int(canvas))
    background(in: ctx, top: p.bgTop, bottom: p.bgBottom)

    let base = CGRect(x: 322, y: 262, width: 380, height: 500)
    let pivot = CGPoint(x: 512, y: 300)

    for (index, angle) in [-0.17, 0.0, 0.17].enumerated() {
        let path = transformed(sheetPath(base), around: pivot, angle: CGFloat(angle))
        let color = index == 1 ? p.sheetSolid : p.sheetGlass
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 26,
                      color: rgb(0, 0, 0, 0.26))
        fill(path, color, in: ctx)
        ctx.restoreGState()
        stroke(path, p.edge, width: 3.5, in: ctx)
    }
    rules(in: base, count: 5, color: p.rule, in: ctx)

    return ctx.makeImage()!
}

// 3. A full page with a band of glassine drawn across its lower half — the
//    literal picture of View > Window Opacity.
func drawVeil(dark: Bool) -> CGImage {
    let p = palette(dark: dark)
    let ctx = context(width: Int(canvas), height: Int(canvas))
    background(in: ctx, top: p.bgTop, bottom: p.bgBottom)

    let page = CGRect(x: 296, y: 236, width: 432, height: 560)
    dropShadow(sheetPath(page), p.sheetSolid, in: ctx)
    rules(in: page, count: 8, color: p.rule, in: ctx)

    let band = CGRect(x: 232, y: 300, width: 560, height: 226)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                  color: rgb(0, 0, 0, 0.24))
    fill(sheetPath(band, radius: 22), p.sheetGlass, in: ctx)
    ctx.restoreGState()
    stroke(sheetPath(band, radius: 22), p.edge, width: 4, in: ctx)

    return ctx.makeImage()!
}

// 4. One sheet, top-right corner folded back. The flap is translucent, so the
//    page's own type shows through it — the quietest of the six.
func drawFold(dark: Bool) -> CGImage {
    let p = palette(dark: dark)
    let ctx = context(width: Int(canvas), height: Int(canvas))
    background(in: ctx, top: p.bgTop, bottom: p.bgBottom)

    let page = CGRect(x: 288, y: 232, width: 448, height: 568)
    dropShadow(sheetPath(page), p.sheetSolid, in: ctx)
    rules(in: page, count: 7, color: p.rule, in: ctx)

    let size: CGFloat = 208
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: page.maxX - size, y: page.maxY))
    flap.addLine(to: CGPoint(x: page.maxX, y: page.maxY - size))
    flap.addLine(to: CGPoint(x: page.maxX - size, y: page.maxY - size))
    flap.closeSubpath()

    fill(flap, p.sheetGlass, in: ctx)
    stroke(flap, p.edge, width: 4, in: ctx)

    return ctx.makeImage()!
}

// 5. Two sheets crossed at a right angle. The intersection is the densest thing
//    in the mark, which is what keeps it readable at 32 px.
func drawCrossfold(dark: Bool) -> CGImage {
    let p = palette(dark: dark)
    let ctx = context(width: Int(canvas), height: Int(canvas))
    background(in: ctx, top: p.bgTop, bottom: p.bgBottom)

    let center = CGPoint(x: 512, y: 512)
    let upright = CGRect(x: 386, y: 214, width: 252, height: 596)
    let across = CGRect(x: 214, y: 386, width: 596, height: 252)

    for rect in [upright, across] {
        let path = transformed(sheetPath(rect, radius: 30), around: center, angle: 0.10)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                      color: rgb(0, 0, 0, 0.26))
        fill(path, p.sheetGlass, in: ctx)
        ctx.restoreGState()
        stroke(path, p.edge, width: 4, in: ctx)
    }

    return ctx.makeImage()!
}

// 6. A letterform option, in the spirit of Folio's Folded F: a G whose bar is a
//    separate glassine sheet crossing the ring.
func drawGlyphG(dark: Bool) -> CGImage {
    let p = palette(dark: dark)
    let ctx = context(width: Int(canvas), height: Int(canvas))
    background(in: ctx, top: p.bgTop, bottom: p.bgBottom)

    let center = CGPoint(x: 500, y: 512)
    let thickness: CGFloat = 104
    let radius: CGFloat = 232

    let ring = CGMutablePath()
    ring.addArc(center: center, radius: radius,
                startAngle: -0.10 * .pi, endAngle: 1.42 * .pi,
                clockwise: false)
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30,
                  color: rgb(0, 0, 0, 0.32))
    stroke(ring, p.sheetSolid, width: thickness, in: ctx)
    ctx.restoreGState()

    let bar = CGRect(x: center.x + 12, y: center.y - thickness / 2,
                     width: radius + thickness / 2 - 12, height: thickness)
    fill(sheetPath(bar, radius: thickness / 2), p.sheetGlass, in: ctx)
    stroke(sheetPath(bar, radius: thickness / 2), p.edge, width: 4, in: ctx)

    return ctx.makeImage()!
}

enum Concept: String, CaseIterable {
    case interleaf = "Interleaf"
    case sheaf = "Sheaf"
    case veil = "Veil"
    case fold = "Fold"
    case crossfold = "Crossfold"
    case glyphG = "Glassine G"
}

func image(for concept: Concept, dark: Bool) -> CGImage {
    switch concept {
    case .interleaf: return drawInterleaf(dark: dark)
    case .sheaf: return drawSheaf(dark: dark)
    case .veil: return drawVeil(dark: dark)
    case .fold: return drawFold(dark: dark)
    case .crossfold: return drawCrossfold(dark: dark)
    case .glyphG: return drawGlyphG(dark: dark)
    }
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}

func label(_ text: String, at point: CGPoint, size: CGFloat,
           color: CGColor, in ctx: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String):
            CTFontCreateWithName("SF Pro Display" as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes))
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift scripts/make-glassine-icon-concepts.swift <output-directory>\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var images: [String: CGImage] = [:]
for concept in Concept.allCases {
    for dark in [false, true] {
        let rendered = image(for: concept, dark: dark)
        let suffix = dark ? "dark" : "light"
        images["\(concept.rawValue)-\(suffix)"] = rendered
        let stem = concept.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        write(rendered, to: output.appendingPathComponent("glassine-concept-\(stem)-\(suffix).png"))
    }
}

// One sheet for judging character and 64/32 px legibility side by side.
let board = context(width: 3000, height: 2280)
board.setFillColor(rgb(236, 239, 243))
board.fill(CGRect(x: 0, y: 0, width: 3000, height: 2280))
label("Glassine — app icon directions", at: CGPoint(x: 120, y: 2170),
      size: 58, color: rgb(28, 35, 45), in: board)
label("Overlapping translucent sheets · light and dark appearance · with 64 px and 32 px checks",
      at: CGPoint(x: 122, y: 2106), size: 29, color: rgb(91, 101, 114), in: board)

for (index, concept) in Concept.allCases.enumerated() {
    let x = CGFloat(index % 3) * 960 + 100
    let y: CGFloat = index / 3 == 0 ? 1120 : 120
    label("\(index + 1)  \(concept.rawValue)", at: CGPoint(x: x, y: y + 820),
          size: 38, color: rgb(32, 40, 51), in: board)
    label("LIGHT", at: CGPoint(x: x, y: y + 760), size: 18,
          color: rgb(91, 101, 114), in: board)
    label("DARK", at: CGPoint(x: x + 430, y: y + 760), size: 18,
          color: rgb(91, 101, 114), in: board)

    let light = images["\(concept.rawValue)-light"]!
    let dark = images["\(concept.rawValue)-dark"]!
    board.draw(light, in: CGRect(x: x, y: y + 280, width: 410, height: 410))
    board.draw(dark, in: CGRect(x: x + 430, y: y + 280, width: 410, height: 410))

    label("64", at: CGPoint(x: x + 4, y: y + 210), size: 16,
          color: rgb(116, 125, 137), in: board)
    label("32", at: CGPoint(x: x + 98, y: y + 210), size: 16,
          color: rgb(116, 125, 137), in: board)
    board.draw(light, in: CGRect(x: x, y: y + 120, width: 64, height: 64))
    board.draw(light, in: CGRect(x: x + 96, y: y + 136, width: 32, height: 32))
    board.draw(dark, in: CGRect(x: x + 430, y: y + 120, width: 64, height: 64))
    board.draw(dark, in: CGRect(x: x + 526, y: y + 136, width: 32, height: 32))
}

write(board.makeImage()!, to: output.appendingPathComponent("glassine-icon-concepts-board.png"))

print("wrote 12 concept PNGs + glassine-icon-concepts-board.png to \(output.path)")
