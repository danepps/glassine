import AppKit

/// Start quit review with each document's flush, before AppKit's aggregate
/// unsaved-documents alert. Successful writes close silently; a failed write
/// reaches the ordinary per-document Save / Don't Save / Cancel sheet.
final class GlassineDocumentController: NSDocumentController {
    override func reviewUnsavedDocuments(withAlertTitle title: String?, cancellable: Bool,
        delegate: Any?, didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        closeAllDocuments(withDelegate: delegate, didCloseAllSelector: didReviewAllSelector,
                          contextInfo: contextInfo)
    }
}
