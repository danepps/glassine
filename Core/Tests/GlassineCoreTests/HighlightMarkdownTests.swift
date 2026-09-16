import Foundation
import Markdown
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

    @Test("Plain-text block markers and indentation cannot create Markdown structure", arguments: [
        "Key point\n---", "Key point\n===", "Key point\n-", "Key point\n--",
        "---", "- - -", "  ---", "\t---", "Key point\n\n    Indented text",
        "Key point\n\n\tIndented text", "Key point\n\n  - item", "Key point\n\n + item",
        "Key point\n\n  1. item", "Key point\n1)\titem", "Key point\n\n    # Heading",
        "Key point\n\n```swift\ncode\n```", "Key point\n\n> nested quote"
    ])
    func literalBlocks(_ text: String) throws {
        let markdown = HighlightMarkdown.render([
            HighlightExcerpt(text: text, note: text, pageIndex: 0, pageLabel: "1", color: "Yellow")
        ], title: "Reading", sourceURL: nil)
        let document = Markdown.Document(parsing: markdown)
        let all = nodes(document)
        #expect(all.compactMap { $0 as? Heading }.map(\.level) == [1, 2])
        #expect(all.filter { $0 is ThematicBreak }.count == 1) // The export's own separator.
        #expect(all.filter { $0 is BlockQuote }.count == 1)
        #expect(!all.contains { $0 is CodeBlock || $0 is ListItem || $0 is HTMLBlock })
        let quote = try #require(all.compactMap { $0 as? BlockQuote }.first)
        #expect(literalText(quote) == text)
        let noteParagraphs = Array(document.children).compactMap { $0 as? Paragraph }
        let note = noteParagraphs.dropFirst().dropLast().map { literalText($0) }.joined(separator: "\n\n")
        #expect(note == "Note: " + text)
    }

    @Test("HTML entity spellings in literal text are preserved")
    func literalEntities() throws {
        let text = "A & B &copy; &#35; &lt;script&gt;"
        let markdown = HighlightMarkdown.render([
            HighlightExcerpt(text: text, note: text, pageIndex: 0, pageLabel: "1", color: "Yellow")
        ], title: "Reading", sourceURL: nil)
        let all = nodes(Markdown.Document(parsing: markdown))
        let quote = try #require(all.compactMap { $0 as? BlockQuote }.first)
        #expect(literalText(quote) == text)
        #expect(all.compactMap { $0 as? Paragraph }.contains { literalText($0) == "Note: " + text })
    }

    private func nodes(_ node: any Markup) -> [any Markup] {
        [node] + node.children.flatMap { nodes($0) }
    }

    private func literalText(_ node: any Markup) -> String {
        if let text = node as? Text { return text.string }
        if node is SoftBreak || node is LineBreak { return "\n" }
        let separator = node is BlockQuote ? "\n\n" : ""
        return node.children.map { literalText($0) }.joined(separator: separator)
    }
}
