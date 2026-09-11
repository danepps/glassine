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
    private(set) var showsSearchResults = false

    private let thumbnailView = PDFThumbnailView()
    private let outlineView = NSOutlineView()
    private let outlineScrollView = NSScrollView()
    private let modeControl = NSSegmentedControl()
    private let pdfView: PDFView
    private var pendingFilters: [CIFilter] = []
    private var outlineRoot: PDFOutline?
    /// Set while the reading position is driving the selection, so the
    /// selection handler does not turn around and navigate.
    private var isSyncingSelection = false

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("glassine.outlineCell")

    var hasOutline: Bool { (outlineRoot?.numberOfChildren ?? 0) > 0 }

    private var storedMode: SidebarMode = .thumbnails

    var mode: SidebarMode {
        get { storedMode }
        set {
            showsSearchResults = false
            storedMode = newValue
            if isViewLoaded { applyMode() }
        }
    }

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        storedMode = Prefs.sidebarMode
        buildModeControl()
        buildThumbnails()
        buildOutline()
        addChild(searchResults)
        pin(searchResults.view)
        applyMode()
    }

    // MARK: Construction

    private func buildModeControl() {
        modeControl.segmentCount = 3
        modeControl.segmentStyle = .texturedRounded
        modeControl.trackingMode = .selectOne
        modeControl.setImage(NSImage(systemSymbolName: "square.grid.2x2",
                                     accessibilityDescription: "Thumbnails"),
                             forSegment: SidebarMode.thumbnails.rawValue)
        modeControl.setImage(NSImage(systemSymbolName: "list.bullet",
                                     accessibilityDescription: "Table of Contents"),
                             forSegment: SidebarMode.outline.rawValue)
        modeControl.setToolTip("Thumbnails (\u{2325}\u{2318}2)",
                               forSegment: SidebarMode.thumbnails.rawValue)
        modeControl.setToolTip("Table of Contents (\u{2325}\u{2318}3)",
                               forSegment: SidebarMode.outline.rawValue)
        modeControl.setEnabled(false, forSegment: SidebarMode.outline.rawValue)
        modeControl.setImage(NSImage(systemSymbolName: "magnifyingglass",
                                     accessibilityDescription: "Search Results"), forSegment: 2)
        modeControl.setToolTip("Search Results (⌥⌘4)", forSegment: 2)
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeControl)

        NSLayoutConstraint.activate([
            modeControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            modeControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 8)
        ])
    }

    private func buildThumbnails() {
        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 120, height: 160)
        thumbnailView.maximumNumberOfColumns = 1
        // Clear so the sidebar's vibrant material shows through.
        thumbnailView.backgroundColor = .clear
        thumbnailView.wantsLayer = true
        thumbnailView.contentFilters = pendingFilters
        pin(thumbnailView)
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

    private func applyMode() {
        searchResults.view.isHidden = !showsSearchResults
        let showOutline = !showsSearchResults && storedMode == .outline && hasOutline
        outlineScrollView.isHidden = !showOutline
        thumbnailView.isHidden = showOutline || showsSearchResults
        modeControl.selectedSegment = showsSearchResults ? 2 : showOutline
            ? SidebarMode.outline.rawValue : SidebarMode.thumbnails.rawValue
        if showOutline { syncSelection() }
    }

    func showSearchResults() {
        _ = view
        showsSearchResults = true
        applyMode()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 2 { showSearchResults(); return }
        guard let selected = SidebarMode(rawValue: sender.selectedSegment) else { return }
        Prefs.sidebarMode = selected
        mode = selected
    }

    /// The reader swapped its PDFView's document (a Markdown render or reload).
    /// PDFThumbnailView observes its pdfView and rebuilds itself, so only the
    /// outline needs reloading -- verified 2026-09-04 by watching thumbnails
    /// appear for a Markdown document, whose PDF arrives after the view loads.
    func documentDidChange() {
        guard isViewLoaded else { return }
        outlineRoot = pdfView.document?.outlineRoot
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        modeControl.setEnabled(hasOutline, forSegment: SidebarMode.outline.rawValue)
        storedMode = hasOutline ? Prefs.sidebarMode : .thumbnails
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
        let best = OutlineSync.index(atOrBefore: here, in: rows)
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
