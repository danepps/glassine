import AppKit
import GlassineCore
import PDFKit
import Testing
@testable import Glassine

/// Uses the app's actual WebKit print path. Run alone with
/// GLASSINE_RUN_MARKDOWN_PRINT_TEST=1 and WindowServer/WebKit access.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GLASSINE_RUN_MARKDOWN_PRINT_TEST"] == "1"))
@MainActor func markdownTablesRepeatHeadersWithoutSplittingRows() async throws {
    _ = NSApplication.shared
    let rows = (1...45).map { index in
        let id = String(format: "%03d", index)
        return "| [RowStart\(id)](https://example.com/rows/\(id)) | A longer explanation that wraps onto several lines, with enough detail to exercise a table row near the bottom of a printed page. RowEnd\(id) |"
    }
    let markdown = """
    # Paginated table

    This introduction puts the table partway down the first page.

    | Item identifier | Details repeated header |
    | --- | --- |
    \(rows.joined(separator: "\n"))

    ## After the table

    Final paragraph after all forty-five rows.
    """
    let body = MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil).html
    let printer = WebKitHTMLPrinter()
    let queue = RenderQueue(printer: printer)
    defer { printer.teardown() }
    let cases: [(String, Int, MarkdownLayout)] = MarkdownStyle.builtIns.map { ($0.id, 13, .pages) }
        + [("manuscript", 9, .pages), ("manuscript", 17, .pages), ("manuscript", 13, .continuous)]
    for (style, size, layout) in cases {
        let styling = MarkdownStyling(styleID: style, css: MarkdownHTML.builtInStyle(style),
                                      size: size, layout: layout)
        let html = MarkdownHTML.page(body: body, title: "Table pagination fixture", styling: styling)
        let rendered: RenderedMarkdown = try await withCheckedThrowingContinuation { continuation in
            queue.render(html: html, baseURL: nil, key: "table-fixture", layout: layout) {
                continuation.resume(with: $0)
            }
        }
        let name = "\(style)-\(size)-\(layout == .pages ? "pages" : "continuous")"
        if let directory = ProcessInfo.processInfo.environment["GLASSINE_MARKDOWN_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try rendered.data.write(to: url.appendingPathComponent("\(name).pdf"))
        }
        let pdf = rendered.document
        if layout == .pages { #expect(pdf.pageCount >= 3) }
        else { #expect(pdf.pageCount == 1) }
        var rowLinks = 0
        for index in 0..<pdf.pageCount {
            let page = try #require(pdf.page(at: index))
            let text = (page.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if text.contains("RowStart") || text.contains("RowEnd") {
                #expect(text.contains("Item identifier"), "Missing table header: \(name), page \(index + 1)")
                #expect(text.contains("Details repeated header"))
            }
            rowLinks += page.annotations.filter {
                ($0.action as? PDFActionURL)?.url?.host == "example.com"
            }.count
        }
        #expect(rowLinks == 45, "Pagination must preserve cell links")
        #expect(pdf.string?.contains("Final paragraph after all forty-five rows.") == true)
        for index in 1...45 {
            let id = String(format: "%03d", index)
            let start = pdf.findString("RowStart\(id)", withOptions: [])
            let end = pdf.findString("RowEnd\(id)", withOptions: [])
            #expect(start.count == 1 && end.count == 1, "Every table row must appear exactly once")
            let startPage = try #require(start.first?.pages.first)
            let endPage = try #require(end.first?.pages.first)
            #expect(startPage === endPage, "Row \(id) is split: \(name)")
            if layout == .pages {
                #expect(try #require(end.first).bounds(for: endPage).minY >= 71,
                        "Table text must stay inside the printable area")
            }
        }
    }

    // Multiple tables after enough prose to span pages exercise placement
    // when preceding text has already incurred native pagination adjustments.
    let introduction = Array(repeating:
        "A paragraph before the tables, with several lines of explanatory text to vary where the first table begins on a printed page.",
        count: 24).joined(separator: "\n\n")
    let mixed = """
    # Mixed content

    \(introduction)

    | First header | First description |
    | --- | --- |
    \((1...18).map { "| FirstRow\($0) | A wrapping description with several words before FirstEnd\($0). |" }.joined(separator: "\n"))

    A short paragraph between the tables.

    | Second header | Second description |
    | --- | --- |
    \((1...8).map { "| SecondRow\($0) | A different table with its own header and SecondEnd\($0). |" }.joined(separator: "\n"))

    ## Oversized row

    | Tall header | Tall description |
    | --- | --- |
    | TallStart | \(Array(repeating: "Tall row content that must never be dropped or clipped.", count: 90).joined(separator: " ")) TallEnd |

    FinalMixedMarker
    """
    let styling = MarkdownStyling(styleID: "manuscript", css: MarkdownHTML.builtInStyle("manuscript"),
                                  size: 13, layout: .pages)
    let mixedBody = MarkdownHTML.body(fromMarkdown: mixed, baseDirectory: nil).html
    let mixedHTML = MarkdownHTML.page(body: mixedBody, title: "Mixed tables", styling: styling)
    let mixedResult: RenderedMarkdown = try await withCheckedThrowingContinuation { continuation in
        queue.render(html: mixedHTML, baseURL: nil, key: "mixed-tables", layout: .pages) {
            continuation.resume(with: $0)
        }
    }
    if let directory = ProcessInfo.processInfo.environment["GLASSINE_MARKDOWN_CAPTURE_DIR"] {
        try mixedResult.data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("mixed-tables.pdf"))
    }
    let pdf = mixedResult.document
    for index in 0..<pdf.pageCount {
        let text = (pdf.page(at: index)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.contains("FirstRow") { #expect(text.contains("First header")) }
        if text.contains("SecondRow") { #expect(text.contains("Second header")) }
    }
    for marker in ["TallStart", "TallEnd", "FinalMixedMarker"] {
        #expect(pdf.findString(marker, withOptions: []).count == 1,
                "A row taller than the paper must flow instead of losing content")
    }
    let shortTableStart = try #require(pdf.findString("SecondRow1", withOptions: []).first?.pages.first)
    let shortTableEnd = try #require(pdf.findString("SecondEnd8", withOptions: []).first?.pages.first)
    #expect(shortTableStart === shortTableEnd, "A short table should stay whole")
    let mixedText = (pdf.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    #expect(mixedText.components(separatedBy: "Tall row content").count == 91)
}
