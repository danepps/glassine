import GlassineCore
import PDFKit
import UIKit
import WebKit

/// Typesets HTML into a PDF with an offscreen `WKWebView` -- the iOS half of the
/// render pipeline. The queue, superseding, the watchdog, the one retry and the
/// idle teardown are `GlassineCore.RenderQueue`'s, exactly as on the Mac; this is
/// only the primitive it drives.
///
/// It is two primitives, in fact, because `NSPrintOperation` does not exist here
/// and the two layouts want different WebKit APIs (Spike B):
///
/// - **Pages** is `UIPrintPageRenderer` + `viewPrintFormatter()`, with
///   `paperRect` and `printableRect` set by KVC because they have no setters.
///   WebKit's 1.25 minimum shrink applies on iOS as well, but against the
///   *printable* width, so the content lays out at 468 x 1.25 = 585 CSS px and
///   prints at 0.8 pt per px. The web view is laid out at that width so the
///   JavaScript measurement sees what the print will do; the frame does not
///   affect the print itself.
/// - **Continuous** is `createPDF(configuration:)` at 1:1 -- no shrink, so the
///   measured height must *not* be divided by 1.25 -- on a web view sized
///   `612 x ceil(scrollHeight)`. **But CoreGraphics caps a PDF page at
///   14,400 pt and `createPDF` silently tiles past it**, slicing lines of text in
///   half at each seam, so past that height the job falls back to
///   `UIPrintPageRenderer` with 612 x 14,400 paper and zero margins: real page
///   breaks, no sliced lines, and the stylesheet's continuous `body { padding }`
///   still supplies the white space.
///
/// Only `createPDF` keeps the `glassine-outline://` link annotations. Every
/// `UIPrintPageRenderer` output has none at all, so the printer records what it
/// measured and which geometry it printed at, and `MarkdownRendererIOS` turns
/// that into the outline through `HeadingLocator`.
@MainActor
final class UIKitHTMLPrinter: NSObject, HTMLPrinter {

    /// US Letter at 72 dpi.
    static let paperSize = CGSize(width: 612, height: 792)
    /// One inch. Margins come from `printableRect`, never from an `@page` rule
    /// or `perPageContentInsets`: WebKit would apply both.
    static let margin: CGFloat = 72
    /// WebKit lays a printed page out 25% wider than the *printable* area and
    /// scales the result down (WebCore's minimum shrink factor).
    static let printShrinkFactor: CGFloat = 1.25
    /// CoreGraphics' hard ceiling on a page box.
    static let maxPageHeight: CGFloat = 14_400

    static var printableWidth: CGFloat { paperSize.width - 2 * margin }
    static var printableHeight: CGFloat { paperSize.height - 2 * margin }

    /// Where the outline positions of the render just delivered come from.
    enum OutlineSource {
        /// `createPDF` output: the `glassine-outline://` link annotations are in
        /// the PDF, so `applyOutline` reads them itself.
        case annotations
        /// `UIPrintPageRenderer` output: no annotations anywhere, so the
        /// measurement and the geometry it was printed at are the raw material
        /// for measure-then-snap.
        case measured([MeasuredHeading], HeadingLocator.Geometry)
    }

    /// Read by `MarkdownRendererIOS` inside the render's completion, which
    /// `RenderQueue` calls before it starts the next job.
    private(set) var outlineSource: OutlineSource = .annotations

    // MARK: State

    private var webView: WKWebView?
    /// The completion for the print in flight. Nil means nothing is expected and
    /// any callback that arrives anyway is dropped.
    private var pendingCompletion: ((Result<Data, Error>) -> Void)?
    private var pendingHTML: String?
    private var pendingBaseURL: URL?
    /// The load we are waiting for. Starting the next job's `loadHTMLString`
    /// cancels this one's navigation, whose failure callback then arrives and
    /// must not be charged to the job that displaced it.
    private var activeNavigation: WKNavigation?
    private var didRestartWebProcess = false
    private var wantsContinuous = false
    /// How the page that is currently loaded was pressed, so `reprint` can press
    /// it again without reloading or re-measuring.
    private var lastPress: Press?
    private var measured: [MeasuredHeading] = []

    private enum Press {
        /// `UIPrintPageRenderer`: Letter sheets, or the 14,400 pt fallback.
        case paginated(paper: CGSize, margin: CGFloat)
        /// `createPDF`: the whole document on one page as tall as its content.
        case wholePage(height: CGFloat)
    }

    // MARK: HTMLPrinter

