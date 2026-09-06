import Foundation
import GlassineCore
import PDFKit
import UIKit

/// PDFKit's document delegate: what class its pages are, and where its find
/// callbacks go. On the Mac this is `GlassineDocument` itself; iOS has no
/// NSDocument, so it is its own small object.
///
/// `@unchecked Sendable` because PDFKit calls `didMatchString` from its own find
/// thread. The one mutable field is written once, on the main thread, before any
/// find can start, and every call hops to the main actor before touching it --
/// the same treatment the Mac gives these two callbacks.
final class PDFDocumentBridge: NSObject, PDFDocumentDelegate, @unchecked Sendable {

    nonisolated(unsafe) weak var findSink: (any FindSink)?

    func classForPage() -> AnyClass { ReaderPage.self }

    func didMatchString(_ instance: PDFSelection) {
        // A PDFSelection is not Sendable and this may be PDFKit's find thread,
        // so it crosses in a box and is only ever read again on the main actor.
        let selection = UncheckedBox(instance)
        forward { sink in sink.findDidMatch(selection.value) }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        // Pass the document on where PDFKit named it: a document that has since
        // been replaced can still report the end of the search it was cancelled
        // out of, and only `findDidEnd(in:)` can tell those apart.
        let document = UncheckedBox(notification.object as? PDFDocument)
        forward { sink in
            if let document = document.value {
                sink.findDidEnd(in: document)
            } else {
                sink.findDidEnd()
            }
        }
    }

    private func forward(_ body: @escaping @MainActor (any FindSink) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if let findSink { body(findSink) }
            }
        } else {
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    if let findSink { body(findSink) }
                }
            }
        }
    }

    private struct UncheckedBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}

/// One open document, for one scene: the URL and its security scope, the
/// `PDFDocument`, the find state machine, the reading position, and the readouts
/// the chrome shows. The iOS analogue of `GlassineDocument` +
/// `ReaderWindowController`'s model half.
///
/// Two kinds of file end up in the same `PDFDocument` slot, exactly as on the
/// Mac. A `.pdf` is opened directly. A `.md` file is decoded and converted here
/// and typeset into real pages by `MarkdownRendererIOS`, so everything
/// downstream -- the inversion, find, the outline, position memory, printing --
/// works without knowing the difference. Typesetting is asynchronous, so the
/// first Markdown render is just "reload #0": the reader appears with an empty
/// (already inverted, so never white) PDFView and fills a fraction of a second
/// later through the same install path a file-change reload uses.
@MainActor
@Observable
final class DocumentSession {

    enum Kind: Sendable {
        case pdf
        case markdown
    }

    enum Phase: Equatable {
        case opening
        /// An iCloud file that is not on the device yet.
        case downloading
        case ready
        case failed(String)
    }

    let url: URL
    let kind: Kind
    let title: String

    private(set) var phase: Phase = .opening
    private(set) var document: PDFDocument?
    private(set) var pageCount = 0
    private(set) var currentPageIndex = 0

    /// "6,433 words" under the title, as in the Mac window's subtitle. Nil for
    /// a PDF.
    private(set) var subtitle: String?

    // MARK: Markdown

    /// True while what is on screen is a Markdown document laid out as one very
    /// tall page: the capsule then reads "53%", because "1 of 1" says nothing
    /// about a 65-page memo.
    private(set) var isContinuousMarkdown = false
    /// 0...100, recomputed on the same debounce the outline sync uses.
    private(set) var progressPercent = 0

    @ObservationIgnored private var content: MarkdownContent?
    @ObservationIgnored private var styling = MarkdownStyling.current
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var presenter: MarkdownFilePresenter?
    /// Reloads, in order: two saves in quick succession are two conversions
    /// racing on a concurrent queue, and without this the slower one could
    /// overwrite the newer revision.
    @ObservationIgnored private var reloader: MarkdownReloader?
    /// Bumped for every render; a completion whose generation is stale is
    /// dropped, which is also what keeps a superseded render from reporting an
    /// error.
    @ObservationIgnored private var renderGeneration = 0
    /// Where the reader is, as an outline entry, recorded just before a
    /// re-render and applied once the replacement is installed. A page index and
    /// a point mean nothing across a re-typesetting that moved every page break.
    @ObservationIgnored private var pendingAnchor: ReadingAnchor?
    /// Identifies this document to the renderer's job queue, so a second render
    /// of the same file supersedes one still waiting.
    @ObservationIgnored private let renderKey = UUID().uuidString
    /// Set when the render on screen came off a print renderer, which leaves a
    /// clipped ghost copy of every carried-over heading below the printable
    /// band: invisible on the page, but real to `findString`.
    @ObservationIgnored private var ghostBand: (pageHeight: CGFloat, margin: CGFloat)?
    @ObservationIgnored private var prefsObserver: NSObjectProtocol?
    #if DEBUG
    @ObservationIgnored private var didApplyDebugArguments = false
    #endif

