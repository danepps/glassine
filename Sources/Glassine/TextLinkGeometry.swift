import Foundation
import GlassineCore
import PDFKit

/// Where a plain-text address is joined across lines, decided from where the
/// words sit on the page.
///
/// `TextLinks` joins a run that ends a line in `/`, `-` and the like to the
/// first run of the next line, because that is how a word processor wraps an
/// address. The text cannot tell that from a paragraph or list item that
/// simply ends in `/`: "…/than-pack-the-court/" followed by a bullet that
/// begins "Marquette" opened ".../the-court/Marquette". The page can. A
/// wrapping engine moves a word to the next line only when it does not fit,
/// so if the whole next run would have fitted after the previous one with
/// room to spare, the line was ended by hand and the address ends there.
///
/// The rule is deliberately one-sided: it refuses only joins that are
/// certainly a paragraph break, and joins whenever it lacks the evidence to
/// say so (a rotated page, a scan, too few lines to find the margin).
extension PDFPage {

    /// Slack, in points, for kerning and for a margin estimated from ragged
    /// lines.
    static let lineWrapTolerance: CGFloat = 2

    /// The character under `point` (page space), as an offset into `string`,
    /// for finding the address a click landed on; nil off the text.
    ///
    /// Not `characterIndex(at:)`. On macOS 27 that falls one character
    /// further behind for every line above the point -- measured on WebKit's
    /// PDFs and on a plain CoreText page alike: 0 on the first line, -1 on
    /// the second, -20 on the twenty-first -- as if it counted characters
    /// without the line breaks PDFKit puts into `string`. The word it finds
    /// is right; the offset it reports is not. On the first lines of a page
    /// the slip stays inside a long address, which is why it went unseen; a
    /// third of the way down, a click near the start of a line lands on the
    /// line above, often on the line break itself, and the address is lost
    /// (or, where the slip reaches another address, that one would open).
    /// One-character selections put each
    /// character where it is drawn, so the page's text map, built from
    /// them, answers instead. It is cached on a `ReaderPage` (every page the
    /// app opens) and built per call on any other page.
    func linkCharacterIndex(at point: CGPoint) -> Int? {
        let map = (self as? ReaderPage)?.textMap ?? PageTextMap(text: string ?? "") { index in
            self.selection(for: NSRange(location: index, length: 1))?.bounds(for: self) ?? .null
        }
        return map.strictCharacterIndex(at: point)
    }

    /// The address under the character at `index` (an offset into `string`,
    /// as the click handler found it), joined across lines only where the
    /// layout says the line wrapped.
    func textLinkURL(at index: Int) -> URL? {
        guard let text = string else { return nil }
        // The page's lines are measured once per lookup, and only when a
        // candidate join actually needs them.
        var lines: [CGRect]?
        return TextLinks.url(in: text, at: index) { previous, next in
            if lines == nil { lines = self.lineBoxes() }
            return self.lineWrapped(between: previous, and: next, lines: lines ?? [])
        }
    }

    /// Whether the run `next` (the first word of a line) could have been
    /// carried there by line wrapping from the line that `previous` ends.
    /// `lines` are the page's line boxes; pass nil to measure them here.
    func lineWrapped(between previous: NSRange, and next: NSRange, lines: [CGRect]? = nil) -> Bool {
        // Page space is not reading space on a rotated page; no opinion.
        guard rotation == 0 else { return true }
        // A scan's text is an invisible OCR layer over a picture of the page;
        // its line boxes say little about where the printed lines broke.
        if string?.contains("\u{FFFC}") == true { return true }
        guard let before = selection(for: previous)?.bounds(for: self),
              let after = selection(for: next)?.bounds(for: self),
              !before.isEmpty, !after.isEmpty else { return true }
        guard let margin = rightMargin(besides: before, lines: lines ?? lineBoxes()) else { return true }
        return before.maxX + after.width > margin - Self.lineWrapTolerance
    }

    /// Every line of text on the page, as PDFKit groups them.
    func lineBoxes() -> [CGRect] {
        guard let all = selection(for: bounds(for: .mediaBox)) else { return [] }
        return all.selectionsByLine().map { $0.bounds(for: self) }.filter { !$0.isEmpty }
    }

    /// The right edge lines normally reach in the column that holds `box`:
    /// the upper quartile of the right edges of the lines that overlap its
    /// line horizontally. Overlap keeps a two-column page to its own column;
    /// the quartile rather than the maximum keeps a title spanning both
    /// columns, or one overlong line, from moving the margin. Nil with fewer
    /// than three such lines.
    func rightMargin(besides box: CGRect, lines: [CGRect]) -> CGFloat? {
        // The whole line the box sits on, if PDFKit reported one.
        let line = lines.first { $0.minY <= box.midY && box.midY <= $0.maxY && $0.intersects(box) } ?? box
        let rights = lines
            .filter { $0.minX < line.maxX && line.minX < $0.maxX }
            .map(\.maxX)
            .sorted()
        guard rights.count >= 3 else { return nil }
        return rights[(rights.count - 1) * 3 / 4]
    }
}
