import Foundation
import Testing
@testable import GlassineCore

@Suite("MarkdownHTML")
struct MarkdownHTMLTests {

    @Test("YAML front matter is stripped, both terminators")
    func frontMatter() {
        let dashes = "---\ntitle: Memo\nauthor: Dan\n---\n# Heading\n\nBody.\n"
        #expect(MarkdownHTML.stripFrontMatter(dashes) == "# Heading\n\nBody.\n")

        let dots = "---\ntitle: Memo\n...\n# Heading\n"
        #expect(MarkdownHTML.stripFrontMatter(dots) == "# Heading\n")

        // A byte-order mark ahead of the fence still counts as a leading fence.
        #expect(MarkdownHTML.stripFrontMatter("\u{FEFF}---\na: b\n---\nX") == "X")

        // No front matter, and a horizontal rule that only looks like one.
        #expect(MarkdownHTML.stripFrontMatter("# Heading\n\n---\n") == "# Heading\n\n---\n")
        // An unterminated fence is left alone rather than eating the document.
        #expect(MarkdownHTML.stripFrontMatter("---\nnope\n") == "---\nnope\n")
    }

    @Test("Heading numbering matches the anchors in the HTML, in order")
    func headingNumbering() {
        let markdown = """
        # One

        text

        ## Two

        ### Three

        # Four
        """
        let converted = MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil)

        #expect(converted.headings.map(\.title) == ["One", "Two", "Three", "Four"])
        #expect(converted.headings.map(\.level) == [1, 2, 3, 1])
        #expect(converted.headings.map(\.index) == [0, 1, 2, 3])

        // Every heading's anchor is present, and they appear in document order.
        var searchFrom = converted.html.startIndex
        for heading in converted.headings {
            let anchor = "glassine-outline://\(heading.index)"
            guard let range = converted.html.range(of: anchor, range: searchFrom..<converted.html.endIndex)
            else {
                Issue.record("missing anchor \(anchor)")
                return
            }
            searchFrom = range.upperBound
        }
        #expect(converted.html.contains("<a class=\"fh\" href=\"glassine-outline://0\">One</a></h1>"))
    }

    @Test("A relative image inside the base directory is inlined; one outside is not")
    func imageInlining() {
        let root = TempDirectory()
        let documents = root.url.appendingPathComponent("docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)

        let inside = documents.appendingPathComponent("logo.png")
        try? Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: inside)
        let outside = root.url.appendingPathComponent("secret.png")
        try? Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x02]).write(to: outside)

        let markdown = """
        ![in](logo.png)

        ![out](../secret.png)

        ![remote](https://example.com/x.png)
        """
        let converted = MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: documents)

        // Exactly one image was inlined: the one inside the document's folder.
        #expect(converted.html.components(separatedBy: "data:image/png;base64,").count - 1 == 1)
        #expect(!converted.html.contains("logo.png"))
        // "../secret.png" is not ours to inline, and a remote source never is;
        // both keep their own src and the CSP stops them loading.
        #expect(converted.html.contains("../secret.png"))
        #expect(converted.html.contains("https://example.com/x.png"))
    }

    @Test("An image over the 8 MB cap is left as a plain reference")
    func imageSizeCap() {
        let root = TempDirectory()
        let big = root.url.appendingPathComponent("big.png")
        try? Data(count: 8 * 1024 * 1024 + 1).write(to: big)
        let small = root.url.appendingPathComponent("small.png")
        try? Data(count: 1024).write(to: small)

        let over = MarkdownHTML.body(fromMarkdown: "![x](big.png)", baseDirectory: root.url)
        #expect(!over.html.contains("data:image/png;base64,"))
        #expect(over.html.contains("big.png"))

        let under = MarkdownHTML.body(fromMarkdown: "![x](small.png)", baseDirectory: root.url)
        #expect(under.html.contains("data:image/png;base64,"))
    }

    @Test("Word count is over the plain text, not the markup")
    func wordCount() {
        let markdown = """
        # Title Here

        Some **bold** words and a [link](https://example.com/very/long/path).

        ```
        let code = 1
        ```
        """
        let converted = MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil)
        // "Title Here" (2) + "Some bold words and a link" (6) + "let code 1" (3).
        #expect(converted.stats.words == 11)

        // A URL in a link destination is markup, not prose: it must not count.
        let bare = MarkdownHTML.body(fromMarkdown: "one two three", baseDirectory: nil)
        #expect(bare.stats.words == 3)
    }

    @Test("The page wraps the body with the CSP and both style layers")
    func pageTemplate() {
        let styling = MarkdownStyling(styleID: "manuscript",
                                      css: "/* STYLE-LAYER-MARKER */",
                                      size: 12,
                                      layout: .pages)
        let page = MarkdownHTML.page(body: "<p>Hi</p>", title: "A & B", styling: styling)
        #expect(page.contains("default-src 'none'; img-src data:; style-src 'unsafe-inline'"))
        #expect(page.contains("<title>A &amp; B</title>"))
        #expect(page.contains("/* STYLE-LAYER-MARKER */"))
        #expect(page.contains("--body-size: 12pt;"))
        #expect(page.contains("<p>Hi</p>"))
        // Paged geometry brings the keep-with-next hack; continuous does not.
        #expect(page.contains("margin-bottom: -72pt;"))
        let continuous = MarkdownHTML.page(body: "", title: "",
                                           styling: MarkdownStyling(styleID: "manuscript",
                                                                    css: "",
                                                                    size: 11,
                                                                    layout: .continuous))
        #expect(continuous.contains("body { padding: 72pt; }"))
        #expect(!continuous.contains("margin-bottom: -72pt;"))
    }

    @Test("Every built-in style id resolves, and an unknown one falls back")
    func builtInStyles() {
        for style in MarkdownStyle.builtIns {
            #expect(!MarkdownHTML.builtInStyle(style.id).isEmpty)
        }
        #expect(MarkdownHTML.builtInStyle("nonsense")
                == MarkdownHTML.builtInStyle(MarkdownStyle.defaultID))
    }
}

