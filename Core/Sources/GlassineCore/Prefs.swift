import Foundation

extension Notification.Name {
    public static let glassinePrefsChanged = Notification.Name("GlassinePrefsChanged")
}

/// System / Light / Dark override. The mapping onto a platform appearance
/// object lives with the platform: the Mac app extends this with
/// `nsAppearance` and installs `Prefs.applyAppearanceOverride`.
public enum AppearanceMode: Int, Sendable {
    case system = 0, light = 1, dark = 2
}

/// Which pane the sidebar shows. `recents` is iOS-only: the iPad sidebar puts
/// the recents picker beside Thumbnails and Contents, where the Mac has a start
/// tab instead. The Mac's segmented control only ever writes 0 or 1, and its
/// `applyMode` treats anything that is not `.outline` as thumbnails, so a
/// preference file written on an iPad is harmless there.
public enum SidebarMode: Int, Sendable {
    case thumbnails = 0, outline = 1, recents = 2
}

/// A file Glassine has opened, remembered for the Recents window. The path is
/// what the list shows and what keys the reading position; the bookmark is what
/// still finds the file after a rename or a move.
public struct RecentDocument: Sendable {
    public var path: String
    /// Made with `bookmarkData()` and its default options. On iOS a bookmark
    /// made that way is implicitly security-scoped, so the resolver there has
    /// to call `startAccessingSecurityScopedResource()` before reading the file.
    public var bookmark: Data?
    public var lastOpened: Date
    /// Pages the document had when it was last opened. Nil for Markdown, whose
    /// page count is not known until it has been typeset.
    public var pageCount: Int?

    public var url: URL { URL(fileURLWithPath: path) }

