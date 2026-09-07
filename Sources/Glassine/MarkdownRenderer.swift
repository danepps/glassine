import AppKit
import GlassineCore
import PDFKit
import WebKit

/// Typesets HTML into a paginated PDF with an offscreen WKWebView -- the Mac's
/// half of the render pipeline. The queue, superseding, the watchdog, the one
/// retry and the idle teardown live in `GlassineCore.RenderQueue`; this is only
/// the primitive it drives.
///
/// Nothing on screen is ever a web view: the view lives in a borderless window
/// that is never ordered in, and its only job is to run WebKit's print path,
/// which is what gives us real page breaks, selectable text, and link
/// annotations.
@MainActor
final class WebKitHTMLPrinter: NSObject, HTMLPrinter {

    /// US Letter at 72 dpi.
    static let paperSize = NSSize(width: 612, height: 792)
    /// One inch. Margins come from NSPrintInfo, never from an `@page` rule:
    /// WebKit subtracts the print info's margins itself and would double them.
    private static let margin: CGFloat = 72
    /// WebKit lays a printed page out 25% wider than the paper and scales the
    /// result down to fit (WebCore's minimum shrink factor), so a measurement
    /// only matches the print if the web view is that much wider too -- and the
    /// height it reports has to be scaled back down by the same amount.
    private static let printShrinkFactor: CGFloat = 1.25

    private var webView: WKWebView?
    private var hostWindow: NSWindow?

    private var outputURL: URL?
    /// The completion for the print in flight. Nil means nothing is expected,
    /// and any callback that arrives anyway is dropped.
    private var pendingCompletion: ((Swift.Result<Data, Error>) -> Void)?
    private var pendingHTML: String?
    private var pendingBaseURL: URL?
    /// The operation whose completion we are waiting for. A callback from any
    /// other (say, one the watchdog already gave up on) is ignored rather than
    /// being credited to whatever job is current by then.
    private var activeOperation: NSPrintOperation?
    /// The load we are waiting for, for the same reason: cancelling a navigation
    /// to start the next job makes the old one report failure, and that failure
    /// must not be charged to the job that displaced it.
    private var activeNavigation: WKNavigation?
    private var didRestartWebProcess = false
    /// True while the job in flight wants one very tall page.
    private var wantsContinuous = false
    /// The measured height of a continuous job's content, in points; nil for a
    /// paginated job, and also when the measurement failed and the job has to
    /// fall back to Letter pages.
    private var continuousHeight: CGFloat?

    override init() { super.init() }

    // MARK: HTMLPrinter

    func print(html: String,
               baseURL: URL?,
               layout: MarkdownLayout,
               completion: @escaping (Swift.Result<Data, Error>) -> Void) {
        pendingCompletion = completion
        pendingHTML = html
        pendingBaseURL = baseURL
        wantsContinuous = (layout == .continuous)
        didRestartWebProcess = false
        continuousHeight = nil
        let view = makeWebView()
        // Lay a continuous job out at the width WebKit will print it at, so its
        // measured height is the printed height; a paginated job is never
        // measured and its frame does not matter.
        view.frame.size.width = wantsContinuous
            ? Self.paperSize.width * Self.printShrinkFactor
            : Self.paperSize.width
        activeNavigation = view.loadHTMLString(html, baseURL: baseURL)
    }

    func reprint(completion: @escaping (Swift.Result<Data, Error>) -> Void) {
        pendingCompletion = completion
        printLoadedPage()
    }

    func teardown() {
        dropWebView()
        activeOperation = nil
        activeNavigation = nil
        pendingCompletion = nil
        pendingHTML = nil
        pendingBaseURL = nil
        discardOutput()
    }

    // MARK: Web view

    private func makeWebView() -> WKWebView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.shouldPrintBackgrounds = true
        configuration.suppressesIncrementalRendering = true

        let frame = NSRect(origin: .zero, size: Self.paperSize)
        let view = WKWebView(frame: frame, configuration: configuration)
        view.navigationDelegate = self

        // WebKit lays out and prints reliably only from a window. This one is
        // borderless, never ordered in, and never released.
        let window = NSWindow(contentRect: frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view

        webView = view
        hostWindow = window
        return view
    }

    private func dropWebView() {
        webView?.navigationDelegate = nil
        hostWindow?.contentView = nil
        webView = nil
        hostWindow = nil
    }

