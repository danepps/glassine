import AppKit
import CoreText
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

    /// A real paginated PDF with drawn heading baselines and an outline that
    /// survives serialization. Fractional destinations reproduce the same
    /// scroll-origin rounding as a typeset Markdown document.
    private func outlinedPDF() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        let headings: [(page: Int, y: CGFloat, title: String)] = [
            (0, 720, "Introduction"),
            (1, 720, "Earlier section"),
            (1, 539.63, "Fractional heading"),
            (1, 180.37, "End of page section"),
            (2, 792, "Next page section"),
            (3, 720, "Conclusion")
        ]
        for pageIndex in 0..<4 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for heading in headings where heading.page == pageIndex {
                context.textPosition = CGPoint(x: 72, y: min(heading.y, 760))
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: heading.title,
                    attributes: [.font: NSFont.systemFont(ofSize: 14)]))
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        let source = try #require(PDFDocument(data: data as Data))
        let root = PDFOutline()
        for heading in headings {
            let page = try #require(source.page(at: heading.page))
            let outline = PDFOutline()
            outline.label = heading.title
            outline.destination = PDFDestination(page: page, at: CGPoint(x: 72, y: heading.y))
            root.insertChild(outline, at: root.numberOfChildren)
        }
        source.outlineRoot = root
        let serialized = try #require(source.dataRepresentation())
        return try #require(PDFDocument(data: serialized))
    }

    private func lockedPDF() throws -> PDFDocument {
        let source = try outlinedPDF()
        let options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: "owner", .userPasswordOption: "reader"
        ]
        let encrypted = try #require(source.dataRepresentation(options: options))
        let locked = try #require(PDFDocument(data: encrypted))
        try #require(locked.isLocked)
        return locked
    }

    @Test("Locked PDFs attach thumbnails after unlock notifications and rebuild their page collection")
    func lockedPDFThumbnails() async throws {
        _ = NSApplication.shared
        let locked = try lockedPDF()
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = locked
        let sidebar = SidebarViewController(pdfView: pdfView, isContinuousMarkdown: false)
        _ = sidebar.view
        sidebar.documentDidChange(isContinuousMarkdown: false)
        let thumbnails = try #require(descendants(of: sidebar.view).compactMap { $0 as? PDFThumbnailView }.first)
        #expect(thumbnails.pdfView == nil)

        try #require(locked.unlock(withPassword: "reader"))
        // The reader's unlock observer refreshes the same installed document.
        // Repeated refreshes must not attach inside that notification stack.
        sidebar.documentDidChange(isContinuousMarkdown: false)
        sidebar.documentDidChange(isContinuousMarkdown: false)
        #expect(thumbnails.pdfView == nil)
        for _ in 0..<50 where thumbnails.pdfView == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(thumbnails.pdfView === pdfView)
        thumbnails.layoutSubtreeIfNeeded()
        let collection = try #require(descendants(of: thumbnails).compactMap { $0 as? NSCollectionView }.first)
        #expect(collection.numberOfSections == 1)
        #expect(collection.numberOfItems(inSection: 0) == locked.pageCount)
        for index in 0..<locked.pageCount {
            let page = try #require(locked.page(at: index))
            pdfView.go(to: page)
            #expect(pdfView.currentPage === page)
        }
    }

    @Test("A pending thumbnail attachment cannot outlive its document or installed layout")
    func pendingUnlockedThumbnails() async throws {
        _ = NSApplication.shared
        let locked = try lockedPDF()
        let pdfView = PDFView()
        pdfView.document = locked
        let sidebar = SidebarViewController(pdfView: pdfView, isContinuousMarkdown: false)
        _ = sidebar.view
        let thumbnails = try #require(descendants(of: sidebar.view).compactMap { $0 as? PDFThumbnailView }.first)
        try #require(locked.unlock(withPassword: "reader"))
        sidebar.documentDidChange(isContinuousMarkdown: false)
        // Changing layout while attachment is pending must keep the tall
        // continuous document detached, including after the queued work runs.
        sidebar.documentDidChange(isContinuousMarkdown: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(thumbnails.pdfView == nil && thumbnails.isHidden)

        sidebar.documentDidChange(isContinuousMarkdown: false)
        let replacement = try lockedPDF()
        pdfView.document = replacement
        sidebar.documentDidChange(isContinuousMarkdown: false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(thumbnails.pdfView == nil && replacement.isLocked)
        try #require(replacement.unlock(withPassword: "reader"))
        sidebar.documentDidChange(isContinuousMarkdown: false)
        for _ in 0..<50 where thumbnails.pdfView == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(thumbnails.pdfView === pdfView && pdfView.document === replacement)
    }

    @Test("Paginated PDF outline selection tolerates rounded jumps without crossing page boundaries")
    func paginatedOutlineRounding() throws {
        _ = NSApplication.shared
        let suite = "PaginatedOutlineTests.\(UUID())"
        let previous = Prefs.defaults
        let defaults = try #require(UserDefaults(suiteName: suite))
        Prefs.defaults = defaults
        defer { Prefs.defaults = previous; defaults.removePersistentDomain(forName: suite) }

        let pdf = try outlinedPDF()
        #expect(pdf.pageCount == 4 && pdf.string?.contains("Fractional heading") == true)
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = pdf
        let sidebar = SidebarViewController(pdfView: pdfView, isContinuousMarkdown: false)
        _ = sidebar.view
        sidebar.documentDidChange(isContinuousMarkdown: false)
        sidebar.mode = .outline
        let outline = try #require(descendants(of: sidebar.view).compactMap { $0 as? NSOutlineView }.first)
        #expect(outline.numberOfRows == 6)
        let target = try #require(pdf.outlineRoot?.child(at: 2)?.destination)
        let page = try #require(target.page)
        let nextPage = try #require(pdf.outlineRoot?.child(at: 4)?.destination)

        for scale in [0.7, 1.0, 1.337, 2.0] {
            pdfView.autoScales = false
            pdfView.scaleFactor = scale
            pdfView.layoutDocumentView()
            outline.deselectAll(nil)
            // Selection invokes the real sidebar delegate and PDFKit jump.
            outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            sidebar.syncSelection()
            #expect(outline.selectedRow == 2,
                    "scale: \(scale); destination: \(String(describing: pdfView.currentDestination?.point)); heading: \(target.point)")

            pdfView.go(to: PDFDestination(page: page,
                at: CGPoint(x: target.point.x, y: target.point.y + 8 / scale)))
            sidebar.syncSelection()
            #expect(outline.selectedRow == 1)
            pdfView.go(to: PDFDestination(page: page,
                at: CGPoint(x: target.point.x, y: target.point.y - 8 / scale)))
            sidebar.syncSelection()
            #expect(outline.selectedRow == 2)

            pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: 72, y: 0.37)))
            #expect(OutlineSync.currentOrdinal(of: pdfView)?.page == 1)
            sidebar.syncSelection()
            #expect(outline.selectedRow == 3)
            pdfView.go(to: nextPage)
            sidebar.syncSelection()
            #expect(outline.selectedRow == 4)
        }
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