    // MARK: Find

    let find = FindController()
    private(set) var findCountText = ""
    private(set) var findCanStep = false
    var findQuery = ""
    var isFindBarVisible = false

    // MARK: Go to page
    //
    // These two live on the session rather than in `ReaderView`'s `@State`
    // because the capsule that sets them is a **toolbar** item. SwiftUI hosts
    // toolbar content separately, and a `@State` flag written from there does
    // not reach the same view's `.alert` -- observed: the popover attached to
    // the capsule itself opened, and an alert attached to the body never
    // appeared in the element tree. A shared `@Observable` reference has no
    // such split.
    var isPageDialogVisible = false
    var pageEntry = ""

    // MARK: Outline

    private(set) var outlineEntries: [OutlineEntry] = []
    /// Row of `outlineEntries` the reader is inside, or -1 above the first one.
    private(set) var outlineSelection = -1

    // MARK: Plumbing

    @ObservationIgnored private let bridge = PDFDocumentBridge()
    @ObservationIgnored private(set) weak var pdfView: ReaderPDFView?
    /// Bumped whenever the reader's `PDFView` is (re)attached. A weak reference
    /// cannot be observed through the `@Observable` macro, and the thumbnail
    /// strip binds straight to that view, so this is what tells it to rebuild.
    private(set) var pdfViewToken = 0
    @ObservationIgnored private var position: ReadingPosition?
    @ObservationIgnored private var accessingScope = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var scrollObservation: NSKeyValueObservation?
    @ObservationIgnored private var outlineSyncPending = false
    /// Set by the reader on every appearance pass; picks which of the two
    /// highlight styles a match gets.
    @ObservationIgnored var isInverted = false

    init(url: URL) {
        self.url = url
        self.kind = DocumentTypes.kind(of: url)
        self.title = url.deletingPathExtension().lastPathComponent
        // Held for the life of the session, not just the read: PDFKit reads
        // pages lazily, so releasing the scope after the open would strand
        // every page that has not been rendered yet.
        accessingScope = url.startAccessingSecurityScopedResource()
        find.delegate = self
        // Not `find` directly: the session filters the print path's ghost text
        // out of the match stream before the state machine ever sees it.
        bridge.findSink = self
    }

