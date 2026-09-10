import Foundation
import PDFKit

/// Receives find results from the PDFDocument delegate.
///
/// PDFKit's end-of-find notification names the document it came from, and a
/// document that has since been replaced can still report the end of the search
/// it was cancelled out of. `findDidEnd(in:)` carries that identity; the default
/// implementation forwards to the identity-free `findDidEnd()`, so a platform
/// shell that has nothing better to pass keeps working unchanged.
@MainActor
public protocol FindSink: AnyObject {
    func findDidMatch(_ selection: PDFSelection)
    func findDidEnd()
    func findDidEnd(in document: PDFDocument)
}

extension FindSink {
    public func findDidEnd(in document: PDFDocument) { findDidEnd() }
}

/// What a `FindController` needs from whatever is showing the document. Every
/// method is called on the main actor, synchronously, at exactly the point the
/// window controller used to do the work itself.
@MainActor
public protocol FindControllerDelegate: AnyObject {
    /// Drop every trace of the previous search from the view: the highlight
    /// arrays, PDFKit's `highlightedSelections`, and its *current selection* --
    /// in light mode the current match is PDFKit's own selection, and nothing
    /// else ever clears it.
    func findControllerDidClear(_ controller: FindController)

    /// The match set (or the current index) changed: re-apply the highlights.
    func findController(_ controller: FindController,
                        didUpdate matches: [PDFSelection],
                        current: Int,
                        inProgress: Bool)

    /// Scroll to `selection` and mark it as the current match.
    func findController(_ controller: FindController,
                        show selection: PDFSelection,
                        at index: Int)

    /// Whether stepping through matches is possible right now.
    func findController(_ controller: FindController, canStep: Bool)

    /// `countText` changed.
    func findControllerCountDidChange(_ controller: FindController)
}

/// Incremental find over a `PDFDocument`, and the small state machine that makes
/// replacing a running search safe.
///
/// PDFKit delivers find callbacks asynchronously and does not tag them with the
/// query, so a search cancelled mid-flight can still report matches (and its
/// end) after a replacement has begun. The old search is cancelled,
/// `isAwaitingCancelledFindEnd` drops its stragglers, and the new query starts
/// from the old search's end callback -- or from a 0.5 s fallback timer, in case
/// PDFKit never reports the end of a cancelled search.
///
/// Three identities keep that machine honest. An edit made *while* a
/// cancellation is pending replaces the queued query rather than starting a
/// second one, an empty query included, so clearing the field cannot leave a
/// search to come back to life when the end finally arrives. The fallback timer
/// carries a token, so one armed for an earlier cancellation cannot fire into a
/// later wait. And both callbacks are checked against `document`: a Markdown
/// reload can replace the PDF mid-search, and the old document's stragglers name
/// pages the view no longer has.
@MainActor
public final class FindController: FindSink {

    public weak var delegate: FindControllerDelegate?
    /// The document being searched. Held weakly: the window controller owns it,
    /// and a Markdown reload replaces it underneath us.
    public weak var document: PDFDocument?

    public private(set) var matches: [PDFSelection] = []
    public private(set) var matchIndex = 0
    public private(set) var findInProgress = false
    public private(set) var lastQuery = ""

    /// The hit-count readout. Deliberately a stored property rather than
    /// something computed from the state above: the label is blank for the
    /// moment between starting a search and its first hit, and blank again
    /// while a document swap is in flight, and neither of those is expressible
    /// as a function of (query, matches, inProgress) alone.
    public private(set) var countText = ""

    /// Set while a cancelled PDFKit search is still winding down: its late
    /// callbacks are ignored, and `pendingQuery` starts when its end arrives.
    public private(set) var isAwaitingCancelledFindEnd = false
    /// The query waiting for the cancelled search to report its end.
    public private(set) var pendingQuery: String?
    /// Set while re-running a find after the document was swapped underneath us:
    /// the first match must not steal the reading position we just restored.
    private var suppressFirstMatchScroll = false
    private var highlightRefreshPending = false
    /// Identifies one wait for a cancelled search's end. The 0.5 s fallback
    /// timer captures it, so a timer armed for an earlier cancellation cannot
    /// fire into a later one that happens to be waiting when it comes due --
    /// which would start the replacement half a second early, or after a
    /// `reset(for:)` had already thrown the pending query away.
    private var cancellationToken = 0

