import Foundation
import Markdown

/// Pandoc/GitHub/Obsidian Markdown footnotes: `[^label]` in the prose, and
/// `[^label]: the note` somewhere else in the file.
///
/// cmark-gfm has the extension (`CMARK_OPT_FOOTNOTES`) but swift-markdown never
/// turns it on and has no node types for it, so a footnote arrives here as
/// ordinary text and has to be handled in two passes of our own:
///
/// 1. **Definitions come out of the source text before it is parsed at all.**
///    They have to: `[^1]: https://example.com` is a *link reference
///    definition* to cmark, which would quietly turn every `[^1]` in the
///    document into a link to that URL. Lifting the block out first means cmark
///    never sees it.
/// 2. **References are rewritten in the parsed tree**, on `Text` nodes only, so
///    a `[^1]` inside a code span, a fenced block, or a link destination is
///    left exactly as written without any special casing.
///
/// The notes themselves are then appended as a `<section class="footnotes">`
/// after the body, and the two halves are tied together with ordinary `#fn-…`
/// fragment links -- which WebKit's print path turns into real internal
/// `GoTo` destinations in the PDF, so a click on a marker jumps to the note and
/// the back-link jumps back, with no annotation surgery needed.
enum MarkdownFootnotes {

    /// What `extract` lifted out of a document.
    struct Notes {
        /// The source text with every definition block replaced by a blank
        /// line, ready to parse.
        var text: String
        /// Labels in the order they were defined, first definition wins.
        var labels: [String] = []
        /// Label -> the note's Markdown.
        var bodies: [String: String] = [:]
        /// Label -> the `fn-…`/`fnref-…` id suffix, unique across the document.
        var slugs: [String: String] = [:]

        var isEmpty: Bool { labels.isEmpty }
    }

    // MARK: Definitions

