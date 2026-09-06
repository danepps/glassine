import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import GlassineCore

@Suite("ReadingAnchor")
struct ReadingAnchorTests {

    /// A document whose outline is exactly `labels`, one entry per page, each an
    /// inch down its page (so there is room above the first heading, which is
    /// where a reader legitimately has nothing to anchor to). Enough to stand in
    /// for a re-typeset memo: what changes across a re-render is the
    /// *pagination*, and none of that is visible through the anchor.
    private func makeDocument(_ labels: [String]) -> PDFDocument {
        let document = makeBlankPDF(pageCount: max(labels.count, 1))
        let root = PDFOutline()
        for (index, label) in labels.enumerated() {
            let node = PDFOutline()
            node.label = label
            node.destination = PDFDestination(page: document.page(at: index)!,
                                              at: CGPoint(x: 0, y: 700))
            root.insertChild(node, at: index)
        }
        document.outlineRoot = root
        return document
    }

    private func entries(_ document: PDFDocument) -> [OutlineEntry] {
        OutlineSync.entries(of: document.outlineRoot, in: document)
    }

    private func here(_ document: PDFDocument, page: Int, y: CGFloat) -> OutlineSync.Ordinal {
        OutlineSync.ordinal(of: document.page(at: page)!, y: y, in: document)!
    }

    // MARK: Depth arithmetic

    @Test("Depth stacks the pages, and inverts")
    func depthRoundTrips() {
        let document = makeBlankPDF(pageCount: 4)      // 612 x 792 each

        #expect(OutlineSync.depth(of: here(document, page: 0, y: 792), in: document) == 0)
        #expect(OutlineSync.depth(of: here(document, page: 0, y: 392), in: document) == 400)
        #expect(OutlineSync.depth(of: here(document, page: 2, y: 792), in: document) == 1584)
        #expect(OutlineSync.depth(of: here(document, page: 2, y: 592), in: document) == 1784)
        // A destination above the page top clamps there, so it reads as the top.
        #expect(OutlineSync.depth(of: here(document, page: 1, y: 100_000), in: document) == 792)

        for depth in [CGFloat(0), 400, 792, 1784, 3167] {
            let ordinal = OutlineSync.ordinal(atDepth: depth, in: document)!
            #expect(OutlineSync.depth(of: ordinal, in: document) == depth)
        }
        // Past the end clamps to the foot of the last page.
        let beyond = OutlineSync.ordinal(atDepth: 99_999, in: document)!
        #expect(beyond.page == 3)
        #expect(OutlineSync.depth(of: beyond, in: document) == 3168)
    }

    // MARK: Capture

