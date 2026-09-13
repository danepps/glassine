import Foundation
import Testing
@testable import GlassineCore

@Suite("Highlight Markdown export")
struct HighlightMarkdownTests {
    @Test("Exports quotes and notes by page, with distinct printed and physical page numbers")
    func pageGroups() {
        let source = URL(fileURLWithPath: "/Papers/Reading.pdf")
        let excerpts = [
            HighlightExcerpt(text: "First passage.", note: "Compare the later holding.", pageIndex: 0, pageLabel: "1", color: "Yellow"),
            HighlightExcerpt(text: "Second passage.", note: "", pageIndex: 0, pageLabel: "1", color: "Blue"),
            HighlightExcerpt(text: "Preface.", note: "Two lines.\n\nAnother paragraph.", pageIndex: 3, pageLabel: "iv", color: "Green")
        ]
        let expected = """
        # Highlights — Reading

        Source: [Reading.pdf](<file:///Papers/Reading.pdf>)

        3 highlights, 2 notes.

        ## Page 1

        > First passage.

        **Note:** Compare the later holding.

        Yellow · [Page 1](<file:///Papers/Reading.pdf#page=1>)

        ---

        > Second passage.

        Blue · [Page 1](<file:///Papers/Reading.pdf#page=1>)

        ---

        ## Page iv · PDF 4

        > Preface.

        **Note:** Two lines.

        Another paragraph.

        Green · [Page iv · PDF 4](<file:///Papers/Reading.pdf#page=4>)

        ---
        """ + "\n"
        #expect(HighlightMarkdown.render(excerpts, title: "Reading", sourceURL: source) == expected)
    }

    @Test("Literal Markdown and HTML in PDFs and notes stay literal")
    func escaping() {
        let source = URL(fileURLWithPath: "/Papers/A [draft] #1.pdf")
        let excerpts = [HighlightExcerpt(text: "A *quote* [link](https://example.com) <b>bold</b>",
            note: "# Heading\r\n1. item\r\n- item\n`code`", pageIndex: 1, pageLabel: "2", color: "Pink")]
        let markdown = HighlightMarkdown.render(excerpts, title: "A [draft]", sourceURL: source)
        #expect(markdown.contains(#"A \*quote\* \[link\](https://example.com) \<b\>bold\</b\>"#))
        #expect(markdown.contains("**Note:** \\# Heading\n1\\. item\n\\- item\n\\`code\\`"))
        #expect(markdown.contains("(<" + source.absoluteString + "#page=2>)"))
        #expect(!markdown.contains("\r"))
    }

    @Test("Image-only highlights export notes without inventing quoted text")
    func noTextOrSource() {
        let markdown = HighlightMarkdown.render([
            HighlightExcerpt(text: "", note: "A comment, not a quote.", pageIndex: 0, pageLabel: "", color: "Custom color")
        ], title: "Untitled", sourceURL: nil)
        #expect(markdown.contains("1 highlight, 1 note."))
        #expect(markdown.contains("*No extractable text.*"))
        #expect(markdown.contains("**Note:** A comment, not a quote."))
        #expect(!markdown.contains("> A comment"))
        #expect(!markdown.contains("file:"))
        #expect(markdown.contains("Custom color · Page 1"))
    }
}
