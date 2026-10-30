import AppKit
import GlassineCore
import PDFKit

/// Owns presentation crops, never a PDF mutation. Analysis uses immutable
/// CoreGraphics page references off the main thread. A short document is
/// installed in one transaction once every page is known; a long one starts
/// with the pages around the reader and then installs the rest in a few
/// growing batches, each one a position-preserving transaction.
@MainActor
final class ReaderModeController {
    private struct PageSnapshot: @unchecked Sendable {
        let index: Int
        let page: CGPDFPage?
        let crop: CGRect
        let annotations: [CGRect]
    }
    private struct Detection: Sendable {
        let index: Int
        let bounds: CGRect?
    }

    /// Documents up to this length wait for every page, exactly as before
    /// progressive trimming: with parallel low-resolution detection that is
    /// well under a second, and the reader sees a single layout change.
    static let progressivePageThreshold = 100
    /// Pages either side of the reader's page analysed before the first install.
    static let neighbourPages = 4
    /// Later installs wait for at least this many pages, or a quarter of the
    /// pages already known, so a book sees a handful of layout transactions
    /// rather than one per page.
    nonisolated private static let minimumBatch = 32
    /// Leave a core for the main thread and PDFKit's own tile rendering, and
    /// bound the number of bitmaps alive at once.
    nonisolated private static let concurrency = max(1, min(ProcessInfo.processInfo.activeProcessorCount - 1, 8))
    private struct Layout {
        let box: PDFDisplayBox
        let mode: PDFDisplayMode
        let direction: PDFDisplayDirection
        let scale: CGFloat
        let autoScales: Bool
        let breaks: Bool
        let margins: NSEdgeInsets
    }

    private weak var document: GlassineDocument?
    private weak var pdfView: ReaderPDFView?
    private weak var analyzedDocument: PDFDocument?
    private weak var analyzingDocument: PDFDocument?
    /// One entry per page of `analyzedDocument`, or nil until the first
    /// results arrive. Only pages in `knownPages` hold a detection; the others
    /// are nil, which installs the page's full original box.
    private var contentBounds: [CGRect?]?
    private var knownPages = IndexSet()
    private var analysis: Task<Void, Never>?
    private var pendingAnnotationPages: Set<Int> = []
    private var generation = 0
    private var updateGeneration = 0
    private var updateScheduled = false
    private var originalLayout: Layout?
    private var widthToFit: CGFloat = 0
    private var fittingWidth = false
    private var adjustingScale = false
    private var lastViewportWidth: CGFloat = 0
    private var lastFittedScale: CGFloat?
    private(set) var settings: ReaderModeSettings
    private(set) var isPreparing = false
    var onPreparationChanged: ((Bool) -> Void)?
    var preservePosition: ((_ changes: () -> Void) -> Void)?
    /// The page the reader is on or about to be restored to. The window's
    /// reading position knows this before PDFView has scrolled there.
    var readingPageIndex: (() -> Int?)?

    var isAvailable: Bool {
        document?.kind == .pdf && pdfView?.document?.isLocked == false
            && (pdfView?.document?.pageCount ?? 0) > 0
    }
    var isEnabled: Bool { isAvailable && settings.enabled }
    var isApplied: Bool { originalLayout != nil }

    init(document: GlassineDocument, pdfView: ReaderPDFView) {
        self.document = document
        self.pdfView = pdfView
        settings = ReaderModeSettings.load(for: document.fileURL)
    }

    deinit { analysis?.cancel() }

    func toggle() {
        guard isAvailable else { return }
        cancelScheduledUpdate()
        settings.enabled.toggle()
        settings.save(for: document?.fileURL)
        if settings.enabled { prepare() }
        else { cancelAnalysis(); restoreLayout() }
    }

