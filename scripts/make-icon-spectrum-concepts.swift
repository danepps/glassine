// make-icon-spectrum-concepts.swift — variations on the shipping icon.
//
// Usage: swift scripts/make-icon-spectrum-concepts.swift <output-directory>
//
// Round seven of the icon explorations (2026-11-27). The concept stays the
// shipping one (fanned glassine leaves, four coloured rules, the Spectrum
// palette) and each variant changes one or two things: how the fan is held,
// where the colour lives, how heavy the rules are, what the tile is. The
// compositing is make-icon.swift's, at 1024 on the legacy macOS grid only; no
// per-size tuning, since these are for choosing a direction, not shipping.
// Writes a light and dark PNG per variant and one review board.

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: a)
}

func context(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

func fill(_ path: CGPath, _ color: CGColor, in ctx: CGContext) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func pagePath(_ rect: CGRect, fold: CGFloat, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
    p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
             tangent2End: CGPoint(x: rect.minX + radius, y: rect.maxY), radius: radius)
    p.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - fold))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
    p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
             tangent2End: CGPoint(x: rect.maxX - radius, y: rect.minY), radius: radius)
    p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
    p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
             tangent2End: CGPoint(x: rect.minX, y: rect.minY + radius), radius: radius)
    p.closeSubpath()
    return p
}

// The Spectrum palette, as in make-icon.swift: red, orange, violet, blue.
let accents = [rgb(232, 48, 14), rgb(232, 164, 0), rgb(154, 100, 160), rgb(33, 72, 160)]

struct Palette {
    var tileTop: CGColor
    var tileBottom: CGColor
    var tint: CGColor
    var tintTop: CGFloat
    var tintUnder: CGFloat
    var ink: CGColor
    var sheen: CGColor
    var shadow: CGFloat
    var rimWidth: CGFloat
    var glowBlur: CGFloat
    var glowAlpha: CGFloat
    var neutralRim: CGColor
}

func dimmed(_ alpha: CGFloat, sheen: CGFloat) -> CGFloat {
    alpha + (1 - alpha) * (1 - sheen) * 0.85
}

let lightPalette = Palette(
    tileTop: rgb(251, 251, 250), tileBottom: rgb(227, 230, 234),
    tint: rgb(255, 255, 255), tintTop: 0.92, tintUnder: 0.60,
    ink: rgb(38, 46, 58), sheen: rgb(255, 255, 255, 0.40), shadow: 0.46,
    rimWidth: 8, glowBlur: 11, glowAlpha: 0.42,
    neutralRim: rgb(160, 168, 180))

let darkPalette = Palette(
    tileTop: rgb(35, 41, 49), tileBottom: rgb(11, 14, 18),
    tint: rgb(22, 27, 34), tintTop: dimmed(0.58, sheen: 0.5),
    tintUnder: dimmed(0.34, sheen: 0.5),
    ink: rgb(240, 244, 250), sheen: rgb(226, 238, 255, 0.08), shadow: 0.26,
    rimWidth: 9, glowBlur: 20, glowAlpha: 0.65,
    neutralRim: rgb(120, 130, 145))

// MARK: - Variants

enum RimMode { case accents, topOnly, neutral }
enum Pivot { case centre, foot }

struct Variant {
    var key: String
    var title: String
    var note: String
    var angles: [CGFloat] = [0.20, 0.10, -0.02, -0.13]   // back leaf first
    var pivot: Pivot = .centre
    var step = CGSize(width: 6, height: -4)              // per leaf, back to front
    var leafScale: CGFloat = 1
    var shift = CGSize.zero                              // whole fan, design units
    var rims: RimMode = .accents
    var rimScale: CGFloat = 1
    var glow = true
    var topRulesInk = false
    var sheetTint: CGFloat = 0          // accent wash on each leaf behind the top
    var ruleHeight: CGFloat = 34
    var ruleWidths: [CGFloat] = [268, 340, 296, 340]
    var rulePitch: CGFloat = 84
    var underRules = true               // ink rules on the leaves behind
    var light: (inout Palette) -> Void = { _ in }
    var dark: (inout Palette) -> Void = { _ in }
}

