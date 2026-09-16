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
