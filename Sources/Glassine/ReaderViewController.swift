import AppKit
import CoreImage
import GlassineCore
import ObjectiveC
import PDFKit

/// PDFView with two additions: it reports effective-appearance changes
/// (NSViewController has no hook for that -- only NSView does), and the arrow
/// keys always move a whole page instead of scrolling by a line.
final class ReaderPDFView: PDFView {
    var onEffectiveAppearanceChange: (() -> Void)?
    var readerModeActive = false
    var onReaderModeZoomToFit: (() -> Void)?
    var onReaderModeManualZoom: (() -> Void)?
    weak var highlightDocument: GlassineDocument?
    var onHighlightAdded: ((PDFAnnotation) -> Void)?
    var onEditHighlightNote: ((PDFAnnotation) -> Void)?

    @objc func highlightSelection(_ sender: Any?) {
        guard let selection = currentSelection,
              let color = HighlightColor(rawValue: (sender as? NSMenuItem)?.tag ?? 0),
              let first = highlightDocument?.addHighlight(selection: selection, color: color).first else { return }
        setCurrentSelection(nil, animate: false)
        onHighlightAdded?(first.annotation)
    }

    @objc func removeClickedHighlight(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation else { return }
        highlightDocument?.removeHighlight(annotation)
    }

    @objc func editClickedHighlightNote(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation,
              annotation.page?.document === document, document === highlightDocument?.pdf else { return }
        onEditHighlightNote?(annotation)
    }

    @objc func copyClickedHighlightAsMarkdown(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation,
              let page = annotation.page, page.document === document,
              let owner = highlightDocument, document === owner.pdf else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(owner.highlightsMarkdown([SavedHighlight(page: page, annotation: annotation)]), forType: .string)
    }

    // MARK: Plain-text addresses

    /// A plain-text address under the press now in progress, which Glassine
    /// opens itself rather than leaving to PDFKit, whose detection stops at
    /// the end of the line and so opens only the first half of an address the
    /// PDF wrapped.
    ///
    /// This is a gesture recognizer and not a `mouseDown(with:)` override on
    /// purpose. On macOS 27 PDFKit handles the mouse and a finger on a touch
    /// display through gesture recognizers of its own (text selection by
    /// touch, the long-press menu, double tap), and it installs none of them
    /// on a subclass that overrides `mouseDown`, `mouseDragged` or `mouseUp`:
    /// the view drops to the old tracking loop and a finger gets only AppKit's
    /// mouse emulation. `ReaderPDFViewGestureTests` holds that line.
    private var pendingTextLink: URL?

    /// Where the latest press began (view coordinates) and its click count; a
    /// touch counts as one click. `pdfViewWillClick(onLink:with:)` is told
    /// only the address PDFKit read, not where the click was.
    private var lastPress: (point: NSPoint, clickCount: Int)?

    fileprivate var textLinkClick: NSClickGestureRecognizer?
    private var textLinkFilter: TextLinkClickFilter?

    // MARK: Page turns by touch

    enum PageTurn { case back, forward }

    /// A finger tapped in the left strip of the view goes back a page, in the
    /// right strip forward: the arrow keys, for a hand already on the screen.
    /// Touch only (`buttonMask` 0), so a mouse click in the same place is
    /// still just a click, and installed only where there are touch displays.
    fileprivate var pageTurnTap: NSClickGestureRecognizer?

    /// The turn the touch now in progress would make, if it stays a tap.
    private var pendingPageTurn: PageTurn?

    /// Which turn a tap at `x` makes, by position alone. The strips are 14% of
    /// the view each, never narrower than a fingertip nor wider than 120 pt,
    /// and a view too narrow to leave a middle between them has none.
    static func pageTurnZone(x: CGFloat, in bounds: NSRect) -> PageTurn? {
        let strip = min(max(bounds.width * 0.14, 56), 120)
        guard bounds.width >= strip * 3 else { return nil }
        if x < bounds.minX + strip { return .back }
        if x > bounds.maxX - strip { return .forward }
        return nil
    }

    /// The turn a tap at this point makes. A link under the finger is a link,
    /// and the scroller is the scroller.
    func pageTurn(forTapAt point: NSPoint) -> PageTurn? {
        guard let turn = Self.pageTurnZone(x: point.x, in: bounds) else { return nil }
        if textLink(atViewPoint: point) != nil { return nil }
        if let page = page(for: point, nearest: false),
           let annotation = page.annotation(at: convert(point, to: page)),
           annotation.type == "Link" || annotation.type == "Widget" {
            return nil
        }
        if let superview, let hit = superview.hitTest(convert(point, to: superview)),
           sequence(first: hit, next: \.superview).contains(where: { $0 is NSScroller }) {
            return nil
        }
        return turn
    }