/// Markdown footnotes -- the Pandoc/GitHub/Obsidian extension cmark-gfm has and
/// swift-markdown never turns on, so `MarkdownFootnotes` implements it: the
/// definitions come out of the text before the parse, the references are
/// rewritten in the tree, and the notes are appended as a section.
@Suite("Markdown footnotes")
struct MarkdownFootnoteTests {

    private func convert(_ markdown: String) -> (html: String,
                                                 headings: [MarkdownHeading],
                                                 stats: MarkdownStats) {
        MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil)
    }

    @Test("A reference and its definition become a marker and a note")
    func basic() {
        let html = convert("""
        The report said so.[^gao]

        [^gao]: GAO Report 24-1.
        """).html

        #expect(html.contains(
            "<sup class=\"fnref\" id=\"fnref-gao\"><a href=\"#fn-gao\">1</a></sup>"))
        #expect(html.contains("<section class=\"footnotes\">"))
        #expect(html.contains("<li id=\"fn-gao\">"))
        #expect(html.contains("GAO Report 24-1."))
        #expect(html.contains("<a class=\"fnback\" href=\"#fnref-gao\">\u{21A9}</a></p>"))
        // The definition line itself is gone from the prose.
        #expect(!html.contains("[^gao]:"))
        #expect(!html.contains("[^gao]"))
    }

    @Test("Two references to one label share a number and never share an id")
    func repeatedReference() {
        let html = convert("""
        First.[^a] Second.[^a]

        [^a]: Once.
        """).html

        #expect(html.components(separatedBy: "href=\"#fn-a\">1</a>").count - 1 == 2)
        #expect(html.contains("id=\"fnref-a\""))
        #expect(html.contains("id=\"fnref-a-2\""))
        // One note, listed once.
        #expect(html.components(separatedBy: "<li id=\"fn-a\">").count - 1 == 1)
    }

    @Test("Numbering follows first reference, not the order of the definitions")
    func numberingByReference() {
        let html = convert("""
        Beta first.[^beta] Then alpha.[^alpha]

        [^alpha]: The alpha note.
        [^beta]: The beta note.
        """).html

        #expect(html.contains("<a href=\"#fn-beta\">1</a>"))
        #expect(html.contains("<a href=\"#fn-alpha\">2</a>"))
        // And the list is in number order.
        let beta = html.range(of: "<li id=\"fn-beta\">")
        let alpha = html.range(of: "<li id=\"fn-alpha\">")
        #expect(beta != nil && alpha != nil)
        if let beta, let alpha { #expect(beta.lowerBound < alpha.lowerBound) }
    }

    @Test("A definition runs on through lazy and indented continuation lines")
    func continuations() {
        let converted = convert("""
        Text.[^long]

        [^long]: The first line
        lazily continued on the next.

            And a second paragraph, indented.

        A plain paragraph that is not part of the note.
        """)

        #expect(converted.html.contains("lazily continued on the next."))
        #expect(converted.html.contains("<p>And a second paragraph, indented."))
        // Two paragraphs inside the one note; the back-link is in the last.
        #expect(converted.html.contains(
            "indented.<a class=\"fnback\" href=\"#fnref-long\">\u{21A9}</a></p>"))
        // The unindented paragraph after the blank line ended the note and is
        // still body text, ahead of the notes section.
        let paragraph = converted.html.range(of: "A plain paragraph that is not part of the note.")
        let section = converted.html.range(of: "<section class=\"footnotes\">")
        #expect(paragraph != nil && section != nil)
        if let paragraph, let section { #expect(paragraph.lowerBound < section.lowerBound) }
    }

    @Test("Code spans and fenced blocks are left exactly as written")
    func code() {
        let html = convert("""
        Real one.[^x] Literal `[^x]` in code.

        ```
        [^x]: not a definition
        [^x] not a reference
        ```

        [^x]: The note.
        """).html

        // Exactly one marker, and the code kept its brackets.
        #expect(html.components(separatedBy: "class=\"fnref\"").count - 1 == 1)
        #expect(html.contains("<code>[^x]</code>"))
        #expect(html.contains("[^x]: not a definition"))
        #expect(html.contains("[^x] not a reference"))
        // The definition inside the fence was not lifted out: the note is the
        // real one below it.
        #expect(html.contains("The note."))
    }

    @Test("A reference with no definition stays literal text")
    func undefined() {
        let html = convert("Nothing defines this.[^ghost]\n").html
        #expect(html.contains("[^ghost]"))
        #expect(!html.contains("class=\"fnref\""))
        #expect(!html.contains("<section class=\"footnotes\">"))
    }

    @Test("A definition that is only a URL is a note, not a link reference")
    func singleTokenDefinition() {
        // cmark reads `[^1]: https://example.com` as a *link reference
        // definition* and would turn `[^1]` into a link to it; the text pass
        // has to take the line out before the parser ever sees it.
        let html = convert("""
        See the site.[^1]

        [^1]: https://example.com
        """).html

        #expect(html.contains("<a href=\"#fn-1\">1</a>"))
        #expect(!html.contains("<a href=\"https://example.com\">[^1]</a>"))
        #expect(html.contains("<li id=\"fn-1\">"))
        #expect(html.contains("https://example.com"))
    }

    @Test("A note's own Markdown is rendered")
    func noteMarkdown() {
        let html = convert("""
        Cited.[^n]

        [^n]: See *Sorrells*, [287 U.S. 435](https://example.com/sorrells), and `code`.
        """).html

        #expect(html.contains("<em>Sorrells</em>"))
        #expect(html.contains("<a href=\"https://example.com/sorrells\">287 U.S. 435</a>"))
        #expect(html.contains("<code>code</code>"))
    }

    @Test("A document with no footnotes gets no notes section")
    func none() {
        let html = convert("# Title\n\nJust prose, with a [link](https://example.com).\n").html
        #expect(!html.contains("footnotes"))
        #expect(!html.contains("fnref"))
    }

    @Test("An unreferenced definition is dropped")
    func unreferenced() {
        let html = convert("""
        Body text.

        [^unused]: Nobody points at this.
        """).html

        #expect(!html.contains("<section class=\"footnotes\">"))
        #expect(!html.contains("Nobody points at this."))
        #expect(!html.contains("[^unused]"))
    }

    @Test("The word count includes the notes and not the markers")
    func words() {
        // "Body text here" (3) + the note's "One two three four" (4).
        let converted = convert("""
        Body text here.[^w]

        [^w]: One two three four.
        """)
        #expect(converted.stats.words == 7)
    }

    @Test("Front matter is still stripped when the document has footnotes")
    func withFrontMatter() {
        let converted = convert("""
        ---
        title: Memo
        ---
        # Heading

        Text.[^f]

        [^f]: A note.
        """)
        #expect(!converted.html.contains("title: Memo"))
        #expect(converted.headings.map(\.title) == ["Heading"])
        #expect(converted.html.contains("<li id=\"fn-f\">"))
    }

    @Test("A footnote in a heading stays out of the outline label")
    func inHeading() {
        let converted = convert("""
        ## A Heading[^h]

        [^h]: The note.
        """)
        #expect(converted.headings.map(\.title) == ["A Heading"])
        #expect(converted.html.contains("class=\"fnref\""))
    }

    @Test("A label with awkward characters still makes one usable id")
    func slugging() {
        let html = convert("""
        Text.[^a b?]

        [^a b?]: Not a footnote -- the label has a space.
        """).html
        // A label may not contain whitespace, so this is literal text.
        #expect(!html.contains("class=\"fnref\""))

        let punctuated = convert("""
        Text.[^note.1]

        [^note.1]: Punctuated label.
        """).html
        #expect(punctuated.contains("id=\"fn-note-1\""))
        #expect(punctuated.contains("href=\"#fn-note-1\""))
    }
}

