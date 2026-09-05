// make-icon.swift — generates the Glassine app icon artwork as a PNG.
//
// Usage:
//   swift make-icon.swift <out.png> [--dark] [--full-bleed] [--size N]
//
//   --dark        Dark appearance: concept D5 "Neon Rules" on the graphite tile.
//   --full-bleed  Use the full Icon Composer canvas. Without this flag the
//                 artwork uses the legacy macOS icon grid, which insets the
//                 tile inside the canvas.
//   --size N      Output side in pixels (default 1024). Every size is drawn at
//                 its own resolution rather than downsampled from 1024, so the
//                 rims and rules can be widened to survive; see `tuning(for:)`.
//
// The drawing is Palette Rules from scripts/make-icon-concepts.swift, which
// stays as the exploratory record: four fanned glassine leaves, each composited
// out of the blurred backdrop plus a milky tint the way the app composites its
// own translucent window, coloured rims, and four coloured rules on the top
// leaf. Light is that script's round-six L4 (the "Near white" tile, coloured
// rims with a tight soft glow); dark is its round-five D5 (graphite tile, neon
// rim bloom, sheen at 50%).
//
// Pure CoreGraphics + ImageIO so it runs as a plain script with no app bundle.

import Foundation
import CoreGraphics
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

/// A page with its top-right corner cut away.
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

// MARK: - Palettes

/// The reader's four accent colours, unchanged since the Folio icon: they are
/// the rules on the top leaf and the rims of the four leaves.
let accents = [rgb(255, 91, 91),    // coral
               rgb(255, 190, 48),   // amber
               rgb(46, 210, 171),   // mint
               rgb(76, 160, 255)]   // blue

struct Palette {
    let tileTop: CGColor
    let tileBottom: CGColor
    let tint: CGColor            // the leaf's own milkiness, over the backdrop
    let tintTop: CGFloat         // alpha for the front leaf …
    let tintUnder: CGFloat       // … and for the ones behind it
    let ink: CGColor             // rules on the leaves below the top one
    let sheen: CGColor
    let shadow: CGFloat
    let rimWidth: CGFloat        // design units
    let glowBlur: CGFloat        // design units; 0 for a rim with no bloom
    let glowAlpha: CGFloat
}

/// Taking a leaf's tint toward opaque as the sheen level drops. The soft light
/// across a dark leaf is only half the top-edge gradient; the rest is the type
/// on the leaves underneath glowing up through the blurred backdrop, and the
/// only thing that shuts that off is a less transparent sheet. D5 is sheen 50%.
func dimmed(_ alpha: CGFloat, sheen: CGFloat) -> CGFloat {
    alpha + (1 - alpha) * (1 - sheen) * 0.85
}

let darkSheen: CGFloat = 0.5

// L4: the palest tile of round six. The fan has almost no tone to sit against,
// so the coloured rims do the separating and the shadow under each leaf is
// deepened; the front leaf's tint is raised to 0.92 so its page still reads as
// white paper over the leaves behind it.
let lightPalette = Palette(
    tileTop: rgb(251, 251, 250),        // #FBFBFA
    tileBottom: rgb(227, 230, 234),     // #E3E6EA
    tint: rgb(255, 255, 255),
    tintTop: 0.92, tintUnder: 0.60,
    ink: rgb(38, 46, 58),
    sheen: rgb(255, 255, 255, 0.40),
    shadow: 0.46,
    rimWidth: 8,
    // On a pale tile the dark row's wide bloom reads as a smear rather than an
    // edge, so the light crossing gets a tighter, weaker glow.
    glowBlur: 11, glowAlpha: 0.42
)

// D5: the graphite tile the app has always shipped on, the rims blooming, and
// the sheen at half so the fan reads as unlit glass rather than a lightbox.
let darkPalette = Palette(
    tileTop: rgb(35, 41, 49),           // #232931
    tileBottom: rgb(11, 14, 18),        // #0B0E12
    tint: rgb(22, 27, 34),
    tintTop: dimmed(0.58, sheen: darkSheen),
    tintUnder: dimmed(0.34, sheen: darkSheen),
    ink: rgb(240, 244, 250),
    sheen: rgb(226, 238, 255, 0.16 * darkSheen),
    shadow: 0.26,
    rimWidth: 9,
    glowBlur: 20, glowAlpha: 0.65
)

// MARK: - Geometry, in the 1024 design space

