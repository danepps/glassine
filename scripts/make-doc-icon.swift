// make-doc-icon.swift — builds Support/MarkdownDocument.icns, the Finder
// document icon for Markdown files.
//
// Usage:
//   swift scripts/make-doc-icon.swift [output.icns] [--keep-iconset]
//
//   --keep-iconset  Leave the intermediate .iconset beside the output so the
//                   individual sizes can be inspected.
//
// The app icon's drawing language on a single sheet: the same folded page, a
// coral rim, and the four coloured rules — with the M↓ mark above them saying
// which kind of document this is. Light variant only: Finder draws one document
// icon whatever the appearance is. Each size is drawn at its own pixel
// resolution rather than downsampled, so the 16 and 32 px tiles can snap their
// edges to the pixel grid and carry a heavier mark. Pure CoreGraphics +
// ImageIO, so it runs as a plain script.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: a)
}

func fill(_ path: CGPath, _ color: CGColor, in ctx: CGContext) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func rounded(_ rect: CGRect, radius: CGFloat, _ color: CGColor, in ctx: CGContext) {
    guard radius > 0.5 else { return fill(CGPath(rect: rect, transform: nil), color, in: ctx) }
    fill(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                transform: nil), color, in: ctx)
}

// MARK: - Design space

// The 1024 pt canvas the concept was drawn on. Everything below is expressed
// in it and mapped onto the target tile.
// Centred, unlike the Folio-era sheet, which sat left of centre to leave room
// for the margin tabs that this design drops.
let pageRect = CGRect(x: 200, y: 112, width: 624, height: 800)
let foldSize: CGFloat = 150
let pageRadius: CGFloat = 24

// The four rules keep the app icon's proportions, widened to this sheet.
let ruleLeft: CGFloat = 289
let ruleThickness: CGFloat = 38
let ruleWidths: [CGFloat] = [350, 446, 388, 446]
let ruleYs: [CGFloat] = [452, 364, 276, 188]
let ruleColors = [rgb(255, 91, 91), rgb(255, 190, 48), rgb(46, 210, 171), rgb(76, 160, 255)]

let markCenterY: CGFloat = 700
let markSize: CGFloat = 224

let paperColor = rgb(255, 255, 255)
let foldColor = rgb(212, 219, 229)
let inkColor = rgb(38, 46, 58)              // #262E3A, the app icon's slate
let rimColor = ruleColors[0]                // coral, as on the app icon's top leaf
let rimWidth: CGFloat = 9

// MARK: - Per-size tuning

// At 16 and 32 px the design has to be redrawn rather than scaled: the sheet
// is zoomed so it fills the tile, the mark is drawn heavier than the
// proportional size (a 0.25 × height stem lands under 2 px and greys out), the
// rules are floored at 2 px so their colours survive, and at 16 px the rules
// and the arrow are dropped — there is room for a bold M and nothing else, so
// the mark moves back to the middle of the sheet and the coral rim is left to
// carry the family's colour.
struct Tuning {
    var zoom: CGFloat = 1
    var rules = 4
    var rulePitch: CGFloat?     // px
    var ruleHeight: CGFloat?    // px
    var markCenterY: CGFloat?   // design units
    var markHeight: CGFloat?
    var markWidth: CGFloat?
    var markStroke: CGFloat?
    var arrow = true
    var shadow = true
}

func tuning(for side: Int) -> Tuning {
    switch side {
    case 16:
        return Tuning(zoom: 1.18, rules: 0, markCenterY: pageRect.midY,
                      markHeight: 9, markWidth: 8, markStroke: 2,
                      arrow: false, shadow: false)
    case 32:
        return Tuning(zoom: 1.10, rules: 4, rulePitch: 3, ruleHeight: 2,
                      markHeight: 10, markStroke: 2, shadow: false)
    case 64:
        return Tuning(ruleHeight: 3)
    default:
        return Tuning()
    }
}

// MARK: - Drawing

