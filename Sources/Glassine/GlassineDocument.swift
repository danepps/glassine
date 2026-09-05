import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Receives find results from the PDFDocument delegate.
protocol FindSink: AnyObject {
    func findDidMatch(_ selection: PDFSelection)
    func findDidEnd()
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

    // Markdown state
    private var bodyHTML: String?
    /// The headings behind the current body, in document order; they become the
    /// rendered PDF's outline.
    private var headings: [MarkdownHeading] = []
    private var lastLoadedHash: Int?
    private var styling = MarkdownStyling.current
    /// Word count of the Markdown behind the current render; nil for a PDF.
    /// The window shows it as its subtitle.
    private(set) var markdownStats: MarkdownStats?
    /// True while the PDF on screen is a Markdown document laid out as one tall
    /// page: the reader's indicator then shows reading progress as a percentage,
    /// because "1 of 1" would say nothing.
    private(set) var isContinuousMarkdown = false
    private var watcher: FileWatcher?
    /// Bumped for every render; a completion whose generation is stale is dropped.
    private var renderGeneration = 0
    private var observingPrefs = false
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
            let data = try Data(contentsOf: url)
            lastLoadedHash = data.hashValue
            let converted = MarkdownHTML.body(
                fromMarkdown: try MarkdownHTML.decode(data, url: url),
                baseDirectory: url.deletingLastPathComponent())
            bodyHTML = converted.html
            headings = converted.headings
            markdownStats = converted.stats
        }
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController(document: self))
        guard kind == .markdown else { return }
        startRender(initial: true)
        startWatching()
        observePrefs()
    }

    // MARK: Markdown rendering

    private func startRender(initial: Bool) {
        guard kind == .markdown, let bodyHTML else { return }
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

    private func install(_ rendered: MarkdownRenderer.Result,
                         initial: Bool,
                         layout: MarkdownLayout) {
        isContinuousMarkdown = (layout == .continuous)
        // The delegate has to be in place before anything asks for a page:
        // PDFKit calls classForPage lazily, and a page vended before this is set
        // would be a plain PDFPage, which cannot draw dark-mode find highlights.
        rendered.document.delegate = self
        Self.applyOutline(headings, to: rendered.document)
        pdf = rendered.document
        if let url = fileURL,
           let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) {
            fileModificationDate = values.contentModificationDate
        }
        NotificationCenter.default.post(name: .glassineDocumentDidReplacePDF,
                                        object: self,
                                        userInfo: ["initial": initial])
    }

    /// Give a rendered Markdown PDF the outline WebKit's print path never
    /// writes. MarkdownHTML wraps every heading in a `glassine-outline://<n>`
    /// anchor, and WebKit *does* emit link annotations, so each annotation
    /// names one heading and says exactly where it landed. The annotations are
    /// removed afterwards: nothing on screen should link to a private scheme.
    private static func applyOutline(_ headings: [MarkdownHeading], to document: PDFDocument) {
        guard !headings.isEmpty else { return }

        var located: [Int: (page: Int, top: CGFloat)] = [:]
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard let url = annotation.url, url.scheme == "glassine-outline",
                      let index = url.host.flatMap(Int.init) else { continue }
                // A heading that wraps onto two lines gets one annotation per
                // line; the topmost is where the bookmark should point.
                let top = annotation.bounds.maxY
                let better = located[index].map {
                    pageIndex < $0.page || (pageIndex == $0.page && top > $0.top)
                } ?? true
                if better { located[index] = (pageIndex, top) }
                page.removeAnnotation(annotation)
            }
        }

        let root = PDFOutline()
        var stack: [(level: Int, node: PDFOutline)] = [(0, root)]
        var previous: PDFDestination?
        for heading in headings {
            var destination = previous
            if let hit = located[heading.index], let page = document.page(at: hit.page) {
                // PDF coordinates are bottom-up, so this is the top-left corner
                // the view scrolls to.
                destination = PDFDestination(page: page, at: NSPoint(x: 0, y: hit.top + 4))
                previous = destination
            } else if destination == nil, let first = document.page(at: 0) {
                destination = PDFDestination(
                    page: first, at: NSPoint(x: 0, y: first.bounds(for: .mediaBox).maxY))
            }
            let node = PDFOutline()
            node.label = heading.title
            node.destination = destination
            // A jump from h1 straight to h3 simply nests under the h1.
            while stack.count > 1, stack[stack.count - 1].level >= heading.level {
                stack.removeLast()
            }
            let parent = stack[stack.count - 1].node
            parent.insertChild(node, at: parent.numberOfChildren)
            stack.append((heading.level, node))
        }
        document.outlineRoot = root
    }

    // MARK: Reloading

    private func startWatching() {
        guard let url = fileURL, watcher == nil else { return }
        watcher = FileWatcher(url: url) { [weak self] in
            self?.reloadFromDisk()
        }
    }

    private func reloadFromDisk() {
        guard kind == .markdown, let url = fileURL else { return }
        let baseDirectory = url.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let data = try? Data(contentsOf: url) else { return }
            let hash = data.hashValue
            guard let text = try? MarkdownHTML.decode(data, url: url) else { return }
            let converted = MarkdownHTML.body(fromMarkdown: text, baseDirectory: baseDirectory)
            DispatchQueue.main.async {
                guard let self, self.lastLoadedHash != hash else { return }
                self.lastLoadedHash = hash
                self.bodyHTML = converted.html
                self.headings = converted.headings
                self.markdownStats = converted.stats
                self.startRender(initial: false)
            }
        }
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
        watcher?.retarget(to: newURL)
    }

    override func close() {
        watcher?.stop()
        watcher = nil
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
        // around it, so the cached body is reused as is.
        startRender(initial: false)
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

    /// An export is always paginated: one 40-inch page is a way to read on
    /// screen, not a file to hand someone or print. A continuous render is
    /// therefore typeset a second time, under its own renderer key so the
    /// document's own render is not superseded.
    private func pdfDataForExport(_ completion: @escaping (Swift.Result<Data, Error>) -> Void) {
        // Deliberately not the raw render bytes for Markdown: those still carry
        // the glassine-outline:// link annotations and none of the bookmarks.
        // Copying the original bytes keeps a PDF export byte-identical;
        // dataRepresentation() re-serialises and is only the fallback.
        if kind == .pdf, let url = fileURL, let data = try? Data(contentsOf: url) {
            completion(.success(data))
            return
        }
        if kind == .markdown, styling.layout == .continuous, let bodyHTML {
            let html = MarkdownHTML.page(body: bodyHTML,
                                         title: displayName ?? "",
                                         styling: styling.paginated)
            let outline = headings
            MarkdownRenderer.shared.render(html: html,
                                           baseURL: fileURL,
                                           key: renderKey + ".export",
                                           layout: .pages) { result in
                switch result {
                case .success(let rendered):
                    Self.applyOutline(outline, to: rendered.document)
                    guard let data = rendered.document.dataRepresentation() else {
                        completion(.failure(Self.nothingToExport))
                        return
                    }
                    completion(.success(data))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            return
        }
        guard let data = pdf?.dataRepresentation() else {
            completion(.failure(Self.nothingToExport))
            return
        }
        completion(.success(data))
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
            findSink?.findDidMatch(instance)
        } else {
            DispatchQueue.main.async { self.findSink?.findDidMatch(instance) }
        }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        if Thread.isMainThread {
            findSink?.findDidEnd()
        } else {
            DispatchQueue.main.async { self.findSink?.findDidEnd() }
        }
    }
}
