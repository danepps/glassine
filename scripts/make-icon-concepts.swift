// make-icon-concepts.swift — exploratory Glassine app-icon directions.
//
// Produces light/dark concept pairs and review boards, in three rounds: the
// first two are the Folio-era directions that led to the shipping Margin Tabs
// icon, the third takes the Glassine name literally. These are intentionally
// separate from the shipping icon pipeline until a direction is selected.

// Usage: swift scripts/make-icon-concepts.swift <output-directory>


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

func pagePath(_ rect: CGRect, fold: CGFloat, radius: CGFloat = 20) -> CGPath {
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

func fill(_ path: CGPath, _ color: CGColor, in ctx: CGContext) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func pill(_ rect: CGRect, color: CGColor, in ctx: CGContext) {
    fill(CGPath(roundedRect: rect, cornerWidth: rect.height / 2,
                cornerHeight: rect.height / 2, transform: nil), color, in: ctx)
}

func background(in ctx: CGContext, top: CGColor, bottom: CGColor,
                roundedSquare: Bool = false) {
    let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let shape = roundedSquare
        ? CGPath(roundedRect: bounds, cornerWidth: 188, cornerHeight: 188, transform: nil)
        : superellipse(in: bounds)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [top, bottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 220, y: canvas),
                           end: CGPoint(x: 800, y: 0),
                           options: roundedSquare
                               ? [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                               : [])
    ctx.restoreGState()

    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
    ctx.setLineWidth(5)
    ctx.strokePath()
}

func drawPageShadow(_ path: CGPath, fillColor: CGColor, in ctx: CGContext,
                    alpha: CGFloat = 0.38) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 34,
                  color: rgb(0, 0, 0, alpha))
    fill(path, fillColor, in: ctx)
    ctx.restoreGState()
}

func drawFold(rect: CGRect, size: CGFloat, color: CGColor, in ctx: CGContext) {
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: rect.maxX - size, y: rect.maxY))
    flap.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - size))
    flap.addLine(to: CGPoint(x: rect.maxX - size, y: rect.maxY - size))
    flap.closeSubpath()
    fill(flap, color, in: ctx)
}

enum Concept: String, CaseIterable {
    case invert = "Invert"
    case pageStack = "Page Stack"
    case focus = "Focus Band"
}

enum RoundTwoConcept: String, CaseIterable {
    case aperture = "Night Aperture"
    case pageTurn = "Page Turn"
    case openBook = "Open Book"
    case marginTabs = "Margin Tabs"
    case portal = "Reader Portal"
    case foldedF = "Folded F"
}

func drawInvert(dark: Bool) -> CGImage {
    let ctx = context(width: 1024, height: 1024)
    background(in: ctx,
               top: dark ? rgb(22, 31, 49) : rgb(49, 87, 151),
               bottom: dark ? rgb(7, 11, 18) : rgb(18, 34, 64))

    let r = CGRect(x: 236, y: 182, width: 552, height: 660)
    let page = pagePath(r, fold: 138)
    drawPageShadow(page, fillColor: rgb(247, 249, 252), in: ctx, alpha: dark ? 0.60 : 0.36)

    ctx.saveGState()
    ctx.addPath(page)
    ctx.clip()
    ctx.setFillColor(dark ? rgb(30, 38, 52) : rgb(35, 45, 60))
    ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 326))
    ctx.saveGState()
    ctx.clip(to: CGRect(x: r.minX, y: 502, width: r.width, height: 12))
    let seam = CGGradient(colorsSpace: colorSpace,
                          colors: [rgb(77, 213, 255), rgb(93, 111, 255)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(seam,
                           start: CGPoint(x: r.minX, y: 508),
                           end: CGPoint(x: r.maxX, y: 508), options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    drawFold(rect: r, size: 138,
             color: dark ? rgb(189, 203, 222) : rgb(199, 210, 225), in: ctx)

    let darkInk = dark ? rgb(64, 76, 94) : rgb(65, 78, 98)
    let lightInk = dark ? rgb(215, 224, 237) : rgb(223, 231, 241)
    pill(CGRect(x: 310, y: 672, width: 350, height: 29), color: darkInk, in: ctx)
    pill(CGRect(x: 310, y: 608, width: 404, height: 29), color: darkInk, in: ctx)
    pill(CGRect(x: 310, y: 420, width: 404, height: 29), color: lightInk, in: ctx)
    pill(CGRect(x: 310, y: 356, width: 276, height: 29), color: lightInk, in: ctx)
    return ctx.makeImage()!
}

func drawPageStack(dark: Bool) -> CGImage {
    let ctx = context(width: 1024, height: 1024)
    background(in: ctx,
               top: dark ? rgb(20, 45, 45) : rgb(34, 110, 107),
               bottom: dark ? rgb(7, 18, 20) : rgb(9, 49, 56))

    let backRect = CGRect(x: 318, y: 236, width: 486, height: 590)
    let back = pagePath(backRect, fold: 118)
    drawPageShadow(back, fillColor: dark ? rgb(25, 163, 157) : rgb(59, 221, 204),
                   in: ctx, alpha: 0.42)
    drawFold(rect: backRect, size: 118,
             color: dark ? rgb(31, 113, 114) : rgb(30, 151, 150), in: ctx)

    let frontRect = CGRect(x: 218, y: 180, width: 500, height: 620)
    let front = pagePath(frontRect, fold: 126)
    drawPageShadow(front, fillColor: dark ? rgb(42, 51, 58) : rgb(249, 250, 247),
                   in: ctx, alpha: dark ? 0.58 : 0.38)
    if dark {
        ctx.addPath(front)
        ctx.setStrokeColor(rgb(116, 139, 144))
        ctx.setLineWidth(4)
        ctx.strokePath()
    }
    drawFold(rect: frontRect, size: 126,
             color: dark ? rgb(78, 97, 103) : rgb(202, 217, 215), in: ctx)

    let ink = dark ? rgb(201, 216, 218) : rgb(87, 105, 108)
    pill(CGRect(x: 286, y: 622, width: 318, height: 28), color: ink, in: ctx)
    pill(CGRect(x: 286, y: 555, width: 364, height: 28), color: ink, in: ctx)
    pill(CGRect(x: 286, y: 488, width: 292, height: 28), color: ink, in: ctx)
    pill(CGRect(x: 278, y: 397, width: 328, height: 62),
         color: dark ? rgb(25, 174, 161, 0.34) : rgb(55, 213, 191, 0.35), in: ctx)
    pill(CGRect(x: 302, y: 414, width: 246, height: 28),
         color: dark ? rgb(125, 244, 222) : rgb(13, 105, 99), in: ctx)
    return ctx.makeImage()!
}

func drawFocus(dark: Bool) -> CGImage {
    let ctx = context(width: 1024, height: 1024)
    background(in: ctx,
               top: dark ? rgb(44, 29, 47) : rgb(112, 63, 117),
               bottom: dark ? rgb(17, 12, 23) : rgb(48, 26, 63))

    let r = CGRect(x: 226, y: 180, width: 572, height: 664)
    let page = pagePath(r, fold: 138)
    let paper = dark ? rgb(53, 48, 61) : rgb(252, 248, 245)
    drawPageShadow(page, fillColor: paper, in: ctx, alpha: dark ? 0.60 : 0.40)
    if dark {
        ctx.addPath(page)
        ctx.setStrokeColor(rgb(125, 109, 136))
        ctx.setLineWidth(4)
        ctx.strokePath()
    }
    drawFold(rect: r, size: 138,
             color: dark ? rgb(93, 79, 103) : rgb(220, 207, 220), in: ctx)

    let faint = dark ? rgb(158, 147, 168) : rgb(167, 153, 164)
    pill(CGRect(x: 304, y: 665, width: 330, height: 25), color: faint, in: ctx)
    pill(CGRect(x: 304, y: 613, width: 410, height: 25), color: faint, in: ctx)

    let bandRect = CGRect(x: 258, y: 345, width: 508, height: 220)
    fill(CGPath(roundedRect: bandRect, cornerWidth: 36, cornerHeight: 36, transform: nil),
         dark ? rgb(22, 17, 29) : rgb(47, 31, 60), in: ctx)
    pill(CGRect(x: 312, y: 482, width: 366, height: 27), color: rgb(221, 210, 226), in: ctx)
    pill(CGRect(x: 312, y: 425, width: 292, height: 27), color: rgb(246, 184, 67), in: ctx)
    pill(CGRect(x: 304, y: 408, width: 326, height: 61), color: rgb(246, 184, 67, 0.16), in: ctx)
    return ctx.makeImage()!
}

func image(for concept: Concept, dark: Bool) -> CGImage {
    switch concept {
    case .invert: return drawInvert(dark: dark)
    case .pageStack: return drawPageStack(dark: dark)
    case .focus: return drawFocus(dark: dark)
    }
}

func documentColors(dark: Bool) -> (paper: CGColor, ink: CGColor, fold: CGColor, rim: CGColor?) {
    dark
        ? (rgb(8, 11, 15), rgb(245, 248, 252), rgb(42, 48, 58), rgb(125, 140, 160))
        : (rgb(255, 255, 255), rgb(38, 46, 58), rgb(213, 220, 230), nil)
}

func drawDocument(_ rect: CGRect, fold: CGFloat, dark: Bool, in ctx: CGContext,
                  shadow: CGFloat = 0.42) -> CGPath {
    let colors = documentColors(dark: dark)
    let page = pagePath(rect, fold: fold)
    drawPageShadow(page, fillColor: colors.paper, in: ctx, alpha: dark ? 0.65 : shadow)
    if let rim = colors.rim {
        ctx.addPath(page)
        ctx.setStrokeColor(rim)
        ctx.setLineWidth(4)
        ctx.strokePath()
    }
    drawFold(rect: rect, size: fold, color: colors.fold, in: ctx)
    return page
}

func drawAperture(dark: Bool) -> CGImage {
    let ctx = context(width: 1024, height: 1024)
    background(in: ctx,
               top: dark ? rgb(11, 24, 47) : rgb(38, 105, 204),
               bottom: dark ? rgb(3, 7, 15) : rgb(11, 39, 91))
    let colors = documentColors(dark: dark)
    let r = CGRect(x: 224, y: 170, width: 576, height: 682)
    _ = drawDocument(r, fold: 134, dark: dark, in: ctx)

    pill(CGRect(x: 306, y: 685, width: 306, height: 25), color: colors.ink, in: ctx)
    pill(CGRect(x: 306, y: 630, width: 390, height: 25), color: colors.ink, in: ctx)

    let center = CGPoint(x: 520, y: 424)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: rgb(62, 205, 255, 0.50))
    ctx.setFillColor(dark ? rgb(5, 8, 14) : rgb(17, 28, 48))
    ctx.fillEllipse(in: CGRect(x: center.x - 174, y: center.y - 174, width: 348, height: 348))
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(79, 213, 255))
    ctx.setLineWidth(18)
    ctx.strokeEllipse(in: CGRect(x: center.x - 174, y: center.y - 174, width: 348, height: 348))
    pill(CGRect(x: 400, y: 468, width: 242, height: 27), color: rgb(246, 250, 255), in: ctx)
    pill(CGRect(x: 400, y: 411, width: 206, height: 27), color: rgb(246, 250, 255), in: ctx)
    pill(CGRect(x: 400, y: 354, width: 150, height: 27), color: rgb(102, 226, 255), in: ctx)
    return ctx.makeImage()!
}

