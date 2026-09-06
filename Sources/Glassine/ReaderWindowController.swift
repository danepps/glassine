import AppKit
import PDFKit

extension NSToolbarItem.Identifier {
    static let pageIndicator = NSToolbarItem.Identifier("glassine.pageIndicator")
    static let search = NSToolbarItem.Identifier("glassine.search")
    static let searchCount = NSToolbarItem.Identifier("glassine.searchCount")
    static let searchNav = NSToolbarItem.Identifier("glassine.searchNav")
}

/// Toolbar view for the page indicator: just a container that shows a
/// pointing-hand cursor, so the number reads as clickable.
private final class PageIndicatorContainer: NSView {
    /// While the page field is being edited the capsule gets an accent ring:
    /// the tinted field alone reads as "the number got selected" in dark mode,
    /// not as a box you are typing in.
    var isEditing = false {
        didSet { applyEditingBorder() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyEditingBorder()
    }

    func applyEditingBorder() {
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = 6   // matches the toolbar item's capsule
        layer.borderWidth = isEditing ? 1.5 : 0
        guard isEditing else {
            layer.borderColor = nil
            return
        }
        // A CGColor is resolved once and does not follow the appearance, so
        // pin it to ours every time the ring goes up.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
}

/// The private CoreGraphics call Terminal and iTerm use to blur the desktop
/// behind a transparent window; there is no public equivalent for a window
/// whose content is a PDFView. Both symbols are resolved through RTLD_DEFAULT
/// at first use, so a macOS that withdraws them costs the blur, not the app.
private enum BackdropBlur {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int32, Int32, Int32) -> Int32

    /// Radius that reads as a blur without smearing the desktop into a wash.
    static let radius: Int32 = 24

    static let apply: ((NSWindow, Int32) -> Void)? = {
        let processHandle = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let connectionSymbol = dlsym(processHandle, "CGSMainConnectionID"),
              let blurSymbol = dlsym(processHandle, "CGSSetWindowBackgroundBlurRadius")
        else { return nil }
        let connectionID = unsafeBitCast(connectionSymbol, to: MainConnectionID.self)
        let setRadius = unsafeBitCast(blurSymbol, to: SetBlurRadius.self)
        return { window, radius in
            guard window.windowNumber > 0 else { return }
            _ = setRadius(connectionID(), Int32(window.windowNumber), radius)
        }
    }()
}

/// Chrome, translucency and the backdrop blur in one pass, because they share
/// the window's background colour. In dark mode the title bar and tab bar sit on
/// the same tone as the inverted page paper; the toolbar controls keep their own
/// glass capsules. Tabs are separate windows, so every window does this for
/// itself -- a start tab included, which is why this is not a method on the
/// reader's controller.
enum WindowChrome {

