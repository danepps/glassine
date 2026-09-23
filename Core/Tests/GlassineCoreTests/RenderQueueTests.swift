import Foundation
import Testing
@testable import GlassineCore

@MainActor
private final class TestHTMLPrinter: HTMLPrinter {
    var html: [String] = []
    var completions: [(Result<Data, Error>) -> Void] = []
    var reprints: [(Result<Data, Error>) -> Void] = []
    var teardownCount = 0
    var succeedsOnSecondLoad = false
    let data = makeTextPDFData(pages: ["Recovered Markdown"])

    func print(html: String, baseURL: URL?, layout: MarkdownLayout,
               completion: @escaping (Result<Data, Error>) -> Void) {
        self.html.append(html)
        completions.append(completion)
        if succeedsOnSecondLoad && self.html.count == 2 { completion(.success(data)) }
    }

    func reprint(completion: @escaping (Result<Data, Error>) -> Void) {
        reprints.append(completion)
    }

    func teardown() { teardownCount += 1 }
}

@MainActor
private final class RenderClock {
    var work: [(TimeInterval, DispatchWorkItem)] = []

    func fire(_ delay: TimeInterval) throws {
        let index = try #require(work.firstIndex { $0.0 == delay })
        work.remove(at: index).1.perform()
    }
}

@MainActor
@Suite("Markdown render recovery")
struct RenderQueueTests {
    private func harness() -> (RenderQueue, TestHTMLPrinter, RenderClock) {
        let printer = TestHTMLPrinter()
        let queue = RenderQueue(printer: printer)
        let clock = RenderClock()
        queue.schedule = { clock.work.append(($0, $1)) }
        return (queue, printer, clock)
    }

    @Test("A stalled typesetter reloads in a fresh printer before reporting an error")
    func timeoutRecreatesPrinter() async {
        let printer = TestHTMLPrinter()
        printer.succeedsOnSecondLoad = true
        let queue = RenderQueue(printer: printer)
        let result: Result<RenderedMarkdown, Error> = await withCheckedContinuation { continuation in
            queue.render(html: "latest", baseURL: nil, key: "document", layout: .pages) {
                continuation.resume(returning: $0)
            }
        }
        #expect((try? result.get().document.string)?.contains("Recovered Markdown") == true)
        #expect(printer.html == ["latest", "latest"])
        #expect(printer.teardownCount == 1)
    }

    @Test("Sleep cancels deadlines and restarts the interrupted file on wake")
    func sleepAndWake() throws {
        let (queue, printer, clock) = harness()
        var results: [Result<RenderedMarkdown, Error>] = []
        queue.render(html: "first", baseURL: nil, key: "a", layout: .continuous) { results.append($0) }
        queue.setSuspended(true)
        try clock.fire(10)
        printer.completions[0](.failure(MarkdownRenderError.printFailed))
        #expect(results.isEmpty)
        queue.render(html: "second", baseURL: nil, key: "b", layout: .pages) { results.append($0) }
        #expect(printer.html == ["first"])
        queue.setSuspended(false)
        #expect(printer.html == ["first", "first"])
        printer.completions[0](.success(printer.data))
        #expect(results.isEmpty, "A callback from the sleeping printer must be ignored")
        printer.completions[1](.success(printer.data))
        #expect(printer.html == ["first", "first", "second"])
        printer.completions[2](.success(printer.data))
        #expect(results.count == 2)
        #expect(results.allSatisfy { (try? $0.get()) != nil })
    }

    @Test("Saves before and during sleep keep only the newest queued revision")
    func latestContentWinsDuringSleep() throws {
        let (queue, printer, clock) = harness()
        var superseded = 0
        var rendered: RenderedMarkdown?
        let oldCompletion: (Result<RenderedMarkdown, Error>) -> Void = {
            if case .failure(MarkdownRenderError.superseded) = $0 { superseded += 1 }
            else { Issue.record("An obsolete revision was delivered") }
        }
        queue.render(html: "old", baseURL: nil, key: "a", layout: .pages, completion: oldCompletion)
        queue.render(html: "newer", baseURL: nil, key: "a", layout: .pages, completion: oldCompletion)
        queue.setSuspended(true)
        queue.setSuspended(true)
        queue.render(html: "newest", baseURL: nil, key: "a", layout: .pages) { rendered = try? $0.get() }
        #expect(superseded == 2)
        try clock.fire(10)
        #expect(printer.html == ["old"])
        queue.setSuspended(false)
        queue.setSuspended(false)
        #expect(printer.html == ["old", "newest"])
        printer.completions[1](.success(printer.data))
        #expect(rendered != nil)
        #expect(printer.teardownCount == 1)
    }

