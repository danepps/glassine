import Foundation
import Markdown

/// Turns bare `http://` and `https://` addresses in a document's text into
/// links, the way GitHub's extended autolinks do.
///
/// swift-markdown attaches only cmark's table, strikethrough and tasklist
/// extensions, not autolink, so a bare address used to be plain text in the
/// rendered PDF with no link annotation behind it. Clicking it then fell to
/// `TextLinks`, which has to guess where an address that wrapped over several
/// lines begins and ends. A real `<a href>` gets a link annotation on every
/// line it wraps onto, so nothing has to be guessed.
///
/// The parse uses cmark's smart punctuation, which has already turned `--` in
/// an address into an en dash and `'` into a curly quote by the time this
/// runs. An address is literal text, so those are put back the way they were
/// typed, in the destination and in the text shown.
///
/// It works on `Text` nodes only, so code spans, code blocks and raw HTML are
/// never touched, and it leaves alone the text of a link (which is already a
/// link) and an image (its alt text goes into an attribute). Headings are
/// skipped only when their content will be wrapped in an outline anchor,
/// because links cannot nest. The caller chooses this alongside the anchor
/// policy, so a separate marker or a preview's plain heading allows links.
///
/// `MarkupRewriter` maps one node to one node, so the splitting happens a
/// level up, in `defaultVisit`, where a parent rebuilds its children. Runs of
/// adjacent `Text` siblings are read together, so an address cmark happened to
/// hand over in pieces is still found whole.
struct MarkdownAutolinker: MarkupRewriter {
    let linkHeadings: Bool

    /// Whether any address was linked. The caller counts words on the tree
    /// as it was when nothing was, so the count cannot change.
    private(set) var linkedAny = false

    mutating func visitLink(_ link: Link) -> Markup? { link }
    mutating func visitImage(_ image: Image) -> Markup? { image }
    mutating func visitHeading(_ heading: Heading) -> Markup? {
        linkHeadings ? defaultVisit(heading) : heading
    }

    mutating func defaultVisit(_ markup: Markup) -> Markup? {
        var children: [Markup] = []
        for child in markup.children {
            if let rewritten = visit(child) { children.append(rewritten) }
        }
        guard markup is InlineContainer else { return markup.withUncheckedChildren(children) }
        return markup.withUncheckedChildren(linkingTextRuns(children))
    }

    /// The children with each run of adjacent `Text` nodes split around the
    /// addresses it contains. A run with no address is kept as it was.
    private mutating func linkingTextRuns(_ children: [Markup]) -> [Markup] {
        var result: [Markup] = []
        var index = 0
        while index < children.count {
            guard children[index] is Text else {
                result.append(children[index])
                index += 1
                continue
            }
            var end = index
            var string = ""
            while end < children.count, let text = children[end] as? Text {
                string += text.string
                end += 1
            }
            // An address that runs straight into emphasis or strikethrough was
            // most likely cut there by a `*`, `_` or `~` that belongs to it;
            // half an address is worse than none, so that one stays text.
            let next = end < children.count ? children[end] : nil
            let cutOff = next is Emphasis || next is Strong || next is Strikethrough
            let segments = Self.segments(in: string, continuesIntoMarkup: cutOff)
            if segments.contains(where: { if case .link = $0 { return true } else { return false } }) {
                linkedAny = true
                for segment in segments {
                    switch segment {
                    case .text(let text):
                        result.append(Text(text))
                    case .link(let address):
                        result.append(Link(destination: address, Text(address)))
                    }
                }
            } else {
                result.append(contentsOf: children[index..<end])
            }
            index = end
        }
        return result
    }

    // MARK: Finding addresses

    enum Segment: Equatable {
        case text(String)
        /// The address as typed: smart punctuation already undone.
        case link(String)
    }

    /// `text` cut into plain stretches and addresses. When
    /// `continuesIntoMarkup` is true the text is followed directly by
    /// emphasis or strikethrough, and an address that reaches its very end is
    /// left as text.
    static func segments(in text: String, continuesIntoMarkup: Bool = false) -> [Segment] {
        let scalars = Array(text.unicodeScalars)
        var segments: [Segment] = []
        var plainStart = 0
        var index = 0
        while index < scalars.count {
            guard let scheme = schemeLength(scalars, at: index),
                  index == 0 || opensAddress(scalars[index - 1]) else {
                index += 1
                continue
            }
            var end = index + scheme
            while end < scalars.count, !endsAddress(scalars, at: end) { end += 1 }
            let reachedEnd = end == scalars.count
            end = trimmedEnd(scalars, start: index, end: end)
            let hostStart = index + scheme
            guard end > hostStart, isHostCharacter(scalars[hostStart]),
                  !(reachedEnd && continuesIntoMarkup) else {
                index = hostStart
                continue
            }
            if plainStart < index { segments.append(.text(string(scalars[plainStart..<index]))) }
            segments.append(.link(scalars[index..<end].map(asTyped).joined()))
            plainStart = end
            index = end
        }
        if plainStart < scalars.count { segments.append(.text(string(scalars[plainStart...]))) }
        return segments
    }