    static func apply(to window: NSWindow, content: NSView?) {
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        window.titlebarAppearsTransparent = dark
        window.titlebarSeparatorStyle = dark ? .none : .automatic
        // Black unless the pages are actually being lifted off black.
        let level = Prefs.darkPaper
        let paper: NSColor = (level != .black && Prefs.invertInDarkMode)
            ? NSColor(white: level.lift, alpha: 1) : .black

        let opacity = Prefs.windowOpacity
        let translucent = opacity < Prefs.maxWindowOpacity
        // Fading the window itself (alphaValue) leaves the desktop behind it
        // perfectly sharp. Fading only the content leaves the window's own
        // pixels transparent, and transparent pixels are what the compositor
        // blurs behind.
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : (dark ? paper : .windowBackgroundColor)
        if let content {
            content.wantsLayer = true
            content.alphaValue = translucent ? opacity : 1
        }
        BackdropBlur.apply?(window, translucent && Prefs.windowBlur ? BackdropBlur.radius : 0)
    }
}

/// One window (or tab) per document: sidebar + PDFView, a unified toolbar with
/// a page indicator and a search field, incremental find, and reading-position
/// memory.
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                    NSSearchFieldDelegate, NSTextFieldDelegate,
                                    NSMenuItemValidation, FindSink {

    private let glassineDocument: GlassineDocument
    private let readerVC: ReaderViewController
    private let sidebarVC: SidebarViewController
    private let splitVC = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem?
    private var didSettleSidebar = false

    private let pageLabel = NSTextField(labelWithString: "")
    private let pageField = NSTextField()
    private weak var pageIndicator: PageIndicatorContainer?
    private weak var pageIndicatorItem: NSToolbarItem?
    private weak var searchItem: NSSearchToolbarItem?
    private let searchCountLabel = NSTextField(labelWithString: "")

    private var matches: [PDFSelection] = []
    private var matchIndex = 0
    private var searchNavControl: NSSegmentedControl?
    private var findInProgress = false
    private var lastQuery = ""
    /// Set while a cancelled PDFKit search is still winding down: its late
    /// callbacks are ignored, and `pendingQuery` starts when its end arrives.
    private var awaitingCancelledFindEnd = false
    private var pendingQuery: String?
    /// Read once, at init: PDFView posts page-change notifications while it
    /// lays out, and those would otherwise overwrite the stored position with
    /// page 1 before we ever get a chance to restore it.
    private let savedPosition: Prefs.Position?
    private var restoreStarted = false
    private var restoreFinished = false
    /// Set while re-running a find after the document was swapped underneath us:
    /// the first match must not steal the reading position we just restored.
    private var suppressFirstMatchScroll = false
    /// The page indicator's fixed width, which has to grow or shrink when a
    /// Markdown re-render changes the page count.
    private var pageIndicatorWidth: NSLayoutConstraint?
    /// Where the last install aimed. A burst of saves can land a second render
    /// while the first install's two-pass jump is still in flight, and the live
    /// destination is meaningless at that moment; this is what to aim at instead.
    private var lastInstallTarget: Prefs.Position?
    /// The clip view the progress readout watches. PDFKit builds a fresh
    /// document view for every document, so this is re-resolved after each
    /// install rather than looked up once.
    private weak var progressClipView: NSClipView?
    private var progressRefreshPending = false

    private var pdfView: ReaderPDFView { readerVC.pdfView }
    private var pageCount: Int { glassineDocument.pdf?.pageCount ?? 0 }

    // MARK: Init

    /// The tab group every reader window belongs to, and how the app tells a
    /// reader window apart from the Recents window in `NSApp.windows`.
    static let tabbingIdentifier = NSWindow.TabbingIdentifier("GlassineReader")

    /// Is a document on screen? A minimised window counts; a closed one, which
    /// AppKit keeps around because reader windows are not released on close,
    /// does not.
    static var anyWindowIsOpen: Bool {
        NSApp.windows.contains {
            $0.tabbingIdentifier == tabbingIdentifier && ($0.isVisible || $0.isMiniaturized)
        }
    }

    init(document: GlassineDocument) {
        glassineDocument = document
        savedPosition = document.fileURL.flatMap { Prefs.lastPosition(for: $0) }
        let reader = ReaderViewController(document: document)
        readerVC = reader
        sidebarVC = SidebarViewController(pdfView: reader.pdfView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 1040),
            // Deliberately no .fullSizeContentView: macOS 26's glass toolbar
            // tints itself from the content beneath it, and it samples the PDF
            // view *before* the inversion filter, which made the whole title
            // and tab bar read light in dark mode.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.contentMinSize = Self.minimumContentSize

        super.init(window: window)

        window.delegate = self
        shouldCascadeWindows = false

        document.findSink = self
        reader.onInversionChanged = { [weak self] inverted in
            self?.applyInversion(inverted)
        }

        buildContent()
        // Installing the content view controller resizes the window to the
        // split view's fitting size (320pt wide, no height), so the frame is
        // chosen only after it: the autosaved one if there is one, else the
        // default clamped to the screen.
        sizeWindowInitially(window)
        buildToolbar()
        configurePageControls()
        applyWindowAppearance()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(prefsChanged),
            name: .glassinePrefsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        // Zooming changes how much of a continuous document fits on screen, and
        // with it the fraction the reader has behind them.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollGeometryChanged),
            name: .PDFViewScaleChanged,
            object: pdfView
        )
        // Markdown documents get their PDF asynchronously, and again on every
        // reload; this is the one place a new document is installed.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(documentDidReplacePDF(_:)),
            name: .glassineDocumentDidReplacePDF,
            object: document
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Keep the sidebar and the find highlights in step with the page inversion.
    private func applyInversion(_ inverted: Bool) {
        sidebarVC.setContentFilters(inverted ? ReaderViewController.makeDarkFilters() : [])
        applyHighlights()
        applyWindowAppearance()
    }

    @objc private func prefsChanged() {
        applyWindowAppearance()
    }

    private func applyWindowAppearance() {
        guard let window else { return }
        WindowChrome.apply(to: window, content: contentViewController?.view)
    }

    /// Dark mode recolours the matched glyphs green in ReaderPage; light mode
    /// uses PDFKit's own translucent highlight.
    private func applyHighlights() {
        let inverted = readerVC.isInverted
        pdfView.isInverted = inverted
        if inverted {
            // The reverse-video boxes are the highlight; suppress PDFKit's own
            // translucent selection wash so it does not double up on them.
            for selection in matches { selection.color = .clear }
            pdfView.highlightedSelections = nil
            pdfView.setFindMatches(matches, current: matchIndex)
        } else {
            pdfView.setFindMatches([], current: 0)
            for selection in matches {
                selection.color = NSColor.systemGreen.withAlphaComponent(0.35)
            }
            pdfView.highlightedSelections = matches.isEmpty ? nil : matches
        }
    }

    private static let defaultContentSize = NSSize(width: 960, height: 1040)
    private static let minimumContentSize = NSSize(width: 480, height: 360)

    /// The autosave string is "x y w h sx sy sw sh" in points.
    private static func hasUsableSavedFrame(named name: String) -> Bool {
        guard let raw = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") else {
            return false
        }
        let parts = raw.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 4 else { return false }
        return parts[2] >= minimumContentSize.width && parts[3] >= minimumContentSize.height
    }