    public init(path: String, bookmark: Data?, lastOpened: Date, pageCount: Int?) {
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
public enum Prefs {
    /// `.standard` in both apps; a test swaps in an isolated suite.
    nonisolated(unsafe) public static var defaults = UserDefaults.standard

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

    /// The key the Mac app's one-time recents seed writes; the seed itself needs
    /// NSDocumentController and so stays platform-side.
    public static let recentDocumentsSeededKey = Key.recentDocumentsSeeded

    /// Where custom Markdown stylesheets live. The default is the Mac's
    /// `~/Library/Application Support/Glassine/Styles`, computed exactly as it
    /// always was; the iOS app points this at its own `Documents/Styles` at
    /// launch, so the folder shows up in the Files app.
    nonisolated(unsafe) public static var stylesDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Glassine/Styles", isDirectory: true)
    }()

    /// Installed by the app at launch: applying a Light/Dark override is the one
    /// thing about an appearance that only the platform can do (`NSApp.appearance`
    /// on the Mac, `overrideUserInterfaceStyle` on iOS). Called synchronously
    /// from the `appearance` setter, before the change notification goes out.
    nonisolated(unsafe) public static var applyAppearanceOverride: ((AppearanceMode) -> Void)?

    /// Sizes offered in View ▸ Markdown ▸ Size.
    public static let markdownFontSizes = [10, 11, 12, 13]

    /// Render page content light-on-dark when the app is in dark mode. Default on.
    public static var invertInDarkMode: Bool {
        get { defaults.object(forKey: Key.invertInDarkMode) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.invertInDarkMode)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// How dark the inverted page reads. Default black, which is the plain
    /// inversion with no extra filter stage.
    public static var darkPaper: DarkPaper {
        get { DarkPaper(rawValue: defaults.integer(forKey: Key.darkPaper)) ?? .black }
        set {
            defaults.set(newValue.rawValue, forKey: Key.darkPaper)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// System / Light / Dark override. Default follows the system.
    public static var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.integer(forKey: Key.appearance)) ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appearance)
            applyAppearanceOverride?(newValue)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// Preferred sidebar pane. A document with no outline falls back to
    /// thumbnails without disturbing this.
    public static var sidebarMode: SidebarMode {
        get { SidebarMode(rawValue: defaults.integer(forKey: Key.sidebarMode)) ?? .thumbnails }
        set {
            defaults.set(newValue.rawValue, forKey: Key.sidebarMode)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    // MARK: Window opacity

    public static let minWindowOpacity = 0.3
    public static let maxWindowOpacity = 1.0
    /// One press of Increase/Decrease Opacity.
    public static let windowOpacityStep = 0.1

    /// Alpha applied to every reader window. Default fully opaque.
    public static var windowOpacity: Double {
        get { clampOpacity(defaults.object(forKey: Key.windowOpacity) as? Double ?? 1) }
        set {
            defaults.set(clampOpacity(newValue), forKey: Key.windowOpacity)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// Blur whatever shows through a translucent window, the way Terminal does.
    /// Only has an effect below full opacity. Default on.
    public static var windowBlur: Bool {
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
    public static var markdownStyle: String {
        get { defaults.string(forKey: Key.markdownStyle) ?? MarkdownStyle.defaultID }
        set {
            defaults.set(newValue, forKey: Key.markdownStyle)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// Paginated or one continuous page. Default paginated.
    public static var markdownLayout: MarkdownLayout {
        get { MarkdownLayout(rawValue: defaults.integer(forKey: Key.markdownLayout)) ?? .pages }
        set {
            defaults.set(newValue.rawValue, forKey: Key.markdownLayout)
            NotificationCenter.default.post(name: .glassinePrefsChanged, object: nil)
        }
    }

    /// Body point size for rendered Markdown. Default 11.
    public static var markdownFontSize: Int {
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

    public struct Position: Sendable, Equatable {
        public var pageIndex: Int
        public var x: CGFloat
        public var y: CGFloat

        public init(pageIndex: Int, x: CGFloat, y: CGFloat) {
            self.pageIndex = pageIndex
            self.x = x
            self.y = y
        }
    }

    /// Entries are `[page, x, y, lastAccessed]`; older three-element entries
    /// still read (and are treated as least recently used).
    public static func lastPosition(for url: URL) -> Position? {
        let table = defaults.dictionary(forKey: Key.lastPositions) ?? [:]
        guard let raw = table[url.path] as? [Double], raw.count >= 3 else { return nil }
        return Position(pageIndex: Int(raw[0]), x: raw[1], y: raw[2])
    }

    private static let maxPositions = 500

    public static func setLastPosition(_ position: Position, for url: URL) {
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
    public static func lastAccess(for url: URL) -> Date? {
        let table = defaults.dictionary(forKey: Key.lastPositions) ?? [:]
        guard let raw = table[url.path] as? [Double], raw.count >= 4 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw[3])
    }

    /// Files with a saved reading position, most recently read first. One of the
    /// two sources the Mac app's one-time recents seed draws on.
    public static func positionedPaths() -> [String] {
        let table = defaults.dictionary(forKey: Key.lastPositions) ?? [:]
        return table.keys.sorted { accessStamp(table[$0]) > accessStamp(table[$1]) }
    }

    // MARK: Recent documents

    public static let maxRecentDocuments = 30

    /// Most recent first, capped. Glassine's own list rather than
    /// NSDocumentController's, because that one is ten items long, carries no
    /// dates, and holds only paths.
    public static var recentDocuments: [RecentDocument] {
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
    public static func noteRecentDocument(_ url: URL, pageCount: Int?) {
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

    /// Block until every queued `noteRecentDocument` has been written. Only
    /// worth calling where the writes have to have landed before something else
    /// reads them -- a test, or a deliberate flush before quitting.
    public static func flushRecentDocumentWrites() {
        recentsQueue.sync {}
    }

    public static func removeRecentDocument(path: String) {
        var list = recentDocuments
        list.removeAll { $0.path == path }
        recentDocuments = list
    }

    /// Where the entry's file is now: its stored path if that still exists,
    /// otherwise wherever the bookmark leads. A resolved move is written back,
    /// so the row shows the new location instead of "Not found". Nil means the
    /// file is really gone.
    public static func resolvedURL(for entry: RecentDocument) -> URL? {
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
}