    /// What the arrow keys do: a page, or a viewport of a document that is
    /// one long page.
    func turnPage(_ turn: PageTurn) {
        if scrollsRatherThanPages {
            scrollByViewport(turn == .forward ? 1 : -1)
        } else if turn == .forward {
            goToNextPage(nil)
        } else {
            goToPreviousPage(nil)
        }
    }

    fileprivate func touchBegan(forPageTurnAt point: NSPoint) -> Bool {
        pendingPageTurn = pageTurn(forTapAt: point)
        return pendingPageTurn != nil
    }

    /// True while `pageTurnTap` has a claim on the touch.
    fileprivate var holdsPageTurnTouch: Bool { pendingPageTurn != nil }

    @objc private func pageTurnTapped(_ recognizer: NSClickGestureRecognizer) {
        guard let turn = pendingPageTurn else { return }
        pendingPageTurn = nil
        if recognizer.state == .ended { turnPage(turn) }
    }

    /// How an address is opened. A seam for tests, which must never launch a
    /// browser.
    var openURL: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installTextLinkHandling()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installTextLinkHandling()
    }

    private func installTextLinkHandling() {
        let filter = TextLinkClickFilter(view: self)
        let click = NSClickGestureRecognizer(target: self, action: #selector(textLinkClicked(_:)))
        click.delegate = filter
        if #available(macOS 27.0, *) {
            // A finger that lands on an address and then scrolls is scrolling.
            click.isCancellableByScrollGesture = true
        }
        addGestureRecognizer(click)
        textLinkClick = click
        textLinkFilter = filter
        if #available(macOS 27.0, *) {
            let tap = NSClickGestureRecognizer(target: self, action: #selector(pageTurnTapped(_:)))
            tap.buttonMask = 0
            tap.allowedTouchTypes = .direct
            tap.isCancellableByScrollGesture = true
            tap.delegate = filter
            addGestureRecognizer(tap)
            pageTurnTap = tap
        }
        // Every link PDFKit decides to open comes back through
        // `pdfKitWillOpen(_:)`.
        delegate = filter
    }

    /// The links PDFKit opens itself: a real link annotation, and its own
    /// reading of a plain-text address when a press was not `textLinkClick`'s
    /// to claim (a modified click, or a drag that began and ended on the
    /// address). PDFKit reads only to the end of the line, so the second kind
    /// is opened as the whole address under the press instead.
    fileprivate func pdfKitWillOpen(_ url: URL) {
        // The second click of a double click: the first already opened it.
        if let press = lastPress, press.clickCount > 1 { return }
        if let press = lastPress, let whole = textLink(atViewPoint: press.point) {
            openURL(whole)
        } else {
            openURL(url)
        }
    }

    /// Every mouse-down and touch-began on the view, before any recognizer has
    /// acted. True when the press is a plain single click or tap on a
    /// plain-text address, which `textLinkClick` then claims.
    fileprivate func pressBegan(at point: NSPoint, clickCount: Int, modified: Bool) -> Bool {
        lastPress = (point, clickCount)
        pendingTextLink = clickCount == 1 && !modified ? textLink(atViewPoint: point) : nil
        return pendingTextLink != nil
    }

    /// True while `textLinkClick` has a claim on the press, so PDFKit's own
    /// recognizers wait for it: without that they begin first and it never
    /// fires. A press that turns into a drag fails the click and PDFKit goes
    /// on to select text, as anywhere else on the page.
    fileprivate var holdsTextLinkPress: Bool { pendingTextLink != nil }

    @objc private func textLinkClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let url = pendingTextLink else { return }
        pendingTextLink = nil
        if recognizer.state == .ended, textLink(atViewPoint: recognizer.location(in: self)) == url {
            openURL(url)
        }
    }

    /// The plain-text address at a point in this view's coordinates, joined
    /// across the lines it wrapped over (see `PDFPage.textLinkURL(at:)`).
    func textLink(atViewPoint point: NSPoint) -> URL? {
        guard let page = page(for: point, nearest: false), page.string != nil else { return nil }
        let pagePoint = convert(point, to: page)
        // A real link annotation wins; PDFKit handles those correctly.
        if page.annotation(at: pagePoint)?.type == "Link" { return nil }
        // Not PDFKit's `characterIndex(at:)`, whose offset slips by a line
        // break per line; and on a scan under OCR text it names the page
        // image. See `linkCharacterIndex(at:)`.
        guard let index = page.linkCharacterIndex(at: pagePoint) else { return nil }
        return page.textLinkURL(at: index)
    }

    /// The pointer over a scan with OCR text. PDFKit reports the page image
    /// under every point of such a page and so shows a hand everywhere; this
    /// reports text over the lines and bare page between them, which gives
    /// the I-beam and the arrow of an ordinary page. `areaOfInterest(forMouse:)`
    /// and PDFKit's cursor code both come through here. Link and annotation
    /// areas are left as PDFKit found them.
    override func areaOfInterest(for cursorLocation: NSPoint) -> PDFAreaOfInterest {
        var area = super.areaOfInterest(for: cursorLocation)
        guard area.contains(.imageArea),
              let page = page(for: cursorLocation, nearest: false) as? ReaderPage,
              let overText = page.isOverScanText(at: convert(cursorLocation, to: page))
        else { return area }
        area.remove(.imageArea)
        if overText { area.insert(.textArea) } else { area.remove(.textArea) }
        return area
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        var clickedHighlight: PDFAnnotation?
        if let page = page(for: point, nearest: false) {
            let pagePoint = convert(point, to: page)
            clickedHighlight = page.annotations.reversed().first(where: {
                $0.type == "Highlight" &&
                    SavedHighlight.rects(for: $0).contains(where: { $0.contains(pagePoint) })
            })
        }
        // PDFKit's native markup picker is not safe to copy, and its edits
        // bypass our document undo tracking. Keep PDFKit's lookup, copy, link
        // and navigation items even when the selected text is highlighted.
        let menu = super.menu(for: event) ?? NSMenu()
        // Identify (never invoke) PDFKit's built-in mutation actions. They do
        // not notify Glassine or participate in its undo/autosave workflow.
        let nativeEdits: Set<String> = ["_removeMarkup:", "_addNote:"]
        for item in menu.items where item.view != nil ||
            item.action.map({ nativeEdits.contains(NSStringFromSelector($0)) }) == true ||
            item.identifier?.rawValue.hasPrefix("glassine.context.") == true {
            menu.removeItem(item)
        }
        if currentSelection?.string?.isEmpty == false {
            let copy = menu.addItem(withTitle: "Copy Without Cleanup", action: #selector(copyRaw(_:)), keyEquivalent: "")
            copy.target = self
            copy.identifier = NSUserInterfaceItemIdentifier("glassine.context.copyRaw")
        }
        menu.insertItem(makeHighlightMenuItem(annotation: clickedHighlight), at: 0)
        if let annotation = clickedHighlight {
            let item = NSMenuItem(title: "Delete Highlight", action: #selector(removeClickedHighlight(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = annotation
            item.identifier = NSUserInterfaceItemIdentifier("glassine.context.deleteHighlight")
            menu.insertItem(item, at: 1)
            let noteTitle = annotation.contents?.isEmpty == false ? "Edit Note…" : "Add Note…"
            let note = NSMenuItem(title: highlightDocument?.canEdit(annotation) == true ? noteTitle : "View Note…",
                action: #selector(editClickedHighlightNote(_:)), keyEquivalent: "")
            note.target = self
            note.representedObject = annotation
            note.identifier = NSUserInterfaceItemIdentifier("glassine.context.note")
            menu.insertItem(note, at: 2)
            let copy = NSMenuItem(title: "Copy Highlight as Markdown", action: #selector(copyClickedHighlightAsMarkdown(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = annotation
            copy.identifier = NSUserInterfaceItemIdentifier("glassine.context.copyHighlight")
            menu.insertItem(copy, at: 3)
        }
        if clickedHighlight == nil {
            let separator = NSMenuItem.separator()
            separator.identifier = NSUserInterfaceItemIdentifier("glassine.context.separator")
            menu.insertItem(separator, at: 1)
        }
        return menu
    }

    func makeHighlightMenuItem(annotation: PDFAnnotation?) -> NSMenuItem {
        // Capture the selection while the menu opens; menu tracking can change
        // focus and PDFKit's live selection before the button action arrives.
        let selection = currentSelection?.copy() as? PDFSelection
        let owner = highlightDocument
        let enabled = annotation.map { owner?.canEdit($0) == true }
            ?? (owner?.canEditHighlights == true && selection?.string?.isEmpty == false)
        let title = annotation == nil ? "Highlight" : "Highlight Color"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("glassine.context.highlightColors")
        item.view = HighlightColorMenuView(title: title, enabled: enabled,
            selectedColor: annotation?.color) { [weak self, weak owner] color in
                guard let self, let owner, self.highlightDocument === owner,
                      self.document === owner.pdf else { return }
                if let annotation {
                    owner.recolorHighlight(annotation, color: color.color)
                } else if let selection,
                          let first = owner.addHighlight(selection: selection, color: color).first {
                    self.setCurrentSelection(nil, animate: false)
                    self.onHighlightAdded?(first.annotation)
                }
            }
        return item
    }

    /// The dark-mode highlight bookkeeping, which is platform-independent and
    /// lives in Core; this view is just its host.
    private lazy var highlighter = FindHighlighter(pdfView: self)

    /// Set by the window controller. When true, find matches are drawn here as
    /// reverse video instead of PDFKit's translucent yellow, because a yellow
    /// wash reads poorly through the dark-mode inversion filter.
    var isInverted = false {
        didSet { highlighter.isInverted = isInverted }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    // MARK: Reverse-video find highlights

    func setFindMatches(_ selections: [PDFSelection], current: Int) {
        highlighter.setFindMatches(selections, current: current)
    }

    func setCurrentMatchIndex(_ index: Int) {
        highlighter.setCurrentMatchIndex(index)
    }

    /// The scroll geometry, when there is any: PDFKit builds a fresh document
    /// view per document, so this is resolved on demand rather than cached.
    private var scrollGeometry: (clip: NSClipView, documentView: NSView)? {
        guard let documentView, let clip = documentView.enclosingScrollView?.contentView
        else { return nil }
        return (clip, documentView)
    }

    /// One page, taller than the window: a continuous Markdown render, or a
    /// single-page PDF zoomed past the frame. There is no next page to go to, so
    /// page navigation is a no-op and the arrows have to scroll instead.
    private var scrollsRatherThanPages: Bool {
        guard document?.pageCount == 1, let (clip, documentView) = scrollGeometry else {
            return false
        }
        return documentView.bounds.height > clip.bounds.height + 1
    }

    /// How far the top of the visible area has travelled down the document --
    /// the same quantity the window's progress readout uses, and stated for a
    /// flipped and an unflipped document view alike so a future PDFKit cannot
    /// reverse it silently.
    private var scrollOffset: CGFloat {
        guard let (clip, documentView) = scrollGeometry else { return 0 }
        return documentView.isFlipped
            ? clip.bounds.minY - documentView.bounds.minY
            : documentView.bounds.maxY - clip.bounds.maxY
    }

    /// Put the top of the visible area `offset` down the scrollable range,
    /// clamped to its ends -- so the last press at either end lands exactly on
    /// it instead of overshooting or beeping.
    ///
    /// This moves the clip view itself rather than sending `scrollPageDown(_:)`:
    /// PDFView is an NSView wrapping a private scroll view and the responder
    /// chain runs child → parent, so those actions sent to this view walk up
    /// past the window instead of down into the scroller.
    private func scroll(toOffset offset: CGFloat) {
        guard let (clip, documentView) = scrollGeometry else { return }
        let span = max(documentView.bounds.height - clip.bounds.height, 0)
        let clamped = min(max(offset, 0), span)
        var origin = clip.bounds.origin
        origin.y = documentView.isFlipped
            ? documentView.bounds.minY + clamped
            : documentView.bounds.maxY - clip.bounds.height - clamped
        clip.scroll(to: origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// One viewport per press, less a little overlap so the line you stopped on
    /// is still there.
    private func scrollByViewport(_ direction: CGFloat) {
        guard let (clip, _) = scrollGeometry else { return }
        let step = max(clip.bounds.height - 24, 1)
        scroll(toOffset: scrollOffset + direction * step)
    }

    /// Page-at-a-time arrows. This lives on the view, so arrow keys still edit
    /// text normally while the search field or page field has focus. Page
    /// Up/Down and Space/Shift-Space fall through to PDFView untouched.
    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        // A continuous Markdown document is one page: "next page" has nothing
        // to do, so the same keys move a viewport at a time instead. Ordinary
        // documents are unaffected.
        if scrollsRatherThanPages {
            switch event.specialKey {
            case .upArrow, .leftArrow:
                if command && event.specialKey == .upArrow { scroll(toOffset: 0) }
                else { scrollByViewport(-1) }
                return
            case .downArrow, .rightArrow:
                if command && event.specialKey == .downArrow {
                    scroll(toOffset: .greatestFiniteMagnitude)
                } else {
                    scrollByViewport(1)
                }
                return
            default:
                break
            }
        }
        switch event.specialKey {
        case .upArrow, .leftArrow:
            if command && event.specialKey == .upArrow { goToFirstPage(nil) }
            else { goToPreviousPage(nil) }
        case .downArrow, .rightArrow:
            if command && event.specialKey == .downArrow { goToLastPage(nil) }
            else { goToNextPage(nil) }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Copying

    /// Copy the selection as flowing text rather than as printed lines.
    ///
    /// PDFKit hands over exactly what the page shows: a hard return at every
    /// line end, and a word broken across a line still split and hyphenated.
    /// Pasted anywhere that is not a PDF, that is a wall of ragged lines to
    /// re-flow by hand. `CopyCleanup` puts the paragraphs back together;
    /// "Copy Without Cleanup" (⌥⌘C) still reaches PDFKit's own copy for the
    /// paste that wants the lines as printed.
    override func copy(_ sender: Any?) {
        // Nothing but a page image (U+FFFC) selected: PDFKit's copy, as before
        // there was text to clean. With text alongside, the cleanup drops it.
        guard let selection = currentSelection,
              let raw = selection.string, !raw.isEmpty,
              !PageTextMap.isGraphicOnly(raw) else {
            super.copy(sender)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(CopyCleanup.text(for: selection, isWord: Self.isWord),
                             forType: .string)
    }

    /// PDFKit's untouched copy.
    @objc func copyRaw(_ sender: Any?) {
        super.copy(sender)
    }

    /// "Is this a word?", answered by the system dictionary through the spell
    /// checker: a whole-word check that finds nothing to correct. One letter is
    /// never asked about -- the checker accepts most single letters, which would
    /// make "a-" / "bove" look like a compound and keep a hyphen that was a
    /// syllable break.
    private static func isWord(_ word: String) -> Bool {
        guard word.count >= 2 else { return false }
        let found = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0)
        return found.location == NSNotFound
    }
}

/// The delegate of `ReaderPDFView.textLinkClick`, and the view's
/// `PDFViewDelegate`. A separate object because PDFView answers both sets of
/// delegate messages itself: its own `PDFViewWillChangeScaleFactor:toScale:`
/// forwards to the delegate, so a view that is its own delegate recurses until
/// the stack runs out, and a gesture delegate method on the subclass would
/// replace PDFKit's.
private final class TextLinkClickFilter: NSObject, NSGestureRecognizerDelegate, PDFViewDelegate {

    private weak var view: ReaderPDFView?

    init(view: ReaderPDFView) { self.view = view }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        view?.pdfKitWillOpen(url)
    }

    /// Mouse input. Also asked about scroll and magnify events, which are
    /// never a click.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let view, gestureRecognizer === view.textLinkClick,
              event.type == .leftMouseDown else { return false }
        let modified = !event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
        return view.pressBegan(at: view.convert(event.locationInWindow, from: nil),
                               clickCount: event.clickCount, modified: modified)
    }

    /// A finger on a touch display, which never arrives as an event.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        guard let view else { return false }
        let point = touch.location(in: view)
        if gestureRecognizer === view.pageTurnTap { return view.touchBegan(forPageTurnAt: point) }
        return view.pressBegan(at: point, clickCount: 1, modified: false)
    }

    /// PDFKit's recognizers on the view and its pages wait for the click to
    /// fail. Scrolling does not wait: the scroll view's own recognizers are
    /// left out.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let view, let other = otherGestureRecognizer.view, !(other is NSScrollView),
              other === view || other.isDescendant(of: view) else { return false }
        guard gestureRecognizer === view.pageTurnTap else { return view.holdsTextLinkPress }
        // The page-turn tap. An address under the finger is the text-link
        // click's, and a finger that stays down is PDFKit's: its recognizers
        // that need a hold (the menu, a drag, a selection) do not wait, and
        // when one of them begins the tap is over.
        guard view.holdsPageTurnTouch, otherGestureRecognizer !== view.textLinkClick else { return false }
        if let press = otherGestureRecognizer as? NSPressGestureRecognizer, press.minimumPressDuration > 0 {
            return false
        }
        return true
    }
}

/// Menu validation, which PDFView does in Objective-C.
///
/// `validateMenuItem:` is implemented by PDFView but declared nowhere in its
/// Swift interface, so this cannot be an `override` and `super` cannot be
/// spelled: at runtime this implementation simply replaces PDFKit's for this
/// class. Everything except our own action is therefore handed back to PDFView's
/// implementation through the runtime. Dropping it instead would take the
/// answers for Copy, Select All and the page and zoom items with it.
extension ReaderPDFView: NSMenuItemValidation {

    private typealias Validate = @convention(c) (AnyObject, Selector, NSMenuItem) -> ObjCBool

    private static let pdfViewValidate: Validate? = {
        let selector = #selector(NSMenuItemValidation.validateMenuItem(_:))
        guard let method = class_getInstanceMethod(PDFView.self, selector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: Validate.self)
    }()

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(editClickedHighlightNote(_:)) ||
            menuItem.action == #selector(copyClickedHighlightAsMarkdown(_:)) {
            guard let annotation = menuItem.representedObject as? PDFAnnotation,
                  annotation.page?.document === document, document === highlightDocument?.pdf else { return false }
            if menuItem.action == #selector(copyClickedHighlightAsMarkdown(_:)) { return true }
            return onEditHighlightNote != nil &&
                (highlightDocument?.canEdit(annotation) == true || annotation.contents?.isEmpty == false)
        }

        if menuItem.action == #selector(highlightSelection(_:)) {
            return highlightDocument?.canEditHighlights == true && currentSelection?.string?.isEmpty == false
        }
        if menuItem.action == #selector(removeClickedHighlight(_:)) {
            guard let annotation = menuItem.representedObject as? PDFAnnotation else { return false }
            return highlightDocument?.canEdit(annotation) == true
        }
        if menuItem.action == #selector(copyRaw(_:)) {
            return currentSelection?.string?.isEmpty == false
        }
        guard let inherited = Self.pdfViewValidate else { return true }
        return inherited(self, #selector(NSMenuItemValidation.validateMenuItem(_:)),
                         menuItem).boolValue
    }
}


