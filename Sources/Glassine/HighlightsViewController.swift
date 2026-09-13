import AppKit
import PDFKit

final class HighlightsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    let table = HighlightsTable()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var colorButtons: [HighlightColorButton] = []
    private let remove = NSButton(title: "Delete", target: nil, action: nil)
    private let noteButton = NSButton(title: "Note…", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private var syncing = false
    private(set) var highlights: [SavedHighlight] = []
    weak var document: GlassineDocument?
    var onSelect: ((SavedHighlight) -> Void)?

    var selectedHighlights: [SavedHighlight] {
        table.selectedRowIndexes.compactMap { highlights.indices.contains($0) ? highlights[$0] : nil }
    }

    var selectedHighlight: SavedHighlight? {
        let selected = selectedHighlights
        return selected.count == 1 ? selected.first : nil
    }

    override func loadView() {
        view = NSView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("highlight")))
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.style = .sourceList
        table.rowHeight = 78
        table.usesAutomaticRowHeights = true
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateSelection)
        table.onDelete = { [weak self] in self?.deleteHighlight(nil) }
        table.onCopy = { [weak self] in self?.copyHighlightsAsMarkdown(nil) }
        let menu = NSMenu()
        for (title, action) in [("Add or Edit Note…", #selector(editSelectedNote(_:))),
                                ("Copy as Markdown", #selector(copyHighlightsAsMarkdown(_:))),
                                ("Export All Highlights…", #selector(exportHighlights(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        table.menu = menu
        table.setAccessibilityLabel("Saved highlights")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        for color in HighlightColor.allCases {
            let button = HighlightColorButton(color: color)
            button.target = self
            button.action = #selector(changeColor(_:))
            colorButtons.append(button)
        }
        let colors = NSStackView(views: colorButtons)
        colors.spacing = 6
        remove.bezelStyle = .rounded
        remove.target = self
        remove.action = #selector(deleteHighlight(_:))
        remove.setAccessibilityLabel("Delete selected highlight")
        let actions = NSStackView(views: [colors, remove])
        actions.spacing = 8
        for (button, action, label) in [
            (noteButton, #selector(editSelectedNote(_:)), "Add or edit the selected highlight note"),
            (copyButton, #selector(copyHighlightsAsMarkdown(_:)), "Copy selected highlights as Markdown"),
            (exportButton, #selector(exportHighlights(_:)), "Export all highlights as Markdown")
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
        }
        let tools = NSStackView(views: [noteButton, copyButton, exportButton])
        tools.spacing = 6
        for child in [status, scroll, actions, tools] {
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
            scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            tools.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 6),
            tools.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
            tools.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            tools.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])
        refresh()
    }

    func refresh(select annotation: PDFAnnotation? = nil) {
        guard isViewLoaded else { return }
        let selected = annotation.map { [$0] } ?? selectedHighlights.map(\.annotation)
        let identities = Set(selected.map(ObjectIdentifier.init))
        highlights = document?.savedHighlights ?? []
        syncing = true
        table.reloadData()
        let rows = IndexSet(highlights.indices.filter { identities.contains(ObjectIdentifier(highlights[$0].annotation)) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if annotation != nil, let row = rows.first { table.scrollRowToVisible(row) }
        syncing = false
        status.stringValue = highlights.isEmpty ? "Select text to highlight it (⇧⌘H)"
            : "\(highlights.count) " + (highlights.count == 1 ? "highlight" : "highlights")
        if document?.kind == .markdown { status.stringValue = "Highlighting is available for PDF files" }
        else if document?.canEditHighlights == false {
            status.stringValue = "Highlights are read-only in this PDF"
        }
        updateActions()
    }

    private func updateActions() {
        let editable = selectedHighlight.map { document?.canEdit($0.annotation) == true } ?? false
        for button in colorButtons {
            button.isEnabled = editable
            button.state = selectedHighlight.map { button.highlightColor.matches($0.annotation.color) } == true ? .on : .off
            button.setAccessibilityValue(button.state == .on ? "Selected" : "")
        }
        remove.isEnabled = !selectedHighlights.isEmpty && selectedHighlights.allSatisfy { document?.canEdit($0.annotation) == true }
        noteButton.isEnabled = selectedHighlight.map { editable || !$0.note.isEmpty } ?? false
        noteButton.toolTip = editable ? "Add or edit a note" : "View the note"
        copyButton.isEnabled = !selectedHighlights.isEmpty
        exportButton.isEnabled = !highlights.isEmpty
    }

    @objc func deleteHighlight(_ sender: Any?) {
        let selected = selectedHighlights
        guard !selected.isEmpty, selected.allSatisfy({ document?.canEdit($0.annotation) == true }) else { return }
        let row = table.selectedRow
        document?.removeHighlights(selected.map(\.annotation))
        refresh()
        if !highlights.isEmpty {
            table.selectRowIndexes(IndexSet(integer: min(row, highlights.count - 1)), byExtendingSelection: false)
        }
    }

    @objc func editSelectedNote(_ sender: Any?) {
        guard let highlight = selectedHighlight else { return }
        editNote(for: highlight.annotation)
    }

    func editNote(for annotation: PDFAnnotation) {
        guard let document, let page = annotation.page, page.document === document.pdf,
              annotation.type == "Highlight" else { return }
        let editable = document.canEdit(annotation)
        guard editable || annotation.contents?.isEmpty == false else { return }
        let editor = HighlightNoteEditor(highlight: SavedHighlight(page: page, annotation: annotation),
            editable: editable) { [weak document] text in
                document?.setHighlightNote(annotation, text: text) == true
            }
        presentAsSheet(editor)
    }

    @objc func copyHighlightsAsMarkdown(_ sender: Any?) {
        copySelectedHighlights(to: .general)
    }

    func copySelectedHighlights(to pasteboard: NSPasteboard) {
        guard let document, !selectedHighlights.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(document.highlightsMarkdown(selectedHighlights), forType: .string)
    }

    @objc private func exportHighlights(_ sender: Any?) {
        document?.exportHighlightsAsMarkdown(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(editSelectedNote(_:)):
            return selectedHighlight.map { document?.canEdit($0.annotation) == true || !$0.note.isEmpty } ?? false
        case #selector(copyHighlightsAsMarkdown(_:)): return !selectedHighlights.isEmpty
        case #selector(exportHighlights(_:)): return !highlights.isEmpty
        default: return true
        }
    }

    @objc private func changeColor(_ sender: HighlightColorButton) {
        guard let selectedHighlight else { return }
        document?.recolorHighlight(selectedHighlight.annotation, color: sender.highlightColor.color)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { highlights.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActions()
        if !table.isHandlingMouse { activateSelection() }
    }

    @objc func activateSelection() {
        guard !syncing, let selectedHighlight else { return }
        onSelect?(selectedHighlight)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("savedHighlightCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? HighlightCell
            ?? HighlightCell(identifier: id)
        let item = highlights[row]
        cell.page.stringValue = item.pageReference
        cell.passage.stringValue = item.displayText
        cell.note.stringValue = item.note.isEmpty ? "" : "Note: " + item.note.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        cell.note.toolTip = item.note.isEmpty ? nil : item.note
        cell.note.isHidden = item.note.isEmpty
        cell.swatch.layer?.backgroundColor = item.annotation.color.withAlphaComponent(1).cgColor
        cell.updateColors()
        cell.setAccessibilityLabel("\(item.pageReference). \(cell.passage.stringValue). \(cell.note.stringValue)")
        return cell
    }
}

/// Native buttons keep keyboard and accessibility behavior; a drawn swatch and
/// contrasting checkmark make the color and selection visible in either theme.
final class HighlightColorButton: NSButton {
    let highlightColor: HighlightColor

    init(color: HighlightColor) {
        highlightColor = color
        super.init(frame: .zero)
        title = ""
        setButtonType(.momentaryChange)
        isBordered = false
        toolTip = color.title
        setAccessibilityLabel("\(color.title) highlight")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26), heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 4))
        highlightColor.color.withAlphaComponent(isEnabled ? 1 : 0.3).setFill()
        circle.fill()
        NSColor.labelColor.withAlphaComponent(isEnabled ? 0.35 : 0.1).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        if state == .on {
            // NSButton is flipped: increasing y moves down, unlike the
            // conventional AppKit drawing coordinates used by this path.
            let up: CGFloat = isFlipped ? -1 : 1
            let check = NSBezierPath()
            check.move(to: NSPoint(x: bounds.midX - 4, y: bounds.midY))
            check.line(to: NSPoint(x: bounds.midX - 1, y: bounds.midY - 3 * up))
            check.line(to: NSPoint(x: bounds.midX + 5, y: bounds.midY + 4 * up))
            check.lineWidth = 2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.black.withAlphaComponent(isEnabled ? 0.8 : 0.3).setStroke()
            check.stroke()
        }
        if isHighlighted {
            NSColor.black.withAlphaComponent(0.12).setFill()
            circle.fill()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A single context-menu row; native buttons remain individually accessible.
final class HighlightColorMenuView: NSView {
    private let onPick: (HighlightColor) -> Void

    init(title: String, enabled: Bool, selectedColor: NSColor?,
         onPick: @escaping (HighlightColor) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = enabled ? .labelColor : .disabledControlTextColor
        let colors = HighlightColor.allCases.map { color in
            let button = HighlightColorButton(color: color)
            button.isEnabled = enabled
            button.state = selectedColor.map { color.matches($0) } == true ? .on : .off
            button.setAccessibilityValue(button.state == .on ? "Selected" : "")
            button.target = self
            button.action = #selector(pickColor(_:))
            return button
        }
        let swatches = NSStackView(views: colors)
        swatches.spacing = 6
        for child in [label, swatches] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatches.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            swatches.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            swatches.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            swatches.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        frame = NSRect(origin: .zero, size: fittingSize)
    }

    @objc private func pickColor(_ sender: HighlightColorButton) {
        enclosingMenuItem?.menu?.cancelTracking()
        onPick(sender.highlightColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class HighlightsTable: NSTableView {
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
    private(set) var isHandlingMouse = false
    override func mouseDown(with event: NSEvent) {
        isHandlingMouse = true
        defer { isHandlingMouse = false }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .delete, .deleteForward: onDelete?()
        case .carriageReturn, .enter: sendAction(action, to: target)
        default: super.keyDown(with: event)
        }
    }
}

private final class HighlightCell: NSTableCellView {
    let page = NSTextField(labelWithString: "")
    let passage = NSTextField(wrappingLabelWithString: "")
    let note = NSTextField(wrappingLabelWithString: "")
    let swatch = NSView()
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }
    func updateColors() {
        page.textColor = backgroundStyle == .emphasized ? .selectedControlTextColor : .secondaryLabelColor
        passage.textColor = backgroundStyle == .emphasized ? .selectedControlTextColor : .labelColor
        note.textColor = backgroundStyle == .emphasized ? .selectedControlTextColor : .secondaryLabelColor
    }
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        page.font = .systemFont(ofSize: 11, weight: .medium)
        passage.font = .systemFont(ofSize: 12)
        passage.maximumNumberOfLines = 3
        passage.lineBreakMode = .byWordWrapping
        passage.cell?.isScrollable = false
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        note.font = .systemFont(ofSize: 11)
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping
        let text = NSStackView(views: [passage, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        for child in [page, text, swatch] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            swatch.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            swatch.widthAnchor.constraint(equalToConstant: 8),
            swatch.heightAnchor.constraint(equalToConstant: 8),
            page.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 6),
            page.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            page.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            text.topAnchor.constraint(equalTo: page.bottomAnchor, constant: 3),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            passage.widthAnchor.constraint(equalTo: text.widthAnchor),
            note.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
