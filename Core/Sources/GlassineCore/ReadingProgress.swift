import CoreGraphics

/// How far through a continuous document the reader has got, expressed purely
/// as scroll geometry so both platforms can compute it from whatever scroll
/// view they have.
///
/// The fraction is how far the *top* of the visible area has travelled through
/// the scrollable range: 0 at the top of the document, 1 once its bottom edge is
/// at the bottom of the view. A page shorter than the view is entirely on
/// screen, so it reads 100%. Resolving the two ends of the range (a clip view's
/// bounds against its document view's, and the flipped-coordinate correction)
/// stays with the platform.
public enum ReadingProgress {

    /// A span this small means everything fits: nothing to scroll, all read.
    private static let minimumSpan: CGFloat = 0.5

    /// `travelled` and `span` in the same units; the result is clamped to 0...1.
    public static func fraction(travelled: CGFloat, span: CGFloat) -> CGFloat {
        guard span > minimumSpan else { return 1 }
        return min(max(travelled / span, 0), 1)
    }

    /// The inverse: how far to travel to sit at `fraction`. Nil when there is
    /// nothing to scroll, which is the caller's cue to do nothing at all.
    public static func offset(forFraction fraction: CGFloat, span: CGFloat) -> CGFloat? {
        guard span > minimumSpan else { return nil }
        return span * min(max(fraction, 0), 1)
    }
}
