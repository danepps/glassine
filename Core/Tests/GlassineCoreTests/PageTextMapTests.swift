import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import GlassineCore

/// Lays text down with known geometry: every character `advance` wide, each
/// line's glyph boxes `glyphHeight` tall from its baseline `y`. A page image
/// (U+FFFC) can be put anywhere in the text with its own rectangle.
private struct Layout {
    var text = ""
    var boxes: [CGRect] = []
    var advance: CGFloat = 6
    var glyphHeight: CGFloat = 10

    /// Starts a new line (a newline first, unless at the start or right
    /// after a graphic) and returns the UTF-16 index of its first character.
    @discardableResult
    mutating func line(_ string: String, x: CGFloat, y: CGFloat) -> Int {
        if !text.isEmpty, text.last != "\u{FFFC}" {
            text += "\n"
            boxes.append(.zero)
        }
        let start = boxes.count
        for (offset, character) in string.utf16.enumerated() {
            _ = character
            boxes.append(CGRect(x: x + CGFloat(offset) * advance, y: y, width: advance, height: glyphHeight))
        }
        text += string
        return start
    }

    mutating func graphic(_ rect: CGRect) {
        if !text.isEmpty {
            text += "\n"
            boxes.append(.zero)
        }
        text += "\u{FFFC}"
        boxes.append(rect)
    }

    var map: PageTextMap {
        let boxes = boxes
        return PageTextMap(text: text) { boxes[$0] }
    }

    /// The middle of character `index`, nudged left or right of its centre.
    func point(_ index: Int, right: Bool = false) -> CGPoint {
        let r = boxes[index]
        return CGPoint(x: right ? r.maxX - 1 : r.minX + 1, y: r.midY)
    }

    func string(_ range: NSRange?) -> String? {
        range.map { (text as NSString).substring(with: $0) }
    }
}

@Suite("PageTextMap")
struct PageTextMapTests {

    /// Three lines down one column, 14 pt apart, under a page-sized scan.
    private func column() -> (Layout, [Int]) {
        var layout = Layout()
        layout.graphic(CGRect(x: 0, y: 0, width: 612, height: 792))
        let starts = [
            layout.line("First line of text.", x: 72, y: 700),
            layout.line("Here scholars, argue it.", x: 72, y: 686),
            layout.line("Third line ends here.", x: 72, y: 672)
        ]
        return (layout, starts)
    }

    @Test("Caret: left half before the character, right half after it")
    func caretInsideLine() {
        let (layout, starts) = column()
        let map = layout.map
        let third = starts[1] + 2
        #expect(map.caret(at: layout.point(third)) == third)
        #expect(map.caret(at: layout.point(third, right: true)) == third + 1)
    }

    @Test("Caret: past the end of a line, before its start")
    func caretOutsideLine() {
        let (layout, starts) = column()
        let map = layout.map
        let end = starts[1] + "Here scholars, argue it.".utf16.count
        #expect(map.caret(at: CGPoint(x: 500, y: 690)) == end)
        #expect(map.caret(at: CGPoint(x: 10, y: 690)) == starts[1])
    }

    @Test("Caret: a point in the leading goes to the nearer line")
    func caretBetweenLines() {
        let (layout, starts) = column()
        let map = layout.map
        // Line 1 spans y 700...710, line 2 686...696.
        #expect(map.caret(at: CGPoint(x: 73, y: 698.5)) == starts[0])
        #expect(map.caret(at: CGPoint(x: 73, y: 697.5)) == starts[1])
    }

    @Test("Caret: OCR glyph boxes shorter than the printed line still claim the click")
    func shortGlyphBoxes() {
        var layout = Layout()
        layout.glyphHeight = 3
        layout.graphic(CGRect(x: 0, y: 0, width: 612, height: 792))
        let upper = layout.line("upper words", x: 72, y: 714)
        let lower = layout.line("lower words", x: 72, y: 700)
        let map = layout.map
        // On the visible x-height of the lower line, well above its boxes.
        #expect(map.caret(at: CGPoint(x: 73, y: 706)) == lower)
        #expect(map.caret(at: CGPoint(x: 73, y: 712)) == upper)
        // But a strict hit needs the box itself.
        #expect(map.strictCharacterIndex(at: CGPoint(x: 73, y: 706)) == nil)
        #expect(map.strictCharacterIndex(at: CGPoint(x: 73, y: 701)) == lower)
    }

