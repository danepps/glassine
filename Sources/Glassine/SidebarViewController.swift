import AppKit
import CoreImage
import GlassineCore
import PDFKit

/// The sidebar: page thumbnails or the document's outline, chosen by a
/// segmented control at the top. PDFThumbnailView does the selection sync with
/// the PDFView on its own; the outline view is driven from here.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource,
                                   NSOutlineViewDelegate {

    let searchResults = SearchResultsViewController()
    let highlights = HighlightsViewController()
    private(set) var showsSearchResults = false
    private(set) var showsHighlights = false

    private let thumbnailView = PDFThumbnailView()
    private let outlineView = NSOutlineView()
    private let outlineScrollView = NSScrollView()
    private let emptyOutlineView = NSView()
    private let modeControl = NSSegmentedControl()
    private let pdfView: PDFView
    private var pendingFilters: [CIFilter] = []
    private var outlineRoot: PDFOutline?
    private(set) var isContinuousMarkdown: Bool
    var onSearchRequested: (() -> Void)?

    private enum Pane { case thumbnails, outline, search, highlights }
    private var panes: [Pane] {
        isContinuousMarkdown ? [.outline, .search, .highlights]
            : [.thumbnails, .outline, .search, .highlights]
    }
    /// Set while the reading position is driving the selection, so the
    /// selection handler does not turn around and navigate.
    private var isSyncingSelection = false

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("glassine.outlineCell")

    var hasOutline: Bool { (outlineRoot?.numberOfChildren ?? 0) > 0 }
    var canShowOutline: Bool { hasOutline || isContinuousMarkdown }

    private var storedMode: SidebarMode = .thumbnails

    var mode: SidebarMode {
        get { storedMode }
        set {
            showsSearchResults = false
            showsHighlights = false
            storedMode = resolvedMode(newValue)
            if isViewLoaded { applyMode() }
        }
    }

    init(pdfView: PDFView, isContinuousMarkdown: Bool = false) {
        self.pdfView = pdfView
        self.isContinuousMarkdown = isContinuousMarkdown
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        storedMode = resolvedMode(Prefs.sidebarMode)
        buildModeControl()
        buildThumbnails()
        buildOutline()
        buildEmptyOutline()
        addChild(searchResults)
        pin(searchResults.view)
        addChild(highlights)
        pin(highlights.view)
        applyMode()
    }

    // MARK: Construction

    private func buildModeControl() {
        modeControl.segmentStyle = .texturedRounded
        modeControl.trackingMode = .selectOne
        updateModeControl()
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeControl)

        NSLayoutConstraint.activate([
            modeControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            modeControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 8)
        ])
    }

    private func updateModeControl() {
        modeControl.segmentCount = panes.count
        for (index, pane) in panes.enumerated() {
            let symbol: String
            let title: String
            let shortcut: String
            switch pane {
            case .thumbnails: (symbol, title, shortcut) = ("square.grid.2x2", "Thumbnails", "⌥⌘2")
            case .outline: (symbol, title, shortcut) = ("list.bullet", "Table of Contents", "⌥⌘3")
            case .search: (symbol, title, shortcut) = ("magnifyingglass", "Search Results", "⌥⌘4")
            case .highlights: (symbol, title, shortcut) = ("highlighter", "Highlights", "⌥⌘5")
            }
            modeControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: title),
                                 forSegment: index)
            modeControl.setToolTip("\(title) (\(shortcut))", forSegment: index)
            modeControl.setEnabled(pane != .outline || canShowOutline, forSegment: index)
        }
    }

    private func buildThumbnails() {
        thumbnailView.pdfView = isContinuousMarkdown ? nil : pdfView
        thumbnailView.thumbnailSize = NSSize(width: 120, height: 160)
        thumbnailView.maximumNumberOfColumns = 1
        // Clear so the sidebar's vibrant material shows through.
        thumbnailView.backgroundColor = .clear
        thumbnailView.wantsLayer = true
        thumbnailView.contentFilters = pendingFilters
        pin(thumbnailView)
    }

    private func buildEmptyOutline() {
        let title = NSTextField(labelWithString: "No headings")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "Search this document to find a passage.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        let search = NSButton(title: "Search Document", target: self, action: #selector(requestSearch(_:)))
        search.bezelStyle = .rounded
        let stack = NSStackView(views: [title, detail, search])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyOutlineView.addSubview(stack)
        pin(emptyOutlineView)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: emptyOutlineView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: emptyOutlineView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: emptyOutlineView.topAnchor, constant: 32)
        ])
    }

    @objc private func requestSearch(_ sender: Any?) {
        if let onSearchRequested { onSearchRequested() }
        else { showSearchResults() }
    }

    private func buildOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("glassine.outline"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self

        outlineScrollView.documentView = outlineView
        outlineScrollView.hasVerticalScroller = true
        outlineScrollView.drawsBackground = false
        outlineScrollView.contentView.drawsBackground = false
        outlineScrollView.automaticallyAdjustsContentInsets = false
        pin(outlineScrollView)
    }

    /// Both panes fill the area under the mode control.
    private func pin(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 8),
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: Mode

    private func resolvedMode(_ preferred: SidebarMode) -> SidebarMode {
        if isContinuousMarkdown { return .outline }
        return preferred == .outline && hasOutline ? .outline : .thumbnails
    }

    private func applyMode() {
        searchResults.view.isHidden = !showsSearchResults
        highlights.view.isHidden = !showsHighlights
        let showOutline = !showsSearchResults && !showsHighlights && storedMode == .outline
        outlineScrollView.isHidden = !showOutline || !hasOutline
        emptyOutlineView.isHidden = !showOutline || hasOutline
        thumbnailView.isHidden = showOutline || showsSearchResults || showsHighlights
        let selected: Pane = showsHighlights ? .highlights : showsSearchResults ? .search
            : showOutline ? .outline : .thumbnails
        modeControl.selectedSegment = panes.firstIndex(of: selected) ?? -1
        if showOutline { syncSelection() }
    }

    func showSearchResults() {
        _ = view
        showsSearchResults = true
        showsHighlights = false
        applyMode()
    }

    func showHighlights() {
        _ = view
        showsSearchResults = false
        showsHighlights = true
        highlights.refresh()
        applyMode()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        guard panes.indices.contains(sender.selectedSegment) else { return }
        let selected: SidebarMode
        switch panes[sender.selectedSegment] {
        case .search: requestSearch(sender); return
        case .highlights: showHighlights(); return
        case .thumbnails: selected = .thumbnails
        case .outline: selected = .outline
        }
        // Continuous Markdown's local fallback must not replace the user's
        // preferred pane for ordinary PDFs and paginated Markdown.
        if !isContinuousMarkdown { Prefs.sidebarMode = selected }
        mode = selected
    }

    /// The reader swapped its PDFView's document (a Markdown render or reload).
    /// Detach thumbnails for the continuous render and rebuild its contents.
    /// Use the installed layout, which may lag the preference during a render.
    func documentDidChange(isContinuousMarkdown: Bool = false) {
        self.isContinuousMarkdown = isContinuousMarkdown
        guard isViewLoaded else { return }
        thumbnailView.pdfView = isContinuousMarkdown ? nil : pdfView
        outlineRoot = pdfView.document?.outlineRoot
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        updateModeControl()
        storedMode = resolvedMode(Prefs.sidebarMode)
        highlights.refresh()
        applyMode()
    }

    /// Same inversion filters as the reader, so thumbnails match the pages. The
    /// outline is native text and is deliberately left unfiltered.
    func setContentFilters(_ filters: [CIFilter]) {
        pendingFilters = filters
        if isViewLoaded { thumbnailView.contentFilters = filters }
    }

    // MARK: Selection

    private func destination(of node: PDFOutline) -> PDFDestination? {
        OutlineSync.destination(of: node)
    }

    /// Highlight the last entry, in pre-order, that starts at or before the
    /// reading position. Never navigates. The rule and the ordinal arithmetic
    /// are `OutlineSync`'s; the rows come from the outline view, so a chapter
    /// the reader has collapsed is not a candidate.
    func syncSelection() {
        guard isViewLoaded, !outlineScrollView.isHidden, hasOutline,
              let here = OutlineSync.currentOrdinal(of: pdfView) else { return }

        let document = pdfView.document
        let rows: [OutlineEntry] = (0..<outlineView.numberOfRows).map { row in
            guard let node = outlineView.item(atRow: row) as? PDFOutline else {
                return OutlineEntry(node: PDFOutline(), depth: 0, ordinal: nil)
            }
            var start: OutlineSync.Ordinal?
            if let target = OutlineSync.destination(of: node), let page = target.page {
                start = OutlineSync.ordinal(of: page, y: target.point.y, in: document)
            }
            return OutlineEntry(node: node, depth: 0, ordinal: start)
        }
        // PDFKit rounds the scroll origin: after a heading jump its reported
        // destination can sit a fraction of a point above the target. Allow
        // one view point so the continuous outline keeps the clicked heading
        // selected, while ordinary scrolling still follows the current section.
        let selectionPosition = isContinuousMarkdown
            ? OutlineSync.Ordinal(page: here.page, offset: here.offset + 1 / max(pdfView.scaleFactor, 0.01))
            : here
        let best = OutlineSync.index(atOrBefore: selectionPosition, in: rows)
        guard best != outlineView.selectedRow else { return }

        isSyncingSelection = true
        if best >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: best), byExtendingSelection: false)
            outlineView.scrollRowToVisible(best)
        } else {
            outlineView.deselectAll(nil)
        }
        isSyncingSelection = false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? PDFOutline,
              let target = destination(of: node) else { return }
        pdfView.go(to: target)
    }

    // MARK: Outline data

    private func node(for item: Any?) -> PDFOutline? {
        (item as? PDFOutline) ?? outlineRoot
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(for: item)?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(for: item)?.child(at: index) ?? PDFOutline()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? NSTableCellView ?? makeCell()
        cell.textField?.stringValue = (item as? PDFOutline)?.label ?? ""
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellIdentifier
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
