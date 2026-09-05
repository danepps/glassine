import AppKit

/// One row of the Recents list: an entry from `Prefs.recentDocuments` after the
/// file has been located.
private struct RecentRow {
    var url: URL
    /// The entry's stored path, which is how it is removed from the list. Not
    /// necessarily `url.path` -- a bookmark resolve rewrites one and not yet the
    /// other.
    var key: String
    var lastOpened: Date
    var pageCount: Int?
    var isMissing: Bool
}

/// What Glassine shows when it has nothing open: the files the reader has been
/// in, most recent first, with a filter, each one's reading position, and the
/// way to any other file.
///
/// A window of its own rather than a document window, and `tabbingMode`
/// `.disallowed`, so it can never be pulled into the reader's tab group.
final class RecentsWindowController: NSWindowController, NSWindowDelegate,
                                     NSTableViewDataSource, NSTableViewDelegate,
                                     NSSearchFieldDelegate {

    static let shared = RecentsWindowController()

    private static let frameAutosaveName = "RecentsWindow"

    private let searchField = NSSearchField()
    private let table = RecentsTableView()
    private let removeButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "No recent documents")

    private var allRows: [RecentRow] = []
    private var rows: [RecentRow] = []

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
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
        buildContent(in: window)
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

    // MARK: Content

    private func buildContent(in window: NSWindow) {
        let root = RecentsDropView()
        root.onDrop = { [weak self] urls in self?.openDropped(urls) ?? false }

        searchField.placeholderString = "Filter"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false

        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 56
        table.headerView = nil
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.onOpen = { [weak self] in self?.openSelectedRow() }
        table.onDelete = { [weak self] in self?.removeSelected(nil) }
        table.onCancel = { [weak self] in self?.cancelOperation(nil) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recent"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator

        let openOther = NSButton(title: "Open Other…", target: self,
                                 action: #selector(openOther(_:)))
        openOther.bezelStyle = .rounded

        removeButton.title = "Remove from List"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        removeButton.isEnabled = false

        let views: [NSView] = [searchField, scroll, emptyLabel, separator, openOther, removeButton]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: openOther.topAnchor, constant: -12),

            openOther.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            openOther.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            removeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            removeButton.centerYAnchor.constraint(equalTo: openOther.centerYAnchor)
        ])

        searchField.nextKeyView = table
        table.nextKeyView = searchField
        window.contentView = root
    }

    // MARK: Showing

    func show() {
        guard let window else { return }
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if table.selectedRow < 0 && !rows.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        // The list is what the reader came here for; the filter is a keystroke away.
        window.makeFirstResponder(table)
    }

    func hide() {
        guard window?.isVisible == true else { return }
        window?.orderOut(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Dates and reading positions move while a document is open.
        reload()
    }

    // MARK: Rows

    private func reload() {
        allRows = Prefs.recentDocuments.map { entry in
            let resolved = Prefs.resolvedURL(for: entry)
            return RecentRow(url: resolved ?? entry.url,
                             key: resolved?.path ?? entry.path,
                             lastOpened: entry.lastOpened,
                             pageCount: entry.pageCount,
                             isMissing: resolved == nil)
        }
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let selectedKey = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].key : nil

        rows = query.isEmpty ? allRows : allRows.filter {
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
        table.reloadData()
        emptyLabel.stringValue = allRows.isEmpty ? "No recent documents" : "No matches"
        emptyLabel.isHidden = !rows.isEmpty

        if let selectedKey, let index = rows.firstIndex(where: { $0.key == selectedKey }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        } else if !rows.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        removeButton.isEnabled = table.selectedRow >= 0
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: RecentRowView.identifier, owner: self)
            as? RecentRowView ?? RecentRowView()
        view.configure(rows[row])
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }

    // MARK: Actions

    @objc private func rowDoubleClicked(_ sender: Any?) {
        // A double click in the empty space below the last row must not open
        // whatever happens to be selected.
        guard table.clickedRow >= 0 else { return }
        open(rows[table.clickedRow])
    }

    private func openSelectedRow() {
        guard rows.indices.contains(table.selectedRow) else { return }
        open(rows[table.selectedRow])
    }

    private func open(_ row: RecentRow) {
        guard !row.isMissing else {
            NSSound.beep()
            return
        }
        open(row.url)
    }

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

    @objc private func openOther(_ sender: Any?) {
        NSDocumentController.shared.openDocument(nil)
    }

    @objc private func removeSelected(_ sender: Any?) {
        let index = table.selectedRow
        guard rows.indices.contains(index) else { return }
        Prefs.removeRecentDocument(path: rows[index].key)
        reload()
        // Land on the row that took the removed one's place.
        if !rows.isEmpty {
            table.selectRowIndexes([min(index, rows.count - 1)], byExtendingSelection: false)
        }
    }

    /// Edit ▸ Find… reaches this through the responder chain, the same selector
    /// the reader window uses for its search field.
    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
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

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        applyFilter()
    }

    // MARK: Drag and drop

    private func openDropped(_ urls: [URL]) -> Bool {
        let openable = urls.filter(GlassineDocument.canOpen)
        guard !openable.isEmpty else { return false }
        for url in openable { open(url) }
        return true
    }
}

