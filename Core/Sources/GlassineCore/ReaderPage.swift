import ObjectiveC
import PDFKit

/// Stable, unique address used as the associated-object key.
nonisolated(unsafe) private let highlightKey =
    UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

/// Immutable box so the render thread only ever sees a fully formed value.
private final class HighlightBox: NSObject {
    let items: [ReaderPage.Highlight]
    init(_ items: [ReaderPage.Highlight]) { self.items = items }
}

/// PDFPage subclass used for every page (see `GlassineDocument.classForPage()`).
/// It draws the dark-mode find highlights: PDFKit renders pages through the
/// page object, so this is the hook that actually runs, and the highlight
/// boxes end up inside the view's inversion filter along with the text.
///
/// Deliberately no Swift stored properties: PDFKit allocates pages through a
/// private initialiser that never runs Swift's ivar setup, so a stored `Array`
/// here is read as a null buffer on the tile-rendering thread and crashes.
/// State lives in an associated object, which the ObjC runtime keeps
/// thread-safe, and the boxed array is immutable once published.
public final class ReaderPage: PDFPage {

    public struct Highlight: Sendable {
        public let rect: CGRect
        public let isCurrent: Bool

        public init(rect: CGRect, isCurrent: Bool) {
            self.rect = rect
            self.isCurrent = isCurrent
        }
    }

    /// Set by ReaderPDFView. Empty in light mode, where PDFKit's own yellow
    /// `highlightedSelections` are used instead.
    public var findHighlights: [Highlight] {
        get { (objc_getAssociatedObject(self, highlightKey) as? HighlightBox)?.items ?? [] }
        set {
            objc_setAssociatedObject(self, highlightKey, HighlightBox(newValue),
                                     .OBJC_ASSOCIATION_RETAIN)
        }
    }

    /// Pre-filter ink for the matches. The view's inversion filter (invert +
    /// 180 degree hue rotation) turns this into terminal green on the dark page.
    /// Drawn translucently over white paper it comes out as a dark-green box
    /// with the glyphs inside lifted to pale green.
    ///
    /// The default is the Mac's value, calibrated against a **linear-light**
    /// `CIColorInvert`. iOS inverts in sRGB (Spike A), so the same green needs a
    /// different pre-filter value there and the iOS app overwrites this at
    /// launch -- which is why it is a `var`. Nothing else writes it, and the Mac
    /// never touches it.
    nonisolated(unsafe) public static var matchInk =
        CGColor(red: 0, green: 0.77, blue: 0, alpha: 1)
    private static let boxAlpha: CGFloat = 0.35
    private static let currentOutlineWidth: CGFloat = 1.5

    public override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)

        let boxes = findHighlights
        guard !boxes.isEmpty else { return }

        context.saveGState()

        // A translucent box over each match, mirroring light mode's native
        // highlight. The 1pt vertical inset keeps the rect off the
        // neighbouring lines, whose ascenders and descenders reach into a
        // line's selection bounds.
        context.setBlendMode(.normal)
        context.setFillColor(Self.matchInk.copy(alpha: Self.boxAlpha) ?? Self.matchInk)
        for highlight in boxes {
            context.fill(highlight.rect.insetBy(dx: 0, dy: 1))
        }

        // The current match adds a solid outline just inside its box. (An
        // outline drawn *outside* the rect painted opaque green over the
        // neighbouring lines' glyphs, which the inversion filter turned into a
        // dark strike through them.)
        context.setStrokeColor(Self.matchInk)
        context.setLineWidth(Self.currentOutlineWidth)
        for highlight in boxes where highlight.isCurrent {
            let rect = highlight.rect.insetBy(dx: 0, dy: 1)
                .insetBy(dx: Self.currentOutlineWidth / 2, dy: Self.currentOutlineWidth / 2)
            context.stroke(rect)
        }

        context.restoreGState()
    }
}
