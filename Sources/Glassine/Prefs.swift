import AppKit

extension Notification.Name {
    static let glassinePrefsChanged = Notification.Name("GlassinePrefsChanged")
    /// Posted by a GlassineDocument (as `object`) once a new PDFDocument has taken
    /// the place of the old one -- the first Markdown render, a reload after the
    /// file changed on disk, or a typography change. `userInfo["initial"]` is
    /// true for the first render of a window.
    static let glassineDocumentDidReplacePDF = Notification.Name("GlassineDocumentDidReplacePDF")
}

enum AppearanceMode: Int {
    case system = 0, light = 1, dark = 2

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// How rendered Markdown is laid out: real Letter pages, or one tall page the
/// reader scrolls through without a break.
enum MarkdownLayout: Int {
    case pages = 0, continuous = 1

    var title: String {
        switch self {
        case .pages: return "Pages"
        case .continuous: return "Continuous"
        }
    }
}

/// A stylesheet for rendered Markdown: one of the built-ins, whose CSS lives in
/// `MarkdownHTML`, or a `.css` file the reader dropped into Application Support.
struct MarkdownStyle: Equatable {
    var id: String
    var title: String
    /// nil for a built-in.
    var url: URL?

    static let defaultID = "manuscript"
    static let customPrefix = "custom:"

    static let builtIns: [MarkdownStyle] = [
        MarkdownStyle(id: "manuscript", title: "Manuscript"),
        MarkdownStyle(id: "modern", title: "Modern"),
        MarkdownStyle(id: "github", title: "GitHub"),
        MarkdownStyle(id: "antique", title: "Antique"),
        MarkdownStyle(id: "ink", title: "Ink"),
        MarkdownStyle(id: "academic", title: "Academic")
    ]

    /// ~/Library/Application Support/Glassine/Styles
    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Glassine/Styles", isDirectory: true)
    }

    /// The `.css` files in that folder, in name order. Read every time the Style
    /// menu opens, so a newly dropped file needs no relaunch.
    static func customStyles() -> [MarkdownStyle] {
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
    static func css(forID id: String) -> String {
        guard id.hasPrefix(customPrefix) else { return MarkdownHTML.builtInStyle(id) }
        let name = String(id.dropFirst(customPrefix.count))
        let url = folder.appendingPathComponent(name).appendingPathExtension("css")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return MarkdownHTML.builtInStyle(defaultID)
        }
        return text
    }
}

/// Which pane the sidebar shows.
enum SidebarMode: Int {
    case thumbnails = 0, outline = 1
}

/// How dark the paper gets in inverted dark mode. `black` is the plain
/// inversion; the other two add a tone-compression stage that lifts the page
/// off pure black. Only meaningful while pages are being inverted.
enum DarkPaper: Int {
    case black = 0, charcoal = 1, gray = 2

    var title: String {
        switch self {
        case .black: return "Black Paper"
        case .charcoal: return "Charcoal Paper"
        case .gray: return "Gray Paper"
        }
    }

    /// The two ends of the compressed range, as on-screen greys: paper
    /// (inverted black) rises to `lift`, ink (inverted white) falls to `top`.
    /// `lift` is also the window's chrome colour, so the two always match.
    /// Tuned by eye against a text-heavy PDF; edit here to re-tune.
    var lift: CGFloat {
        switch self {
        case .black: return 0
        case .charcoal: return 0.11
        case .gray: return 0.17
        }
    }

    var top: CGFloat {
        switch self {
        case .black: return 1
        case .charcoal: return 0.93
        case .gray: return 0.90
        }
    }
}

/// A file Glassine has opened, remembered for the Recents window. The path is
/// what the list shows and what keys the reading position; the bookmark is what
/// still finds the file after a rename or a move.
struct RecentDocument {
    var path: String
    var bookmark: Data?
    var lastOpened: Date
    /// Pages the document had when it was last opened. Nil for Markdown, whose
    /// page count is not known until it has been typeset.
    var pageCount: Int?

    var url: URL { URL(fileURLWithPath: path) }

    init(path: String, bookmark: Data?, lastOpened: Date, pageCount: Int?) {
        self.path = path
        self.bookmark = bookmark
        self.lastOpened = lastOpened
        self.pageCount = pageCount
    }

