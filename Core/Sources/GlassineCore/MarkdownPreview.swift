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
        let body = converted.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "<p class=\"preview-notice\">This Markdown file is empty.</p>" : converted.html
        return page(body: body, title: url.lastPathComponent)
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
