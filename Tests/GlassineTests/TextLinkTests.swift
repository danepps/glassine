import AppKit
import GlassineCore
import PDFKit
import Testing
import XCTest
@testable import Glassine

// MARK: - Fixtures

enum TextLinkFixture {
    static let turley = "https://jonathanturley.org/2026/11/09/the-reverse-ginsburg-scenario-democrats-may-only-need-to-wait-rather-than-pack-the-court/"
    static let yahoo = "https://www.yahoo.com/news/politics/article/final-2026-midterm-election-results-democrats-clinch-56-seat-senate-majority-with-peltolas-alaska-win-what-they-can--and-cant--do-next-184618858.html"
    static let huffpost = "https://www.huffpost.com/entry/supreme-court-packing-expanding-democrats-2028_n_6a9af459e4b0bd4d29d41faf"

    /// The three addresses as plain text: each paragraph is an HTML block,
    /// which the autolinker never touches, so the PDF has the words and no
    /// link annotation, as a Word-made PDF does. The Turley address ends its
    /// paragraph in `/`, and the next paragraph starts with a capitalised word.
    static let plainMarkdown = """
    <p>Turley, Nov. 9, 2026: \(turley)</p>

    <p>Marquette Law School Poll, Nov. 2026.</p>

    <p>Yahoo News, Nov. 20, 2026: \(yahoo)</p>

    <p>HuffPost, Sept. 4, 2026: \(huffpost)</p>

    <p>Closing paragraph with enough words in it to run onto a second line of the page, so the column has an ordinary right margin to measure.</p>
    """

    /// The same addresses as bare Markdown, which the autolinker turns into
    /// real links.
    static let bareMarkdown = """
    - Turley, Nov. 9, 2026: \(turley)
    - Marquette Law School Poll, Nov. 2026.
    - Yahoo News, Nov. 20, 2026: \(yahoo)
    - HuffPost, Sept. 4, 2026: \(huffpost)
    """

    /// Ink, the style Dan reads in: its Iowan Old Style sets `ff` as a
    /// ligature, as the PDF that showed the bug did.
    static func styling(size: Int) -> MarkdownStyling {
        MarkdownStyling(styleID: "ink", css: MarkdownHTML.builtInStyle("ink"), size: size, layout: .pages)
    }

