import Foundation

/// An immutable export snapshot; the formatter never touches a live PDF.
public struct HighlightExcerpt: Sendable {
    public let text: String
    public let note: String
    public let pageIndex: Int
    public let pageLabel: String
    public let color: String

    public init(text: String, note: String, pageIndex: Int, pageLabel: String, color: String) {
        self.text = text
        self.note = note
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.color = color
    }

    public var pageReference: String {
        let number = String(pageIndex + 1)
        return pageLabel == number || pageLabel.isEmpty ? "Page \(number)" : "Page \(pageLabel) · PDF \(number)"
    }
}

public enum HighlightMarkdown {
    public static func render(_ excerpts: [HighlightExcerpt], title: String, sourceURL: URL?) -> String {
        var lines = ["# Highlights — \(escape(title))", ""]
        if let sourceURL {
            lines += ["Source: [\(escape(sourceURL.lastPathComponent))](<\(sourceURL.absoluteString)>)", ""]
        }
        let notes = excerpts.filter { !$0.note.isEmpty }.count
        lines += ["\(excerpts.count) \(excerpts.count == 1 ? "highlight" : "highlights"), \(notes) \(notes == 1 ? "note" : "notes").", ""]
        var previousPage: Int?
        for excerpt in excerpts {
            if previousPage != excerpt.pageIndex {
                lines += ["## \(escape(excerpt.pageReference))", ""]
                previousPage = excerpt.pageIndex
            }
            if excerpt.text.isEmpty { lines += ["*No extractable text.*", ""] }
            else { lines += escape(excerpt.text).components(separatedBy: "\n").map { "> \($0)" } + [""] }
            if !excerpt.note.isEmpty { lines += ["**Note:** \(escape(excerpt.note))", ""] }
            var reference = escape(excerpt.pageReference)
            if let sourceURL, var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: true) {
                components.fragment = "page=\(excerpt.pageIndex + 1)"
                if let url = components.url { reference = "[\(reference)](<\(url.absoluteString)>)" }
            }
            lines += ["\(escape(excerpt.color)) · \(reference)", "", "---", ""]
        }
        return lines.joined(separator: "\n")
    }

    /// PDF text and notes are plain text, not executable HTML or Markdown.
    private static func escape(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let escaped = normalized.map { "\\`*_[]<>#|~".contains($0) ? "\\\($0)" : String($0) }.joined()
        return escaped.components(separatedBy: "\n").map { line in
            if line.hasPrefix("- ") || line.hasPrefix("+ ") { return "\\" + line }
            return line.replacingOccurrences(of: #"^(\s*\d+)([.)]) "#, with: #"$1\\$2 "#, options: .regularExpression)
        }.joined(separator: "\n")
    }
}