    fileprivate init?(stored: [String: Any]) {
        guard let path = stored["path"] as? String else { return nil }
        self.path = path
        bookmark = stored["bookmark"] as? Data
        lastOpened = (stored["date"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
            ?? .distantPast
        pageCount = stored["pages"] as? Int
    }

    fileprivate var stored: [String: Any] {
        var value: [String: Any] = ["path": path,
                                    "date": lastOpened.timeIntervalSinceReferenceDate]
        if let bookmark { value["bookmark"] = bookmark }
        if let pageCount { value["pages"] = pageCount }
        return value
    }
}

/// User preferences. Small on purpose; everything defaults to "follow the system".
enum Prefs {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let invertInDarkMode = "invertInDarkMode"
        static let darkPaper = "darkPaper"
        static let appearance = "appearance"
        static let lastPositions = "lastPositions"
        static let markdownStyle = "markdownStyle"
        static let markdownLayout = "markdownLayout"
        static let markdownFontSize = "markdownFontSize"
        static let sidebarMode = "sidebarMode"
        static let windowOpacity = "windowOpacity"
        static let windowBlur = "windowBlur"
        static let recentDocuments = "recentDocuments"
        static let recentDocumentsSeeded = "recentDocumentsSeeded"
    }

    /// Sizes offered in View ▸ Markdown ▸ Size.
    static let markdownFontSizes = [10, 11, 12, 13]

    /// Render page content light-on-dark when the app is in dark mode. Default on.
    static var invertInDarkMode: Bool {
        get { defaults.object(forKey: Key.invertInDarkMode) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.invertInDarkMode)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// How dark the inverted page reads. Default black, which is the plain
    /// inversion with no extra filter stage.
    static var darkPaper: DarkPaper {
        get { DarkPaper(rawValue: defaults.integer(forKey: Key.darkPaper)) ?? .black }
        set {
            defaults.set(newValue.rawValue, forKey: Key.darkPaper)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// System / Light / Dark override. Default follows the system.
    static var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.integer(forKey: Key.appearance)) ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appearance)
            NSApp.appearance = newValue.nsAppearance
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// Preferred sidebar pane. A document with no outline falls back to
    /// thumbnails without disturbing this.
    static var sidebarMode: SidebarMode {
        get { SidebarMode(rawValue: defaults.integer(forKey: Key.sidebarMode)) ?? .thumbnails }
        set {
            defaults.set(newValue.rawValue, forKey: Key.sidebarMode)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    // MARK: Window opacity

    static let minWindowOpacity = 0.3
    static let maxWindowOpacity = 1.0
    /// One press of Increase/Decrease Opacity.
    static let windowOpacityStep = 0.1

    /// Alpha applied to every reader window. Default fully opaque.
    static var windowOpacity: Double {
        get { clampOpacity(defaults.object(forKey: Key.windowOpacity) as? Double ?? 1) }
        set {
            defaults.set(clampOpacity(newValue), forKey: Key.windowOpacity)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// Blur whatever shows through a translucent window, the way Terminal does.
    /// Only has an effect below full opacity. Default on.
    static var windowBlur: Bool {
        get { defaults.object(forKey: Key.windowBlur) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.windowBlur)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// Rounded to the step, or repeated ⌥⌘↑ lands on 0.9999… and the menu item
    /// never notices it has reached the top.
    private static func clampOpacity(_ value: Double) -> Double {
        min(max((value * 100).rounded() / 100, minWindowOpacity), maxWindowOpacity)
    }

    // MARK: Markdown typography

    /// Stylesheet for rendered Markdown, by id. Default the Manuscript built-in.
    static var markdownStyle: String {
        get { defaults.string(forKey: Key.markdownStyle) ?? MarkdownStyle.defaultID }
        set {
            defaults.set(newValue, forKey: Key.markdownStyle)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// Paginated or one continuous page. Default paginated.
    static var markdownLayout: MarkdownLayout {
        get { MarkdownLayout(rawValue: defaults.integer(forKey: Key.markdownLayout)) ?? .pages }
        set {
            defaults.set(newValue.rawValue, forKey: Key.markdownLayout)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// Body point size for rendered Markdown. Default 11.
    static var markdownFontSize: Int {
        get {
            let stored = defaults.integer(forKey: Key.markdownFontSize)
            return markdownFontSizes.contains(stored) ? stored : 11
        }
        set {
            guard markdownFontSizes.contains(newValue) else { return }
            defaults.set(newValue, forKey: Key.markdownFontSize)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    // MARK: Reading position memory (per file path)

    struct Position {
        var pageIndex: Int
        var x: CGFloat
        var y: CGFloat
    }

    /// Entries are `[page, x, y, lastAccessed]`; older three-element entries
    /// still read (and are treated as least recently used).
    static func lastPosition(for url: URL) -> Position? {
        let table = defaults.dictionary(forKey: Key.lastPositions) ?? [:]
        guard let raw = table[url.path] as? [Double], raw.count >= 3 else { return nil }
        return Position(pageIndex: Int(raw[0]), x: raw[1], y: raw[2])
    }

    private static let maxPositions = 500

    static func setLastPosition(_ position: Position, for url: URL) {
        var table = defaults.dictionary(forKey: Key.lastPositions) ?? [:]
        table[url.path] = [Double(position.pageIndex), Double(position.x), Double(position.y),
                           Date().timeIntervalSinceReferenceDate]
        // Keep the table bounded by evicting the least recently used entries.
        if table.count > maxPositions {
            let byAge = table.keys.sorted { lhs, rhs in
                accessStamp(table[lhs]) < accessStamp(table[rhs])
            }
            for key in byAge.prefix(table.count - maxPositions) {
                table.removeValue(forKey: key)
            }
        }
        defaults.set(table, forKey: Key.lastPositions)
    }

    private static func accessStamp(_ raw: Any?) -> Double {
        guard let values = raw as? [Double], values.count >= 4 else { return 0 }
        return values[3]
    }

    /// When a reading position for this file was last written. The closest thing
    /// to a "last opened" stamp for a document from before the recents list.
    static func lastAccess(for url: URL) -> Date? {
        let table = defaults.dictionary(forKey: Key.lastPositions) ?? [:]
        guard let raw = table[url.path] as? [Double], raw.count >= 4 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw[3])
    }

    // MARK: Recent documents

    static let maxRecentDocuments = 30

    /// Most recent first, capped. Glassine's own list rather than
    /// NSDocumentController's, because that one is ten items long, carries no
    /// dates, and holds only paths.
    static var recentDocuments: [RecentDocument] {
        get {
            let stored = defaults.array(forKey: Key.recentDocuments) as? [[String: Any]] ?? []
            return stored.compactMap(RecentDocument.init(stored:))
        }
        set {
            defaults.set(newValue.prefix(maxRecentDocuments).map(\.stored),
                         forKey: Key.recentDocuments)
        }
    }

    /// Documents can be read concurrently, and this is a read-modify-write of
    /// one defaults key that also makes a bookmark, which reads the file. One
    /// serial queue, off the main thread, settles both.
    private static let recentsQueue = DispatchQueue(label: "com.epps.Glassine.recents")

    /// Record an open: the file moves to the front and takes today's date.
    static func noteRecentDocument(_ url: URL, pageCount: Int?) {
        let file = url.standardizedFileURL
        recentsQueue.async {
            var list = recentDocuments
            list.removeAll { $0.path == file.path }
            list.insert(RecentDocument(path: file.path,
                                       bookmark: try? file.bookmarkData(),
                                       lastOpened: Date(),
                                       pageCount: pageCount),
                        at: 0)
            recentDocuments = list
        }
    }

    static func removeRecentDocument(path: String) {
        var list = recentDocuments
        list.removeAll { $0.path == path }
        recentDocuments = list
    }

    /// Where the entry's file is now: its stored path if that still exists,
    /// otherwise wherever the bookmark leads. A resolved move is written back,
    /// so the row shows the new location instead of "Not found". Nil means the
    /// file is really gone.
    static func resolvedURL(for entry: RecentDocument) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: entry.path) { return entry.url }
        guard let bookmark = entry.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              fm.fileExists(atPath: url.path)
        else { return nil }

        // Standardized, so the returned URL and the rewritten entry agree on the
        // path -- which is what the Recents list keys a row by.
        let moved = url.standardizedFileURL
        var list = recentDocuments
        if let index = list.firstIndex(where: { $0.path == entry.path }) {
            list[index].path = moved.path
            if stale { list[index].bookmark = try? moved.bookmarkData() }
            recentDocuments = list
        }
        return moved
    }

    /// First launch after the recents list arrived: adopt whatever
    /// NSDocumentController remembers, then any file with a saved reading
    /// position it did not mention. The second source matters because the
    /// system recent-documents list is empty whenever macOS is set to keep no
    /// recent items, while the position table is Glassine's own and dated.
    static func seedRecentDocumentsIfNeeded() {
        guard defaults.object(forKey: Key.recentDocumentsSeeded) == nil else { return }
        defaults.set(true, forKey: Key.recentDocumentsSeeded)
        guard recentDocuments.isEmpty else { return }

        let fm = FileManager.default
        var seen = Set<String>()
        var seeded: [RecentDocument] = []

        for url in NSDocumentController.shared.recentDocumentURLs {
            let path = url.standardizedFileURL.path
            guard fm.fileExists(atPath: path), seen.insert(path).inserted else { continue }
            seeded.append(entry(forSeeding: URL(fileURLWithPath: path)))
        }
        for path in positionedPaths() where !seen.contains(path) && fm.fileExists(atPath: path) {
            seen.insert(path)
            seeded.append(entry(forSeeding: URL(fileURLWithPath: path)))
        }

        // The two sources are each in their own order, so sort the whole thing.
        recentDocuments = seeded.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Deliberately no bookmark: making one reads the file, and doing that for
    /// thirty files during launch draws a privacy prompt for every protected
    /// folder they sit in, before the reader has asked for anything. A seeded
    /// entry earns its bookmark the first time it is actually opened.
    private static func entry(forSeeding url: URL) -> RecentDocument {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return RecentDocument(path: url.path,
                              bookmark: nil,
                              lastOpened: lastAccess(for: url) ?? modified ?? .distantPast,
                              pageCount: nil)
    }

    /// Files with a saved reading position, most recently read first.
    private static func positionedPaths() -> [String] {
        let table = defaults.dictionary(forKey: Key.lastPositions) ?? [:]
        return table.keys.sorted { accessStamp(table[$0]) > accessStamp(table[$1]) }
    }
}