    @Test("Two columns: the leading between two lines beats the line level with it across the gutter")
    func twoColumns() {
        var layout = Layout()
        layout.graphic(CGRect(x: 0, y: 0, width: 612, height: 792))
        // Left column x 72...252, right column x 300...480, lines at 700 and 686.
        let leftTop = layout.line("left column top line text.", x: 72, y: 700)
        let leftNext = layout.line("left column next line text", x: 72, y: 686)
        let rightTop = layout.line("right column top line text", x: 300, y: 703)
        _ = layout.line("right column next line txt", x: 300, y: 689)
        let map = layout.map
        // Just right of the left column's end, in its leading (y 697), where the
        // right column has a line (703...713) only 3 pt above: still the left.
        let caret = map.caret(at: CGPoint(x: 240, y: 697.5))
        let leftTopEnd = leftTop + 26, leftNextEnd = leftNext + 26
        #expect(caret.map { (leftTop...leftTopEnd).contains($0) || (leftNext...leftNextEnd).contains($0) } == true)
        // Inside the right column it is the right column.
        #expect(map.caret(at: layout.point(rightTop + 3)) == rightTop + 3)
    }

    @Test("Character drag: the text between the carets, nil when they meet")
    func characterRange() {
        let (layout, starts) = column()
        let map = layout.map
        let from = layout.point(starts[0] + 6)                // "line ..."
        let to = layout.point(starts[1] + 3, right: true)     // "...Here"
        #expect(layout.string(map.range(from: from, to: to, granularity: .character))
                == "line of text.\nHere")
        // Backwards gives the same.
        #expect(layout.string(map.range(from: to, to: from, granularity: .character))
                == "line of text.\nHere")
        #expect(map.range(from: from, to: from, granularity: .character) == nil)
    }

    @Test("Word: the word under the point; punctuation alone; a span of words")
    func wordRange() {
        let (layout, starts) = column()
        let map = layout.map
        let scholars = starts[1] + 5
        let point = layout.point(scholars + 3)
        #expect(layout.string(map.range(from: point, to: point, granularity: .word)) == "scholars")
        let comma = layout.point(scholars + 8)
        #expect(layout.string(map.range(from: comma, to: comma, granularity: .word)) == ",")
        let argue = layout.point(scholars + 11)
        #expect(layout.string(map.range(from: point, to: argue, granularity: .word)) == "scholars, argue")
    }

    @Test("Line: whole lines between the two points, without the final newline")
    func lineRange() {
        let (layout, starts) = column()
        let map = layout.map
        let one = layout.point(starts[1] + 4)
        #expect(layout.string(map.range(from: one, to: one, granularity: .line))
                == "Here scholars, argue it.")
        let three = layout.point(starts[2] + 1)
        #expect(layout.string(map.range(from: three, to: one, granularity: .line))
                == "Here scholars, argue it.\nThird line ends here.")
    }

    @Test("Edges: to the end of the page and from its start, never including the scan")
    func edges() {
        let (layout, starts) = column()
        let map = layout.map
        let point = layout.point(starts[1] + 5)
        #expect(layout.string(map.rangeToEnd(from: point, granularity: .character))
                == "scholars, argue it.\nThird line ends here.")
        #expect(layout.string(map.rangeFromStart(to: point, granularity: .word))
                == "First line of text.\nHere scholars")
        #expect(layout.string(map.rangeToEnd(from: point, granularity: .line))
                == "Here scholars, argue it.\nThird line ends here.")
    }

    @Test("A scan with text on it is text-bearing; a figure in the margin is not")
    func textBearing() {
        var layout = Layout()
        layout.graphic(CGRect(x: 0, y: 0, width: 612, height: 792))
        layout.line("Body text on the scan.", x: 72, y: 700)
        layout.graphic(CGRect(x: 400, y: 100, width: 100, height: 100))
        layout.line("Caption.", x: 400, y: 80)
        let map = layout.map
        #expect(map.graphics.map(\.isTextBearing) == [true, false])
        #expect(map.isTextBearingGraphic(at: 0))
        let figure = map.graphics[1].index
        #expect(!map.isTextBearingGraphic(at: figure))
        #expect(map.textBearingGraphicContains(CGPoint(x: 300, y: 300)))
        // The figure lies on the scan too, so the scan answers there.
        #expect(map.textBearingGraphicContains(CGPoint(x: 450, y: 150)))
    }

    @Test("A graphic without text over it is not text-bearing, and nothing claims a point")
    func bareGraphic() {
        var layout = Layout()
        layout.graphic(CGRect(x: 0, y: 400, width: 612, height: 392))
        layout.line("Text below the picture.", x: 72, y: 300)
        let map = layout.map
        #expect(map.graphics.count == 1)
        #expect(map.graphics[0].isTextBearing == false)
        #expect(!map.textBearingGraphicContains(CGPoint(x: 300, y: 600)))
    }

    @Test("Removing text-bearing graphics splits a range around them")
    func removingGraphics() {
        var layout = Layout()
        layout.line("before", x: 72, y: 700)
        layout.graphic(CGRect(x: 0, y: 0, width: 612, height: 792))
        layout.line("after the scan", x: 72, y: 600)
        let map = layout.map
        let whole = NSRange(location: 0, length: (layout.text as NSString).length)
        let parts = map.removingTextBearingGraphics(from: whole)
        #expect(parts.map { layout.string($0) } == ["before\n", "after the scan"])
        #expect(map.removingTextBearingGraphics(from: NSRange(location: 0, length: 3))
                == [NSRange(location: 0, length: 3)])
    }

    @Test("Strict index: inside a character only")
    func strictIndex() {
        let (layout, starts) = column()
        let map = layout.map
        #expect(map.strictCharacterIndex(at: layout.point(starts[2] + 4)) == starts[2] + 4)
        #expect(map.strictCharacterIndex(at: CGPoint(x: 30, y: 705)) == nil)   // margin
        #expect(map.strictCharacterIndex(at: CGPoint(x: 80, y: 698)) == nil)   // leading
    }

    @Test("Empty boxes stay in the text but not in the geometry; no text means no caret")
    func emptyBoxes() {
        var layout = Layout()
        layout.graphic(CGRect(x: 0, y: 0, width: 612, height: 792))
        let start = layout.line("a b", x: 72, y: 700)
        layout.boxes[start + 1] = .zero      // the space has no box
        let map = layout.map
        #expect(map.caret(at: layout.point(start + 2)) == start + 2)
        #expect(layout.string(map.range(from: layout.point(start), to: layout.point(start + 2, right: true),
                                         granularity: .character)) == "a b")
        #expect(PageTextMap(text: "\u{FFFC}") { _ in CGRect(x: 0, y: 0, width: 10, height: 10) }
            .caret(at: .zero) == nil)
    }

    @Test("Graphic-only text")
    func graphicOnly() {
        #expect(PageTextMap.isGraphicOnly("\u{FFFC}"))
        #expect(PageTextMap.isGraphicOnly(" \u{FFFC}\n"))
        #expect(!PageTextMap.isGraphicOnly("\u{FFFC}text"))
        #expect(!PageTextMap.isGraphicOnly(""))
        #expect(!PageTextMap.isGraphicOnly("  "))
    }
}

