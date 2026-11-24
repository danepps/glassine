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
/// The expected digests were taken from the pre-Phase-4 source and re-recorded
/// on 2026-09-07, when footnote support added five rules to the base layer
/// (`sup.fnref`, the `section.footnotes` block and `a.fnback`), and on
/// 2026-11-24 for the outline-anchor CSS comment update; the rules did not
/// change in that update. If a deliberate
/// change to the stylesheet moves them again, re-record them *and* say so in
/// HANDOFF — an accidental move is a silently different render for every
/// Markdown document on both platforms.
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
        #expect(digest(snapshot(layout: .pages)) == "f843af62e61a7405e2192f58006857bbea27cb81c0ed69047bf88945d7cf9696")
        #expect(digest(snapshot(layout: .continuous)) == "c9b6d320e60d1713e302a13bdcb3ddb8d3661a81b25ad17c7ce9a621e61ba326")
    }

    #if os(macOS)
    @Test("Mac heading markers stay out of the text flow, including empty headings")
    func headingMarkerHTML() {
        let markdown = "# Supercalifragilisticexpialidocious\n\n# Short\n\n#\n"
        let converted = MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil)
        #expect(converted.html == """
        <h1 id="supercalifragilisticexpialidocious"><a class="fh" href="glassine-outline://0" aria-hidden="true" style="position: absolute; width: 1pt; height: 1em;">&#160;</a>Supercalifragilisticexpialidocious</h1>
        <h1 id="short"><a class="fh" href="glassine-outline://1" aria-hidden="true" style="position: absolute; width: 1pt; height: 1em;">&#160;</a>Short</h1>
        <h1 id="section"><a class="fh" href="glassine-outline://2" aria-hidden="true" style="position: absolute; width: 1pt; height: 1em;">&#160;</a></h1>

        """)
        let preview = MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil, output: .preview)
        #expect(preview.html == """
        <h1 id="supercalifragilisticexpialidocious">Supercalifragilisticexpialidocious</h1>
        <h1 id="short">Short</h1>
        <h1 id="section"></h1>

        """)
    }
    #endif

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
