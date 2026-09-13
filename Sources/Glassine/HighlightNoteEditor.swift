import AppKit

/// The sheet owns a draft and its undo stack. Done commits one document edit;
/// Cancel never changes the PDF. The save closure rechecks annotation identity.
final class HighlightNoteEditor: NSViewController {
    let textView = NSTextView()
    private let draftUndo = UndoManager()
    private let passage: String
    private let initialNote: String
    private let editable: Bool
    private let onSave: (String) -> Bool
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    override var undoManager: UndoManager? { draftUndo }

    init(highlight: SavedHighlight, editable: Bool, onSave: @escaping (String) -> Bool) {
        passage = highlight.displayText
        initialNote = highlight.note
        self.editable = editable
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 350))
        let title = NSTextField(labelWithString: editable ? "Highlight Note" : "Highlight Note (Read-Only)")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let quote = NSTextField(wrappingLabelWithString: passage)
        quote.font = .systemFont(ofSize: 12)
        quote.textColor = .secondaryLabelColor
        quote.maximumNumberOfLines = 3
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = editable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = initialNote
        textView.setAccessibilityLabel("Highlight note")
        scroll.documentView = textView
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        let cancel = NSButton(title: editable ? "Cancel" : "Close", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: "Done", target: self, action: #selector(saveNote(_:)))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = [.command]
        done.isHidden = !editable
        let buttons = NSStackView(views: [cancel, done])
        buttons.spacing = 8
        for child in [title, quote, scroll, errorLabel, buttons] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 440),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            quote.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            quote.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            quote.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: quote.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: quote.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 170),
            errorLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: quote.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: quote.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    @objc func saveNote(_ sender: Any?) {
        guard editable else { return }
        guard onSave(textView.string) else {
            errorLabel.stringValue = "This highlight is no longer editable. Copy your note before closing."
            return
        }
        if presentingViewController != nil { dismiss(self) }
    }

    @objc func cancel(_ sender: Any?) {
        if presentingViewController != nil { dismiss(self) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