    static func html(_ markdown: String, size: Int) -> String {
        MarkdownHTML.page(body: MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil).html,
                          title: "Text link fixture", styling: styling(size: size))
    }

    /// Typesets `markdown` through the app's WebKit print path, spinning the
    /// main run loop until it is done. Synchronous, for XCTest.
    @MainActor
    static func render(_ markdown: String, size: Int = 13) throws -> PDFDocument {
        _ = NSApplication.shared
        let printer = WebKitHTMLPrinter()
        defer { printer.teardown() }
        let queue = RenderQueue(printer: printer)
        var result: Result<RenderedMarkdown, Error>?
        queue.render(html: html(markdown, size: size), baseURL: nil, key: "text-links", layout: .pages) { result = $0 }
        let deadline = Date().addingTimeInterval(30)
        while result == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get().document
    }

    /// Typesets `markdown` through the app's WebKit print path. For Swift
    /// Testing.
    @MainActor
    static func renderAsync(_ markdown: String, size: Int = 13) async throws -> PDFDocument {
        _ = NSApplication.shared
        let printer = WebKitHTMLPrinter()
        defer { printer.teardown() }
        let queue = RenderQueue(printer: printer)
        let rendered: RenderedMarkdown = try await withCheckedThrowingContinuation { continuation in
            queue.render(html: html(markdown, size: size), baseURL: nil, key: "text-links", layout: .pages) {
                continuation.resume(with: $0)
            }
        }
        return rendered.document
    }

    /// The page text's range for `address`, which the PDF may have split
    /// with line breaks wherever it wrapped, and in which `ff` may be the one
    /// ligature character U+FB00.
    static func range(of address: String, on page: PDFPage) -> NSRange? {
        let text = (page.string ?? "") as NSString
        let target = Array(address.utf16)
        var start = text.range(of: String(address.prefix(12)))
        while start.location != NSNotFound {
            var i = start.location, j = 0
            while i < text.length, j < target.count {
                let c = text.character(at: i)
                if c == 0x0A { i += 1; continue }
                if c == 0xFB00, j + 1 < target.count, target[j] == 0x66, target[j + 1] == 0x66 {
                    i += 1; j += 2; continue
                }
                guard c == target[j] else { break }
                i += 1; j += 1
            }
            if j == target.count { return NSRange(location: start.location, length: i - start.location) }
            let rest = NSMaxRange(start)
            start = text.range(of: String(address.prefix(12)),
                               range: NSRange(location: rest, length: text.length - rest))
        }
        return nil
    }

    /// Where each line of `text` starts: 0 and every index after a break.
    static func lineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        for i in 0..<text.length where text.character(at: i) == 0x0A { starts.append(i + 1) }
        return starts
    }

    /// Points to click on each line the address is on: the middle of its part
    /// of the line, and its first and last characters there -- the ends are
    /// where an index that slips by a character or two leaves the address.
    static func clickPoints(of address: String, on page: PDFPage) -> [CGPoint] {
        guard let range = range(of: address, on: page) else { return [] }
        let text = (page.string ?? "") as NSString
        func center(_ index: Int) -> CGPoint? {
            guard let box = page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page),
                  box.width > 0 else { return nil }
            return CGPoint(x: box.midX, y: box.midY)
        }
        var points = linePoints(of: address, on: page)
        var lineStart = range.location
        for i in range.location...NSMaxRange(range) {
            guard i == NSMaxRange(range) || text.character(at: i) == 0x0A else { continue }
            if let first = center(lineStart) { points.append(first) }
            if i > lineStart, let last = center(i - 1) { points.append(last) }
            lineStart = i + 1
        }
        return points
    }

    /// A point in the middle of the address's part of each line it is on,
    /// in page space, top line first.
    static func linePoints(of address: String, on page: PDFPage) -> [CGPoint] {
        guard let range = range(of: address, on: page),
              let selection = page.selection(for: range) else { return [] }
        return selection.selectionsByLine().map { line in
            let box = line.bounds(for: page)
            return CGPoint(x: box.midX, y: box.midY)
        }
    }
}

// MARK: - Joining by the page's geometry (Swift Testing)

extension MacAppTests {
    @Suite("Plain-text links across lines", .serialized) @MainActor
    struct TextLinkGeometryTests {

        /// Ink at 13 pt (Dan's setting) and at 22 pt, where the HuffPost
        /// address takes three lines. At 22 pt WebKit breaks the Yahoo address
        /// inside "artic|le", where no rule can tell a wrap from a word that
        /// ended, so it is checked at 13 pt only, where every break follows a
        /// hyphen or slash.
        @Test("An address ending its paragraph in / is not joined to the next paragraph; a wrapped one is joined whole",
              arguments: [13, 22])
        func paragraphBreakVersusWrap(size: Int) async throws {
            let pdf = try await TextLinkFixture.renderAsync(TextLinkFixture.plainMarkdown, size: size)
            let page = try #require(pdf.page(at: 0))
            #expect(page.annotations.allSatisfy { $0.type != "Link" },
                    "the fixture's addresses must be plain text")
            let text = try #require(page.string)

