import AppKit
import GlassineCore

/// The recent-documents picker: the files the reader has been in, most recent
/// first, with a filter, each one's reading position, and the way to any other
/// file.
///
/// It knows nothing about where it is shown. The launch window
/// (`RecentsWindowController`) and a start tab (`StartTabWindowController`) both
/// host one and decide for themselves what opening a document means.
final class RecentsViewController: NSViewController, NSTableViewDataSource,
                                   NSTableViewDelegate, NSSearchFieldDelegate {

    /// A document the reader picked, by double click, Return or a drop.
    var onOpen: ((URL) -> Void)?
    /// "Open Other…": the host runs whichever Open panel suits it.
    var onOpenOther: (() -> Void)?
    /// Escape.
    var onCancel: (() -> Void)?

    private let searchField = NSSearchField()
    private let table = RecentsTableView()
    private let removeButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "No recent documents")

    private var allRows: [RecentRow] = []
    private var rows: [RecentRow] = []

    /// A start tab sits on the reader's own chrome colour -- black in dark mode
    /// -- so its list has to let that through instead of painting the standard
    /// control background over it. The launch window is a plain window and keeps
    /// the default.
    private let drawsListBackground: Bool

    private static let defaultSize = NSSize(width: 680, height: 520)

    init(drawsListBackground: Bool = true) {
        self.drawsListBackground = drawsListBackground
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    override func loadView() {
        let root = RecentsDropView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        root.onDrop = { [weak self] urls in self?.openDropped(urls) ?? false }

        searchField.placeholderString = "Filter"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false

        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        if !drawsListBackground { table.backgroundColor = .clear }
        table.rowHeight = 56
        table.headerView = nil
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.onOpen = { [weak self] in self?.openSelectedRow() }
        table.onDelete = { [weak self] in self?.removeSelected(nil) }
        table.onCancel = { [weak self] in self?.onCancel?() }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recent"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = drawsListBackground
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
        view = root

        // A start tab lives in a translucent window whose content view is faded
        // to the window opacity. The list draws no background of its own there
        // (drawsListBackground == false), so without a backing the root's pixels
        // are fully clear: the backdrop blur -- weighted by the window's own
        // alpha -- skips them, whatever is behind shows through razor sharp, and
        // the row labels antialias onto nothing and halo. Paint the root the
        // reader's own page colour, opaque, so the whole content view has a
        // uniform alpha to fade and blur, exactly like the reader's page. The
        // launch window is opaque and keeps the standard control background.
        if !drawsListBackground {
            root.wantsLayer = true
            root.onAppearanceChange = { [weak self] in self?.applyBackingColour() }
            applyBackingColour()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(prefsChanged),
            name: .glassinePrefsChanged, object: nil)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func prefsChanged() { applyBackingColour() }

    /// The reader's page colour: black or the Dark Paper lift in dark mode, the
    /// page's white in light mode -- the same tone `WindowChrome` paints the
    /// title-bar band, so a start tab reads as one surface with the reader.
    private func applyBackingColour() {
        guard drawsListBackground == false, isViewLoaded, let layer = view.layer else { return }
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colour: NSColor
        if dark {
            let level = Prefs.darkPaper
            colour = (level != .black && Prefs.invertInDarkMode)
                ? NSColor(white: level.lift, alpha: 1) : .black
        } else {
            colour = .white
        }
        // A CGColor is resolved once and does not follow the appearance, so pin
        // it under ours.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = colour.cgColor
        }
    }

    // MARK: Focus

    /// The list is what the reader came here for; the filter is a keystroke away.
    func focusList() {
        if table.selectedRow < 0 && !rows.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        view.window?.makeFirstResponder(table)
    }

    /// Edit ▸ Find… reaches this through the responder chain, the same selector
    /// the reader window uses for its search field.
    @objc func focusSearch(_ sender: Any?) {
        view.window?.makeFirstResponder(searchField)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // MARK: Rows

    func reload() {
        allRows = RecentsModel.rows()
        applyFilter()
    }

    private func applyFilter() {
        let selectedKey = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].key : nil

        rows = RecentsModel.filter(allRows, query: searchField.stringValue)
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
        onOpen?(row.url)
    }

    @objc private func openOther(_ sender: Any?) {
        onOpenOther?()
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

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        applyFilter()
    }

    // MARK: Drag and drop

    private func openDropped(_ urls: [URL]) -> Bool {
        let openable = urls.filter(GlassineDocument.canOpen)
        guard !openable.isEmpty else { return false }
        for url in openable { onOpen?(url) }
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

/// The picker's root view, which accepts a file dropped anywhere on it.
/// AppKit walks up from the view under the pointer to find a registered
/// destination, so the table and the scroll view need no part in this.
final class RecentsDropView: NSView {

    var onDrop: (([URL]) -> Bool)?
    /// The controller repaints its backing here: a CGColor does not follow the
    /// light/dark switch, and only an NSView is told the effective appearance
    /// changed (NSViewController is not).
    var onAppearanceChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

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

    func configure(_ row: RecentRow) {
        let dimmed: CGFloat = row.isMissing ? 0.5 : 1
        icon.image = NSWorkspace.shared.icon(forFile: row.url.path)
        icon.alphaValue = dimmed
        nameLabel.stringValue = row.url.lastPathComponent
        nameLabel.alphaValue = dimmed
        detailLabel.stringValue = row.isMissing ? "Not found" : RecentsModel.detailText(row)
        dateLabel.stringValue = RecentsModel.dateText(row.lastOpened)
    }

}
