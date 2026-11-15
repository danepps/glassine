import AppKit
import CoreText
import GlassineCore
import ObjectiveC
import PDFKit
import Testing
import UniformTypeIdentifiers
import XCTest
@testable import Glassine

// MARK: - Fixtures

/// Scanned pages with an invisible OCR layer: each page one image tagged as a
/// Figure (as JSTOR tags its scans), invisible text drawn over it. On macOS 27
/// PDFKit turns the image into a U+FFFC covering the page, and its point
/// hit-testing lands there instead of on the words -- the bug
/// `ScanSelectionPatch` fixes. `scan: false` draws the same text visibly with
/// no image: an ordinary born-digital page.
func makeScanPDFData(pages: [[String]], scan: Bool = true,
                     size: CGSize = CGSize(width: 612, height: 792)) -> Data {
    let output = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    guard let consumer = CGDataConsumer(data: output),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil),
          let bitmap = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
    else { fatalError("could not open a PDF context") }
    bitmap.setFillColor(gray: 1, alpha: 1)
    bitmap.fill(box)
    bitmap.setFillColor(gray: 0.3, alpha: 1)
    for row in stride(from: 60, to: Int(size.height) - 60, by: 13) {
        bitmap.fill(CGRect(x: 60, y: row, width: Int(size.width) - 160, height: 7))
    }
    guard let image = bitmap.makeImage() else { fatalError("no image") }
    let font = CTFontCreateWithName("Times-Roman" as CFString, 11, nil)

    for lines in pages {
        let framesetter = CTFramesetterCreateWithAttributedString(
            NSAttributedString(string: lines.joined(separator: "\n"), attributes: [.font: font]))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: box.insetBy(dx: 60, dy: 60), transform: nil), nil)
        context.beginPDFPage(nil)
        if scan {
            CGPDFContextBeginTag(context, .figure, [:] as CFDictionary)
            context.draw(image, in: box)
            CGPDFContextEndTag(context)
        }
        let ctLines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, origin) in zip(ctLines, origins) {
            context.textPosition = CGPoint(x: 60 + origin.x, y: 60 + origin.y)
            context.setTextDrawingMode(scan ? .invisible : .fill)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    return output as Data
}

enum ScanFixture {
    static func lines(page: Int = 0) -> [String] {
        (0..<30).map { "Line \($0) of page \(page + 1), where scholars argue the point." }
    }

    /// Writes `data` into a fresh temporary folder and opens it the way the app
    /// does, so every page is a `ReaderPage`.
    @MainActor
    static func open(_ data: Data) throws -> (GlassineDocument, PDFDocument, URL) {
        _ = NSApplication.shared
        ScanSelectionPatch.install()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glassine-scan-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Scan.pdf")
        try data.write(to: url)
        let document = try GlassineDocument(contentsOf: url, ofType: UTType.pdf.identifier)
        guard let pdf = document.pdf else { throw CocoaError(.fileReadCorruptFile) }
        return (document, pdf, folder)
    }

    /// Does this system's PDFKit turn the synthetic scan into a U+FFFC that
    /// swallows hit-testing? If not, there is nothing here to fix.
    static func reproduces(_ page: PDFPage) -> Bool {
        guard let text = page.string as NSString?, text.length > 0,
              text.character(at: 0) == 0xFFFC else { return false }
        let r = page.selection(for: NSRange(location: text.length / 2, length: 1))?.bounds(for: page) ?? .zero
        return page.characterIndex(at: CGPoint(x: r.midX, y: r.midY)) == 0
    }

    /// The true box of one character (a one-character selection's bounds;
    /// `characterBounds(at:)` drifts on invisible text).
    static func box(_ index: Int, on page: PDFPage) -> CGRect {
        page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page) ?? .zero
    }

    /// Where `needle` occurs on `page`, searching from `after`.
    static func range(of needle: String, on page: PDFPage, after: Int = 0) -> NSRange {
        let text = (page.string ?? "") as NSString
        return text.range(of: needle, range: NSRange(location: after, length: text.length - after))
    }

    /// Just inside the left edge of the first character of `range`, and just
    /// inside the right edge of its last: points whose caret is unambiguous.
    static func leftEdge(of range: NSRange, on page: PDFPage) -> CGPoint {
        let r = box(range.location, on: page)
        return CGPoint(x: r.minX + 1, y: r.midY)
    }

    static func rightEdge(of range: NSRange, on page: PDFPage) -> CGPoint {
        let r = box(NSMaxRange(range) - 1, on: page)
        return CGPoint(x: r.maxX - 1, y: r.midY)
    }

    static func center(of range: NSRange, on page: PDFPage) -> CGPoint {
        let r = page.selection(for: range)?.bounds(for: page) ?? .zero
        return CGPoint(x: r.midX, y: r.midY)
    }
}

