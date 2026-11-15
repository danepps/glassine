import CoreGraphics
import Foundation

/// Where a page's text is, computed from the text and per-character boxes
/// rather than from PDFKit's point hit-testing.
///
/// Why it exists: on a scanned page with an invisible OCR layer, the kind JSTOR
/// serves, PDFKit puts the page image into the page's text as one U+FFFC
/// (object replacement) character whose bounds cover the whole page, and every
/// point-based lookup -- `characterIndex(at:)`, word and line selection, a
/// mouse drag -- lands on that character instead of the words beneath it. The
/// text and its boxes are still right, so this answers the same questions from
/// them: which caret is nearest a point, and what a drag, double-click or
/// triple-click between two points should select.
///
/// Pure geometry, no PDFKit: indices are UTF-16 offsets into `text` (as
/// PDFKit's are), and the boxes come from a closure so a test can supply them.
/// Coordinates are page space, origin bottom-left, y up.
public struct PageTextMap: Sendable {

    public enum Granularity: Sendable {
        case character, word, line
    }

    /// A U+FFFC in the text: an image or other object PDFKit put in line.
    public struct Graphic: Sendable, Equatable {
        public let index: Int
        public let rect: CGRect
        /// Real text lies on top of it: the image is a scan under an OCR layer.
        public let isTextBearing: Bool
    }

    /// A run of text between line breaks (or graphics), with the union of its
    /// characters' boxes.
    struct Line: Sendable {
        let range: NSRange
        let rect: CGRect
        /// The characters that have a box: (index, minX, maxX), in text order.
        let glyphs: [Glyph]
    }

    struct Glyph: Sendable {
        let index: Int
        let minX: CGFloat
        let maxX: CGFloat
        var midX: CGFloat { (minX + maxX) / 2 }
    }

    /// How many real characters must sit on a graphic before it counts as a
    /// scan under text rather than a figure beside it.
    static let textBearingThreshold = 3

    /// How much more a vertical miss counts than a horizontal one when finding
    /// the line nearest a point. A point in the leading between two lines of
    /// one column should go to one of them, not to the line level with it in
    /// the next column over.
    static let verticalWeight: CGFloat = 3

    public let text: String
    public let graphics: [Graphic]
    let lines: [Line]

    public init(text: String, bounds: (Int) -> CGRect) {
        self.text = text
        let s = text as NSString

        var lines: [Line] = []
        var graphicSlots: [(index: Int, rect: CGRect)] = []
        var textCenters: [CGPoint] = []
        var start = 0
        var glyphs: [Glyph] = []
        var rect = CGRect.null

        func closeLine(at end: Int) {
            if !glyphs.isEmpty {
                lines.append(Line(range: NSRange(location: start, length: end - start),
                                  rect: rect, glyphs: glyphs))
            }
            glyphs = []
            rect = .null
            start = end + 1
        }

        for index in 0..<s.length {
            let unit = s.character(at: index)
            if unit == Self.objectReplacement {
                closeLine(at: index)
                graphicSlots.append((index, Self.usable(bounds(index))))
                continue
            }
            if Self.isLineBreak(unit) {
                // A break's own box is not trusted: PDFKit has been seen to
                // hand back the whole-page graphic's rectangle for one.
                closeLine(at: index)
                continue
            }
            let box = Self.usable(bounds(index))
            // In the range, but no use for geometry.
            guard box.width > 0 else { continue }
            glyphs.append(Glyph(index: index, minX: box.minX, maxX: box.maxX))
            rect = rect.union(box)
            if !Self.isSpace(unit) { textCenters.append(CGPoint(x: box.midX, y: box.midY)) }
        }
        closeLine(at: s.length)

        self.lines = lines
        self.graphics = graphicSlots.map { slot in
            let covered = slot.rect.isEmpty ? 0
                : textCenters.lazy.filter { slot.rect.contains($0) }.prefix(Self.textBearingThreshold).count
            return Graphic(index: slot.index, rect: slot.rect,
                           isTextBearing: covered >= Self.textBearingThreshold)
        }
    }

    // MARK: - Questions about graphics

    /// The graphic at `index` has text on top of it.
    public func isTextBearingGraphic(at index: Int) -> Bool {
        graphics.contains { $0.index == index && $0.isTextBearing }
    }

    /// The point lies on a scan that carries text.
    public func textBearingGraphicContains(_ point: CGPoint) -> Bool {
        graphics.contains { $0.isTextBearing && $0.rect.contains(point) }
    }

    /// `range` minus any text-bearing graphic characters inside it, as the
    /// runs that are left. Empty runs are dropped.
    public func removingTextBearingGraphics(from range: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var location = range.location
        for graphic in graphics where graphic.isTextBearing && NSLocationInRange(graphic.index, range) {
            if graphic.index > location {
                out.append(NSRange(location: location, length: graphic.index - location))
            }
            location = graphic.index + 1
        }
        if NSMaxRange(range) > location {
            out.append(NSRange(location: location, length: NSMaxRange(range) - location))
        }
        return out
    }

    // MARK: - Points to text

    /// The insertion point nearest `point`: before the nearest character when
    /// the point is left of its middle, after it otherwise. Nil when the page
    /// has no text with geometry.
    public func caret(at point: CGPoint) -> Int? {
        hit(at: point)?.caret
    }