func transformed(_ path: CGPath, around center: CGPoint, angle: CGFloat) -> CGPath {
    var transform = CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: angle)
        .translatedBy(x: -center.x, y: -center.y)
    return path.copy(using: &transform)!
}

func drawPageTurn(dark: Bool) -> CGImage {
    let ctx = context(width: 1024, height: 1024)
    background(in: ctx,
               top: dark ? rgb(55, 20, 18) : rgb(226, 82, 43),
               bottom: dark ? rgb(18, 7, 8) : rgb(112, 23, 38))
    let colors = documentColors(dark: dark)

    let baseRect = CGRect(x: 270, y: 190, width: 484, height: 640)
    for (offset, angle, alpha) in [(CGSize(width: -58, height: 8), CGFloat(0.13), CGFloat(0.34)),
                                   (CGSize(width: 52, height: 4), CGFloat(-0.11), CGFloat(0.55))] {
        let r = baseRect.offsetBy(dx: offset.width, dy: offset.height)
        let path = transformed(pagePath(r, fold: 116), around: CGPoint(x: r.midX, y: r.midY), angle: angle)
        drawPageShadow(path,
                       fillColor: dark ? rgb(19, 22, 27, alpha + 0.35) : rgb(255, 203, 156, alpha + 0.25),
                       in: ctx, alpha: 0.28)
    }

    let front = pagePath(baseRect, fold: 122)
    drawPageShadow(front, fillColor: colors.paper, in: ctx, alpha: dark ? 0.66 : 0.44)
    if let rim = colors.rim {
        ctx.addPath(front); ctx.setStrokeColor(rim); ctx.setLineWidth(4); ctx.strokePath()
    }
    drawFold(rect: baseRect, size: 122, color: rgb(255, 113, 68), in: ctx)
    pill(CGRect(x: 338, y: 660, width: 260, height: 27), color: colors.ink, in: ctx)
    pill(CGRect(x: 338, y: 600, width: 348, height: 27), color: colors.ink, in: ctx)
    pill(CGRect(x: 338, y: 540, width: 306, height: 27), color: colors.ink, in: ctx)

    // A large turned corner doubles as a forward arrow.
    let turn = CGMutablePath()
    turn.move(to: CGPoint(x: 520, y: 190))
    turn.addCurve(to: CGPoint(x: 754, y: 414),
                  control1: CGPoint(x: 688, y: 206), control2: CGPoint(x: 746, y: 302))
    turn.addLine(to: CGPoint(x: 754, y: 190))
    turn.closeSubpath()
    fill(turn, dark ? rgb(255, 99, 63) : rgb(255, 124, 74), in: ctx)
    return ctx.makeImage()!
}

func drawOpenBook(dark: Bool) -> CGImage {
    let ctx = context(width: 1024, height: 1024)
    background(in: ctx,
               top: dark ? rgb(10, 40, 30) : rgb(38, 145, 93),
               bottom: dark ? rgb(3, 14, 11) : rgb(9, 66, 49))
    let colors = documentColors(dark: dark)

    let left = CGMutablePath()
    left.move(to: CGPoint(x: 176, y: 716))
    left.addCurve(to: CGPoint(x: 500, y: 660), control1: CGPoint(x: 300, y: 752), control2: CGPoint(x: 432, y: 722))
    left.addLine(to: CGPoint(x: 500, y: 244))
    left.addCurve(to: CGPoint(x: 176, y: 302), control1: CGPoint(x: 420, y: 306), control2: CGPoint(x: 306, y: 272))
    left.closeSubpath()
    let right = CGMutablePath()
    right.move(to: CGPoint(x: 848, y: 716))
    right.addCurve(to: CGPoint(x: 524, y: 660), control1: CGPoint(x: 724, y: 752), control2: CGPoint(x: 592, y: 722))
    right.addLine(to: CGPoint(x: 524, y: 244))
    right.addCurve(to: CGPoint(x: 848, y: 302), control1: CGPoint(x: 604, y: 306), control2: CGPoint(x: 718, y: 272))
    right.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: rgb(0, 0, 0, dark ? 0.68 : 0.42))
    fill(left, colors.paper, in: ctx); fill(right, colors.paper, in: ctx)
    ctx.restoreGState()
    if let rim = colors.rim {
        for page in [left, right] { ctx.addPath(page); ctx.setStrokeColor(rim); ctx.setLineWidth(4); ctx.strokePath() }
    }
    ctx.setStrokeColor(dark ? rgb(91, 106, 101) : rgb(196, 208, 202))
    ctx.setLineWidth(10)
    ctx.move(to: CGPoint(x: 512, y: 250)); ctx.addLine(to: CGPoint(x: 512, y: 662)); ctx.strokePath()
    for y in [580, 510, 440] {
        pill(CGRect(x: 238, y: CGFloat(y), width: 196, height: 24), color: colors.ink, in: ctx)
        pill(CGRect(x: 588, y: CGFloat(y), width: y == 440 ? 146 : 198, height: 24), color: colors.ink, in: ctx)
    }
    // Bookmark at the spine gives the open-book silhouette a memorable accent.
    let ribbon = CGMutablePath()
    ribbon.move(to: CGPoint(x: 487, y: 666)); ribbon.addLine(to: CGPoint(x: 537, y: 666))
    ribbon.addLine(to: CGPoint(x: 537, y: 758)); ribbon.addLine(to: CGPoint(x: 512, y: 731))
    ribbon.addLine(to: CGPoint(x: 487, y: 758)); ribbon.closeSubpath()
    fill(ribbon, rgb(255, 199, 56), in: ctx)
    return ctx.makeImage()!
}

func drawMarginTabs(dark: Bool,
                    lightTop: CGColor? = nil, lightBottom: CGColor? = nil,
                    darkTop: CGColor? = nil, darkBottom: CGColor? = nil,
                    showHighlight: Bool = true,
                    roundedBackground: Bool = false,
                    uniformLineWidths: Bool = false) -> CGImage {
    let ctx = context(width: 1024, height: 1024)
    background(in: ctx,
               top: dark ? (darkTop ?? rgb(39, 31, 16)) : (lightTop ?? rgb(185, 126, 29)),
               bottom: dark ? (darkBottom ?? rgb(14, 10, 5)) : (lightBottom ?? rgb(87, 48, 8)),
               roundedSquare: roundedBackground)
    let colors = documentColors(dark: dark)
    let r = CGRect(x: 214, y: 168, width: 546, height: 686)
    let tabColors = [rgb(255, 91, 91), rgb(255, 190, 48), rgb(46, 210, 171), rgb(76, 160, 255)]
    for (i, color) in tabColors.enumerated() {
        let y = 606 - CGFloat(i) * 104
        let tab = CGPath(roundedRect: CGRect(x: 716, y: y, width: 126, height: 62),
                         cornerWidth: 18, cornerHeight: 18, transform: nil)
        fill(tab, color, in: ctx)
    }
    _ = drawDocument(r, fold: 132, dark: dark, in: ctx)
    let topWidths: [CGFloat] = uniformLineWidths ? [380, 380, 380] : [282, 380, 344]
    for (y, width) in zip([CGFloat(680), 617, 512], topWidths) {
        pill(CGRect(x: 292, y: y, width: width, height: 26), color: colors.ink, in: ctx)
    }
    if showHighlight {
        // Match Glassine's in-app find treatment. Dark appearance is deliberately
        // shifted a little cooler than the raw filtered sample: beside the yellow
        // margin tab, the mathematically pure green reads perceptually olive.
        pill(CGRect(x: 278, y: 434, width: 410, height: 64),
             color: dark ? rgb(7, 78, 38) : rgb(40, 205, 65, 0.35), in: ctx)
        pill(CGRect(x: 304, y: 452, width: 302, height: 27),
             color: dark ? rgb(143, 232, 177) : colors.ink, in: ctx)
    } else {
        pill(CGRect(x: 292, y: 452, width: uniformLineWidths ? 380 : 310, height: 26),
             color: colors.ink, in: ctx)
    }
    pill(CGRect(x: 292, y: 368, width: uniformLineWidths ? 380 : 310, height: 26),
         color: colors.ink, in: ctx)
    return ctx.makeImage()!
}

func drawPortal(dark: Bool) -> CGImage {
    let ctx = context(width: 1024, height: 1024)
    background(in: ctx,
               top: dark ? rgb(32, 16, 43) : rgb(117, 48, 170),
               bottom: dark ? rgb(8, 5, 14) : rgb(42, 18, 83))
    let colors = documentColors(dark: dark)

    let ringRect = CGRect(x: 172, y: 172, width: 680, height: 680)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 34, color: rgb(217, 108, 255, 0.60))
    ctx.setStrokeColor(rgb(215, 111, 255))
    ctx.setLineWidth(64)
    ctx.strokeEllipse(in: ringRect)
    ctx.restoreGState()

    let r = CGRect(x: 286, y: 188, width: 452, height: 646)
    _ = drawDocument(r, fold: 114, dark: dark, in: ctx)
    pill(CGRect(x: 344, y: 650, width: 252, height: 26), color: colors.ink, in: ctx)
    pill(CGRect(x: 344, y: 588, width: 328, height: 26), color: colors.ink, in: ctx)
    pill(CGRect(x: 344, y: 526, width: 286, height: 26), color: colors.ink, in: ctx)

    // Redraw the near arc so the sheet appears to pass through the portal.
    let nearArc = CGMutablePath()
    nearArc.addArc(center: CGPoint(x: 512, y: 512), radius: 340,
                   startAngle: .pi * 1.08, endAngle: .pi * 1.92, clockwise: false)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: rgb(217, 108, 255, 0.55))
    ctx.addPath(nearArc); ctx.setStrokeColor(rgb(238, 141, 255)); ctx.setLineWidth(64); ctx.strokePath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

func drawFoldedF(dark: Bool) -> CGImage {
    let ctx = context(width: 1024, height: 1024)
    background(in: ctx,
               top: dark ? rgb(18, 25, 40) : rgb(42, 88, 193),
               bottom: dark ? rgb(4, 7, 12) : rgb(14, 31, 90))

    let mark = CGMutablePath()
    mark.move(to: CGPoint(x: 300, y: 210))
    mark.addLine(to: CGPoint(x: 300, y: 790))
    mark.addArc(tangent1End: CGPoint(x: 300, y: 820), tangent2End: CGPoint(x: 330, y: 820), radius: 30)
    mark.addLine(to: CGPoint(x: 748, y: 820))
    mark.addLine(to: CGPoint(x: 650, y: 690))
    mark.addLine(to: CGPoint(x: 452, y: 690))
    mark.addLine(to: CGPoint(x: 452, y: 570))
    mark.addLine(to: CGPoint(x: 674, y: 570))
    mark.addLine(to: CGPoint(x: 674, y: 438))
    mark.addLine(to: CGPoint(x: 452, y: 438))
    mark.addLine(to: CGPoint(x: 452, y: 210))
    mark.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: rgb(0, 0, 0, 0.46))
    fill(mark, dark ? rgb(250, 252, 255) : rgb(255, 255, 255), in: ctx)
    ctx.restoreGState()

    // The clipped top-right corner turns the monogram into a folded sheet.
    let fold = CGMutablePath()
    fold.move(to: CGPoint(x: 650, y: 690))
    fold.addLine(to: CGPoint(x: 748, y: 820))
    fold.addLine(to: CGPoint(x: 650, y: 820))
    fold.closeSubpath()
    fill(fold, dark ? rgb(88, 205, 255) : rgb(94, 214, 255), in: ctx)
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: 452, y: 438)); notch.addLine(to: CGPoint(x: 674, y: 438))
    notch.addLine(to: CGPoint(x: 624, y: 488)); notch.addLine(to: CGPoint(x: 452, y: 488)); notch.closeSubpath()
    fill(notch, dark ? rgb(205, 236, 255) : rgb(208, 238, 255), in: ctx)
    return ctx.makeImage()!
}