// MARK: - Page-level behaviour (Swift Testing, no events)

extension MacAppTests {
    @Suite("Text selection on scanned pages", .serialized) @MainActor
    struct ScanSelectionTests {

        @Test("The patch installs all three overrides on ReaderPage, never on PDFPage")
        func installs() {
            ScanSelectionPatch.install()
            #expect(ScanSelectionPatch.installedSelectors == [
                "selectionFromPoint:toPoint:type:",
                "selectionFromPointToBottom:type:",
                "selectionFromTopToPoint:type:"
            ])
            for name in ScanSelectionPatch.installedSelectors {
                let selector = NSSelectorFromString(name)
                #expect(class_getMethodImplementation(ReaderPage.self, selector)
                        != class_getMethodImplementation(PDFPage.self, selector))
            }
        }

        @Test("PDFKit's own point lookups on a scan go through the patch")
        func publicLookups() throws {
            let (document, pdf, folder) = try ScanFixture.open(
                makeScanPDFData(pages: [ScanFixture.lines(page: 0), ScanFixture.lines(page: 1)]))
            defer { document.close(); try? FileManager.default.removeItem(at: folder) }
            let page = try #require(pdf.page(at: 0) as? ReaderPage)
            let next = try #require(pdf.page(at: 1) as? ReaderPage)
            try #require(ScanFixture.reproduces(page),
                         "PDFKit no longer reports the tagged scan as a U+FFFC hit; nothing to fix here")

            let line5 = ScanFixture.range(of: "Line 5 ", on: page).location
            let word = ScanFixture.range(of: "scholars", on: page, after: line5)
            let point = ScanFixture.center(of: word, on: page)
            // The public API funnels into the private method the patch replaces.
            #expect(page.selectionForWord(at: point)?.string == "scholars")
            #expect(page.selectionForLine(at: point)?.string == ScanFixture.lines(page: 0)[5])

            // A drag from page 1 to page 2 through PDFDocument: each page's
            // share is text, and the scans are left out.
            let start = ScanFixture.range(of: "Line 28 ", on: page)
            let end = ScanFixture.range(of: "Line 1 ", on: next)
            let across = try #require(pdf.selection(from: page, at: ScanFixture.leftEdge(of: start, on: page),
                                                    to: next, at: ScanFixture.rightEdge(of: end, on: next)))
            let text = try #require(across.string)
            #expect(!text.contains("\u{FFFC}"))
            #expect(text.hasPrefix("Line 28 of page 1"))
            #expect(text.contains("Line 0 of page 2"))
            #expect(text.hasSuffix("Line 1 "))
        }

        @Test("Scanned text: links use the word under the click, and the scan is never highlighted")
        func linksAndHighlights() throws {
            var lines = ScanFixture.lines()
            lines[3] = "See https://example.com/scholars for the argument."
            let (document, pdf, folder) = try ScanFixture.open(makeScanPDFData(pages: [lines]))
            defer { document.close(); try? FileManager.default.removeItem(at: folder) }
            let page = try #require(pdf.page(at: 0) as? ReaderPage)
            try #require(ScanFixture.reproduces(page))

            let link = ScanFixture.center(of: ScanFixture.range(of: "example", on: page), on: page)
            #expect(page.characterIndex(at: link) == 0)
            let index = page.textCharacterIndex(at: link)
            #expect(TextLinks.url(in: page.string ?? "", at: index)?.absoluteString
                    == "https://example.com/scholars")
            // In the margin, over the scan but off the text: no character.
            #expect(page.textCharacterIndex(at: CGPoint(x: 20, y: 20)) == NSNotFound)

            // Select All carries the scan's U+FFFC; neither a highlight nor the
            // cleaned copy may include it.
            let all = try #require(pdf.selectionForEntireDocument)
            #expect(all.string?.contains("\u{FFFC}") == true)
            #expect(!CopyCleanup.text(for: all).contains("\u{FFFC}"))
            #expect(CopyCleanup.text(for: all).hasPrefix("Line 0 of page 1"))
            let added = document.addHighlight(selection: all, color: .yellow)
            let annotation = try #require(added.first?.annotation)
            #expect(annotation.bounds.height < page.bounds(for: .mediaBox).height - 200)
            #expect(annotation.bounds.minY > 50)
        }

        @Test("A born-digital page is never taken over")
        func bornDigitalNative() throws {
            let (document, pdf, folder) = try ScanFixture.open(
                makeScanPDFData(pages: [ScanFixture.lines()], scan: false))
            defer { document.close(); try? FileManager.default.removeItem(at: folder) }
            let page = try #require(pdf.page(at: 0) as? ReaderPage)
            let a = ScanFixture.center(of: ScanFixture.range(of: "scholars", on: page), on: page)
            let b = ScanFixture.center(of: ScanFixture.range(of: "argue", on: page, after: 300), on: page)
            guard case .native = page.textPreferringSelection(from: a, to: b, granularity: .character) else {
                Issue.record("a born-digital page was taken over")
                return
            }
            #expect(page.textCharacterIndex(at: a) == page.characterIndex(at: a))
            #expect(page.selectionForWord(at: a)?.string == "scholars")
        }
    }
}

