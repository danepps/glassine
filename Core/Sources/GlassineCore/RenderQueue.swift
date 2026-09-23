import Foundation
import PDFKit

/// Errors the Markdown render pipeline can report.
public enum MarkdownRenderError: LocalizedError {
    /// A newer render of the same document replaced this one before it started.
    case superseded
    case timedOut
    case printFailed
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .superseded: return "The render was replaced by a newer one."
        case .timedOut: return "Typesetting the Markdown timed out."
        case .printFailed: return "Typesetting the Markdown failed."
        case .emptyDocument: return "Typesetting the Markdown produced no pages."
        }
    }
}

/// The one primitive a platform has to supply: turn HTML into PDF bytes.
///
/// Everything around it -- the queue, superseding, the watchdog, the retry, the
/// idle teardown -- is in `RenderQueue`, because none of it is platform work.
@MainActor
public protocol HTMLPrinter: AnyObject {
    /// Load `html` and, once it has laid out, print it. A `.continuous` job is
    /// measured after the load and printed onto a single page as tall as its
    /// content.
    ///
    /// An **empty** `Data` on success means the print reported success but left
    /// nothing readable behind; `RenderQueue` treats that exactly like a PDF
    /// with no pages, and retries once.
    func print(html: String,
               baseURL: URL?,
               layout: MarkdownLayout,
               completion: @escaping (Result<Data, Error>) -> Void)

    /// Print the page that is *already loaded* again, without reloading it.
    /// This is the one retry after an empty document: WebKit occasionally
    /// produces nothing on the very first print of a freshly created web view,
    /// and a second press of the same loaded page fixes it.
    func reprint(completion: @escaping (Result<Data, Error>) -> Void)

    /// Let go of whatever is being held (a web view and its content process),
    /// abandoning any print in flight rather than letting the next job inherit
    /// it.
    func teardown()
}

/// Serial render queue with supersede-by-key, a watchdog, bounded recovery,
/// sleep suspension, and an idle teardown.
///
/// Jobs run one at a time; a newer job for the same document supersedes one
/// still waiting in the queue (the loser's completion gets `.superseded`).
/// A stuck load gets one retry with a fresh printer before reporting a timeout.
/// Suspending abandons the printer but keeps its job for a fresh start on wake.
/// The printer is torn down 30 s after the last job, because a WebContent
/// process costs 60-120 MB and a Markdown-free session should not pay for it.
@MainActor
public final class RenderQueue: MarkdownTypesetter {

    private static let timeout: TimeInterval = 10
    private static let idleTeardownDelay: TimeInterval = 30
    private static let retryDelay: TimeInterval = 0.2

    private struct Job {
        let key: String
        let html: String
        let baseURL: URL?
        let layout: MarkdownLayout
        let completion: (Result<RenderedMarkdown, Error>) -> Void
    }

    private let printer: HTMLPrinter
    private var queue: [Job] = []
    private var current: Job?
    private var watchdog: DispatchWorkItem?
    private var idleTeardown: DispatchWorkItem?
    private var didRetryPrint = false
    private var didRetryTimeout = false
    private var isSuspended = false
    /// Every asynchronous callback belongs to one attempt, including callbacks
    /// a printer delivers after teardown and delayed empty-document retries.
    private var attempt = 0
    private var idleGeneration = 0

    /// Tests advance the same watchdog/retry work without waiting on real time.
    package var schedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public init(printer: HTMLPrinter) {
        self.printer = printer
    }

    // MARK: API

    public func render(html: String,
                       baseURL: URL?,
                       key: String,
                       layout: MarkdownLayout,
                       completion: @escaping (Result<RenderedMarkdown, Error>) -> Void) {
        cancelIdleTeardown()

        if let index = queue.firstIndex(where: { $0.key == key }) {
            let dropped = queue.remove(at: index)
            dropped.completion(.failure(MarkdownRenderError.superseded))
        }
        queue.append(Job(key: key, html: html, baseURL: baseURL,
                         layout: layout, completion: completion))
        pump()
    }

    /// The platform calls this while the system, displays, or login session
    /// cannot render. No deadline or WebKit work is left running during sleep.
    public func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended {
            cancelIdleTeardown()
            invalidateAttempt()
            let interrupted = current
            current = nil
            printer.teardown()
            if let interrupted {
                // Prefer a save/style change already waiting for this file.
                if queue.contains(where: { $0.key == interrupted.key }) {
                    interrupted.completion(.failure(MarkdownRenderError.superseded))
                } else {
                    queue.insert(interrupted, at: 0)
                }
            }
        } else {
            pump()
        }
    }

    public func releaseIfIdle() {
        cancelIdleTeardown()
        let stamp = idleGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, stamp == self.idleGeneration,
                      self.current == nil, self.queue.isEmpty else { return }
                self.printer.teardown()
                self.idleTeardown = nil
            }
        }
        idleTeardown = work
        schedule(Self.idleTeardownDelay, work)
    }

    // MARK: Queue

    private func pump() {
        guard !isSuspended, current == nil, !queue.isEmpty else { return }
        current = queue.removeFirst()
        didRetryTimeout = false
        startCurrent()
    }

    private func startCurrent() {
        guard let job = current else { return }
        invalidateAttempt()
        let stamp = attempt
        didRetryPrint = false
        startWatchdog(for: stamp)
        printer.print(html: job.html, baseURL: job.baseURL, layout: job.layout) {
            [weak self] result in
            self?.handlePrinted(result, attempt: stamp)
        }
    }

    private func invalidateAttempt() {
        attempt &+= 1
        watchdog?.cancel()
        watchdog = nil
    }

    private func cancelIdleTeardown() {
        idleGeneration &+= 1
        idleTeardown?.cancel()
        idleTeardown = nil
    }

    private func startWatchdog(for stamp: Int) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.current != nil, stamp == self.attempt else { return }
                self.invalidateAttempt()
                self.printer.teardown()
                if !self.didRetryTimeout {
                    self.didRetryTimeout = true
                    self.startCurrent()
                } else {
                    self.finish(.failure(MarkdownRenderError.timedOut))
                }
            }
        }
        watchdog = work
        schedule(Self.timeout, work)
    }

    private func handlePrinted(_ result: Result<Data, Error>, attempt stamp: Int) {
        guard current != nil, stamp == attempt else { return }
        switch result {
        case .failure(let error):
            finish(.failure(error))
        case .success(let data):
            guard let document = PDFDocument(data: data), document.pageCount > 0 else {
                // WebKit occasionally lands here on the very first print of a
                // freshly created web view; one retry a beat later fixes it.
                if !didRetryPrint {
                    didRetryPrint = true
                    let retry = DispatchWorkItem {
                        [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.current != nil, stamp == self.attempt else { return }
                            self.printer.reprint { [weak self] retry in
                                self?.handlePrinted(retry, attempt: stamp)
                            }
                        }
                    }
                    schedule(Self.retryDelay, retry)
                    return
                }
                finish(.failure(MarkdownRenderError.emptyDocument))
                return
            }
            finish(.success(RenderedMarkdown(data: data, document: document)))
        }
    }

    private func finish(_ result: Result<RenderedMarkdown, Error>) {
        invalidateAttempt()
        guard let job = current else { return }
        current = nil
        job.completion(result)
        pump()
    }
}