    deinit {
        // Not `close()`: a deinit cannot hop to the main actor, and a Timer is
        // not Sendable so it cannot even be read here. The download timer stops
        // itself when its weak reference to the session has gone.
        if accessingScope { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: Opening

    func open() {
        guard phase == .opening else { return }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        if let status, status != .current {
            // An iCloud Drive file that is not on the device. Ask for it and
            // watch the same key until it lands; NSMetadataQuery would tell us
            // sooner but wants a scope and a predicate for one known file.
            phase = .downloading
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            schedulePoll()
            return
        }
        load()
    }

    /// A self-terminating poll rather than a `Timer`: the closure holds only a
    /// weak reference, so it stops the moment the scene lets the session go --
    /// a repeating Timer would have to be invalidated from `deinit`, which a
    /// main-actor class cannot do.
    private func schedulePoll() {
        let box = MainBox(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated { box.value?.pollDownload() }
        }
    }

    private func pollDownload() {
        guard phase == .downloading else { return }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        guard status == .current || status == nil else {
            schedulePoll()
            return
        }
        load()
    }

    private func load() {
        guard kind == .pdf else {
            loadMarkdown()
            return
        }
        var opened: PDFDocument?
        var coordinationError: NSError?
        // A coordinated read, so a Files-app or iCloud writer is not mid-save.
        // PDFKit then reads pages lazily off the same URL, which is why the
        // security scope above is held for the session rather than the block.
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { readURL in
            opened = PDFDocument(url: readURL)
        }
        guard let document = opened else {
            // Same wording as the Mac's read error.
            phase = .failed("\(url.lastPathComponent) could not be opened as a PDF.")
            return
        }
        // Before anything touches a page: PDFKit calls classForPage lazily, and
        // a page vended before the delegate is in place is a plain PDFPage
        // forever and can never draw a dark-mode find highlight.
        document.delegate = bridge
        self.document = document
        pageCount = document.pageCount
        find.document = document
        phase = .ready
        Prefs.noteRecentDocument(url, pageCount: document.pageCount)
        installInView()
    }

    #if DEBUG
    /// `-find <query>` and `-page <n>`, the siblings of `-open`. simctl cannot
    /// tap, and the dark-mode find ink has to be pixel-sampled off a real
    /// screenshot, so this is how those measurements are driven. Run from the
    /// restore's completion, not from `load`: before the first layout PDFKit
    /// silently ignores navigation, and the restore would overwrite it anyway.
    private func applyDebugLaunchArguments() {
        // Once per session: a Markdown document reaches here from the first
        // render's install *and* would again from every reload.
        guard !didApplyDebugArguments else { return }
        didApplyDebugArguments = true
        let arguments = UserDefaults.standard
        if let query = arguments.string(forKey: "find"), !query.isEmpty {
            isFindBarVisible = true
            startFind(query)
        }
        // `-export 1`: run Export as PDF and leave the result in Documents,
        // where a script on the Mac can check that a continuous document
        // exported as real pages with its bookmarks and no private links.
        if arguments.bool(forKey: "export") {
            exportPDF { [weak self] result in
                guard case .success(let file) = result,
                      let data = try? Data(contentsOf: file) else { return }
                _ = self
                let documents = FileManager.default.urls(for: .documentDirectory,
                                                         in: .userDomainMask)[0]
                try? data.write(to: documents.appendingPathComponent("last-export.pdf"))
            }
        }
        let page = arguments.integer(forKey: "page")
        guard page > 0 else { return }
        // Deferred, unlike the find: the restore's completion can run
        // *synchronously* when there is no saved position, which is inside
        // `makeUIView`, before the PDFView is in a window and has any bounds --
        // and PDFKit ignores navigation until it has laid the document out.
        let box = MainBox(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { box.value?.goToPage(number: page) }
        }
    }
    #endif

    /// Release the security scope and every observer. Called when the scene
    /// swaps documents or goes away.
    func close() {
        find.cancelIfFinding()
        savePosition()
        scrollObservation = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let prefsObserver {
            NotificationCenter.default.removeObserver(prefsObserver)
            self.prefsObserver = nil
        }
        watcher?.stop()
        watcher = nil
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self.presenter = nil
        }
        reloader?.invalidate()
        if kind == .markdown { MarkdownRendererIOS.shared.releaseIfIdle() }
        if accessingScope {
            url.stopAccessingSecurityScopedResource()
            accessingScope = false
        }
    }

    // MARK: Markdown

    /// Decode and convert only, so opening stays fast; `document` stays nil
    /// until the first render lands. The reader is shown straight away because
    /// its empty gutter is already the right colour -- there is no white flash
    /// to hide, which is what makes "reload #0" cheap.
    private func loadMarkdown() {
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        guard let data, let converted = try? MarkdownDocumentModel.content(of: data, url: url)
        else {
            phase = .failed("\(url.lastPathComponent) could not be read as Markdown.")
            return
        }
        content = converted
        subtitle = Self.subtitle(for: converted.stats)
        // No page count: a Markdown document has none until it has been typeset.
        Prefs.noteRecentDocument(url, pageCount: nil)
        phase = .ready
        startRender()
        startWatching()
        observePrefs()
    }

    private static func subtitle(for stats: MarkdownStats) -> String {
        "\(stats.words.formatted(.number)) words"
    }

    private func startRender() {
        guard kind == .markdown, let bodyHTML = content?.html else { return }
        renderGeneration += 1
        let generation = renderGeneration
        let html = MarkdownHTML.page(body: bodyHTML, title: title, styling: styling,
                                     platformCSS: ReaderTheme.markdownPlatformCSS)
        let layout = styling.layout
        let started = CFAbsoluteTimeGetCurrent()
        MarkdownRendererIOS.shared.render(html: html,
                                          baseURL: url,
                                          key: renderKey,
                                          layout: layout,
                                          headings: content?.headings ?? []) {
            [weak self] result in
            guard let self, generation == self.renderGeneration else { return }
            // "First" is a fact about the document, not about which event asked
            // for this render: a save or a style change that lands before the
            // opening render has finished supersedes it, and *that* render is
            // then the first successful install -- it has to restore the saved
            // position, and its failure is the one worth reporting.
            let initial = (self.document == nil)
            switch result {
            case .success(let rendered):
                // The one timing worth having, and the only place both ends of
                // it are known: HTML in, outlined PDFDocument out.
                NSLog("Glassine: %@ %@ render of %d pages in %.0f ms",
                      initial ? "first" : "reload", layout.title,
                      rendered.document.pageCount,
                      (CFAbsoluteTimeGetCurrent() - started) * 1000)
                self.installRender(rendered, layout: layout, initial: initial)
            case .failure(let error):
                // A reload that fails almost always means a half-written file;
                // keep showing the last good render and wait for the next save.
                guard initial else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Swap in a freshly typeset PDF, keeping the reading position (by heading),
    /// the outline, and any active search -- the iOS half of the Mac's
    /// `installDocument`.
    private func installRender(_ rendered: RenderedMarkdown,
                               layout: MarkdownLayout,
                               initial: Bool) {
        isContinuousMarkdown = (layout == .continuous)
        ghostBand = MarkdownRendererIOS.shared.lastOutputGhostBand
        let replacement = rendered.document
        // Before anything asks for a page: PDFKit calls classForPage lazily and
        // a page vended before the delegate is in place is a plain PDFPage
        // forever, which can never draw a dark-mode find highlight.
        replacement.delegate = bridge
        document = replacement
        pageCount = replacement.pageCount
        phase = .ready
        #if DEBUG
        // Re-serialised, not the raw print bytes: the outline has just been
        // applied to the in-memory document and only `dataRepresentation`
        // carries it.
        dumpRender(replacement)
        #endif

        // No view yet (the very first render can beat the representable): leave
        // it to `attach`, which installs through the ordinary path and restores
        // the saved position exactly as a PDF's open does.
        guard let pdfView else {
            find.document = replacement
            return
        }

        // Read from the *outgoing* document, so both of these come before the
        // swap.
        if position == nil {
            position = ReadingPosition(pdfView: pdfView, saved: Prefs.lastPosition(for: url),
                                       url: { [weak self] in self?.url })
        }
        guard let position else { return }
        let target = position.targetForInstall(initial: initial)
        // Assigning a document makes PDFView lay out and report page 1; without
        // this those reports would overwrite the position being restored.
        position.beginInstall()
        // Every PDFSelection we hold points into the document about to go away.
        find.reset(for: replacement)

        pdfView.document = replacement
        outlineEntries = OutlineSync.entries(of: replacement.outlineRoot, in: replacement)
        observeScrolling()
        currentPageIndex = 0
        updatePageReadout()

        let anchor = pendingAnchor
        pendingAnchor = nil
        position.aim(in: replacement, target: anchor?.position(in: replacement) ?? target) {
            [weak self] in
            self?.finishRenderInstall()
        }
        pdfView.becomeFirstResponder()
    }

    private func finishRenderInstall() {
        position?.finishInstall()
        #if DEBUG
        applyDebugLaunchArguments()
        #endif
        // The document view only exists once PDFView has laid the new document
        // out, which the install's jump has just forced.
        observeScrolling()
        updatePageReadout()
        updateProgress()
        syncOutlineSelection()
        // Re-run the search against the new document, without letting match 1
        // pull the view away from where the reader was.
        let query = find.lastQuery
        if !query.isEmpty { find.startFind(query, suppressFirstScroll: true) }
    }

    /// Note where the reader is, by heading, before a re-render throws the
    /// current pagination away.
    private func captureAnchor() {
        guard kind == .markdown, document != nil, let pdfView else { return }
        pendingAnchor = ReadingAnchor.capture(from: pdfView)
    }

    // MARK: Auto-refresh

    /// Two watchers, because neither one alone sees every writer. The vnode
    /// source catches an editor or a CLI writing the file directly; an
    /// `NSFilePresenter` catches iCloud and the Files app, which write through
    /// `NSFileCoordinator` and can leave the vnode untouched. Both poke the same
    /// debounce and the same `(inode, mtime, size)` gate, so two notifications
    /// for one save still cost one render.
    private func startWatching() {
        guard kind == .markdown, watcher == nil else { return }
        watcher = FileWatcher(url: url) { [weak self] in
            self?.reloadFromDisk()
        }
        let presenter = MarkdownFilePresenter(url: url) { [weak self] in
            // Straight into the watcher, so the coordinated and uncoordinated
            // paths share one debounce and one signature gate.
            self?.watcher?.poke()
        }
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
    }

    private func reloadFromDisk() {
        guard kind == .markdown else { return }
        if reloader == nil {
            let made = MarkdownReloader()
            made.onContent = { [weak self] fresh in
                // The hash gate stays here: the reloader guarantees order, not
                // that the newest bytes differ from what is already on screen.
                guard let self, self.content?.hash != fresh.hash else { return }
                self.content = fresh
                self.subtitle = Self.subtitle(for: fresh.stats)
                self.captureAnchor()
                self.startRender()
            }
            reloader = made
        }
        reloader?.reload(url: url)
    }

    // MARK: Typography

    /// Kept out of `observers`, which `attach` empties every time SwiftUI hands
    /// over a new `PDFView`: a style change has to keep reaching the document
    /// across that.
    private func observePrefs() {
        guard prefsObserver == nil else { return }
        let box = MainBox(self)
        prefsObserver = NotificationCenter.default.addObserver(
            forName: .glassinePrefsChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { box.value?.stylingChanged() }
        }
    }

    private func stylingChanged() {
        let current = MarkdownStyling.current
        guard kind == .markdown, current != styling else { return }
        styling = current
        // The Markdown itself has not changed, only the stylesheet wrapped round
        // it -- but every page break moves, so where the reader is has to be
        // remembered by heading.
        captureAnchor()
        startRender()
    }

    // MARK: Output

    /// True when what is on screen is not what should leave the app: a
    /// continuous render is one 40-inch page, which is a way to read and not a
    /// thing to hand someone or feed a printer.
    private var needsPaginatedOutput: Bool {
        kind == .markdown && styling.layout == .continuous
    }

    /// The document an export or a print should use. Output is always paginated,
    /// so a continuous render is typeset a second time under its own renderer
    /// key -- the document's own render is not superseded -- and given the same
    /// outline. Anything else is what is already on screen.
    func paginatedDocumentForOutput(
        _ completion: @escaping @MainActor (Result<PDFDocument, Error>) -> Void
    ) {
        guard needsPaginatedOutput, let bodyHTML = content?.html else {
            guard let document else {
                completion(.failure(Self.nothingToExport))
                return
            }
            completion(.success(document))
            return
        }
        // The export and the print sheet take the platform layer too: a document
        // that looked one way on screen and printed another would be a bug
        // report, and the darker panels print better than the near-whites did.
        let html = MarkdownHTML.page(body: bodyHTML, title: title,
                                     styling: styling.paginated,
                                     platformCSS: ReaderTheme.markdownPlatformCSS)
        MarkdownRendererIOS.shared.render(html: html,
                                          baseURL: url,
                                          key: renderKey + ".export",
                                          layout: .pages,
                                          headings: content?.headings ?? []) { result in
            completion(result.map(\.document))
        }
    }

    /// Export as PDF: a paginated re-render, re-serialised so the bookmarks are
    /// in the file and the `glassine-outline://` link annotations are not, in a
    /// temporary file for the document picker to move where the reader says.
    func exportPDF(_ completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        paginatedDocumentForOutput { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let document):
                // Deliberately not the raw render bytes: those still carry the
                // link annotations and none of the bookmarks.
                guard let data = document.dataRepresentation() else {
                    completion(.failure(Self.nothingToExport))
                    return
                }
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent(self.title)
                    .appendingPathExtension("pdf")
                do {
                    try data.write(to: file)
                    completion(.success(file))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private static let nothingToExport = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteUnknownError,
        userInfo: [NSLocalizedDescriptionKey: "There is nothing to export yet."])

    #if DEBUG
    /// The render itself, where a script on the Mac can pull it out of the
    /// container and check the pages, the fonts, the annotations and the
    /// outline. Debug builds only. Two files: what the reader is showing, and --
    /// for a continuous render -- the paginated version output would use.
    private func dumpRender(_ document: PDFDocument) {
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]
        try? document.dataRepresentation()?
            .write(to: documents.appendingPathComponent("last-render.pdf"))
    }
    #endif

    // MARK: The view

    /// The representable hands its `PDFView` over as soon as it exists. The
    /// document may arrive before or after it, so both paths end in
    /// `installInView`.
    func attach(_ view: ReaderPDFView) {
        guard pdfView !== view else { return }
        // SwiftUI can hand over a second view (a scene rebuild, a size-class
        // change); the old one's observers would otherwise pile up.
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        pdfView = view
        pdfViewToken += 1

        let box = MainBox(self)
        observers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { _ in
            MainActor.assumeIsolated { box.value?.pageChanged() }
        })
        // Zooming changes how much of a page is on screen, and with it which
        // chapter has started.
        observers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: view, queue: .main
        ) { _ in
            MainActor.assumeIsolated { box.value?.scheduleOutlineSync() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { box.value?.savePosition() }
        })

        installInView()
    }

    private func installInView() {
        guard let pdfView, let document, pdfView.document !== document else { return }
        pdfView.document = document

        // Created only now: ReadingPosition reads the saved position once, at
        // init, because PDFView reports page 1 while it lays out and those
        // reports would overwrite it.
        let saved = Prefs.lastPosition(for: url)
        let position = ReadingPosition(pdfView: pdfView, saved: saved,
                                       url: { [weak self] in self?.url })
        self.position = position

        outlineEntries = OutlineSync.entries(of: document.outlineRoot, in: document)
        observeScrolling()

        position.restoreIfNeeded { [weak self] in
            guard let self else { return }
            self.updatePageReadout()
            self.syncOutlineSelection()
            #if DEBUG
            self.applyDebugLaunchArguments()
            #endif
        }
        // The reader owns the keyboard: arrows page, and the find shortcuts
        // have to reach the view rather than whatever SwiftUI focused last.
        pdfView.becomeFirstResponder()
    }

    /// A continuous document scrolls a long way without ever changing page, so
    /// `.PDFViewPageChanged` alone would leave the Contents pane's selection
    /// stuck. KVO on PDFKit's own scroll view fills the gap; the sync is
    /// debounced because the offset changes every frame.
    private func observeScrolling() {
        scrollObservation = nil
        guard let scrollView = pdfView?.enclosedScrollView else { return }
        let box = MainBox(self)
        scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { _, _ in
            MainActor.assumeIsolated { box.value?.scheduleOutlineSync() }
        }
    }

    /// Coalesced at 50 ms, the Mac's interval: the offset changes every frame of
    /// a scroll and relaying the capsule out each time is wasted work.
    private func scheduleOutlineSync() {
        guard !outlineSyncPending else { return }
        outlineSyncPending = true
        let box = MainBox(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                guard let session = box.value else { return }
                session.outlineSyncPending = false
                session.syncOutlineSelection()
                session.updatePageReadout()
                session.updateProgress()
            }
        }
    }

    private func pageChanged() {
        updatePageReadout()
        savePosition()
        syncOutlineSelection()
    }

    // MARK: Reading progress (continuous Markdown)

    /// How far through the scrollable range the top of the visible area sits, as
    /// scroll geometry rather than PDF coordinates -- the same quantity, and the
    /// same reasoning, as the Mac's clip-view arithmetic. PDFKit's own
    /// `UIScrollView` is the only thing that moves in a document that never
    /// changes page.
    private var readingProgress: CGFloat {
        guard let scrollView = pdfView?.enclosedScrollView else { return 0 }
        let inset = scrollView.adjustedContentInset
        let visible = scrollView.bounds.height - inset.top - inset.bottom
        let span = scrollView.contentSize.height - visible
        let travelled = scrollView.contentOffset.y + inset.top
        return ReadingProgress.fraction(travelled: travelled, span: span)
    }

    private func updateProgress() {
        guard isContinuousMarkdown else { return }
        let percent = Int((readingProgress * 100).rounded())
        if percent != progressPercent { progressPercent = percent }
    }

    /// Put the top of the visible area at `fraction` of the scrollable range --
    /// what Go to Page does when the capsule is a percentage.
    private func scroll(toFraction fraction: CGFloat) {
        guard let scrollView = pdfView?.enclosedScrollView else { return }
        let inset = scrollView.adjustedContentInset
        let visible = scrollView.bounds.height - inset.top - inset.bottom
        let span = scrollView.contentSize.height - visible
        guard let travelled = ReadingProgress.offset(forFraction: fraction, span: span) else {
            return
        }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x,
                                            y: travelled - inset.top),
                                    animated: false)
        updateProgress()
        syncOutlineSelection()
    }

    /// Core's, since `ReadingPosition` learned the iOS reading of "where the
    /// reader is" (`convert(_:to:)` on the view's own origin rather than
    /// `currentDestination`, which on iOS reports the *bottom* of the visible
    /// area). The gates and the two-pass jump were always Core's.
    private func savePosition() {
        position?.save()
    }

    private func updatePageReadout() {
        guard let pdfView, let document = pdfView.document, let page = pdfView.currentPage
        else { return }
        let index = document.index(for: page)
        guard index != NSNotFound, index != currentPageIndex else { return }
        currentPageIndex = index
    }

    /// Highlight the last entry, in pre-order, that starts at or before the
    /// reading position -- `OutlineSync`'s rule, exactly as the Mac's sidebar
    /// asks it.
    private func syncOutlineSelection() {
        guard !outlineEntries.isEmpty, let pdfView,
              let here = OutlineSync.currentOrdinal(of: pdfView) else { return }
        let best = OutlineSync.index(atOrBefore: here, in: outlineEntries)
        if best != outlineSelection { outlineSelection = best }
    }

    // MARK: Navigation

    /// 1-based, clamped, as the page popover and ⌥⌘G both need it.
    ///
    /// Through a `PDFDestination` at the top of the page rather than
    /// `go(to: page)`, and after forcing the layout: that is the same shape
    /// `ReadingPosition`'s jump and the outline rows already use, and PDFKit
    /// silently ignores navigation until it has laid the document out.
    func goToPage(number: Int) {
        // In continuous Markdown the capsule is a percentage, so the same field
        // takes 0-100 and scrolls to that fraction -- the Mac's rule.
        guard !isContinuousMarkdown else {
            scroll(toFraction: CGFloat(min(max(number, 0), 100)) / 100)
            return
        }
        guard let document, document.pageCount > 0 else { return }
        let target = min(max(number, 1), document.pageCount) - 1
        guard let page = document.page(at: target) else { return }
        let top = page.bounds(for: .cropBox).maxY
        // Force the layout first, exactly as ReadingPosition's jump does:
        // PDFView silently ignores go(to:) before it has laid the document out,
        // and a go-to-page can arrive at any moment -- including one runloop
        // after the document was installed.
        pdfView?.layoutDocumentView()
        pdfView?.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: top)))
        updatePageReadout()
    }

    func go(to destination: PDFDestination) {
        pdfView?.go(to: destination)
        updatePageReadout()
        syncOutlineSelection()
    }

    // MARK: Find

    func startFind(_ query: String) {
        findQuery = query
        find.startFind(query)
    }

    func stepFind(by delta: Int) {
        find.step(by: delta, query: findQuery)
    }

    /// The x / Done button. Everything the Mac's `startFind("")` clears, plus
    /// the bar itself.
    func endFind() {
        findQuery = ""
        find.startFind("")
        isFindBarVisible = false
        pdfView?.becomeFirstResponder()
    }

    /// Dark mode draws its own reverse-video boxes; light mode uses PDFKit's
    /// `highlightedSelections`. Same split as the Mac.
    private func applyHighlights() {
        guard let pdfView else { return }
        let matches = find.matches
        pdfView.isInverted = isInverted
        if isInverted {
            // The drawn box *is* the highlight; PDFKit's own translucent wash
            // would double up on it and comes out olive through the filter.
            for selection in matches { selection.color = .clear }
            pdfView.highlightedSelections = nil
            pdfView.setFindMatches(matches, current: find.matchIndex)
        } else {
            pdfView.setFindMatches([], current: 0)
            for selection in matches {
                selection.color = UIColor.systemGreen.withAlphaComponent(0.35)
            }
            pdfView.highlightedSelections = matches.isEmpty ? nil : matches
        }
    }

    /// The reader calls this when the appearance changes, so live matches
    /// switch highlight style without being searched for again.
    func inversionChanged(to inverted: Bool) {
        guard isInverted != inverted else { return }
        isInverted = inverted
        applyHighlights()
    }

    // MARK: Scene restoration

    /// What a scene publishes so iPadOS can bring this document back, and what
    /// "Open in New Window" hands to a brand-new scene. The bookmark is what
    /// still finds the file after a move; the path is the readable fallback.
    func fill(_ activity: NSUserActivity) {
        activity.title = title
        activity.targetContentIdentifier = url.path
        var info: [String: Any] = [AppLaunch.activityPathKey: url.path]
        if let bookmark = try? url.bookmarkData() {
            info[AppLaunch.activityBookmarkKey] = bookmark
        }
        activity.addUserInfoEntries(from: info)
    }

    /// The inverse. Nil when the activity names a file that is no longer there.
    static func url(from activity: NSUserActivity) -> URL? {
        let info = activity.userInfo ?? [:]
        if let bookmark = info[AppLaunch.activityBookmarkKey] as? Data {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                return url
            }
        }
        guard let path = info[AppLaunch.activityPathKey] as? String,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