            // The Turley address: its last character is "/", the paragraph ends
            // there, and "Marquette" starts the next one.
            let turley = try #require(TextLinkFixture.range(of: TextLinkFixture.turley, on: page))
            let marquette = (text as NSString).range(of: "Marquette")
            #expect(marquette.location > NSMaxRange(turley))
            let turleyPoints = TextLinkFixture.clickPoints(of: TextLinkFixture.turley, on: page)
            #expect(turleyPoints.count >= 4, "the Turley address should wrap: \(turleyPoints)")
            for point in turleyPoints {
                let index = try #require(page.linkCharacterIndex(at: point))
                #expect(page.textLinkURL(at: index)?.absoluteString == TextLinkFixture.turley,
                        "Turley clicked at \(point), \(size) pt")
                // Without the geometry the text alone runs on into "Marquette".
                #expect(TextLinks.url(in: text, at: index)?.absoluteString
                        == TextLinkFixture.turley + "Marquette")
            }

            // Every line of the other two resolves to the whole address; the
            // HuffPost text has the ﬀ ligature in it.
            #expect(text.contains("\u{FB00}"))
            for address in size == 13 ? [TextLinkFixture.yahoo, TextLinkFixture.huffpost]
                                      : [TextLinkFixture.huffpost] {
                let lines = TextLinkFixture.linePoints(of: address, on: page).count
                #expect(lines >= (address == TextLinkFixture.yahoo ? 3 : 2), "\(address) at \(size) pt")
                for point in TextLinkFixture.clickPoints(of: address, on: page) {
                    let index = try #require(page.linkCharacterIndex(at: point))
                    #expect(page.textLinkURL(at: index)?.absoluteString == address,
                            "clicked at \(point), \(size) pt")
                }
            }
        }

        /// PDFKit's `characterIndex(at:)` slips a character per line on this
        /// system (see `PDFPage.linkCharacterIndex(at:)`); the link lookup
        /// must name the character drawn under the point on every line.
        @Test("The link lookup names the character drawn under the point, on every line of a page")
        func characterUnderThePoint() async throws {
            let webKit = try await TextLinkFixture.renderAsync(TextLinkFixture.plainMarkdown, size: 22)
            let coreText = try #require(PDFDocument(data: makeScanPDFData(pages: [ScanFixture.lines()], scan: false)))
            for page in [try #require(webKit.page(at: 0)), try #require(coreText.page(at: 0))] {
                let text = try #require(page.string) as NSString
                var checked = 0, slipped = 0
                for start in TextLinkFixture.lineStarts(in: text) {
                    let index = start + 2
                    guard index < text.length, text.character(at: index) != 0x0A,
                          let box = page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page),
                          box.width > 0 else { continue }
                    let point = CGPoint(x: box.midX, y: box.midY)
                    #expect(page.linkCharacterIndex(at: point) == index,
                            "line starting at \(start): \(text.substring(with: NSRange(location: start, length: min(20, text.length - start))))")
                    if page.characterIndex(at: point) != index { slipped += 1 }
                    checked += 1
                }
                #expect(checked >= 12)
                // Not asserted: a PDFKit fix would make it zero.
                print("characterIndex(at:) slipped on \(slipped) of \(checked) line starts")
            }
        }

        @Test("No evidence, no refusal: too few lines, or a rotated page, always joins")
        func conservativeWithoutEvidence() async throws {
            let pdf = try await TextLinkFixture.renderAsync(TextLinkFixture.plainMarkdown)
            let page = try #require(pdf.page(at: 0))
            let text = try #require(page.string) as NSString
            let turley = try #require(TextLinkFixture.range(of: TextLinkFixture.turley, on: page))
            let lastRunStart = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards,
                                                     range: turley).location + 1
            let previous = NSRange(location: lastRunStart, length: NSMaxRange(turley) - lastRunStart)
            let next = text.range(of: "Marquette")
            #expect(!page.lineWrapped(between: previous, and: next))
            #expect(page.lineWrapped(between: previous, and: next, lines: Array(page.lineBoxes().prefix(2))))
            page.rotation = 90
            defer { page.rotation = 0 }
            #expect(page.lineWrapped(between: previous, and: next))
        }

        @Test("Bare addresses in rendered Markdown carry a link annotation on every line, with the whole address")
        func autolinkAnnotations() async throws {
            let pdf = try await TextLinkFixture.renderAsync(TextLinkFixture.bareMarkdown)
            let page = try #require(pdf.page(at: 0))
            for address in [TextLinkFixture.turley, TextLinkFixture.yahoo, TextLinkFixture.huffpost] {
                let points = TextLinkFixture.linePoints(of: address, on: page)
                #expect(points.count >= 2, "\(address) should wrap")
                for point in points {
                    let annotation = page.annotation(at: point)
                    #expect(annotation?.type == "Link", "no link annotation at \(point) for \(address)")
                    #expect((annotation?.action as? PDFActionURL)?.url?.absoluteString == address,
                            "wrong address at \(point)")
                }
            }
        }
    }
}