func image(for concept: RoundTwoConcept, dark: Bool) -> CGImage {
    switch concept {
    case .aperture: return drawAperture(dark: dark)
    case .pageTurn: return drawPageTurn(dark: dark)
    case .openBook: return drawOpenBook(dark: dark)
    case .marginTabs: return drawMarginTabs(dark: dark)
    case .portal: return drawPortal(dark: dark)
    case .foldedF: return drawFoldedF(dark: dark)
    }
}

// MARK: - Round three: the name

// Glassine is the semi-transparent, supercalendered paper of archival sleeves,
// envelope windows and the interleaving tissue in art books: paper you can see
// through. The app's own signature feature is a window you can see through,
// with whatever is behind it blurred. Every sheet below is composited the way
// the app composites its window — the backdrop, blurred, plus a milky tint —
// rather than faked with a flat wash, so the small sizes tell the truth about
// how much of the idea actually survives.
//
// The tile palette is held constant across all six (the graphite that Margin
// Tabs shipped on) so what is being compared is the idea, not the colour.

enum RoundThreeConcept: String, CaseIterable {
    case interleaf = "Interleaf"
    case windowPanel = "Window Panel"
    case sleeve = "Sleeve"
    case frost = "Frost"
    case onionskin = "Onionskin"
    case glassineTabs = "Glassine Tabs"
}

struct GlassPalette {
    let tileTop: CGColor
    let tileBottom: CGColor
    let paper: CGColor
    let fold: CGColor
    let ink: CGColor
    let tint: CGColor    // the sheet's own milkiness, over the blurred backdrop
    let rim: CGColor
    let sheen: CGColor
    let accent: CGColor
}

func glassPalette(dark: Bool) -> GlassPalette {
    dark
        ? GlassPalette(tileTop: rgb(35, 41, 49), tileBottom: rgb(11, 14, 18),
                       paper: rgb(8, 11, 15), fold: rgb(42, 48, 58),
                       ink: rgb(240, 244, 250),
                       tint: rgb(22, 27, 34, 0.62),
                       rim: rgb(140, 158, 180, 0.85),
                       sheen: rgb(226, 238, 255, 0.16),
                       accent: rgb(102, 190, 255))
        : GlassPalette(tileTop: rgb(82, 88, 96), tileBottom: rgb(34, 39, 45),
                       paper: rgb(255, 255, 255), fold: rgb(213, 220, 230),
                       ink: rgb(38, 46, 58),
                       tint: rgb(240, 245, 250, 0.60),
                       rim: rgb(255, 255, 255, 0.60),
                       sheen: rgb(255, 255, 255, 0.28),
                       accent: rgb(76, 160, 255))
}

func glassTile(in ctx: CGContext, palette: GlassPalette) {
    background(in: ctx, top: palette.tileTop, bottom: palette.tileBottom,
               roundedSquare: true)
}

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
                let x = min(max(offset, 0), width - 1)
                total += Int(input[row + x * 4 + channel])
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
                let y = min(max(offset, 0), height - 1)
                total += Int(input[y * rowBytes + column + channel])
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

// Downsample, blur small, and let the draw-back-up do the rest of the work.
// A wide blur at 1024 would cost seconds per sheet in an unoptimised script,
// and nothing in the result would be any different.
func veil(_ image: CGImage, scale: Int = 8, radius: Int = 4) -> CGImage {
    let width = max(1, image.width / scale)
    let height = max(1, image.height / scale)
    let rowBytes = width * 4
    var pixels = [UInt8](repeating: 0, count: rowBytes * height)
    pixels.withUnsafeMutableBytes { buffer in
        let small = CGContext(data: buffer.baseAddress, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: rowBytes,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        small.interpolationQuality = .high
        small.draw(image, in: CGRect(x: 0, y: 0,
                                     width: CGFloat(width), height: CGFloat(height)))
    }
    let blurred = boxBlur(pixels, width: width, height: height, radius: radius)

    // Copy into a context that owns its memory: `makeImage()` on a context
    // backed by a client buffer is only a snapshot as long as that buffer
    // lives, and this one dies with the closure. CG may pad its rows, so the
    // copy goes row by row rather than in one memcpy.
    let out = context(width: width, height: height)
    let destination = out.data!
    let destinationRowBytes = out.bytesPerRow
    blurred.withUnsafeBytes { buffer in
        let base = buffer.baseAddress!
        for y in 0..<height {
            memcpy(destination + y * destinationRowBytes, base + y * rowBytes, rowBytes)
        }
    }
    return out.makeImage()!
}

/// Everything drawn so far, blurred — the backdrop a sheet laid down next will
/// show. Take it immediately before laying the sheet.
func veiled(_ ctx: CGContext) -> CGImage {
    veil(ctx.makeImage()!)
}

/// Lay a sheet of glassine: a soft shadow, the blurred backdrop, a milky tint,
/// a sheen along the top edge, and a bright rim. The opaque black under the
/// tint is only there to give the shadow something to cast from; the backdrop
/// draw covers it.
func layGlassine(_ shape: CGPath, backdrop: CGImage, palette: GlassPalette,
                 in ctx: CGContext, shadow: CGFloat = 0.42, tint: CGColor? = nil) {
    let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    if shadow > 0 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 34,
                      color: rgb(0, 0, 0, shadow))
        fill(shape, rgb(0, 0, 0), in: ctx)
        ctx.restoreGState()
    }

    let top = shape.boundingBox.maxY
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(backdrop, in: bounds)
    ctx.setFillColor(tint ?? palette.tint)
    ctx.fill(bounds)
    let sheen = CGGradient(colorsSpace: colorSpace,
                           colors: [palette.sheen, rgb(255, 255, 255, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: 0, y: top),
                           end: CGPoint(x: 0, y: top - 170), options: [])
    ctx.restoreGState()

    ctx.addPath(shape)
    ctx.setStrokeColor(palette.rim)
    ctx.setLineWidth(4)
    ctx.strokePath()
}