/// Same-document heading links. Every heading carries a GitHub-style `id`, and
/// WebKit's print path turns a `#slug` link into a real internal `GoTo`
/// destination, so a hand-written table of contents is live in the rendered
/// PDF without any rewriting of the links themselves.
@Suite("Markdown heading anchors")
struct MarkdownHeadingAnchorTests {

    private func html(_ markdown: String) -> String {
        MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil).html
    }

    @Test("Slugs lower-case, drop punctuation, and turn spaces into hyphens")
    func slugShape() {
        let output = html("""
        # The Court's *Ruling*: Sorrells v. United States (1932)

        ## Snake_case and hyphen-ated words

        ### 42
        """)
        #expect(output.contains("<h1 id=\"the-courts-ruling-sorrells-v-united-states-1932\">"))
        #expect(output.contains("<h2 id=\"snake_case-and-hyphen-ated-words\">"))
        #expect(output.contains("<h3 id=\"42\">"))
    }

    @Test("Letters outside ASCII survive; a heading with no letters still gets an id")
    func slugUnicode() {
        let output = html("# Über Größe\n\n## ¡¿?!\n")
        #expect(output.contains("<h1 id=\"über-größe\">"))
        #expect(output.contains("<h2 id=\"section\">"))
    }

    @Test("Repeated titles are numbered the way GitHub numbers them")
    func slugRepeats() {
        let output = html("# Notes\n\n# Notes\n\n# Notes\n")
        #expect(output.contains("id=\"notes\">"))
        #expect(output.contains("id=\"notes-1\">"))
        #expect(output.contains("id=\"notes-2\">"))
    }

    @Test("A link to a heading matches that heading's id; a link to nothing is left alone")
    func links() {
        let output = html("""
        [Go](#background) and [nowhere](#no-such-thing) and
        [out](https://example.com/#background).

        ## Background
        """)
        #expect(output.contains("<a href=\"#background\">Go</a>"))
        #expect(output.contains("<h2 id=\"background\">"))
        // The dead fragment and the external URL are emitted exactly as written.
        #expect(output.contains("<a href=\"#no-such-thing\">nowhere</a>"))
        #expect(output.contains("<a href=\"https://example.com/#background\">out</a>"))
    }

    @Test("A footnote reference in a heading leaves the id and the outline label clean")
    func headingWithFootnote() {
        let converted = MarkdownHTML.body(fromMarkdown: """
        ## The Rule[^r]

        [^r]: The note.
        """, baseDirectory: nil)
        #expect(converted.html.contains("<h2 id=\"the-rule\">"))
        #expect(converted.headings.map(\.title) == ["The Rule"])
    }

    @Test("The outline anchor is still inside the heading, after the id")
    func anchorSurvives() {
        let output = html("# One\n\n## Two\n")
        #expect(output.contains("<h1 id=\"one\"><a class=\"fh\" href=\"glassine-outline://0\">One</a></h1>"))
        #expect(output.contains("<h2 id=\"two\"><a class=\"fh\" href=\"glassine-outline://1\">Two</a></h2>"))
    }
}
