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
}

/// `PDFView` with the three additions the Mac's `ReaderPDFView` has: the
/// dark-mode find highlights, arrow keys that always move a whole page, and a
/// way to reach the chrome from the keyboard.
///
/// Everything a key command needs already exists on `PDFView` except the find
/// shortcuts, so most of these are one-line forwards -- but they have to be
/// declared, because `UIKeyCommand` has no equivalent of AppKit's responder
/// chain picking up `goToNextPage:` from a menu item.
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
            key(UIKeyCommand.inputUpArrow, [], #selector(previousPage)),
            key(UIKeyCommand.inputLeftArrow, [], #selector(previousPage)),
            key(UIKeyCommand.inputDownArrow, [], #selector(nextPage)),
            key(UIKeyCommand.inputRightArrow, [], #selector(nextPage)),
            key(UIKeyCommand.inputUpArrow, .command, #selector(firstPage)),
            key(UIKeyCommand.inputDownArrow, .command, #selector(lastPage)),
            key("f", .command, #selector(focusFind)),
            key("g", .command, #selector(nextMatch)),
            key("g", [.command, .shift], #selector(previousMatch)),
            key("g", [.command, .alternate], #selector(goToPage)),
            key(UIKeyCommand.inputEscape, [], #selector(endFind)),
            // Both, because ⌘+ is typed as ⌘⇧= on most layouts and iOS reports
            // whichever character the key produced.
            key("+", .command, #selector(zoomInCommand)),
            key("=", .command, #selector(zoomInCommand)),
            key("-", .command, #selector(zoomOutCommand)),
            key("0", .command, #selector(zoomToFit))
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

    @objc private func previousPage() {
        if scrollsRatherThanPages { scroll(byViewports: -1) } else { goToPreviousPage(nil) }
    }

    @objc private func nextPage() {
        if scrollsRatherThanPages { scroll(byViewports: 1) } else { goToNextPage(nil) }
    }

    @objc private func firstPage() {
        if scrollsRatherThanPages { scroll(toOffset: 0) } else { goToFirstPage(nil) }
    }

    @objc private func lastPage() {
        if scrollsRatherThanPages {
            scroll(toOffset: .greatestFiniteMagnitude)
        } else {
            goToLastPage(nil)
        }
    }
    @objc private func zoomInCommand() { zoomIn(nil) }
    @objc private func zoomOutCommand() { zoomOut(nil) }
    @objc private func zoomToFit() { autoScales = true }
    @objc private func focusFind() { onCommand?(.focusFind) }
    @objc private func nextMatch() { onCommand?(.nextMatch) }
    @objc private func previousMatch() { onCommand?(.previousMatch) }
    @objc private func endFind() { onCommand?(.endFind) }
    @objc private func goToPage() { onCommand?(.goToPage) }
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