// MARK: - Real PDFKit pages

private final class ScanPageDelegate: NSObject, PDFDocumentDelegate {
    func classForPage() -> AnyClass { ReaderPage.self }
}

/// A synthetic scan run through PDFKit itself. Skipped, not failed, on a
/// system whose PDFKit does not turn the tagged image into a U+FFFC that
/// swallows hit-testing: there is then nothing for the fix to do.
@Suite("ReaderPage on a scanned page") @MainActor
struct ScanPageTests {
    static let lines = (0..<20).map { "Line \($0) where scholars argue the point." }

    private static func document(_ delegate: ScanPageDelegate) -> PDFDocument? {
        let pdf = PDFDocument(data: makeScanPDFData(pages: [lines, lines]))
        pdf?.delegate = delegate
        return pdf
    }

    /// The bug as found on JSTOR pages, reproduced by the fixture.
    static let reproduces: Bool = {
        let delegate = ScanPageDelegate()
        guard let page = document(delegate)?.page(at: 0), let text = page.string as NSString?,
              text.length > 0, text.character(at: 0) == 0xFFFC else { return false }
        let middle = page.selection(for: NSRange(location: text.length / 2, length: 1))?.bounds(for: page) ?? .zero
        return page.characterIndex(at: CGPoint(x: middle.midX, y: middle.midY)) == 0
    }()