    /// How long to wait for a cancelled search's end callback before starting
    /// the replacement anyway.
    private static let cancelledFindFallback: TimeInterval = 0.5
    /// Reassigning the highlight array per match is quadratic on large
    /// documents, so hits after the first are batched onto this.
    private static let highlightBatchDelay: TimeInterval = 0.15

    public init(document: PDFDocument? = nil) {
        self.document = document
    }

    // MARK: Starting and stopping

    /// The search field's action. `NSSearchField` sends it for every edit and
    /// again when editing ends -- a click into the document, say -- with the
    /// same text as before. Restarting the search for an unchanged query would
    /// scroll the reader back to the first match; so an unchanged query is a
    /// no-op, and only a different one starts a find. Returns whether it did.
    @discardableResult
    public func search(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // While a cancellation is pending the effective query is the pending
        // one, not the search being cancelled.
        let current = isAwaitingCancelledFindEnd ? (pendingQuery ?? lastQuery) : lastQuery
        guard trimmed != current else { return false }
        startFind(trimmed)
        return true
    }

    public func startFind(_ query: String, suppressFirstScroll: Bool = false) {
        suppressFirstMatchScroll = suppressFirstScroll
        matches.removeAll()
        matchIndex = 0
        delegate?.findController(self, canStep: false)
        delegate?.findControllerDidClear(self)

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = trimmed
        findInProgress = !trimmed.isEmpty
        setCountText("")

        // Already waiting for a cancelled search to report its end: this edit
        // *replaces* whatever was queued behind it, an empty query included.
        // Falling through to `beginFind("")` instead would leave the stale
        // pending query to start when the end finally arrived -- the search the
        // reader had just cleared coming back to life on its own.
        if isAwaitingCancelledFindEnd {
            pendingQuery = trimmed
            return
        }

        if let pdf = document, pdf.isFinding {
            pdf.cancelFindString()
            pendingQuery = trimmed
            isAwaitingCancelledFindEnd = true
            armCancellationFallback()
            return
        }
        beginFind(trimmed)
    }