    func print(html: String,
               baseURL: URL?,
               layout: MarkdownLayout,
               completion: @escaping (Result<Data, Error>) -> Void) {
        pendingCompletion = completion
        pendingHTML = html
        pendingBaseURL = baseURL
        wantsContinuous = (layout == .continuous)
        didRestartWebProcess = false
        lastPress = nil
        measured = []
        outlineSource = .annotations

        let view = makeWebView()
        // A paginated job is measured at the width WebKit will lay the print out
        // at; a continuous one is measured at the paper width, because
        // `createPDF` does not shrink.
        view.frame = wantsContinuous
            ? CGRect(x: 0, y: 0, width: Self.paperSize.width, height: 1000)
            : CGRect(x: 0, y: 0,
                     width: Self.printableWidth * Self.printShrinkFactor,
                     height: Self.printableHeight)
        activeNavigation = view.loadHTMLString(html, baseURL: baseURL)
    }

    func reprint(completion: @escaping (Result<Data, Error>) -> Void) {
        pendingCompletion = completion
        guard let lastPress else {
            deliver(.failure(MarkdownRenderError.printFailed))
            return
        }
        press(lastPress)
    }

    func teardown() {
        dropWebView()
        activeNavigation = nil
        pendingCompletion = nil
        pendingHTML = nil
        pendingBaseURL = nil
        lastPress = nil
    }

    // MARK: Web view

    /// WebKit lays out and prints reliably only from a window, as on the Mac --
    /// there a borderless window that is never ordered in, here the scene's own
    /// key window with the view at alpha 0 behind everything else.
    private func makeWebView() -> WKWebView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.shouldPrintBackgrounds = true
        configuration.suppressesIncrementalRendering = true

        let view = WKWebView(frame: CGRect(origin: .zero, size: Self.paperSize),
                             configuration: configuration)
        view.navigationDelegate = self
        view.alpha = 0
        view.isUserInteractionEnabled = false
        view.isOpaque = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        Self.host?.insertSubview(view, at: 0)

