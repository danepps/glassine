import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import GlassineCore

/// Lays synthetic lines down a column the way a typesetter would: 72 pt left
/// margin, 300 pt right margin, 12 pt type on 14 pt leading, top line at y 720,
/// each line below the last (PDFKit's y grows *upward*, so "down" subtracts).
private final class ColumnLayout {
    let left: CGFloat
    let right: CGFloat
    let lineHeight: CGFloat
    let leading: CGFloat
    private var y: CGFloat
    private(set) var lines: [CopyCleanup.Line] = []

    init(left: CGFloat = 72, right: CGFloat = 300, lineHeight: CGFloat = 12,
         leading: CGFloat = 14, top: CGFloat = 720) {
        self.left = left
        self.right = right
        self.lineHeight = lineHeight
        self.leading = leading
        self.y = top
    }

    /// One line. `indent` moves its left edge in, `width` shortens it (the
    /// default runs to the right margin), `gap` adds leading above it, and
    /// `page` starts a new page -- which resets the vertical position.
    @discardableResult
    func add(_ text: String, indent: CGFloat = 0, width: CGFloat? = nil,
             gap: CGFloat = 0, page: Int = 0, top: CGFloat? = nil) -> ColumnLayout {
        if let top { y = top }
        y -= leading + gap
        let x = left + indent
        lines.append(CopyCleanup.Line(
            text: text,
            bounds: CGRect(x: x, y: y, width: width ?? (right - x), height: lineHeight),
            page: page))
        return self
    }

    /// A second piece of the line just added, on the same baseline and starting
    /// `gap` beyond where it ended -- what PDFKit reports when the font changes
    /// mid-line (a footnote marker, a small-caps name).
    @discardableResult
    func fragment(_ text: String, gap: CGFloat = 0, width: CGFloat = 40) -> ColumnLayout {
        guard let last = lines.last else { return self }
        lines.append(CopyCleanup.Line(
            text: text,
            bounds: CGRect(x: last.bounds.maxX + gap, y: last.bounds.minY,
                           width: width, height: lineHeight),
            page: last.page))
        return self
    }

    /// A blank line, which is a paragraph break stated outright.
    @discardableResult
    func blank() -> ColumnLayout {
        y -= leading
        lines.append(CopyCleanup.Line(text: "", bounds: .zero, page: 0))
        return self
    }
}

/// A dictionary that knows exactly these words, for the hyphen decisions.
private func dictionary(_ words: String...) -> (String) -> Bool {
    let known = Set(words.map { $0.lowercased() })
    return { known.contains($0.lowercased()) }
}

@Suite("CopyCleanup")
struct CopyCleanupTests {

    // MARK: Joining