// MARK: - Real mouse gestures (XCTest)

/// PDFKit's real mouse handling, driven in-process.
///
/// XCTest rather than Swift Testing on purpose: after PDFKit tracks a drag,
/// the main run loop that Swift Testing's async entry point is parked in
/// returns, and the process exits 0 mid-run with no results (reproduced on
/// macOS 27.2; the cause is inside AppKit/PDFKit). XCTest drives the main
/// thread itself and is unaffected.
@MainActor
final class ScanSelectionGestureTests: XCTestCase {

    /// A borderless window that says it is key, so PDFKit tracks the mouse
    /// without the window ever being activated.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    /// The drag and release are queued, then the press is dispatched, so
    /// PDFKit's own tracking consumes them as it would a person's. Nothing is
    /// activated and the real pointer never moves.
    private final class Harness {
        let window: KeyWindow
        let view: ReaderPDFView
        private var number = 0
        private let restoreFirstMouse: () -> Void

        init(document: PDFDocument, page: PDFPage) {
            window = KeyWindow(contentRect: NSRect(x: -12000, y: -12000, width: 700, height: 1000),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view = ReaderPDFView(frame: window.contentView!.bounds)
            window.contentView!.addSubview(view)
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            view.document = document
            // PDFKit's page view ignores a press in a window that is not key
            // unless it accepts first mouse. Restored on close.
            let cls: AnyClass = NSClassFromString("PDFPageView")!
            let selector = #selector(NSView.acceptsFirstMouse(for:))
            let yes: @convention(block) (AnyObject, NSEvent?) -> ObjCBool = { _, _ in true }
            let previous = class_replaceMethod(cls, selector, imp_implementationWithBlock(yes), "c@:@")
                ?? method_getImplementation(class_getInstanceMethod(NSView.self, selector)!)
            restoreFirstMouse = { class_replaceMethod(cls, selector, previous, "c@:@") }
            window.orderFrontRegardless()
            view.go(to: page)
            view.layoutDocumentView()
            drain(0.6)
        }

        func close() {
            restoreFirstMouse()
            window.orderOut(nil)
            window.close()
        }

        func drain(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02),
                                               inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }

        func point(_ pagePoint: CGPoint, on page: PDFPage) -> CGPoint {
            view.convert(pagePoint, from: page)
        }

