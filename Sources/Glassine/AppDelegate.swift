import AppKit
import GlassineCore
import Sparkle
import UniformTypeIdentifiers

extension AppearanceMode {
    /// The Mac's half of the appearance override. Core knows only the three
    /// modes; turning one into an `NSAppearance` is AppKit's business.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Application delegate. Deliberately thin: NSDocumentController does the file
/// handling, and each window controller owns its own state.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {

    /// Sparkle. Starting the updater here (rather than lazily) lets it run its
    /// scheduled background check; `SUEnableAutomaticChecks` in Info.plist is
    /// the default, and the user's own choice overrides it thereafter. The
    /// controller is also the target of the "Check for Updates…" menu item.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before anything reads a preference, and so before a window exists.
        FolioMigration.runIfNeeded()
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
        // The hook Prefs calls from its `appearance` setter, installed before
        // anything can write the preference.
        Prefs.applyAppearanceOverride = { mode in
            MainActor.assumeIsolated { NSApp.appearance = mode.nsAppearance }
        }
        // Apply a saved Light/Dark override before any window exists.
        NSApp.appearance = Prefs.appearance.nsAppearance
        // Instantiating the shared controller early makes Finder opens and the
        // Open Recent menu work from the first event loop pass.
        _ = NSDocumentController.shared
    }

    /// Set once the app is on its way out, so a window closing during quit does
    /// not flash the Recents window on the way.
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        Prefs.seedRecentDocumentsIfNeeded()
        observeDocumentWindows()
        // A file double-clicked in the Finder arrives as its own Apple Event,
        // which can be delivered either side of this method and opens its
        // document asynchronously. Checking after a beat, rather than now, is
        // what keeps the Recents window from flashing in front of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchCheckDelay) { [weak self] in
            self?.showRecentsIfNoDocuments()
        }
    }

    private static let launchCheckDelay = 0.2

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
    }

    // Launching or reopening with nothing on screen shows the Recents window,
    // not an Open panel: the reader's own files are more use than the file tree.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { RecentsWindowController.shared.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Recents

    @objc func showRecents(_ sender: Any?) {
        RecentsWindowController.shared.show()
    }

    private func observeDocumentWindows() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard isReaderWindow(notification.object) else { return }
        RecentsWindowController.shared.hide()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard isReaderWindow(notification.object) else { return }
        // The window is still on screen at this point, and closing one tab of a
        // multi-tab window closes a window too -- so ask on the next turn,
        // when what is left is what is really left.
        DispatchQueue.main.async { [weak self] in
            self?.showRecentsIfNoDocuments()
        }
    }

    private func isReaderWindow(_ object: Any?) -> Bool {
        (object as? NSWindow)?.tabbingIdentifier == ReaderWindowController.tabbingIdentifier
    }

    private func showRecentsIfNoDocuments() {
        guard !isTerminating, !ReaderWindowController.anyWindowIsOpen else { return }
        RecentsWindowController.shared.show()
    }

    // MARK: Menu actions

    @objc func setAppearance(_ sender: NSMenuItem) {
        guard let mode = AppearanceMode(rawValue: sender.tag) else { return }
        Prefs.appearance = mode
    }

    @objc func toggleInvertInDarkMode(_ sender: NSMenuItem) {
        Prefs.invertInDarkMode.toggle()
    }

    @objc func setDarkPaper(_ sender: NSMenuItem) {
        guard let paper = DarkPaper(rawValue: sender.tag) else { return }
        Prefs.darkPaper = paper
    }

    /// The paper levels are stages of the inversion filter, so they do nothing
    /// unless pages are actually being inverted right now.
    private var isInvertingNow: Bool {
        Prefs.invertInDarkMode
            && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    @objc func increaseOpacity(_ sender: Any?) {
        Prefs.windowOpacity += Prefs.windowOpacityStep
    }

    @objc func decreaseOpacity(_ sender: Any?) {
        Prefs.windowOpacity -= Prefs.windowOpacityStep
    }

    @objc func toggleWindowBlur(_ sender: NSMenuItem) {
        Prefs.windowBlur.toggle()
    }

    @objc func setMarkdownStyle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.markdownStyle = id
    }

    @objc func setMarkdownLayout(_ sender: NSMenuItem) {
        guard let layout = MarkdownLayout(rawValue: sender.tag) else { return }
        Prefs.markdownLayout = layout
    }

    @objc func setMarkdownFontSize(_ sender: NSMenuItem) {
        Prefs.markdownFontSize = sender.tag
    }

    /// Larger/Smaller Text walk the same four sizes the Text Size submenu
    /// lists, and are disabled at either end rather than wrapping around.
    @objc func increaseMarkdownFontSize(_ sender: Any?) {
        stepMarkdownFontSize(by: 1)
    }

    @objc func decreaseMarkdownFontSize(_ sender: Any?) {
        stepMarkdownFontSize(by: -1)
    }

    private func stepMarkdownFontSize(by delta: Int) {
        let sizes = Prefs.markdownFontSizes
        guard let index = sizes.firstIndex(of: Prefs.markdownFontSize) else { return }
        let next = index + delta
        guard sizes.indices.contains(next) else { return }
        Prefs.markdownFontSize = sizes[next]
    }

    /// Open ~/Library/Application Support/Glassine/Styles in the Finder, creating
    /// it the first time, so a custom stylesheet has somewhere obvious to go.
    @objc func openMarkdownStylesFolder(_ sender: NSMenuItem) {
        let folder = MarkdownStyle.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        NSWorkspace.shared.open(folder)
    }

    /// The Style submenu is rebuilt on every open: custom styles are files, and
    /// files appear and vanish while the app is running.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier == MainMenu.markdownStyleMenuIdentifier else { return }
        MainMenu.populateMarkdownStyleMenu(menu, appDelegate: self)
    }

    /// Hand LaunchServices this copy of Glassine as the handler for .md files.
    @objc func makeDefaultMarkdownApp(_ sender: NSMenuItem) {
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL,
            toOpen: GlassineDocument.markdownType
        ) { error in
            guard let error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let alert = NSAlert(error: error)
                    alert.messageText = "Could not make Glassine the default Markdown app."
                    alert.runModal()
                }
            }
        }
    }

    /// True when the Markdown handler LaunchServices reports is this app. The
    /// comparison is by bundle identifier, not path: the copy in build/ and the
    /// copy in /Applications are the same app as far as the user is concerned.
    private var isDefaultMarkdownApp: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: GlassineDocument.markdownType),
              let identifier = Bundle(url: handler)?.bundleIdentifier
        else { return false }
        return identifier == Bundle.main.bundleIdentifier
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setAppearance(_:)):
            menuItem.state = (menuItem.tag == Prefs.appearance.rawValue) ? .on : .off
        case #selector(toggleInvertInDarkMode(_:)):
            menuItem.state = Prefs.invertInDarkMode ? .on : .off
        case #selector(setDarkPaper(_:)):
            menuItem.state = (menuItem.tag == Prefs.darkPaper.rawValue) ? .on : .off
            return isInvertingNow
        case #selector(toggleWindowBlur(_:)):
            menuItem.state = Prefs.windowBlur ? .on : .off
            // Nothing to blur behind an opaque window.
            return Prefs.windowOpacity < Prefs.maxWindowOpacity
        case #selector(increaseOpacity(_:)):
            return Prefs.windowOpacity < Prefs.maxWindowOpacity
        case #selector(decreaseOpacity(_:)):
            return Prefs.windowOpacity > Prefs.minWindowOpacity
        case #selector(setMarkdownStyle(_:)):
            let id = menuItem.representedObject as? String
            menuItem.state = (id == Prefs.markdownStyle) ? .on : .off
        case #selector(setMarkdownLayout(_:)):
            menuItem.state = (menuItem.tag == Prefs.markdownLayout.rawValue) ? .on : .off
        case #selector(setMarkdownFontSize(_:)):
            menuItem.state = (menuItem.tag == Prefs.markdownFontSize) ? .on : .off
        case #selector(increaseMarkdownFontSize(_:)):
            return Prefs.markdownFontSize != Prefs.markdownFontSizes.last
        case #selector(decreaseMarkdownFontSize(_:)):
            return Prefs.markdownFontSize != Prefs.markdownFontSizes.first
        case #selector(makeDefaultMarkdownApp(_:)):
            menuItem.state = isDefaultMarkdownApp ? .on : .off
        default:
            break
        }
        return true
    }
}

