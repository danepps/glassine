import AppKit
import CoreText
import PDFKit
import Testing
@testable import Glassine

@Suite("Search results sidebar") @MainActor
struct SearchResultsTests {
    private func document() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in ["Before alpha comes after. Another alpha passage.", "Page two has beta and alpha nearby."] {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            ])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed),
                CFRange(location: 0, length: 0),
                CGPath(rect: box.insetBy(dx: 48, dy: 48), transform: nil), nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    @Test("Snippets include context without changing the match used for navigation")
    func snippet() throws {
        let pdf = try document()
        let match = try #require(pdf.findString("alpha", withOptions: []).first)
        let text = SearchResultsViewController.snippet(for: match)
        #expect(text.contains("Before alpha comes after"))
        #expect(match.string == "alpha")
        let second = pdf.findString("alpha", withOptions: [])[1]
        let context = SearchResultsViewController.context(for: second)
        #expect((context.text as NSString).substring(with: context.matchRange) == "alpha")
        #expect(context.matchRange.location > (context.text as NSString).range(of: "alpha").location)
        #expect(SearchResultsViewController.pageReference(for: match) == "Page 1")
    }

    @Test("Appending, stepping, replacing and clearing results preserve selection ownership")
    func listLifecycle() async throws {
        _ = NSApplication.shared
        let pdf = try document()
        let hits = pdf.findString("alpha", withOptions: [])
        let results = SearchResultsViewController()
        var selected: [Int] = []
        results.onSelect = { selected.append($0) }
        results.update(Array(hits.prefix(1)), current: 0)
        results.update(hits, current: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(results.table.numberOfRows == 3)
        results.select(2)
        #expect(results.table.selectedRow == 2)
        #expect(selected.isEmpty)
        results.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(selected == [1])
        results.activateSelectedResult()
        #expect(selected == [1, 1])
        results.update(pdf.findString("beta", withOptions: []), current: 0)
        #expect(results.table.numberOfRows == 1)
        #expect(results.matches.first?.string == "beta")
        results.update([], current: 0)
        #expect(results.table.numberOfRows == 0)
        #expect(results.table.selectedRow == -1)
        #expect(selected == [1, 1])
    }

    @Test("Search is a local sidebar mode and survives a replacement document")
    func sidebarMode() throws {
        _ = NSApplication.shared
        let view = PDFView()
        view.document = try document()
        let sidebar = SidebarViewController(pdfView: view)
        sidebar.showSearchResults()
        #expect(sidebar.showsSearchResults)
        sidebar.documentDidChange()
        #expect(sidebar.showsSearchResults)
        sidebar.mode = .thumbnails
        #expect(!sidebar.showsSearchResults)
    }

    @Test("Current-match feedback moves between same-page hits and follows PDF geometry")
    func currentMatchFeedback() throws {
        _ = NSApplication.shared
        let pdf = try document()
        let hits = pdf.findString("alpha", withOptions: [])
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let view = PDFView(frame: host.bounds)
        view.document = pdf
        host.addSubview(view)
        let indicator = FindMatchIndicator(pdfView: view)
        indicator.frame = host.bounds
        host.addSubview(indicator)
        view.layoutDocumentView()

        indicator.show(hits[0], reduceMotion: false)
        let firstRect = try #require(indicator.marker.path).boundingBoxOfPath
        #expect(!firstRect.isEmpty)
        #expect(indicator.pulse.animation(forKey: "findNavigation") != nil)
        indicator.show(hits[1], reduceMotion: false)
        let secondRect = try #require(indicator.marker.path).boundingBoxOfPath
        #expect(hits[0].pages.first === hits[1].pages.first)
        #expect(firstRect != secondRect)
        #expect(indicator.pulse.animationKeys() == ["findNavigation"])
        #expect(indicator.hitTest(secondRect.origin) == nil)

        view.scaleFactor *= 1.5
        view.layoutDocumentView()
        indicator.layout()
        let zoomed = try #require(indicator.marker.path).boundingBoxOfPath
        #expect(abs((zoomed.width - 6) / (secondRect.width - 6) - 1.5) < 0.01)
        let clip = try #require(view.documentView?.enclosingScrollView?.contentView)
        let beforeScroll = zoomed
        let clipOriginBefore = indicator.convert(NSPoint.zero, from: clip)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + 50))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        let afterScroll = try #require(indicator.marker.path).boundingBoxOfPath
        let scrollDistance = indicator.convert(NSPoint.zero, from: clip).y - clipOriginBefore.y
        #expect(abs(scrollDistance) > 0)
        #expect(abs(afterScroll.minY - beforeScroll.minY - scrollDistance) < 0.01)

        indicator.show(hits[0], reduceMotion: true)
        #expect(indicator.pulse.animationKeys() == nil)
        #expect(indicator.marker.path?.isEmpty == false)
        indicator.show(hits[1], reduceMotion: false)
        indicator.clear()
        #expect(indicator.marker.path?.isEmpty == true)
        #expect(indicator.pulse.animationKeys() == nil)
        indicator.show(hits[0], reduceMotion: true)
        view.document = try document()
        indicator.layout()
        #expect(indicator.marker.path?.isEmpty == true)
        indicator.clear()
        #expect(indicator.marker.path?.isEmpty == true)
        #expect(indicator.pulse.animationKeys() == nil)
    }
}