    private func discardOutput() {
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
            outputURL = nil
        }
    }

    private func deliver(_ result: Swift.Result<Data, Error>) {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        activeOperation = nil
        activeNavigation = nil
        completion(result)
    }

    // MARK: Printing

    /// A continuous job needs its content measured before it can be printed;
    /// everything else goes straight to the press.
    private func printWhenMeasured() {
        guard pendingCompletion != nil else { return }
        guard wantsContinuous else {
            printLoadedPage()
            return
        }
        measureContentHeight { [weak self] height in
            guard let self, self.pendingCompletion != nil else { return }
            self.continuousHeight = height
            self.printLoadedPage()
        }
    }

    /// The document's laid-out height. Page scripts are disabled and the CSP
    /// blocks them anyway, but an evaluation in the client content world still
    /// runs; if it ever stops, `nil` falls back to ordinary Letter pages.
    private func measureContentHeight(_ completion: @escaping @MainActor (CGFloat?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript("document.documentElement.scrollHeight",
                                   in: nil,
                                   in: .defaultClient) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let value):
                    completion((value as? NSNumber).map {
                        CGFloat($0.doubleValue) / Self.printShrinkFactor
                    })
                case .failure:
                    completion(nil)
                }
            }
        }
    }

    private func printLoadedPage() {
        guard pendingCompletion != nil, let webView, let hostWindow else { return }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassine-md-\(UUID().uuidString).pdf")
        outputURL = output

        // One tall page instead of many: the paper is exactly as tall as the
        // content (plus a hair, so a rounding error cannot spill onto a second
        // page) and the margins are zero, because in this mode the stylesheet
        // pads the body instead.
        let continuous = continuousHeight.map {
            NSSize(width: Self.paperSize.width, height: ceil($0) + 2)
        }
        let paper = continuous ?? Self.paperSize
        let margin = continuous == nil ? Self.margin : 0

        // A fresh NSPrintInfo, never NSPrintInfo.shared: that one belongs to the
        // user's Print… panel and mutating it would leak these settings into it.
        let info = NSPrintInfo(dictionary: [:])
        if continuous == nil { info.paperName = NSPrinter.PaperName("na-letter") }
        info.paperSize = paper
        info.orientation = .portrait
        info.scalingFactor = 1
        info.leftMargin = margin
        info.rightMargin = margin
        info.topMargin = margin
        info.bottomMargin = margin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = false

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WKPrintingView computes its page range only on a secondary print
        // thread; on the main thread it returns an open-ended range and never
        // finishes. run() never spawns that thread, runModal(for:...) does --
        // this is the whole reason for the sheet-shaped API below.
        operation.canSpawnSeparateThread = true
        operation.view?.frame = NSRect(origin: .zero, size: paper)
        activeOperation = operation

        operation.runModal(for: hostWindow,
                           delegate: self,
                           didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: nil)
    }

    /// AppKit runs the operation on a secondary print thread -- that is the
    /// whole point of `canSpawnSeparateThread` -- and calls this back *on that
    /// thread*. Everything downstream (installing a PDFDocument into a PDFView,
    /// posting notifications) is main-thread work, so hop first.
    @objc private nonisolated func printOperationDidRun(_ operation: NSPrintOperation,
                                                        success: Bool,
                                                        contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.printDidRun(operation, success: success) }
        }
    }

    private func printDidRun(_ operation: NSPrintOperation, success: Bool) {
        guard pendingCompletion != nil, operation === activeOperation else { return }
        guard success, let url = outputURL else {
            discardOutput()
            deliver(.failure(MarkdownRenderError.printFailed))
            return
        }
        let data = try? Data(contentsOf: url)
        discardOutput()
        // Empty data is the queue's cue that the print produced nothing
        // readable, which is the same case as a PDF with no pages: it retries
        // once through `reprint`.
        deliver(.success(data ?? Data()))
    }
}

// MARK: - WKNavigationDelegate

extension WebKitHTMLPrinter: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        // Give WebKit one run-loop turn to settle its layout before printing.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.printWhenMeasured() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === activeNavigation else { return }
        deliver(.failure(error))
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard navigation === activeNavigation else { return }
        deliver(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        dropWebView()
        guard let html = pendingHTML, pendingCompletion != nil, !didRestartWebProcess else {
            deliver(.failure(MarkdownRenderError.printFailed))
            return
        }
        didRestartWebProcess = true
        activeNavigation = makeWebView().loadHTMLString(html, baseURL: pendingBaseURL)
    }
}

/// The app-wide Markdown typesetter: `RenderQueue` driving the WebKit printer.
/// A thin shell so every call site reads exactly as it did before the queue
/// moved into Core.
@MainActor
final class MarkdownRenderer: MarkdownTypesetter {

    static let shared = MarkdownRenderer()

    private let queue = RenderQueue(printer: WebKitHTMLPrinter())

    private init() {}

    /// Render `html` into a PDF. `key` identifies the document: queuing a second
    /// job with the same key drops the first (its completion gets `.superseded`).
    func render(html: String,
                baseURL: URL?,
                key: String,
                layout: MarkdownLayout,
                completion: @escaping (Swift.Result<RenderedMarkdown, Error>) -> Void) {
        queue.render(html: html, baseURL: baseURL, key: key, layout: layout,
                     completion: completion)
    }

    /// Tear the web view down once nothing has needed it for a while: the
    /// WebContent process costs 60-120 MB and a Markdown-free session should
    /// not pay for it.
    func releaseIfIdle() {
        queue.releaseIfIdle()
    }
}