/// Hosts the PDFView and owns the light/dark rendering decision for its window.
final class ReaderViewController: NSViewController {

    let pdfView = ReaderPDFView()
    lazy var findMatchIndicator = FindMatchIndicator(pdfView: pdfView)
    private let glassineDocument: GlassineDocument
    var onViewportSizeChange: (() -> Void)?
    private let readerModeStatus = NSTextField(labelWithString: "Preparing Reader Mode…")

    /// True when pages are being shown light-on-dark.
    private(set) var isInverted = false

    private struct AppearancePreferences: Equatable {
        let mode: AppearanceMode
        let invert: Bool
        let paper: DarkPaper
        let brightness: Double

        static var current: Self {
            Self(mode: Prefs.appearance, invert: Prefs.invertInDarkMode, paper: Prefs.darkPaper,
                 brightness: Prefs.darkModeBrightness)
        }
    }
    private var appliedPreferences: AppearancePreferences?

    /// Called after every appearance pass with the current inversion state, so
    /// the window can keep the sidebar and the find highlights in step.
    var onInversionChanged: ((Bool) -> Void)?

    /// Luminance inversion that keeps hues: invert, then rotate hue 180 degrees,
    /// so blue links stay blue instead of turning orange. A third stage sets
    /// the paper's background and dims its content for low-light reading,
    /// without touching the light-mode path.
    /// CIFilters are mutable objects, so each view gets its own chain rather
    /// than sharing one static set across windows and the sidebar.
    static func makeDarkFilters() -> [CIFilter] {
        guard let invert = CIFilter(name: "CIColorInvert"),
              let hue = CIFilter(name: "CIHueAdjust") else { return [] }
        hue.setValue(Float.pi, forKey: "inputAngle")

        let paper = Prefs.darkPaper
        let brightness = CGFloat(Prefs.darkModeBrightness)
        guard paper != .black || brightness < 1,
              let compress = CIFilter(name: "CIColorMatrix") else {
            return [invert, hue]
        }
        // Brightness changes the content end of the range, leaving the selected
        // black/charcoal/gray paper unchanged. Interpolate in screen sRGB so the
        // slider feels even, then convert both endpoints for the layer filter.
        let top = paper.lift + brightness * (paper.top - paper.lift)
        // out = lift + (top - lift) * in, per channel, in the linear light the
        // layer filters work in (same reason the gutter is 0.997 pre-filter), so
        // the levels are converted from the screen values they are written as.
        let lift = linearLight(paper.lift)
        let span = linearLight(top) - lift
        compress.setValue(CIVector(x: span, y: 0, z: 0, w: 0), forKey: "inputRVector")
        compress.setValue(CIVector(x: 0, y: span, z: 0, w: 0), forKey: "inputGVector")
        compress.setValue(CIVector(x: 0, y: 0, z: span, w: 0), forKey: "inputBVector")
        compress.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        compress.setValue(CIVector(x: lift, y: lift, z: lift, w: 0), forKey: "inputBiasVector")
        return [invert, hue, compress]
    }

