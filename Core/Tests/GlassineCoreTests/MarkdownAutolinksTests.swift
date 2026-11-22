import Foundation
import Testing
@testable import GlassineCore

@Suite("Markdown autolinks")
struct MarkdownAutolinksTests {

    private let turley = "https://jonathanturley.org/2026/11/09/the-reverse-ginsburg-scenario-democrats-may-only-need-to-wait-rather-than-pack-the-court/"
    private let yahoo = "https://www.yahoo.com/news/politics/article/final-2026-midterm-election-results-democrats-clinch-56-seat-senate-majority-with-peltolas-alaska-win-what-they-can--and-cant--do-next-184618858.html"
    private let huffpost = "https://www.huffpost.com/entry/supreme-court-packing-expanding-democrats-2028_n_6a9af459e4b0bd4d29d41faf"

    private func html(_ markdown: String, output: MarkdownHTML.Output = .pdf) -> String {
        MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil, output: output).html
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The `href`s in `html`, in order.
    private func hrefs(_ html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"<a href="([^"]*)""#)
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).map {
            String(html[Range($0.range(at: 1), in: html)!])
        }
    }

    @Test("Bare addresses in list items become one link each, exactly as typed")
    func listItems() {
        let markdown = """
        - Turley, Nov. 9, 2026: \(turley)
        - Yahoo News, Nov. 20, 2026: \(yahoo)
        - HuffPost, Sept. 4, 2026: \(huffpost)
        """
        let out = html(markdown)
        #expect(hrefs(out) == [turley, yahoo, huffpost])
        #expect(out.contains("<a href=\"\(turley)\">\(turley)</a>"))
        // The `--` survives smart punctuation in the destination and the text.
        #expect(out.contains("<a href=\"\(yahoo)\">\(yahoo)</a>"))
        #expect(!out.contains("\u{2013}"))
        #expect(out.contains("<a href=\"\(huffpost)\">\(huffpost)</a>"))
        #expect(out.contains("<p>Turley, Nov. 9, 2026: <a href="))
    }

    @Test("Trailing punctuation is left out of the address")
    func trailingPunctuation() {
        #expect(hrefs(html("See https://example.com/page.")) == ["https://example.com/page"])
        #expect(hrefs(html("See https://example.com/a, then more.")) == ["https://example.com/a"])
        #expect(hrefs(html("Did you read https://example.com/b?")) == ["https://example.com/b"])
        #expect(hrefs(html("Quoted: “https://example.com/q”.")) == ["https://example.com/q"])
        #expect(hrefs(html("It's at 'https://example.com/s'!")) == ["https://example.com/s"])
        // Unbalanced: the parenthesis belongs to the sentence.
        let aside = html("(see https://example.com/c) and on.")
        #expect(hrefs(aside) == ["https://example.com/c"])
        #expect(aside.contains("https://example.com/c</a>) and on."))
        // Balanced: it belongs to the address.
        #expect(hrefs(html("Read https://en.wikipedia.org/wiki/Foo_(bar).")) ==
                ["https://en.wikipedia.org/wiki/Foo_(bar)"])
        #expect(hrefs(html("(https://en.wikipedia.org/wiki/Foo_(bar))")) ==
                ["https://en.wikipedia.org/wiki/Foo_(bar)"])
        // An entity-like ending is not part of it; an ordinary semicolon is.
        #expect(hrefs(html("Go to https://example.com/x&hl; now")) == ["https://example.com/x"])
        #expect(hrefs(html("Go to https://example.com/a;b now")) == ["https://example.com/a;b"])
    }

    @Test("Where an address may start, and what is not one")
    func boundaries() {
        #expect(hrefs(html("Source: https://example.com/a")) == ["https://example.com/a"])
        #expect(hrefs(html("HTTPS://Example.com/Up")) == ["HTTPS://Example.com/Up"])
        #expect(hrefs(html("[https://example.com/sq]")) == ["https://example.com/sq"])
        #expect(hrefs(html("Two: https://a.example and https://b.example.")) ==
                ["https://a.example", "https://b.example"])
        // No host, a letter before the scheme, or a bare scheme: not a link.
        #expect(hrefs(html("Just https:// alone, or https://.")).isEmpty)
        #expect(hrefs(html("foohttps://example.com")).isEmpty)
        #expect(hrefs(html("ftp://example.com and mailto:a@b.c")).isEmpty)
    }

    @Test("Code, raw HTML and existing links are left alone")
    func notDoubleLinked() {
        let markdown = """
        Inline `https://example.com/code` here.

        ```
        https://example.com/fenced
        ```

        An [explicit](https://example.com/explicit) link, the bare https://example.com/explicit too.

        An [https://example.com/text](https://example.com/dest) link.

        An <https://example.com/angle> autolink.

        <div>https://example.com/block</div>
        """
        let out = html(markdown)
        #expect(out.contains("<code>https://example.com/code</code>"))
        #expect(out.contains("<pre><code>https://example.com/fenced\n</code></pre>"))
        #expect(out.contains("<div>https://example.com/block</div>"))
        #expect(hrefs(out) == [
            "https://example.com/explicit", "https://example.com/explicit",
            "https://example.com/dest", "https://example.com/angle"
        ])
        #expect(count("<a href", in: out) == 4)
    }

    @Test("An address in a footnote is linked, and one right before a marker stops there")
    func footnotes() {
        let markdown = """
        A claim.[^1] Another, at https://example.com/body[^2].

        [^1]: See \(huffpost).
        [^2]: Second note.
        """
        let out = html(markdown)
        #expect(out.contains("<a href=\"\(huffpost)\">\(huffpost)</a>."))
        #expect(out.contains("<a href=\"https://example.com/body\">https://example.com/body</a><sup"))
        #expect(!out.contains("[^"))
    }

    @Test("Smart punctuation is undone inside an address only, and a quote is escaped")
    func smartPunctuation() {
        let out = html("An em---dash and en--dash, then https://example.com/a--b---c...d/it's/\"q\"/end")
        #expect(out.contains("An em\u{2014}dash and en\u{2013}dash"))
        // `"` reaches the sanitiser as typed and leaves it as %22.
        #expect(hrefs(out) == ["https://example.com/a--b---c...d/it's/%22q%22/end"])
        // The text keeps the straight quotes; in element content they need no escape.
        #expect(out.contains(">https://example.com/a--b---c...d/it's/\"q\"/end</a>"))
    }

    @Test("Headings are not autolinked")
    func headings() {
        let converted = MarkdownHTML.body(fromMarkdown: "## See https://example.com/h\n\nText.",
                                          baseDirectory: nil)
        #expect(!converted.html.contains("href=\"https://"))
        #expect(converted.html.contains("<a class=\"fh\" href=\"glassine-outline://0\">See https://example.com/h</a>"))
        #expect(converted.headings.map(\.slug) == ["see-httpsexamplecomh"])
    }

    @Test("Emphasis that cuts an address off leaves the address as text")
    func cutByEmphasis() {
        let out = html("At https://example.com/~user/*star*/rest and https://example.com/ok.")
        #expect(hrefs(out) == ["https://example.com/ok"])
        // Inside emphasis, a whole address is still linked.
        #expect(hrefs(html("**bold https://example.com/strong/**")) == ["https://example.com/strong/"])
    }

    @Test("A preview keeps autolinks as ordinary http(s) links")
    func preview() {
        let out = html("Read \(huffpost) and https://example.com/?a=1&b=2.", output: .preview)
        #expect(hrefs(out) == [huffpost, "https://example.com/?a=1&amp;b=2"])
    }

    @Test("Tables cells are autolinked")
    func tables() {
        let out = html("| A | B |\n| --- | --- |\n| x | https://example.com/cell |")
        #expect(hrefs(out) == ["https://example.com/cell"])
    }

    @Test("The word count is what it was before addresses became links")
    func wordCount() {
        // Text the old pipeline counted, as cmark leaves it (smart punctuation
        // applied), with the same separators the collector adds.
        func words(_ text: String) -> Int {
            var n = 0
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                     options: [.byWords, .localized]) { _, _, _, _ in n += 1 }
            return n
        }
        let markdown = "Read foo_https://example.com/a--b now, it\u{2019}s at (https://x.example/y).[^1]\n\n[^1]: Note https://example.com/n_o--te.\n"
        let converted = MarkdownHTML.body(fromMarkdown: markdown, baseDirectory: nil)
        #expect(hrefs(converted.html).contains("https://example.com/a--b"))
        let expected = words("Read foo_https://example.com/a\u{2013}b now, it\u{2019}s at (https://x.example/y). ")
            + words("Note https://example.com/n_o\u{2013}te. ")
        #expect(converted.stats.words == expected)
    }

    @Test("Segments: adjacent text, cut-off flag, and nothing to link")
    func segments() {
        #expect(MarkdownAutolinker.segments(in: "no address here") == [.text("no address here")])
        #expect(MarkdownAutolinker.segments(in: "a https://x.example") ==
                [.text("a "), .link("https://x.example")])
        #expect(MarkdownAutolinker.segments(in: "a https://x.example/~u/", continuesIntoMarkup: true) ==
                [.text("a https://x.example/~u/")])
        #expect(MarkdownAutolinker.segments(in: "a https://x.example b", continuesIntoMarkup: true) ==
                [.text("a "), .link("https://x.example"), .text(" b")])
    }
}
