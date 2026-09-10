import GlassineCore
import PDFKit
import SwiftUI
import UIKit

/// What a hardware keyboard can ask the reader to do. The `PDFView` subclass
/// handles the ones PDFKit already implements and hands the rest up to SwiftUI,
/// which owns the find bar, the page popover and the sheets.
enum ReaderCommand {
    case focusFind
    case nextMatch
    case previousMatch
    case endFind
    case goToPage
    case newWindow
}

/// `PDFView` with the three additions the Mac's `ReaderPDFView` has: the
/// dark-mode find highlights, arrow keys that always move a whole page, and a
/// way to reach the chrome from the keyboard.
///
/// Everything a key command needs already exists on `PDFView` except the find
/// shortcuts, so most of these are one-line forwards -- but they have to be
/// declared, because `UIKeyCommand` has no equivalent of AppKit's responder
/// chain picking up `goToNextPage:` from a menu item.
///
/// Every handler is named `command…`, and that prefix is load-bearing. The
/// handlers were once `nextPage()`, `previousPage()` and so on, and on Dan's
/// iPad Pro (iPadOS 26.6) PDFKit's own `goToNextPage:` turned out to call a
/// selector of exactly that name on the view -- which the Objective-C runtime
/// resolved to *our* `@objc nextPage`, which called `goToNextPage:`, which
/// called `nextPage`… until the stack guard page was hit and the app died with
/// `EXC_BAD_ACCESS` at the end of the hardware-keyboard test (the iOS 26.5
/// simulator's PDFKit does no such thing, so 26 green tests there never saw
/// it). A private `@objc` method is still a selector on the class, and a
/// subclass has no way to know which unpublished selectors its superclass
/// sends itself; a prefix no framework would use is the only defence.
final class ReaderPDFView: PDFView {

    /// Platform-independent highlight bookkeeping; this view is just its host.
    private lazy var highlighter = FindHighlighter(pdfView: self)

    /// When true, matches are drawn by `ReaderPage` as green boxes instead of
    /// PDFKit's translucent wash, which reads poorly through the inversion.
    var isInverted = false {
        didSet { highlighter.isInverted = isInverted }
    }

    /// Set by the representable. Commands the view cannot service itself.
    var onCommand: ((ReaderCommand) -> Void)?