let leafBase = CGRect(x: 266, y: 196, width: 492, height: 632)
let leafFold: CGFloat = 112
let leafRadius: CGFloat = 20
let fanAngles: [CGFloat] = [0.20, 0.10, -0.02, -0.13]   // back leaf first

let ruleInset: CGFloat = 55                              // from the leaf's left edge
let ruleWidths: [CGFloat] = [268, 340, 296, 340]         // top rule first
let ruleOffsets: [CGFloat] = [416, 332, 248, 164]        // from the leaf's minY
let ruleHeight: CGFloat = 34
/// Where the block of four rules is centred, measured from the leaf's foot.
let ruleCentre = (ruleOffsets.last! + ruleOffsets.first! + ruleHeight) / 2

// MARK: - Per-size tuning

// Below 128 px the design has to be redrawn rather than scaled. Rims and rules
// are proportionally sub-pixel there — a 9 pt rim is 0.28 px at 32 — so they
// are floored at a whole pixel and the rules given their own pitch; the top
// leaf is straightened so those rules can land on the pixel grid at all (a 7°
// rotation turns a 2 px rule into two grey rows); and the fan is zoomed to fill
// more of the tile, since the legacy grid's margin is a luxury at 16 px.
struct Tuning {
    var leaves = 4
    var angles: [CGFloat]?      // replaces the fan's angles, front-most last
    var zoom: CGFloat = 1
    var inset: CGFloat = 824 / 1024   // legacy grid; ignored when full-bleed
    var minRim: CGFloat = 0     // px
    var minRule: CGFloat = 0    // px
    var rulePitch: CGFloat?     // px
    var snap = false
    var glow = true
    var shadow = true
    var underRules = true
}

func tuning(for side: Int) -> Tuning {
    switch side {
    case 16:
        return Tuning(leaves: 2, angles: [0.16, 0], zoom: 1.42, inset: 0.98,
                      minRim: 1, minRule: 2, rulePitch: 3, snap: true,
                      glow: false, shadow: false, underRules: false)
    case 32:
        return Tuning(leaves: 3, angles: [0.17, 0.09, 0], zoom: 1.16, inset: 0.94,
                      minRim: 1, minRule: 2, rulePitch: 3, snap: true,
                      underRules: false)
    case 64:
        return Tuning(minRim: 1, minRule: 2, snap: true, underRules: false)
    case 128:
        return Tuning(minRim: 1.25, minRule: 2.5)
    default:
        return Tuning()
    }
}

// MARK: - Glassine compositing