/// A grayscale mask for `CGContext.clip(to:mask:)`, ramping bottom to top.
/// White paints, black hides.
func fadeMask(top: CGFloat, bottom: CGFloat) -> CGImage {
    let gray = CGColorSpaceCreateDeviceGray()
    let ctx = CGContext(data: nil, width: 8, height: 512, bitsPerComponent: 8,
                        bytesPerRow: 0, space: gray,
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let gradient = CGGradient(colorsSpace: gray,
                              colors: [CGColor(gray: bottom, alpha: 1),
                                       CGColor(gray: top, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: 0, y: 512), options: [])
    return ctx.makeImage()!
}

// 1. Interleaf. Two sheets: ordinary paper below, a leaf of glassine laid over
// it, so the type underneath reads softened. What glassine is for, and what the
// app does to your desktop, are the same picture.
func drawInterleaf(dark: Bool) -> CGImage {
    let palette = glassPalette(dark: dark)
    let ctx = context(width: 1024, height: 1024)
    glassTile(in: ctx, palette: palette)

    let backRect = CGRect(x: 150, y: 180, width: 500, height: 620)
    let back = pagePath(backRect, fold: 118)
    drawPageShadow(back, fillColor: palette.paper, in: ctx, alpha: dark ? 0.62 : 0.40)
    drawFold(rect: backRect, size: 118, color: palette.fold, in: ctx)
    for (index, width) in [CGFloat(300), 380, 336, 380, 268].enumerated() {
        pill(CGRect(x: 206, y: 640 - CGFloat(index) * 88, width: width, height: 26),
             color: palette.ink, in: ctx)
    }

    let frontRect = CGRect(x: 340, y: 230, width: 500, height: 620)
    let front = pagePath(frontRect, fold: 118)
    layGlassine(front, backdrop: veiled(ctx), palette: palette, in: ctx)
    drawFold(rect: frontRect, size: 118,
             color: rgb(255, 255, 255, dark ? 0.22 : 0.45), in: ctx)
    return ctx.makeImage()!
}

// 2. Window Panel. One opaque sheet with a glassine panel let into it — the
// address window of an envelope. Two materials, one shape: an opaque field
// with a lighter inset rectangle is the version of this set most likely to
// survive to 16 px.
func drawWindowPanel(dark: Bool) -> CGImage {
    let palette = glassPalette(dark: dark)
    let ctx = context(width: 1024, height: 1024)
    glassTile(in: ctx, palette: palette)

    // Type on the page behind, drawn first so the window has something to show.
    // Only what lands inside the panel is ever seen.
    let panel = CGRect(x: 300, y: 300, width: 424, height: 268)
    for (index, width) in [CGFloat(330), 286, 232].enumerated() {
        pill(CGRect(x: 344, y: 486 - CGFloat(index) * 84, width: width, height: 28),
             color: index == 2 ? palette.accent : rgb(246, 249, 253), in: ctx)
    }
    let tile = veiled(ctx)

    let sheetRect = CGRect(x: 232, y: 168, width: 560, height: 688)
    let sheet = pagePath(sheetRect, fold: 130)
    drawPageShadow(sheet, fillColor: palette.paper, in: ctx, alpha: dark ? 0.65 : 0.42)
    drawFold(rect: sheetRect, size: 130, color: palette.fold, in: ctx)
    for (index, width) in [CGFloat(300), 396, 348].enumerated() {
        pill(CGRect(x: 300, y: 700 - CGFloat(index) * 62, width: width, height: 26),
             color: palette.ink, in: ctx)
    }
    pill(CGRect(x: 300, y: 232, width: 320, height: 26), color: palette.ink, in: ctx)

    let window = CGPath(roundedRect: panel, cornerWidth: 22, cornerHeight: 22,
                        transform: nil)
    layGlassine(window, backdrop: tile, palette: palette, in: ctx, shadow: 0)
    return ctx.makeImage()!
}

// 3. Sleeve. A page two-thirds into an archival sleeve: crisp above the lip,
// veiled below it. The lip is the whole mark once the type stops resolving.
func drawSleeve(dark: Bool) -> CGImage {
    let palette = glassPalette(dark: dark)
    let ctx = context(width: 1024, height: 1024)
    glassTile(in: ctx, palette: palette)

    let pageRect = CGRect(x: 268, y: 152, width: 488, height: 720)
    let page = pagePath(pageRect, fold: 116)
    drawPageShadow(page, fillColor: palette.paper, in: ctx, alpha: dark ? 0.62 : 0.40)
    drawFold(rect: pageRect, size: 116, color: palette.fold, in: ctx)
    for (index, width) in [CGFloat(268), 372, 330, 372, 302, 372, 244].enumerated() {
        pill(CGRect(x: 324, y: 740 - CGFloat(index) * 86, width: width, height: 25),
             color: palette.ink, in: ctx)
    }

    let sleeveRect = CGRect(x: 214, y: 128, width: 596, height: 470)
    let sleeve = CGPath(roundedRect: sleeveRect, cornerWidth: 26, cornerHeight: 26,
                        transform: nil)
    layGlassine(sleeve, backdrop: veiled(ctx), palette: palette, in: ctx, shadow: 0.34)
    pill(CGRect(x: 226, y: sleeveRect.maxY - 16, width: 572, height: 12),
         color: rgb(255, 255, 255, dark ? 0.34 : 0.66), in: ctx)
    return ctx.makeImage()!
}

// 4. Frost. One sheet, opacity ramping top to bottom: crisp type at the top
// dissolving into the blurred tile at the bottom. This is the window-opacity
// control drawn as an icon, and the single silhouette of the set — but it is
// also the one most at risk of fighting Icon Composer's own glass on macOS 26,
// which is what the tinted and clear appearances need to be checked for.
func drawFrost(dark: Bool) -> CGImage {
    let palette = glassPalette(dark: dark)
    let ctx = context(width: 1024, height: 1024)
    glassTile(in: ctx, palette: palette)
    let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)

    let rect = CGRect(x: 232, y: 168, width: 560, height: 688)
    let page = pagePath(rect, fold: 130)
    layGlassine(page, backdrop: veiled(ctx), palette: palette, in: ctx)

    // The paper and its type on their own layer, then composited through a
    // vertical ramp so they fade into the glass rather than stopping.
    let layer = context(width: 1024, height: 1024)
    fill(page, palette.paper, in: layer)
    drawFold(rect: rect, size: 130, color: palette.fold, in: layer)
    for (index, width) in [CGFloat(300), 396, 348, 372, 316, 384, 268].enumerated() {
        pill(CGRect(x: 300, y: 706 - CGFloat(index) * 78, width: width, height: 26),
             color: palette.ink, in: layer)
    }
    ctx.saveGState()
    ctx.clip(to: rect, mask: fadeMask(top: 1, bottom: 0.06))
    ctx.draw(layer.makeImage()!, in: bounds)
    ctx.restoreGState()

    // Restate the rim over the paper, which covered the one layGlassine drew.
    ctx.addPath(page)
    ctx.setStrokeColor(palette.rim)
    ctx.setLineWidth(4)
    ctx.strokePath()
    return ctx.makeImage()!
}

// 5. Onionskin. Four leaves fanned, each laid over the ones below it, so the
// overlaps darken on their own rather than being drawn in. Handsome at 1024
// and the likeliest of the six to collapse into mush at 32.
func drawOnionskin(dark: Bool) -> CGImage {
    let palette = glassPalette(dark: dark)
    let ctx = context(width: 1024, height: 1024)
    glassTile(in: ctx, palette: palette)

    let base = CGRect(x: 266, y: 196, width: 492, height: 632)
    let angles: [CGFloat] = [0.20, 0.10, -0.02, -0.13]
    for (index, angle) in angles.enumerated() {
        let rect = base.offsetBy(dx: CGFloat(index) * 6 - 9, dy: CGFloat(index) * -4)
        let leaf = transformed(pagePath(rect, fold: 112),
                               around: CGPoint(x: rect.midX, y: rect.midY), angle: angle)
        layGlassine(leaf, backdrop: veiled(ctx), palette: palette, in: ctx,
                    shadow: 0.26,
                    tint: dark ? rgb(22, 27, 34, 0.34) : rgb(240, 245, 250, 0.34))
    }

    let topRect = base.offsetBy(dx: 9, dy: -12)
    ctx.saveGState()
    ctx.translateBy(x: topRect.midX, y: topRect.midY)
    ctx.rotate(by: angles[angles.count - 1])
    ctx.translateBy(x: -topRect.midX, y: -topRect.midY)
    for (index, width) in [CGFloat(268), 340, 296, 340].enumerated() {
        pill(CGRect(x: 330, y: 600 - CGFloat(index) * 84, width: width, height: 25),
             color: palette.ink, in: ctx)
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

// 6. Glassine Tabs. The shipping icon's geometry with the sheet made
// translucent, so the tile gradient and the buried ends of the margin tabs
// come through it. The low-risk option: the small-size tuning, the document
// icon family and the Markdown .icns all keep working, and the name gets
// acknowledged. The payoff is correspondingly small.
func drawGlassineTabs(dark: Bool) -> CGImage {
    let palette = glassPalette(dark: dark)
    let ctx = context(width: 1024, height: 1024)
    glassTile(in: ctx, palette: palette)

    let rect = CGRect(x: 214, y: 168, width: 546, height: 686)
    let tabColors = [rgb(255, 91, 91), rgb(255, 190, 48),
                     rgb(46, 210, 171), rgb(76, 160, 255)]
    for (index, color) in tabColors.enumerated() {
        let tab = CGPath(roundedRect: CGRect(x: 716, y: 606 - CGFloat(index) * 104,
                                             width: 126, height: 62),
                         cornerWidth: 18, cornerHeight: 18, transform: nil)
        fill(tab, color, in: ctx)
    }

    let sheet = pagePath(rect, fold: 132)
    layGlassine(sheet, backdrop: veiled(ctx), palette: palette, in: ctx)
    drawFold(rect: rect, size: 132,
             color: rgb(255, 255, 255, dark ? 0.20 : 0.42), in: ctx)
    for y in [CGFloat(680), 617, 554, 491, 428] {
        pill(CGRect(x: 292, y: y, width: 380, height: 26), color: palette.ink, in: ctx)
    }
    return ctx.makeImage()!
}

// MARK: - Round four: Onionskin in colour

// The fan from round three, six ways, answering two notes on it: the light pair
// sat on the same graphite tile as every other concept and so read as a dark
// icon, and the type wanted colour. The light tile here is a warm-white to
// light-gray gradient — the Notes/TextEdit register — and the dark tile keeps
// the graphite the shipping icon uses. Geometry, shadows and the glassine
// compositing are unchanged from `drawOnionskin`; only tile, tint and type
// colour vary, so the six are comparable with each other and with round three.

enum RoundFourConcept: String, CaseIterable {
    case paletteRules = "Palette Rules"
    case rainbowFan = "Rainbow Fan"
    case tintedSheets = "Tinted Sheets"
    case highlighter = "Highlighter"
    case colouredEdges = "Coloured Edges"
    case warmPaper = "Warm Paper"
}

// The shipping icon's margin-tab colours, unaltered: coral, amber, mint, blue.
let tabPalette = [rgb(255, 91, 91), rgb(255, 190, 48),
                  rgb(46, 210, 171), rgb(76, 160, 255)]

func mix(_ base: CGColor, _ other: CGColor, _ amount: CGFloat, alpha: CGFloat) -> CGColor {
    let b = base.components!, o = other.components!
    return CGColor(red: b[0] + (o[0] - b[0]) * amount,
                   green: b[1] + (o[1] - b[1]) * amount,
                   blue: b[2] + (o[2] - b[2]) * amount, alpha: alpha)
}

func onionPalette(dark: Bool) -> GlassPalette {
    dark
        ? glassPalette(dark: true)
        : GlassPalette(tileTop: rgb(247, 245, 240), tileBottom: rgb(197, 202, 212),
                       paper: rgb(255, 255, 255), fold: rgb(216, 222, 231),
                       ink: rgb(38, 46, 58),
                       tint: rgb(255, 255, 255, 0.62),
                       // On a pale tile a white rim is invisible; the sheets are
                       // separated by a slate edge and their shadows instead.
                       rim: rgb(120, 134, 155, 0.78),
                       sheen: rgb(255, 255, 255, 0.40),
                       accent: rgb(255, 91, 91))
}

struct OnionSheet {
    let rect: CGRect
    let angle: CGFloat
    let path: CGPath
}

func onionSheets() -> [OnionSheet] {
    let base = CGRect(x: 266, y: 196, width: 492, height: 632)
    let angles: [CGFloat] = [0.20, 0.10, -0.02, -0.13]
    return angles.enumerated().map { index, angle in
        let rect = base.offsetBy(dx: CGFloat(index) * 6 - 9, dy: CGFloat(index) * -4)
        let path = transformed(pagePath(rect, fold: 112),
                               around: CGPoint(x: rect.midX, y: rect.midY), angle: angle)
        return OnionSheet(rect: rect, angle: angle, path: path)
    }
}

/// Type on one leaf, rotated with it and clipped to it, so the lines on the
/// leaves below show only where those leaves are exposed — and get veiled by
/// whatever is laid over them next. Lines are 32 px rather than round three's
/// 25: colour carries far less of itself than slate does down at 32 px.
func drawSheetLines(_ sheet: OnionSheet, colors: [CGColor], in ctx: CGContext,
                    height: CGFloat = 34, highlight: (index: Int, color: CGColor)? = nil) {
    let widths: [CGFloat] = [268, 340, 296, 340]
    let offsets: [CGFloat] = [416, 332, 248, 164]
    ctx.saveGState()
    ctx.addPath(sheet.path)
    ctx.clip()
    ctx.translateBy(x: sheet.rect.midX, y: sheet.rect.midY)
    ctx.rotate(by: sheet.angle)
    ctx.translateBy(x: -sheet.rect.midX, y: -sheet.rect.midY)
    for index in 0..<4 {
        let line = CGRect(x: sheet.rect.minX + 55, y: sheet.rect.minY + offsets[index],
                          width: widths[index], height: height)
        if let highlight, highlight.index == index {
            pill(line.insetBy(dx: -22, dy: -16), color: highlight.color, in: ctx)
        }
        pill(line, color: colors[index % colors.count], in: ctx)
    }
    ctx.restoreGState()
}

/// The sheet's own milkiness. The top leaf is always the most opaque so its
/// type stays crisp while the stack below it stays veiled.
func onionTint(_ variant: RoundFourConcept, index: Int, dark: Bool) -> CGColor {
    let top = index == 3
    switch variant {
    case .tintedSheets:
        // Coral in front on the light tile. Dark reverses the order and takes
        // far less hue: warm colours mixed into near-black go sepia long before
        // they read as tinted glass, so blue leads and coral is left to the
        // exposed edges behind.
        let hue = dark ? tabPalette[index] : tabPalette[3 - index]
        let base = dark ? rgb(20, 25, 32) : rgb(255, 255, 255)
        return mix(base, hue, dark ? (top ? 0.09 : 0.26) : (top ? 0.17 : 0.32),
                   alpha: dark ? (top ? 0.60 : 0.44) : (top ? 0.80 : 0.60))
    case .warmPaper:
        return dark ? rgb(30, 27, 23, top ? 0.60 : 0.38)
                    : rgb(253, 247, 236, top ? 0.82 : 0.58)
    default:
        return dark ? rgb(22, 27, 34, top ? 0.58 : 0.34)
                    : rgb(255, 255, 255, top ? 0.80 : 0.54)
    }
}

func onionLineColors(_ variant: RoundFourConcept, index: Int,
                     slate: CGColor) -> [CGColor] {
    switch variant {
    case .paletteRules:
        return index == 3 ? tabPalette : [slate]
    case .rainbowFan:
        return (0..<4).map { tabPalette[(index + $0) % 4] }
    case .warmPaper:
        return index == 3 ? [slate, slate, tabPalette[0], slate] : [slate]
    default:
        return [slate]
    }
}

/// A copy of `palette` on a different tile, with the top-edge sheen scaled.
func restyled(_ palette: GlassPalette, tileTop: CGColor? = nil,
              tileBottom: CGColor? = nil, sheen scale: CGFloat = 1) -> GlassPalette {
    GlassPalette(tileTop: tileTop ?? palette.tileTop,
                 tileBottom: tileBottom ?? palette.tileBottom,
                 paper: palette.paper, fold: palette.fold, ink: palette.ink,
                 tint: palette.tint, rim: palette.rim,
                 sheen: palette.sheen.copy(alpha: palette.sheen.alpha * scale)!,
                 accent: palette.accent)
}

/// Taking a sheet's tint toward opaque as the sheen level drops. The soft light
/// across a dark leaf is only half the top-edge gradient; the rest is the type
/// on the leaves underneath, glowing up through the blurred backdrop, and the
/// only thing that shuts that off is a less transparent sheet.
func dimmed(_ tint: CGColor, sheen scale: CGFloat) -> CGColor {
    let alpha = tint.alpha
    return tint.copy(alpha: alpha + (1 - alpha) * (1 - scale) * 0.85)!
}

func drawOnionskinColour(_ variant: RoundFourConcept, dark: Bool,
                         tile: (top: CGColor, bottom: CGColor)? = nil,
                         paperAlpha: (top: CGFloat, under: CGFloat)? = nil,
                         shadow: CGFloat? = nil,
                         sheen: CGFloat = 1,
                         neonEdges: Bool = false) -> CGImage {
    let palette = restyled(onionPalette(dark: dark), tileTop: tile?.top,
                           tileBottom: tile?.bottom, sheen: sheen)
    let ctx = context(width: 1024, height: 1024)
    glassTile(in: ctx, palette: palette)

    let slate = variant == .warmPaper && !dark ? rgb(64, 60, 54) : palette.ink
    for (index, sheet) in onionSheets().enumerated() {
        var tint = onionTint(variant, index: index, dark: dark)
        if let paperAlpha {
            tint = tint.copy(alpha: index == 3 ? paperAlpha.top : paperAlpha.under)!
        }
        layGlassine(sheet.path, backdrop: veiled(ctx), palette: palette, in: ctx,
                    shadow: shadow ?? (dark ? 0.26 : 0.36),
                    tint: dimmed(tint, sheen: sheen))
        if variant == .colouredEdges || neonEdges {
            // On a pale tile the dark row's wide bloom reads as a smear rather
            // than an edge, so the light crossing gets a tighter, weaker glow.
            let soft = neonEdges && !dark
            let edge = tabPalette[3 - index]
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: soft ? 11 : 20,
                          color: edge.copy(alpha: soft ? 0.42 : 0.65)!)
            ctx.addPath(sheet.path)
            ctx.setStrokeColor(edge)
            ctx.setLineWidth(soft ? 8 : 9)
            ctx.strokePath()
            ctx.restoreGState()
        }
        let highlight = variant == .highlighter
            ? (index: index, color: tabPalette[3 - index].copy(alpha: dark ? 0.42 : 0.46)!)
            : nil
        drawSheetLines(sheet, colors: onionLineColors(variant, index: index, slate: slate),
                       in: ctx, highlight: highlight)
    }
    return ctx.makeImage()!
}

/// Successive halving before the final draw. A single 1024 → 32 draw, even at
/// high interpolation quality, drops thin lines outright; the mipmap chain lets
/// them survive as tone, which is what the 32 px cells are there to show.
func downsample(_ image: CGImage, to size: Int) -> CGImage {
    var current = image
    while current.width / 2 > size {
        let side = current.width / 2
        let step = context(width: side, height: side)
        step.draw(current, in: CGRect(x: 0, y: 0, width: side, height: side))
        current = step.makeImage()!
    }
    guard current.width != size else { return current }
    let out = context(width: size, height: size)
    out.draw(current, in: CGRect(x: 0, y: 0, width: size, height: size))
    return out.makeImage()!
}

func image(for concept: RoundThreeConcept, dark: Bool) -> CGImage {
    switch concept {
    case .interleaf: return drawInterleaf(dark: dark)
    case .windowPanel: return drawWindowPanel(dark: dark)
    case .sleeve: return drawSleeve(dark: dark)
    case .frost: return drawFrost(dark: dark)
    case .onionskin: return drawOnionskin(dark: dark)
    case .glassineTabs: return drawGlassineTabs(dark: dark)
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
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift scripts/make-icon-concepts.swift <output-directory>\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var images: [String: CGImage] = [:]
for concept in Concept.allCases {
    for dark in [false, true] {
        let rendered = image(for: concept, dark: dark)
        let suffix = dark ? "dark" : "light"
        let key = "\(concept.rawValue)-\(suffix)"
        images[key] = rendered
        write(rendered, to: output.appendingPathComponent("glassine-concept-\(concept.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))-\(suffix).png"))
    }
}

// A single sheet for evaluating visual character and 32/64 px legibility.
let board = context(width: 2400, height: 1680)
board.setFillColor(rgb(236, 239, 243))
board.fill(CGRect(x: 0, y: 0, width: 2400, height: 1680))
label("Glassine — app icon directions", at: CGPoint(x: 120, y: 1570),
      size: 54, color: rgb(28, 35, 45), in: board)
label("Light and dark appearance studies · with 64 px and 32 px checks", at: CGPoint(x: 122, y: 1512),
      size: 28, color: rgb(91, 101, 114), in: board)

let columns: [CGFloat] = [120, 900, 1680]
for (index, concept) in Concept.allCases.enumerated() {
    let x = columns[index]
    label("\(index + 1)  \(concept.rawValue)", at: CGPoint(x: x, y: 1425),
          size: 36, color: rgb(32, 40, 51), in: board)
    let light = images["\(concept.rawValue)-light"]!
    let dark = images["\(concept.rawValue)-dark"]!
    board.draw(light, in: CGRect(x: x, y: 770, width: 560, height: 560))
    board.draw(dark, in: CGRect(x: x, y: 170, width: 560, height: 560))
    label("LIGHT", at: CGPoint(x: x + 590, y: 1256), size: 19,
          color: rgb(91, 101, 114), in: board)
    label("DARK", at: CGPoint(x: x + 590, y: 656), size: 19,
          color: rgb(91, 101, 114), in: board)
    board.draw(light, in: CGRect(x: x + 590, y: 1150, width: 64, height: 64))
    board.draw(light, in: CGRect(x: x + 606, y: 1092, width: 32, height: 32))
    board.draw(dark, in: CGRect(x: x + 590, y: 550, width: 64, height: 64))
    board.draw(dark, in: CGRect(x: x + 606, y: 492, width: 32, height: 32))
}

write(board.makeImage()!, to: output.appendingPathComponent("glassine-icon-concepts-board.png"))

var roundTwoImages: [String: CGImage] = [:]
for concept in RoundTwoConcept.allCases {
    for dark in [false, true] {
        let rendered = image(for: concept, dark: dark)
        let suffix = dark ? "dark" : "light"
        let key = "\(concept.rawValue)-\(suffix)"
        roundTwoImages[key] = rendered
        let stem = concept.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        write(rendered, to: output.appendingPathComponent("glassine-concept-v2-\(stem)-\(suffix).png"))
    }
}

let boardTwo = context(width: 3000, height: 2280)
boardTwo.setFillColor(rgb(236, 239, 243))
boardTwo.fill(CGRect(x: 0, y: 0, width: 3000, height: 2280))
label("Glassine — expanded icon directions", at: CGPoint(x: 120, y: 2170),
      size: 58, color: rgb(28, 35, 45), in: boardTwo)
label("White paper in light appearance · black paper with white type in dark appearance", at: CGPoint(x: 122, y: 2106),
      size: 29, color: rgb(91, 101, 114), in: boardTwo)

for (index, concept) in RoundTwoConcept.allCases.enumerated() {
    let column = index % 3
    let row = index / 3
    let x = CGFloat(column) * 960 + 100
    let y = row == 0 ? CGFloat(1120) : CGFloat(120)
    let titleY = y + 820
    label("\(index + 1)  \(concept.rawValue)", at: CGPoint(x: x, y: titleY),
          size: 38, color: rgb(32, 40, 51), in: boardTwo)
    label("LIGHT", at: CGPoint(x: x, y: y + 760), size: 18,
          color: rgb(91, 101, 114), in: boardTwo)
    label("DARK", at: CGPoint(x: x + 430, y: y + 760), size: 18,
          color: rgb(91, 101, 114), in: boardTwo)
    let light = roundTwoImages["\(concept.rawValue)-light"]!
    let dark = roundTwoImages["\(concept.rawValue)-dark"]!
    boardTwo.draw(light, in: CGRect(x: x, y: y + 280, width: 410, height: 410))
    boardTwo.draw(dark, in: CGRect(x: x + 430, y: y + 280, width: 410, height: 410))
    label("64", at: CGPoint(x: x + 4, y: y + 210), size: 16,
          color: rgb(116, 125, 137), in: boardTwo)
    label("32", at: CGPoint(x: x + 98, y: y + 210), size: 16,
          color: rgb(116, 125, 137), in: boardTwo)
    boardTwo.draw(light, in: CGRect(x: x, y: y + 120, width: 64, height: 64))
    boardTwo.draw(light, in: CGRect(x: x + 96, y: y + 136, width: 32, height: 32))
    boardTwo.draw(dark, in: CGRect(x: x + 430, y: y + 120, width: 64, height: 64))
    boardTwo.draw(dark, in: CGRect(x: x + 526, y: y + 136, width: 32, height: 32))
}

write(boardTwo.makeImage()!, to: output.appendingPathComponent("glassine-icon-concepts-v2-board.png"))

struct BackgroundOption {
    let name: String
    let slug: String
    let top: CGColor
    let bottom: CGColor
    let hex: String
}

let marginBackgrounds: [BackgroundOption] = [
    BackgroundOption(name: "Ink Blue", slug: "ink-blue",
                     top: rgb(64, 100, 135), bottom: rgb(22, 49, 73),
                     hex: "#406487 → #163149"),
    BackgroundOption(name: "Blue Slate", slug: "blue-slate",
                     top: rgb(92, 108, 124), bottom: rgb(40, 51, 64),
                     hex: "#5C6C7C → #283340"),
    BackgroundOption(name: "Graphite", slug: "graphite",
                     top: rgb(82, 88, 96), bottom: rgb(34, 39, 45),
                     hex: "#525860 → #22272D"),
    BackgroundOption(name: "Quiet Indigo", slug: "quiet-indigo",
                     top: rgb(79, 91, 157), bottom: rgb(37, 43, 91),
                     hex: "#4F5B9D → #252B5B"),
    BackgroundOption(name: "Aubergine", slug: "aubergine",
                     top: rgb(111, 75, 108), bottom: rgb(57, 34, 57),
                     hex: "#6F4B6C → #392239"),
    BackgroundOption(name: "Brick", slug: "brick",
                     top: rgb(163, 77, 62), bottom: rgb(91, 37, 34),
                     hex: "#A34D3E → #5B2522"),
    BackgroundOption(name: "Forest", slug: "forest",
                     top: rgb(70, 112, 87), bottom: rgb(32, 61, 45),
                     hex: "#467057 → #203D2D"),
    BackgroundOption(name: "Soft Stone", slug: "soft-stone",
                     top: rgb(119, 111, 99), bottom: rgb(68, 61, 53),
                     hex: "#776F63 → #443D35")
]

var marginPaletteImages: [CGImage] = []
for option in marginBackgrounds {
    let rendered = drawMarginTabs(dark: false, lightTop: option.top, lightBottom: option.bottom)
    marginPaletteImages.append(rendered)
    write(rendered, to: output.appendingPathComponent("glassine-margin-tabs-bg-\(option.slug).png"))
}

let paletteBoard = context(width: 3000, height: 1800)
paletteBoard.setFillColor(rgb(236, 239, 243))
paletteBoard.fill(CGRect(x: 0, y: 0, width: 3000, height: 1800))
label("Margin Tabs — light background studies", at: CGPoint(x: 110, y: 1695),
      size: 56, color: rgb(28, 35, 45), in: paletteBoard)
label("Document, typography, tabs, lighting, and geometry held constant", at: CGPoint(x: 112, y: 1635),
      size: 28, color: rgb(91, 101, 114), in: paletteBoard)

for index in marginBackgrounds.indices {
    let column = index % 4
    let row = index / 4
    let x = CGFloat(column) * 735 + 90
    let y = row == 0 ? CGFloat(830) : CGFloat(70)
    let option = marginBackgrounds[index]
    let rendered = marginPaletteImages[index]
    label("\(index + 1)  \(option.name)", at: CGPoint(x: x, y: y + 650),
          size: 34, color: rgb(32, 40, 51), in: paletteBoard)
    label(option.hex, at: CGPoint(x: x, y: y + 608),
          size: 20, color: rgb(105, 114, 126), in: paletteBoard)
    paletteBoard.draw(rendered, in: CGRect(x: x, y: y + 70, width: 500, height: 500))
    paletteBoard.draw(rendered, in: CGRect(x: x + 525, y: y + 405, width: 64, height: 64))
    paletteBoard.draw(rendered, in: CGRect(x: x + 541, y: y + 340, width: 32, height: 32))
}

write(paletteBoard.makeImage()!, to: output.appendingPathComponent("glassine-margin-tabs-light-backgrounds.png"))

let selectedLight = drawMarginTabs(
    dark: false,
    lightTop: rgb(82, 88, 96), lightBottom: rgb(34, 39, 45)
)
let selectedDark = drawMarginTabs(
    dark: true,
    darkTop: rgb(35, 41, 49), darkBottom: rgb(11, 14, 18)
)
write(selectedLight, to: output.appendingPathComponent("glassine-margin-tabs-selected-light.png"))
write(selectedDark, to: output.appendingPathComponent("glassine-margin-tabs-selected-dark.png"))

let selectedBoard = context(width: 1900, height: 1160)
selectedBoard.setFillColor(rgb(236, 239, 243))
selectedBoard.fill(CGRect(x: 0, y: 0, width: 1900, height: 1160))
label("Margin Tabs — selected graphite pair", at: CGPoint(x: 110, y: 1050),
      size: 54, color: rgb(28, 35, 45), in: selectedBoard)
label("Candidate artwork · shipping assets unchanged", at: CGPoint(x: 112, y: 992),
      size: 27, color: rgb(91, 101, 114), in: selectedBoard)
label("LIGHT · GRAPHITE", at: CGPoint(x: 110, y: 900), size: 22,
      color: rgb(91, 101, 114), in: selectedBoard)
label("DARK · NEUTRAL BLACK", at: CGPoint(x: 960, y: 900), size: 22,
      color: rgb(91, 101, 114), in: selectedBoard)
selectedBoard.draw(selectedLight, in: CGRect(x: 110, y: 190, width: 680, height: 680))
selectedBoard.draw(selectedDark, in: CGRect(x: 960, y: 190, width: 680, height: 680))
selectedBoard.draw(selectedLight, in: CGRect(x: 810, y: 520, width: 64, height: 64))
selectedBoard.draw(selectedLight, in: CGRect(x: 826, y: 452, width: 32, height: 32))
selectedBoard.draw(selectedDark, in: CGRect(x: 1660, y: 520, width: 64, height: 64))
selectedBoard.draw(selectedDark, in: CGRect(x: 1676, y: 452, width: 32, height: 32))
write(selectedBoard.makeImage()!, to: output.appendingPathComponent("glassine-margin-tabs-selected-pair.png"))

struct ShapeVariant {
    let name: String
    let slug: String
    let showHighlight: Bool
    let roundedBackground: Bool
}

let shapeVariants = [
    ShapeVariant(name: "Clean Page", slug: "clean-page",
                 showHighlight: false, roundedBackground: false),
    ShapeVariant(name: "Four Corners", slug: "four-corners",
                 showHighlight: true, roundedBackground: true),
    ShapeVariant(name: "Clean + Rounded", slug: "clean-rounded",
                 showHighlight: false, roundedBackground: true)
]

var variantPairs: [(light: CGImage, dark: CGImage)] = []
for variant in shapeVariants {
    let light = drawMarginTabs(
        dark: false,
        lightTop: rgb(82, 88, 96), lightBottom: rgb(34, 39, 45),
        showHighlight: variant.showHighlight,
        roundedBackground: variant.roundedBackground
    )
    let dark = drawMarginTabs(
        dark: true,
        darkTop: rgb(35, 41, 49), darkBottom: rgb(11, 14, 18),
        showHighlight: variant.showHighlight,
        roundedBackground: variant.roundedBackground
    )
    variantPairs.append((light, dark))
    write(light, to: output.appendingPathComponent("glassine-margin-tabs-\(variant.slug)-light.png"))
    write(dark, to: output.appendingPathComponent("glassine-margin-tabs-\(variant.slug)-dark.png"))
}

let shapeBoard = context(width: 3000, height: 1260)
shapeBoard.setFillColor(rgb(236, 239, 243))
shapeBoard.fill(CGRect(x: 0, y: 0, width: 3000, height: 1260))
label("Margin Tabs — highlight and frame studies", at: CGPoint(x: 110, y: 1150),
      size: 56, color: rgb(28, 35, 45), in: shapeBoard)
label("Light and dark pairs · graphite palette and document geometry held constant", at: CGPoint(x: 112, y: 1090),
      size: 28, color: rgb(91, 101, 114), in: shapeBoard)

for index in shapeVariants.indices {
    let x = CGFloat(index) * 960 + 90
    let variant = shapeVariants[index]
    let pair = variantPairs[index]
    label("\(index + 1)  \(variant.name)", at: CGPoint(x: x, y: 995),
          size: 38, color: rgb(32, 40, 51), in: shapeBoard)
    label("LIGHT", at: CGPoint(x: x, y: 938), size: 18,
          color: rgb(91, 101, 114), in: shapeBoard)
    label("DARK", at: CGPoint(x: x + 430, y: 938), size: 18,
          color: rgb(91, 101, 114), in: shapeBoard)
    shapeBoard.draw(pair.light, in: CGRect(x: x, y: 400, width: 410, height: 410))
    shapeBoard.draw(pair.dark, in: CGRect(x: x + 430, y: 400, width: 410, height: 410))
    shapeBoard.draw(pair.light, in: CGRect(x: x, y: 270, width: 64, height: 64))
    shapeBoard.draw(pair.light, in: CGRect(x: x + 92, y: 286, width: 32, height: 32))
    shapeBoard.draw(pair.dark, in: CGRect(x: x + 430, y: 270, width: 64, height: 64))
    shapeBoard.draw(pair.dark, in: CGRect(x: x + 522, y: 286, width: 32, height: 32))
}

write(shapeBoard.makeImage()!, to: output.appendingPathComponent("glassine-margin-tabs-shape-variants.png"))

let equalLinesLight = drawMarginTabs(
    dark: false,
    lightTop: rgb(82, 88, 96), lightBottom: rgb(34, 39, 45),
    showHighlight: false, roundedBackground: true, uniformLineWidths: true
)
let equalLinesDark = drawMarginTabs(
    dark: true,
    darkTop: rgb(35, 41, 49), darkBottom: rgb(11, 14, 18),
    showHighlight: false, roundedBackground: true, uniformLineWidths: true
)
write(equalLinesLight, to: output.appendingPathComponent("glassine-margin-tabs-clean-rounded-equal-lines-light.png"))
write(equalLinesDark, to: output.appendingPathComponent("glassine-margin-tabs-clean-rounded-equal-lines-dark.png"))

let equalLinesBoard = context(width: 1900, height: 1160)
equalLinesBoard.setFillColor(rgb(236, 239, 243))
equalLinesBoard.fill(CGRect(x: 0, y: 0, width: 1900, height: 1160))
label("Margin Tabs — clean, rounded, equal lines", at: CGPoint(x: 110, y: 1050),
      size: 54, color: rgb(28, 35, 45), in: equalLinesBoard)
label("Option 3 refinement · line spacing and all other geometry unchanged", at: CGPoint(x: 112, y: 992),
      size: 27, color: rgb(91, 101, 114), in: equalLinesBoard)
label("LIGHT", at: CGPoint(x: 110, y: 900), size: 22,
      color: rgb(91, 101, 114), in: equalLinesBoard)
label("DARK", at: CGPoint(x: 960, y: 900), size: 22,
      color: rgb(91, 101, 114), in: equalLinesBoard)
equalLinesBoard.draw(equalLinesLight, in: CGRect(x: 110, y: 190, width: 680, height: 680))
equalLinesBoard.draw(equalLinesDark, in: CGRect(x: 960, y: 190, width: 680, height: 680))
equalLinesBoard.draw(equalLinesLight, in: CGRect(x: 810, y: 520, width: 64, height: 64))
equalLinesBoard.draw(equalLinesLight, in: CGRect(x: 826, y: 452, width: 32, height: 32))
equalLinesBoard.draw(equalLinesDark, in: CGRect(x: 1660, y: 520, width: 64, height: 64))
equalLinesBoard.draw(equalLinesDark, in: CGRect(x: 1676, y: 452, width: 32, height: 32))
write(equalLinesBoard.makeImage()!, to: output.appendingPathComponent("glassine-margin-tabs-clean-rounded-equal-lines-pair.png"))

var roundThreeImages: [String: CGImage] = [:]
for concept in RoundThreeConcept.allCases {
    for dark in [false, true] {
        let rendered = image(for: concept, dark: dark)
        let suffix = dark ? "dark" : "light"
        roundThreeImages["\(concept.rawValue)-\(suffix)"] = rendered
        let stem = concept.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        write(rendered, to: output.appendingPathComponent("glassine-concept-v3-\(stem)-\(suffix).png"))
    }
}

let boardThree = context(width: 3000, height: 2280)
boardThree.setFillColor(rgb(236, 239, 243))
boardThree.fill(CGRect(x: 0, y: 0, width: 3000, height: 2280))
label("Glassine — directions from the name", at: CGPoint(x: 120, y: 2170),
      size: 58, color: rgb(28, 35, 45), in: boardThree)
label("Translucent paper over a blurred backdrop · graphite tile held constant · 64 px and 32 px checks",
      at: CGPoint(x: 122, y: 2106), size: 29, color: rgb(91, 101, 114), in: boardThree)

for (index, concept) in RoundThreeConcept.allCases.enumerated() {
    let column = index % 3
    let row = index / 3
    let x = CGFloat(column) * 960 + 100
    let y = row == 0 ? CGFloat(1120) : CGFloat(120)
    label("\(index + 1)  \(concept.rawValue)", at: CGPoint(x: x, y: y + 820),
          size: 38, color: rgb(32, 40, 51), in: boardThree)
    label("LIGHT", at: CGPoint(x: x, y: y + 760), size: 18,
          color: rgb(91, 101, 114), in: boardThree)
    label("DARK", at: CGPoint(x: x + 430, y: y + 760), size: 18,
          color: rgb(91, 101, 114), in: boardThree)
    let light = roundThreeImages["\(concept.rawValue)-light"]!
    let dark = roundThreeImages["\(concept.rawValue)-dark"]!
    boardThree.draw(light, in: CGRect(x: x, y: y + 280, width: 410, height: 410))
    boardThree.draw(dark, in: CGRect(x: x + 430, y: y + 280, width: 410, height: 410))
    label("64", at: CGPoint(x: x + 4, y: y + 210), size: 16,
          color: rgb(116, 125, 137), in: boardThree)
    label("32", at: CGPoint(x: x + 98, y: y + 210), size: 16,
          color: rgb(116, 125, 137), in: boardThree)
    boardThree.draw(light, in: CGRect(x: x, y: y + 120, width: 64, height: 64))
    boardThree.draw(light, in: CGRect(x: x + 96, y: y + 136, width: 32, height: 32))
    boardThree.draw(dark, in: CGRect(x: x + 430, y: y + 120, width: 64, height: 64))
    boardThree.draw(dark, in: CGRect(x: x + 526, y: y + 136, width: 32, height: 32))
}

write(boardThree.makeImage()!, to: output.appendingPathComponent("glassine-icon-concepts-v3-board.png"))

var roundFourImages: [String: CGImage] = [:]
for concept in RoundFourConcept.allCases {
    for dark in [false, true] {
        let rendered = drawOnionskinColour(concept, dark: dark)
        let suffix = dark ? "dark" : "light"
        roundFourImages["\(concept.rawValue)-\(suffix)"] = rendered
        let stem = concept.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        write(rendered, to: output.appendingPathComponent("glassine-concept-v4-\(stem)-\(suffix).png"))
    }
}

let boardFour = context(width: 3600, height: 2200)
boardFour.setFillColor(rgb(236, 239, 243))
boardFour.fill(CGRect(x: 0, y: 0, width: 3600, height: 2200))
label("Glassine — Onionskin in colour", at: CGPoint(x: 120, y: 2120),
      size: 58, color: rgb(28, 35, 45), in: boardFour)
label("Round three's fan on a warm-white tile in light appearance · graphite in dark · 64 px and 32 px checks",
      at: CGPoint(x: 122, y: 2058), size: 29, color: rgb(91, 101, 114), in: boardFour)

for (index, concept) in RoundFourConcept.allCases.enumerated() {
    let x = CGFloat(index % 3) * 1170 + 90
    let y = index / 3 == 0 ? CGFloat(1100) : CGFloat(140)
    let darkX = x + 560
    let light = roundFourImages["\(concept.rawValue)-light"]!
    let dark = roundFourImages["\(concept.rawValue)-dark"]!

    // The dark pair sits on its own dark panel: at 64 and 32 px a dark icon on
    // a light board reads as a blob, which says nothing about the artwork.
    fill(CGPath(roundedRect: CGRect(x: darkX - 28, y: y + 100, width: 568, height: 780),
                cornerWidth: 26, cornerHeight: 26, transform: nil),
         rgb(26, 30, 36), in: boardFour)
    // A greyer chip under the light thumbnails: a pale tile on the pale board
    // has no edge, which flatters it in exactly the place it must not be.
    fill(CGPath(roundedRect: CGRect(x: x - 20, y: y + 120, width: 190, height: 110),
                cornerWidth: 18, cornerHeight: 18, transform: nil),
         rgb(203, 209, 218), in: boardFour)

    label("\(index + 1)  \(concept.rawValue)", at: CGPoint(x: x, y: y + 915),
          size: 40, color: rgb(32, 40, 51), in: boardFour)
    label("LIGHT", at: CGPoint(x: x, y: y + 838), size: 20,
          color: rgb(91, 101, 114), in: boardFour)
    label("DARK", at: CGPoint(x: darkX, y: y + 838), size: 20,
          color: rgb(150, 160, 174), in: boardFour)
    boardFour.draw(downsample(light, to: 512), in: CGRect(x: x, y: y + 300, width: 512, height: 512))
    boardFour.draw(downsample(dark, to: 512), in: CGRect(x: darkX, y: y + 300, width: 512, height: 512))

    label("64", at: CGPoint(x: x + 4, y: y + 230), size: 17,
          color: rgb(116, 125, 137), in: boardFour)
    label("32", at: CGPoint(x: x + 100, y: y + 230), size: 17,
          color: rgb(116, 125, 137), in: boardFour)
    label("64", at: CGPoint(x: darkX + 4, y: y + 230), size: 17,
          color: rgb(140, 150, 164), in: boardFour)
    label("32", at: CGPoint(x: darkX + 100, y: y + 230), size: 17,
          color: rgb(140, 150, 164), in: boardFour)
    boardFour.draw(downsample(light, to: 64), in: CGRect(x: x, y: y + 140, width: 64, height: 64))
    boardFour.draw(downsample(light, to: 32), in: CGRect(x: x + 96, y: y + 156, width: 32, height: 32))
    boardFour.draw(downsample(dark, to: 64), in: CGRect(x: darkX, y: y + 140, width: 64, height: 64))
    boardFour.draw(downsample(dark, to: 32), in: CGRect(x: darkX + 96, y: y + 156, width: 32, height: 32))
}

write(boardFour.makeImage()!, to: output.appendingPathComponent("glassine-icon-concepts-v4-onionskin-board.png"))

// MARK: - Round five: Palette Rules, tuned

// Two notes on round four's first variant. The light pair put a white sheet on
// a warm-white tile, so the fan had nothing to sit against; the light row here
// tries three mid-tone tiles at a deepened sheet shadow, with the top leaf's
// tint raised so its page still reads white over a darker backdrop. The dark
// pair had a soft light lying across it — the top-edge sheen plus the type on
// the leaves below coming up through the blurred backdrop — which the dark row
// offers at three levels, plus the neon rims of round four's Coloured Edges on
// their own and crossed with this variant's coloured type.

struct LightTile {
    let name: String
    let slug: String
    let top: CGColor
    let bottom: CGColor
    let hex: String
}

let onionLightTiles: [LightTile] = [
    LightTile(name: "Slate blue", slug: "slate-blue",
              top: rgb(155, 168, 184), bottom: rgb(110, 126, 146),
              hex: "#9BA8B8 → #6E7E92"),
    LightTile(name: "Warm mid gray", slug: "warm-gray",
              top: rgb(216, 211, 203), bottom: rgb(185, 180, 172),
              hex: "#D8D3CB → #B9B4AC"),
    LightTile(name: "Cool mid gray", slug: "cool-gray",
              top: rgb(205, 210, 218), bottom: rgb(169, 176, 187),
              hex: "#CDD2DA → #A9B0BB")
]

struct DarkVariant {
    let name: String
    let slug: String
    let note: String
    let sheen: CGFloat
    let concept: RoundFourConcept
    let neonEdges: Bool
}

let onionDarkVariants: [DarkVariant] = [
    DarkVariant(name: "Sheen 100%", slug: "sheen-100",
                note: "as round four", sheen: 1,
                concept: .paletteRules, neonEdges: false),
    DarkVariant(name: "Sheen 50%", slug: "sheen-50",
                note: "half the glow, rim kept", sheen: 0.5,
                concept: .paletteRules, neonEdges: false),
    DarkVariant(name: "Sheen off", slug: "sheen-off",
                note: "flat card, rim only", sheen: 0,
                concept: .paletteRules, neonEdges: false),
    DarkVariant(name: "Coloured Edges", slug: "coloured-edges",
                note: "round four variant 5", sheen: 1,
                concept: .colouredEdges, neonEdges: false),
    DarkVariant(name: "Neon Rules", slug: "neon-rules",
                note: "coloured type + neon rims, sheen 50%", sheen: 0.5,
                concept: .paletteRules, neonEdges: true)
]

// Over a mid-tone tile the round-four tint left the top leaf grey; the four
// coloured rules need white under them, and the leaves behind stay softer.
let onionPaperAlpha: (top: CGFloat, under: CGFloat) = (0.92, 0.60)

var roundFiveLight: [CGImage] = []
for tile in onionLightTiles {
    let rendered = drawOnionskinColour(.paletteRules, dark: false,
                                       tile: (tile.top, tile.bottom),
                                       paperAlpha: onionPaperAlpha, shadow: 0.46)
    roundFiveLight.append(rendered)
    write(rendered, to: output.appendingPathComponent("glassine-concept-v5-light-\(tile.slug).png"))
}

var roundFiveDark: [CGImage] = []
for variant in onionDarkVariants {
    let rendered = drawOnionskinColour(variant.concept, dark: true,
                                       sheen: variant.sheen,
                                       neonEdges: variant.neonEdges)
    roundFiveDark.append(rendered)
    write(rendered, to: output.appendingPathComponent("glassine-concept-v5-dark-\(variant.slug).png"))
}

let boardFive = context(width: 3320, height: 2220)
boardFive.setFillColor(rgb(236, 239, 243))
boardFive.fill(CGRect(x: 0, y: 0, width: 3320, height: 2220))
label("Glassine — Palette Rules, tuned", at: CGPoint(x: 120, y: 2130),
      size: 58, color: rgb(28, 35, 45), in: boardFive)
label("Round four variant 1 · geometry and line colours unchanged · 64 px and 32 px checks",
      at: CGPoint(x: 122, y: 2068), size: 29, color: rgb(91, 101, 114), in: boardFive)

/// One cell: the 512 render, a 64 and a 32 downsample, a title and a note.
func drawCell(_ image: CGImage, title: String, note: String, at origin: CGPoint,
              titleColor: CGColor, noteColor: CGColor, in board: CGContext) {
    label(title, at: CGPoint(x: origin.x, y: origin.y + 600), size: 38,
          color: titleColor, in: board)
    label(note, at: CGPoint(x: origin.x, y: origin.y + 556), size: 21,
          color: noteColor, in: board)
    board.draw(downsample(image, to: 512), in: CGRect(x: origin.x, y: origin.y,
                                                     width: 512, height: 512))
    label("64", at: CGPoint(x: origin.x + 4, y: origin.y - 70), size: 17,
          color: noteColor, in: board)
    label("32", at: CGPoint(x: origin.x + 100, y: origin.y - 70), size: 17,
          color: noteColor, in: board)
    board.draw(downsample(image, to: 64),
               in: CGRect(x: origin.x, y: origin.y - 160, width: 64, height: 64))
    board.draw(downsample(image, to: 32),
               in: CGRect(x: origin.x + 96, y: origin.y - 144, width: 32, height: 32))
}

let lightRowY: CGFloat = 1280
label("LIGHT — tile contrast (page and shadow tuned to match)",
      at: CGPoint(x: 120, y: lightRowY + 680), size: 32,
      color: rgb(58, 68, 82), in: boardFive)
for (index, tile) in onionLightTiles.enumerated() {
    let x = CGFloat(index) * 640 + 120
    drawCell(roundFiveLight[index], title: "L\(index + 1)  \(tile.name)", note: tile.hex,
             at: CGPoint(x: x, y: lightRowY), titleColor: rgb(32, 40, 51),
             noteColor: rgb(105, 114, 126), in: boardFive)
}

let darkRowY: CGFloat = 320
// The dark cells sit on their own dark panel: at 64 and 32 px a dark icon on a
// light board reads as a blob, which says nothing about the artwork.
fill(CGPath(roundedRect: CGRect(x: 80, y: darkRowY - 190, width: 3160, height: 890),
            cornerWidth: 30, cornerHeight: 30, transform: nil),
     rgb(26, 30, 36), in: boardFive)
label("DARK — soft light across the page, and the neon-rim crossings",
      at: CGPoint(x: 120, y: darkRowY + 735), size: 32,
      color: rgb(58, 68, 82), in: boardFive)
for (index, variant) in onionDarkVariants.enumerated() {
    let x = CGFloat(index) * 640 + 120
    drawCell(roundFiveDark[index], title: "D\(index + 1)  \(variant.name)", note: variant.note,
             at: CGPoint(x: x, y: darkRowY), titleColor: rgb(226, 232, 240),
             noteColor: rgb(150, 160, 174), in: boardFive)
}

write(boardFive.makeImage()!, to: output.appendingPathComponent("glassine-icon-concepts-v5-palette-tuning-board.png"))

// MARK: - Round six: coloured edges, and coloured pages

// D5 carried the dark side, so the light side is asked the same question: with
// the fan's own rims doing the separating, how pale can the tile go before the
// sheets stop reading? Row one is that ladder. Row two asks the other way round
// — colour in the paper rather than at its edge — on the two palest tiles.

let roundSixTiles: [LightTile] = [
    LightTile(name: "Slate blue", slug: "slate-blue",
              top: rgb(155, 168, 184), bottom: rgb(110, 126, 146),
              hex: "#9BA8B8 → #6E7E92"),
    LightTile(name: "Light blue-gray", slug: "light-blue-gray",
              top: rgb(195, 205, 217), bottom: rgb(154, 167, 183),
              hex: "#C3CDD9 → #9AA7B7"),
    LightTile(name: "Warm white", slug: "warm-white",
              top: rgb(247, 245, 240), bottom: rgb(197, 202, 212),
              hex: "#F7F5F0 → #C5CAD4"),
    LightTile(name: "Near white", slug: "near-white",
              top: rgb(251, 251, 250), bottom: rgb(227, 230, 234),
              hex: "#FBFBFA → #E3E6EA")
]

var roundSixEdges: [CGImage] = []
for tile in roundSixTiles {
    let rendered = drawOnionskinColour(.paletteRules, dark: false,
                                       tile: (tile.top, tile.bottom),
                                       paperAlpha: onionPaperAlpha, shadow: 0.46,
                                       neonEdges: true)
    roundSixEdges.append(rendered)
    write(rendered, to: output.appendingPathComponent("glassine-concept-v6-edges-\(tile.slug).png"))
}

enum PageTreatment: String, CaseIterable {
    case colouredLeaves = "Coloured leaves"
    case tintedGlassine = "Tinted glassine"
    case gradientSheet = "Gradient sheet"
}

let pageTreatmentSlugs: [PageTreatment: String] = [
    .colouredLeaves: "coloured-leaves",
    .tintedGlassine: "tinted-glassine",
    .gradientSheet: "gradient-sheet"
]

/// The fan with the colour in the paper rather than in the rules. Geometry,
/// shadows and the glassine compositing are `drawOnionskinColour`'s; only what
/// each leaf is made of changes. Coral leads at the front in every case, so the
/// three read as the same object in three materials.
func drawOnionPages(_ treatment: PageTreatment, dark: Bool,
                    tile: (top: CGColor, bottom: CGColor)? = nil) -> CGImage {
    let palette = restyled(onionPalette(dark: dark), tileTop: tile?.top,
                           tileBottom: tile?.bottom)
    let ctx = context(width: 1024, height: 1024)
    glassTile(in: ctx, palette: palette)

    // Slate on the light leaves, near-white on the dark ones: on saturated paper
    // the four rules would have to compete with the sheet they sit on.
    let ink = dark ? rgb(240, 244, 250) : rgb(30, 36, 46)
    for (index, sheet) in onionSheets().enumerated() {
        let hue = tabPalette[3 - index]
        let top = index == 3
        let tint: CGColor
        switch treatment {
        case .colouredLeaves:
            tint = dark ? mix(rgb(14, 18, 24), hue, 0.60, alpha: 1) : hue
        case .tintedGlassine:
            tint = dark ? mix(rgb(20, 25, 32), hue, 0.34, alpha: top ? 0.66 : 0.50)
                        : hue.copy(alpha: top ? 0.48 : 0.36)!
        case .gradientSheet:
            tint = dark ? rgb(22, 27, 34, top ? 0.58 : 0.34)
                        : rgb(255, 255, 255, top ? 0.92 : 0.60)
        }
        layGlassine(sheet.path, backdrop: veiled(ctx), palette: palette, in: ctx,
                    shadow: dark ? 0.26 : 0.46, tint: tint)

        if treatment == .tintedGlassine {
            ctx.addPath(sheet.path)
            ctx.setStrokeColor(hue.copy(alpha: dark ? 0.95 : 0.85)!)
            ctx.setLineWidth(6)
            ctx.strokePath()
        }
        if treatment == .gradientSheet && top {
            let box = sheet.path.boundingBox
            ctx.saveGState()
            ctx.addPath(sheet.path)
            ctx.clip()
            let wash = CGGradient(
                colorsSpace: colorSpace,
                colors: tabPalette.map { $0.copy(alpha: dark ? 0.40 : 0.52)! } as CFArray,
                locations: [0, 0.34, 0.67, 1])!
            ctx.drawLinearGradient(wash, start: CGPoint(x: 0, y: box.maxY),
                                   end: CGPoint(x: 0, y: box.minY), options: [])
            ctx.restoreGState()
        }
        drawSheetLines(sheet, colors: [ink], in: ctx)
    }
    return ctx.makeImage()!
}

// Row two runs on the two palest tiles: near white first, then the light
// blue-gray, so the same treatment can be read with and without a tile behind it.
let pageTiles = [roundSixTiles[3], roundSixTiles[1]]

var roundSixPages: [(treatment: PageTreatment, tile: LightTile, image: CGImage)] = []
for treatment in PageTreatment.allCases {
    for tile in pageTiles {
        let rendered = drawOnionPages(treatment, dark: false, tile: (tile.top, tile.bottom))
        roundSixPages.append((treatment, tile, rendered))
        write(rendered, to: output.appendingPathComponent(
            "glassine-concept-v6-pages-\(pageTreatmentSlugs[treatment]!)-\(tile.slug).png"))
    }
}

var roundSixPagesDark: [PageTreatment: CGImage] = [:]
for treatment in PageTreatment.allCases {
    let rendered = drawOnionPages(treatment, dark: true)
    roundSixPagesDark[treatment] = rendered
    write(rendered, to: output.appendingPathComponent(
        "glassine-concept-v6-pages-\(pageTreatmentSlugs[treatment]!)-dark.png"))
}

// The one of the three that survives the graphite tile, shown beside D5. The
// tinted sheets go muddy where they overlap and the solid leaves lose the
// palette to a single hue; the wash keeps all four colours on one sheet.
let darkPageTreatment = PageTreatment.gradientSheet

let boardSix = context(width: 4600, height: 2400)
boardSix.setFillColor(rgb(236, 239, 243))
boardSix.fill(CGRect(x: 0, y: 0, width: 4600, height: 2400))
label("Glassine — coloured edges, coloured pages", at: CGPoint(x: 120, y: 2300),
      size: 58, color: rgb(28, 35, 45), in: boardSix)
label("Palette Rules geometry · D5 \"Neon Rules\" carried through as the dark half of every pair",
      at: CGPoint(x: 122, y: 2238), size: 29, color: rgb(91, 101, 114), in: boardSix)

/// A dark cell needs its own dark ground, or the 64 and 32 px checks read as a
/// blob against the board and say nothing about the artwork.
func darkPanel(at x: CGFloat, rowY: CGFloat, in board: CGContext) {
    fill(CGPath(roundedRect: CGRect(x: x - 44, y: rowY - 190, width: 600, height: 890),
                cornerWidth: 30, cornerHeight: 30, transform: nil),
         rgb(26, 30, 36), in: board)
}

let edgeRowY: CGFloat = 1440
label("LIGHT EDGES — coloured rims on the fan, tile going lighter left to right",
      at: CGPoint(x: 120, y: edgeRowY + 680), size: 32,
      color: rgb(58, 68, 82), in: boardSix)
for (index, tile) in roundSixTiles.enumerated() {
    let x = CGFloat(index) * 640 + 120
    drawCell(roundSixEdges[index], title: "L\(index + 1)  \(tile.name)", note: tile.hex,
             at: CGPoint(x: x, y: edgeRowY), titleColor: rgb(32, 40, 51),
             noteColor: rgb(105, 114, 126), in: boardSix)
}
let edgeDarkX = CGFloat(4) * 640 + 120
darkPanel(at: edgeDarkX, rowY: edgeRowY, in: boardSix)
drawCell(roundFiveDark[4], title: "D5  Neon Rules", note: "chosen dark · for reference",
         at: CGPoint(x: edgeDarkX, y: edgeRowY), titleColor: rgb(226, 232, 240),
         noteColor: rgb(150, 160, 174), in: boardSix)

let pageRowY: CGFloat = 320
label("COLOURED PAGES — colour in the paper instead of at its edge",
      at: CGPoint(x: 120, y: pageRowY + 735), size: 32,
      color: rgb(58, 68, 82), in: boardSix)
for (index, entry) in roundSixPages.enumerated() {
    let x = CGFloat(index) * 640 + 120
    let name = "P\(index / 2 + 1)\(index % 2 == 0 ? "a" : "b")"
    drawCell(entry.image, title: "\(name)  \(entry.treatment.rawValue)",
             note: "\(entry.tile.name) tile", at: CGPoint(x: x, y: pageRowY),
             titleColor: rgb(32, 40, 51), noteColor: rgb(105, 114, 126), in: boardSix)
}
let pageDarkX = CGFloat(6) * 640 + 120
darkPanel(at: pageDarkX, rowY: pageRowY, in: boardSix)
drawCell(roundSixPagesDark[darkPageTreatment]!,
         title: "P3 dark  \(darkPageTreatment.rawValue)", note: "graphite tile · beside D5",
         at: CGPoint(x: pageDarkX, y: pageRowY), titleColor: rgb(226, 232, 240),
         noteColor: rgb(150, 160, 174), in: boardSix)

write(boardSix.makeImage()!, to: output.appendingPathComponent("glassine-icon-concepts-v6-light-edges-board.png"))
print("wrote concepts to \(output.path)")
