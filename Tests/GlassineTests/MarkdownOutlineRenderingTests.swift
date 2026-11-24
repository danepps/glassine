import AppKit
import GlassineCore
import PDFKit
import Testing
@testable import Glassine

extension MacAppTests {
    @Suite("Markdown outline rendering", .serialized) @MainActor
    struct MarkdownOutlineRenderingTests {
        /// This must run through the app's print path, because HTML structure
        /// alone cannot prove that WebKit emits a usable PDF link annotation.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["GLASSINE_RUN_MARKDOWN_PRINT_TEST"] == "1"))
        func linkedHeadingsKeepTheirOutlineAndExternalLinks() async throws {
            _ = NSApplication.shared
            let markdown = """
            # First heading

            First page text.

            # [Fully linked heading](https://example.com/fully)

            Text below the fully linked heading.

            # [Leading link](https://example.com/leading) heading

            Text below the heading with a leading link.

            # Middle [linked words](https://example.com/middle) heading

            Text below the heading with a link in the middle.
            """
            let converted = MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil)
            // Every heading starts a new page, so inheriting the previous
            // bookmark's destination cannot accidentally pass the test.
            let styling = MarkdownStyling(styleID: "manuscript",
                                          css: MarkdownHTML.builtInStyle("manuscript")
                                            + "\nh1 { break-before: page; } h1:first-child { break-before: auto; }",
                                          size: 13, layout: .pages)
            let html = MarkdownHTML.page(body: converted.html, title: "Linked headings", styling: styling)
            let printer = WebKitHTMLPrinter()
            let queue = RenderQueue(printer: printer)
            defer { printer.teardown() }
            let rendered: RenderedMarkdown = try await withCheckedThrowingContinuation { continuation in
                queue.render(html: html, baseURL: nil, key: "linked-headings", layout: .pages) {
                    continuation.resume(with: $0)
                }
            }
            let pdf = rendered.document
            #expect(pdf.pageCount == 4)
            MarkdownDocumentModel.applyOutline(converted.headings, to: pdf)
            let root = try #require(pdf.outlineRoot)
            #expect(root.numberOfChildren == 4)
            for (index, path) in ["fully", "leading", "middle"].enumerated() {
                let pageIndex = index + 1
                let heading = converted.headings[pageIndex]
                let page = try #require(pdf.page(at: pageIndex))
                let hit = try #require(pdf.findString(heading.title, withOptions: []).first {
                    $0.pages.first === page
                })
                let destination = try #require(root.child(at: pageIndex)?.destination)
                #expect(destination.page === page, "The bookmark must land on its own heading's page")
                #expect(abs(destination.point.y - hit.bounds(for: page).maxY) < 12,
                        "The bookmark must land at the heading, not just somewhere on its page")
                let link = try #require(page.annotations.first {
                    $0.url?.absoluteString == "https://example.com/\(path)"
                })
                #expect(link.bounds.intersects(hit.bounds(for: page)),
                        "The external link must still cover the linked heading text")
            }
            for index in 0..<pdf.pageCount {
                let page = try #require(pdf.page(at: index))
                #expect(!page.annotations.contains { $0.url?.scheme == "glassine-outline" })
            }
        }
    }
}
