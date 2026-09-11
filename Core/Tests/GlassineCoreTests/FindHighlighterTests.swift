import AppKit
import PDFKit
import Testing
@testable import GlassineCore

private final class HighlightPageDelegate: NSObject, PDFDocumentDelegate {
    func classForPage() -> AnyClass { ReaderPage.self }
}

private final class CountedSelection: PDFSelection {
    var measurements = 0
    override func selectionsByLine() -> [PDFSelection] {
        measurements += 1
        return super.selectionsByLine()
    }
}

@Suite("Incremental find highlights") @MainActor
struct FindHighlighterTests {
    @Test("Appending results measures only new matches and clearing removes old ink")
    func incrementalGeometry() throws {
        let delegate = HighlightPageDelegate()
        let pdf = makeTextPDF(pages: ["alpha beta alpha", "alpha gamma"])
        pdf.delegate = delegate
        let hits = pdf.findString("alpha", withOptions: [])
        #expect(hits.count == 3)
        let selections = hits.map { hit in
            let selection = CountedSelection(document: pdf)
            selection.add(hit)
            return selection
        }
        let view = PDFView()
        view.document = pdf
        let highlighter = FindHighlighter(pdfView: view)
        highlighter.isInverted = true
        highlighter.setFindMatches([selections[0]], current: 0)
        highlighter.setFindMatches(selections, current: 0)
        highlighter.setFindMatches(selections, current: 0)
        #expect(selections.map(\.measurements) == [1, 1, 1])
        let first = try #require(pdf.page(at: 0) as? ReaderPage)
        let last = try #require(pdf.page(at: 1) as? ReaderPage)
        #expect(first.findHighlights.count == 2)
        #expect(last.findHighlights.count == 1)
        highlighter.setCurrentMatchIndex(2)
        #expect(!first.findHighlights.contains(where: { $0.isCurrent }))
        #expect(last.findHighlights.allSatisfy { $0.isCurrent })
        highlighter.setFindMatches([], current: 0)
        #expect(first.findHighlights.isEmpty)
        #expect(last.findHighlights.isEmpty)
        withExtendedLifetime(delegate) {}
    }

    @Test("Replacing an equally sized result set removes the previous page's highlights")
    func replacement() throws {
        let delegate = HighlightPageDelegate()
        let pdf = makeTextPDF(pages: ["alpha", "beta"])
        pdf.delegate = delegate
        let view = PDFView()
        view.document = pdf
        let highlighter = FindHighlighter(pdfView: view)
        highlighter.isInverted = true
        highlighter.setFindMatches(pdf.findString("alpha", withOptions: []), current: 0)
        highlighter.setFindMatches(pdf.findString("beta", withOptions: []), current: 0)
        #expect((pdf.page(at: 0) as? ReaderPage)?.findHighlights.isEmpty == true)
        #expect((pdf.page(at: 1) as? ReaderPage)?.findHighlights.count == 1)
        highlighter.isInverted = false
        #expect((pdf.page(at: 1) as? ReaderPage)?.findHighlights.isEmpty == true)
        withExtendedLifetime(delegate) {}
    }
}