    @Test("Two real timeouts report one error and allow the next document to render")
    func boundedTimeoutRecovery() throws {
        let (queue, printer, clock) = harness()
        var timeouts = 0
        var next: RenderedMarkdown?
        queue.render(html: "stuck", baseURL: nil, key: "a", layout: .pages) {
            if case .failure(MarkdownRenderError.timedOut) = $0 { timeouts += 1 }
            else { Issue.record("Expected the bounded timeout error") }
        }
        queue.render(html: "next", baseURL: nil, key: "b", layout: .pages) { next = try? $0.get() }
        try clock.fire(10)
        #expect(timeouts == 0)
        #expect(printer.html == ["stuck", "stuck"])
        printer.completions[0](.success(printer.data))
        #expect(timeouts == 0 && next == nil)
        try clock.fire(10)
        #expect(timeouts == 1)
        #expect(printer.html == ["stuck", "stuck", "next"])
        printer.completions[1](.failure(MarkdownRenderError.printFailed))
        #expect(next == nil)
        printer.completions[2](.success(printer.data))
        #expect(next != nil && timeouts == 1)
        #expect(printer.teardownCount == 2)
    }

    @Test("An empty-print retry queued before sleep cannot reprint the wake job")
    func emptyRetryDoesNotCrossSleep() throws {
        let (queue, printer, clock) = harness()
        var completed = false
        queue.render(html: "document", baseURL: nil, key: "a", layout: .pages) { _ in completed = true }
        printer.completions[0](.success(Data()))
        queue.setSuspended(true)
        queue.setSuspended(false)
        try clock.fire(0.2)
        #expect(printer.reprints.isEmpty)
        #expect(!completed)
        printer.completions[1](.success(printer.data))
        #expect(completed)
    }

    @Test("An abandoned reprint cannot finish a fresh timeout attempt")
    func oldReprintIsIgnored() throws {
        let (queue, printer, clock) = harness()
        var completed = false
        queue.render(html: "document", baseURL: nil, key: "a", layout: .pages) { _ in completed = true }
        printer.completions[0](.success(Data()))
        try clock.fire(0.2)
        try #require(printer.reprints.count == 1)
        try clock.fire(10)
        printer.reprints[0](.success(printer.data))
        #expect(!completed)
        printer.completions[1](.success(printer.data))
        #expect(completed)
    }

    @Test("Empty output still gets exactly one reprint")
    func emptyOutputRecovery() throws {
        let (queue, printer, clock) = harness()
        var result: Result<RenderedMarkdown, Error>?
        queue.render(html: "document", baseURL: nil, key: "a", layout: .pages) { result = $0 }
        printer.completions[0](.success(Data()))
        try clock.fire(0.2)
        try #require(printer.reprints.count == 1)
        printer.reprints[0](.success(Data()))
        if case .failure(MarkdownRenderError.emptyDocument) = result {} else {
            Issue.record("Repeated empty output must fail rather than loop")
        }
        #expect(printer.html.count == 1 && printer.reprints.count == 1)
    }

    @Test("Cancelled idle teardown and watchdog work cannot tear down the next job")
    func staleTimersAreIgnored() throws {
        let (queue, printer, clock) = harness()
        queue.render(html: "first", baseURL: nil, key: "a", layout: .pages) { _ in }
        printer.completions[0](.success(printer.data))
        queue.releaseIfIdle()
        var completed = false
        queue.render(html: "second", baseURL: nil, key: "b", layout: .pages) { _ in completed = true }
        try clock.fire(10)
        try clock.fire(30)
        #expect(printer.teardownCount == 0 && !completed)
        printer.completions[1](.success(printer.data))
        #expect(completed)
        queue.releaseIfIdle()
        try clock.fire(30)
        #expect(printer.teardownCount == 1)
    }
}