// MARK: - The real click path (XCTest)

/// A real PDFKit click on a plain-text address, in a window that is never
/// activated (the technique and the reason for XCTest are in
/// `ScanSelectionGestureTests`). `openURL` is replaced, so nothing is opened.
/// Only plain-text addresses are clicked: PDFKit would open a real link
/// annotation itself.
@MainActor
final class TextLinkClickTests: XCTestCase {

    /// Ink at 13 pt, Dan's setting, wraps the HuffPost address over two
    /// lines; at 22 pt it takes three.
    func testClickOnEachLineOfAWrappedPlainTextAddressOpensTheWholeAddress() throws {
        try checkClicks(size: 13, huffpostLines: 2)
        try checkClicks(size: 22, huffpostLines: 3)
    }

    private func checkClicks(size: Int, huffpostLines: Int) throws {
        let pdf = try TextLinkFixture.render(TextLinkFixture.plainMarkdown, size: size)
        let page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertTrue(page.annotations.allSatisfy { $0.type != "Link" }, "\(size) pt")
        XCTAssertTrue(page.string?.contains("\u{FB00}") == true,
                      "expected the ﬀ ligature in the page text at \(size) pt")
        let harness = ScanSelectionGestureTests.Harness(document: pdf, page: page)
        defer { harness.close() }
        var opened: [URL] = []
        harness.view.openURL = { opened.append($0) }

        XCTAssertEqual(TextLinkFixture.linePoints(of: TextLinkFixture.huffpost, on: page).count,
                       huffpostLines, "HuffPost lines at \(size) pt")
        // The middle of each line, then the first and last character of each.
        let points = TextLinkFixture.clickPoints(of: TextLinkFixture.huffpost, on: page)
        XCTAssertEqual(points.count, huffpostLines * 3)
        for (index, point) in points.enumerated() {
            opened.removeAll()
            let where_ = "\(size) pt, click \(index + 1) at \(point)"
            let viewPoint = harness.point(point, on: page)
            XCTAssertTrue(harness.view.bounds.contains(viewPoint), "\(where_) is off screen")
            XCTAssertEqual(harness.view.textLink(atViewPoint: viewPoint)?.absoluteString,
                           TextLinkFixture.huffpost, "\(where_), without a click")
            _ = harness.click(viewPoint, count: 1)
            XCTAssertEqual(opened.map(\.absoluteString), [TextLinkFixture.huffpost], "\(where_), clicked")
        }

        // The Turley address, clicked on its last line, stops at its "/".
        opened.removeAll()
        let turley = try XCTUnwrap(TextLinkFixture.linePoints(of: TextLinkFixture.turley, on: page).last)
        _ = harness.click(harness.point(turley, on: page), count: 1)
        XCTAssertEqual(opened.map(\.absoluteString), [TextLinkFixture.turley], "\(size) pt, Turley")
    }
}

// MARK: - Gesture recognizers, not mouse overrides (XCTest)

/// On macOS 27 PDFKit handles the mouse, and a finger on a touch display,
/// through gesture recognizers, and installs none of them on a `PDFView`
/// subclass that overrides `mouseDown`, `mouseDragged` or `mouseUp`: such a
/// view drops to the old tracking loop, and a finger gets only AppKit's mouse
/// emulation instead of PDFKit's touch selection, long-press menu and double
/// tap. `ReaderPDFView` opens plain-text addresses from a click recognizer for
/// that reason, and these hold the line.
@MainActor
final class ReaderPDFViewGestureTests: XCTestCase {

