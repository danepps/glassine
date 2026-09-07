import Foundation

/// One row of the Recents list: an entry from `Prefs.recentDocuments` after the
/// file has been located.
public struct RecentRow: Sendable, Equatable {
    public var url: URL
    /// The entry's stored path, which is how it is removed from the list. Not
    /// necessarily `url.path` -- a bookmark resolve rewrites one and not yet the
    /// other.
    public var key: String
    public var lastOpened: Date
    public var pageCount: Int?
    public var isMissing: Bool

    public init(url: URL, key: String, lastOpened: Date, pageCount: Int?, isMissing: Bool) {
        self.url = url
        self.key = key
        self.lastOpened = lastOpened
        self.pageCount = pageCount
        self.isMissing = isMissing
    }
}

/// The recents list as data: building the rows, filtering them, and the two
/// strings a row shows besides its name. The view (an `NSTableView` on the Mac,
/// a `List` on iOS) owns everything else.
public enum RecentsModel {

    /// Most recent first, each entry located: a moved file resolves through its
    /// bookmark and reads as itself rather than "Not found".
    public static func rows() -> [RecentRow] {
        Prefs.recentDocuments.map { entry in
            let resolved = Prefs.resolvedURL(for: entry)
            return RecentRow(url: resolved ?? entry.url,
                             key: resolved?.path ?? entry.path,
                             lastOpened: entry.lastOpened,
                             pageCount: entry.pageCount,
                             isMissing: resolved == nil)
        }
    }

    /// Case-insensitive, on the **file name** only -- filtering on the whole
    /// path would match every file in a folder whose name happens to contain
    /// the query. An empty (or all-whitespace) query keeps everything.
    public static func filter(_ rows: [RecentRow], query: String) -> [RecentRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(trimmed) }
    }

    /// The containing folder, plus how far in the reader got if there is a
    /// saved position. A Markdown file has no page count until it is typeset,
    /// so it shows just the page it was left on.
    public static func detailText(_ row: RecentRow,
                                  home: String = NSHomeDirectory()) -> String {
        let folder = row.url.deletingLastPathComponent().path
            .replacingOccurrences(of: home, with: "~")
        guard let position = Prefs.lastPosition(for: row.url) else { return folder }
        let page = position.pageIndex + 1
        if let count = row.pageCount, count > 0 {
            return "\(folder)  ·  p. \(page) of \(count)"
        }
        return "\(folder)  ·  p. \(page)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

    private static let olderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM y")
        return formatter
    }()

    public static func dateText(_ date: Date, now: Date = Date()) -> String {
        // A seeded entry can have no date at all: better blank than 1 Jan 2001.
        guard date > .distantPast else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today, " + timeFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return dayFormatter.string(from: date)
        }
        return olderFormatter.string(from: date)
    }
}
