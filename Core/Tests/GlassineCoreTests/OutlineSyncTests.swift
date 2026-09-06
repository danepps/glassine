import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import GlassineCore

@Suite("OutlineSync")
struct OutlineSyncTests {

    /// A three-page document with a two-level outline:
    ///   One       page 0, top
    ///     One.a   page 0, middle
    ///     One.b   page 1, top
    ///   Two       page 2, top
    private func makeOutlinedDocument() -> PDFDocument {
        let document = makeBlankPDF(pageCount: 3)
        func node(_ label: String, page: Int, y: CGFloat) -> PDFOutline {
            let outline = PDFOutline()
            outline.label = label
            outline.destination = PDFDestination(page: document.page(at: page)!,
                                                 at: CGPoint(x: 0, y: y))
            return outline
        }
        let root = PDFOutline()
        let one = node("One", page: 0, y: 780)
        one.insertChild(node("One.a", page: 0, y: 400), at: 0)
        one.insertChild(node("One.b", page: 1, y: 780), at: 1)
        root.insertChild(one, at: 0)
        root.insertChild(node("Two", page: 2, y: 780), at: 1)
        document.outlineRoot = root
        return document
    }

    @Test("Ordinals sort by page, then downwards through the page")
    func ordinalOrdering() {
        let document = makeBlankPDF(pageCount: 2)
        let first = document.page(at: 0)!
        let second = document.page(at: 1)!

        let top = OutlineSync.ordinal(of: first, y: 780, in: document)!
        let middle = OutlineSync.ordinal(of: first, y: 400, in: document)!
        let nextPage = OutlineSync.ordinal(of: second, y: 780, in: document)!

        #expect(top < middle)          // further down the same page sorts later
        #expect(middle < nextPage)     // and the next page later still
        #expect(!(nextPage < top))

        // The y is clamped to the top of the crop box, so PDFView's own
        // destination (which sits a gutter above the page) and a real PDF's
        // huge "unspecified" coordinate both land on the page top.
        let cropTop = first.bounds(for: .cropBox).maxY
        let clamped = OutlineSync.ordinal(of: first, y: 100_000, in: document)!
        #expect(clamped == OutlineSync.ordinal(of: first, y: cropTop, in: document)!)
        #expect(clamped < top)          // the page top is above any heading on it

        // A page that is not in the document has no ordinal.
        #expect(OutlineSync.ordinal(of: PDFPage(), y: 0, in: document) == nil)
    }

    @Test("Flattening is pre-order, with depths")
    func flattening() {
        let document = makeOutlinedDocument()
        let entries = OutlineSync.entries(of: document.outlineRoot, in: document)

        #expect(entries.map { $0.node.label } == ["One", "One.a", "One.b", "Two"])
        #expect(entries.map(\.depth) == [0, 1, 1, 0])
        #expect(entries.allSatisfy { $0.ordinal != nil })
        #expect(OutlineSync.entries(of: nil, in: document).isEmpty)
    }

    @Test("index(atOrBefore:) picks the last entry that has started")
    func indexAtOrBefore() {
        let document = makeOutlinedDocument()
        let entries = OutlineSync.entries(of: document.outlineRoot, in: document)
        let page = { (index: Int) in document.page(at: index)! }

        func index(page pageIndex: Int, y: CGFloat) -> Int {
            OutlineSync.index(
                atOrBefore: OutlineSync.ordinal(of: page(pageIndex), y: y, in: document)!,
                in: entries)
        }

        // Page 1, at the very top: exactly on "One"'s start.
        #expect(index(page: 0, y: 780) == 0)
        // Just below it, still inside "One".
        #expect(index(page: 0, y: 779) == 0)
        // Exactly on "One.a".
        #expect(index(page: 0, y: 400) == 1)
        #expect(index(page: 0, y: 399) == 1)
        // Page 2 top: "One.b".
        #expect(index(page: 1, y: 780) == 2)
        #expect(index(page: 1, y: 10) == 2)
        // Page 3: "Two", the last entry.
        #expect(index(page: 2, y: 780) == 3)
        #expect(index(page: 2, y: 1) == 3)
    }

    @Test("Nothing is selected above the first entry, or with no entries")
    func nothingSelected() {
        let document = makeBlankPDF(pageCount: 2)
        func node(_ label: String, page: Int, y: CGFloat) -> PDFOutline {
            let outline = PDFOutline()
            outline.label = label
            outline.destination = PDFDestination(page: document.page(at: page)!,
                                                 at: CGPoint(x: 0, y: y))
            return outline
        }
        let root = PDFOutline()
        // The first chapter starts part-way down page 1, so the top of the
        // document is before every entry.
        root.insertChild(node("Later", page: 0, y: 300), at: 0)
        document.outlineRoot = root

        let entries = OutlineSync.entries(of: document.outlineRoot, in: document)
        let atTop = OutlineSync.ordinal(of: document.page(at: 0)!, y: 780, in: document)!
        #expect(OutlineSync.index(atOrBefore: atTop, in: entries) == -1)

        #expect(OutlineSync.index(atOrBefore: atTop, in: []) == -1)
    }

    @Test("An entry with no destination is skipped rather than claimed")
    func entriesWithoutDestinations() {
        let document = makeBlankPDF(pageCount: 2)
        let root = PDFOutline()
        let bare = PDFOutline()
        bare.label = "No destination"
        root.insertChild(bare, at: 0)
        let real = PDFOutline()
        real.label = "Real"
        real.destination = PDFDestination(page: document.page(at: 0)!, at: CGPoint(x: 0, y: 780))
        root.insertChild(real, at: 1)
        document.outlineRoot = root

        let entries = OutlineSync.entries(of: root, in: document)
        #expect(entries[0].ordinal == nil)
        #expect(entries[1].ordinal != nil)

        let here = OutlineSync.ordinal(of: document.page(at: 1)!, y: 100, in: document)!
        #expect(OutlineSync.index(atOrBefore: here, in: entries) == 1)
    }

    @Test("A goto action supplies the destination when the node has none")
    func gotoActionDestination() {
        let document = makeBlankPDF(pageCount: 2)
        let node = PDFOutline()
        node.label = "Via action"
        let target = PDFDestination(page: document.page(at: 1)!, at: CGPoint(x: 0, y: 500))
        node.action = PDFActionGoTo(destination: target)
        #expect(OutlineSync.destination(of: node)?.page === document.page(at: 1))
    }
}
