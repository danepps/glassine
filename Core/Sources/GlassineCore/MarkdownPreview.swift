import Foundation

/// The small, self-contained document handed to the system's Quick Look HTML
/// viewer. It shares parsing and typography with the reader, but has no PDF
/// generation, preferences writes, network access or custom stylesheet lookup.
public enum MarkdownPreview {
    public static let maximumFileSize = 2 * 1024 * 1024

    public static func html(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        if let size = values.fileSize, size > maximumFileSize {
            return notice("This file is too large to preview. Open it in Glassine to read the full document.", title: url.lastPathComponent)
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // Recheck after a bounded read: the file may have grown since stat.
        let data = try file.read(upToCount: maximumFileSize + 1) ?? Data()
        guard data.count <= maximumFileSize else {
            return notice("This file is too large to preview. Open it in Glassine to read the full document.", title: url.lastPathComponent)
        }
        let text = try MarkdownHTML.decode(data, url: url)
        let converted = MarkdownHTML.body(fromMarkdown: text,
                                          baseDirectory: url.deletingLastPathComponent(),
                                          output: .preview)
        if converted.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return notice("This Markdown file is empty.", title: url.lastPathComponent)
        }
        guard let outline = outline(converted.headings) else {
            return page(body: converted.html, title: url.lastPathComponent)
        }
        return page(body: outline + "\n<main class=\"preview-body\">\n"
                        + converted.html + "</main>",
                    title: url.lastPathComponent)
    }

    /// The headings column: one ordinary fragment link per heading, to the
    /// `id` the anchorer gave it. No script (the CSP allows none), so there is
    /// no current-section highlight and nothing collapses.
    ///
    /// nil for a document with fewer than two listable headings, which keeps
    /// today's single-column page. A heading with no text is left out: its
    /// link would be an empty line. (Its slug is never empty -- the anchorer
    /// falls back to `section` -- but one built without a slug is skipped too,
    /// so every href names an `id` that is really in the body.)
    static func outline(_ headings: [MarkdownHeading]) -> String? {
        let listed = headings.filter { !$0.slug.isEmpty && !$0.title.isEmpty }
        guard listed.count >= 2, let top = listed.map(\.level).min() else { return nil }
        let items = listed.map { heading -> String in
            let title = MarkdownHTML.escape(heading.title)
            return "<li class=\"outline-depth-\(heading.level - top)\">"
                + "<a href=\"#\(MarkdownHTML.escape(heading.slug))\" title=\"\(title)\">"
                + title + "</a></li>"
        }
        return "<nav class=\"preview-outline\" aria-label=\"Contents\"><ul>\n"
            + items.joined(separator: "\n") + "\n</ul></nav>"
    }

    private static func notice(_ message: String, title: String) -> Data {
        // Only fixed, developer-authored messages reach this helper.
        page(body: "<p class=\"preview-notice\">\(message)</p>", title: title)
    }

    private static func page(body: String, title: String) -> Data {
        let style = MarkdownStyling(styleID: MarkdownStyle.defaultID,
                                    css: MarkdownHTML.builtInStyle(MarkdownStyle.defaultID),
                                    size: 12, layout: .continuous)
        return Data(MarkdownHTML.page(body: body, title: title, styling: style,
                                      platformCSS: previewCSS).utf8)
    }

    private static let previewCSS = """
    :root { color-scheme: light dark; }
    html { background: var(--paper); }
    body {
      box-sizing: border-box;
      max-width: 54rem;
      margin: 0 auto;
      padding: 32px clamp(20px, 5vw, 56px) 48px;
      overflow-wrap: anywhere;
    }
    h1, h2, h3, h4, h5, h6 { scroll-margin-top: 24px; }
    a[href]:hover { text-decoration: underline; }
    /* A link whose destination was stripped (a relative file, an unsafe
       scheme) is plain text now and must not dress as a link. */
    a:not([href]) { color: inherit; }
    img { height: auto; }
    table { display: block; overflow-x: auto; }
    .preview-notice { color: var(--muted); }
    /* The headings column, present only for two or more headings. Below
       700px it is hidden and <main> is an unstyled block, so the page is
       laid out exactly as one without the column. */
    .preview-outline { display: none; }
    @media (min-width: 700px) {
      body:has(> .preview-outline) { max-width: none; margin: 0; padding: 0 0 0 200px; }
      .preview-outline {
        display: block;
        position: fixed;
        top: 0;
        bottom: 0;
        left: 0;
        width: 200px;
        box-sizing: border-box;
        overflow-y: auto;
        padding: 32px 12px 32px 16px;
        background: var(--paper);
        border-right: 1px solid var(--rule);
        font: 12px/1.35 -apple-system, system-ui, sans-serif;
        overflow-wrap: normal;
      }
      .preview-outline ul { list-style: none; margin: 0; padding: 0; }
      .preview-outline li { margin: 0; padding: 2px 0; }
      .preview-outline a {
        display: block;
        color: var(--muted);
        text-decoration: none;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }
      .preview-outline a:hover { color: var(--text); text-decoration: none; }
      .preview-outline .outline-depth-0 { font-weight: 600; }
      .preview-outline .outline-depth-0:not(:first-child) { margin-top: 6px; }
      .preview-outline .outline-depth-1 { padding-left: 12px; }
      .preview-outline .outline-depth-2 { padding-left: 24px; }
      .preview-outline .outline-depth-3 { padding-left: 36px; }
      .preview-outline .outline-depth-4 { padding-left: 48px; }
      .preview-outline .outline-depth-5 { padding-left: 60px; }
      .preview-body {
        box-sizing: border-box;
        max-width: 54rem;
        margin: 0 auto;
        padding: 32px clamp(24px, 4vw, 56px) 48px;
      }
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --paper: #181818;
        --text: #EEEEEE;
        --muted: #B5B5B5;
        --rule: #484848;
        --code-bg: #252525;
        --code-border: #404040;
        --th-bg: #292929;
        --link: #8AB4F8;
      }
    }
    """
}
