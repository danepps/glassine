import AppKit
import PDFKit

/// A virtualized results list. PDF text extraction happens only for visible rows;
/// the bounded cache is discarded whenever the search or document is replaced.
final class SearchResultsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = SearchResultsTable()
    private let status = NSTextField(labelWithString: "Type to search this document")
    private let scroll = NSScrollView()
    private(set) var matches: [PDFSelection] = []
    private var snippets: [Int: Snippet] = [:]
    private var syncing = false
    var onSelect: ((Int) -> Void)?
    static let liveHighlightLimit = 500

    override func loadView() {
        view = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 78
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateSelectedResult)
        table.setAccessibilityLabel("Search results")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        for child in [status, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func update(_ selections: [PDFSelection], current: Int) {
        _ = view
        let isAppend = selections.count >= matches.count &&
            zip(matches, selections).allSatisfy { $0 === $1 }
        let previousCount = matches.count
        matches = selections
        syncing = true
        if isAppend {
            if selections.count > previousCount {
                // No insertion animation or delayed selection adjustment: rows
                // already displayed retain their identity as a batch arrives.
                table.noteNumberOfRowsChanged()
            }
        } else {
            snippets.removeAll()
            table.reloadData()
        }
        syncing = false
        select(current, scrollToRow: false)
    }

    func updateStatus(query: String, count: Int, inProgress: Bool) {
        _ = view
        let countText = "\(count) " + (count == 1 ? "result" : "results")
        if query.isEmpty { status.stringValue = "Type to search this document" }
        else if inProgress { status.stringValue = "\(countText) · Searching…" }
        else { status.stringValue = count == 0 ? "No matches" : countText }
        if count > Self.liveHighlightLimit {
            status.stringValue += "\nOnly the selected match is highlighted"
        }
    }

    func select(_ index: Int, scrollToRow: Bool = true) {
        guard isViewLoaded else { return }
        syncing = true
        if matches.indices.contains(index) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if scrollToRow { table.scrollRowToVisible(index) }
        } else { table.deselectAll(nil) }
        syncing = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !table.isHandlingMouse else { return }
        activateSelectedResult()
    }

    @objc func activateSelectedResult() {
        guard !syncing, matches.indices.contains(table.selectedRow) else { return }
        onSelect?(table.selectedRow)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("searchResultCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? SearchResultCell
            ?? SearchResultCell(identifier: id)
        let match = matches[row]
        cell.page.stringValue = Self.pageReference(for: match)
        let snippet: Snippet
        if let cached = snippets[row] { snippet = cached }
        else {
            snippet = Self.context(for: match)
            if snippets.count >= 256 { snippets.removeAll(keepingCapacity: true) }
            snippets[row] = snippet
        }
        let text = NSMutableAttributedString(string: snippet.text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
        ])
        if snippet.matchRange.length > 0 {
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12), range: snippet.matchRange)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        cell.snippet.attributedStringValue = text
        cell.updateColors()
        cell.setAccessibilityLabel("\(cell.page.stringValue). \(snippet.text)")
        return cell
    }

    static func pageReference(for selection: PDFSelection) -> String {
        guard let page = selection.pages.first, let document = page.document else { return "" }
        let index = document.index(for: page)
        guard index != NSNotFound else { return "" }
        let physical = String(index + 1)
        let label = page.label ?? physical
        return label == physical ? "Page \(physical)" : "Page \(label) · PDF \(physical)"
    }

    struct Snippet {
        let text: String
        let matchRange: NSRange
    }

    static func snippet(for selection: PDFSelection) -> String { context(for: selection).text }

    static func context(for selection: PDFSelection) -> Snippet {
        // Use the actual match's character range: searching a common word can
        // include earlier hits in the context, which must not become the bold hit.
        guard let page = selection.pages.first,
              selection.numberOfTextRanges(on: page) > 0,
              let content = page.string else {
            return Snippet(text: normalized(selection.string ?? ""), matchRange: NSRange(location: 0, length: 0))
        }
        let text = content as NSString
        let hit = selection.range(at: 0, on: page)
        guard hit.location != NSNotFound, NSMaxRange(hit) <= text.length else {
            return Snippet(text: normalized(selection.string ?? ""), matchRange: NSRange(location: 0, length: 0))
        }
        let start = max(0, hit.location - 40)
        let end = min(text.length, NSMaxRange(hit) + 95)
        func collapse(_ range: NSRange) -> String {
            text.substring(with: range).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        let before = collapse(NSRange(location: start, length: hit.location - start))
        let prefix = (start > 0 ? "…" : "") + String(before.drop(while: { $0.isWhitespace }))
        let term = collapse(hit)
        let after = collapse(NSRange(location: NSMaxRange(hit), length: end - NSMaxRange(hit)))
        let full = (prefix + term + after).trimmingCharacters(in: .whitespacesAndNewlines)
            + (end < text.length ? "…" : "")
        return Snippet(text: full, matchRange: NSRange(location: prefix.utf16.count, length: term.utf16.count))
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

private final class SearchResultCell: NSTableCellView {
    let page = NSTextField(labelWithString: "")
    let snippet = NSTextField(wrappingLabelWithString: "")

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    func updateColors() {
        let selected = backgroundStyle == .emphasized
        page.textColor = selected ? .selectedControlTextColor : .secondaryLabelColor
        let text = NSMutableAttributedString(attributedString: snippet.attributedStringValue)
        text.addAttribute(.foregroundColor,
                          value: selected ? NSColor.selectedControlTextColor : NSColor.labelColor,
                          range: NSRange(location: 0, length: text.length))
        snippet.attributedStringValue = text
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        page.font = .systemFont(ofSize: 11, weight: .medium)
        page.textColor = .secondaryLabelColor
        snippet.maximumNumberOfLines = 3
        snippet.lineBreakMode = .byWordWrapping
        snippet.cell?.wraps = true
        snippet.cell?.isScrollable = false
        snippet.cell?.usesSingleLineMode = false
        for child in [page, snippet] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            page.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            page.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            snippet.topAnchor.constraint(equalTo: page.bottomAnchor, constant: 3),
            snippet.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            snippet.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            snippet.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Mouse clicks use the action even when the row is already selected. Keyboard
/// arrows use the selection notification; Return activates the current row.
final class SearchResultsTable: NSTableView {
    private(set) var isHandlingMouse = false

    override func mouseDown(with event: NSEvent) {
        isHandlingMouse = true
        defer { isHandlingMouse = false }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            sendAction(action, to: target)
        } else { super.keyDown(with: event) }
    }
}