    /// First-launch screen: the widest landscape display (Dan reads on the
    /// landscape Studio Display, not the portrait one), else whatever there is.
    private static var preferredScreen: NSScreen? {
        let landscape = NSScreen.screens.filter { $0.frame.width > $0.frame.height }
        return landscape.max { $0.frame.width < $1.frame.width } ?? NSScreen.main
    }

    /// The default frame: defaultContentSize clamped to fit, centred on the
    /// preferred screen.
    private static func defaultFrame(for window: NSWindow) -> NSRect {
        var size = defaultContentSize
        let chrome = window.frame.height - window.contentLayoutRect.height
        guard let screen = preferredScreen else {
            return NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height + chrome))
        }
        let visible = screen.visibleFrame
        size.width = min(size.width, visible.width)
        size.height = min(size.height, visible.height - chrome)
        let frameSize = NSSize(width: size.width, height: size.height + chrome)
        return NSRect(
            x: visible.midX - frameSize.width / 2,
            y: visible.midY - frameSize.height / 2,
            width: frameSize.width,
            height: frameSize.height
        )
    }

    private func sizeWindowInitially(_ window: NSWindow) {
        if !Self.hasUsableSavedFrame(named: "ReaderWindow") {
            // A build that predates this sizing logic autosaved the collapsed
            // 320x32 frame, and setFrameAutosaveName below would restore it
            // (clamped up to contentMinSize), so drop it first.
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame ReaderWindow")
            window.setFrame(Self.defaultFrame(for: window), display: false)
        }
        // Restores the saved frame when there is one, and saves from here on.
        window.setFrameAutosaveName("ReaderWindow")
    }

    private func buildContent() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = true
        sidebarItem.allowsFullHeightLayout = true

        let contentItem = NSSplitViewItem(viewController: readerVC)
        contentItem.minimumThickness = 320

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(contentItem)
        self.sidebarItem = sidebarItem

        // Installing this shrinks the window to the split view's fitting
        // size (320pt wide, no height); sizeWindowInitially runs afterwards.
        // Deliberately no preferredContentSize: the window keeps snapping
        // back to it, which broke user resizing and window tiling.
        contentViewController = splitVC
    }

    private func buildToolbar() {
        // Toolbars sharing an identifier are kept in sync by AppKit, so
        // removing the page indicator for one continuous Markdown window would
        // strip it from every other window (and every window opened after).
        let toolbar = NSToolbar(identifier: "GlassineReaderToolbar.\(UUID().uuidString)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    // MARK: Page indicator

    private var indicatorFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    private func configurePageControls() {
        let font = indicatorFont

        // Idle state: one label holding the whole "13 of 30" string, so it is
        // centred in the capsule by construction whatever the digit count.
        pageLabel.alignment = .center
        pageLabel.font = font
        pageLabel.toolTip = indicatorToolTip
        pageLabel.translatesAutoresizingMaskIntoConstraints = false

        // Editing state: an unbezelled field in the same place. The toolbar
        // item's capsule is the only chrome; the accent tint is the caret hint.
        pageField.isEditable = true
        pageField.isSelectable = true
        pageField.isBezeled = false
        pageField.isBordered = false
        pageField.drawsBackground = false
        pageField.focusRingType = .none
        pageField.alignment = .center
        pageField.font = font
        pageField.textColor = .labelColor
        pageField.delegate = self
        pageField.target = self
        pageField.action = #selector(commitPageField)
        pageField.wantsLayer = true
        pageField.layer?.cornerRadius = 4
        pageField.layer?.masksToBounds = true
        pageField.isHidden = true
        // Editing is only ever entered deliberately (a click or ⌥⌘G); this
        // keeps the key-view loop from handing it focus on its own.
        pageField.refusesFirstResponder = true
        pageField.translatesAutoresizingMaskIntoConstraints = false

        updatePageField()
    }

    private func makePageIndicatorItem() -> NSToolbarItem {
        let container = PageIndicatorContainer()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pageLabel)
        container.addSubview(pageField)
        pageIndicator = container

        // Fixed width, sized for the widest string this document can show, so
        // the capsule never resizes while paging; the label centres inside it.
        let width = container.widthAnchor.constraint(equalToConstant: currentIndicatorWidth)
        pageIndicatorWidth = width

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 22),
            width,

            pageLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            pageLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            pageField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            pageField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            pageField.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(beginPageEdit))
        container.addGestureRecognizer(click)

        let item = NSToolbarItem(itemIdentifier: .pageIndicator)
        item.label = "Page"
        item.paletteLabel = "Page"
        item.toolTip = indicatorToolTip
        item.view = container
        item.isBordered = true
        item.visibilityPriority = .high
        pageIndicatorItem = item
        return item
    }

    /// True while the reader is showing a continuous Markdown render: one very
    /// tall page, where "1 of 1" says nothing and a percentage says everything.
    private var showsProgress: Bool { glassineDocument.isContinuousMarkdown }

    private func indicatorWidth(for pageCount: Int) -> CGFloat {
        let widest = "\(max(pageCount, 1)) of \(max(pageCount, 1))"
            .size(withAttributes: [.font: indicatorFont]).width
        return ceil(widest) + 20
    }

    /// Sized for "100%", so the capsule does not jitter as the reader scrolls.
    private var progressIndicatorWidth: CGFloat {
        ceil("100%".size(withAttributes: [.font: indicatorFont]).width) + 20
    }

    private var currentIndicatorWidth: CGFloat {
        showsProgress ? progressIndicatorWidth : indicatorWidth(for: pageCount)
    }

    private var indicatorToolTip: String {
        showsProgress ? "Go to position (\u{2325}\u{2318}G)" : "Go to page (\u{2325}\u{2318}G)"
    }

    /// Width and tooltip both depend on which readout the capsule is showing,
    /// so they are re-applied together whenever the layout can have changed.
    private func updateIndicatorMode() {
        pageIndicatorWidth?.constant = currentIndicatorWidth
        pageLabel.toolTip = indicatorToolTip
        pageIndicatorItem?.toolTip = indicatorToolTip
    }

    private var currentPageNumber: Int? {
        guard let pdf = pdfView.document, let page = pdfView.currentPage else { return nil }
        let index = pdf.index(for: page)
        return index == NSNotFound ? nil : index + 1
    }

    private func updatePageField() {
        if showsProgress {
            updateProgressLabel()
            return
        }
        guard let number = currentPageNumber, pageCount > 0 else {
            pageLabel.stringValue = ""
            return
        }
        indicate(value: "\(number)", trailing: " of \(pageCount)")
        if pageField.isHidden { pageField.stringValue = "\(number)" }
    }

    private func updateProgressLabel() {
        let percent = currentProgressPercent
        indicate(value: "\(percent)", trailing: "%")
        if pageField.isHidden { pageField.stringValue = "\(percent)" }
    }

    /// The readout is one attributed string so the capsule centres it whatever
    /// its width: the number in label colour, the rest a shade back.
    private func indicate(value: String, trailing: String) {
        let font = indicatorFont
        let text = NSMutableAttributedString(
            string: value,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(
            string: trailing,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        pageLabel.attributedStringValue = text
    }

    // MARK: Reading progress (continuous Markdown)

    /// The scroll geometry behind the progress readout: the clip view that
    /// frames the visible area, and the document view it slides over.
    private var scrollGeometry: (clip: NSClipView, documentView: NSView)? {
        guard let documentView = pdfView.documentView,
              let clip = documentView.enclosingScrollView?.contentView
        else { return nil }
        return (clip, documentView)
    }

    /// How far through the scrollable range the top of the visible area sits:
    /// 0 at the top of the document, 1 once its bottom edge is at the bottom of
    /// the view. A page shorter than the view is entirely on screen, so it is
    /// read: 100%.
    private var readingProgress: CGFloat {
        guard let (clip, documentView) = scrollGeometry else { return 0 }
        let span = documentView.bounds.height - clip.bounds.height
        guard span > 0.5 else { return 1 }
        // PDFKit's document view is flipped, but the geometry is cheap to state
        // for both so a future PDFKit cannot invert the readout silently.
        let travelled = documentView.isFlipped
            ? clip.bounds.minY - documentView.bounds.minY
            : documentView.bounds.maxY - clip.bounds.maxY
        return min(max(travelled / span, 0), 1)
    }

    private var currentProgressPercent: Int {
        Int((readingProgress * 100).rounded())
    }

    /// Put the top of the visible area at `fraction` of the scrollable range.
    private func scrollToProgress(_ fraction: CGFloat) {
        guard let (clip, documentView) = scrollGeometry else { return }
        let span = documentView.bounds.height - clip.bounds.height
        guard span > 0.5 else { return }
        let travelled = span * min(max(fraction, 0), 1)
        var origin = clip.bounds.origin
        origin.y = documentView.isFlipped
            ? documentView.bounds.minY + travelled
            : documentView.bounds.maxY - clip.bounds.height - travelled
        clip.scroll(to: origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        updatePageField()
    }

    /// A continuous document scrolls without ever changing page, so
    /// .PDFViewPageChanged never fires and the clip view's own bounds
    /// notification is the only thing that reports movement. Re-resolved after
    /// every install: PDFKit builds a new document view for each document.
    private func observeScrollGeometry() {
        let clip = pdfView.documentView?.enclosingScrollView?.contentView
        guard clip !== progressClipView else { return }
        if let previous = progressClipView {
            NotificationCenter.default.removeObserver(
                self, name: NSView.boundsDidChangeNotification, object: previous)
        }
        progressClipView = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollGeometryChanged),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
    }

    /// Coalesced: a scroll posts this every frame, and relaying the label out
    /// each time is wasted work when the percentage barely moves.
    @objc private func scrollGeometryChanged() {
        guard showsProgress, !progressRefreshPending else { return }
        progressRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.progressRefreshPending = false
            if self.showsProgress { self.updateProgressLabel() }
        }
    }

    /// Swap the label for the editable field, with the number preselected.
    @objc func beginPageEdit() {
        guard pageCount > 0, pageField.isHidden else { return }
        if showsProgress {
            pageField.stringValue = "\(currentProgressPercent)"
            pageField.placeholderString = "0\u{2013}100"
        } else {
            pageField.stringValue = currentPageNumber.map(String.init) ?? ""
            // Emptying the field should still say what a legal answer looks like.
            pageField.placeholderString = "1\u{2013}\(pageCount)"
        }
        pageLabel.isHidden = true
        pageField.isHidden = false
        pageField.refusesFirstResponder = false
        pageIndicator?.isEditing = true
        window?.makeFirstResponder(pageField)
        pageField.currentEditor()?.selectAll(nil)
    }

    /// Back to the idle label. Never navigates on its own.
    private func endPageEdit() {
        guard !pageField.isHidden else { return }
        pageField.isHidden = true
        pageField.drawsBackground = false
        pageField.refusesFirstResponder = true
        pageIndicator?.isEditing = false
        pageLabel.isHidden = false
        updatePageField()
    }

    @objc private func commitPageField() {
        defer {
            endPageEdit()
            window?.makeFirstResponder(pdfView)
        }
        guard let pdf = pdfView.document, pdf.pageCount > 0,
              let requested = Int(pageField.stringValue.trimmingCharacters(in: .whitespaces))
        else { return }
        if showsProgress {
            scrollToProgress(CGFloat(min(max(requested, 0), 100)) / 100)
            return
        }
        let target = min(max(requested, 1), pdf.pageCount) - 1
        let current = pdfView.currentPage.map { pdf.index(for: $0) } ?? NSNotFound
        if target != current, let page = pdf.page(at: target) {
            pdfView.go(to: page)
        }
    }

    @objc private func pageChanged() {
        updatePageField()
        savePosition()
        sidebarVC.syncSelection()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === pageField else { return }
        pageField.drawsBackground = true
        pageField.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
        pageIndicator?.applyEditingBorder()
        pageField.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === pageField else { return }
        endPageEdit()
    }

    // The search field's action is what normally restarts the find, but a
    // cancel-button click that AppKit swallows into a search interaction can
    // empty the field without sending it. Any route to an empty field resets.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField,
              field.stringValue.isEmpty, !lastQuery.isEmpty else { return }
        startFind("")
    }

    // MARK: Toolbar delegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .pageIndicator,
         .flexibleSpace, .search, .searchCount, .searchNav]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .pageIndicator:
            return makePageIndicatorItem()
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: .search)
            item.preferredWidthForSearchField = 180
            item.resignsFirstResponderWithCancel = true
            let field = item.searchField
            field.delegate = self
            field.sendsWholeSearchString = false
            field.sendsSearchStringImmediately = false
            field.target = self
            field.action = #selector(searchChanged(_:))
            searchItem = item
            return item
        case .searchCount:
            return makeSearchCountItem()
        case .searchNav:
            return makeSearchNavItem()
        default:
            return nil
        }
    }

    // MARK: Find

    private var searchField: NSSearchField? { searchItem?.searchField }

    private func makeSearchCountItem() -> NSToolbarItem {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                    weight: .regular)
        searchCountLabel.font = font
        searchCountLabel.textColor = .secondaryLabelColor
        searchCountLabel.alignment = .center
        searchCountLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchCountLabel)
        // Fixed width, sized for the widest readout: a capsule that grows and
        // shrinks shifts the search field sideways, and the cancel button
        // moves out from under a pointer that was aiming at it.
        let widest = ["No matches", "9999 of 9999", "9999 found…"]
            .map { $0.size(withAttributes: [.font: font]).width }
            .max() ?? 56

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 22),
            container.widthAnchor.constraint(equalToConstant: ceil(widest) + 20),
            searchCountLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            searchCountLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        let item = NSToolbarItem(itemIdentifier: .searchCount)
        item.label = "Matches"
        item.paletteLabel = "Matches"
        item.view = container
        // Must outrank the search field so it is never pushed into the
        // toolbar's overflow menu.
        item.visibilityPriority = .high
        return item
    }

    /// Previous / next match, mirroring ⇧⌘G / ⌘G. Greyed out until a search
    /// has produced matches.
    private func makeSearchNavItem() -> NSToolbarItem {
        let control = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous match")!,
                NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next match")!
            ],
            trackingMode: .momentary,
            target: self,
            action: #selector(searchNavClicked(_:))
        )
        control.segmentStyle = .separated
        control.setToolTip("Previous match (\u{21E7}\u{2318}G)", forSegment: 0)
        control.setToolTip("Next match (\u{2318}G)", forSegment: 1)
        control.isEnabled = false
        searchNavControl = control

        let item = NSToolbarItem(itemIdentifier: .searchNav)
        item.label = "Previous/Next"
        item.paletteLabel = "Previous/Next Match"
        item.view = control
        item.visibilityPriority = .high
        return item
    }

    @objc private func searchNavClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? findPrevious(sender) : findNext(sender)
    }

    private func startFind(_ query: String, suppressFirstScroll: Bool = false) {
        suppressFirstMatchScroll = suppressFirstScroll
        matches.removeAll()
        matchIndex = 0
        searchNavControl?.isEnabled = false
        pdfView.highlightedSelections = nil
        pdfView.setFindMatches([], current: 0)
        // In light mode the current match is PDFKit's own selection, and nothing
        // else ever drops it: without this the last match stays washed on the
        // page after the query stops matching, and survives cancelling the
        // search entirely.
        pdfView.setCurrentSelection(nil, animate: false)

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = trimmed
        findInProgress = !trimmed.isEmpty
        searchCountLabel.stringValue = ""

        // PDFKit delivers find callbacks asynchronously and does not tag them
        // with the query, so a search cancelled mid-flight can still report
        // matches (and its end) after a replacement has begun. Hold the new
        // query until the old search's end callback arrives, discarding
        // anything else from it in the meantime. The timer is a safety net in
        // case PDFKit never reports the end of a cancelled search.
        if let pdf = glassineDocument.pdf, pdf.isFinding {
            pdf.cancelFindString()
            pendingQuery = trimmed
            awaitingCancelledFindEnd = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.awaitingCancelledFindEnd else { return }
                self.awaitingCancelledFindEnd = false
                self.startPendingFind()
            }
            return
        }
        beginFind(trimmed)
    }

    private func beginFind(_ trimmed: String) {
        findInProgress = !trimmed.isEmpty
        guard !trimmed.isEmpty, let pdf = glassineDocument.pdf else { return }
        pdf.beginFindString(trimmed, withOptions: [.caseInsensitive])
    }

    private func startPendingFind() {
        guard let query = pendingQuery else { return }
        pendingQuery = nil
        beginFind(query)
    }

    func findDidMatch(_ selection: PDFSelection) {
        guard !awaitingCancelledFindEnd else { return }
        matches.append(selection)
        // Show the first hit immediately; the rest arrive asynchronously.
        // Reassigning the highlight array per match is quadratic on large
        // documents, so later hits are batched onto a short timer instead:
        // they appear within ~150ms of being found rather than only when the
        // whole search ends.
        if matches.count == 1 {
            if suppressFirstMatchScroll {
                // Re-running the query after a reload: light the matches up but
                // stay where the reader was.
                suppressFirstMatchScroll = false
            } else {
                showMatch(0)
            }
            applyHighlights()
            // Stepping is useful as soon as there is something to step through;
            // it wraps over the results found so far.
            searchNavControl?.isEnabled = true
        } else {
            scheduleHighlightRefresh()
        }
        searchCountLabel.stringValue = "\(matches.count) found…"
    }

    func findDidEnd() {
        if awaitingCancelledFindEnd {
            awaitingCancelledFindEnd = false
            startPendingFind()
            return
        }
        findInProgress = false
        applyHighlights()
        updateSearchCount()
    }

    private var highlightRefreshPending = false

    private func scheduleHighlightRefresh() {
        guard !highlightRefreshPending else { return }
        highlightRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.highlightRefreshPending = false
            // findDidEnd has already applied the final set if the search is over.
            if self.findInProgress { self.applyHighlights() }
        }
    }

    /// "K of N" once a search has finished, "No matches" when it found nothing,
    /// blank when there is no query. Left alone while a search is still running
    /// -- findDidMatch shows the running total there.
    private func updateSearchCount() {
        searchNavControl?.isEnabled = !matches.isEmpty
        guard !lastQuery.isEmpty else {
            searchCountLabel.stringValue = ""
            return
        }
        if findInProgress {
            searchCountLabel.stringValue = "\(matches.count) found…"
        } else if matches.isEmpty {
            searchCountLabel.stringValue = "No matches"
        } else {
            searchCountLabel.stringValue = "\(matchIndex + 1) of \(matches.count)"
        }
    }

    private func showMatch(_ index: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        matchIndex = ((index % count) + count) % count
        let selection = matches[matchIndex]
        if readerVC.isInverted {
            // PDFKit would paint its own selection wash over our reverse-video
            // box, and inverted it comes out olive. Scroll to the match, then
            // drop the selection and let the drawn box mark it.
            pdfView.go(to: selection)
            pdfView.setCurrentSelection(nil, animate: false)
            pdfView.setCurrentMatchIndex(matchIndex)
        } else {
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.go(to: selection)
        }
        if !findInProgress { updateSearchCount() }
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        startFind(sender.stringValue)
    }

    @objc func findNext(_ sender: Any?) {
        step(by: 1)
    }

    @objc func findPrevious(_ sender: Any?) {
        step(by: -1)
    }

    private func step(by delta: Int) {
        guard matches.isEmpty else {
            showMatch(matchIndex + delta)
            return
        }
        let query = (searchField?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !findInProgress, !query.isEmpty, query == lastQuery {
            // Already searched for exactly this and came up empty.
            NSSound.beep()
        } else {
            startFind(query)
        }
    }

    @objc func focusSearch(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        guard let text = pdfView.currentSelection?.string, !text.isEmpty else { return }
        searchField?.stringValue = text
        startFind(text)
    }

    @objc func focusPageField(_ sender: Any?) {
        beginPageEdit()
    }

    // MARK: Field editing

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if control is NSSearchField {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if matches.isEmpty {
                    startFind(control.stringValue)
                } else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    findPrevious(nil)
                } else {
                    findNext(nil)
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                control.stringValue = ""
                startFind("")
                searchItem?.endSearchInteraction()
                window?.makeFirstResponder(pdfView)
                return true
            default:
                return false
            }
        }

        if control === pageField {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                commitPageField()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                endPageEdit()
                window?.makeFirstResponder(pdfView)
                return true
            default:
                return false
            }
        }

        return false
    }

    // MARK: Window / tabs

    override func showWindow(_ sender: Any?) {
        if let window, !window.isVisible {
            // Front-to-back: adopt the frontmost existing reader window as tab host.
            let host = NSApp.orderedWindows.first {
                $0 !== window && $0.isVisible && !$0.isMiniaturized
                    && $0.tabbingIdentifier == window.tabbingIdentifier
            }
            host?.addTabbedWindow(window, ordered: .above)
            // Joining a tab group re-lays the split view out and loses the
            // collapsed state set at init, so assert it again here.
            sidebarItem?.isCollapsed = true
        }

        super.showWindow(sender)
        // Not left to the app delegate's didBecomeKey observer: a document
        // opened while Glassine is in the background never becomes key, and the
        // Recents window would sit there behind it until it did.
        RecentsWindowController.shared.hide()
        // The backdrop blur is keyed to the window number, so re-assert it once
        // the window is actually on screen (and in its tab group).
        applyWindowAppearance()
        window?.makeFirstResponder(pdfView)
        // A plain PDF is never installed through documentDidReplacePDF, so this
        // is the one chance to read its outline; a Markdown document has no PDF
        // yet and picks its mode up when the first render lands.
        if pdfView.document != nil { sidebarVC.documentDidChange() }
        observeScrollGeometry()
        restorePositionIfNeeded()
    }

    // MARK: Sidebar mode

    @objc func showThumbnails(_ sender: Any?) { setSidebarMode(.thumbnails) }

    @objc func showOutline(_ sender: Any?) { setSidebarMode(.outline) }

    private func setSidebarMode(_ mode: SidebarMode) {
        Prefs.sidebarMode = mode
        sidebarVC.mode = mode
        if sidebarItem?.isCollapsed == true {
            sidebarItem?.animator().isCollapsed = false
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showThumbnails(_:)):
            menuItem.state = sidebarVC.mode == .thumbnails ? .on : .off
        case #selector(showOutline(_:)):
            menuItem.state = sidebarVC.mode == .outline ? .on : .off
            return sidebarVC.hasOutline
        case #selector(focusPageField(_:)):
            // In a continuous document this edits the progress percentage
            // instead, so the only thing that disables it is having no document.
            return pageCount > 0
        default:
            break
        }
        return true
    }

    /// A new tab is a start tab -- the recents picker, in the tab, rather than
    /// an Open panel in front of the window. Implementing this is also what
    /// makes AppKit show the "+" button in the tab bar.
    override func newWindowForTab(_ sender: Any?) {
        StartTabWindowController.present(besides: window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !didSettleSidebar else { return }
        didSettleSidebar = true
        sidebarItem?.isCollapsed = true
    }

    func windowWillClose(_ notification: Notification) {
        if let pdf = glassineDocument.pdf, pdf.isFinding { pdf.cancelFindString() }
        savePosition()
    }

    // MARK: Reading position

    private func savePosition() {
        // Nothing is worth saving until the restore has run: the layout-time
        // page changes all report page 1.
        guard restoreFinished else { return }
        guard let url = glassineDocument.fileURL,
              let pdf = pdfView.document,
              let destination = pdfView.currentDestination,
              let page = destination.page
        else { return }
        let index = pdf.index(for: page)
        guard index != NSNotFound else { return }
        Prefs.setLastPosition(
            Prefs.Position(pageIndex: index,
                           x: destination.point.x,
                           y: destination.point.y),
            for: url
        )
    }

    private func restorePositionIfNeeded() {
        guard !restoreStarted else { return }
        // A Markdown document has no PDF yet when its window is shown. Leave
        // restoreStarted false: the first render posts
        // .glassineDocumentDidReplacePDF and installDocument does the restore.
        guard pdfView.document != nil else { return }
        restoreStarted = true

        guard let saved = savedPosition,
              let pdf = pdfView.document,
              saved.pageIndex > 0 || saved.x != 0 || saved.y != 0,
              saved.pageIndex < pdf.pageCount,
              let page = pdf.page(at: saved.pageIndex)
        else {
            restoreFinished = true
            updatePageField()
            return
        }

        let destination = PDFDestination(page: page, at: NSPoint(x: saved.x, y: saved.y))
        jump(to: destination, expectingPageIndex: saved.pageIndex) { [weak self] in
            guard let self else { return }
            self.restoreFinished = true
            self.updatePageField()
        }
    }

    /// PDFView silently ignores go(to:) before it has laid the document out, so
    /// force layout and jump on the next runloop pass; then confirm we actually
    /// landed on the expected page and retry once if not.
    private func jump(to destination: PDFDestination,
                      expectingPageIndex index: Int,
                      completion: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pdfView.layoutDocumentView()
            self.pdfView.go(to: destination)

            DispatchQueue.main.async {
                let landed = self.pdfView.currentPage
                    .map { self.pdfView.document?.index(for: $0) ?? NSNotFound } ?? NSNotFound
                if landed != index { self.pdfView.go(to: destination) }
                completion()
            }
        }
    }

    // MARK: Document replacement (Markdown render / reload)

    @objc private func documentDidReplacePDF(_ note: Notification) {
        guard let replacement = glassineDocument.pdf else { return }
        let initial = (note.userInfo?["initial"] as? Bool) ?? false
        if let stats = glassineDocument.markdownStats {
            window?.subtitle = "\(stats.words.formatted(.number)) words"
        }
        // On a reload, hold the place the reader is actually looking at; on the
        // first render there is nothing on screen yet, so use the saved one.
        var target = initial ? savedPosition : lastInstallTarget
        // restoreFinished is false only while an install's jump is still in
        // flight, and the view is then somewhere arbitrary; trust the live
        // destination in every other case.
        if !initial, restoreFinished,
           let old = pdfView.document,
           let destination = pdfView.currentDestination,
           let page = destination.page {
            let index = old.index(for: page)
            if index != NSNotFound {
                target = Prefs.Position(pageIndex: index,
                                        x: destination.point.x,
                                        y: destination.point.y)
            }
        }
        installDocument(replacement, target: target)
    }

    /// Swap in a freshly rendered PDF, keeping the reading position, the page
    /// indicator, and any active search.
    private func installDocument(_ replacement: PDFDocument, target: Prefs.Position?) {
        // Assigning a document makes PDFView lay out and report page 1; without
        // this those reports would overwrite the position we are restoring.
        restoreFinished = false

        // Every PDFSelection we hold points into the document about to go away.
        if let old = glassineDocument.pdf, old !== replacement, old.isFinding {
            old.cancelFindString()
        }
        matches.removeAll()
        matchIndex = 0
        findInProgress = false
        awaitingCancelledFindEnd = false
        pendingQuery = nil
        pdfView.setFindMatches([], current: 0)
        pdfView.highlightedSelections = nil
        pdfView.setCurrentSelection(nil, animate: false)
        searchNavControl?.isEnabled = false
        searchCountLabel.stringValue = ""

        pdfView.document = replacement
        sidebarVC.documentDidChange()
        observeScrollGeometry()
        updateIndicatorMode()
        updatePageField()

        let clamped = target.map {
            Prefs.Position(pageIndex: min(max($0.pageIndex, 0), max(replacement.pageCount - 1, 0)),
                           x: $0.x, y: $0.y)
        }
        lastInstallTarget = clamped
        guard let clamped, let page = replacement.page(at: clamped.pageIndex) else {
            finishInstall()
            return
        }
        let destination = PDFDestination(page: page, at: NSPoint(x: clamped.x, y: clamped.y))
        jump(to: destination, expectingPageIndex: clamped.pageIndex) { [weak self] in
            self?.finishInstall()
        }
    }

    private func finishInstall() {
        restoreStarted = true
        restoreFinished = true
        // The document view only exists once PDFView has laid the new document
        // out, which the install's jump has just forced.
        observeScrollGeometry()
        updatePageField()
        // Swapping the document can leave the window itself as first responder,
        // and the next activation then hands focus to the first key view it
        // finds -- which is in the toolbar, not the page.
        if let window, window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(pdfView)
        }
        // Re-run the search against the new document, without letting match 1
        // pull the view away from where the reader was.
        if !lastQuery.isEmpty { startFind(lastQuery, suppressFirstScroll: true) }
    }
}