    func update(_ value: ReaderModeSettings) {
        let previous = settings
        settings = value.validated
        settings.save(for: document?.fileURL)
        guard settings != previous, isEnabled else { return }
        // Slider ticks in one event-loop pass share one geometry transaction.
        // The latest settings are saved immediately, even if the window closes.
        guard !updateScheduled else { return }
        updateScheduled = true
        let token = updateGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.updateGeneration == token else { return }
            self.updateScheduled = false
            guard self.isEnabled else { return }
            // Returning to Automatic from custom margins resumes any scan the
            // custom margins interrupted; otherwise this re-applies the padding.
            if self.settings.automatic, self.analysis == nil,
               let pdf = self.pdfView?.document, !self.analysisComplete(for: pdf) { self.prepare() }
            else { self.apply() }
        }
    }

    private func cancelScheduledUpdate() {
        updateGeneration &+= 1
        updateScheduled = false
    }

    /// Called after installing a new PDF (including revert) or unlocking the
    /// current PDF. Discard work and bounds belonging to old pages.
    func documentDidChange() {
        cancelScheduledUpdate()
        cancelAnalysis()
        if analyzedDocument !== pdfView?.document {
            clearBounds(in: analyzedDocument)
            contentBounds = nil
            knownPages = []
            analyzedDocument = pdfView?.document
            // Until an automatic scan finishes, an already-active art-box
            // view must show the replacement's entire original crop box.
            if isApplied, let pdf = analyzedDocument {
                for index in 0..<pdf.pageCount {
                    guard let page = pdf.page(at: index) as? ReaderPage else { continue }
                    page.readerContentBounds = page.bounds(for: .cropBox)
                }
            }
        }
        if isEnabled { prepare() }
        else if isApplied { restoreLayout() }
    }

    func annotationsDidChange(on pages: [PDFPage]) {
        guard isEnabled, settings.automatic, let pdf = pdfView?.document else { return }
        let indices = Set(pages.compactMap { page -> Int? in
            guard page.document === pdf else { return nil }
            let index = pdf.index(for: page)
            return index == NSNotFound ? nil : index
        })
        guard !indices.isEmpty else { return }
        if analysis != nil, analyzingDocument === pdf {
            // Keep the scan running. Pages it has already reported merge now;
            // the rest merge when their results arrive, before they install.
            let known = indices.filter { knownPages.contains($0) }
            pendingAnnotationPages.formUnion(indices.subtracting(known))
            if !known.isEmpty, includeAnnotations(on: known, in: pdf), isApplied { apply() }
            return
        }
        guard analyzedDocument === pdf, contentBounds != nil else { prepare(); return }
        if includeAnnotations(on: indices, in: pdf) { apply() }
    }

    /// The immutable PDF ink has not changed. Expanding cached bounds with new
    /// annotation bounds avoids rasterizing even one page, let alone every page.
    /// Removal deliberately retains the wider, safe crop until the next load.
    private func includeAnnotations(on indices: Set<Int>, in pdf: PDFDocument) -> Bool {
        guard var cached = contentBounds, cached.count == pdf.pageCount else { return false }
        var cropChanged = false
        for index in indices where knownPages.contains(index) {
            guard cached.indices.contains(index), let page = pdf.page(at: index),
                  let previous = cached[index] else { continue }
            let original = page.bounds(for: .cropBox)
            var expanded = previous
            for annotation in ReaderContentBounds.visibleAnnotationBounds(on: page) {
                let visible = annotation.intersection(original)
                if !visible.isNull && !visible.isEmpty { expanded = expanded.union(visible) }
            }
            if expanded != previous {
                cached[index] = expanded
                cropChanged = cropChanged || settings.bounds(in: original, content: expanded)
                    != settings.bounds(in: original, content: previous)
            }
        }
        contentBounds = cached
        return cropChanged
    }

    private func preparing(_ value: Bool) {
        guard value != isPreparing else { return }
        isPreparing = value
        onPreparationChanged?(value)
    }

    private func cancelAnalysis() {
        generation &+= 1
        analysis?.cancel()
        analysis = nil
        analyzingDocument = nil
        pendingAnnotationPages.removeAll()
        preparing(false)
    }

    private func prepare() {
        guard isEnabled, let pdf = pdfView?.document else { return }
        cancelAnalysis()
        if analyzedDocument !== pdf {
            contentBounds = nil
            knownPages = []
        }
        if !settings.automatic || analysisComplete(for: pdf) {
            apply()
            return
        }
        // A scan interrupted by switching Reader Mode off, or by custom
        // margins, resumes where it stopped: what is already known installs now.
        if analyzedDocument === pdf, contentBounds != nil { apply() }
        let order = analysisOrder(in: pdf)
        let snapshots = order.compactMap { index -> PageSnapshot? in
            guard let page = pdf.page(at: index) else { return nil }
            return PageSnapshot(index: index, page: page.pageRef, crop: page.bounds(for: .cropBox),
                                annotations: ReaderContentBounds.visibleAnnotationBounds(on: page))
        }
        guard snapshots.count == order.count else { return }
        preparing(true)
        analyzingDocument = pdf
        analyzedDocument = pdf
        let firstBatch = pdf.pageCount <= Self.progressivePageThreshold ? snapshots.count
            : priorityCount(in: pdf, order: order)
        let currentGeneration = generation
        let (stream, continuation) = AsyncStream<[Detection]>.makeStream()
        let worker = Task.detached(priority: .userInitiated) {
            await Self.detect(snapshots, firstBatch: firstBatch, into: continuation)
            continuation.finish()
        }
        // Cancelling the consumer below ends the stream, which stops the worker.
        continuation.onTermination = { _ in worker.cancel() }
        analysis = Task { [weak self, weak pdf] in
            for await batch in stream {
                // Every batch re-checks the generation: a cancelled prepare or
                // a replaced document must never install a stale result.
                guard let self, let pdf, self.generation == currentGeneration else { return }
                self.receive(batch, in: pdf)
            }
        }
    }

    private func analysisComplete(for pdf: PDFDocument) -> Bool {
        analyzedDocument === pdf && contentBounds?.count == pdf.pageCount
            && knownPages.count == pdf.pageCount
    }

    /// Unknown pages, nearest the reader first: the visible pages and their
    /// neighbours, then onward through the document, then back toward page 1.
    private func analysisOrder(in pdf: PDFDocument) -> [Int] {
        let window = priorityWindow(in: pdf)
        let known = knownPages
        let unknown = { (index: Int) in !known.contains(index) }
        return window.filter(unknown)
            + (window.upperBound + 1..<pdf.pageCount).filter(unknown)
            + (0..<window.lowerBound).reversed().filter(unknown)
    }

    private func priorityCount(in pdf: PDFDocument, order: [Int]) -> Int {
        let window = priorityWindow(in: pdf)
        return order.prefix { window.contains($0) }.count
    }

    private func priorityWindow(in pdf: PDFDocument) -> ClosedRange<Int> {
        let last = pdf.pageCount - 1
        var around: [Int] = []
        if let target = readingPageIndex?() {
            around = [min(max(target, 0), last)]
        } else if let view = pdfView {
            around = (view.visiblePages.isEmpty ? [view.currentPage].compactMap { $0 } : view.visiblePages)
                .map { pdf.index(for: $0) }
                .filter { $0 != NSNotFound && $0 <= last }
        }
        let low = around.min() ?? 0, high = around.max() ?? 0
        return max(low - Self.neighbourPages, 0)...min(high + Self.neighbourPages, last)
    }

    /// Detects pages in the given order, a bounded number at a time, and
    /// reports them in batches: the first once the leading `firstBatch` pages
    /// are all done, later ones as they accumulate.
    nonisolated private static func detect(_ snapshots: [PageSnapshot], firstBatch: Int,
                                           into continuation: AsyncStream<[Detection]>.Continuation) async {
        await withTaskGroup(of: (Int, Detection)?.self) { group in
            var next = 0
            func start() {
                guard next < snapshots.count else { return }
                let position = next, snapshot = snapshots[next]
                next += 1
                group.addTask {
                    // A cancelled page has no answer; reporting nil would
                    // cache it as blank.
                    guard !Task.isCancelled else { return nil }
                    let bounds: CGRect? = autoreleasepool {
                        guard let page = snapshot.page else { return nil }
                        return ReaderContentBounds.detect(pageRef: page, cropBox: snapshot.crop,
                                                           annotationBounds: snapshot.annotations)
                    }
                    return (position, Detection(index: snapshot.index, bounds: bounds))
                }
            }
            for _ in 0..<concurrency { start() }
            var pending: [Detection] = []
            var delivered = 0
            var leadingRemaining = firstBatch
            for await result in group {
                guard !Task.isCancelled, let (position, detection) = result else {
                    group.cancelAll()
                    return
                }
                pending.append(detection)
                if position < firstBatch { leadingRemaining -= 1 }
                start()
                let finished = delivered + pending.count == snapshots.count
                let ready = delivered == 0 ? leadingRemaining == 0
                    : pending.count >= max(minimumBatch, delivered / 4)
                if finished || ready {
                    continuation.yield(pending)
                    delivered += pending.count
                    pending.removeAll()
                }
            }
        }
    }

    private func receive(_ batch: [Detection], in pdf: PDFDocument) {
        guard pdfView?.document === pdf, analyzedDocument === pdf, analyzingDocument === pdf,
              isEnabled, settings.automatic else { return }
        var bounds = contentBounds ?? Array(repeating: nil, count: pdf.pageCount)
        guard bounds.count == pdf.pageCount else { return }
        for detection in batch where bounds.indices.contains(detection.index) {
            bounds[detection.index] = detection.bounds
            knownPages.insert(detection.index)
        }
        contentBounds = bounds
        // These pages' snapshots predate annotations added during the scan.
        let arrived = pendingAnnotationPages.filter { knownPages.contains($0) }
        _ = includeAnnotations(on: arrived, in: pdf)
        pendingAnnotationPages.subtract(arrived)
        if knownPages.count == pdf.pageCount {
            analysis = nil
            analyzingDocument = nil
            pendingAnnotationPages.removeAll()
            preparing(false)
        }
        apply()
    }

    /// Re-entrant: an automatic scan calls this once per batch, and a slider
    /// change may call it between batches. Unknown pages keep their full box.
    private func apply() {
        guard isEnabled, let pdfView, let pdf = pdfView.document else { return }
        if settings.automatic {
            // Nothing installs before the first batch, so the first
            // transaction already fits the trimmed width.
            guard analyzedDocument === pdf, contentBounds?.count == pdf.pageCount else { return }
        } else {
            // A custom change supersedes an automatic scan still in flight.
            cancelAnalysis()
        }
        var pages: [(ReaderPage, CGRect)] = []
        var widest: CGFloat = 0
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) as? ReaderPage else {
                assertionFailure("Reader Mode requires ReaderPage instances")
                cancelAnalysis()
                settings.enabled = false
                settings.save(for: document?.fileURL)
                restoreLayout()
                return
            }
            let original = page.bounds(for: .cropBox)
            let detected = contentBounds?[index]
            let bounds = settings.automatic ? settings.bounds(in: original, content: detected)
                : settings.customBounds(in: original, rotation: page.rotation)
            pages.append((page, bounds))
            // Blank/uncertain pages retain their full box, but must not make
            // otherwise useful text smaller merely because a blank leaf exists.
            if !settings.automatic || detected != nil {
                let rotated = abs(page.rotation % 180) == 90
                widest = max(widest, rotated ? bounds.height : bounds.width)
            }
        }
        if widest == 0 {
            widest = pages.map { abs($0.0.rotation % 180) == 90 ? $0.1.height : $0.1.width }.max() ?? 1
        }
        let shouldFit = originalLayout == nil || fittingWidth
        if originalLayout == nil {
            originalLayout = Layout(box: pdfView.displayBox, mode: pdfView.displayMode,
                direction: pdfView.displayDirection, scale: pdfView.scaleFactor,
                autoScales: pdfView.autoScales, breaks: pdfView.displaysPageBreaks,
                margins: pdfView.pageBreakMargins)
        }
        analyzedDocument = pdf
        widthToFit = widest
        fittingWidth = shouldFit
        changeLayout {
            // PDFKit caches annotation transforms for its current display box.
            // Leaving and reentering the art-box layout invalidates those
            // transforms when only our virtual bounds have changed.
            if pdfView.displayBox == .artBox { pdfView.displayBox = .cropBox }
            for (page, bounds) in pages { page.readerContentBounds = bounds }
            pdfView.readerModeActive = true
            pdfView.autoScales = false
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
            pdfView.displayBox = .artBox
            pdfView.displaysPageBreaks = true
            pdfView.pageBreakMargins = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
            pdfView.pageShadowsEnabled = false
            if shouldFit { self.fitWidth() }
            pdfView.layoutDocumentView()
            for (page, _) in pages where !page.annotations.isEmpty {
                pdfView.annotationsChanged(on: page)
            }
        }
    }

    private func changeLayout(_ changes: () -> Void) {
        adjustingScale = true
        defer { adjustingScale = false }
        if let preservePosition { preservePosition(changes) }
        else { changes() }
    }

    private func clearBounds(in pdf: PDFDocument?) {
        guard let pdf else { return }
        for index in 0..<pdf.pageCount {
            (pdf.page(at: index) as? ReaderPage)?.readerContentBounds = nil
        }
    }

    private func restoreLayout() {
        guard let pdfView, let layout = originalLayout else { return }
        originalLayout = nil
        fittingWidth = false
        lastFittedScale = nil
        changeLayout {
            self.clearBounds(in: self.analyzedDocument)
            pdfView.readerModeActive = false
            pdfView.displayBox = layout.box
            pdfView.displayMode = layout.mode
            pdfView.displayDirection = layout.direction
            pdfView.displaysPageBreaks = layout.breaks
            pdfView.pageBreakMargins = layout.margins
            pdfView.autoScales = layout.autoScales
            if !layout.autoScales { pdfView.scaleFactor = layout.scale }
            pdfView.pageShadowsEnabled = !pdfView.isInverted
            pdfView.layoutDocumentView()
        }
    }

    private func fitWidth() {
        guard let pdfView, widthToFit > 0 else { return }
        lastViewportWidth = viewportWidth
        let available = max(lastViewportWidth - 32, 1)
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(available / widthToFit, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        lastFittedScale = pdfView.scaleFactor
    }

    private var viewportWidth: CGFloat {
        guard let pdfView else { return 0 }
        guard let clip = pdfView.documentView?.enclosingScrollView?.contentView else { return pdfView.bounds.width }
        // PDFKit scales the clip's bounds as it zooms. Convert its visible area
        // back to view points so zoom cannot feed back into the width calculation.
        return pdfView.convert(clip.bounds, from: clip).width
    }

    func zoomToFit() {
        guard isApplied else { return }
        fittingWidth = true
        changeLayout { self.fitWidth() }
    }

    func scaleDidChange() {
        guard !adjustingScale, let pdfView else { return }
        // PDFKit may deliver our own scale notification after the transaction.
        if let lastFittedScale, abs(pdfView.scaleFactor - lastFittedScale) < 0.000001 { return }
        manualZoomChosen()
    }

    func manualZoomChosen() {
        fittingWidth = false
        lastFittedScale = nil
    }

    func viewportDidChange() {
        guard isApplied, fittingWidth, !adjustingScale,
              abs(viewportWidth - lastViewportWidth) > 0.5 else { return }
        changeLayout { self.fitWidth() }
    }
}
