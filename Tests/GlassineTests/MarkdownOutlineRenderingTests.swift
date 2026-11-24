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

        @Test(.enabled(if: ProcessInfo.processInfo.environment["GLASSINE_RUN_MARKDOWN_PRINT_TEST"] == "1"))
        func wrappedBareAddressKeepsItsWholeLinkAndOutline() async throws {
            _ = NSApplication.shared
            let address = "https://example.com/a/very/long/address/used/as/a/heading/that/cannot/fit/on/one/line/of/the/page/at/this/size"
            // Text above the heading keeps a missing marker's page-top fallback
            // from accidentally passing the destination check.
            let markdown = "Text above the address.\n\n# \(address)\n\nText below the address."
            let converted = MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil)
            #expect(converted.headings.count == 1)
            // A fixed character width makes three lines, with breaks inside
            // the address like the owner's wrapped heading.
            let styling = MarkdownStyling(styleID: "manuscript",
                                          css: MarkdownHTML.builtInStyle("manuscript")
                                            + "\nh1 { font-family: Menlo, monospace; font-size: 18pt; width: 40ch; word-break: break-all; }",
                                          size: 13, layout: .pages)
            let html = MarkdownHTML.page(body: converted.html, title: "Bare address heading", styling: styling)
            let printer = WebKitHTMLPrinter()
            let queue = RenderQueue(printer: printer)
            defer { printer.teardown() }
            let rendered: RenderedMarkdown = try await withCheckedThrowingContinuation { continuation in
                queue.render(html: html, baseURL: nil, key: "bare-address-heading", layout: .pages) {
                    continuation.resume(with: $0)
                }
            }
            let pdf = rendered.document
            try #require(pdf.pageCount == 1)
            let page = try #require(pdf.page(at: 0))
            let selection = try #require(pdf.selectionForEntireDocument)
            let lines = selection.selectionsByLine().filter {
                !($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            // Exclude the two prose lines and any whitespace-only marker, then
            // prove the remaining three lines contain the complete address.
            let addressLines = Array(lines.dropFirst().dropLast())
            try #require(addressLines.count == 3)
            #expect(addressLines.map {
                ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined() == address)

            MarkdownDocumentModel.applyOutline(converted.headings, to: pdf)
            let root = try #require(pdf.outlineRoot)
            #expect(root.numberOfChildren == 1)
            let entry = try #require(root.child(at: 0))
            #expect(entry.numberOfChildren == 0)
            #expect(entry.label == address)
            let destination = try #require(entry.destination)
            #expect(destination.page === page)
            #expect(abs(destination.point.y - addressLines[0].bounds(for: page).maxY) < 12,
                    "The bookmark must land at the address's first line")
            #expect(!page.annotations.contains { $0.url?.scheme == "glassine-outline" })

            let links = page.annotations.filter { $0.url != nil }
            #expect(!links.isEmpty)
            #expect(links.allSatisfy { $0.url?.absoluteString == address },
                    "No annotation may contain a truncated address")
            for line in addressLines {
                let bounds = line.bounds(for: page)
                #expect(links.contains {
                    $0.url?.absoluteString == address
                        && $0.bounds.insetBy(dx: -2, dy: -2).contains(bounds)
                }, "Every line of the address must be covered by a link to the whole address")
            }
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["GLASSINE_RUN_MARKDOWN_PRINT_TEST"] == "1"))
        func longAndEmptyHeadingsDoNotGainALine() async throws {
            _ = NSApplication.shared
            let longWord = String(repeating: "Supercalifragilisticexpialidocious", count: 3)
            let beforeEmptyHeading = "# \(longWord)\n\nBefore empty heading.\n\n"
            let paragraph = "After empty heading."
            let styling = MarkdownStyling(styleID: "manuscript",
                                          css: MarkdownHTML.builtInStyle("manuscript")
                                            + "\nbody { width: 240pt; }",
                                          size: 20, layout: .pages)
            let printer = WebKitHTMLPrinter()
            let queue = RenderQueue(printer: printer)
            defer { printer.teardown() }

            func render(_ markdown: String, key: String) async throws -> PDFDocument {
                let converted = MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil)
                let html = MarkdownHTML.page(body: converted.html, title: "Heading layout", styling: styling)
                let rendered: RenderedMarkdown = try await withCheckedThrowingContinuation { continuation in
                    queue.render(html: html, baseURL: nil, key: key, layout: .pages) {
                        continuation.resume(with: $0)
                    }
                }
                return rendered.document
            }

            let pdf = try await render(beforeEmptyHeading + "#\n\n" + paragraph, key: "empty-heading")
            let baseline = try await render(beforeEmptyHeading + paragraph, key: "no-empty-heading")
            #expect(pdf.pageCount == 1)
            #expect(baseline.pageCount == 1)
            let page = try #require(pdf.page(at: 0))
            let baselinePage = try #require(baseline.page(at: 0))
            let markers = page.annotations.filter { $0.url?.scheme == "glassine-outline" }
            #expect(markers.count == 2)
            for index in 0..<2 {
                #expect(markers.filter { $0.url?.host == "\(index)" }.count == 1)
            }
            let marker = try #require(markers.first { $0.url?.host == "0" })
            let selection = try #require(pdf.selectionForEntireDocument)
            let lines = selection.selectionsByLine().filter {
                !($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            try #require(lines.count >= 2)
            // Prove the fixture really wraps the single word. Whitespace-only
            // marker text is excluded so the old marker's extra line cannot
            // masquerade as the heading's first text line.
            let firstTwoLines = lines.prefix(2).map {
                ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined()
            try #require(longWord.hasPrefix(firstTwoLines))
            let firstLine = lines[0].bounds(for: page)
            let secondLine = lines[1].bounds(for: page)
            #expect(abs(firstLine.maxY - marker.bounds.maxY) < 6,
                    "The marker must sit at the heading's first text line")

            let afterEmpty = try #require(pdf.findString(paragraph, withOptions: []).first)
            let withoutEmpty = try #require(baseline.findString(paragraph, withOptions: []).first)
            // Measure a full heading line from the wrapped word, rather than
            // assuming the font metrics or WebKit's print shrink factor. An
            // empty heading may change collapsed margins, but cannot add a line.
            let headingLineHeight = firstLine.maxY - secondLine.maxY
            try #require(headingLineHeight > 0)
            let addedSpacing = withoutEmpty.bounds(for: baselinePage).maxY - afterEmpty.bounds(for: page).maxY
            #expect(abs(addedSpacing) < headingLineHeight - 2,
                    "An empty heading must contribute less than a full heading line")
        }
    }
}