    func testReaderViewDoesNotOverrideTheMouseMethods() {
        for name in ["mouseDown:", "mouseDragged:", "mouseUp:"] {
            let selector = NSSelectorFromString(name)
            XCTAssertEqual(class_getInstanceMethod(ReaderPDFView.self, selector),
                           class_getInstanceMethod(PDFView.self, selector),
                           "ReaderPDFView overrides \(name); PDFKit then installs no gesture recognizers")
        }
    }

    func testReaderViewKeepsPDFKitsGestureRecognizers() throws {
        let pdf = try TextLinkFixture.render(TextLinkFixture.plainMarkdown, size: 13)
        func counts(_ view: PDFView) -> (view: Int, pages: Int) {
            let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 700, height: 1000),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view.frame = window.contentView!.bounds
            window.contentView!.addSubview(view)
            view.document = pdf
            view.layoutDocumentView()
            defer { window.close() }
            return (view.gestureRecognizers.count, view.documentView?.gestureRecognizers.count ?? 0)
        }
        let plain = counts(PDFView())
        try XCTSkipIf(plain.pages == 0, "this PDFKit installs no gesture recognizers on its pages (before macOS 27)")
        let reader = counts(ReaderPDFView())
        XCTAssertEqual(reader.pages, plain.pages, "PDFKit's recognizers on the document view")
        // PDFKit's own, plus the text-link click and the page-turn tap.
        XCTAssertEqual(reader.view, plain.view + 2, "PDFKit's recognizers on the view")
    }

    // MARK: Page turns by touch

    /// A touch cannot be synthesized (it reaches neither `NSApp.sendEvent` nor
    /// an event monitor), so these cover everything up to the finger: where
    /// the strips are, what a tap in them does, and what it leaves alone.
    func testPageTurnStripsAreTheOuterEdgesOfTheView() {
        let wide = NSRect(x: 0, y: 0, width: 1000, height: 800)   // 14% = 140, capped at 120
        XCTAssertEqual(ReaderPDFView.pageTurnZone(x: 0, in: wide), .back)
        XCTAssertEqual(ReaderPDFView.pageTurnZone(x: 119, in: wide), .back)
        XCTAssertNil(ReaderPDFView.pageTurnZone(x: 121, in: wide))
        XCTAssertNil(ReaderPDFView.pageTurnZone(x: 500, in: wide))
        XCTAssertNil(ReaderPDFView.pageTurnZone(x: 879, in: wide))
        XCTAssertEqual(ReaderPDFView.pageTurnZone(x: 881, in: wide), .forward)
        let medium = NSRect(x: 0, y: 0, width: 600, height: 800)  // 14% = 84
        XCTAssertEqual(ReaderPDFView.pageTurnZone(x: 83, in: medium), .back)
        XCTAssertNil(ReaderPDFView.pageTurnZone(x: 85, in: medium))
        XCTAssertEqual(ReaderPDFView.pageTurnZone(x: 517, in: medium), .forward)
        let narrow = NSRect(x: 0, y: 0, width: 300, height: 800)  // floor of 56
        XCTAssertEqual(ReaderPDFView.pageTurnZone(x: 55, in: narrow), .back)
        XCTAssertNil(ReaderPDFView.pageTurnZone(x: 57, in: narrow))
        // No room for a middle: no strips at all.
        XCTAssertNil(ReaderPDFView.pageTurnZone(x: 5, in: NSRect(x: 0, y: 0, width: 150, height: 800)))
    }

    func testTurnPageMovesAPageAndStopsAtTheEnds() throws {
        let pdf = PDFDocument()
        for index in 0..<3 { pdf.insert(PDFPage(), at: index) }
        let harness = ScanSelectionGestureTests.Harness(document: pdf, page: try XCTUnwrap(pdf.page(at: 0)))
        defer { harness.close() }
        let view = harness.view
        func current() -> Int { view.currentPage.map(pdf.index(for:)) ?? -1 }
        XCTAssertEqual(current(), 0)
        view.turnPage(.back)
        XCTAssertEqual(current(), 0, "back from the first page")
        view.turnPage(.forward)
        XCTAssertEqual(current(), 1)
        view.turnPage(.forward)
        view.turnPage(.forward)
        XCTAssertEqual(current(), 2, "forward from the last page")
        view.turnPage(.back)
        XCTAssertEqual(current(), 1)
    }

    /// An address in the strip is still an address, and the middle of the
    /// view turns nothing.
    func testATapOnAnAddressOrInTheMiddleIsNotAPageTurn() throws {
        let pdf = try TextLinkFixture.render(TextLinkFixture.plainMarkdown, size: 13)
        let page = try XCTUnwrap(pdf.page(at: 0))
        let harness = ScanSelectionGestureTests.Harness(document: pdf, page: page)
        defer { harness.close() }
        let view = harness.view
        XCTAssertNil(view.pageTurn(forTapAt: NSPoint(x: view.bounds.midX, y: view.bounds.midY)))
        XCTAssertEqual(view.pageTurn(forTapAt: NSPoint(x: view.bounds.minX + 4, y: view.bounds.midY)), .back)
        XCTAssertEqual(view.pageTurn(forTapAt: NSPoint(x: view.bounds.maxX - 30, y: view.bounds.midY)), .forward)
        // Every point of the wrapped address, wherever it falls.
        for point in TextLinkFixture.clickPoints(of: TextLinkFixture.huffpost, on: page) {
            XCTAssertNil(view.pageTurn(forTapAt: harness.point(point, on: page)), "on the address at \(point)")
        }
    }

    /// The second click of a double click reaches PDFKit, which reads the
    /// address itself; the first click has already opened it.
    func testDoubleClickOnAnAddressOpensItOnce() throws {
        let pdf = try TextLinkFixture.render(TextLinkFixture.plainMarkdown, size: 13)
        let page = try XCTUnwrap(pdf.page(at: 0))
        let harness = ScanSelectionGestureTests.Harness(document: pdf, page: page)
        defer { harness.close() }
        var opened: [URL] = []
        harness.view.openURL = { opened.append($0) }
        for point in TextLinkFixture.linePoints(of: TextLinkFixture.huffpost, on: page) {
            opened.removeAll()
            _ = harness.click(harness.point(point, on: page), count: 2)
            XCTAssertEqual(opened.map(\.absoluteString), [TextLinkFixture.huffpost], "double click at \(point)")
        }
    }

    /// A press that moves is not the click recognizer's. Whatever PDFKit then
    /// makes of it (a selection, or a click on the address as it read it),
    /// nothing but the whole address is ever opened, and the view goes on
    /// answering clicks.
    func testDragBegunOnAnAddressNeverOpensPartOfIt() throws {
        let pdf = try TextLinkFixture.render(TextLinkFixture.plainMarkdown, size: 13)
        let page = try XCTUnwrap(pdf.page(at: 0))
        let harness = ScanSelectionGestureTests.Harness(document: pdf, page: page)
        defer { harness.close() }
        var opened: [URL] = []
        harness.view.openURL = { opened.append($0) }
        let lines = TextLinkFixture.linePoints(of: TextLinkFixture.huffpost, on: page)
        for point in lines {
            let start = harness.point(point, on: page)
            _ = harness.drag(from: start, to: CGPoint(x: start.x + 40, y: start.y))
            _ = harness.drag(from: start, to: CGPoint(x: start.x + 30, y: start.y + 200))
        }
        XCTAssertTrue(opened.allSatisfy { $0.absoluteString == TextLinkFixture.huffpost },
                      "opened \(opened.map(\.absoluteString))")
        opened.removeAll()
        let first = try XCTUnwrap(lines.first)
        _ = harness.click(harness.point(first, on: page), count: 1)
        XCTAssertEqual(opened.map(\.absoluteString), [TextLinkFixture.huffpost], "a click after the drags")
    }
}