        webView = view
        return view
    }

    private static var host: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.keyWindow != nil })?.keyWindow
            ?? scenes.first?.windows.first
    }

    private func dropWebView() {
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    private func deliver(_ result: Result<Data, Error>) {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        activeNavigation = nil
        completion(result)
    }

    /// One run-loop turn, which is what a re-laid-out web view needs before it
    /// can be measured again.
    private func afterOneTurn(_ body: @escaping @Sendable @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }

    // MARK: Measurement

    /// `scrollHeight` and every `a.fh` anchor's top, in one evaluation. Page
    /// scripts are off and the CSP is `default-src 'none'`, but an evaluation in
    /// the *client* content world still runs -- the same fact the Mac's
    /// continuous measurement rests on.
    private static let measureJS = """
    (function () {
      var out = { height: document.documentElement.scrollHeight, headings: [] };
      var anchors = document.querySelectorAll('a.fh');
      for (var i = 0; i < anchors.length; i++) {
        var rect = anchors[i].getBoundingClientRect();
        out.headings.push({
          href: anchors[i].getAttribute('href') || '',
          text: (anchors[i].textContent || '').trim(),
          top: rect.top + window.scrollY
        });
      }
      return JSON.stringify(out);
    })()
    """

    private struct Measurement: Sendable {
        var height: CGFloat
        var headings: [MeasuredHeading]
    }

    private func measure(_ completion: @escaping @Sendable @MainActor (Measurement?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript(Self.measureJS, in: nil, in: .defaultClient) { result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result,
                      let json = (value as? String)?.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: json)
                        as? [String: Any]
                else {
                    completion(nil)
                    return
                }
                let raw = (object["headings"] as? [[String: Any]]) ?? []
                let headings: [MeasuredHeading] = raw.enumerated().map { position, entry in
                    let href = (entry["href"] as? String) ?? ""
                    let index = Int(href.replacingOccurrences(
                        of: "glassine-outline://", with: "")) ?? position
                    return MeasuredHeading(
                        index: index,
                        title: (entry["text"] as? String) ?? "",
                        top: CGFloat((entry["top"] as? NSNumber)?.doubleValue ?? 0))
                }
                completion(Measurement(
                    height: CGFloat((object["height"] as? NSNumber)?.doubleValue ?? 0),
                    headings: headings))
            }
        }
    }

    // MARK: Printing

    private func printLoadedPage() {
        guard pendingCompletion != nil else { return }
        measure { [weak self] measurement in
            guard let self, self.pendingCompletion != nil else { return }
            guard let measurement else {
                self.deliver(.failure(MarkdownRenderError.printFailed))
                return
            }
            self.measured = measurement.headings
            guard self.wantsContinuous else {
                self.press(.paginated(paper: Self.paperSize, margin: Self.margin))
                return
            }
            self.sizeForContinuous(measurement.height)
        }
    }

    /// Measure, resize, let one run-loop turn pass, measure again -- then decide
    /// between one tall page and the paginated fallback.
    private func sizeForContinuous(_ firstHeight: CGFloat) {
        guard let webView else { return }
        webView.frame = CGRect(x: 0, y: 0,
                               width: Self.paperSize.width, height: ceil(firstHeight))
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        afterOneTurn { [weak self] in
            guard let self, self.pendingCompletion != nil else { return }
            self.measure { [weak self] measurement in
                guard let self, self.pendingCompletion != nil,
                      let measurement else { return }
                self.measured = measurement.headings
                let height = ceil(measurement.height)
                guard height > Self.maxPageHeight else {
                    self.webView?.frame = CGRect(x: 0, y: 0,
                                                 width: Self.paperSize.width, height: height)
                    self.afterOneTurn { [weak self] in self?.press(.wholePage(height: height)) }
                    return
                }
                self.paginateTallPages()
            }
        }
    }

    /// Past CoreGraphics' 14,400 pt ceiling. The paper is 612 x 14,400 with no
    /// margins, so the printable width is the whole sheet and WebKit lays the
    /// content out at 612 x 1.25 = 765 CSS px -- a different measuring width from
    /// the continuous route, so the headings are measured again there.
    private func paginateTallPages() {
        guard let webView else { return }
        webView.frame = CGRect(x: 0, y: 0,
                               width: Self.paperSize.width * Self.printShrinkFactor,
                               height: Self.maxPageHeight)
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        afterOneTurn { [weak self] in
            guard let self, self.pendingCompletion != nil else { return }
            self.measure { [weak self] measurement in
                guard let self, self.pendingCompletion != nil else { return }
                if let measurement { self.measured = measurement.headings }
                self.press(.paginated(
                    paper: CGSize(width: Self.paperSize.width, height: Self.maxPageHeight),
                    margin: 0))
            }
        }
    }

    private func press(_ mode: Press) {
        lastPress = mode
        switch mode {
        case .paginated(let paper, let margin):
            outlineSource = .measured(
                measured,
                HeadingLocator.Geometry(pageHeight: paper.height,
                                        margin: margin,
                                        scale: 1 / Self.printShrinkFactor))
            deliver(.success(drawPaginated(paper: paper, margin: margin)))
        case .wholePage(let height):
            // `createPDF` keeps the link annotations, so the Mac's outline path
            // works here untouched.
            outlineSource = .annotations
            createTallPage(height: height)
        }
    }

    private func drawPaginated(paper size: CGSize, margin: CGFloat) -> Data {
        guard let webView else { return Data() }
        let renderer = UIPrintPageRenderer()
        let formatter = webView.viewPrintFormatter()
        // The margins are the printable rect's; without this the formatter adds
        // a second set of its own.
        formatter.perPageContentInsets = .zero
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        let paper = CGRect(origin: .zero, size: size)
        let printable = margin > 0 ? paper.insetBy(dx: margin, dy: margin) : paper
        // No public setter for either; KVC is the only route.
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")

        let pages = renderer.numberOfPages
        let output = NSMutableData()
        UIGraphicsBeginPDFContextToData(output, paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for index in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        // Empty data is the queue's cue that the press produced nothing
        // readable; it retries once through `reprint`.
        return output as Data
    }

    private func createTallPage(height: CGFloat) {
        guard let webView else {
            deliver(.failure(MarkdownRenderError.printFailed))
            return
        }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: Self.paperSize.width, height: height)
        webView.createPDF(configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch result {
                case .success(let data): self.deliver(.success(data))
                case .failure(let error): self.deliver(.failure(error))
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension UIKitHTMLPrinter: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        // One run-loop turn for WebKit to settle its layout before measuring.
        afterOneTurn { [weak self] in self?.printLoadedPage() }
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
        let view = makeWebView()
        view.frame = wantsContinuous
            ? CGRect(x: 0, y: 0, width: Self.paperSize.width, height: 1000)
            : CGRect(x: 0, y: 0,
                     width: Self.printableWidth * Self.printShrinkFactor,
                     height: Self.printableHeight)
        activeNavigation = view.loadHTMLString(html, baseURL: pendingBaseURL)
    }
}

/// The app-wide Markdown typesetter: `RenderQueue` driving the UIKit printer,
/// plus the outline step, which on iOS is not the same on both routes.
///
/// The Mac's shell only forwards, because `applyOutline` can always read link
/// annotations there. Here a paginated render has no annotations at all, so the
/// outline is applied *inside* the render -- before the caller's completion runs,
/// while the printer's record of what it measured still belongs to this job.
@MainActor
final class MarkdownRendererIOS {

    static let shared = MarkdownRendererIOS()

    private let printer = UIKitHTMLPrinter()
    private lazy var queue = RenderQueue(printer: printer)

    private init() {}

    /// Render `html` and give the result its outline. `key` identifies the
    /// document: queuing a second job with the same key drops the first (its
    /// completion gets `.superseded`).
    func render(html: String,
                baseURL: URL?,
                key: String,
                layout: MarkdownLayout,
                headings: [MarkdownHeading],
                completion: @escaping (Result<RenderedMarkdown, Error>) -> Void) {
        queue.render(html: html, baseURL: baseURL, key: key, layout: layout) {
            [weak self] result in
            guard let self else {
                completion(result)
                return
            }
            if case .success(let rendered) = result {
                self.applyOutline(headings, to: rendered.document)
            }
            completion(result)
        }
    }

    /// True when the render just delivered came off a print renderer, which
    /// leaves a clipped ghost copy of every carried-over heading below the
    /// printable band. The reader filters those out of its find results.
    private(set) var lastOutputGhostBand: (pageHeight: CGFloat, margin: CGFloat)?

    private func applyOutline(_ headings: [MarkdownHeading], to document: PDFDocument) {
        switch printer.outlineSource {
        case .annotations:
            lastOutputGhostBand = nil
            MarkdownDocumentModel.applyOutline(headings, to: document)
        case .measured(let measured, let geometry):
            lastOutputGhostBand = (geometry.pageHeight, geometry.margin)
            // The measurement's own anchor text is discarded in favour of the
            // heading list's title: they say the same thing, and the list is
            // what `applyOutline` will label the bookmarks with, so a mismatch
            // between what is searched for and what is shown is impossible.
            let titles = Dictionary(headings.map { ($0.index, $0.title) },
                                    uniquingKeysWith: { first, _ in first })
            let named = measured.map {
                MeasuredHeading(index: $0.index,
                                title: titles[$0.index] ?? $0.title,
                                top: $0.top)
            }
            MarkdownDocumentModel.applyOutline(
                headings, to: document,
                located: HeadingLocator.located(named, in: document, geometry: geometry))
            if geometry.margin == 0 { Self.trimTrailingBlank(of: document) }
        }
    }

    /// The tall-page fallback's last sheet is a whole 14,400 pt however little
    /// of it the document needed -- measured, 12,722 pt of blank under the end of
    /// a six-part memo, which is a third of the scrollable range and reads as the
    /// document having stopped working. `UIPrintPageRenderer` has no way to ask
    /// for a short last page, so the page is *cropped* to what it drew.
    ///
    /// The crop box only, never the media box: PDFView lays out on the crop box
    /// and `OutlineSync` measures with it, while `applyOutline` and
    /// `HeadingLocator` work in media-box coordinates that must not move under
    /// the destinations just written into the outline.
    private static func trimTrailingBlank(of document: PDFDocument) {
        guard document.pageCount > 1,
              let last = document.page(at: document.pageCount - 1) else { return }
        let box = last.bounds(for: .mediaBox)
        guard let text = last.selection(for: box) else { return }
        var bottom = CGFloat.greatestFiniteMagnitude
        for line in text.selectionsByLine() {
            let bounds = line.bounds(for: last)
            guard bounds.height > 0, bounds.width > 0 else { continue }
            bottom = min(bottom, bounds.minY)
        }
        guard bottom < CGFloat.greatestFiniteMagnitude else { return }
        // The stylesheet's own inch of trailing white space, kept.
        let used = min(box.maxY - bottom + 77, box.height)
        guard used < box.height - 100 else { return }
        last.setBounds(CGRect(x: box.minX, y: box.maxY - used,
                              width: box.width, height: used),
                       for: .cropBox)
    }

    /// Tear the web view down once nothing has needed it for a while: a
    /// WebContent process costs 60-120 MB and a Markdown-free session should not
    /// pay for it.
    func releaseIfIdle() {
        queue.releaseIfIdle()
    }
}
