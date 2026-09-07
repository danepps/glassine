import CoreGraphics
import GlassineCore
import SwiftUI
import UIKit

/// Everything about how an inverted page is made to look right on iOS, in one
/// place, because every number here was derived from the same two facts:
/// SwiftUI's filters run in **sRGB** (the Mac's Core Image chain runs in linear
/// light), and the chain is `complement` then `hue-rotate 180 degrees`.
enum ReaderTheme {

    // MARK: The inversion chain

    /// Dark Paper as two more modifiers. `.contrast(c)` is `v -> (v - 0.5)c + 0.5`
    /// and `.brightness(b)` is `v -> v + b`, both on the same 0...1 screen values
    /// `DarkPaper.lift`/`.top` already store, so no linear-light conversion is
    /// needed here (Spike A measured paper 28 and 43, ink 237 and 230 -- the
    /// Mac's numbers exactly, first try).
    static func contrast(for paper: DarkPaper) -> Double { Double(paper.top - paper.lift) }

    static func brightness(for paper: DarkPaper) -> Double {
        Double(paper.lift) - 0.5 * (1 - contrast(for: paper))
    }

    // MARK: Pre-filter colours

    /// The page-break gutter, chosen for how it looks *after* the filter.
    ///
    /// The Mac's 0.997 white does not survive the port: an sRGB complement turns
    /// 254 into 1, one level off the paper's 0, and the page break disappears
    /// (Spike A gotcha 3, measured 1/0 Black, 29/28 Charcoal, 44/43 Gray). 0.94
    /// gives the Mac's ~12-level separation instead: 15/0, 40/28, 54/43.
    static let invertedGutter = UIColor(white: 0.94, alpha: 1)
    /// Not inverted: the Mac's own two greys.
    static let darkGutter = UIColor(white: 0.11, alpha: 1)
    static let lightGutter = UIColor(white: 0.94, alpha: 1)

    /// Pre-filter ink for the find boxes, re-derived for iOS.
    ///
    /// The chain is `C = 255 - P`, then the standard 180 degree hue-rotation
    /// matrix -- which Spike A's measurements match to the level (`11,87,208` ->
    /// `107,183,255`, `255,0,0` -> `255,147,147`). For a pre-filter green
    /// `(0, k, 0)` that matrix collapses to
    ///
    ///     on screen = (255 - 1.43k, 255 - 0.43k, 255 - 1.43k)
    ///
    /// so **the on-screen green is always as much red and blue as it is short of
    /// white**: the wanted #5CF25C (92,242,92) is simply not reachable from any
    /// pre-filter colour, because running it backwards puts the red and blue
    /// rows at 306 and they clip. The closest point on the reachable line is
    /// `k = 114`, which gives **92,206,92** -- the target's red and blue exactly,
    /// its green 36 levels short. (The Mac's own measured #69E170 is 105,225,112,
    /// so this is a shade deeper and no further from it than the target is.)
    ///
    /// Measured on the iPad Pro 13-inch simulator at Black paper: the solid
    /// current-match outline reads **92,206,92**, the 35%-alpha box over white
    /// paper **32,72,32**, and the glyphs inside it **206,240,206**. All three
    /// are what the formula predicts for k = 114.
    ///
    /// The colour space is spelled out because `CGColor(red:green:blue:alpha:)`
    /// does **not** mean sRGB: the same 0.447 through that initialiser landed on
    /// the page as 0.385, an implied gamma of about 1.86, and the calibration
    /// would then only be true of whatever space CoreGraphics chose.
    static let matchInk: CGColor = {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        return CGColor(colorSpace: sRGB, components: [0, 114.0 / 255.0, 0, 1])!
    }()

    // MARK: The Markdown stylesheet's platform layer