        private func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
            number += 1
            return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: number, clickCount: clicks,
                                      pressure: type == .leftMouseUp ? 0 : 1)!
        }

        /// Press at `from`, drag to `to` in a dozen steps, release. View
        /// coordinates.
        func drag(from: CGPoint, to: CGPoint) -> String? {
            view.clearSelection()
            for step in 1...12 {
                let t = CGFloat(step) / 12
                NSApp.postEvent(event(.leftMouseDragged,
                                      CGPoint(x: from.x + (to.x - from.x) * t,
                                              y: from.y + (to.y - from.y) * t)), atStart: false)
            }
            NSApp.postEvent(event(.leftMouseUp, to), atStart: false)
            NSApp.sendEvent(event(.leftMouseDown, from))
            drain(0.4)
            return view.currentSelection?.string
        }

        /// A single, double or triple click, built up click by click as a
        /// person's is.
        func click(_ point: CGPoint, count: Int) -> String? {
            view.clearSelection()
            for clicks in 1...count {
                NSApp.postEvent(event(.leftMouseUp, point, clicks: clicks), atStart: false)
                NSApp.sendEvent(event(.leftMouseDown, point, clicks: clicks))
                drain(0.2)
            }
            return view.currentSelection?.string
        }
    }

    func testDragDoubleAndTripleClickSelectTextOverAScan() throws {
        let lines = ScanFixture.lines()
        let (document, pdf, folder) = try ScanFixture.open(makeScanPDFData(pages: [lines]))
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let page = try XCTUnwrap(pdf.page(at: 0) as? ReaderPage)
        try XCTSkipUnless(ScanFixture.reproduces(page),
                          "PDFKit no longer reports the tagged scan as a U+FFFC hit; nothing to fix here")
        let harness = Harness(document: pdf, page: page)
        defer { harness.close() }
        let text = try XCTUnwrap(page.string) as NSString

        // From just inside the start of "page" on line 5 to just inside the
        // end of "argue" on line 7: exactly the text between.
        let line5 = ScanFixture.range(of: "Line 5 ", on: page).location
        let line7 = ScanFixture.range(of: "Line 7 ", on: page).location
        let start = ScanFixture.range(of: "page", on: page, after: line5)
        let end = ScanFixture.range(of: "argue", on: page, after: line7)
        let dragged = try XCTUnwrap(harness.drag(
            from: harness.point(ScanFixture.leftEdge(of: start, on: page), on: page),
            to: harness.point(ScanFixture.rightEdge(of: end, on: page), on: page)))
        XCTAssertFalse(dragged.contains("\u{FFFC}"))
        XCTAssertEqual(dragged, text.substring(with: NSRange(location: start.location,
                                                             length: NSMaxRange(end) - start.location)))
        XCTAssertTrue(dragged.hasPrefix("page 1, where scholars argue the point.\nLine 6 "))

        let word = harness.point(ScanFixture.center(of: ScanFixture.range(of: "scholars", on: page, after: line5),
                                                    on: page), on: page)
        XCTAssertEqual(harness.click(word, count: 2), "scholars")
        XCTAssertEqual(harness.click(word, count: 3), lines[5])
        // A plain click still clears the selection.
        XCTAssertNil(harness.click(word, count: 1))
    }

    func testBornDigitalPageStillSelectsNatively() throws {
        let (document, pdf, folder) = try ScanFixture.open(
            makeScanPDFData(pages: [ScanFixture.lines()], scan: false))
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let page = try XCTUnwrap(pdf.page(at: 0) as? ReaderPage)
        let harness = Harness(document: pdf, page: page)
        defer { harness.close() }

        let line5 = ScanFixture.range(of: "Line 5 ", on: page).location
        let start = ScanFixture.range(of: "page", on: page, after: line5)
        let end = ScanFixture.range(of: "argue", on: page, after: line5 + 70)
        let dragged = try XCTUnwrap(harness.drag(
            from: harness.point(ScanFixture.leftEdge(of: start, on: page), on: page),
            to: harness.point(ScanFixture.rightEdge(of: end, on: page), on: page)))
        XCTAssertTrue(dragged.contains("where scholars argue the point."), dragged)
        XCTAssertTrue(dragged.contains("Line 6 of page 1"), dragged)
        let word = harness.point(ScanFixture.center(of: ScanFixture.range(of: "scholars", on: page, after: line5),
                                                    on: page), on: page)
        XCTAssertEqual(harness.click(word, count: 2), "scholars")
    }

    /// The same gestures against a real file, for checking real scans:
    /// GLASSINE_SCAN_PDF=/path GLASSINE_SCAN_PAGE=50 swift test --filter ScanSelectionGestureTests
    /// A page that is not a scan is checked for being left to PDFKit instead.
    /// Prints what each gesture selected.
    func testRealFileFromEnvironment() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["GLASSINE_SCAN_PDF"] else {
            throw XCTSkip("set GLASSINE_SCAN_PDF (and GLASSINE_SCAN_PAGE) to run against a real file")
        }
        let index = Int(environment["GLASSINE_SCAN_PAGE"] ?? "0") ?? 0
        let (document, pdf, folder) = try ScanFixture.open(try Data(contentsOf: URL(fileURLWithPath: path)))
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let page = try XCTUnwrap(pdf.page(at: index) as? ReaderPage)
        let harness = Harness(document: pdf, page: page)
        defer { harness.close() }

        // Body characters at a given fraction of the page's text.
        func characterPoint(_ fraction: Double, on page: PDFPage) -> CGPoint {
            let text = (page.string ?? "") as NSString
            var k = Int(Double(text.length) * fraction)
            var r = CGRect.zero
            while k < text.length - 1 {
                let unit = text.character(at: k)
                r = ScanFixture.box(k, on: page)
                if r.width > 1, r.height > 1, unit != 0x20, unit != 0x0A, unit != 0xFFFC { break }
                k += 1
            }
            return CGPoint(x: r.midX, y: r.midY)
        }
        let a = characterPoint(0.30, on: page), b = characterPoint(0.36, on: page)
        let takenOver: Bool
        if case .native = page.textPreferringSelection(from: a, to: b, granularity: .character) {
            takenOver = false
        } else {
            takenOver = true
        }
        let dragged = harness.drag(from: harness.point(a, on: page), to: harness.point(b, on: page)) ?? ""
        let double = harness.click(harness.point(a, on: page), count: 2) ?? ""
        let triple = harness.click(harness.point(a, on: page), count: 3) ?? ""
        print("SCAN page index \(index): taken over \(takenOver)")
        print("SCAN drag (\(dragged.count) chars): \(dragged.debugDescription)")
        print("SCAN double-click: \(double.debugDescription)")
        print("SCAN triple-click: \(triple.debugDescription)")
        for selected in [dragged, double, triple] {
            XCTAssertFalse(selected.isEmpty)
            XCTAssertFalse(selected.contains("\u{FFFC}"))
        }
        XCTAssertGreaterThan(dragged.count, 20)
        XCTAssertFalse(double.contains(" "))

        // Across a page turn in the continuous view: zoom out so the middle of
        // this page and of the next are both in the window.
        if index + 1 < pdf.pageCount, let next = pdf.page(at: index + 1) {
            harness.view.autoScales = false
            harness.view.scaleFactor = 0.6
            harness.view.go(to: page)
            harness.view.layoutDocumentView()
            harness.drain(0.3)
            let from = harness.point(characterPoint(0.5, on: page), on: page)
            let to = harness.point(characterPoint(0.5, on: next), on: next)
            XCTAssertTrue(harness.view.bounds.contains(from) && harness.view.bounds.contains(to),
                          "both ends of the cross-page drag must be on screen: \(from) \(to)")
            let across = harness.drag(from: from, to: to) ?? ""
            print("SCAN across pages (\(across.count) chars), contains U+FFFC: \(across.contains("\u{FFFC}"))")
            print("SCAN across head: \(String(across.prefix(120)).debugDescription)")
            print("SCAN across tail: \(String(across.suffix(120)).debugDescription)")
            XCTAssertFalse(across.isEmpty)
            if let selection = harness.view.currentSelection {
                let cleaned = CopyCleanup.text(for: selection)
                print("SCAN across, cleaned copy has U+FFFC: \(cleaned.contains("\u{FFFC}"))")
            }
        }

        let all = try XCTUnwrap(pdf.selectionForEntireDocument)
        let cleaned = CopyCleanup.text(for: all)
        print("SCAN select all: raw has U+FFFC \(all.string?.contains("\u{FFFC}") == true); cleaned copy \(cleaned.count) chars, has U+FFFC \(cleaned.contains("\u{FFFC}"))")
        XCTAssertFalse(cleaned.contains("\u{FFFC}"))
    }
}