func render(side: Int) -> CGImage {
    let t = tuning(for: side)
    let s = CGFloat(side)
    let unit = s / 1024 * t.zoom

    let ctx = CGContext(data: nil, width: side, height: side,
                        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Whole-pixel edges: a sheet edge or a rule landing on a half pixel comes
    // back as two grey rows instead of one dark one.
    func at(_ v: CGFloat) -> CGFloat { ((v - 512) * unit + s / 2).rounded() }
    func size(_ v: CGFloat, min m: CGFloat = 1) -> CGFloat { max(m, (v * unit).rounded()) }

    let left = at(pageRect.minX), right = at(pageRect.maxX)
    let bottom = at(pageRect.minY), top = at(pageRect.maxY)
    let sheet = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    let fold = size(foldSize)
    let radius = (pageRadius * unit).rounded()

    let page = CGMutablePath()
    page.move(to: CGPoint(x: sheet.minX, y: sheet.minY + radius))
    page.addLine(to: CGPoint(x: sheet.minX, y: sheet.maxY - radius))
    page.addArc(tangent1End: CGPoint(x: sheet.minX, y: sheet.maxY),
                tangent2End: CGPoint(x: sheet.minX + radius, y: sheet.maxY), radius: radius)
    page.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
    page.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
    page.addLine(to: CGPoint(x: sheet.maxX, y: sheet.minY + radius))
    page.addArc(tangent1End: CGPoint(x: sheet.maxX, y: sheet.minY),
                tangent2End: CGPoint(x: sheet.maxX - radius, y: sheet.minY), radius: radius)
    page.addLine(to: CGPoint(x: sheet.minX + radius, y: sheet.minY))
    page.addArc(tangent1End: CGPoint(x: sheet.minX, y: sheet.minY),
                tangent2End: CGPoint(x: sheet.minX, y: sheet.minY + radius), radius: radius)
    page.closeSubpath()

    ctx.saveGState()
    if t.shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 30 * unit,
                      color: rgb(0, 0, 0, 0.22))
    }
    fill(page, paperColor, in: ctx)
    ctx.restoreGState()

    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
    flap.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
    flap.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY - fold))
    flap.closeSubpath()
    fill(flap, foldColor, in: ctx)

    // The coral rim is the app icon's front leaf, on its own. It is a
    // double-width stroke clipped to the sheet, so the rim lies wholly inside
    // the pixel-snapped edge: a centred 1 px stroke at 16 px would land half in
    // and half out and come back as two grey rows.
    ctx.saveGState()
    ctx.addPath(page)
    ctx.clip()
    ctx.addPath(page)
    ctx.setStrokeColor(rimColor)
    ctx.setLineWidth(size(rimWidth) * 2)
    ctx.strokePath()
    ctx.restoreGState()

    // One rounded pitch rather than four rounded positions: at 32 px the
    // design's even 88 pt spacing would otherwise round to 3, 3, 2 px apart.
    let ruleX = at(ruleLeft)
    let ruleH = t.ruleHeight ?? size(ruleThickness)
    let pitch = t.rulePitch ?? size(ruleYs[0] - ruleYs[1])
    let blockHeight = pitch * 3 + ruleH
    let firstY = (at((ruleYs.last! + ruleYs.first! + ruleThickness) / 2)
                  + blockHeight / 2 - ruleH).rounded()
    for index in 0..<t.rules {
        let w = max(3, size(ruleWidths[index]))
        rounded(CGRect(x: ruleX, y: firstY - CGFloat(index) * pitch,
                       width: w, height: ruleH),
                radius: ruleH <= 2 ? 0 : ruleH / 2, ruleColors[index], in: ctx)
    }

    let h = t.markHeight ?? size(markSize)
    let stroke = t.markStroke ?? max(1, (h * 0.25).rounded())
    let mW = t.markWidth ?? (h * 1.02).rounded()
    let gap = max(1, (h * 0.19).rounded())
    let arrowW = max(3, (h * 0.62).rounded())
    let headH = max(2, (h * 0.46).rounded())
    let total = t.arrow ? mW + gap + arrowW : mW
    let x0 = (sheet.midX - total / 2).rounded()
    let y0 = (at(t.markCenterY ?? markCenterY) - h / 2).rounded()

    // The M is a stroked polyline clipped to its own box: that keeps the stem
    // terminals flat and the mitred apex from spiking past the cap height.
    ctx.saveGState()
    ctx.clip(to: CGRect(x: x0 - stroke, y: y0, width: mW + 2 * stroke, height: h))
    let m = CGMutablePath()
    m.move(to: CGPoint(x: x0 + stroke / 2, y: y0 - stroke))
    m.addLine(to: CGPoint(x: x0 + stroke / 2, y: y0 + h))
    m.addLine(to: CGPoint(x: x0 + mW / 2, y: (y0 + h * 0.40).rounded()))
    m.addLine(to: CGPoint(x: x0 + mW - stroke / 2, y: y0 + h))
    m.addLine(to: CGPoint(x: x0 + mW - stroke / 2, y: y0 - stroke))
    ctx.addPath(m)
    ctx.setStrokeColor(inkColor)
    ctx.setLineWidth(stroke)
    ctx.setLineJoin(.miter)
    ctx.setMiterLimit(24)
    ctx.setLineCap(.butt)
    ctx.strokePath()
    ctx.restoreGState()

    if t.arrow {
        let ax = x0 + mW + gap
        let stemY = (y0 + headH * 0.76).rounded()
        fill(CGPath(rect: CGRect(x: (ax + arrowW / 2 - stroke / 2).rounded(), y: stemY,
                                 width: stroke, height: y0 + h - stemY), transform: nil),
             inkColor, in: ctx)
        let head = CGMutablePath()
        head.move(to: CGPoint(x: ax + arrowW / 2, y: y0))
        head.addLine(to: CGPoint(x: ax + arrowW, y: y0 + headH))
        head.addLine(to: CGPoint(x: ax, y: y0 + headH))
        head.closeSubpath()
        fill(head, inkColor, in: ctx)
    }

    return ctx.makeImage()!
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fputs("failed to create image destination at \(url.path)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fputs("failed to write \(url.path)\n", stderr)
        exit(1)
    }
}

var outputPath: String?
var keepIconset = false
for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--keep-iconset": keepIconset = true
    default:
        guard !argument.hasPrefix("--") else {
            fputs("unknown option \(argument)\n", stderr)
            exit(2)
        }
        outputPath = argument
    }
}

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let output = URL(fileURLWithPath: outputPath
    ?? repoRoot.appendingPathComponent("Support/MarkdownDocument.icns").path)

let iconset = output.deletingLastPathComponent()
    .appendingPathComponent(output.deletingPathExtension().lastPathComponent + ".iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (point size, scale) — 32 and 256 are each rendered once and used twice.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2)
]
var images: [Int: CGImage] = [:]
for variant in variants {
    let side = variant.points * variant.scale
    let image = images[side] ?? render(side: side)
    images[side] = image
    let suffix = variant.scale == 1 ? "" : "@2x"
    write(image, to: iconset.appendingPathComponent(
        "icon_\(variant.points)x\(variant.points)\(suffix).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
if !keepIconset {
    try FileManager.default.removeItem(at: iconset)
}
print("wrote \(output.path)")
