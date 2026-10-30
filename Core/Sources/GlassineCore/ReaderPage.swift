import ObjectiveC
import PDFKit

/// Stable, unique address used as the associated-object key.
nonisolated(unsafe) private let highlightKey =
    UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

/// Immutable box so the render thread only ever sees a fully formed value.
/// The ink travels with the rectangles, so a tile thread reads both from one
/// published object and never from shared mutable state.
private final class HighlightBox: NSObject {
    let items: [ReaderPage.Highlight]
    let ink: CGColor
    init(_ items: [ReaderPage.Highlight], ink: CGColor) {
        self.items = items
        self.ink = ink
    }
}

nonisolated(unsafe) private let readerBoundsKey =
    UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

private final class ReaderBoundsBox: NSObject {
    let rect: CGRect
    init(_ rect: CGRect) { self.rect = rect }
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

    /// A presentation-only box used by the Mac reader's art-box display.
    /// The PDF's actual page dictionaries and crop/media boxes are untouched.
    public var readerContentBounds: CGRect? {
        get { (objc_getAssociatedObject(self, readerBoundsKey) as? ReaderBoundsBox)?.rect }
        set {
            objc_setAssociatedObject(self, readerBoundsKey, newValue.map(ReaderBoundsBox.init),
                                     .OBJC_ASSOCIATION_RETAIN)
        }
    }

    private static let originalBoundsKey = "com.epps.Glassine.originalPDFBounds"

    /// PDFKit asks the virtual bounds accessor when serializing, including
    /// artBox. Suppress presentation bounds on the output thread only, keeping
    /// concurrent on-screen rendering intact. Restore nesting even on errors.
    /// The body must finish copying or serializing synchronously on this thread;
    /// the guard does not propagate to asynchronous work or PDFKit print workers.
    public static func withOriginalBounds<T>(_ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[originalBoundsKey]
        dictionary[originalBoundsKey] = true
        defer {
            if let previous { dictionary[originalBoundsKey] = previous }
            else { dictionary.removeObject(forKey: originalBoundsKey) }
        }
        return try body()
    }

    public override func bounds(for box: PDFDisplayBox) -> CGRect {
        if box == .artBox, Thread.current.threadDictionary[Self.originalBoundsKey] == nil,
           let bounds = readerContentBounds { return bounds }
        return super.bounds(for: box)
    }

    public struct Highlight: Sendable {
        public let rect: CGRect
        public let isCurrent: Bool

        public init(rect: CGRect, isCurrent: Bool) {
            self.rect = rect
            self.isCurrent = isCurrent
        }
    }

    /// Set by `FindHighlighter`. Empty in light mode, where PDFKit's own yellow
    /// `highlightedSelections` are used instead. Assigning here draws in the
    /// default `matchInk`; `setFindHighlights(_:ink:)` names the ink.
    public var findHighlights: [Highlight] {
        get { highlightBox?.items ?? [] }
        set { setFindHighlights(newValue, ink: Self.matchInk) }
    }

    /// Publish the highlights together with the ink they are drawn in. One
    /// immutable box per call, so a tile thread drawing this page sees either
    /// the old pair or the new one, never a mix.
    public func setFindHighlights(_ highlights: [Highlight], ink: CGColor) {
        objc_setAssociatedObject(self, highlightKey, HighlightBox(highlights, ink: ink),
                                 .OBJC_ASSOCIATION_RETAIN)
    }

    /// The ink the current highlights will be drawn in; nil before any were
    /// set. For the tests.
    var findHighlightInk: CGColor? { highlightBox?.ink }

    private var highlightBox: HighlightBox? {
        objc_getAssociatedObject(self, highlightKey) as? HighlightBox
    }

    /// Default pre-filter ink for the matches: the Mac's. The view's inversion
    /// filter (invert + 180 degree hue rotation) turns this into terminal green
    /// on the dark page. Drawn translucently over white paper it comes out as a
    /// dark-green box with the glyphs inside lifted to pale green.
    ///
    /// Calibrated against a **linear-light** `CIColorInvert`. iOS inverts in
    /// sRGB (Spike A), so the same green needs a different pre-filter value
    /// there; the iOS app hands its own to `FindHighlighter(pdfView:matchInk:)`,
    /// which passes it with every set of highlights. A constant rather than a
    /// launch-time global, because PDFKit's tile threads read whatever ink the
    /// draw uses and a shared `var` would be a race the moment anything wrote
    /// it twice.
    public static let matchInk = CGColor(red: 0, green: 0.77, blue: 0, alpha: 1)
    private static let boxAlpha: CGFloat = 0.35
    private static let currentOutlineWidth: CGFloat = 1.5

    public override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)

        // Save/export snapshots include permanent annotations, never the
        // temporary find overlay drawn by this page subclass.
        guard Thread.current.threadDictionary[Self.originalBoundsKey] == nil else { return }
        guard let published = highlightBox, !published.items.isEmpty else { return }
        let boxes = published.items
        let ink = published.ink

        context.saveGState()

        // A translucent box over each match, mirroring light mode's native
        // highlight. The 1pt vertical inset keeps the rect off the
        // neighbouring lines, whose ascenders and descenders reach into a
        // line's selection bounds.
        context.setBlendMode(.normal)
        context.setFillColor(ink.copy(alpha: Self.boxAlpha) ?? ink)
        for highlight in boxes {
            context.fill(highlight.rect.insetBy(dx: 0, dy: 1))
        }

        // The current match adds a solid outline just inside its box. (An
        // outline drawn *outside* the rect painted opaque green over the
        // neighbouring lines' glyphs, which the inversion filter turned into a
        // dark strike through them.)
        context.setStrokeColor(ink)
        context.setLineWidth(Self.currentOutlineWidth)
        for highlight in boxes where highlight.isCurrent {
            let rect = highlight.rect.insetBy(dx: 0, dy: 1)
                .insetBy(dx: Self.currentOutlineWidth / 2, dy: Self.currentOutlineWidth / 2)
            context.stroke(rect)
        }

        context.restoreGState()
    }
}
