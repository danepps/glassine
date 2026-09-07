import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import GlassineCore

@Suite("MarkdownDocumentModel.applyOutline")
struct ApplyOutlineTests {

    private let headings = [
        MarkdownHeading(level: 1, title: "One", index: 0),
        MarkdownHeading(level: 2, title: "One.a", index: 1),
        MarkdownHeading(level: 3, title: "One.a.i", index: 2),
        MarkdownHeading(level: 1, title: "Two", index: 3)
    ]

    /// Where each heading landed, as the anchors would report it.
    private let rects: [Int: (page: Int, rect: CGRect)] = [
        0: (0, CGRect(x: 72, y: 700, width: 200, height: 14)),
        1: (0, CGRect(x: 72, y: 500, width: 200, height: 14)),
        2: (1, CGRect(x: 72, y: 700, width: 200, height: 14)),
        3: (2, CGRect(x: 72, y: 700, width: 200, height: 14))
    ]

    private func makeAnnotatedDocument() -> PDFDocument {
        let document = makeBlankPDF(pageCount: 3)
        for (index, placement) in rects.sorted(by: { $0.key < $1.key }) {
            let annotation = PDFAnnotation(bounds: placement.rect, forType: .link,
                                           withProperties: nil)
            annotation.url = URL(string: "glassine-outline://\(index)")
            document.page(at: placement.page)?.addAnnotation(annotation)
        }
        return document
    }

    private var locatedMap: [Int: (page: Int, top: CGFloat)] {
        rects.mapValues { (page: $0.page, top: $0.rect.maxY) }
    }

    /// (label, depth, page index, y) for every node, in pre-order.
    private func flatten(_ document: PDFDocument) -> [String] {
        var out: [String] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let page = child.destination?.page.flatMap { document.index(for: $0) } ?? -1
                let y = child.destination.map { Int($0.point.y.rounded()) } ?? -1
                out.append("\(String(repeating: "-", count: depth))\(child.label ?? "") @\(page):\(y)")
                walk(child, depth: depth + 1)
            }
        }
        guard let root = document.outlineRoot else { return [] }
        walk(root, depth: 0)
        return out
    }

    @Test("The annotation path and the located path build the same outline")
    func bothPathsAgree() {
        let viaAnnotations = makeAnnotatedDocument()
        MarkdownDocumentModel.applyOutline(headings, to: viaAnnotations)

        let viaMap = makeAnnotatedDocument()
        MarkdownDocumentModel.applyOutline(headings, to: viaMap, located: locatedMap)

        let expected = ["One @0:718", "-One.a @0:518", "--One.a.i @1:718", "Two @2:718"]
        #expect(flatten(viaAnnotations) == expected)
        #expect(flatten(viaMap) == expected)
    }

    @Test("The annotation path removes the private-scheme links; the located path does not")
    func annotationCleanup() {
        let viaAnnotations = makeAnnotatedDocument()
        MarkdownDocumentModel.applyOutline(headings, to: viaAnnotations)
        #expect(outlineLinkCount(viaAnnotations) == 0)

        let viaMap = makeAnnotatedDocument()
        #expect(outlineLinkCount(viaMap) == 4)
        MarkdownDocumentModel.applyOutline(headings, to: viaMap, located: locatedMap)
        #expect(outlineLinkCount(viaMap) == 4)
    }

    private func outlineLinkCount(_ document: PDFDocument) -> Int {
        var count = 0
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? []
            where annotation.url?.scheme == "glassine-outline" {
                count += 1
            }
        }
        return count
    }

    @Test("A heading that wraps onto two lines yields one entry, at the topmost")
    func wrappedHeadingTakesTheTopmostAnnotation() {
        let document = makeBlankPDF(pageCount: 1)
        for y in [640, 660] {     // added bottom line first, then the top one
            let annotation = PDFAnnotation(bounds: CGRect(x: 72, y: CGFloat(y), width: 200, height: 14),
                                           forType: .link, withProperties: nil)
            annotation.url = URL(string: "glassine-outline://0")
            document.page(at: 0)?.addAnnotation(annotation)
        }
        MarkdownDocumentModel.applyOutline(
            [MarkdownHeading(level: 1, title: "Wrapped", index: 0)], to: document)

        #expect(document.outlineRoot?.numberOfChildren == 1)
        #expect(flatten(document) == ["Wrapped @0:678"])   // 660 + 14 + 4
        #expect(outlineLinkCount(document) == 0)
    }

    @Test("A heading with no anchor inherits the last destination, or page 1")
    func missingAnchorsFallBack() {
        let document = makeBlankPDF(pageCount: 2)
        // Only the second heading has an anchor.
        let annotation = PDFAnnotation(bounds: CGRect(x: 72, y: 300, width: 100, height: 14),
                                       forType: .link, withProperties: nil)
        annotation.url = URL(string: "glassine-outline://1")
        document.page(at: 1)?.addAnnotation(annotation)

        MarkdownDocumentModel.applyOutline([
            MarkdownHeading(level: 1, title: "First", index: 0),
            MarkdownHeading(level: 1, title: "Second", index: 1),
            MarkdownHeading(level: 1, title: "Third", index: 2)
        ], to: document)

        let rows = flatten(document)
        #expect(rows.count == 3)
        // No anchor and nothing before it: the top of page 1.
        #expect(rows[0].hasPrefix("First @0:"))
        #expect(rows[1] == "Second @1:318")
        // No anchor of its own: it stays where the previous heading pointed.
        #expect(rows[2] == "Third @1:318")
    }

    @Test("An empty heading list leaves the document alone")
    func emptyHeadings() {
        let document = makeAnnotatedDocument()
        MarkdownDocumentModel.applyOutline([], to: document)
        #expect(document.outlineRoot == nil)
        #expect(outlineLinkCount(document) == 4)
    }
}