/// Return opens, Delete removes, Escape leaves: NSTableView handles none of the
/// three itself, and its own key handling would swallow all of them.
final class RecentsTableView: NSTableView {

    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: (() -> Void)?

    private enum Key: UInt16 {
        case returnKey = 36, enter = 76, delete = 51, forwardDelete = 117, escape = 53
    }

    override func keyDown(with event: NSEvent) {
        switch Key(rawValue: event.keyCode) {
        case .returnKey, .enter: onOpen?()
        case .delete, .forwardDelete: onDelete?()
        case .escape: onCancel?()
        case nil: super.keyDown(with: event)
        }
    }
}

/// The window's content view, which accepts a file dropped anywhere on it.
/// AppKit walks up from the view under the pointer to find a registered
/// destination, so the table and the scroll view need no part in this.
final class RecentsDropView: NSView {

    var onDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: options) as? [URL] ?? []
        return urls.filter(GlassineDocument.canOpen)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(droppedURLs(sender)) ?? false
    }
}

/// One recent document: icon, name, where it is and how far into it the reader
/// got, and when they were last there.
final class RecentRowView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("RecentRow")

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.alignment = .right
        icon.imageScaling = .scaleProportionallyUpOrDown

        for label in [nameLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)

        for view in [icon, nameLabel, detailLabel, dateLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = nameLabel

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor,
                                                constant: -10),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor,
                                                  constant: -10),

            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            dateLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// NSTableCellView recolours only its `textField` for a selected row; the
    /// two secondary labels would stay grey on the accent-coloured highlight.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let colour: NSColor = backgroundStyle == .emphasized
                ? .alternateSelectedControlTextColor : .secondaryLabelColor
            detailLabel.textColor = colour
            dateLabel.textColor = colour
        }
    }

    fileprivate func configure(_ row: RecentRow) {
        let dimmed: CGFloat = row.isMissing ? 0.5 : 1
        icon.image = NSWorkspace.shared.icon(forFile: row.url.path)
        icon.alphaValue = dimmed
        nameLabel.stringValue = row.url.lastPathComponent
        nameLabel.alphaValue = dimmed
        detailLabel.stringValue = row.isMissing ? "Not found" : Self.detailText(row)
        dateLabel.stringValue = Self.dateText(row.lastOpened)
    }

    /// The containing folder, plus how far in the reader got if there is a
    /// saved position. A Markdown file has no page count until it is typeset,
    /// so it shows just the page it was left on.
    private static func detailText(_ row: RecentRow) -> String {
        let folder = row.url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
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

    private static func dateText(_ date: Date) -> String {
        // A seeded entry can have no date at all: better blank than 1 Jan 2001.
        guard date > .distantPast else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today, " + timeFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return dayFormatter.string(from: date)
        }
        return olderFormatter.string(from: date)
    }
}
