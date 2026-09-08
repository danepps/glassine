import Foundation
import Markdown
import UniformTypeIdentifiers

/// How rendered Markdown is laid out: real Letter pages, or one tall page the
/// reader scrolls through without a break.
public enum MarkdownLayout: Int, Sendable {
    case pages = 0, continuous = 1

    public var title: String {
        switch self {
        case .pages: return "Pages"
        case .continuous: return "Continuous"
        }
    }
}

/// A stylesheet for rendered Markdown: one of the built-ins, whose CSS lives in
/// `MarkdownHTML`, or a `.css` file the reader dropped into the styles folder.
public struct MarkdownStyle: Equatable, Sendable {
    public var id: String
    public var title: String
    /// nil for a built-in.
    public var url: URL?

    public init(id: String, title: String, url: URL? = nil) {
        self.id = id
        self.title = title
        self.url = url
    }

    public static let defaultID = "manuscript"
    public static let customPrefix = "custom:"

    public static let builtIns: [MarkdownStyle] = [
        MarkdownStyle(id: "manuscript", title: "Manuscript"),
        MarkdownStyle(id: "modern", title: "Modern"),
        MarkdownStyle(id: "github", title: "GitHub"),
        MarkdownStyle(id: "antique", title: "Antique"),
        MarkdownStyle(id: "ink", title: "Ink"),
        MarkdownStyle(id: "academic", title: "Academic")
    ]

    /// Where custom stylesheets live. `~/Library/Application Support/Glassine/Styles`
    /// on the Mac; whatever `Prefs.stylesDirectory` is set to elsewhere.
    public static var folder: URL { Prefs.stylesDirectory }

    /// The `.css` files in that folder, in name order. Read every time the Style
    /// menu opens, so a newly dropped file needs no relaunch.
    public static func customStyles() -> [MarkdownStyle] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "css" }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                return MarkdownStyle(id: customPrefix + name, title: name, url: url)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The style layer for an id: a built-in's CSS, or a custom file read from
    /// disk. A custom style whose file has gone away falls back to the default.
    public static func css(forID id: String) -> String {
        guard id.hasPrefix(customPrefix) else { return MarkdownHTML.builtInStyle(id) }
        let name = String(id.dropFirst(customPrefix.count))
        let url = folder.appendingPathComponent(name).appendingPathExtension("css")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return MarkdownHTML.builtInStyle(defaultID)
        }
        return text
    }
}

/// Everything the stylesheet depends on. Resolved from `Prefs` on the main
/// thread (a custom style's CSS is read from disk here) and then carried around
/// as a value, so the HTML itself can be built off-main.
public struct MarkdownStyling: Equatable, Sendable {
    public var styleID: String
    /// The style layer: the CSS that sets the base layer's variables.
    public var css: String
    public var size: Int
    public var layout: MarkdownLayout

    public init(styleID: String, css: String, size: Int, layout: MarkdownLayout) {
        self.styleID = styleID
        self.css = css
        self.size = size
        self.layout = layout
    }

    public static var current: MarkdownStyling {
        let id = Prefs.markdownStyle
        return MarkdownStyling(styleID: id,
                               css: MarkdownStyle.css(forID: id),
                               size: Prefs.markdownFontSize,
                               layout: Prefs.markdownLayout)
    }

    /// The same styling, paginated: an export is a document to file or print,
    /// never one 40-inch page.
    public var paginated: MarkdownStyling {
        var copy = self
        copy.layout = .pages
        return copy
    }
}

/// Word count for a Markdown document.
public struct MarkdownStats: Equatable, Sendable {
    public var words: Int

    public init(words: Int) { self.words = words }
}

/// One heading of a Markdown document, in document order. `index` is what the
/// `glassine-outline://` anchor in the HTML carries, so a link annotation in the
/// rendered PDF names exactly one heading.
public struct MarkdownHeading: Sendable {
    public var level: Int
    public var title: String
    public var index: Int

