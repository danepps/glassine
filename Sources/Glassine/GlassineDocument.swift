import AppKit
import GlassineCore
import PDFKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by a GlassineDocument (as `object`) once a new PDFDocument has taken
    /// the place of the old one -- the first Markdown render, a reload after the
    /// file changed on disk, or a typography change. `userInfo["initial"]` is
    /// true for the first render of a window.
    static let glassineDocumentDidReplacePDF = Notification.Name("GlassineDocumentDidReplacePDF")
}

/// Read-only NSDocument wrapping a PDFDocument. NSDocument gives us Finder
/// integration, Open Recent, the title-bar proxy icon, and one-window-per-file
/// semantics for free.
///
/// Two kinds of file end up in the same PDFDocument slot. A `.pdf` is opened
/// directly. A `.markdown` file is converted to HTML and typeset into a real
/// paginated PDF by `MarkdownRenderer`, so everything downstream -- tabs, dark
/// mode, find, position memory, printing -- works without knowing the
/// difference. Because typesetting is asynchronous, the first Markdown render
/// is just "reload #0": the window opens empty and fills a fraction of a second
/// later through the same path a file-change reload uses.
@objc(GlassineDocument)
final class GlassineDocument: NSDocument, PDFDocumentDelegate {

    enum Kind {
        case pdf
        case markdown
    }

    /// macOS does not declare this in CoreTypes, so Glassine imports it (see
    /// UTImportedTypeDeclarations in Info.plist).
    static let markdownType = UTType(importedAs: "net.daringfireball.markdown",
                                     conformingTo: .plainText)

    private static let markdownExtensions: Set<String> =
        ["md", "markdown", "mdown", "mkdn", "mkd", "mdwn"]

    private(set) var kind: Kind = .pdf
    private(set) var pdf: PDFDocument?
    weak var findSink: FindSink?

    // Markdown state. The decode/convert/headings/word-count half lives in
    // Core; this class keeps the NSDocument shell around it.
    private var content: MarkdownContent?
    private var styling = MarkdownStyling.current
    /// Word count of the Markdown behind the current render; nil for a PDF.
    /// The window shows it as its subtitle.
    var markdownStats: MarkdownStats? { content?.stats }
    /// True while the PDF on screen is a Markdown document laid out as one tall
    /// page: the reader's indicator then shows reading progress as a percentage,
    /// because "1 of 1" would say nothing.
    private(set) var isContinuousMarkdown = false
    private var watcher: FileWatcher?
    /// Reloads, in order: two saves in quick succession are two conversions
    /// racing on a concurrent queue, and without this the slower one could
    /// overwrite the newer revision (and then start a render carrying a newer
    /// generation, so the render guard could not catch it either).
    private var reloader: MarkdownReloader?
    /// Bumped for every render; a completion whose generation is stale is dropped.
    private var renderGeneration = 0
    private var observingPrefs = false
    /// Where the reader is, as an outline entry, recorded just before a
    /// re-render and handed to the window once the replacement is installed. A
    /// page index and a point mean nothing across a re-typesetting that moved
    /// every page break -- or, going Pages → Continuous, collapsed them all into
    /// one page.
    private var pendingAnchor: ReadingAnchor?
    /// Identifies this document to the renderer's job queue, so a second render
    /// of the same file supersedes one still waiting.
    private let renderKey = UUID().uuidString

