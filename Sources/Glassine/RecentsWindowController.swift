import AppKit
import GlassineCore

/// What Glassine shows when it has nothing open: a window around the recent
/// documents picker.
///
/// A window of its own rather than a document window, and `tabbingMode`
/// `.disallowed`, so it can never be pulled into the reader's tab group. The
/// list, the filter and the keyboard handling all live in `RecentsViewController`,
/// which a start tab hosts too.
final class RecentsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = RecentsWindowController()

    private static let frameAutosaveName = "RecentsWindow"
    private static let defaultSize = NSSize(width: 680, height: 520)

    private let recentsVC = RecentsViewController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glassine"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 320)

        super.init(window: window)

        window.delegate = self
        shouldCascadeWindows = false

        recentsVC.onOpen = { [weak self] url in self?.open(url) }
        recentsVC.onOpenOther = { NSDocumentController.shared.openDocument(nil) }
        recentsVC.onCancel = { [weak self] in self?.cancelOperation(nil) }
        window.contentViewController = recentsVC
        // Installing a content view controller resizes the window to the view's
        // fitting size, so the window's own size is restated after it.
        window.setContentSize(Self.defaultSize)

        // Centre before naming the autosave, not on first show: naming it saves
        // the frame there and then, so a window centred afterwards would still
        // have stored its bottom-left starting frame.
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameAutosaveName)") == nil {
            window.center()
        }
        // Restores a saved frame if there is one, and saves from here on.
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Showing

    func show() {
        guard let window else { return }
        recentsVC.reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        recentsVC.focusList()
    }

    func hide() {
        guard window?.isVisible == true else { return }
        window?.orderOut(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Dates and reading positions move while a document is open.
        recentsVC.reload()
    }

    // MARK: Opening

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
            [weak self] _, _, error in
            if let error {
                NSApp.presentError(error)
                return
            }
            self?.hide()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        // With no document open there is nothing behind this window, so leaving
        // would leave the app showing nothing at all.
        guard ReaderWindowController.anyWindowIsOpen else {
            NSSound.beep()
            return
        }
        hide()
    }
}