    public init(level: Int, title: String, index: Int) {
        self.level = level
        self.title = title
        self.index = index
    }
}

/// Markdown -> HTML. Pure Swift, no AppKit, safe to call off the main thread.
///
/// The HTML is a complete page with an inline stylesheet; page geometry is
/// deliberately *not* in it (no `@page` rule) because the print info supplies
/// the margins and WebKit would otherwise apply both.
public enum MarkdownHTML {

    /// Decode file bytes as text. UTF-8 is the rule; a UTF-16 byte-order mark is
    /// honoured, and anything else is reported the way an unreadable PDF is.
    public static func decode(_ data: Data, url: URL) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadInapplicableStringEncodingError,
            userInfo: [
                NSURLErrorKey: url,
                NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent) is not valid UTF-8 text."
            ]
        )
    }

    /// Convert Markdown to the `<body>` half of the page. `baseDirectory` is the
    /// Markdown file's folder: relative image references are resolved against it
    /// and inlined as data URIs, since the page is loaded from a string and the
    /// CSP blocks every other image source.
    ///
    /// Kept separate from `page(body:title:styling:)` so a style or size change
    /// can re-wrap the same body without reparsing the Markdown.
    ///
    /// The headings come back with it: the caller turns them into the rendered
    /// PDF's outline, using the anchors this leaves around each one. So do the
    /// word-count statistics, which are counted from the same parse.
    ///
    /// Footnotes are two of the passes: their definitions come out of the text
    /// *before* it is parsed (see `MarkdownFootnotes`), and their references
    /// are rewritten in the tree before the headings are anchored, so that a
    /// footnote inside a heading is already a marker by the time the anchorer
    /// formats the heading's children.
    public static func body(fromMarkdown markdown: String,
                     baseDirectory: URL?) -> (html: String,
                                              headings: [MarkdownHeading],
                                              stats: MarkdownStats) {
        let base = baseDirectory?.standardizedFileURL
        let notes = MarkdownFootnotes.extract(from: stripFrontMatter(markdown))
        var document = Document(parsing: notes.text, options: [.disableSourcePosOpts])
        document = inliningImages(document, baseDirectory: base)

        // A document with no definitions cannot have a reference, so it is not
        // worth rebuilding its whole tree to find out.
        var referencer = MarkdownFootnotes.Referencer(slugs: notes.slugs)
        if !notes.isEmpty, let rewritten = referencer.visit(document) as? Document {
            document = rewritten
        }

        // Only notes that were actually referenced are rendered, and in
        // reference order -- an unreferenced definition is dropped, the way
        // Pandoc and GitHub drop it.
        var rendered: [(slug: String, html: String)] = []
        var noteWords = 0
        for label in referencer.order {
            var note = Document(parsing: notes.bodies[label] ?? "",
                                options: [.disableSourcePosOpts])
            note = inliningImages(note, baseDirectory: base)
            noteWords += statistics(of: note).words
            rendered.append((notes.slugs[label] ?? label, HTMLFormatter.format(note)))
        }

        var stats = statistics(of: document)
        stats.words += noteWords

        var anchorer = HeadingAnchorer()
        if let rewritten = anchorer.visit(document) as? Document {
            document = rewritten
        }
        let html = HTMLFormatter.format(document) + MarkdownFootnotes.notesSection(rendered)
        return (html, anchorer.headings, stats)
    }

    private static func inliningImages(_ document: Document, baseDirectory: URL?) -> Document {
        guard let baseDirectory else { return document }
        var inliner = ImageInliner(baseDirectory: baseDirectory)
        return (inliner.visit(document) as? Document) ?? document
    }

    /// Wrap a formatted body in the full page: charset, CSP, and the stylesheet
    /// for the current styling.
    ///
    /// `platformCSS` is an optional **third** layer, emitted after the style
    /// layer, for corrections a platform's *display* pipeline forces on the
    /// document. It exists for exactly one thing today: iOS inverts dark mode in
    /// sRGB (`255 - v`) where macOS inverts in linear light, so the near-white
    /// panel colours the Mac is calibrated for come out five levels off the page
    /// there. See `ReaderTheme.markdownPlatformCSS` in the iOS app.
    ///
    /// It goes **last, after the style layer**, because the style layer is where
    /// both the six built-ins and a user's own `.css` live — they share one slot
    /// (`MarkdownStyling.css`), and every built-in sets `--code-bg` itself, so a
    /// correction placed before it would be overridden by all six and correct
    /// nothing. The cost is that a custom stylesheet's own panel colour is
    /// overridden too on iOS; `!important` is its escape hatch.
    ///
    /// Passing nothing emits nothing — not an empty `<style>` — so the macOS
    /// output is byte-for-byte what it was before this parameter existed
    /// (`MarkdownHTMLSnapshotTests` is the guard).
    public static func page(body: String, title: String, styling: MarkdownStyling,
                            platformCSS: String? = nil) -> String {
        let platformLayer = platformCSS.map { "\n<style>\($0)</style>" } ?? ""
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" \
        content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <title>\(escape(title))</title>
        <style>\(baseStyle(styling))</style>
        <style>\(styling.css)</style>\(platformLayer)
        </head><body>
        \(body)
        </body></html>
        """
    }

    // MARK: Front matter

    /// Drop a leading YAML front-matter block (`---` … `---` or `…`), which is
    /// metadata for other tools and reads as a horizontal rule otherwise.
    public static func stripFrontMatter(_ text: String) -> String {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        guard body.hasPrefix("---") else { return body }

        let lines = body.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return body }
        for index in 1..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line == "---" || line == "..." {
                return lines[(index + 1)...].joined(separator: "\n")
            }
        }
        return body
    }

    // MARK: Statistics

    /// Words, counted over the document's plain text so that markup, URLs and
    /// image data never inflate the number.
    private static func statistics(of document: Document) -> MarkdownStats {
        var collector = TextCollector()
        collector.visit(document)
        var words = 0
        let text = collector.text
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .localized]) { _, _, _, _ in
            words += 1
        }
        return MarkdownStats(words: words)
    }

    /// Gathers the readable text: prose, inline code and code blocks.
    private struct TextCollector: MarkupWalker {
        var text = ""

        mutating func visitText(_ node: Text) { text += node.string + " " }
        mutating func visitInlineCode(_ node: InlineCode) { text += node.code + " " }
        mutating func visitCodeBlock(_ node: CodeBlock) { text += node.code + " " }
    }

    // MARK: Headings

    /// Wraps each heading's content in an anchor carrying a private-scheme URL,
    /// and records the heading in the same pass so the numbering and the list
    /// can never drift apart. WebKit emits a link annotation for every `<a>`
    /// but no PDF outline, so those annotations are how the renderer learns
    /// where each heading landed. The anchor is styled invisible.
    ///
    /// The heading also gets a GitHub-style `id`, which is what makes a
    /// hand-written table of contents (`[Background](#background)`) work: WebKit
    /// turns a same-document fragment link into a real internal `GoTo`
    /// destination in the printed PDF, so the link is live in the reader
    /// without any annotation surgery. A fragment that matches no heading is
    /// simply dead, as it was before.
    private struct HeadingAnchorer: MarkupRewriter {
        var headings: [MarkdownHeading] = []
        /// How many headings have already claimed each slug, so a repeated
        /// title becomes `slug-1`, `slug-2`, … the way GitHub numbers them.
        private var taken: [String: Int] = [:]

        mutating func visitHeading(_ heading: Heading) -> Markup? {
            let index = headings.count
            let title = title(of: heading)
            headings.append(MarkdownHeading(level: heading.level,
                                            title: title,
                                            index: index))
            let inner = heading.children.map { HTMLFormatter.format($0) }.joined()
            let level = heading.level
            return HTMLBlock("<h\(level) id=\"\(slug(for: title))\">"
                             + "<a class=\"fh\" href=\"glassine-outline://\(index)\">"
                             + inner + "</a></h\(level)>\n")
        }

        /// GitHub's anchor slug: lower-cased, everything but letters, numbers,
        /// hyphens and underscores dropped, spaces turned into hyphens. Letters
        /// outside ASCII are kept, which is both what GitHub does and what an
        /// `id` allows.
        private mutating func slug(for title: String) -> String {
            var slug = ""
            for character in title.lowercased() {
                if character.isLetter || character.isNumber
                    || character == "-" || character == "_" {
                    slug.append(character)
                } else if character == " " {
                    slug.append("-")
                }
            }
            if slug.isEmpty { slug = "section" }
            let used = taken[slug, default: 0]
            taken[slug] = used + 1
            return used == 0 ? slug : "\(slug)-\(used)"
        }

        /// The bookmark's label. Not `heading.plainText`: that reads an
        /// `InlineHTML` node out as its raw markup, and a footnote reference in
        /// a heading is exactly such a node by the time this runs. The marker
        /// belongs in the page, not in the outline, so it is skipped.
        private func title(of heading: Heading) -> String {
            var collector = TitleCollector()
            collector.visit(heading)
            return collector.text.trimmingCharacters(in: .whitespaces)
        }

        private struct TitleCollector: MarkupWalker {
            var text = ""

            mutating func visitText(_ node: Text) { text += node.string }
            mutating func visitInlineCode(_ node: InlineCode) { text += node.code }
            mutating func visitSoftBreak(_ node: SoftBreak) { text += " " }
            mutating func visitLineBreak(_ node: LineBreak) { text += " " }
        }
    }

    // MARK: Images

    /// Rewrites relative image sources that point inside the document's own
    /// folder into `data:` URIs. Remote sources are left alone and the CSP then
    /// keeps them from loading, so a render never touches the network.
    private struct ImageInliner: MarkupRewriter {
        let baseDirectory: URL
        /// Refuse to inline anything huge: it would bloat the HTML and stall
        /// the render for no reading benefit.
        static let sizeCap = 8 * 1024 * 1024

        mutating func visitImage(_ image: Image) -> Markup? {
            guard let source = image.source, !source.isEmpty else { return image }
            if let url = URL(string: source), url.scheme != nil { return image }

            let relative = source.removingPercentEncoding ?? source
            let resolved = URL(fileURLWithPath: relative,
                               relativeTo: baseDirectory).standardizedFileURL
            // Stay inside the document's folder; "../../secret.png" is not ours
            // to inline.
            guard resolved.path.hasPrefix(baseDirectory.path + "/") else { return image }

            guard let values = try? resolved.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, size <= Self.sizeCap,
                  let data = try? Data(contentsOf: resolved),
                  let type = UTType(filenameExtension: resolved.pathExtension),
                  let mime = type.preferredMIMEType
            else { return image }

            var copy = image
            copy.source = "data:\(mime);base64,\(data.base64EncodedString())"
            return copy
        }
    }

    // MARK: Template

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The base layer: page structure and the mechanics of lists, checkboxes,
    /// tables, code and the outline anchor, all expressed through CSS
    /// variables. The style layer that follows it -- a built-in below, or a
    /// custom `.css` file used verbatim -- only has to set those variables.
    ///
    /// Every colour is chosen for how it looks *after* the reader's dark-mode
    /// filter (invert + 180° hue = a luminance flip). The inversion happens in
    /// *linear* light, which magnifies whatever is not pure white: #FAFAFA
    /// comes back as the dark gray a code block wants, but a whole page of
    /// #FFFDF8 comes back as a visible brown slab. So panels may be off-white
    /// and `--paper` may not: it stays #FFFFFF in every built-in style, and a
    /// custom style that tints it will see that tint in dark mode.
    private static func baseStyle(_ styling: MarkdownStyling) -> String {
        let geometry = styling.layout == .continuous ? continuousGeometry : pagedGeometry
        return """
        :root {
          --body-font: ui-serif, "New York", Georgia, serif;
          --heading-font: var(--body-font);
          --mono-font: ui-monospace, "SF Mono", Menlo, monospace;
          --body-size: \(styling.size)pt;
          --line-height: 1.5;
          --paragraph-gap: 8pt;
          --text: #000000;
          --muted: #444444;
          --rule: #D0D0D0;
          --code-bg: #FAFAFA;
          --code-border: #E0E0E0;
          --th-bg: #F5F5F5;
          --link: #0B57D0;
          --paper: #FFFFFF;
        }
        html { -webkit-print-color-adjust: exact; }
        body {
          font-family: var(--body-font);
          font-size: var(--body-size);
          line-height: var(--line-height);
          color: var(--text);
          background: var(--paper);
          margin: 0;
          word-wrap: break-word;
        }
        h1, h2, h3, h4, h5, h6 {
          font-family: var(--heading-font);
          font-weight: 600;
          line-height: 1.25;
          margin: 14pt 0 6pt;
        }
        h1 { font-size: calc(var(--body-size) * 1.8); margin-top: 0; }
        h2 { font-size: calc(var(--body-size) * 1.35); }
        h3 { font-size: calc(var(--body-size) * 1.15); }
        h4, h5, h6 { font-size: var(--body-size); }
        p { margin: 0 0 var(--paragraph-gap); orphans: 2; widows: 2; }
        a { color: var(--link); text-decoration: none; }
        /* The outline anchor wrapped around every heading must not be visible;
           this rule has to come after the one above to win. */
        a.fh { color: inherit; text-decoration: none; }
        /* Footnotes: a superscript marker in the prose, and the notes
           themselves in an ordered list after a rule at the end. */
        sup.fnref { font-size: 0.75em; line-height: 0; vertical-align: super; }
        section.footnotes { margin-top: 24pt; font-size: 0.9em; }
        section.footnotes ol { padding-left: 1.5em; }
        section.footnotes li { margin-bottom: 6pt; }
        a.fnback { margin-left: 0.3em; }
        ul, ol { margin: 0 0 var(--paragraph-gap); padding-left: 20pt; }
        li { margin: 0 0 2pt; }
        li > ul, li > ol { margin-top: 2pt; }
        li > ul:last-child, li > ol:last-child { margin-bottom: 0; }
        /* swift-markdown's HTMLFormatter wraps every list item's text in a <p>,
           even in a tight list, so item spacing has to come off the paragraph
           and a task item's text has to be pulled back inline beside its box. */
        li > p { margin: 0 0 2pt; }
        li > p:last-child { margin-bottom: 0; }
        input[type="checkbox"] + p { display: inline; }
        code {
          font-family: var(--mono-font);
          font-size: calc(var(--body-size) * 0.87);
          background: var(--code-bg);
          border: 1px solid var(--code-border);
          border-radius: 3px;
          padding: 0 2px;
        }
        pre {
          font-family: var(--mono-font);
          font-size: calc(var(--body-size) * 0.82);
          line-height: 1.35;
          background: var(--code-bg);
          border: 1px solid var(--code-border);
          border-radius: 4px;
          padding: 6pt 8pt;
          margin: 0 0 var(--paragraph-gap);
          white-space: pre-wrap;
          overflow-wrap: anywhere;
        }
        pre code { background: none; border: 0; padding: 0; font-size: inherit; }
        blockquote {
          margin: 0 0 var(--paragraph-gap);
          padding-left: 10pt;
          border-left: 3px solid var(--rule);
          color: var(--muted);
        }
        table {
          border-collapse: collapse;
          font-size: calc(var(--body-size) * 0.91);
          margin: 0 0 var(--paragraph-gap);
          width: 100%;
        }
        th, td { border: 1px solid var(--rule); padding: 3pt 5pt; text-align: left; vertical-align: top; }
        th { background: var(--th-bg); font-weight: 600; }
        img { max-width: 100%; }
        /* Remote images are blocked by the CSP; hide the empty box too. */
        img[src^="http"] { display: none; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 12pt 0; }
        del { text-decoration: line-through; }
        input[type="checkbox"] {
          -webkit-appearance: none;
          appearance: none;
          width: 9pt;
          height: 9pt;
          border: 1px solid var(--muted);
          border-radius: 2px;
          vertical-align: -1px;
          margin: 0 4px 0 0;
        }
        input[type="checkbox"]:checked {
          background: var(--muted);
          border-color: var(--muted);
        }
        li:has(> input[type="checkbox"]) { list-style: none; margin-left: -14pt; }
        \(geometry)
        """
    }

    /// Real pages: margins come from NSPrintInfo, so the document has no page
    /// box of its own -- only the rules that keep blocks from being split.
    private static let pagedGeometry = """
    h1, h2, h3, h4, h5, h6 {
      break-after: avoid;
      page-break-after: avoid;
      break-inside: avoid;
    }
    /* WebKit ignores break-after: avoid when the next block is itself
       unbreakable, which leaves headings stranded at the foot of a page.
       Giving the heading an invisible tail that is taller than a line, then
       pulling it back with a negative margin, makes the heading box too tall
       to fit there and carries it over with its content. */
    h1::after, h2::after, h3::after, h4::after, h5::after, h6::after {
      content: "";
      display: block;
      height: 72pt;
      margin-bottom: -72pt;
    }
    pre, tr { break-inside: avoid; page-break-inside: avoid; }
    """

    /// One tall page: printed with no margins at all, so the inch of white
    /// space has to be padding on the body -- where it is also part of the
    /// scrollHeight the renderer measures. Nothing breaks, so none of the
    /// keep-together rules apply.
    private static let continuousGeometry = "body { padding: 72pt; }"

    // MARK: Built-in styles

    /// The style layer for a built-in id; an unknown id falls back to the
    /// default. Each one sets the base layer's variables and adds only the few
    /// rules that give it its character.
    public static func builtInStyle(_ id: String) -> String {
        switch id {
        case "modern": return modernStyle
        case "github": return githubStyle
        case "antique": return antiqueStyle
        case "ink": return inkStyle
        case "academic": return academicStyle
        default: return manuscriptStyle
        }
    }

    /// New York on white: the base layer's own defaults, spelled out so the
    /// preset does not drift if those change.
    private static let manuscriptStyle = """
    :root {
      --body-font: ui-serif, "New York", Georgia, serif;
      --heading-font: var(--body-font);
      --line-height: 1.5;
      --paragraph-gap: 8pt;
    }
    """

    private static let modernStyle = """
    :root {
      --body-font: -apple-system, system-ui, "Helvetica Neue", sans-serif;
      --heading-font: var(--body-font);
      --line-height: 1.72;
      --paragraph-gap: 11pt;
      --muted: #55595E;
      --rule: #E2E2E2;
      --code-bg: #FAFAFA;
      --code-border: #EBEBEB;
      --th-bg: #FAFAFA;
    }
    h1, h2, h3 { font-weight: 300; letter-spacing: -0.015em; margin-top: 20pt; }
    h1 { font-size: calc(var(--body-size) * 2.1); }
    h2 { font-size: calc(var(--body-size) * 1.5); }
    h3 { font-size: calc(var(--body-size) * 1.2); }
    h4, h5, h6 { font-weight: 600; letter-spacing: 0.02em; }
    blockquote { border-left-width: 2px; padding-left: 12pt; font-style: italic; }
    hr { margin: 20pt 0; }
    th, td { padding: 5pt 7pt; }
    """

    private static let githubStyle = """
    :root {
      --body-font: -apple-system, system-ui, "Helvetica Neue", Arial, sans-serif;
      --heading-font: var(--body-font);
      --line-height: 1.55;
      --paragraph-gap: 10pt;
      --muted: #57606A;
      --rule: #D8DEE4;
      --code-bg: #F6F8FA;
      --code-border: #EAEEF2;
      --th-bg: #F6F8FA;
    }
    h1, h2 { border-bottom: 1px solid var(--rule); padding-bottom: 4pt; }
    h1 { font-size: calc(var(--body-size) * 1.9); }
    h2 { font-size: calc(var(--body-size) * 1.45); margin-top: 18pt; }
    code { border: 0; border-radius: 6px; padding: 1px 4px; }
    pre { border-radius: 6px; padding: 8pt 10pt; }
    blockquote { border-left: 4px solid var(--rule); padding-left: 12pt; }
    table { width: auto; }
    th, td { padding: 4pt 7pt; }
    """

    private static let antiqueStyle = """
    :root {
      --body-font: Baskerville, "Libre Baskerville", Georgia, serif;
      --heading-font: var(--body-font);
      --line-height: 1.62;
      --paragraph-gap: 9pt;
      --text: #17130C;
      --muted: #4A4033;
      --rule: #DCD2BE;
      --code-bg: #FBF7EE;
      --code-border: #E7DECB;
      --th-bg: #FAF5E9;
    }
    body { font-variant-numeric: oldstyle-nums; }
    h1 {
      text-align: center;
      font-weight: 400;
      font-size: calc(var(--body-size) * 2);
      letter-spacing: 0.02em;
      margin-bottom: 14pt;
    }
    h2 { font-weight: 400; font-size: calc(var(--body-size) * 1.4); }
    h3 { font-style: italic; font-weight: 400; }
    blockquote { font-style: italic; }
    """

    private static let inkStyle = """
    :root {
      --body-font: "Iowan Old Style", Palatino, "Times New Roman", Times, serif;
      --heading-font: var(--body-font);
      --line-height: 1.3;
      --paragraph-gap: 7pt;
      --text: #000000;
      --muted: #2E2E2E;
      --rule: #A8A8A8;
      --code-bg: #F7F7F7;
      --code-border: #DCDCDC;
      --th-bg: #F7F7F7;
    }
    h1, h2, h3, h4, h5, h6 {
      font-variant-caps: small-caps;
      letter-spacing: 0.07em;
      font-weight: 600;
    }
    /* Rules hang off the headings rather than sitting between paragraphs. */
    h1 {
      font-size: calc(var(--body-size) * 1.55);
      border-bottom: 1.5pt solid var(--text);
      padding-bottom: 3pt;
      margin-bottom: 9pt;
    }
    h2 {
      font-size: calc(var(--body-size) * 1.2);
      border-bottom: 0.5pt solid var(--rule);
      padding-bottom: 2pt;
    }
    h3 { font-size: var(--body-size); }
    blockquote { border-left-width: 2px; }
    """

    private static let academicStyle = """
    :root {
      --body-font: "Times New Roman", Times, serif;
      --heading-font: "Times New Roman", Times, serif;
      --line-height: 1.5;
      --paragraph-gap: 0pt;
      --rule: #C4C4C4;
    }
    /* Indent-led paragraphs: no gap between them, so every other block has to
       supply its own breathing room. */
    p { text-indent: 1.4em; }
    ul, ol, pre, blockquote, table { margin-top: 8pt; margin-bottom: 8pt; }
    h1, h2, h3, h4, h5, h6 { margin: 16pt 0 7pt; }
    h1 {
      text-align: center;
      font-size: calc(var(--body-size) * 1.4);
      font-weight: 700;
      margin-bottom: 12pt;
    }
    h2 { font-size: calc(var(--body-size) * 1.15); }
    h3 { font-size: var(--body-size); font-style: italic; font-weight: 400; }
    h1 + p, h2 + p, h3 + p, h4 + p, h5 + p, h6 + p { text-indent: 0; }
    li > p, blockquote p, td p, th p { text-indent: 0; }
    blockquote {
      margin-left: 18pt;
      padding-left: 0;
      border-left: 0;
      font-size: calc(var(--body-size) * 0.95);
      color: var(--text);
    }
    """
}
