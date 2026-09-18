import AppKit

/// Keep selection legible over tinted or transparent chrome using the public
/// tab API. Selection belongs to the tab group, even when another window is key.
@MainActor final class WindowTabSelection: NSObject {
    private weak var window: NSWindow?
    private weak var observedGroup: NSWindowTabGroup?
    private var groupObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var selectionObservation: NSKeyValueObservation?
    private var membersObservation: NSKeyValueObservation?

    init(window: NSWindow) {
        self.window = window
        super.init()
        groupObservation = window.observe(\.tabGroup, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.observeGroup() }
        }
        titleObservation = window.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidUpdate),
                                                name: NSWindow.didUpdateNotification, object: window)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func windowDidUpdate() {
        // A detached window's single-window group is created lazily. AppKit
        // can notify the old group's removal before that replacement exists.
        if window?.tabGroup !== observedGroup { observeGroup() }
    }

    private func observeGroup() {
        let group = window?.tabGroup
        if group !== observedGroup {
            selectionObservation = nil
            membersObservation = nil
            observedGroup = group
            selectionObservation = group?.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            membersObservation = group?.observe(\.windows, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.observeGroup() }
            }
        }
        refresh()
    }

    private func refresh() {
        guard let window else { return }
        let selected = window.tabGroup?.selectedWindow === window
        let title = selected ? NSAttributedString(string: window.tab.title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]) : nil
        if window.tab.attributedTitle != title { window.tab.attributedTitle = title }
    }
}
