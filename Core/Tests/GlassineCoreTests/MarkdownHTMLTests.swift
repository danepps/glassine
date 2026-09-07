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
