import Foundation

/// The `glassine:` URL scheme, which opens a local file in Glassine.
///
/// Accepted forms (all name the same file):
///
///     glassine:///Users/dan/Memo.md
///     glassine://open?path=/Users/dan/Memo.md
///     glassine://open?file=/Users/dan/Memo.md
///     glassine://open?url=file:///Users/dan/Memo.md
///     glassine://Users/dan/Memo.md      (forgiving: host taken as the first folder)
///     glassine:~/Memo.md                (a leading ~ is expanded)
///
/// Spaces may be percent-encoded or, where a terminal passes them through, left
/// literal. Only file locations come out; anything else yields nil.
public enum GlassineURL {

    public static let scheme = "glassine"

    /// The file URL `url` names, or nil if it is not a usable `glassine:` link.
    public static func fileURL(from url: URL) -> URL? {
        fileURL(fromString: url.absoluteString)
    }

    public static func fileURL(fromString raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":"),
              trimmed[..<colon].lowercased() == scheme else { return nil }
        var rest = String(trimmed[trimmed.index(after: colon)...])

        // Query forms: glassine://open?path=… (also file= / url=).
        if let comps = URLComponents(string: "x:" + rest),
           let items = comps.queryItems, !items.isEmpty {
            for name in ["path", "file", "url"] {
                if let value = items.first(where: { $0.name.lowercased() == name })?.value,
                   !value.isEmpty {
                    return location(from: value)
                }
            }
            return nil
        }

        // Path forms. Strip the authority marker; a lone "open" host is a verb.
        if rest.hasPrefix("//") {
            rest.removeFirst(2)
            if rest.lowercased().hasPrefix("open/") { rest.removeFirst(4) }
        }
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }
        let decoded = rest.removingPercentEncoding ?? rest
        guard !decoded.isEmpty else { return nil }
        if decoded.hasPrefix("/") || decoded.hasPrefix("~") {
            return location(from: decoded)
        }
        // glassine://Users/dan/x.md: the "host" was really the first folder.
        return location(from: "/" + decoded)
    }

    private static func location(from value: String) -> URL? {
        if value.lowercased().hasPrefix("file:") {
            guard let url = URL(string: value) ?? URL(string: value.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed.union([":"])) ?? ""),
                  url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        let path = (value as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
