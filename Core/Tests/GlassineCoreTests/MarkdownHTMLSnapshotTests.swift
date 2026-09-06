import CryptoKit
import Foundation
import Testing

@testable import GlassineCore

/// The Mac's HTML must not move. `MarkdownHTML.page` gained a `platformCSS`
/// parameter in Phase 4 so the iOS app can re-tune four colour variables for a
/// sRGB inversion; every existing caller passes nothing, and this test is the
/// guard that "nothing" still produces the byte-for-byte page it produced
/// before that parameter existed.
///
/// The expected digests were taken from the pre-Phase-4 source. If a deliberate
/// change to the stylesheet moves them, re-record them *and* say so in HANDOFF —
/// an accidental move is a silently different render for every Markdown
/// document on both platforms.
struct MarkdownHTMLSnapshotTests {

    private func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// One page per built-in style, both layouts, at a fixed size, hashed.
    private func snapshot(layout: MarkdownLayout) -> String {
        var joined = ""
        for style in MarkdownStyle.builtIns {
            let styling = MarkdownStyling(styleID: style.id,
                                          css: MarkdownHTML.builtInStyle(style.id),
                                          size: 11,
                                          layout: layout)
            joined += MarkdownHTML.page(body: "<h1>Heading</h1><p>Body &amp; more.</p>",
                                        title: "Snapshot",
                                        styling: styling)
        }
        return joined
    }

    @Test("page() with no platformCSS is byte-identical to the pre-Phase-4 output")
    func pageIsUnchangedWithoutPlatformCSS() {
        #expect(digest(snapshot(layout: .pages)) == "8feec783e0b2a465be0f9cdd65333ef87cbf36858d179ff2c49c30440fb7b9ec")
        #expect(digest(snapshot(layout: .continuous)) == "79b5ff441dff40eeaa1f7e29ff15e91015bd2363b37d0ddae9a6a4a174435f9f")
    }

    @Test("platformCSS is emitted as a third layer, after the style layer")
    func platformCSSComesLast() {
        let styling = MarkdownStyling(styleID: "manuscript",
                                      css: "/* STYLE-LAYER-MARKER */",
                                      size: 12,
                                      layout: .pages)
        let page = MarkdownHTML.page(body: "<p>Hi</p>", title: "T", styling: styling,
                                     platformCSS: "/* PLATFORM-LAYER-MARKER */")
        let style = page.range(of: "/* STYLE-LAYER-MARKER */")
        let platform = page.range(of: "/* PLATFORM-LAYER-MARKER */")
        #expect(style != nil && platform != nil)
        if let style, let platform { #expect(style.upperBound < platform.lowerBound) }
        #expect(page.components(separatedBy: "<style>").count == 4)   // three layers

        // And nil is not an empty layer.
        let plain = MarkdownHTML.page(body: "<p>Hi</p>", title: "T", styling: styling)
        #expect(plain.components(separatedBy: "<style>").count == 3)
        #expect(plain == MarkdownHTML.page(body: "<p>Hi</p>", title: "T",
                                           styling: styling, platformCSS: nil))
    }
}
