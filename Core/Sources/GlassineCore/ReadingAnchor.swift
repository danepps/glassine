import CoreGraphics
import PDFKit

/// Where the reader is, said in terms the *text* understands rather than the
/// pagination: "300 pt below the fourth outline entry, the one called
/// 'III. The Rule'".
///
/// A `Prefs.Position` is a page index and a point, which is exactly right for
/// reopening a file that has not changed and exactly wrong across a re-render.
/// Re-typesetting a Markdown document at a new size or style moves every page
/// break; switching Pages → Continuous collapses the whole document onto page 0,
/// where a page-12 destination clamps to page 0 and its y describes a different
/// paragraph entirely. A heading survives all of that.
///
/// Two things are kept beside the title. The **index**, because titles repeat: a
/// memo with three "Notes" headings needs the nearest one, not the first. And
/// the **offset** below the heading, because a heading alone is too coarse: the
/// commonest reload of all is an append to a file being read, where the text
/// above the reader has not moved by a point, and snapping back to the top of
/// the current section on every save would be a worse answer than the page
/// carry-over it replaces. With the offset, an unchanged reload lands exactly
/// where the reader was, and only the text that actually moved moves them.
public struct ReadingAnchor: Sendable, Equatable {
    /// Row in `OutlineSync.entries(of:in:)`, pre-order.
    public let index: Int
    /// The entry's label, as it read in the outline it was captured from.
    public let title: String
    /// How far below that heading the reader had got, in points down the
    /// document (`OutlineSync.depth`). Never negative.
    public let offset: CGFloat

    public init(index: Int, title: String, offset: CGFloat = 0) {
        self.index = index
        self.title = title
        self.offset = max(offset, 0)
    }

    /// The entry the reader is under and how far into it, or nil when the
    /// document has no outline or the reader is above its first entry -- in
    /// which case the caller keeps whatever it was doing before.
    public static func anchor(at here: OutlineSync.Ordinal,
                              in entries: [OutlineEntry],
                              of document: PDFDocument) -> ReadingAnchor? {
        let index = OutlineSync.index(atOrBefore: here, in: entries)
        guard index >= 0, index < entries.count else { return nil }
        var offset: CGFloat = 0
        if let start = entries[index].ordinal,
           let base = OutlineSync.depth(of: start, in: document),
           let reader = OutlineSync.depth(of: here, in: document) {
            offset = reader - base
        }
        return ReadingAnchor(index: index,
                             title: entries[index].node.label ?? "",
                             offset: offset)
    }

    /// Capture from a live view: the outline of the document it is showing, and
    /// where in it the reader has got to.
    @MainActor
    public static func capture(from pdfView: PDFView) -> ReadingAnchor? {
        guard let document = pdfView.document else { return nil }
        let entries = OutlineSync.entries(of: document.outlineRoot, in: document)
        guard !entries.isEmpty, let here = OutlineSync.currentOrdinal(of: pdfView) else {
            return nil
        }
        return anchor(at: here, in: entries, of: document)
    }

    /// Find this anchor's heading again in a freshly rendered outline: the entry
    /// at the same row when its label still matches (the common case -- a
    /// re-render of unchanged text renumbers nothing), else the entry carrying
    /// the same label that sits nearest the old row (text was inserted or
    /// removed above it), else nothing at all.
    public func resolvedIndex(in entries: [OutlineEntry]) -> Int? {
        if index >= 0, index < entries.count, entries[index].node.label == title {
            return index
        }
        var best: Int?
        var bestDistance = Int.max
        for (row, entry) in entries.enumerated() where entry.node.label == title {
            let distance = abs(row - index)
            if distance < bestDistance {
                bestDistance = distance
                best = row
            }
        }
        return best
    }

    public func resolve(in entries: [OutlineEntry]) -> OutlineEntry? {
        resolvedIndex(in: entries).map { entries[$0] }
    }

    /// Where this anchor lands in `document`, as a saved position -- which is
    /// what the install path aims at, so the restore gates and
    /// `lastInstallTarget` stay exactly as they are for every other install.
    ///
    /// How far above the *next* heading a clamped landing stops. A section that
    /// got shorter in the re-render must not carry the reader past its end -- but
    /// stopping one point short of the next heading is a knife edge: PDFKit's
    /// `go(to:)` lands within a point or two, and a page break in between makes
    /// it coarser still, so the reader arrived under the next heading anyway
    /// (measured on iOS: Manuscript to Ink moved the Contents selection from
    /// "6. The Edit menu..." to "7. Reading-position identity..."). A line's
    /// worth of clearance is invisible where the clamp does not bind, and is the
    /// difference between the right heading and the next one where it does.
    private static let clearance: CGFloat = 24

    /// The offset is re-applied below the heading's new home and clamped to the
    /// heading that follows it: a section that got shorter in the re-render must
    /// not carry the reader past its end.
    public func position(in document: PDFDocument) -> Prefs.Position? {
        let entries = OutlineSync.entries(of: document.outlineRoot, in: document)
        guard let row = resolvedIndex(in: entries),
              let start = entries[row].ordinal,
              let base = OutlineSync.depth(of: start, in: document)
        else { return nil }

        var target = base + offset
        if row + 1 <= entries.count - 1,
           let next = entries[(row + 1)...].lazy.compactMap({ $0.ordinal }).first,
           let ceiling = OutlineSync.depth(of: next, in: document) {
            target = min(target, max(ceiling - Self.clearance, base))
        }

        guard let landing = OutlineSync.ordinal(atDepth: target, in: document),
              document.page(at: landing.page) != nil else { return nil }
        // An ordinal's offset is the negated y it was built from.
        return Prefs.Position(pageIndex: landing.page, x: 0, y: -landing.offset)
    }
}
