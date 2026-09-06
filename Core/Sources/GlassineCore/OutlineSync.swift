import CoreGraphics
import PDFKit

/// One row of a flattened table of contents.
public struct OutlineEntry {
    public let node: PDFOutline
    /// 0 for a top-level chapter, 1 for its children, and so on.
    public let depth: Int
    /// Where the entry starts, or nil if it has no usable destination.
    public let ordinal: OutlineSync.Ordinal?

    public init(node: PDFOutline, depth: Int, ordinal: OutlineSync.Ordinal?) {
        self.node = node
        self.depth = depth
        self.ordinal = ordinal
    }
}

/// The rules behind "which chapter am I in?": turning a PDF destination into a
/// comparable position, flattening an outline tree in reading order, and picking
/// the entry that starts at or before where the reader is.
///
/// The Mac's sidebar keeps its `NSOutlineView` and asks these three questions;
/// an iOS list over `entries(of:in:)` asks the same ones.
public enum OutlineSync {

    /// A position in a document, ordered the way a reader moves through it:
    /// page first, then *downward* offset (PDF y grows upwards, so the offset is
    /// negated and larger y sorts earlier).
    public struct Ordinal: Comparable, Sendable {
        public let page: Int
        public let offset: CGFloat

        public init(page: Int, offset: CGFloat) {
            self.page = page
            self.offset = offset
        }

        public static func < (lhs: Ordinal, rhs: Ordinal) -> Bool {
            lhs.page == rhs.page ? lhs.offset < rhs.offset : lhs.page < rhs.page
        }

        public static func == (lhs: Ordinal, rhs: Ordinal) -> Bool {
            lhs.page == rhs.page && lhs.offset == rhs.offset
        }
    }

    /// Real PDFs use either form of destination.
    public static func destination(of node: PDFOutline) -> PDFDestination? {
        node.destination ?? (node.action as? PDFActionGoTo)?.destination
    }

    /// Page index and downward offset of a destination, so positions compare as
    /// a plain tuple. The y is clamped to the top of the page: PDFView's own
    /// destination sits a gutter's height above it, and an unspecified
    /// destination in a real PDF is a huge number.
    public static func ordinal(of page: PDFPage, y: CGFloat, in document: PDFDocument?) -> Ordinal? {
        guard let index = document?.index(for: page), index != NSNotFound else { return nil }
        return Ordinal(page: index, offset: -min(y, page.bounds(for: .cropBox).maxY))
    }

    /// Where the reader is now. Falls back to the top of the current page when
    /// the view has no destination to give.
    ///
    /// **`currentDestination` is not the same point on the two platforms.** On
    /// macOS it sits a gutter's height *above* the top of the visible area,
    /// which the clamp in `ordinal(of:y:in:)` tames. On iOS it comes back near
    /// the **bottom** of the visible area (measured in Phase 2: a reader parked
    /// at the top of a Letter page stored y = 4.9 out of 792), so a position read
    /// from it describes a passage the reader has not got to yet -- which showed
    /// up as a re-render carrying the reader a whole page forward, because the
    /// anchor was captured a viewport low and then re-aimed at the top of the
    /// view. `convert(_:to:)` on the view's own origin is the top-left the
    /// restore actually aims at, and is what `DocumentSession` already saves.
    @MainActor
    public static func currentOrdinal(of pdfView: PDFView) -> Ordinal? {
        let document = pdfView.document
        #if canImport(UIKit)
        // `page(for:nearest:)` rather than `currentPage`: PDFKit's current page
        // is whichever one covers most of the view, which at a page break is the
        // one *below* the reader -- and its top is a heading or two ahead of
        // them. The page under the view's own top-left corner is where they are.
        if let page = pdfView.page(for: .zero, nearest: true) {
            let top = pdfView.convert(CGPoint.zero, to: page)
            if let ordinal = ordinal(of: page, y: top.y, in: document) { return ordinal }
        }
        #else
        if let destination = pdfView.currentDestination, let page = destination.page,
           let ordinal = ordinal(of: page, y: destination.point.y, in: document) {
            return ordinal
        }
        #endif
        guard let page = pdfView.currentPage else { return nil }
        return ordinal(of: page, y: page.bounds(for: .mediaBox).maxY, in: document)
    }

    /// The outline flattened pre-order -- the order the rows appear in with
    /// everything expanded, which is also reading order. The root itself is not
    /// an entry.
    public static func entries(of root: PDFOutline?, in document: PDFDocument?) -> [OutlineEntry] {
        guard let root else { return [] }
        var result: [OutlineEntry] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                var ordinal: Ordinal?
                if let target = destination(of: child), let page = target.page {
                    ordinal = self.ordinal(of: page, y: target.point.y, in: document)
                }
                result.append(OutlineEntry(node: child, depth: depth, ordinal: ordinal))
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return result
    }

    /// A position as a single number: how far down the whole document it is, in
    /// points, with every page's crop box stacked in reading order. Exact for a
    /// Markdown render, whose pages are all the same size, and trivially exact
    /// for a continuous one, which has only the one page.
    ///
    /// This is what makes "the reader was 300 pt below that heading" a sentence
    /// two different paginations of the same text can both understand.
    public static func depth(of ordinal: Ordinal, in document: PDFDocument) -> CGFloat? {
        guard ordinal.page >= 0, ordinal.page < document.pageCount,
              let page = document.page(at: ordinal.page) else { return nil }
        var total: CGFloat = 0
        for index in 0..<ordinal.page {
            total += document.page(at: index)?.bounds(for: .cropBox).height ?? 0
        }
        // Ordinal.offset is -y clamped to the page top, so the page top is at
        // -maxY and the depth into the page is maxY + offset.
        return total + page.bounds(for: .cropBox).maxY + ordinal.offset
    }

    /// The inverse: which page, and where on it, `depth` points at. Past the end
    /// of the document it clamps to the foot of the last page.
    public static func ordinal(atDepth depth: CGFloat, in document: PDFDocument) -> Ordinal? {
        guard document.pageCount > 0 else { return nil }
        var remaining = max(depth, 0)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            let last = index == document.pageCount - 1
            if remaining < box.height || last {
                return Ordinal(page: index, offset: min(remaining, box.height) - box.maxY)
            }
            remaining -= box.height
        }
        return nil
    }

    /// The last entry, in pre-order, that starts at or before `here`; -1 when
    /// none does (the reader is above the first chapter). Entries without a
    /// destination are skipped, exactly as the sidebar skips a row it cannot
    /// place.
    public static func index(atOrBefore here: Ordinal, in entries: [OutlineEntry]) -> Int {
        var best = -1
        for (row, entry) in entries.enumerated() {
            guard let start = entry.ordinal else { continue }
            if start <= here { best = row }
        }
        return best
    }
}
