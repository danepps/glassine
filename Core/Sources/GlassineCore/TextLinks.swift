import Foundation

/// Finds the web address under a click in a page's plain text, for PDFs that
/// print addresses without making them links (Word does this). PDFKit's own
/// detection stops at the end of the line, so an address the word processor
/// wrapped after "ginsburg-" opened as ".../ruth-bader-ginsburg-". This joins
/// the pieces back together first.
public enum TextLinks {
    /// Characters a wrapped address can break a line on. A period is left out
    /// on purpose: a line ending in "example.com." is almost always the end of
    /// a sentence, not a break inside an address.
    static let wrapEnders = Set("-/_=&?#~%+".utf16)

    /// Most lines an address is joined across; a guard against runaway joins.
    static let maxLines = 6

    static let schemes: Set<String> = ["http", "https", "mailto", "ftp"]

    /// The address covering the character at `index` (a UTF-16 offset into
    /// `text`, as `PDFPage.characterIndex(at:)` reports it), or nil.
    public static func url(in text: String, at index: Int) -> URL? {
        let s = text as NSString
        guard index >= 0, index < s.length, !isSpace(s.character(at: index)) else { return nil }
        var start = index, end = index + 1
        while start > 0, !isSpace(s.character(at: start - 1)) { start -= 1 }
        while end < s.length, !isSpace(s.character(at: end)) { end += 1 }
        let clicked = NSRange(location: start, length: end - start)

        var runs = [clicked]
        while runs.count < maxLines, let last = runs.last,
              wrapEnders.contains(s.character(at: NSMaxRange(last) - 1)),
              let next = run(after: NSMaxRange(last), in: s) {
            runs.append(next)
        }
        while runs.count < maxLines, let first = runs.first,
              let previous = run(before: first.location, in: s),
              wrapEnders.contains(s.character(at: NSMaxRange(previous) - 1)) {
            runs.insert(previous, at: 0)
        }

        var joined = ""
        var offset = 0
        for run in runs {
            if run == clicked { offset = (joined as NSString).length + (index - run.location) }
            joined += s.substring(with: run)
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let match = detector.matches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length))
            .first { NSLocationInRange(offset, $0.range) }
        guard let url = match?.url, let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else {
            return nil
        }
        return url
    }

    /// The word that starts the next line, when only whitespace including a
    /// line break separates it from `position`.
    private static func run(after position: Int, in s: NSString) -> NSRange? {
        var i = position, sawBreak = false
        while i < s.length, isSpace(s.character(at: i)) {
            sawBreak = sawBreak || isBreak(s.character(at: i))
            i += 1
        }
        guard sawBreak, i < s.length else { return nil }
        var end = i
        while end < s.length, !isSpace(s.character(at: end)) { end += 1 }
        return NSRange(location: i, length: end - i)
    }

    /// The word that ends the previous line, when only whitespace including a
    /// line break separates it from `position`.
    private static func run(before position: Int, in s: NSString) -> NSRange? {
        var i = position, sawBreak = false
        while i > 0, isSpace(s.character(at: i - 1)) {
            sawBreak = sawBreak || isBreak(s.character(at: i - 1))
            i -= 1
        }
        guard sawBreak, i > 0 else { return nil }
        var start = i
        while start > 0, !isSpace(s.character(at: start - 1)) { start -= 1 }
        return NSRange(location: start, length: i - start)
    }

    private static func isSpace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isBreak(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.newlines.contains(scalar)
    }
}
