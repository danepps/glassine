import Foundation
import PDFKit
import Testing
@testable import GlassineCore

/// Stands in for the window controller: records what the controller asked for
/// and does nothing to any view.
@MainActor
final class FakeFindDelegate: FindControllerDelegate {
    var clears = 0
    var updates: [(count: Int, current: Int, inProgress: Bool)] = []
    var shown: [Int] = []
    var stepStates: [Bool] = []
    var counts: [String] = []

    func findControllerDidClear(_ controller: FindController) { clears += 1 }

    func findController(_ controller: FindController,
                        didUpdate matches: [PDFSelection],
                        current: Int,
                        inProgress: Bool) {
        updates.append((matches.count, current, inProgress))
    }

    func findController(_ controller: FindController,
                        show selection: PDFSelection,
                        at index: Int) {
        shown.append(index)
    }

    func findController(_ controller: FindController, canStep: Bool) {
        stepStates.append(canStep)
    }

    func findControllerCountDidChange(_ controller: FindController) {
        counts.append(controller.countText)
    }
}

/// The `PDFDocumentDelegate` half of `GlassineDocument`, so a real PDFKit search
/// reaches the controller the way it does in the app. `sink` can be detached to
/// simulate PDFKit never reporting the end of a cancelled search.
final class FindForwarder: NSObject, PDFDocumentDelegate {
    @MainActor var sink: FindSink?

    func didMatchString(_ instance: PDFSelection) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { sink?.findDidMatch(instance) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.sink?.findDidMatch(instance) }
            }
        }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        let source = notification.object as? PDFDocument
        if Thread.isMainThread {
            MainActor.assumeIsolated { deliver(source) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.deliver(source) }
            }
        }
    }

    @MainActor
    private func deliver(_ source: PDFDocument?) {
        guard let sink else { return }
        if let source { sink.findDidEnd(in: source) } else { sink.findDidEnd() }
    }
}

/// A `PDFDocument` whose asynchronous find is recorded instead of run, so the
/// cancellation state machine can be driven one callback at a time. Its pages
/// are real, so the selections handed to `findDidMatch` are real too.
final class ProbeDocument: PDFDocument {
    var started: [String] = []
    var cancelCount = 0
    private var finding = false

    override var isFinding: Bool { finding }

    override func beginFindString(_ string: String, withOptions options: NSString.CompareOptions) {
        started.append(string)
        finding = true
    }

    override func cancelFindString() {
        cancelCount += 1
        finding = false
    }

    /// A selection that really belongs to this document, for the identity checks.
    func firstMatch(_ text: String) -> PDFSelection {
        guard let selection = findString(text, withOptions: [.caseInsensitive]).first else {
            fatalError("the probe document does not contain \(text)")
        }
        return selection
    }
}

func makeProbeDocument() -> ProbeDocument {
    let data = makeTextPDFData(pages: (0..<3).map {
        "alpha beta gamma delta omega page \($0)"
    })
    guard let document = ProbeDocument(data: data) else {
        fatalError("could not read back the probe PDF")
    }
    return document
}

@MainActor
@Suite("FindController")
struct FindControllerTests {

    /// Six pages, four "alpha"s each: 24 hits, and "omega" appears once.
    private func makeDocument() -> PDFDocument {
        makeTextPDF(pages: (0..<6).map { page in
            "alpha beta alpha gamma alpha delta alpha page \(page)"
                + (page == 3 ? " omega" : "")
        })
    }