let roundOne: [Variant] = [
    Variant(key: "shipping", title: "Shipping (1.13)",
            note: "Reference: the current icon."),
    Variant(key: "wide-fan", title: "Wide Fan",
            note: "Leaves spread about twice as far; smaller.",
            angles: [0.52, 0.27, 0.03, -0.21], step: CGSize(width: 4, height: -2),
            leafScale: 0.84, shift: CGSize(width: 0, height: 8)),
    Variant(key: "hand", title: "Hand of Cards",
            note: "Fanned from a common point at the foot.",
            angles: [0.46, 0.30, 0.14, -0.02], pivot: .foot,
            step: .zero, leafScale: 0.86, shift: CGSize(width: 110, height: 40),
            underRules: false),
    Variant(key: "cascade", title: "Cascade",
            note: "No rotation: the leaves step up and left.",
            angles: [0, 0, 0, 0], step: CGSize(width: 34, height: -34),
            leafScale: 0.84, shift: CGSize(width: 0, height: 4)),
    Variant(key: "tinted", title: "Tinted Sheets",
            note: "Each leaf behind is washed in its colour.",
            rimScale: 0.6, sheetTint: 0.28),
    Variant(key: "rules-only", title: "Rules Only",
            note: "Colour only in the rules; rims neutral.",
            rims: .neutral, rimScale: 0.55, glow: false),
    Variant(key: "rims-only", title: "Rims Only",
            note: "Colour only in the rims; rules in ink.",
            rimScale: 1.4, topRulesInk: true),
    Variant(key: "bold-rules", title: "Bold Rules",
            note: "Heavier, longer rules; one red rim.",
            rims: .topOnly, ruleHeight: 54, ruleWidths: [300, 382, 330, 382],
            rulePitch: 96),
    Variant(key: "paper", title: "Paper Tile",
            note: "Warm paper tile, as on danepps.com.",
            light: { p in
                p.tileTop = rgb(250, 247, 240); p.tileBottom = rgb(234, 226, 210)
                p.tint = rgb(255, 253, 248); p.ink = rgb(48, 40, 34)
            },
            dark: { p in
                p.tileTop = rgb(44, 38, 33); p.tileBottom = rgb(18, 15, 12)
                p.tint = rgb(30, 26, 22); p.ink = rgb(246, 240, 230)
            }),
]

// MARK: - Glassine compositing (make-icon.swift's)

func blurRows(_ input: [UInt8], _ output: inout [UInt8], width: Int, height: Int, radius: Int) {
    let window = radius * 2 + 1
    for y in 0..<height {
        let row = y * width * 4
        for channel in 0..<4 {
            var total = 0
            for offset in -radius...radius {
                total += Int(input[row + min(max(offset, 0), width - 1) * 4 + channel])
            }
            for x in 0..<width {
                output[row + x * 4 + channel] = UInt8(total / window)
                let leaving = min(max(x - radius, 0), width - 1)
                let entering = min(max(x + radius + 1, 0), width - 1)
                total += Int(input[row + entering * 4 + channel])
                total -= Int(input[row + leaving * 4 + channel])
            }
        }
    }
}

func blurColumns(_ input: [UInt8], _ output: inout [UInt8], width: Int, height: Int, radius: Int) {
    let window = radius * 2 + 1
    let rowBytes = width * 4
    for x in 0..<width {
        let column = x * 4
        for channel in 0..<4 {
            var total = 0
            for offset in -radius...radius {
                total += Int(input[min(max(offset, 0), height - 1) * rowBytes + column + channel])
            }
            for y in 0..<height {
                output[y * rowBytes + column + channel] = UInt8(total / window)
                let leaving = min(max(y - radius, 0), height - 1)
                let entering = min(max(y + radius + 1, 0), height - 1)
                total += Int(input[entering * rowBytes + column + channel])
                total -= Int(input[leaving * rowBytes + column + channel])
            }
        }
    }
}