    /// Lift every footnote definition out of the raw Markdown.
    ///
    /// A definition starts on a line of the form `[^label]: text` -- at most
    /// three spaces of indent, since four would be an indented code block --
    /// and runs on through lines indented by four spaces or a tab, through
    /// lazy continuation lines (an unindented line that does not start another
    /// definition), and across a blank line when the line after it is indented,
    /// which starts a second paragraph in the same note. A blank line followed
    /// by unindented text ends the note.
    ///
    /// Fenced code blocks are tracked so a `[^x]: …` line inside one is left
    /// alone.
    static func extract(from markdown: String) -> Notes {
        var notes = Notes(text: markdown)
        // Nothing that looks even slightly like a definition: leave the text
        // untouched rather than paying for a line-by-line rebuild.
        guard markdown.contains("[^") else { return notes }

        let lines = markdown.components(separatedBy: "\n")
        var kept: [String] = []
        kept.reserveCapacity(lines.count)
        var fence: Fence?
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if let open = fence {
                if open.closes(line) { fence = nil }
                kept.append(line)
                index += 1
                continue
            }
            if let opened = Fence(opening: line) {
                fence = opened
                kept.append(line)
                index += 1
                continue
            }
            guard let start = definitionStart(line) else {
                kept.append(line)
                index += 1
                continue
            }

            var body = [start.rest]
            index += 1
            gathering: while index < lines.count {
                let next = lines[index]
                if isBlank(next) {
                    // A blank line only continues the note when what follows it
                    // is indented; otherwise the note ended here.
                    var lookahead = index
                    while lookahead < lines.count, isBlank(lines[lookahead]) { lookahead += 1 }
                    guard lookahead < lines.count,
                          let stripped = strippingIndent(lines[lookahead]) else { break gathering }
                    body.append("")
                    body.append(stripped)
                    index = lookahead + 1
                    continue
                }
                if let stripped = strippingIndent(next) {
                    body.append(stripped)
                    index += 1
                    continue
                }
                // An unindented line starts the next definition, or lazily
                // continues this one.
                if definitionStart(next) != nil { break gathering }
                body.append(next)
                index += 1
            }

            // A blank line in the definition's place, so the paragraphs that
            // surrounded it do not run together once it is gone.
            kept.append("")
            guard notes.bodies[start.label] == nil else { continue }
            notes.labels.append(start.label)
            notes.bodies[start.label] = body.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !notes.isEmpty else { return notes }
        notes.text = kept.joined(separator: "\n")
        notes.slugs = slugs(for: notes.labels)
        return notes
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// `[^label]: rest`, with up to three spaces of indent. The label may not
    /// contain whitespace or `]`.
    private static func definitionStart(_ line: String) -> (label: String, rest: String)? {
        var rest = Substring(line)
        var indent = 0
        while let first = rest.first, first == " ", indent < 3 {
            rest = rest.dropFirst()
            indent += 1
        }
        guard rest.hasPrefix("[^") else { return nil }
        rest = rest.dropFirst(2)
        guard let end = rest.firstIndex(of: "]") else { return nil }
        let label = rest[rest.startIndex..<end]
        guard !label.isEmpty,
              !label.contains(where: { $0 == " " || $0 == "\t" }) else { return nil }
        rest = rest[rest.index(after: end)...]
        guard rest.hasPrefix(":") else { return nil }
        rest = rest.dropFirst()
        while let first = rest.first, first == " " || first == "\t" { rest = rest.dropFirst() }
        return (String(label), String(rest))
    }

    /// One level of block indentation -- four spaces or a tab -- removed, or
    /// nil when the line has none.
    private static func strippingIndent(_ line: String) -> String? {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
        return nil
    }

    /// A ``` or ~~~ fence, so a definition-shaped line inside a code block is
    /// left where it is.
    private struct Fence {
        let marker: Character
        let length: Int

        init?(opening line: String) {
            var rest = Substring(line)
            var indent = 0
            while let first = rest.first, first == " ", indent < 3 {
                rest = rest.dropFirst()
                indent += 1
            }
            guard let first = rest.first, first == "`" || first == "~" else { return nil }
            let run = rest.prefix { $0 == first }
            guard run.count >= 3 else { return nil }
            marker = first
            length = run.count
        }

        /// A closing fence is the same character, at least as long, and carries
        /// nothing else.
        func closes(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.first == marker else { return false }
            let run = trimmed.prefix { $0 == marker }
            return run.count >= length && run.count == trimmed.count
        }
    }

    // MARK: Ids

    /// A label made safe to put in an `id` and a `#fragment`. Anything outside
    /// `[A-Za-z0-9_-]` becomes `-`, and a collision that creates (`a b` and
    /// `a-b` both slugify to `a-b`) is broken with the label's position.
    private static func slugs(for labels: [String]) -> [String: String] {
        var slugs: [String: String] = [:]
        var taken: Set<String> = []
        for (position, label) in labels.enumerated() {
            var slug = String(label.map { character -> Character in
                character.isASCII && (character.isLetter || character.isNumber
                                      || character == "-" || character == "_")
                    ? character : "-"
            })
            if slug.isEmpty { slug = "n" }
            if taken.contains(slug) { slug += "-\(position + 1)" }
            taken.insert(slug)
            slugs[label] = slug
        }
        return slugs
    }

    // MARK: References

    /// Replaces every `[^label]` that has a definition with a superscript
    /// marker linking to the note, numbering them by first reference.
    ///
    /// It works on `Text` nodes, which is what keeps it out of code spans, code
    /// blocks and link destinations without a single special case, and splices
    /// the marker in as `InlineHTML` -- raw HTML that `HTMLFormatter` passes
    /// straight through, and that the word count does not see.
    ///
    /// `MarkupRewriter` can only map one node to one node, so the splicing has
    /// to happen a level up, in `defaultVisit`, where a parent rebuilds its
    /// children.
    struct Referencer: MarkupRewriter {
        /// Label -> id slug; a label that is not in here has no definition and
        /// stays literal text.
        let slugs: [String: String]
        /// Labels in the order they were first referenced. This is the
        /// numbering, and the order the notes are listed in.
        private(set) var order: [String] = []
        private var numbers: [String: Int] = [:]
        private var uses: [String: Int] = [:]

        init(slugs: [String: String]) { self.slugs = slugs }

        mutating func defaultVisit(_ markup: Markup) -> Markup? {
            // An image's children are its alt text, which HTMLFormatter puts in
            // an attribute; markup spliced in there would be nonsense.
            if markup is Image { return markup }

            var children: [Markup] = []
            for child in markup.children {
                guard let text = child as? Text else {
                    if let rewritten = visit(child) { children.append(rewritten) }
                    continue
                }
                children.append(contentsOf: expand(text))
            }
            return markup.withUncheckedChildren(children)
        }

        /// One `Text` node split around the markers it contains.
        private mutating func expand(_ text: Text) -> [Markup] {
            let string = text.string
            guard string.contains("[^") else { return [text] }

            var pieces: [Markup] = []
            var literal = ""
            var index = string.startIndex

            while index < string.endIndex {
                guard string[index] == "[",
                      let reference = reference(in: string, from: index) else {
                    literal.append(string[index])
                    index = string.index(after: index)
                    continue
                }
                if !literal.isEmpty {
                    pieces.append(Text(literal))
                    literal = ""
                }
                pieces.append(InlineHTML(marker(for: reference.label)))
                index = reference.end
            }
            if !literal.isEmpty { pieces.append(Text(literal)) }
            return pieces.isEmpty ? [text] : pieces
        }

        /// `[^label]` starting at `index`, if it is one and the label is
        /// defined.
        private func reference(in string: String,
                               from index: String.Index) -> (label: String, end: String.Index)? {
            let afterBracket = string.index(after: index)
            guard afterBracket < string.endIndex, string[afterBracket] == "^" else { return nil }
            var cursor = string.index(after: afterBracket)
            var label = ""
            while cursor < string.endIndex {
                let character = string[cursor]
                if character == "]" {
                    guard !label.isEmpty, slugs[label] != nil else { return nil }
                    return (label, string.index(after: cursor))
                }
                guard !character.isWhitespace else { return nil }
                label.append(character)
                cursor = string.index(after: cursor)
            }
            return nil
        }

        /// The superscript. Only the first reference to a label carries the
        /// plain `fnref-<slug>` id, because that is what the note's back-link
        /// points at; the rest are numbered so no id is ever duplicated.
        private mutating func marker(for label: String) -> String {
            let slug = slugs[label] ?? label
            let number: Int
            if let existing = numbers[label] {
                number = existing
            } else {
                order.append(label)
                number = order.count
                numbers[label] = number
            }
            let use = (uses[label] ?? 0) + 1
            uses[label] = use
            let id = use == 1 ? "fnref-\(slug)" : "fnref-\(slug)-\(use)"
            return "<sup class=\"fnref\" id=\"\(id)\"><a href=\"#fn-\(slug)\">\(number)</a></sup>"
        }
    }

    // MARK: The notes section

    /// The `<section class="footnotes">` that closes the document: a rule and
    /// an ordered list, one item per referenced note, each ending in a
    /// back-link to its first reference.
    ///
    /// `notes` is `(slug, rendered HTML)` in footnote-number order. An empty
    /// list renders nothing at all -- a document without footnotes must come
    /// out exactly as it did before this existed.
    static func notesSection(_ notes: [(slug: String, html: String)]) -> String {
        guard !notes.isEmpty else { return "" }
        var html = "<section class=\"footnotes\">\n<hr>\n<ol>\n"
        for note in notes {
            html += "<li id=\"fn-\(note.slug)\">\n"
            html += withBackLink(note.html, slug: note.slug)
            html += "</li>\n"
        }
        return html + "</ol>\n</section>\n"
    }

    /// The back-link goes *inside* the note's last paragraph so it sits at the
    /// end of the last line rather than on a line of its own; a note that ends
    /// in something else (a list, a code block) gets it appended instead.
    private static func withBackLink(_ html: String, slug: String) -> String {
        let link = "<a class=\"fnback\" href=\"#fnref-\(slug)\">\u{21A9}</a>"
        let content = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let closing = content.range(of: "</p>", options: .backwards) else {
            return content + link + "\n"
        }
        return content.replacingCharacters(in: closing, with: link + "</p>") + "\n"
    }
}