    /// The third `<style>` layer `MarkdownHTML.page(… platformCSS:)` emits, and
    /// the only thing iOS changes about the shared stylesheet.
    ///
    /// **Why it has to exist.** The panels are drawn into the PDF once and then
    /// inverted at display time, so one set of values has to serve both
    /// appearances — and the two platforms invert differently. macOS runs
    /// `CIColorInvert` in *linear light*, where the round trip through the sRGB
    /// transfer function magnifies the gap between paper and a near-white:
    /// `#FAFAFA` comes back **59 levels** above a Black page and `#F5F5F5` **83**
    /// (`enc(1 - lin(250/255)) * 255 = 59.2`, `= 83.2`). iOS has no layer
    /// filters; `PageInversion` is `.contrast(-1)`, which is exactly `255 - v` in
    /// sRGB, so the same two colours land **5** and **10** levels above the page
    /// — measured in Phase 3, and invisible. What carried a code block there was
    /// its border, not its fill.
    ///
    /// **Why not just use the Mac's numbers.** Matching 59 on iOS needs a
    /// pre-filter `#C4C4C4`, which is not a pale panel in light mode, it is a
    /// grey slab; one value has to serve both appearances, so it cannot be both.
    /// These are the compromise, picked by screenshot on the iPad Pro 11-inch at
    /// Black, Charcoal and Gray in dark and against white in light: a fill that
    /// reads as a filled panel in dark without reading as a slab in light, with
    /// the border kept well clear of its own fill so the Phase 3 look (an
    /// outlined box) survives as the panel's edge. `#E8E8E8` was measured
    /// alongside and was the paler, weaker of the two.
    ///
    /// Measured on screen, sRGB levels:
    ///
    ///     paper / fill / table head / border
    ///     Black     0 /  31 /  37 /  57
    ///     Charcoal 28 /  53 /  58 /  75
    ///     Gray     43 /  66 /  70 /  85
    ///     light   255 / 224 / 218 / 191
    ///
    /// (The border readings are a 1 pt line sampled at 2x, so they run a few
    /// levels short of the 64 the arithmetic gives.)
    ///
    /// It is one layer for all six built-in styles, because the style layer is
    /// where they set `--code-bg` and a correction underneath it would be
    /// overridden by every one of them. A style's own panel *tint* is the cost —
    /// Antique's warm `#FBF7EE` goes neutral on iOS.
    static let markdownPlatformCSS = """
    :root {
      --code-bg: #E0E0E0;
      --th-bg: #DADADA;
      --code-border: #BFBFBF;
      --rule: #BFBFBF;
    }
    """

    // MARK: Chrome

    /// The window chrome under an inverted page takes the paper's own tone, the
    /// way `applyWindowAppearance` does on the Mac -- black at Black Paper, the
    /// lift above it -- so the sidebar and the toolbar sit on exactly the page.
    static func chrome(inverted: Bool, colorScheme: ColorScheme, paper: DarkPaper) -> Color {
        guard colorScheme == .dark else { return Color(uiColor: .systemBackground) }
        guard inverted else { return Color(uiColor: .systemBackground) }
        return Color(white: Double(paper.lift))
    }
}

/// The dark-mode page inversion, as a modifier so the reader and the thumbnail
/// strip apply exactly the same chain (the Mac mirrors its CIFilters onto the
/// sidebar for the same reason).
///
/// Nothing but the page may go inside it: chrome placed here would be inverted
/// too. That is why `ReaderView` puts the toolbar and the find bar outside.
struct PageInversion: ViewModifier {
    let inverted: Bool
    let paper: DarkPaper

    func body(content: Content) -> some View {
        // Deliberately *not* an `if inverted { … } else { … }`. A conditional in
        // a ViewModifier is a `_ConditionalContent`, and switching branches
        // gives the representable a new identity: SwiftUI tears the `PDFView`
        // down and builds another one, which was observed losing the reading
        // position every time the appearance changed. So all four modifiers are
        // always applied and carry identity values when they are not wanted.
        //
        // `.contrast(-1)` stands in for `.colorInvert()`, which takes no
        // argument and so cannot be neutralised: contrast is
        // `v -> (v - 0.5)c + 0.5`, and at c = -1 that is exactly `1 - v`.
        // Measured identical to `.colorInvert()` on every Spike A probe.
        content
            .contrast(inverted ? -1 : 1)
            .hueRotation(.degrees(inverted ? 180 : 0))
            .contrast(inverted ? ReaderTheme.contrast(for: paper) : 1)
            .brightness(inverted ? ReaderTheme.brightness(for: paper) : 0)
    }
}

extension View {
    func pageInversion(_ inverted: Bool, paper: DarkPaper) -> some View {
        modifier(PageInversion(inverted: inverted, paper: paper))
    }
}

/// Swift 6 will not let a `@MainActor` object be captured by the `@Sendable`
/// closures NotificationCenter, KVO and Timer all take, even though every one of
/// them fires on the main thread here. This box carries the reference across
/// that boundary; `MainActor.assumeIsolated` on the far side is the same pattern
/// the Mac app uses for PDFKit's find callbacks.
final class MainBox<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}