func veiled(_ ctx: CGContext) -> CGImage {
    let side = min(128, ctx.width)
    let radius = max(1, Int((CGFloat(side) * 0.031).rounded()))
    let rowBytes = side * 4
    var pixels = [UInt8](repeating: 0, count: rowBytes * side)
    let source = ctx.makeImage()!
    pixels.withUnsafeMutableBytes { buffer in
        let small = CGContext(data: buffer.baseAddress, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        small.interpolationQuality = .high
        small.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
    }
    var a = pixels
    var scratch = [UInt8](repeating: 0, count: pixels.count)
    for _ in 0..<3 {
        blurRows(a, &scratch, width: side, height: side, radius: radius)
        blurColumns(scratch, &a, width: side, height: side, radius: radius)
    }
    let out = context(width: side, height: side)
    let destination = out.data!
    a.withUnsafeBytes { buffer in
        for y in 0..<side {
            memcpy(destination + y * out.bytesPerRow, buffer.baseAddress! + y * rowBytes, rowBytes)
        }
    }
    return out.makeImage()!
}

// MARK: - Drawing

func render(_ v: Variant, dark: Bool, side: Int = 1024) -> CGImage {
    var palette = dark ? darkPalette : lightPalette
    dark ? v.dark(&palette) : v.light(&palette)
    let s = CGFloat(side)
    let ctx = context(width: side, height: side)
    let inner = (s * 824 / 1024).rounded()
    let origin = ((s - inner) / 2).rounded()
    let tile = CGRect(x: origin, y: origin, width: inner, height: inner)
    let u = inner / 1024
    let toTile = CGAffineTransform(translationX: tile.midX, y: tile.midY)
        .scaledBy(x: u, y: u).translatedBy(x: -512, y: -512)

    let corner = 188 * u
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [palette.tileTop, palette.tileBottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: tile.minX + 220 * u, y: tile.maxY),
                           end: CGPoint(x: tile.minX + 800 * u, y: tile.minY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.addPath(tilePath)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
    ctx.setLineWidth(5 * u)
    ctx.strokePath()

    // Leaf geometry in design space, scaled about the fan's centre.
    let base = CGRect(x: 266, y: 196, width: 492, height: 632)
    let k = v.leafScale
    let scaled = CGRect(x: 512 - (512 - base.minX) * k, y: 512 - (512 - base.minY) * k,
                        width: base.width * k, height: base.height * k)
        .offsetBy(dx: v.shift.width, dy: v.shift.height)
    let n = v.angles.count
    let centreIndex = CGFloat(n - 1) / 2

    struct Leaf { let index: Int; let rect: CGRect; let transform: CGAffineTransform; let path: CGPath }
    var leaves: [Leaf] = []
    for i in 0..<n {
        let d = CGFloat(i) - centreIndex
        let r = scaled.offsetBy(dx: d * v.step.width - 9, dy: d * v.step.height).applying(toTile)
        let pivot: CGPoint
        switch v.pivot {
        case .centre: pivot = CGPoint(x: r.midX, y: r.midY)
        case .foot: pivot = CGPoint(x: r.midX - r.width * 0.15, y: r.minY - r.height * 0.18)
        }
        let spin = CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .rotated(by: v.angles[i]).translatedBy(x: -pivot.x, y: -pivot.y)
        var t = spin
        let path = pagePath(r, fold: 112 * k * u, radius: 20 * u).copy(using: &t)!
        leaves.append(Leaf(index: i, rect: r, transform: spin, path: path))
    }

    let g = u * k
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bounds = CGRect(x: 0, y: 0, width: s, height: s)
    for leaf in leaves {
        let top = leaf.index == n - 1
        let colour = accents[n - 1 - leaf.index]
        let backdrop = veiled(ctx)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18 * g), blur: 34 * g,
                      color: rgb(0, 0, 0, palette.shadow))
        fill(leaf.path, rgb(0, 0, 0), in: ctx)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(leaf.path); ctx.clip()
        ctx.draw(backdrop, in: bounds)
        ctx.setFillColor(palette.tint.copy(alpha: top ? palette.tintTop : palette.tintUnder)!)
        ctx.fill(bounds)
        if v.sheetTint > 0 && !top {
            ctx.setFillColor(colour.copy(alpha: v.sheetTint * (dark ? 1.3 : 1))!)
            ctx.fill(bounds)
        }
        let sheen = CGGradient(colorsSpace: colorSpace,
                               colors: [palette.sheen, rgb(255, 255, 255, 0)] as CFArray,
                               locations: [0, 1])!
        let sheenTop = leaf.path.boundingBox.maxY
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: sheenTop),
                               end: CGPoint(x: 0, y: sheenTop - 170 * g), options: [])
        ctx.restoreGState()

        // The rim.
        let rimColour: CGColor
        var bloom = v.glow
        switch v.rims {
        case .accents: rimColour = colour
        case .topOnly:
            rimColour = top ? colour : palette.neutralRim
            bloom = bloom && top
        case .neutral: rimColour = palette.neutralRim; bloom = false
        }
        let rimWidth = palette.rimWidth * v.rimScale * u
        ctx.saveGState()
        if bloom {
            ctx.setShadow(offset: .zero, blur: palette.glowBlur * u,
                          color: rimColour.copy(alpha: palette.glowAlpha)!)
        }
        ctx.addPath(leaf.path)
        ctx.setStrokeColor(rimColour)
        ctx.setLineWidth(v.rims == .topOnly && !top ? rimWidth * 0.55 : rimWidth)
        ctx.strokePath()
        ctx.restoreGState()

        // The rules, on every leaf, coloured on the top one.
        if !top && !v.underRules { continue }
        ctx.saveGState()
        ctx.addPath(leaf.path); ctx.clip()
        ctx.concatenate(leaf.transform)
        let h = v.ruleHeight * g
        let pitch = v.rulePitch * g
        let centre = leaf.rect.minY + 307 * g
        let blockHeight = pitch * 3 + h
        let firstY = centre + blockHeight / 2 - h
        let x = leaf.rect.minX + 55 * g
        for index in 0..<4 {
            let rect = CGRect(x: x, y: firstY - CGFloat(index) * pitch,
                              width: v.ruleWidths[index] * g, height: h)
            let colour = top && !v.topRulesInk ? accents[index] : palette.ink
            fill(CGPath(roundedRect: rect, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil),
                 colour, in: ctx)
        }
        ctx.restoreGState()
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor,
          bold: Bool = false, in ctx: CGContext) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes)!)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

