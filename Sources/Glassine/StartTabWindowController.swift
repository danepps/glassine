import AppKit
import GlassineCore

/// A new tab with nothing in it yet: the recents picker, shown as a tab of the
/// reader's own window group the way Safari shows its start page. Picking a
/// document opens it in this tab's place.
///
/// It is a reader-group window (same tabbing identifier) with a toolbar of its
/// own, so the tab bar and title bar keep the reader's height and look, and so
/// everything that asks "is a document window open?" -- the launch-window
/// timing checks in particular -- counts it.
final class StartTabWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    /// Nothing else owns a start tab: AppKit holds the window, not its
    /// controller. Membership ends in `windowWillClose`.
    private static var open: [StartTabWindowController] = []

    private let recentsVC = RecentsViewController(drawsListBackground: false)

    /// Set once this tab has handed over to a document window, so a multi-file
    /// drop closes the tab once rather than once per file.
    private var didReplace = false

    /// Opens a start tab beside `host` -- the tab the reader pressed ⌘T (or the
    /// "+" button) in -- and puts the focus in the list.
    static func present(besides host: NSWindow?) {
        let controller = StartTabWindowController()
        guard let window = controller.window else { return }
        open.append(controller)

        if let host {
            // A tab is sized by its group anyway; matching the host first keeps
            // the window from flashing at its own size on the way in.
            window.setFrame(host.frame, display: false)
            host.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        // The backdrop blur is keyed to the window number, which a window that
        // has never been ordered in does not have.
        controller.applyWindowAppearance()
        controller.recentsVC.focusList()
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 1040),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Recents"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = ReaderWindowController.tabbingIdentifier
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 480, height: 360)

        super.init(window: window)

        window.delegate = self
        shouldCascadeWindows = false

        recentsVC.onOpen = { [weak self] url in self?.open(url) }
        recentsVC.onOpenOther = { [weak self] in self?.openOther() }
        window.contentViewController = recentsVC

        // Every window gets its own toolbar identifier: AppKit keeps toolbars
        // that share one in lockstep, which has bitten this app before. The
        // toolbar itself is empty -- it exists so the title bar matches the
        // reader's.
        let toolbar = NSToolbar(identifier: "GlassineStartToolbar.\(UUID().uuidString)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        applyWindowAppearance()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyWindowAppearance),
            name: .glassinePrefsChanged,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyWindowAppearance() {
        guard let window else { return }
        WindowChrome.apply(to: window, content: contentViewController?.view)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    // MARK: Opening

    /// Replace in place: the document window adopts the frontmost reader-group
    /// window as its tab host and inserts itself above it, and that window is
    /// this one, so the document lands exactly where this tab is. Closing the
    /// start tab afterwards -- once the document is on screen, so the group
    /// never collapses -- leaves the document sitting in its place. A document
    /// that is already open just has its tab selected, which is what
    /// `openDocument` does with one.
    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
            [weak self] _, _, error in
            if let error {
                NSApp.presentError(error)
                return
            }
            guard let self, !self.didReplace else { return }
            self.didReplace = true
            self.close()
        }
    }

    /// The Open panel, opened from this tab, replaces this tab too. Hence
    /// `beginOpenPanel` rather than `openDocument(_:)`, which would open the
    /// file behind our back and leave the start tab sitting there.
    private func openOther() {
        NSDocumentController.shared.beginOpenPanel { [weak self] urls in
            guard let self, let urls, !urls.isEmpty else { return }
            for url in urls { self.open(url) }
        }
    }

    // MARK: Window

    /// ⌘T and the "+" button from a start tab open another start tab.
    override func newWindowForTab(_ sender: Any?) {
        Self.present(besides: window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Dates and reading positions move while a document is open.
        recentsVC.reload()
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}