    private func setUp() throws -> (ScanPageDelegate, PDFDocument, ReaderPage, NSString) {
        let delegate = ScanPageDelegate()
        let pdf = try #require(Self.document(delegate))
        let page = try #require(pdf.page(at: 0) as? ReaderPage)
        return (delegate, pdf, page, try #require(page.string) as NSString)
    }

    private func center(_ range: NSRange, on page: PDFPage) -> CGPoint {
        let r = page.selection(for: range)?.bounds(for: page) ?? .zero
        return CGPoint(x: r.midX, y: r.midY)
    }

    private func string(_ answer: ReaderPage.TextSelectionOverride) -> String?? {
        if case .text(let selection) = answer { return .some(selection?.string) }
        return .none
    }

    @Test("The scan is one text-bearing graphic, and PDFKit's own hit lands on it",
          .enabled(if: ScanPageTests.reproduces))
    func graphic() throws {
        let (_, _, page, _) = try setUp()
        #expect(page.textMap.graphics.count == 1)
        #expect(page.textMap.graphics.first?.isTextBearing == true)
        // (Not `selectionForWord(at:)`: headless, PDFKit's own word lookup
        // crashes in its data-detector scan on this page.)
        #expect(page.characterIndex(at: CGPoint(x: 100, y: 700)) == 0)
    }

    @Test("Word, line and character selection from the page's own geometry",
          .enabled(if: ScanPageTests.reproduces))
    func selections() throws {
        let (_, _, page, text) = try setUp()
        let line3 = text.range(of: "Line 3 ").location
        let scholars = text.range(of: "scholars", range: NSRange(location: line3, length: 40))
        let point = center(scholars, on: page)
        #expect(string(page.textPreferringSelection(from: point, to: point, granularity: .word)) == "scholars")
        #expect(string(page.textPreferringSelection(from: point, to: point, granularity: .line))
                == .some(Self.lines[3]))
        let argue = text.range(of: "argue", range: NSRange(location: line3 + 50, length: 50))
        let from = page.selection(for: NSRange(location: scholars.location, length: 1))!.bounds(for: page)
        let to = page.selection(for: NSRange(location: NSMaxRange(argue) - 1, length: 1))!.bounds(for: page)
        let dragged = string(page.textPreferringSelection(from: CGPoint(x: from.minX + 1, y: from.midY),
                                                          to: CGPoint(x: to.maxX - 1, y: to.midY),
                                                          granularity: .character))
        #expect(dragged == .some("scholars argue the point.\nLine 4 where scholars argue"))
    }

    @Test("Edge selections for a drag across pages leave the scan out",
          .enabled(if: ScanPageTests.reproduces))
    func edges() throws {
        let (_, _, page, text) = try setUp()
        let line18 = text.range(of: "Line 18 ")
        let point = center(NSRange(location: line18.location, length: 4), on: page)
        let toBottom = try #require(string(page.textPreferringSelection(fromPointToBottom: point,
                                                                         granularity: .word)) ?? nil)
        #expect(toBottom == "Line 18 where scholars argue the point.\nLine 19 where scholars argue the point.")
        let fromTop = try #require(string(page.textPreferringSelection(fromTopToPoint: point,
                                                                        granularity: .line)) ?? nil)
        #expect(fromTop.hasPrefix("Line 0 where"))
        #expect(fromTop.hasSuffix("Line 18 where scholars argue the point."))
        #expect(!fromTop.contains("\u{FFFC}"))
    }

    @Test("Character index under a point: the text's, not the scan's",
          .enabled(if: ScanPageTests.reproduces))
    func characterIndex() throws {
        let (_, _, page, text) = try setUp()
        let line2 = text.range(of: "Line 2 ").location
        let scholars = text.range(of: "scholars", range: NSRange(location: line2, length: 40))
        let r = page.selection(for: NSRange(location: scholars.location + 2, length: 1))!.bounds(for: page)
        let point = CGPoint(x: r.midX, y: r.midY)
        #expect(page.characterIndex(at: point) == 0)
        #expect(page.textCharacterIndex(at: point) == scholars.location + 2)
        #expect(page.textCharacterIndex(at: CGPoint(x: 10, y: 10)) == NSNotFound)
    }

    @Test("An ordinary page is answered by PDFKit, and builds no map")
    func ordinaryPage() throws {
        let delegate = ScanPageDelegate()
        let pdf = makeTextPDF(pages: ["An ordinary page where scholars argue the point."])
        pdf.delegate = delegate
        let page = try #require(pdf.page(at: 0) as? ReaderPage)
        let text = try #require(page.string) as NSString
        let point = center(text.range(of: "scholars"), on: page)
        guard case .native = page.textPreferringSelection(from: point, to: point, granularity: .word) else {
            Issue.record("an ordinary page was taken over")
            return
        }
        #expect(page.textCharacterIndex(at: point) == page.characterIndex(at: point))
    }
}