// --rims: the shipping fan with the leaf outlines at increasing weights. The
// stroke is centred on the leaf's edge, so half of each extra point eats into
// the page and half spreads outward.
let rimScales: [CGFloat] = [1, 1.5, 2, 2.5, 3, 4]
let rimLadder = rimScales.map { k in
    Variant(key: "rim-\(String(format: "%.1f", k))x",
            title: k == 1 ? "Outline 1× (shipping)" : "Outline \(String(format: k == k.rounded() ? "%.0f" : "%.1f", k))×",
            note: "Light rim \(String(format: "%.0f", 8 * k)) pt, dark \(String(format: "%.0f", 9 * k)) pt at 1024.",
            rimScale: k)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let rimsMode = arguments.contains("--rims")
arguments.removeAll { $0 == "--rims" }
// --only <key> keeps one round-one variant; --rim-scale N multiplies its outline.
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}
let only = option("--only")
// --leaf-scale a,b,… renders the kept variants once per sheet size.
let leafScales = option("--leaf-scale")?.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
let rimMultiplier = option("--rim-scale").flatMap { Double($0) }.map { CGFloat($0) } ?? 1
guard arguments.count == 1 else {
    fputs("usage: swift scripts/make-icon-spectrum-concepts.swift <output-directory> [--rims] [--only key] [--rim-scale N]\n", stderr)
    exit(2)
}
var variants = rimsMode ? rimLadder : roundOne.filter { only == nil || $0.key == only }
if rimMultiplier != 1 {
    variants = variants.map { v in
        var v = v
        v.rimScale *= rimMultiplier
        v.key += "-rim\(String(format: "%g", Double(rimMultiplier)))x"
        v.title += ", outline \(String(format: "%g", Double(rimMultiplier)))×"
        return v
    }
}
if let leafScales {
    variants = variants.flatMap { v in
        leafScales.map { k in
            var w = v
            w.leafScale = k
            w.key += "-sheets\(String(format: "%g", Double(k)))"
            w.title += ", sheets \(String(format: "%g", Double(k)))"
            w.note = "Sheet size \(String(format: "%g", Double(k))) of the shipping icon's (was \(String(format: "%g", Double(v.leafScale))))."
            return w
        }
    }
}
let boardTitle = rimsMode ? "Glassine icon — outline weight" : "Glassine icon variations — Spectrum palette"
let boardNote = rimsMode
    ? "The shipping fan with only the leaf outlines thickened. Light and dark, with 64 and 32 px previews."
    : "Same concept and four colours; each variant changes one or two things. Light and dark, with 64 and 32 px previews."