    override class var autosavesInPlace: Bool { false }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    deinit {
        watcher?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Reading

    private static func kind(forType typeName: String, url: URL) -> Kind {
        if let type = UTType(typeName) {
            if type.conforms(to: .pdf) { return .pdf }
            if type == markdownType || type.conforms(to: markdownType) { return .markdown }
        }
        // LaunchServices sometimes hands over a plain-text type (or the raw
        // extension) for Markdown, so fall back to the file name.
        return markdownExtensions.contains(url.pathExtension.lowercased()) ? .markdown : .pdf
    }

    /// True for a file this reader can open. Used where there is no type name to
    /// go on, such as a file dropped on the Recents window.
    static func canOpen(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pdf" || markdownExtensions.contains(ext)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        kind = Self.kind(forType: typeName, url: url)
        switch kind {
        case .pdf:
            guard let document = PDFDocument(url: url) else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadCorruptFileError,
                    userInfo: [
                        NSURLErrorKey: url,
                        NSLocalizedDescriptionKey: "\(url.lastPathComponent) could not be opened as a PDF."
                    ]
                )
            }
            document.delegate = self
            pdf = document
        case .markdown:
            // Only text work here; `pdf` stays nil until the renderer finishes.
            content = try MarkdownDocumentModel.content(of: try Data(contentsOf: url), url: url)
        }
        Prefs.noteRecentDocument(url, pageCount: pdf?.pageCount)
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController(document: self))
        guard kind == .markdown else { return }
        startRender()
        startWatching()
        observePrefs()
    }

    // MARK: Markdown rendering

    private func startRender() {
        guard kind == .markdown, let bodyHTML = content?.html else { return }
        renderGeneration += 1
        let generation = renderGeneration
        let html = MarkdownHTML.page(body: bodyHTML,
                                     title: displayName ?? "",
                                     styling: styling)
        let layout = styling.layout
        MarkdownRenderer.shared.render(html: html,
                                       baseURL: fileURL,
                                       key: renderKey,
                                       layout: layout) { [weak self] result in
            guard let self, generation == self.renderGeneration else { return }
            // "First" is a fact about the document, not about which event asked
            // for this render: a save or a style change that lands before the
            // opening render has finished supersedes it, and *that* render is
            // then the first successful install -- it has to restore the saved
            // position, and its failure is the one worth reporting.
            let initial = (self.pdf == nil)
            switch result {
            case .success(let rendered):
                self.install(rendered, initial: initial, layout: layout)
            case .failure(let error):
                // A reload that fails almost always means a half-written file;
                // keep showing the last good render and wait for the next save.
                guard initial else { return }
                self.presentError(error)
                self.close()
            }
        }
    }

    /// Note where the reader is, by heading, before a re-render throws the
    /// current pagination away.
    @MainActor
    private func captureAnchor() {
        guard kind == .markdown, pdf != nil else { return }
        pendingAnchor = (windowControllers.first as? ReaderWindowController)?.readingAnchor
    }

    private func install(_ rendered: RenderedMarkdown,
                         initial: Bool,
                         layout: MarkdownLayout) {
        isContinuousMarkdown = (layout == .continuous)
        // The delegate has to be in place before anything asks for a page:
        // PDFKit calls classForPage lazily, and a page vended before this is set
        // would be a plain PDFPage, which cannot draw dark-mode find highlights.
        rendered.document.delegate = self
        MarkdownDocumentModel.applyOutline(content?.headings ?? [], to: rendered.document)
        pdf = rendered.document
        if let url = fileURL,
           let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) {
            fileModificationDate = values.contentModificationDate
        }
        var info: [AnyHashable: Any] = ["initial": initial]
        if let anchor = pendingAnchor { info["anchor"] = anchor }
        pendingAnchor = nil
        NotificationCenter.default.post(name: .glassineDocumentDidReplacePDF,
                                        object: self,
                                        userInfo: info)
    }

    // MARK: Reloading

    private func startWatching() {
        guard let url = fileURL, watcher == nil else { return }
        watcher = FileWatcher(url: url) { [weak self] in
            self?.reloadFromDisk()
        }
    }

    /// Built on first reload rather than at init, so a PDF document never makes
    /// one, and always from the main actor.
    @MainActor
    private func makeReloader() -> MarkdownReloader {
        let made = MarkdownReloader()
        made.onContent = { [weak self] fresh in
            // The hash gate stays here: the reloader guarantees order, not that
            // the newest bytes differ from the ones already on screen.
            guard let self, self.content?.hash != fresh.hash else { return }
            self.content = fresh
            self.captureAnchor()
            self.startRender()
        }
        return made
    }

    @MainActor
    private func reloadFromDisk() {
        guard kind == .markdown, let url = fileURL else { return }
        if reloader == nil { reloader = makeReloader() }
        reloader?.reload(url: url)
    }

    /// Retire every reload still converting. The document is going away, or the
    /// file it points at has moved and what is in flight was read from the old
    /// path.
    @MainActor
    private func invalidateReloads() {
        reloader?.invalidate()
    }

    // Route the coordinated-write callback into the watcher instead of letting
    // NSDocument run its own revert machinery; the watcher's debounce and
    // signature gate then keep the two paths from rendering twice.
    override func presentedItemDidChange() {
        if kind == .markdown {
            watcher?.poke()
        } else {
            super.presentedItemDidChange()
        }
    }

    override func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        MainActor.assumeIsolated { invalidateReloads() }
        watcher?.retarget(to: newURL)
    }

    override func close() {
        watcher?.stop()
        watcher = nil
        MainActor.assumeIsolated { invalidateReloads() }
        super.close()
        if kind == .markdown { MarkdownRenderer.shared.releaseIfIdle() }
    }

    // MARK: Typography

    private func observePrefs() {
        guard !observingPrefs else { return }
        observingPrefs = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(prefsChanged), name: .glassinePrefsChanged, object: nil)
    }

    @objc private func prefsChanged() {
        let current = MarkdownStyling.current
        guard kind == .markdown, current != styling else { return }
        styling = current
        // The Markdown itself has not changed, only the stylesheet wrapped
        // around it, so the cached body is reused as is -- but every page break
        // moves, so where the reader is has to be remembered by heading.
        MainActor.assumeIsolated { captureAnchor() }
        startRender()
    }

    // MARK: Export

    @objc func exportAsPDF(_ sender: Any?) {
        guard let window = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let base = fileURL?.deletingPathExtension().lastPathComponent
            ?? (displayName ?? "Document")
        panel.nameFieldStringValue = base + ".pdf"
        if let directory = fileURL?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let destination = panel.url else { return }
            self.pdfDataForExport { result in
                switch result {
                case .success(let data):
                    do { try data.write(to: destination) } catch { self.presentError(error) }
                case .failure(let error):
                    self.presentError(error)
                }
            }
        }
    }

    /// True when what is on screen is not what should leave the app: a
    /// continuous Markdown render is one 40-inch page, which is a way to read
    /// and not a thing to hand someone or feed a printer.
    var needsPaginatedOutput: Bool { kind == .markdown && styling.layout == .continuous }

    /// The document an export or a print should use. Output is always
    /// paginated, so a continuous render is typeset a second time under its own
    /// renderer key -- the document's own render is not superseded -- and given
    /// the same outline. Anything else is what is already on screen.
    func paginatedDocumentForOutput(
        _ completion: @escaping (Swift.Result<PDFDocument, Error>) -> Void
    ) {
        guard needsPaginatedOutput, let bodyHTML = content?.html else {
            guard let pdf else {
                completion(.failure(Self.nothingToExport))
                return
            }
            completion(.success(pdf))
            return
        }
        let html = MarkdownHTML.page(body: bodyHTML,
                                     title: displayName ?? "",
                                     styling: styling.paginated)
        let outline = content?.headings ?? []
        MarkdownRenderer.shared.render(html: html,
                                       baseURL: fileURL,
                                       key: renderKey + ".export",
                                       layout: .pages) { result in
            switch result {
            case .success(let rendered):
                MarkdownDocumentModel.applyOutline(outline, to: rendered.document)
                completion(.success(rendered.document))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func pdfDataForExport(_ completion: @escaping (Swift.Result<Data, Error>) -> Void) {
        // Deliberately not the raw render bytes for Markdown: those still carry
        // the glassine-outline:// link annotations and none of the bookmarks.
        // Copying the original bytes keeps a PDF export byte-identical;
        // dataRepresentation() re-serialises and is only the fallback.
        if kind == .pdf, let url = fileURL, let data = try? Data(contentsOf: url) {
            completion(.success(data))
            return
        }
        paginatedDocumentForOutput { result in
            switch result {
            case .success(let document):
                guard let data = document.dataRepresentation() else {
                    completion(.failure(Self.nothingToExport))
                    return
                }
                completion(.success(data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private static let nothingToExport = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteUnknownError,
        userInfo: [NSLocalizedDescriptionKey: "There is nothing to export yet."])

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(exportAsPDF(_:)) { return pdf != nil }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: PDFDocumentDelegate

    func classForPage() -> AnyClass {
        ReaderPage.self
    }

    func didMatchString(_ instance: PDFSelection) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { findSink?.findDidMatch(instance) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.findSink?.findDidMatch(instance) }
            }
        }
    }

    /// PDFKit names the document the search ran in, which is what lets the find
    /// controller tell its own search's end from a straggler belonging to a
    /// document a Markdown reload has already replaced.
    func documentDidEndDocumentFind(_ notification: Notification) {
        let source = notification.object as? PDFDocument
        if Thread.isMainThread {
            MainActor.assumeIsolated { deliverFindEnd(from: source) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.deliverFindEnd(from: source) }
            }
        }
    }

    @MainActor
    private func deliverFindEnd(from source: PDFDocument?) {
        guard let sink = findSink else { return }
        if let source {
            sink.findDidEnd(in: source)
        } else {
            sink.findDidEnd()
        }
    }
}