    @Test("Lines of one paragraph join with single spaces")
    func joinsAParagraph() {
        let layout = ColumnLayout()
        layout.add("The Court held that the")
        layout.add("statute was invalid on")
        layout.add("its face and could not be")
        #expect(CopyCleanup.text(lines: layout.lines)
                == "The Court held that the statute was invalid on its face and could not be")
    }

    @Test("A syllable break loses its hyphen")
    func dropsASyllableHyphen() {
        let layout = ColumnLayout()
        layout.add("The text of the consti-")
        layout.add("tution says otherwise")
        #expect(CopyCleanup.text(lines: layout.lines)
                == "The text of the constitution says otherwise")
    }

    @Test("A compound word keeps its hyphen when the dictionary knows both halves")
    func keepsACompoundHyphen() {
        let layout = ColumnLayout()
        layout.add("It was a well-")
        layout.add("known rule of law")
        let isWord = dictionary("well", "known", "constitution", "rule", "law", "it", "was", "a")
        #expect(CopyCleanup.text(lines: layout.lines, isWord: isWord)
                == "It was a well-known rule of law")
    }

    @Test("The dictionary closes up a split word it recognises")
    func closesUpAKnownWord() {
        let layout = ColumnLayout()
        layout.add("The text of the consti-")
        layout.add("tution says otherwise")
        let isWord = dictionary("well", "known", "constitution")
        #expect(CopyCleanup.text(lines: layout.lines, isWord: isWord)
                == "The text of the constitution says otherwise")
    }

    @Test("Two fragments the dictionary cannot place close up anyway")
    func closesUpUnknownFragments() {
        let layout = ColumnLayout()
        layout.add("granted certio-")
        layout.add("rari in the case")
        #expect(CopyCleanup.text(lines: layout.lines, isWord: dictionary("case", "the"))
                == "granted certiorari in the case")
    }

    @Test("A capital after the hyphen keeps it")
    func keepsHyphenBeforeACapital() {
        let layout = ColumnLayout()
        layout.add("the opinion in Smith-")
        layout.add("Jones was unanimous")
        #expect(CopyCleanup.text(lines: layout.lines)
                == "the opinion in Smith-Jones was unanimous")
    }

    @Test("A numeric range keeps its hyphen")
    func keepsHyphenInANumberRange() {
        let layout = ColumnLayout()
        layout.add("see pages 18-")
        layout.add("19 of the brief")
        #expect(CopyCleanup.text(lines: layout.lines) == "see pages 18-19 of the brief")
    }

    @Test("A soft hyphen is always a line-break hyphen")
    func dropsASoftHyphen() {
        let layout = ColumnLayout()
        layout.add("the consti\u{00AD}")
        layout.add("tution")
        #expect(CopyCleanup.text(lines: layout.lines) == "the constitution")
    }

    // MARK: Paragraph breaks

    @Test("A first-line indent starts a new paragraph")
    func indentStartsAParagraph() {
        let layout = ColumnLayout()
        layout.add("the last line of the first paragraph")
        layout.add("The second one begins here", indent: 18)
        #expect(CopyCleanup.text(lines: layout.lines)
                == "the last line of the first paragraph\nThe second one begins here")
    }

    @Test("A short line ending a sentence starts a new paragraph")
    func shortTerminalLineStartsAParagraph() {
        let layout = ColumnLayout()
        layout.add("The Court held that the")
        layout.add("statute was invalid.", width: 100)
        layout.add("A second paragraph follows")
        #expect(CopyCleanup.text(lines: layout.lines)
                == "The Court held that the statute was invalid.\nA second paragraph follows")
    }

    @Test("A sentence ending at a full-width line stays inside its paragraph")
    func fullWidthSentenceEndDoesNotBreak() {
        let layout = ColumnLayout()
        layout.add("The Court held that the")
        layout.add("statute was invalid on its face.")
        layout.add("A second sentence follows it")
        #expect(CopyCleanup.text(lines: layout.lines)
                == "The Court held that the statute was invalid on its face."
                + " A second sentence follows it")
    }

    @Test("A line ending in a dash is not the end of a sentence")
    func dashIsNotTerminal() {
        let layout = ColumnLayout()
        layout.add("the rule --", width: 60)
        layout.add("and its exception")
        #expect(CopyCleanup.text(lines: layout.lines) == "the rule -- and its exception")
    }

    @Test("A blank line is a paragraph break")
    func blankLineBreaks() {
        let layout = ColumnLayout()
        layout.add("first paragraph")
        layout.blank()
        layout.add("second paragraph")
        #expect(CopyCleanup.text(lines: layout.lines) == "first paragraph\nsecond paragraph")
    }

    @Test("Extra leading between lines is a paragraph break")
    func extraLeadingBreaks() {
        let layout = ColumnLayout()
        layout.add("first paragraph")
        layout.add("second paragraph", gap: 14)
        #expect(CopyCleanup.text(lines: layout.lines) == "first paragraph\nsecond paragraph")
    }

    @Test("Every line of a block quote is indented, so none of them breaks")
    func blockQuoteJoins() {
        let layout = ColumnLayout()
        layout.add("the Court explained itself")
        layout.add("A statute that reaches", indent: 18)
        layout.add("this far is invalid on", indent: 18)
        layout.add("its face and always was", indent: 18)
        #expect(CopyCleanup.text(lines: layout.lines)
                == "the Court explained itself\n"
                + "A statute that reaches this far is invalid on its face and always was")
    }

    @Test("A centred heading is a paragraph of its own")
    func centredHeadingBreaksBothSides() {
        let layout = ColumnLayout()
        layout.add("the end of the previous section")
        layout.add("II. The Rule", indent: 90, width: 60)
        layout.add("The next section begins here")
        #expect(CopyCleanup.text(lines: layout.lines)
                == "the end of the previous section\nII. The Rule\nThe next section begins here")
    }

    @Test("A list marker starts an item")
    func listMarkerBreaks() {
        let layout = ColumnLayout()
        layout.add("the statute lists three things")
        layout.add("1. the first of them")
        layout.add("that runs on to a second line")
        layout.add("2. the second of them")
        layout.add("(a) with a lettered clause")
        layout.add("• and a bulleted one")
        #expect(CopyCleanup.text(lines: layout.lines)
                == """
                the statute lists three things
                1. the first of them that runs on to a second line
                2. the second of them
                (a) with a lettered clause
                • and a bulleted one
                """)
    }

    @Test("A wrapped case name is not a roman-numeral list item")
    func caseNameIsNotAListMarker() {
        let layout = ColumnLayout()
        layout.add("as the Court held in Brown")
        layout.add("v. Board of Education")
        #expect(CopyCleanup.text(lines: layout.lines)
                == "as the Court held in Brown v. Board of Education")
    }

    // MARK: Pieces of one printed line

    @Test("A footnote marker cut off the end of a line is not a new paragraph")
    func superscriptFragmentRejoinsItsLine() {
        let layout = ColumnLayout()
        layout.add("the Court decided otherwise")
        layout.add("in that Term,", width: 90)
        layout.fragment("29 and said so", width: 138)
        layout.add("in the opinion that followed")
        #expect(CopyCleanup.text(lines: layout.lines)
                == "the Court decided otherwise in that Term,29 and said so"
                + " in the opinion that followed")
    }

    @Test("A gap between two pieces of one line is a space")
    func spacedFragmentKeepsItsSpace() {
        let layout = ColumnLayout()
        layout.add("28", width: 8)
        layout.fragment("MICHAEL J. KLARMAN, FROM JIM CROW", gap: 4, width: 200)
        #expect(CopyCleanup.text(lines: layout.lines)
                == "28 MICHAEL J. KLARMAN, FROM JIM CROW")
    }

    @Test("A hyphen inside one printed line is not a line-end hyphen")
    func fragmentHyphenIsLeftAlone() {
        let layout = ColumnLayout()
        layout.add("the Lochner-", width: 70)
        layout.fragment("era cases", width: 60)
        #expect(CopyCleanup.text(lines: layout.lines, isWord: dictionary("era", "the"))
                == "the Lochner-era cases")
    }

    // MARK: Columns and pages

    @Test("Two columns on a page are separate columns, joined in reading order")
    func twoColumnsJoinInOrder() {
        let left = ColumnLayout(left: 72, right: 290, top: 720)
        left.add("the paragraph begins in")
        left.add("the left column and runs")
        let right = ColumnLayout(left: 320, right: 540, top: 720)
        right.add("on into the right column")
        right.add("where it finishes")
        #expect(CopyCleanup.text(lines: left.lines + right.lines)
                == "the paragraph begins in the left column and runs"
                + " on into the right column where it finishes")
    }

    @Test("A short line is measured against its own column's right margin")
    func shortnessUsesTheOwnColumnMargin() {
        let left = ColumnLayout(left: 72, right: 290, top: 720)
        left.add("the paragraph begins in")
        left.add("the left column.", width: 80)
        let right = ColumnLayout(left: 320, right: 540, top: 720)
        right.add("A new paragraph opens the")
        right.add("right column")
        #expect(CopyCleanup.text(lines: left.lines + right.lines)
                == "the paragraph begins in the left column."
                + "\nA new paragraph opens the right column")
    }

    @Test("A running head across the page does not merge the columns beneath it")
    func runningHeadDoesNotMergeColumns() {
        func line(_ text: String, _ x: CGFloat, _ width: CGFloat,
                  _ y: CGFloat) -> CopyCleanup.Line {
            CopyCleanup.Line(text: text,
                             bounds: CGRect(x: x, y: y, width: width, height: 12),
                             page: 0)
        }
        // A page number and a title sharing the running head's baseline, then
        // two columns of one paragraph. Nothing may take the head's left edge
        // for the right column's margin, or its right edge for the left's.
        var lines = [line("18", 72, 12, 730),
                     line("THE JOURNAL OF THINGS", 300, 230, 730)]
        for (index, text) in ["the paragraph begins in", "the left column and runs",
                              "past the foot of it, where"].enumerated() {
            lines.append(line(text, 72, 218, 700 - CGFloat(index) * 14))
        }
        for (index, text) in ["it carries on into the right",
                              "column and finishes"].enumerated() {
            lines.append(line(text, 320, 220, 700 - CGFloat(index) * 14))
        }
        #expect(CopyCleanup.text(lines: lines)
                == "18 THE JOURNAL OF THINGS\n"
                + "the paragraph begins in the left column and runs past the foot of it,"
                + " where it carries on into the right column and finishes")
    }

    @Test("A sentence running across a page break joins")
    func pageBreakJoins() {
        let layout = ColumnLayout()
        layout.add("the sentence begins at the")
        layout.add("foot of one page and", page: 0)
        layout.add("continues at the head of", page: 1, top: 720)
        layout.add("the next one", page: 1)
        #expect(CopyCleanup.text(lines: layout.lines)
                == "the sentence begins at the foot of one page and"
                + " continues at the head of the next one")
    }

    // MARK: Shape of the output

    @Test("The paragraph separator is the caller's to choose")
    func paragraphSeparatorIsHonoured() {
        let layout = ColumnLayout()
        layout.add("first paragraph")
        layout.blank()
        layout.add("second paragraph")
        #expect(CopyCleanup.text(lines: layout.lines, paragraphSeparator: "\n\n")
                == "first paragraph\n\nsecond paragraph")
    }

    @Test("Whitespace inside a line collapses, and empty input stays empty")
    func collapsesWhitespace() {
        let layout = ColumnLayout()
        layout.add("  the   line \t was  padded  ")
        #expect(CopyCleanup.text(lines: layout.lines) == "the line was padded")
        #expect(CopyCleanup.text(lines: []) == "")
        #expect(CopyCleanup.text("") == "")
    }

    // MARK: The text-only fallback

    @Test("The text-only path joins lines and keeps blank-line breaks")
    func textOnlyFallback() {
        let raw = """
        The text of the consti-
        tution says otherwise.
        A sentence ending a line is not a break.

        The second paragraph.
        """
        #expect(CopyCleanup.text(raw)
                == "The text of the constitution says otherwise."
                + " A sentence ending a line is not a break.\nThe second paragraph.")
    }

    @Test("The text-only path applies the same hyphen rules")
    func textOnlyHyphens() {
        let isWord = dictionary("well", "known")
        #expect(CopyCleanup.text("a well-\nknown rule", isWord: isWord) == "a well-known rule")
        #expect(CopyCleanup.text("pages 18-\n19") == "pages 18-19")
        #expect(CopyCleanup.text("certio-\nrari") == "certiorari")
        #expect(CopyCleanup.text("first\n\n\nsecond", paragraphSeparator: "\n\n")
                == "first\n\nsecond")
    }

    // MARK: PDFKit

    /// The convenience over a real `PDFDocument`, drawn here with Core Text so
    /// PDFKit has real glyphs to extract and real line rectangles to report.
    @Test("A PDFKit selection is cleaned up through its own line geometry")
    func pdfSelectionIsCleanedUp() {
        let document = makeTextPDF(pages: ["The text of the consti-\ntution says otherwise."])
        guard let page = document.page(at: 0),
              let selection = page.selection(for: page.bounds(for: .mediaBox))
        else {
            Issue.record("the drawn page yielded no selection")
            return
        }
        let cleaned = CopyCleanup.text(for: selection)
        #expect(cleaned.contains("constitution"))
        #expect(!cleaned.contains("\n"))
        #expect(!cleaned.contains("-"))
    }

    @Test("A selection PDFKit reports no geometry for still gets the text path")
    func selectionWithoutGeometryFallsBack() {
        let lines = [CopyCleanup.Line(text: "the consti-", bounds: .null, page: 0),
                     CopyCleanup.Line(text: "tution", bounds: .null, page: 0)]
        #expect(CopyCleanup.text(lines: lines) == "the constitution")
    }
}