    /// PDFKit's own scroll view, which is where a continuous document actually
    /// moves. Not API, but it is the only `UIScrollView` PDFView owns, and the
    /// Contents pane needs to know when it scrolls.
    var enclosedScrollView: UIScrollView? {
        var queue: [UIView] = subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? UIScrollView { return scrollView }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: Find highlights

    func setFindMatches(_ selections: [PDFSelection], current: Int) {
        highlighter.setFindMatches(selections, current: current)
    }

    func setCurrentMatchIndex(_ index: Int) {
        highlighter.setCurrentMatchIndex(index)
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            key(UIKeyCommand.inputUpArrow, [], #selector(commandPreviousPage)),
            key(UIKeyCommand.inputLeftArrow, [], #selector(commandPreviousPage)),
            key(UIKeyCommand.inputDownArrow, [], #selector(commandNextPage)),
            key(UIKeyCommand.inputRightArrow, [], #selector(commandNextPage)),
            key(UIKeyCommand.inputUpArrow, .command, #selector(commandFirstPage)),
            key(UIKeyCommand.inputDownArrow, .command, #selector(commandLastPage)),
            key("f", .command, #selector(commandFocusFind)),
            key("g", .command, #selector(commandNextMatch)),
            key("g", [.command, .shift], #selector(commandPreviousMatch)),
            key("g", [.command, .alternate], #selector(commandGoToPage)),
            // The Mac's Cmd-T, spelled the way iPadOS spells a second window.
            // The menu item declares the same shortcut; this is what answers the
            // key while the menu is shut and the reader has the responder.
            key("n", .command, #selector(commandNewWindow)),
            key(UIKeyCommand.inputEscape, [], #selector(commandEndFind)),
            // Both, because ⌘+ is typed as ⌘⇧= on most layouts and iOS reports
            // whichever character the key produced.
            key("+", .command, #selector(commandZoomInCommand)),
            key("=", .command, #selector(commandZoomInCommand)),
            key("-", .command, #selector(commandZoomOutCommand)),
            key("0", .command, #selector(commandZoomToFit))
        ]
        // Without this the scroll view swallows the plain arrows and the page
        // creeps by a line instead of turning.
        for command in commands where command.modifierFlags.isEmpty {
            command.wantsPriorityOverSystemBehavior = true
        }
        commands.append(contentsOf: super.keyCommands ?? [])
        return commands
    }

    private func key(_ input: String, _ flags: UIKeyModifierFlags,
                     _ action: Selector) -> UIKeyCommand {
        UIKeyCommand(input: input, modifierFlags: flags, action: action)
    }

    // MARK: Copying

    /// Copy the selection as flowing text rather than as printed lines.
    ///
    /// PDFKit hands over exactly what the page shows: a hard return at every
    /// line end, and a word broken across a line still split and hyphenated.
    /// `CopyCleanup` puts the paragraphs back together. The Mac keeps PDFKit's
    /// own copy on ⌥⌘C; there is no second copy command here yet.
    override func copy(_ sender: Any?) {
        guard let selection = currentSelection,
              let raw = selection.string, !raw.isEmpty else {
            super.copy(sender)
            return
        }
        UIPasteboard.general.string = CopyCleanup.text(for: selection, isWord: Self.isWord)
    }

    /// "Is this a word?", answered by the system dictionary: a whole-word check
    /// that finds nothing to correct. One letter is never asked about -- the
    /// checker accepts most single letters, which would make "a-" / "bove" look
    /// like a compound and keep a hyphen that was a syllable break.
    private static func isWord(_ word: String) -> Bool {
        guard word.count >= 2 else { return false }
        let whole = NSRange(location: 0, length: word.utf16.count)
        let misspelled = UITextChecker().rangeOfMisspelledWord(
            in: word, range: whole, startingAt: 0, wrap: false, language: "en_US")
        return misspelled.location == NSNotFound
    }

    // MARK: Scrolling instead of paging

    /// One page, taller than the view: a continuous Markdown render, or a
    /// single-page PDF zoomed past the frame. There is no next page to go to, so
    /// page navigation is a no-op and the arrows have to scroll instead -- the
    /// Mac learned the same thing (BUG-007).
    private var scrollsRatherThanPages: Bool {
        guard document?.pageCount == 1, let scrollView = enclosedScrollView else {
            return false
        }
        return scrollView.contentSize.height > scrollView.bounds.height + 1
    }

    /// One viewport per press, less a little overlap so the line you stopped on
    /// is still there. Clamped at both ends, so the last press lands exactly on
    /// the end instead of overshooting.
    private func scroll(byViewports direction: CGFloat) {
        guard let scrollView = enclosedScrollView else { return }
        let inset = scrollView.adjustedContentInset
        let visible = scrollView.bounds.height - inset.top - inset.bottom
        scroll(toOffset: scrollView.contentOffset.y + inset.top
               + direction * max(visible - 24, 1))
    }

    private func scroll(toOffset offset: CGFloat) {
        guard let scrollView = enclosedScrollView else { return }
        let inset = scrollView.adjustedContentInset
        let visible = scrollView.bounds.height - inset.top - inset.bottom
        let span = max(scrollView.contentSize.height - visible, 0)
        let clamped = min(max(offset, 0), span)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x,
                                            y: clamped - inset.top),
                                    animated: false)
    }

    @objc private func commandPreviousPage() {
        if scrollsRatherThanPages { scroll(byViewports: -1) } else { goToPreviousPage(nil) }
    }

    @objc private func commandNextPage() {
        if scrollsRatherThanPages { scroll(byViewports: 1) } else { goToNextPage(nil) }
    }

    @objc private func commandFirstPage() {
        if scrollsRatherThanPages { scroll(toOffset: 0) } else { goToFirstPage(nil) }
    }

    @objc private func commandLastPage() {
        if scrollsRatherThanPages {
            scroll(toOffset: .greatestFiniteMagnitude)
        } else {
            goToLastPage(nil)
        }
    }
    @objc private func commandZoomInCommand() { zoomIn(nil) }
    @objc private func commandZoomOutCommand() { zoomOut(nil) }
    @objc private func commandZoomToFit() { autoScales = true }
    @objc private func commandFocusFind() { onCommand?(.focusFind) }
    @objc private func commandNextMatch() { onCommand?(.nextMatch) }
    @objc private func commandPreviousMatch() { onCommand?(.previousMatch) }
    @objc private func commandEndFind() { onCommand?(.endFind) }
    @objc private func commandGoToPage() { onCommand?(.goToPage) }
    @objc private func commandNewWindow() { onCommand?(.newWindow) }
}

/// Off, as on the Mac: scanning page text for phone numbers and addresses and
/// inserting temporary link annotations is not what a reader wants.
///
/// Through KVC because PDFKit deprecated `PDFView.enableDataDetectors` on iOS 18
/// "in favor of -[PDFDocument enableDataDetectors]" -- which the iOS 26 SDK does
/// not actually declare. The deprecated property is therefore still the only way
/// to say this, and setting it directly is a warning in a build that must have
/// none. It is an ObjC property, so the key is its name.
@MainActor
private func disableDataDetectors(on view: PDFView) {
    view.setValue(false, forKey: "enableDataDetectors")
}

/// The reader itself. Everything inside this representable is inverted in dark
/// mode and nothing else is, which is why the toolbar and the find bar are the
/// caller's, not this view's.
struct ReaderPDFViewRepresentable: UIViewRepresentable {

    let session: DocumentSession
    let inverted: Bool
    let colorScheme: ColorScheme
    let onCommand: (ReaderCommand) -> Void

    func makeUIView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.displaysPageBreaks = true
        disableDataDetectors(on: view)
        // The reader is one scrolling document, not a page-turning book; the
        // page view controller also breaks `go(to:)` mid-page.
        view.usePageViewController(false)
        view.accessibilityIdentifier = "readerPDFView"
        view.onCommand = onCommand
        session.attach(view)
        apply(to: view)
        return view
    }

    func updateUIView(_ view: ReaderPDFView, context: Context) {
        view.onCommand = onCommand
        session.attach(view)
        apply(to: view)
        session.inversionChanged(to: inverted)
    }

    private func apply(to view: ReaderPDFView) {
        // The filter inverts everything inside the view, gutter included, so
        // the gutter is chosen for what it becomes. See ReaderTheme.
        let background: UIColor = inverted
            ? ReaderTheme.invertedGutter
            : (colorScheme == .dark ? ReaderTheme.darkGutter : ReaderTheme.lightGutter)
        if view.backgroundColor != background { view.backgroundColor = background }
        // Inverted, PDFKit's drop shadows become bright halos around every page
        // and a light band at the end of the document.
        if view.pageShadowsEnabled == inverted { view.pageShadowsEnabled = !inverted }
    }
}