// A separable box blur, run three times, which is a good enough Gaussian for a
// backdrop nobody reads. Pure CoreGraphics buffers so the script still runs as
// a script; the pixels are premultiplied, which is exactly what averaging wants.
func blurRows(_ input: [UInt8], _ output: inout [UInt8],
              width: Int, height: Int, radius: Int) {
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

func blurColumns(_ input: [UInt8], _ output: inout [UInt8],
                 width: Int, height: Int, radius: Int) {
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

func boxBlur(_ pixels: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
    guard radius > 0 else { return pixels }
    var source = pixels
    var scratch = [UInt8](repeating: 0, count: pixels.count)
    for _ in 0..<3 {
        blurRows(source, &scratch, width: width, height: height, radius: radius)
        blurColumns(scratch, &source, width: width, height: height, radius: radius)
    }
    return source
}

/// Everything drawn so far, blurred — the backdrop the leaf laid down next will
/// show through. Downsample, blur small, and let the draw-back-up do the rest:
/// a wide blur at 1024 would cost seconds per leaf and look no different.
func veiled(_ ctx: CGContext) -> CGImage {
    // The working width is capped so the blur stays at ~3% of the canvas at
    // every size: a 64 px tile is veiled as much as a 1024 px one.
    let side = min(128, ctx.width)
    let radius = max(1, Int((CGFloat(side) * 0.031).rounded()))
    let rowBytes = side * 4
    var pixels = [UInt8](repeating: 0, count: rowBytes * side)
    let source = ctx.makeImage()!
    pixels.withUnsafeMutableBytes { buffer in
        let small = CGContext(data: buffer.baseAddress, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: rowBytes,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        small.interpolationQuality = .high
        small.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
    }
    let blurred = boxBlur(pixels, width: side, height: side, radius: radius)

    // Copy into a context that owns its memory: `makeImage()` on a context
    // backed by a client buffer is only a snapshot as long as that buffer
    // lives, and this one dies with the closure. CG may pad its rows, so the
    // copy goes row by row rather than in one memcpy.
    let out = context(width: side, height: side)
    let destination = out.data!
    blurred.withUnsafeBytes { buffer in
        let base = buffer.baseAddress!
        for y in 0..<side {
            memcpy(destination + y * out.bytesPerRow, base + y * rowBytes, rowBytes)
        }
    }
    return out.makeImage()!
}

// MARK: - Drawing

struct Leaf {
    let design: Int         // 0 = backmost of the four in the concept's fan
    let rect: CGRect        // pixel space, before rotation
    let angle: CGFloat
    let path: CGPath        // pixel space, rotated
}

func render(side: Int, dark: Bool, fullBleed: Bool) -> CGImage {
    let t = tuning(for: side)
    let palette = dark ? darkPalette : lightPalette
    let s = CGFloat(side)
    let ctx = context(width: side, height: side)

    let inner = fullBleed ? s : (s * t.inset).rounded()
    let origin = ((s - inner) / 2).rounded()
    let tile = CGRect(x: origin, y: origin, width: inner, height: inner)
    let u = inner / 1024                 // design unit → pixels, tile scale
    let g = u * t.zoom                   // … and for the artwork on the tile
    func snapped(_ v: CGFloat) -> CGFloat { t.snap ? v.rounded() : v }

    // Design space → pixels, zoomed about the centre of the tile.
    let toTile = CGAffineTransform(translationX: tile.midX, y: tile.midY)
        .scaledBy(x: g, y: g)
        .translatedBy(x: -512, y: -512)

    // ------------------------------------------------------------- the tile
    let corner = 188 * u
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner,
                          cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [palette.tileTop, palette.tileBottom] as CFArray,
                              locations: [0, 1])!
    // Extending both ends is essential: without it the diagonal gradient leaves
    // transparent wedges in the top-left and bottom-right corners.
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: tile.minX + 220 * u, y: tile.maxY),
        end: CGPoint(x: tile.minX + 800 * u, y: tile.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    if !fullBleed {
        ctx.addPath(tilePath)
        ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
        ctx.setLineWidth(max(0.5, 5 * u))
        ctx.strokePath()
    }

    // ------------------------------------------------------------- the fan
    let kept = min(t.leaves, fanAngles.count)
    var leaves: [Leaf] = []
    for position in 0..<kept {
        // Keep the front-most leaves: dropping one at 32 px drops the leaf
        // whose sliver of blue was never going to be more than a stray pixel.
        let design = fanAngles.count - kept + position
        let angle = t.angles.map { $0[position] } ?? fanAngles[design]
        // Built in pixel space rather than transformed from the design, so the
        // straightened top leaf of a small tile can have whole-pixel edges.
        var rect = leafBase
            .offsetBy(dx: CGFloat(design) * 6 - 9, dy: CGFloat(design) * -4)
            .applying(toTile)
        if t.snap {
            rect = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
                          width: rect.width.rounded(), height: rect.height.rounded())
        }
        var spin = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: angle)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        let path = pagePath(rect, fold: leafFold * g, radius: leafRadius * g)
        leaves.append(Leaf(design: design, rect: rect, angle: angle,
                           path: path.copy(using: &spin)!))
    }

    let rimWidth = max(t.minRim, palette.rimWidth * g)
    let ruleH = max(t.minRule, snapped(ruleHeight * g))
    let rulePitch = t.rulePitch ?? (ruleOffsets[0] - ruleOffsets[1]) * g

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    for leaf in leaves {
        let top = leaf.design == fanAngles.count - 1
        let backdrop = veiled(ctx)

        // The opaque black under the tint is only there to give the shadow
        // something to cast from; the backdrop draw covers it.
        if t.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -18 * g), blur: 34 * g,
                          color: rgb(0, 0, 0, palette.shadow))
            fill(leaf.path, rgb(0, 0, 0), in: ctx)
            ctx.restoreGState()
        }

        let bounds = CGRect(x: 0, y: 0, width: s, height: s)
        ctx.saveGState()
        ctx.addPath(leaf.path)
        ctx.clip()
        ctx.draw(backdrop, in: bounds)
        ctx.setFillColor(palette.tint.copy(alpha: top ? palette.tintTop : palette.tintUnder)!)
        ctx.fill(bounds)
        let sheen = CGGradient(colorsSpace: colorSpace,
                               colors: [palette.sheen, rgb(255, 255, 255, 0)] as CFArray,
                               locations: [0, 1])!
        let sheenTop = leaf.path.boundingBox.maxY
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: sheenTop),
                               end: CGPoint(x: 0, y: sheenTop - 170 * g), options: [])
        ctx.restoreGState()

        // The rim is opaque and wider than the neutral sheet edge underneath it,
        // so only the coloured stroke is drawn.
        let edge = accents[fanAngles.count - 1 - leaf.design]
        let bloom = t.glow && palette.glowBlur > 0
        if bloom {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: palette.glowBlur * g,
                          color: edge.copy(alpha: palette.glowAlpha)!)
            ctx.addPath(leaf.path)
            ctx.setStrokeColor(edge)
            ctx.setLineWidth(rimWidth)
            ctx.strokePath()
            ctx.restoreGState()
        }
        // A 1 px stroke centred on a whole-pixel edge lands half in and half
        // out and comes back as two grey rows, so at the snapped sizes the rim
        // is redrawn as a double-width stroke clipped to the leaf — the inner
        // half only, on the pixel. Anything the bloom pass left outside the
        // edge stays, which is what a bloom is.
        if t.snap || !bloom {
            ctx.saveGState()
            if t.snap { ctx.addPath(leaf.path); ctx.clip() }
            ctx.addPath(leaf.path)
            ctx.setStrokeColor(edge)
            ctx.setLineWidth(t.snap ? rimWidth * 2 : rimWidth)
            ctx.strokePath()
            ctx.restoreGState()
        }

        guard top || t.underRules else { continue }

        // Type on one leaf, rotated with it and clipped to it, so the rules on
        // the leaves below show only where those leaves are exposed — and get
        // veiled by whatever is laid over them next.
        ctx.saveGState()
        ctx.addPath(leaf.path)
        ctx.clip()
        ctx.translateBy(x: leaf.rect.midX, y: leaf.rect.midY)
        ctx.rotate(by: leaf.angle)
        ctx.translateBy(x: -leaf.rect.midX, y: -leaf.rect.midY)
        // The block is positioned from its own centre, so that widening the
        // rules and forcing their pitch at small sizes does not walk it up the
        // page.
        let blockHeight = rulePitch * 3 + ruleH
        let firstY = snapped(leaf.rect.minY + ruleCentre * g + blockHeight / 2 - ruleH)
        // At 16 px the design's 55 pt margin is a single pixel, which puts the
        // rules against the rim; they are held off it and trimmed to fit.
        let margin = max(ruleInset * g, rimWidth + 1)
        let x = snapped(leaf.rect.minX + margin)
        for index in 0..<4 {
            let width = max(3, min(snapped(ruleWidths[index] * g),
                                   snapped(leaf.rect.width - 2 * margin)))
            let rect = CGRect(x: x, y: firstY - CGFloat(index) * rulePitch,
                              width: width, height: ruleH)
            let radius = ruleH <= 2 ? 0 : ruleH / 2
            let color = top ? accents[index] : palette.ink
            fill(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                        transform: nil), color, in: ctx)
        }
        ctx.restoreGState()
    }
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Output

var outputPath: String?
var dark = false
var fullBleed = false
var side = 1024
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--dark": dark = true
    case "--full-bleed": fullBleed = true
    case "--size":
        guard let value = arguments.first.flatMap(Int.init), value > 0 else {
            FileHandle.standardError.write("--size needs a positive integer\n".data(using: .utf8)!)
            exit(2)
        }
        side = value
        arguments.removeFirst()
    default:
        if argument.hasPrefix("--") {
            FileHandle.standardError.write("unknown option \(argument)\n".data(using: .utf8)!)
            exit(2)
        }
        outputPath = argument
    }
}

guard let outputPath else {
    FileHandle.standardError.write(
        "usage: make-icon.swift <output.png> [--dark] [--full-bleed] [--size N]\n".data(using: .utf8)!
    )
    exit(2)
}

let outputURL = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("failed to create image destination\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(destination, render(side: side, dark: dark, fullBleed: fullBleed), nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write("failed to write \(outputURL.path)\n".data(using: .utf8)!)
    exit(1)
}

print("wrote \(outputURL.path) \(side)px\(dark ? " [dark]" : " [light]")\(fullBleed ? " [full-bleed]" : "")")