/// Folio became Glassine, which means a new bundle identifier and so a new
/// preferences domain and a new Application Support folder. On first launch
/// only, the settings a reader would notice losing are carried across. Nothing
/// on the Folio side is ever removed: the old app keeps working if it is still
/// installed, and this is safe to have run more than once.
enum FolioMigration {

    private static let oldDomain = "com.epps.Folio"
    private static let doneKey = "migratedFromFolio"

    /// Sparkle's own `SU*` keys are deliberately not among these. Their update
    /// history belongs to Folio's feed, and Glassine polls a different one.
    private static let keys = [
        "invertInDarkMode",
        "appearance",
        "lastPositions",
        "markdownStyle",
        "markdownFontSize",
        "markdownLayout",
        "sidebarMode",
        "windowOpacity",
        "windowBlur",
        "NSWindow Frame ReaderWindow"
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: doneKey) == nil,
              let old = defaults.persistentDomain(forName: oldDomain)
        else { return }

        for key in keys {
            if let value = old[key] { defaults.set(value, forKey: key) }
        }
        copyStyles()
        defaults.set(true, forKey: doneKey)
    }

    /// ~/Library/Application Support/Folio/Styles holds whatever custom
    /// stylesheets the reader wrote; copy the folder wholesale, never move it.
    private static func copyStyles() {
        let fm = FileManager.default
        let destination = MarkdownStyle.folder
        let source = destination
            .deletingLastPathComponent()      // .../Glassine
            .deletingLastPathComponent()      // .../Application Support
            .appendingPathComponent("Folio/Styles", isDirectory: true)
        guard fm.fileExists(atPath: source.path),
              !fm.fileExists(atPath: destination.path)
        else { return }
        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.copyItem(at: source, to: destination)
    }
}

extension Prefs {
    /// First launch after the recents list arrived: adopt whatever
    /// NSDocumentController remembers, then any file with a saved reading
    /// position it did not mention. The second source matters because the
    /// system recent-documents list is empty whenever macOS is set to keep no
    /// recent items, while the position table is Glassine's own and dated.
    ///
    /// Mac-side, because NSDocumentController is: Core keeps the storage and
    /// the seeded-flag key, this supplies the one list it cannot reach.
    static func seedRecentDocumentsIfNeeded() {
        guard defaults.object(forKey: recentDocumentsSeededKey) == nil else { return }
        defaults.set(true, forKey: recentDocumentsSeededKey)
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
}
