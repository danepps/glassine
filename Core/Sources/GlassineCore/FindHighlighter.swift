import CoreGraphics
import PDFKit

/// The dark-mode find highlights: it flattens the match selections into
/// per-line rectangles keyed by page, pushes them into the `ReaderPage` objects
/// (PDFKit draws pages through them) and invalidates the tiles that changed.
///
/// Owned by the platform's PDFView subclass, which forwards `setFindMatches`,
/// `setCurrentMatchIndex` and its inversion state to it. The only thing that
/// differs between AppKit and UIKit is how a view is marked for redisplay.
@MainActor
public final class FindHighlighter {

    /// When true, find matches are drawn by `ReaderPage` as reverse video
    /// instead of PDFKit's translucent yellow, because a yellow wash reads
    /// poorly through the dark-mode inversion filter.
    public var isInverted = false {
        didSet { if isInverted != oldValue { refresh(allMatchPages) } }
    }

    public private(set) var findMatches: [PDFSelection] = []
    public private(set) var currentMatchIndex = 0

    private struct LineRect {
        let rect: CGRect
        let match: Int
    }

    private weak var pdfView: PDFView?
    private var lineRects: [ObjectIdentifier: [LineRect]] = [:]
    private var pagesByMatch: [Int: [PDFPage]] = [:]
    private var allMatchPages: [PDFPage] = []

    public init(pdfView: PDFView) {
        self.pdfView = pdfView
    }

    public func setFindMatches(_ selections: [PDFSelection], current: Int) {
        let previous = allMatchPages
        findMatches = selections
        currentMatchIndex = current
        rebuildLineRects()
        refresh(previous + allMatchPages)
    }

    public func setCurrentMatchIndex(_ index: Int) {
        guard index != currentMatchIndex else { return }
        let affected = (pagesByMatch[currentMatchIndex] ?? []) + (pagesByMatch[index] ?? [])
        currentMatchIndex = index
        refresh(affected)
    }

    /// Flatten every match into per-line rectangles keyed by page, so drawing a
    /// page is a dictionary lookup rather than a scan of the whole match list.
    private func rebuildLineRects() {
        lineRects = [:]
        pagesByMatch = [:]
        allMatchPages = []
        var seen = Set<ObjectIdentifier>()

        for (index, selection) in findMatches.enumerated() {
            var pages: [PDFPage] = []
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let rect = line.bounds(for: page).insetBy(dx: 0, dy: -1)
                    lineRects[ObjectIdentifier(page), default: []]
                        .append(LineRect(rect: rect, match: index))
                    if !pages.contains(where: { $0 === page }) { pages.append(page) }
                }
            }
            pagesByMatch[index] = pages
            for page in pages where seen.insert(ObjectIdentifier(page)).inserted {
                allMatchPages.append(page)
            }
        }
    }

    /// Push the current rects into the page objects (PDFKit draws through
    /// them) and invalidate the cached tiles for every page that changed.
    private func refresh(_ pages: [PDFPage]) {
        guard let pdfView else { return }
        var seen = Set<ObjectIdentifier>()
        for page in pages where seen.insert(ObjectIdentifier(page)).inserted {
            if let readerPage = page as? ReaderPage {
                let rects = isInverted ? (lineRects[ObjectIdentifier(page)] ?? []) : []
                readerPage.findHighlights = rects.map {
                    ReaderPage.Highlight(rect: $0.rect,
                                         isCurrent: $0.match == currentMatchIndex)
                }
            }
            pdfView.annotationsChanged(on: page)
        }
        // annotationsChanged alone does not always drop an already-rendered
        // tile, so nudge the layout as well: without this, matches that arrive
        // after a page is on screen stay unhighlighted until it is scrolled
        // out and back.
        if !pages.isEmpty {
            pdfView.layoutDocumentView()
            #if canImport(UIKit)
            pdfView.setNeedsDisplay()
            #else
            pdfView.needsDisplay = true
            #endif
        }
    }
}