    /// Start the pending query anyway if PDFKit never reports the cancelled
    /// search's end. One timer per cancellation, identified by a token: it
    /// starts whatever is pending when it fires, and an empty pending query
    /// starts nothing.
    private func armCancellationFallback() {
        cancellationToken &+= 1
        let token = cancellationToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cancelledFindFallback) {
            [weak self] in
            guard let self, self.isAwaitingCancelledFindEnd,
                  self.cancellationToken == token else { return }
            self.isAwaitingCancelledFindEnd = false
            self.startPendingFind()
        }
    }

    private func beginFind(_ trimmed: String) {
        findInProgress = !trimmed.isEmpty
        guard !trimmed.isEmpty, let pdf = document else { return }
        pdf.beginFindString(trimmed, withOptions: [.caseInsensitive])
    }

    private func startPendingFind() {
        guard let query = pendingQuery else { return }
        pendingQuery = nil
        beginFind(query)
    }

    /// Cancel whatever is running, without touching the query or the view. The
    /// window's close handler calls this.
    public func cancelIfFinding() {
        if let pdf = document, pdf.isFinding { pdf.cancelFindString() }
    }

    /// A new document is taking the old one's place. Every `PDFSelection` we
    /// hold points into the document about to go away, so the whole match set
    /// goes with it -- but `lastQuery` stays, because the search is re-run
    /// against the replacement once it is installed.
    public func reset(for replacement: PDFDocument?) {
        if let old = document, old !== replacement, old.isFinding { old.cancelFindString() }
        matches.removeAll()
        matchIndex = 0
        findInProgress = false
        isAwaitingCancelledFindEnd = false
        pendingQuery = nil
        // Any fallback timer still in the air belongs to a wait this reset has
        // just ended; retire its token so it cannot fire into the next one.
        cancellationToken &+= 1
        document = replacement
        delegate?.findControllerDidClear(self)
        delegate?.findController(self, canStep: false)
        setCountText("")
    }

    // MARK: FindSink

    public func findDidMatch(_ selection: PDFSelection) {
        guard !isAwaitingCancelledFindEnd else { return }
        // A match found in a document that has since been replaced -- a Markdown
        // reload landing mid-search. Its pages are not in the document on
        // screen, so navigating to it would ask PDFView to show a page it does
        // not have.
        guard selection.pages.first?.document === document else { return }
        matches.append(selection)
        // Show the first hit immediately; the rest arrive asynchronously and
        // appear within ~150 ms of being found rather than only at the end.
        if matches.count == 1 {
            if suppressFirstMatchScroll {
                // Re-running the query after a reload: light the matches up but
                // stay where the reader was.
                suppressFirstMatchScroll = false
            } else {
                showMatch(0)
            }
            notifyMatchesChanged()
            // Stepping is useful as soon as there is something to step through;
            // it wraps over the results found so far.
            delegate?.findController(self, canStep: true)
        } else {
            scheduleHighlightRefresh()
        }
        setCountText("\(matches.count) found…")
    }

    /// The identified form. An end reported by anything but the document we are
    /// searching is a straggler from a replaced document and is dropped outright:
    /// it must neither finish the new search nor release the pending query.
    public func findDidEnd(in document: PDFDocument) {
        guard document === self.document else { return }
        findDidEnd()
    }

    public func findDidEnd() {
        if isAwaitingCancelledFindEnd {
            isAwaitingCancelledFindEnd = false
            startPendingFind()
            return
        }
        findInProgress = false
        notifyMatchesChanged()
        updateSearchCount()
    }

    private func scheduleHighlightRefresh() {
        guard !highlightRefreshPending else { return }
        highlightRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightBatchDelay) { [weak self] in
            guard let self else { return }
            self.highlightRefreshPending = false
            // findDidEnd has already applied the final set if the search is over.
            if self.findInProgress { self.notifyMatchesChanged() }
        }
    }

    // MARK: Stepping

    /// Move `delta` matches, wrapping. With no matches it restarts the search
    /// for `query`; returns false when the query has already been searched for
    /// and came up empty, which is the caller's cue to beep.
    @discardableResult
    public func step(by delta: Int, query: String) -> Bool {
        guard matches.isEmpty else {
            showMatch(matchIndex + delta)
            return true
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !findInProgress, !trimmed.isEmpty, trimmed == lastQuery {
            // Already searched for exactly this and came up empty.
            return false
        }
        startFind(trimmed)
        return true
    }

    public func showMatch(_ index: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        matchIndex = ((index % count) + count) % count
        delegate?.findController(self, show: matches[matchIndex], at: matchIndex)
        if !findInProgress { updateSearchCount() }
    }

    // MARK: Readout

    /// "K of N" once a search has finished, "No matches" when it found nothing,
    /// blank when there is no query. Left alone while a search is still running
    /// -- `findDidMatch` shows the running total there.
    private func updateSearchCount() {
        delegate?.findController(self, canStep: !matches.isEmpty)
        guard !lastQuery.isEmpty else {
            setCountText("")
            return
        }
        if findInProgress {
            setCountText("\(matches.count) found…")
        } else if matches.isEmpty {
            setCountText("No matches")
        } else {
            setCountText("\(matchIndex + 1) of \(matches.count)")
        }
    }

    private func setCountText(_ text: String) {
        countText = text
        delegate?.findControllerCountDidChange(self)
    }

    private func notifyMatchesChanged() {
        delegate?.findController(self, didUpdate: matches, current: matchIndex,
                                 inProgress: findInProgress)
    }
}