    @Test("The anchor is the entry the reader is under, plus how far into it")
    func capturesTheEntryAndOffset() {
        let document = makeDocument(["One", "Two", "Three"])
        let rows = entries(document)

        // Half way down page 1. "Two" sits 92 pt down that page, so the reader
        // is 308 pt into its section.
        let anchor = ReadingAnchor.anchor(at: here(document, page: 1, y: 392),
                                          in: rows, of: document)
        #expect(anchor == ReadingAnchor(index: 1, title: "Two", offset: 308))

        // Above the first heading there is nothing to anchor to, and the caller
        // keeps whatever it was going to do.
        #expect(ReadingAnchor.anchor(at: here(document, page: 0, y: 100_000),
                                     in: rows, of: document) == nil)
        #expect(ReadingAnchor.anchor(at: here(document, page: 1, y: 392),
                                     in: [], of: document) == nil)
    }

    // MARK: Resolution

    @Test("An unchanged document resolves back to exactly where the reader was")
    func unchangedDocumentIsExact() {
        // The commonest reload of all: text appended below, nothing above the
        // reader moved. The old page-and-point carry-over was exact here, and
        // the anchor has to be too.
        let document = makeDocument(["One", "Two", "Three"])
        let anchor = ReadingAnchor.anchor(at: here(document, page: 2, y: 500),
                                          in: entries(document), of: document)!

        let replacement = makeDocument(["One", "Two", "Three", "Four"])
        let position = anchor.position(in: replacement)
        #expect(position?.pageIndex == 2)
        #expect(position?.y == 500)
    }

    @Test("A heading that moved is found by label, nearest to where it was")
    func resolvesByLabelWhenTheIndexMoved() {
        // A heading inserted above the reading position shifts every later entry
        // down one row -- and one page.
        let document = makeDocument(["One", "Two", "Three", "Four"])
        let anchor = ReadingAnchor.anchor(at: here(document, page: 2, y: 500),
                                          in: entries(document), of: document)!
        #expect(anchor.index == 2)

        let replacement = makeDocument(["One", "New", "Two", "Three", "Four"])
        #expect(anchor.resolve(in: entries(replacement))?.node.label == "Three")
        let position = anchor.position(in: replacement)
        #expect(position?.pageIndex == 3)       // "Three" now starts on page 3
        #expect(position?.y == 500)             // same distance into the section
    }

    @Test("Repeated titles resolve to the nearest one, not the first")
    func repeatedTitlesResolveToTheNearest() {
        let anchor = ReadingAnchor(index: 4, title: "Notes", offset: 100)
        let replacement = makeDocument(["Notes", "A", "B", "C", "D", "Notes", "E"])

        // Row 4 is "D", so the index shortcut misses and the label search runs:
        // rows 0 and 5 both say "Notes", and 5 is nearer.
        #expect(anchor.resolvedIndex(in: entries(replacement)) == 5)
        let position = anchor.position(in: replacement)
        #expect(position?.pageIndex == 5)
        #expect(position?.y == 600)     // 100 pt below the heading at y 700
    }

    @Test("The offset never carries the reader past the next heading")
    func offsetIsClampedToTheSection() {
        // Captured 1,000 pt into a section; in the re-render that section runs
        // to less than a page and the next heading follows sooner.
        let anchor = ReadingAnchor(index: 1, title: "Two", offset: 1_000)
        let replacement = makeDocument(["One", "Two", "Three"])

        let position = anchor.position(in: replacement)!
        let depth = OutlineSync.depth(
            of: OutlineSync.ordinal(of: replacement.page(at: position.pageIndex)!,
                                    y: position.y, in: replacement)!,
            in: replacement)!
        // "Two" starts at 884 and "Three" at 1,676; 884 + 1,000 would land past
        // "Three", so it stops a line's clearance short of it -- not one point,
        // which `go(to:)` and a page break between the two can each swallow.
        #expect(depth == 1_652)
    }

    @Test("A heading that is gone resolves to nothing, and so does an outline-less document")
    func unresolvableAnchorsGiveNothing() {
        let anchor = ReadingAnchor(index: 2, title: "Three", offset: 100)
        let rewritten = makeDocument(["One", "Two", "Four"])
        #expect(anchor.resolve(in: entries(rewritten)) == nil)
        #expect(anchor.position(in: rewritten) == nil)

        // No outline at all -- a plain PDF, or a memo with no headings.
        let bare = makeBlankPDF(pageCount: 3)
        #expect(anchor.resolve(in: entries(bare)) == nil)
        #expect(anchor.position(in: bare) == nil)
    }

    @Test("Pages to Continuous: the whole document is one page and the anchor still lands")
    func resolvesOntoASinglePageDocument() {
        // What a continuous render looks like: one very tall page, every heading
        // on it. The old anchor said "entry 3"; the page index it carried said
        // "page 3", which does not exist here at all -- it would have clamped to
        // page 0 and used a page-3 y, i.e. the wrong paragraph entirely.
        let paginated = makeDocument(["One", "Two", "Three", "Four"])
        let anchor = ReadingAnchor.anchor(at: here(paginated, page: 3, y: 492),
                                          in: entries(paginated), of: paginated)!
        #expect(anchor == ReadingAnchor(index: 3, title: "Four", offset: 208))

        let continuous = makeTextPDF(pages: ["one tall page"],
                                     size: CGSize(width: 612, height: 8000))
        let root = PDFOutline()
        for (index, label) in ["One", "Two", "Three", "Four"].enumerated() {
            let node = PDFOutline()
            node.label = label
            node.destination = PDFDestination(page: continuous.page(at: 0)!,
                                              at: CGPoint(x: 0, y: 8000 - CGFloat(index) * 1500))
            root.insertChild(node, at: index)
        }
        continuous.outlineRoot = root

        let position = anchor.position(in: continuous)
        #expect(position?.pageIndex == 0)
        // "Four" is 4,500 pt down the tall page; 208 pt further in is 4,708.
        #expect(position?.y == CGFloat(3292))
    }
}