let output = URL(fileURLWithPath: arguments[0], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let columns = 3
let cell = CGSize(width: 1000, height: 640)
let rows = (variants.count + columns - 1) / columns
let boardW = Int(cell.width) * columns + 120
let boardH = Int(cell.height) * rows + 240
let board = context(width: boardW, height: boardH)
board.setFillColor(rgb(236, 239, 243))
board.fill(CGRect(x: 0, y: 0, width: boardW, height: boardH))
text(boardTitle, x: 60, y: CGFloat(boardH) - 100,
     size: 52, color: rgb(28, 35, 45), bold: true, in: board)
text(boardNote,
     x: 60, y: CGFloat(boardH) - 150, size: 26, color: rgb(91, 101, 114), in: board)

for (i, v) in variants.enumerated() {
    let light = render(v, dark: false)
    let dark = render(v, dark: true)
    let stem = rimsMode ? v.key : "\(String(format: "%02d", i + 1))-\(v.key)"
    write(light, to: output.appendingPathComponent("\(stem)-light.png"))
    write(dark, to: output.appendingPathComponent("\(stem)-dark.png"))
    let col = i % columns, row = i / columns
    let x = 60 + CGFloat(col) * cell.width
    let top = CGFloat(boardH) - 200 - CGFloat(row) * cell.height
    text("\(i + 1). \(v.title)", x: x, y: top - 40, size: 34, color: rgb(32, 40, 51), bold: true, in: board)
    text(v.note, x: x, y: top - 80, size: 24, color: rgb(91, 101, 114), in: board)
    board.draw(light, in: CGRect(x: x, y: top - 520, width: 420, height: 420))
    board.draw(dark, in: CGRect(x: x + 430, y: top - 520, width: 420, height: 420))
    board.draw(light, in: CGRect(x: x + 862, y: top - 200, width: 64, height: 64))
    board.draw(light, in: CGRect(x: x + 878, y: top - 250, width: 32, height: 32))
    board.draw(dark, in: CGRect(x: x + 862, y: top - 400, width: 64, height: 64))
    board.draw(dark, in: CGRect(x: x + 878, y: top - 450, width: 32, height: 32))
    print("rendered \(v.key)")
}
write(board.makeImage()!, to: output.appendingPathComponent(rimsMode ? "00-board-outline-weight.png" : "00-board.png"))
print("wrote \(output.path)")