    /// The length of `http://` or `https://` at `index`, in any case.
    private static func schemeLength(_ s: [Unicode.Scalar], at index: Int) -> Int? {
        for scheme in ["http://", "https://"] {
            let length = scheme.unicodeScalars.count
            guard index + length <= s.count else { continue }
            if string(s[index..<index + length]).lowercased() == scheme { return length }
        }
        return nil
    }

    /// What may come right before an address: whitespace, an opening bracket
    /// or quote in either form, the GFM emphasis characters, or a dash.
    /// A letter or a colon may not, so `foo:https://x` stays text, as in GFM.
    private static let openers = Set("([{\"'\u{201C}\u{201D}\u{2018}\u{2019}*_~\u{2013}\u{2014}".unicodeScalars)

    private static func opensAddress(_ c: Unicode.Scalar) -> Bool {
        openers.contains(c) || CharacterSet.whitespacesAndNewlines.contains(c)
    }

    /// An address ends at whitespace or `<`, and before a `[^`: no address
    /// contains one, and it is how a footnote reference written straight
    /// after an address begins.
    private static func endsAddress(_ s: [Unicode.Scalar], at index: Int) -> Bool {
        let c = s[index]
        if c == "<" || CharacterSet.whitespacesAndNewlines.contains(c) { return true }
        return c == "[" && index + 1 < s.count && s[index + 1] == "^"
    }

    private static func isHostCharacter(_ c: Unicode.Scalar) -> Bool {
        c.properties.isAlphabetic || c.properties.numericType != nil
    }

    /// Punctuation that ends a sentence or closes a quote rather than ending
    /// an address, judged on the character as typed (a curly quote counts as
    /// the straight one it was).
    private static let trailing = Set("?!.,:*_~'\"".unicodeScalars)

    /// GFM's end-of-address rules: trailing punctuation is dropped, a closing
    /// parenthesis only while the parentheses are unbalanced, and an `&name;`
    /// that looks like an entity reference. A closing square bracket is
    /// treated like a parenthesis, so `[https://x.example]` -- left as text
    /// by cmark when no reference matches it -- does not keep the `]`.
    private static func trimmedEnd(_ s: [Unicode.Scalar], start: Int, end: Int) -> Int {
        var end = end
        // Count once, then update only the closer being removed. Recounting
        // the remaining address for each unmatched bracket makes a long
        // suffix quadratic. Punctuation and entity suffixes contain no brackets.
        var parentheses = 0
        var brackets = 0
        for c in s[start..<end] {
            switch c {
            case "(": parentheses += 1
            case ")": parentheses -= 1
            case "[": brackets += 1
            case "]": brackets -= 1
            default: break
            }
        }
        while end > start {
            let c = s[end - 1]
            if asTyped(c).unicodeScalars.allSatisfy(trailing.contains) {
                end -= 1
            } else if c == ")" || c == "]" {
                if c == ")" {
                    guard parentheses < 0 else { break }
                    parentheses += 1
                } else {
                    guard brackets < 0 else { break }
                    brackets += 1
                }
                end -= 1
            } else if c == ";" {
                var k = end - 2
                while k > start, s[k].isASCII, s[k].properties.isAlphabetic || ("0"..."9").contains(s[k]) {
                    k -= 1
                }
                guard k < end - 2, s[k] == "&" else { break }
                end = k
            } else {
                break
            }
        }
        return end
    }

    /// One character of an address the way it was typed, before smart
    /// punctuation changed it.
    private static func asTyped(_ c: Unicode.Scalar) -> String {
        switch c {
        case "\u{2013}": return "--"
        case "\u{2014}": return "---"
        case "\u{2026}": return "..."
        case "\u{2018}", "\u{2019}": return "'"
        case "\u{201C}", "\u{201D}": return "\""
        default: return String(c)
        }
    }

    private static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars)
        return String(result)
    }
}