    private func settle(_ controller: FindController, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.findInProgress && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // One more turn, so the batched highlight refresh has run.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test("A query reports its matches and then ends")
    func findReportsMatchesThenEnd() async {
        let document = makeDocument()
        let forwarder = FindForwarder()
        document.delegate = forwarder
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate
        forwarder.sink = controller

        controller.startFind("alpha")
        #expect(controller.lastQuery == "alpha")
        #expect(controller.findInProgress)
        #expect(controller.countText == "")     // blank until the first hit
        await settle(controller)

        #expect(controller.matches.count == 24)
        #expect(controller.findInProgress == false)
        #expect(controller.matchIndex == 0)
        #expect(controller.countText == "1 of 24")
        #expect(delegate.shown.first == 0)      // the first hit is shown at once
        #expect(delegate.stepStates.contains(true))
        // The running total was on show while the search ran.
        #expect(delegate.counts.contains { $0.hasSuffix(" found…") })
    }

    @Test("The field's action with an unchanged query does not restart the search")
    func unchangedQueryIsANoOp() async {
        let document = makeDocument()
        let forwarder = FindForwarder()
        document.delegate = forwarder
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate
        forwarder.sink = controller

        #expect(controller.search("alpha"))
        await settle(controller)
        controller.showMatch(5)
        #expect(delegate.shown == [0, 5])

        // The reader clicks into the document: the field sends "alpha" again.
        #expect(controller.search("alpha") == false)
        #expect(controller.search("  alpha ") == false)
        #expect(controller.matchIndex == 5)
        #expect(delegate.shown == [0, 5])           // no jump back to the first match
        #expect(controller.matches.count == 24)     // and the matches are untouched

        // A different query still starts a search; so does clearing.
        #expect(controller.search("omega"))
        #expect(controller.lastQuery == "omega")
        await settle(controller)
        #expect(controller.search(""))
        #expect(controller.lastQuery == "")
        #expect(controller.search("") == false)
    }

    @Test("A query with no matches says so; an empty query says nothing")
    func noMatches() async {
        let document = makeDocument()
        let forwarder = FindForwarder()
        document.delegate = forwarder
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate
        forwarder.sink = controller

        controller.startFind("zzzznothing")
        await settle(controller)
        #expect(controller.matches.isEmpty)
        #expect(controller.countText == "No matches")
        #expect(delegate.stepStates.last == false)

        controller.startFind("")
        #expect(controller.lastQuery == "")
        #expect(controller.findInProgress == false)
        #expect(controller.countText == "")
    }

    @Test("Stepping wraps in both directions")
    func steppingWraps() async {
        let document = makeDocument()
        let forwarder = FindForwarder()
        document.delegate = forwarder
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate
        forwarder.sink = controller

        controller.startFind("alpha")
        await settle(controller)
        let count = controller.matches.count
        #expect(count == 24)

        #expect(controller.step(by: -1, query: "alpha"))
        #expect(controller.matchIndex == count - 1)
        #expect(controller.countText == "\(count) of \(count)")

        #expect(controller.step(by: 1, query: "alpha"))
        #expect(controller.matchIndex == 0)
        #expect(controller.countText == "1 of \(count)")

        #expect(controller.step(by: 3, query: "alpha"))
        #expect(controller.matchIndex == 3)
    }

    @Test("Stepping a query that already found nothing reports failure")
    func steppingWithNothingToStepTo() async {
        let document = makeDocument()
        let forwarder = FindForwarder()
        document.delegate = forwarder
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate
        forwarder.sink = controller

        controller.startFind("zzzznothing")
        await settle(controller)
        // Same query, already searched, no hits: nowhere to go -- the app beeps.
        #expect(controller.step(by: 1, query: "zzzznothing") == false)
        // A different query restarts the search instead.
        #expect(controller.step(by: 1, query: "omega"))
        await settle(controller)
        #expect(controller.matches.count == 1)
    }

    @Test("Replacing a running query drops the old search's stragglers")
    func stragglersAreDropped() async {
        let document = makeDocument()
        let forwarder = FindForwarder()
        document.delegate = forwarder
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate
        // Detached: PDFKit's own callbacks for the first search go nowhere, so
        // the state machine is driven by hand. The selections are taken before
        // the asynchronous find starts, and really belong to this document, so
        // the identity check in findDidMatch passes them.
        forwarder.sink = nil
        let hit = document.findString("alpha", withOptions: [.caseInsensitive])[0]
        let laterHit = document.findString("alpha", withOptions: [.caseInsensitive])[1]

        document.beginFindString("alpha", withOptions: [.caseInsensitive])
        #expect(document.isFinding)

        controller.startFind("omega")
        #expect(controller.isAwaitingCancelledFindEnd)
        #expect(controller.pendingQuery == "omega")
        #expect(controller.lastQuery == "omega")

        // A late hit from the cancelled search must not join the new results.
        controller.findDidMatch(hit)
        #expect(controller.matches.isEmpty)
        #expect(controller.countText == "")

        // The cancelled search's end starts the replacement, and hits are taken
        // again from that moment on.
        controller.findDidEnd()
        #expect(controller.isAwaitingCancelledFindEnd == false)
        #expect(controller.pendingQuery == nil)
        #expect(controller.findInProgress)
        controller.findDidMatch(laterHit)
        #expect(controller.matches.count == 1)
        #expect(controller.countText == "1 found…")
        #expect(delegate.shown == [0])

        document.cancelFindString()
    }

    @Test("The 0.5 s fallback starts the replacement when no end callback arrives")
    func fallbackTimerFires() async {
        let document = makeDocument()
        let forwarder = FindForwarder()
        document.delegate = forwarder
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate
        forwarder.sink = nil     // PDFKit's end callback never reaches us

        document.beginFindString("alpha", withOptions: [.caseInsensitive])
        controller.startFind("omega")
        #expect(controller.isAwaitingCancelledFindEnd)
        #expect(controller.pendingQuery == "omega")

        // Still waiting well before the fallback.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(controller.isAwaitingCancelledFindEnd)

        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(controller.isAwaitingCancelledFindEnd == false)
        #expect(controller.pendingQuery == nil)
    }

    @Test("A document swap clears the matches but keeps the query")
    func resetKeepsTheQuery() async {
        let document = makeDocument()
        let forwarder = FindForwarder()
        document.delegate = forwarder
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate
        forwarder.sink = controller

        controller.startFind("alpha")
        await settle(controller)
        #expect(!controller.matches.isEmpty)

        let replacement = makeDocument()
        controller.reset(for: replacement)
        #expect(controller.matches.isEmpty)
        #expect(controller.findInProgress == false)
        #expect(controller.countText == "")
        #expect(controller.lastQuery == "alpha")    // the re-run needs it
        #expect(controller.document === replacement)
        #expect(delegate.stepStates.last == false)
    }

    @Test("A re-run after a swap lights the matches up without scrolling")
    func suppressedFirstScroll() async {
        let document = makeDocument()
        let forwarder = FindForwarder()
        document.delegate = forwarder
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate
        forwarder.sink = controller

        controller.startFind("alpha", suppressFirstScroll: true)
        await settle(controller)
        #expect(controller.matches.count == 24)
        #expect(delegate.shown.isEmpty)             // never scrolled to a match
        #expect(controller.countText == "1 of 24")
    }

    // MARK: Cancellation, replaced documents and stale timers (BUG-002)

    @Test("Clearing the field during a pending cancellation clears the queue too")
    func clearingDuringCancellationDropsThePendingQuery() async {
        let document = makeProbeDocument()
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate

        controller.startFind("alpha")
        #expect(document.started == ["alpha"])

        // "beta" cancels "alpha" and queues itself behind its end callback.
        controller.startFind("beta")
        #expect(controller.isAwaitingCancelledFindEnd)
        #expect(controller.pendingQuery == "beta")
        #expect(document.cancelCount == 1)

        // The reader clears the field before that end arrives. isFinding is
        // already false, so the old code fell straight through to beginFind("")
        // and left "beta" queued.
        controller.startFind("")
        #expect(controller.pendingQuery == "")
        #expect(controller.lastQuery == "")
        #expect(controller.findInProgress == false)

        controller.findDidEnd(in: document)
        #expect(controller.isAwaitingCancelledFindEnd == false)
        #expect(controller.pendingQuery == nil)
        #expect(controller.findInProgress == false)
        #expect(controller.matches.isEmpty)
        #expect(controller.countText == "")
        // "beta" never ran.
        #expect(document.started == ["alpha"])
    }

    @Test("Repeated edits during a pending cancellation start only the last one")
    func onlyTheLastEditStarts() async {
        let document = makeProbeDocument()
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate

        controller.startFind("alpha")
        controller.startFind("be")
        controller.startFind("bet")
        controller.startFind("beta")
        #expect(controller.pendingQuery == "beta")
        // One cancellation, not one per edit: the search was already cancelled.
        #expect(document.cancelCount == 1)

        controller.findDidEnd(in: document)
        #expect(document.started == ["alpha", "beta"])
        #expect(controller.lastQuery == "beta")
        #expect(controller.findInProgress)
    }

    @Test("The fallback timer of a cancellation that was reset cannot fire into the next one")
    func staleFallbackTimerIsRetired() async {
        let document = makeProbeDocument()
        let replacement = makeProbeDocument()
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate

        controller.startFind("alpha")
        controller.startFind("beta")            // arms fallback #1, due in 0.5 s
        #expect(controller.isAwaitingCancelledFindEnd)

        // A Markdown reload swaps the document out from under the wait.
        controller.reset(for: replacement)
        #expect(controller.isAwaitingCancelledFindEnd == false)

        // 0.4 s in, a fresh search on the replacement is cancelled in its turn,
        // so the controller is waiting again when fallback #1 comes due.
        try? await Task.sleep(nanoseconds: 400_000_000)
        controller.startFind("gamma")
        controller.startFind("delta")           // arms fallback #2, due at 0.9 s
        #expect(controller.pendingQuery == "delta")

        // 0.6 s: fallback #1 has come and gone and must have done nothing.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(controller.isAwaitingCancelledFindEnd)
        #expect(controller.pendingQuery == "delta")
        #expect(replacement.started == ["gamma"])

        // 1.1 s: fallback #2, the one that belongs to this wait, has run.
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(controller.isAwaitingCancelledFindEnd == false)
        #expect(replacement.started == ["gamma", "delta"])
    }

    @Test("A match from a replaced document is dropped")
    func staleMatchIsDropped() async {
        let document = makeProbeDocument()
        let replacement = makeProbeDocument()
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate

        let staleHit = document.firstMatch("alpha")
        controller.startFind("alpha")
        controller.reset(for: replacement)
        controller.startFind("alpha")

        // The old document's search reports a hit after the swap.
        controller.findDidMatch(staleHit)
        #expect(controller.matches.isEmpty)
        #expect(delegate.shown.isEmpty)         // nothing asked the view to navigate

        // The replacement's own hit is taken.
        controller.findDidMatch(replacement.firstMatch("alpha"))
        #expect(controller.matches.count == 1)
        #expect(delegate.shown == [0])
    }

    @Test("An end from a replaced document does not finish the new search")
    func staleEndIsDropped() async {
        let document = makeProbeDocument()
        let replacement = makeProbeDocument()
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate

        controller.startFind("alpha")
        controller.reset(for: replacement)
        controller.startFind("alpha")
        #expect(controller.findInProgress)

        controller.findDidEnd(in: document)
        #expect(controller.findInProgress)      // still running against the new one
        #expect(controller.countText == "")

        controller.findDidEnd(in: replacement)
        #expect(controller.findInProgress == false)
        #expect(controller.countText == "No matches")
    }

    @Test("A stale end cannot release a pending query either")
    func staleEndDoesNotReleaseThePendingQuery() async {
        let document = makeProbeDocument()
        let other = makeProbeDocument()
        let controller = FindController(document: document)
        let delegate = FakeFindDelegate()
        controller.delegate = delegate

        controller.startFind("alpha")
        controller.startFind("beta")
        #expect(controller.isAwaitingCancelledFindEnd)

        controller.findDidEnd(in: other)
        #expect(controller.isAwaitingCancelledFindEnd)
        #expect(controller.pendingQuery == "beta")
        #expect(document.started == ["alpha"])

        controller.findDidEnd(in: document)
        #expect(document.started == ["alpha", "beta"])
    }
}