    /// The character under `point`, and only a real hit: horizontally inside
    /// the character's box and vertically inside its line. For link detection,
    /// where "nearest" would turn a click in the margin into a click on a word.
    public func strictCharacterIndex(at point: CGPoint) -> Int? {
        for line in lines where line.rect.minY <= point.y && point.y <= line.rect.maxY {
            if let glyph = line.glyphs.first(where: { $0.minX <= point.x && point.x <= $0.maxX }) {
                return glyph.index
            }
        }
        return nil
    }

    /// What a press at `from` dragged to `to` selects, at the given
    /// granularity. Nil when nothing would be selected (a character drag that
    /// never crossed a character's middle) or the page has no text.
    public func range(from: CGPoint, to: CGPoint, granularity: Granularity) -> NSRange? {
        guard let a = hit(at: from), let b = hit(at: to) else { return nil }
        switch granularity {
        case .character:
            let lo = min(a.caret, b.caret), hi = max(a.caret, b.caret)
            return hi > lo ? NSRange(location: lo, length: hi - lo) : nil
        case .word:
            let first = wordRange(a), last = wordRange(b)
            let lo = min(first.location, last.location)
            let hi = max(NSMaxRange(first), NSMaxRange(last))
            return NSRange(location: lo, length: hi - lo)
        case .line:
            let lo = min(a.line, b.line), hi = max(a.line, b.line)
            return NSRange(location: lines[lo].range.location,
                           length: NSMaxRange(lines[hi].range) - lines[lo].range.location)
        }
    }

    /// From `point` to the end of the page's text: the first page's share of a
    /// drag that continues onto the next page.
    public func rangeToEnd(from point: CGPoint, granularity: Granularity) -> NSRange? {
        guard let a = hit(at: point), let last = lines.last else { return nil }
        let start: Int
        switch granularity {
        case .character: start = a.caret
        case .word: start = wordRange(a).location
        case .line: start = lines[a.line].range.location
        }
        let end = NSMaxRange(last.range)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// From the start of the page's text to `point`: the last page's share of
    /// a drag that began on an earlier page.
    public func rangeFromStart(to point: CGPoint, granularity: Granularity) -> NSRange? {
        guard let b = hit(at: point), let first = lines.first else { return nil }
        let end: Int
        switch granularity {
        case .character: end = b.caret
        case .word: end = NSMaxRange(wordRange(b))
        case .line: end = NSMaxRange(lines[b.line].range)
        }
        let start = first.range.location
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: - Hit testing

    struct Hit {
        let line: Int
        let character: Int
        let caret: Int
    }

    /// The nearest line, then the horizontally nearest character on it.
    ///
    /// Containment is never required: OCR glyph boxes are often a fraction of
    /// the printed line's height, so a click on a visible letter can miss its
    /// box entirely and has to fall to the nearest one.
    func hit(at point: CGPoint) -> Hit? {
        var best: (line: Int, score: CGFloat)?
        for (number, line) in lines.enumerated() {
            let r = line.rect
            let dx = max(r.minX - point.x, 0, point.x - r.maxX)
            let dy = max(r.minY - point.y, 0, point.y - r.maxY)
            let score = dx + Self.verticalWeight * dy
            if best == nil || score < best!.score { best = (number, score) }
        }
        guard let number = best?.line else { return nil }

        var nearest: (glyph: Glyph, distance: CGFloat)?
        for glyph in lines[number].glyphs {
            let distance = max(glyph.minX - point.x, 0, point.x - glyph.maxX)
            if nearest == nil || distance < nearest!.distance { nearest = (glyph, distance) }
        }
        guard let glyph = nearest?.glyph else { return nil }
        let caret = point.x < glyph.midX ? glyph.index : glyph.index + 1
        return Hit(line: number, character: glyph.index, caret: caret)
    }

    /// The word containing the hit character, found the way the text system
    /// finds words; a hit on punctuation or a space selects just that
    /// character (a double-click on "scholars," selects "scholars").
    private func wordRange(_ hit: Hit) -> NSRange {
        let s = text as NSString
        var found = NSRange(location: hit.character, length: 1)
        s.enumerateSubstrings(in: lines[hit.line].range, options: [.byWords, .substringNotRequired]) {
            _, range, _, stop in
            if NSLocationInRange(hit.character, range) {
                found = range
                stop.pointee = true
            } else if range.location > hit.character {
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - Characters

    static let objectReplacement: unichar = 0xFFFC

    /// A string with an object replacement character and nothing else but
    /// whitespace: the text of a selection that holds only an image.
    public static func isGraphicOnly(_ text: String) -> Bool {
        var sawGraphic = false
        for scalar in text.unicodeScalars {
            if scalar.value == 0xFFFC { sawGraphic = true }
            else if !CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
        }
        return sawGraphic
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0xA0
    }

    /// Null, infinite and non-finite rectangles become `.zero`, which the
    /// geometry then ignores.
    private static func usable(_ rect: CGRect) -> CGRect {
        guard !rect.isNull, !rect.isInfinite, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return .zero }
        return rect.standardized
    }
}
