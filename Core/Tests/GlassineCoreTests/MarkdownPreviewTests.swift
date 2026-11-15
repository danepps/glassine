import Foundation
import Testing
@testable import GlassineCore

@Suite("Markdown Quick Look content")
struct MarkdownPreviewTests {
    private func render(_ text: String, folder: TempDirectory, name: String = "Preview.md") throws -> String {
        let url = folder.write(Data(text.utf8), to: name)
        return String(decoding: try MarkdownPreview.html(for: url), as: UTF8.self)
    }

    @Test("Previews share Markdown formatting and use working HTML heading and footnote anchors")
    func richMarkdown() throws {
        let folder = TempDirectory()
        let html = try render("""
        ---
        title: Hidden metadata
        ---
        # A & B

        [Second section](#second) and a footnote.[^note]

        | Name | Value |
        | --- | --- |
        | **Bold** | *Italic* |

        - [x] Finished

        ```swift
        let value = "<script>"
        ```

        ## Second

        Body.

        [^note]: The note **text**.
        """, folder: folder, name: "A & B.md")
        #expect(html.contains("<title>A &amp; B.md</title>"))
        #expect(!html.contains("Hidden metadata"))
        #expect(html.contains("<h2 id=\"second\">Second</h2>"))
        #expect(html.contains("href=\"#second\""))
        #expect(!html.contains("glassine-outline://"))
        #expect(html.contains("<table>"))
        #expect(html.contains("<strong>Bold</strong>"))
        #expect(html.contains("checked=\"\""))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("class=\"fnref\""))
        #expect(html.contains("class=\"fnback\""))
        #expect(html.contains("<strong>text</strong>"))
        #expect(html.contains("prefers-color-scheme: dark"))
        #expect(!html.contains("margin-bottom: -72pt;"))
    }

