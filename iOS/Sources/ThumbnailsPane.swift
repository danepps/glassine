import GlassineCore
import PDFKit
import SwiftUI

/// Page thumbnails, filtered with the same chain as the reader so they match it
/// -- the Mac mirrors its CIFilters onto the sidebar for exactly this reason.
/// `PDFThumbnailView` keeps its own selection in step with the `PDFView` it is
/// bound to, so tapping one navigates and nothing here has to.
@MainActor
struct ThumbnailsPane: View {

    let session: DocumentSession
    let inverted: Bool
    let paper: DarkPaper

    var body: some View {
        // Reading the token is what makes this rebuild when the reader's view
        // appears (the reference itself is weak and cannot be observed).
        let _ = session.pdfViewToken
        Group {
            if let pdfView = session.pdfView {
                ThumbnailRepresentable(pdfView: pdfView)
                    .pageInversion(inverted, paper: paper)
            } else {
                Color.clear
            }
        }
        .accessibilityIdentifier("thumbnailsPane")
    }
}

private struct ThumbnailRepresentable: UIViewRepresentable {
    let pdfView: ReaderPDFView

    func makeUIView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = pdfView
        view.thumbnailSize = CGSize(width: 110, height: 150)
        view.layoutMode = .vertical
        // Clear, so the pane's own chrome colour shows through instead of a
        // slab of control background inside black.
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "thumbnailStrip"
        view.accessibilityLabel = "Page thumbnails"
        return view
    }

    func updateUIView(_ view: PDFThumbnailView, context: Context) {
        if view.pdfView !== pdfView { view.pdfView = pdfView }
    }
}
