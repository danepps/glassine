import AppKit

/// Start quit review with each document's flush, before AppKit's aggregate
/// unsaved-documents alert. Successful writes close silently; a failed write
/// reaches the ordinary per-document Save / Don't Save / Cancel sheet.
///
/// The app delegate is told the quit has begun before the first document
/// closes, so the "show Recents when the last window goes" rule stays quiet
/// while documents are still flushing; a cancelled review turns it back on.
final class GlassineDocumentController: NSDocumentController {
    override func reviewUnsavedDocuments(withAlertTitle title: String?, cancellable: Bool,
        delegate: Any?, didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        (NSApp.delegate as? AppDelegate)?.isQuitting = true
        let relay = QuitReviewRelay(delegate: delegate as AnyObject?, selector: didReviewAllSelector)
        closeAllDocuments(withDelegate: relay,
                          didCloseAllSelector: #selector(QuitReviewRelay.controller(_:didCloseAll:contextInfo:)),
                          contextInfo: contextInfo)
    }
}

/// Sits between `closeAllDocuments` and whoever asked for the review, so a
/// cancelled quit can clear the delegate's flag before the answer goes back.
/// Keeps itself alive until the callback arrives; AppKit holds the delegate
/// only weakly.
private final class QuitReviewRelay: NSObject {
    private static var inFlight: Set<QuitReviewRelay> = []
    private let delegate: AnyObject?
    private let selector: Selector?

    init(delegate: AnyObject?, selector: Selector?) {
        self.delegate = delegate
        self.selector = selector
        super.init()
        Self.inFlight.insert(self)
    }

    @objc func controller(_ controller: NSDocumentController, didCloseAll: Bool,
                          contextInfo: UnsafeMutableRawPointer?) {
        Self.inFlight.remove(self)
        if !didCloseAll { (NSApp.delegate as? AppDelegate)?.isQuitting = false }
        guard let delegate, let selector, delegate.responds(to: selector),
              let method = delegate.method(for: selector) else { return }
        // AppKit's callback shape is `controller:didReviewAll:contextInfo:`; a
        // three-argument selector needs the IMP called directly.
        typealias Callback = @convention(c) (AnyObject, Selector, NSDocumentController, Bool,
                                             UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(method, to: Callback.self)(delegate, selector, controller, didCloseAll, contextInfo)
    }
}