    @Test("Preview content cannot introduce active HTML, unsafe links or attribute injection")
    func passiveContent() throws {
        let folder = TempDirectory()
        let html = try render("""
        <script>window.previewAttack = true</script>

        <meta http-equiv="refresh" content="0;url=https://example.com">

        [Run](javascript:alert%281%29) [File](file:///tmp/example)

        [Website](https://example.com?a=1&b=2) and x<sup>2</sup><br>next.

        ![Remote image](https://example.com/image.png)

        <!-- This comment should stay hidden. -->

        Mid-sentence <!-- an inline aside --> text with <U>underline</U>, a
        <span onclick="alert(1)">span</span> and a [sibling](docs/other.md) link.

        Footnote.[^note]

        [^note]: <iframe src="https://example.com"></iframe>
        """, folder: folder)
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<meta http-equiv=\"refresh\""))
        #expect(!html.contains("<iframe"))
        // The reader's sanitiser runs first, so these are removed outright,
        // not shown as text the way other embedded HTML is.
        #expect(!html.contains("previewAttack"))
        #expect(!html.contains("&lt;script"))
        #expect(!html.contains("refresh"))
        #expect(!html.contains("&lt;iframe"))
        #expect(!html.contains("href=\"javascript:"))
        #expect(!html.contains("href=\"file:"))
        #expect(html.contains("href=\"https://example.com?a=1&amp;b=2\""))
        #expect(html.contains("<sup>2</sup><br>"))
        #expect(html.contains("[Remote image]"))
        #expect(!html.contains("This comment should stay hidden"))
        // An inline comment is dropped like a block one; a bare formatting tag
        // survives; a tag with attributes is shown as text; a link that lost
        // its destination is an anchor without an href, styled as plain text.
        #expect(!html.contains("an inline aside"))
        #expect(html.contains("<u>underline</u>"))
        #expect(!html.contains("<span"))
        #expect(html.contains("&lt;span onclick="))
        #expect(html.contains("span&lt;/span&gt;"))
        #expect(html.contains("<a>sibling</a>"))
        #expect(!html.contains("docs/other.md"))
        #expect(html.contains("a:not([href]) { color: inherit; }"))
        #expect(html.contains("default-src 'none'; img-src data:; style-src 'unsafe-inline'"))
    }

    @Test("UTF-16 is decoded and unreadable or missing files report errors")
    func encodingAndReadErrors() throws {
        let folder = TempDirectory()
        let utf16 = try #require("# Résumé\n\n日本語".data(using: .utf16))
        let url = folder.write(utf16, to: "UTF16.md")
        let html = String(decoding: try MarkdownPreview.html(for: url), as: UTF8.self)
        #expect(html.contains("Résumé"))
        #expect(html.contains("日本語"))
        let invalid = folder.write(Data([0xC3, 0x28]), to: "Invalid.md")
        #expect(throws: (any Error).self) { try MarkdownPreview.html(for: invalid) }
        #expect(throws: (any Error).self) { try MarkdownPreview.html(for: folder.url) }
        #expect(throws: (any Error).self) {
            try MarkdownPreview.html(for: folder.url.appendingPathComponent("Missing.md"))
        }
    }

    @Test("Empty and oversized files get useful previews, without truncation or source edits")
    func fileLimits() throws {
        let folder = TempDirectory()
        #expect(try render("  \n\n", folder: folder).contains("This Markdown file is empty."))
        let original = Data(repeating: 0x61, count: MarkdownPreview.maximumFileSize + 1)
        let url = folder.write(original, to: "Large.md")
        let html = String(decoding: try MarkdownPreview.html(for: url), as: UTF8.self)
        #expect(html.contains("too large to preview"))
        #expect(html.utf8.count < 20_000)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Images stay inside the document folder, including through symlinks")
    func localImages() throws {
        let folder = TempDirectory()
        let outside = TempDirectory()
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0, 1])
        folder.write(image, to: "Inside.png")
        let secret = outside.write(image, to: "Outside.png")
        try FileManager.default.createSymbolicLink(at: folder.url.appendingPathComponent("Link.png"), withDestinationURL: secret)
        let html = try render("""
        ![Inside](Inside.png)

        ![Symlink](Link.png)

        ![Missing](Missing.png)
        """, folder: folder)
        #expect(html.components(separatedBy: "src=\"data:image/png;base64,").count - 1 == 1)
        #expect(html.contains("alt=\"Inside\""))
        #expect(html.contains("[Symlink]"))
        #expect(html.contains("[Missing]"))
    }

    @Test("Local and embedded PDF figures survive in preview bodies and footnotes")
    func pdfFigures() throws {
        let folder = TempDirectory()
        let pdf = makeTextPDFData(pages: ["A PDF figure"])
        folder.write(pdf, to: "Figure.pdf")
        let encoded = pdf.base64EncodedString()
        for source in ["Figure.pdf", "data:application/pdf;base64,\(encoded)",
                       "DATA:APPLICATION/PDF;base64,\(encoded)",
                       "data:application/pdf;version=1.3;base64,\(encoded)"] {
            let html = try render("""
            ![Figure](\(source))

            Note.[^note]

            [^note]: ![Footnote figure](\(source))
            """, folder: folder)
            let imageCount = html.components(separatedBy: "<img ").count - 1
            #expect(imageCount == 2)
        }

        // Accept the exact PDF media type, not a prefix that admits other
        // application types or arbitrary HTML documents.
        for mediaType in ["application/pdf-other", "application/pdf+xml", "text/html"] {
            let html = try render("![Unsupported](data:\(mediaType);base64,\(encoded))", folder: folder)
            #expect(!html.contains("<img "))
            #expect(html.contains("[Unsupported]"))
        }
    }

    @Test("PDF figures share the preview image budget with PNGs and footnotes")
    func pdfImageBudget() throws {
        let folder = TempDirectory()
        var pdf = makeTextPDFData(pages: ["A large PDF figure"])
        pdf.append(Data("\n%".utf8))
        pdf.append(Data(repeating: 0x20, count: 5 * 1024 * 1024 - pdf.count))
        folder.write(pdf, to: "Large.pdf")
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZuoAAAAASUVORK5CYII="))
        folder.write(png, to: "Small.png")
        let html = try render("""
        ![PDF figure](Large.pdf)

        ![PNG figure](Small.png)

        Note.[^note]

        [^note]: ![Over budget](Large.pdf)
        """, folder: folder)
        let pdfCount = html.components(separatedBy: "src=\"data:application/pdf;base64,").count - 1
        let pngCount = html.components(separatedBy: "src=\"data:image/png;base64,").count - 1
        #expect(pdfCount == 1)
        #expect(pngCount == 1)
        #expect(html.contains("[Over budget]"))
    }

    /// The `href`s of the outline's links, in order.
    private func outlineHrefs(_ html: String) throws -> [String] {
        let start = try #require(html.range(of: "<nav class=\"preview-outline\""))
        let end = try #require(html.range(of: "</nav>", range: start.upperBound..<html.endIndex))
        return html[start.upperBound..<end.lowerBound]
            .components(separatedBy: "<a href=\"").dropFirst()
            .compactMap { $0.split(separator: "\"", maxSplits: 1).first.map(String.init) }
    }

    @Test("Two or more headings get a headings column listing each one in order")
    func outlineColumn() throws {
        let folder = TempDirectory()
        let html = try render("""
        # Title

        Intro.

        ## First part

        ### A detail

        ## Second part
        """, folder: folder)
        #expect(html.contains("<nav class=\"preview-outline\" aria-label=\"Contents\"><ul>"))
        #expect(try outlineHrefs(html) == ["#title", "#first-part", "#a-detail", "#second-part"])
        #expect(html.contains("<li class=\"outline-depth-0\"><a href=\"#title\" title=\"Title\">Title</a></li>"))
        #expect(html.contains("<li class=\"outline-depth-1\"><a href=\"#first-part\" title=\"First part\">First part</a></li>"))
        #expect(html.contains("<li class=\"outline-depth-2\"><a href=\"#a-detail\""))
        #expect(html.contains("<li class=\"outline-depth-1\"><a href=\"#second-part\""))
        // The body follows the column, in its own element.
        let nav = try #require(html.range(of: "</nav>"))
        let main = try #require(html.range(of: "<main class=\"preview-body\">"))
        #expect(nav.upperBound <= main.lowerBound)
        #expect(html.contains("</main>\n</body>"))
        #expect(html.contains("<h2 id=\"first-part\">First part</h2>"))
        #expect(!html.contains("<script"))
        #expect(html.contains("content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\""))
    }

    @Test("Indentation is relative to the shallowest heading in the document")
    func outlineRelativeDepth() throws {
        let folder = TempDirectory()
        let page = try render("## Two\n\n#### Four\n\n### Three\n\n## Two again\n", folder: folder)
        let html = try #require(page.components(separatedBy: "</head>").last)
        #expect(html.contains("<li class=\"outline-depth-0\"><a href=\"#two\""))
        #expect(html.contains("<li class=\"outline-depth-2\"><a href=\"#four\""))
        #expect(html.contains("<li class=\"outline-depth-1\"><a href=\"#three\""))
        #expect(html.contains("<li class=\"outline-depth-0\"><a href=\"#two-again\""))
        #expect(!html.contains("outline-depth-3"))
    }

    @Test("Repeated titles link to their numbered ids, and every link names an id in the body")
    func outlineRepeatedTitles() throws {
        let folder = TempDirectory()
        let html = try render("# Notes\n\nA.\n\n# Notes\n\nB.\n\n## Notes\n\n## !!!\n", folder: folder)
        let hrefs = try outlineHrefs(html)
        #expect(hrefs == ["#notes", "#notes-1", "#notes-2", "#section"])
        for href in hrefs {
            #expect(html.contains("id=\"\(href.dropFirst())\""))
        }
    }

    @Test("Outline titles and hrefs are escaped")
    func outlineEscaping() throws {
        let folder = TempDirectory()
        let html = try render("""
        # Smith & Jones

        ## Code `a<b> "q"` here
        """, folder: folder)
        let nav = try #require(html.range(of: "<nav"))
        let navEnd = try #require(html.range(of: "</nav>"))
        let navHTML = String(html[nav.lowerBound..<navEnd.upperBound])
        #expect(navHTML.contains("<a href=\"#smith--jones\" title=\"Smith &amp; Jones\">Smith &amp; Jones</a>"))
        // Inline code keeps a straight quote (prose quotes come out curly).
        #expect(navHTML.contains("<a href=\"#code-ab-q-here\" title=\"Code a&lt;b&gt; &quot;q&quot; here\">Code a&lt;b&gt; &quot;q&quot; here</a>"), "\(navHTML)")
        #expect(!navHTML.contains("<b>"))
        #expect(!navHTML.contains("\"q\""))
    }

    @Test("No column for zero or one heading, an empty file, or a file too large to preview")
    func outlineAbsent() throws {
        let folder = TempDirectory()
        for text in ["Just a paragraph.", "# Only one\n\nText.", "  \n\n"] {
            let html = try render(text, folder: folder)
            let body = try #require(html.components(separatedBy: "</head>").last)
            #expect(!body.contains("<nav"))
            #expect(!body.contains("<main"))
            // Exactly the body the page had before the column existed.
            let converted = MarkdownHTML.body(fromMarkdown: text, baseDirectory: folder.url,
                                              output: .preview).html
            let expected = converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "<p class=\"preview-notice\">This Markdown file is empty.</p>" : converted
            #expect(html.contains("</head><body>\n\(expected)\n</body></html>"))
        }
        let url = folder.write(Data(repeating: 0x23, count: MarkdownPreview.maximumFileSize + 1),
                               to: "Large.md")
        let large = String(decoding: try MarkdownPreview.html(for: url), as: UTF8.self)
        #expect(!large.contains("<nav"))
        #expect(large.contains("</head><body>\n<p class=\"preview-notice\">This file is too large"))
    }

    @Test("Headings with no text, or built without a slug, are left out of the column")
    func outlineSkipsUnlinkable() {
        #expect(MarkdownPreview.outline([
            MarkdownHeading(level: 1, title: "One", index: 0, slug: "one"),
            MarkdownHeading(level: 1, title: "No slug", index: 1)
        ]) == nil)
        let html = MarkdownPreview.outline([
            MarkdownHeading(level: 1, title: "", index: 0, slug: "section"),
            MarkdownHeading(level: 2, title: "A", index: 1, slug: "a"),
            MarkdownHeading(level: 3, title: "B", index: 2, slug: "b")
        ])
        #expect(html?.contains("href=\"#section\"") == false)
        #expect(html?.contains("<li class=\"outline-depth-0\"><a href=\"#a\"") == true)
    }

    @Test("The image budget spans the body and footnotes")
    func totalImageBudget() throws {
        let folder = TempDirectory()
        folder.write(Data(count: 5 * 1024 * 1024), to: "Large.png")
        let html = try render("""
        ![Body](Large.png)

        Note.[^note]

        [^note]: ![Footnote image](Large.png)
        """, folder: folder)
        #expect(html.components(separatedBy: "src=\"data:image/png;base64,").count - 1 == 1)
        #expect(html.contains("[Footnote image]"))
    }
}