    /// sRGB value to linear light. Core Animation ignores the colour channels of
    /// `inputAVector`, so the lift has to be a plain bias and this is the space
    /// it lands in.
    private static func linearLight(_ value: CGFloat) -> CGFloat {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    init(document: GlassineDocument) {
        self.glassineDocument = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func loadView() {
        let container = NSView()
        for child in [pdfView, findMatchIndicator] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                child.topAnchor.constraint(equalTo: container.topAnchor),
                child.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        view = container
        readerModeStatus.font = .systemFont(ofSize: 12)
        readerModeStatus.textColor = .secondaryLabelColor
        readerModeStatus.drawsBackground = true
        readerModeStatus.backgroundColor = .windowBackgroundColor
        readerModeStatus.isHidden = true
        readerModeStatus.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(readerModeStatus)
        NSLayoutConstraint.activate([
            readerModeStatus.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            readerModeStatus.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.enableDataDetectors = false
        // Inversion is a layer filter on the whole view, so PDFKit's own white
        // placeholder tiles are inverted too and pages never flash white.
        pdfView.wantsLayer = true
        pdfView.document = glassineDocument.pdf
        pdfView.highlightDocument = glassineDocument
        pdfView.onEffectiveAppearanceChange = { [weak self] in self?.applyAppearance() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(prefsChanged),
            name: .glassinePrefsChanged,
            object: nil
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        applyAppearance()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        onViewportSizeChange?()
    }

    func setReaderModePreparing(_ preparing: Bool) {
        readerModeStatus.isHidden = !preparing
    }

    @objc private func prefsChanged() {
        // Blur and opacity sliders notify on every tick. Rebuilding PDF
        // filters, sidebar thumbnails and find highlights for those ticks
        // can stall menu tracking, especially with several documents open.
        guard appliedPreferences != .current else { return }
        applyAppearance()
    }

    // MARK: Appearance

    private func applyAppearance() {
        appliedPreferences = .current
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let invert = dark && Prefs.invertInDarkMode

        // The filter inverts everything inside the view, gutter included, so the
        // pre-filter gutter colour is the complement of what we want to see.
        // CIColorInvert works in linear light, so the pre-filter gutter has to
        // sit very close to white to come out near-black: 0.997 composites to
        // roughly 0.07, dark enough to read as black but still just visible
        // against the pure-black page paper at a page break.
        pdfView.backgroundColor = invert
            ? NSColor(white: 0.997, alpha: 1)
            : NSColor(white: dark ? 0.11 : 0.94, alpha: 1)

        // Rebuilt rather than cached: the chain depends on Prefs.darkPaper,
        // which this pass may be reacting to.
        pdfView.contentFilters = invert ? Self.makeDarkFilters() : []
        // Inverted, PDFKit's drop shadows become bright halos around every page
        // and a light band at the end of the document.
        pdfView.pageShadowsEnabled = !invert && !pdfView.readerModeActive

        if isInverted != invert {
            isInverted = invert
        }
        onInversionChanged?(invert)
    }

    // MARK: Actions

    @objc func zoomToFit(_ sender: Any?) {
        if pdfView.readerModeActive {
            pdfView.onReaderModeZoomToFit?()
            return
        }
        pdfView.autoScales = true
    }

    @objc func actualSize(_ sender: Any?) {
        pdfView.onReaderModeManualZoom?()
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
    }
}
