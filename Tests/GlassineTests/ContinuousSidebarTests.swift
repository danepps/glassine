import AppKit
import GlassineCore
import PDFKit
import Testing
@testable import Glassine

@Suite("Continuous Markdown sidebar", .serialized) @MainActor
struct ContinuousSidebarTests {
    private func document(headings: Bool, height: CGFloat = 18_000) -> PDFDocument {
        let pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: height), for: .mediaBox)
        pdf.insert(page, at: 0)
        if headings {
            let root = PDFOutline()
            for (index, title) in ["Introduction", "Discussion", "Conclusion"].enumerated() {
                let node = PDFOutline()
                node.label = title
                node.destination = PDFDestination(page: page,
                    at: CGPoint(x: 0, y: height - CGFloat(index) * height / 3 - 0.37))
                root.insertChild(node, at: index)
            }
            pdf.outlineRoot = root
        }
        return pdf
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test("Continuous layout replaces the strip with contents and preserves the paginated preference")
    func layoutTransitions() throws {
        _ = NSApplication.shared
        let suite = "ContinuousSidebarTests.\(UUID())"
        let previous = Prefs.defaults
        let defaults = try #require(UserDefaults(suiteName: suite))
        Prefs.defaults = defaults
        defer { Prefs.defaults = previous; defaults.removePersistentDomain(forName: suite) }
        Prefs.sidebarMode = .thumbnails

        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = document(headings: true)
        let sidebar = SidebarViewController(pdfView: pdfView, isContinuousMarkdown: true)
        _ = sidebar.view
        sidebar.documentDidChange(isContinuousMarkdown: true)
        let children = descendants(of: sidebar.view)
        let thumbnails = try #require(children.compactMap { $0 as? PDFThumbnailView }.first)
        let control = try #require(children.compactMap { $0 as? NSSegmentedControl }.first)
        let outline = try #require(children.compactMap { $0 as? NSOutlineView }.first)
        #expect(thumbnails.isHidden && thumbnails.pdfView == nil)
        #expect(sidebar.mode == .outline && outline.numberOfRows == 3)
        #expect(control.segmentCount == 3 && control.selectedSegment == 0)
        #expect(control.toolTip(forSegment: 0) == "Table of Contents (⌥⌘3)")

        let target = try #require(pdfView.document?.outlineRoot?.child(at: 1)?.destination)
        for scale in [0.7, 1.0, 1.337, 2.0] {
            pdfView.autoScales = false
            pdfView.scaleFactor = scale
            pdfView.layoutDocumentView()
            pdfView.go(to: target)
            sidebar.syncSelection()
            #expect(outline.selectedRow == 1,
                    "scale: \(scale); destination: \(String(describing: pdfView.currentDestination?.point)); heading: \(target.point)")
            let beforeHeading = PDFDestination(page: try #require(target.page),
                at: CGPoint(x: target.point.x, y: target.point.y + 8 / scale))
            pdfView.go(to: beforeHeading)
            sidebar.syncSelection()
            #expect(outline.selectedRow == 0)
        }

        // The search/highlights indices change when the thumbnail button goes away.
        control.selectedSegment = 1
        control.sendAction(control.action, to: control.target)
        #expect(sidebar.showsSearchResults)
        pdfView.document = document(headings: true)
        sidebar.documentDidChange(isContinuousMarkdown: true)
        #expect(sidebar.showsSearchResults && control.selectedSegment == 1)
        control.selectedSegment = 2
        control.sendAction(control.action, to: control.target)
        #expect(sidebar.showsHighlights)
        control.selectedSegment = 0
        control.sendAction(control.action, to: control.target)
        #expect(sidebar.mode == .outline && !sidebar.showsHighlights)
        #expect(Prefs.sidebarMode == .thumbnails)
        sidebar.mode = .thumbnails
        #expect(sidebar.mode == .outline && thumbnails.isHidden)

        // Layout, rather than page aspect ratio, controls this behavior: even a
        // very tall ordinary PDF must keep its thumbnail navigation available.
        sidebar.documentDidChange(isContinuousMarkdown: false)
        #expect(sidebar.mode == .thumbnails && !thumbnails.isHidden)
        #expect(thumbnails.pdfView === pdfView)
        #expect(control.segmentCount == 4 && control.selectedSegment == 0)
        control.selectedSegment = 2
        control.sendAction(control.action, to: control.target)
        #expect(sidebar.showsSearchResults)
    }

    @Test("Heading-less continuous documents offer search, including after a heading disappears on reload")
    func noHeadings() throws {
        _ = NSApplication.shared
        let pdfView = PDFView()
        pdfView.document = document(headings: true)
        let sidebar = SidebarViewController(pdfView: pdfView, isContinuousMarkdown: true)
        _ = sidebar.view
        sidebar.documentDidChange(isContinuousMarkdown: true)
        pdfView.document = document(headings: false)
        sidebar.documentDidChange(isContinuousMarkdown: true)
        let children = descendants(of: sidebar.view)
        let title = try #require(children.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "No headings" })
        let button = try #require(children.compactMap { $0 as? NSButton }
            .first { $0.title == "Search Document" })
        #expect(!title.isHiddenOrHasHiddenAncestor)
        #expect(sidebar.canShowOutline && !sidebar.hasOutline && sidebar.mode == .outline)
        var requestedSearch = false
        sidebar.onSearchRequested = { requestedSearch = true; sidebar.showSearchResults() }
        button.performClick(nil)
        #expect(requestedSearch && sidebar.showsSearchResults)
        #expect(title.isHiddenOrHasHiddenAncestor)
        sidebar.onSearchRequested = nil
        sidebar.mode = .thumbnails
        #expect(!title.isHiddenOrHasHiddenAncestor)
        pdfView.document = document(headings: true)
        sidebar.documentDidChange(isContinuousMarkdown: true)
        #expect(title.isHiddenOrHasHiddenAncestor && sidebar.hasOutline)
    }
}
