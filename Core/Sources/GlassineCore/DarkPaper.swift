import CoreGraphics

/// How dark the paper gets in inverted dark mode. `black` is the plain
/// inversion; the other two add a tone-compression stage that lifts the page
/// off pure black. Only meaningful while pages are being inverted.
///
/// `lift` and `top` are the single source of truth for both platforms, and they
/// are written as **screen sRGB** levels -- what you want to see -- because that
/// is the only form a human can re-tune. Each platform converts:
///
/// - macOS feeds a `CIColorMatrix` through `CALayer.contentFilters`, whose
///   numbers land in *linear* light, so `ReaderViewController.linearLight`
///   converts both ends before building the matrix.
/// - iOS has no layer filters, so the same compression is expressed as SwiftUI
///   `.contrast(c).brightness(b)` with `c = top - lift` and
///   `b = lift - 0.5 * (1 - c)`.
public enum DarkPaper: Int, Sendable {
    case black = 0, charcoal = 1, gray = 2

    public var title: String {
        switch self {
        case .black: return "Black Paper"
        case .charcoal: return "Charcoal Paper"
        case .gray: return "Gray Paper"
        }
    }

    /// The two ends of the compressed range, as on-screen greys: paper
    /// (inverted black) rises to `lift`, ink (inverted white) falls to `top`.
    /// `lift` is also the window's chrome colour, so the two always match.
    /// Tuned by eye against a text-heavy PDF; edit here to re-tune.
    public var lift: CGFloat {
        switch self {
        case .black: return 0
        case .charcoal: return 0.11
        case .gray: return 0.17
        }
    }

    public var top: CGFloat {
        switch self {
        case .black: return 1
        case .charcoal: return 0.93
        case .gray: return 0.90
        }
    }
}
