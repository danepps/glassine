import AppKit
import GlassineCore
import PDFKit
import Testing
@testable import Glassine

/// Holds completions so document state can be checked before, after, and out
/// of order with a render. Pages are real PDFKit objects; WebKit is not needed
/// to inject an otherwise rare typesetting failure.
@MainActor
final class ControlledMarkdownTypesetter: MarkdownTypesetter {
    struct Request {
        let html: String
        let completion: (Result<RenderedMarkdown, Error>) -> Void
    }
    var requests: [Request] = []

    func render(html: String, baseURL: URL?, key: String, layout: MarkdownLayout,
                completion: @escaping (Result<RenderedMarkdown, Error>) -> Void) {
        requests.append(Request(html: html, completion: completion))
    }

    @discardableResult
    func succeed(_ index: Int) -> PDFDocument {
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        requests[index].completion(.success(RenderedMarkdown(data: Data(), document: pdf)))
        return pdf
    }

    func fail(_ index: Int) {
        requests[index].completion(.failure(MarkdownRenderError.timedOut))
    }

    func releaseIfIdle() {}
}

@MainActor
@Suite("Markdown document refresh", .serialized)
struct MarkdownDocumentRefreshTests {
    private let originalText = "# Original revision\n\nThe original text."
    private let updatedText = "# Updated revision\n\nThe important updated text."

    private func withIsolatedDefaults(_ body: () async throws -> Void) async throws {
        Prefs.flushRecentDocumentWrites()
        let name = "com.epps.Glassine.refresh-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let previous = Prefs.defaults
        Prefs.defaults = defaults
        defer {
            Prefs.flushRecentDocumentWrites()
            Prefs.defaults = previous
            defaults.removePersistentDomain(forName: name)
        }
        _ = NSApplication.shared
        try await body()
    }

    private func withDocument(
        _ body: (GlassineDocument, URL, ControlledMarkdownTypesetter) async throws -> Void
    ) async throws {
        try await withIsolatedDefaults {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("GlassineRefresh-\(UUID()).md")
            try originalText.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let document = try GlassineDocument(contentsOf: url, ofType: GlassineDocument.markdownType.identifier)
            let typesetter = ControlledMarkdownTypesetter()
            document.markdownTypesetter = typesetter
            document.makeWindowControllers()
            defer { document.close() }
            try #require(typesetter.requests.count == 1)
            typesetter.succeed(0)
            try await body(document, url, typesetter)
        }
    }

    private func save(_ text: String, to url: URL, document: GlassineDocument) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        document.presentedItemDidChange()
    }

    private func waitForRequests(_ count: Int, in typesetter: ControlledMarkdownTypesetter) async throws {
        let deadline = Date().addingTimeInterval(5)
        while typesetter.requests.count < count && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(typesetter.requests.count == count)
    }

    @Test("Saving identical bytes retries a failed refresh, then resumes deduplication")
    func retryFailedRefresh() async throws {
        try await withDocument { document, url, typesetter in
            let original = try #require(document.pdf)
            try save(updatedText, to: url, document: document)
            try await waitForRequests(2, in: typesetter)
            typesetter.fail(1)
            #expect(document.pdf === original)

            try save(updatedText, to: url, document: document)
            try await waitForRequests(3, in: typesetter)
            #expect(typesetter.requests[2].html.contains("important updated text"))
            let replacement = typesetter.succeed(2)
            #expect(document.pdf === replacement)

            try save(updatedText, to: url, document: document)
            try await Task.sleep(for: .milliseconds(600))
            #expect(typesetter.requests.count == 3 && document.pdf === replacement)
        }
    }

    @Test("Pending identical saves coalesce, but reverting to earlier text supersedes the pending render")
    func pendingRefreshAndRevertedContent() async throws {
        try await withDocument { document, url, typesetter in
            let original = try #require(document.pdf)
            try save(updatedText, to: url, document: document)
            try await waitForRequests(2, in: typesetter)
            try save(updatedText, to: url, document: document)
            try await Task.sleep(for: .milliseconds(600))
            #expect(typesetter.requests.count == 2)

            try save(originalText, to: url, document: document)
            try await waitForRequests(3, in: typesetter)
            typesetter.succeed(1)
            #expect(document.pdf === original, "The superseded text must never replace the visible PDF")
            let restored = typesetter.succeed(2)
            #expect(document.pdf === restored)
        }
    }

    @Test("An unchanged save also retries a failed typography change")
    func retryFailedStyleChange() async throws {
        try await withDocument { document, url, typesetter in
            Prefs.markdownFontSize = 13
            try #require(typesetter.requests.count == 2)
            typesetter.fail(1)
            try save(originalText, to: url, document: document)
            try await waitForRequests(3, in: typesetter)
            let replacement = typesetter.succeed(2)
            #expect(document.pdf === replacement)
        }
    }

    @Test("Export remains paginated while switching away from Continuous")
    func exportDuringLayoutTransition() async throws {
        try await withIsolatedDefaults {
            Prefs.markdownLayout = .continuous
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("GlassineOutput-\(UUID()).md")
            let body = "# Export fixture\n\n" + (1...100).map {
                "Paragraph \($0) with text for a long document.\n\n"
            }.joined()
            try body.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let document = try GlassineDocument(contentsOf: url, ofType: GlassineDocument.markdownType.identifier)
            document.makeWindowControllers()
            defer { document.close() }
            let deadline = Date().addingTimeInterval(30)
            while document.pdf == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            let original = try #require(document.pdf)
            try #require(document.isContinuousMarkdown && original.pageCount == 1)
            try #require((original.page(at: 0)?.bounds(for: .mediaBox).height ?? 0) > 792)

            // Hold just the display render. Export still uses the actual
            // WebKit typesetter while that layout change is pending.
            let pending = ControlledMarkdownTypesetter()
            document.markdownTypesetter = pending
            Prefs.markdownLayout = .pages
            document.markdownTypesetter = nil
            try #require(pending.requests.count == 1 && document.pdf === original)
            #expect(document.needsPaginatedOutput && document.canPrint)
            var result: Result<Data, Error>?
            document.pdfDataForExport { result = $0 }
            let outputDeadline = Date().addingTimeInterval(30)
            while result == nil && Date() < outputDeadline { try await Task.sleep(for: .milliseconds(25)) }
            let completed = try #require(result)
            let exported = try #require(PDFDocument(data: completed.get()))
            #expect(exported.pageCount > 1)
            for index in 0..<exported.pageCount {
                #expect(exported.page(at: index)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
            }
            #expect(exported.string?.contains("Paragraph 100") == true)
            #expect(document.pdf === original, "Export must not replace the on-screen document")
        }
    }
}
