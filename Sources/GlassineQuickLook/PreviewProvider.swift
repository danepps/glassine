import Foundation
import GlassineCore
import QuickLookUI
import UniformTypeIdentifiers

/// Quick Look owns the window, scrolling, selection and WebKit process. Return
/// self-contained HTML instead of running the reader's PDF printing pipeline.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        return QLPreviewReply(dataOfContentType: .html,
                              contentSize: CGSize(width: 760, height: 860)) { reply in
            reply.stringEncoding = .utf8
            return try MarkdownPreview.html(for: url)
        }
    }
}