// MARK: - FindSink

/// PDFKit's find results, filtered before the state machine sees them.
///
/// The only thing filtered is the print path's ghost text: a heading the
/// keep-with-next hack carries onto the next page leaves a *clipped* copy in the
/// bottom margin of the page it left, invisible in the render but real to
/// `findString` and to `beginFindString`. Without this the counter over-reports
/// and stepping lands on a page that shows nothing.
extension DocumentSession: FindSink {

    func findDidMatch(_ selection: PDFSelection) {
        guard !isGhost(selection) else { return }
        find.findDidMatch(selection)
    }

    func findDidEnd() { find.findDidEnd() }

    func findDidEnd(in document: PDFDocument) { find.findDidEnd(in: document) }

    /// True for a selection lying wholly below the printable band. PDF y grows
    /// upwards, so the band's foot is at `margin` and real text never has its
    /// top edge below that.
    private func isGhost(_ selection: PDFSelection) -> Bool {
        guard let band = ghostBand, band.margin > 0,
              let page = selection.pages.first else { return false }
        return selection.bounds(for: page).maxY <= band.margin + 0.5
    }
}

/// `NSFilePresenter` for the open Markdown file, beside the vnode watcher.
///
/// The Mac gets by on the watcher alone because the writers that matter there
/// (editors, CLI tools) do not coordinate. On iOS the important writers do:
/// iCloud Drive and the Files app both go through `NSFileCoordinator`, and a
/// coordinated write can leave the vnode source with nothing to report. This
/// pokes the watcher's debounce rather than doing anything itself, so one save
/// seen twice still costs one render.
///
/// `@unchecked Sendable` because it is: the URL is immutable and the one
/// callback is delivered on the main queue, which is where the closure it holds
/// belongs.
final class MarkdownFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {

    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let onChange: @MainActor () -> Void

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        super.init()
    }

    func presentedItemDidChange() {
        MainActor.assumeIsolated { onChange() }
    }
}

// MARK: - FindControllerDelegate

extension DocumentSession: FindControllerDelegate {

    func findControllerDidClear(_ controller: FindController) {
        pdfView?.highlightedSelections = nil
        pdfView?.setFindMatches([], current: 0)
        // In light mode the current match is PDFKit's own selection and nothing
        // else ever drops it, so without this the last match stays washed on the
        // page after the query stops matching -- and survives ending the find.
        pdfView?.setCurrentSelection(nil, animate: false)
    }

    func findController(_ controller: FindController,
                        didUpdate matches: [PDFSelection],
                        current: Int,
                        inProgress: Bool) {
        applyHighlights()
    }

    func findController(_ controller: FindController,
                        show selection: PDFSelection,
                        at index: Int) {
        guard let pdfView else { return }
        if isInverted {
            pdfView.go(to: selection)
            pdfView.setCurrentSelection(nil, animate: false)
            pdfView.setCurrentMatchIndex(index)
        } else {
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.go(to: selection)
        }
        updatePageReadout()
        syncOutlineSelection()
    }

    func findController(_ controller: FindController, canStep: Bool) {
        findCanStep = canStep
    }

    func findControllerCountDidChange(_ controller: FindController) {
        findCountText = controller.countText
    }
}
