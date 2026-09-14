import AppKit
import GlassineCore
import PDFKit

/// Owns presentation crops, never a PDF mutation. Analysis uses immutable
/// CoreGraphics page references off the main thread; installation is one
/// transaction so neither scale nor earlier page heights change while reading.
@MainActor
final class ReaderModeController {
    private struct PageSnapshot: @unchecked Sendable {
        let page: CGPDFPage?
        let crop: CGRect
        let annotations: [CGRect]
    }
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
    private var contentBounds: [CGRect?]?
    private var analysis: Task<[CGRect?]?, Never>?
    private var generation = 0
    private var originalLayout: Layout?
    private var widthToFit: CGFloat = 0
    private var fittingWidth = false
    private var adjustingScale = false
    private var lastViewportWidth: CGFloat = 0
    private(set) var settings: ReaderModeSettings
    private(set) var isPreparing = false
    var onPreparationChanged: ((Bool) -> Void)?
    var preservePosition: ((_ changes: () -> Void) -> Void)?

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
        if !settings.automatic || contentBounds != nil { apply() }
        else { prepare() }
    }

    /// Called after the reader installs a new PDF (including revert), before
    /// its normal position restore. Discard old-page work and bounds.
    func documentDidChange() {
        cancelAnalysis()
        if analyzedDocument !== pdfView?.document {
            clearBounds(in: analyzedDocument)
            contentBounds = nil
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
        guard isEnabled, settings.automatic else { return }
        if isApplied, pages.allSatisfy({ page in
            guard let bounds = (page as? ReaderPage)?.readerContentBounds else { return false }
            return ReaderContentBounds.visibleAnnotationBounds(on: page).allSatisfy(bounds.contains)
        }) { return }
        // Highlights normally sit inside the existing ink, but annotations
        // imported into an outer margin must be included in the next crop.
        contentBounds = nil
        prepare()
    }

    private func preparing(_ value: Bool) {
        isPreparing = value
        onPreparationChanged?(value)
    }

    private func cancelAnalysis() {
        generation &+= 1
        analysis?.cancel()
        analysis = nil
        preparing(false)
    }

    private func prepare() {
        guard isEnabled, let pdf = pdfView?.document else { return }
        cancelAnalysis()
        if !settings.automatic || (analyzedDocument === pdf && contentBounds != nil) {
            apply()
            return
        }
        let snapshots = (0..<pdf.pageCount).compactMap { index -> PageSnapshot? in
            guard let page = pdf.page(at: index) else { return nil }
            return PageSnapshot(page: page.pageRef, crop: page.bounds(for: .cropBox),
                                annotations: ReaderContentBounds.visibleAnnotationBounds(on: page))
        }
        guard snapshots.count == pdf.pageCount else { return }
        preparing(true)
        let currentGeneration = generation
        let task = Task.detached(priority: .userInitiated) { () -> [CGRect?]? in
            var result: [CGRect?] = []
            result.reserveCapacity(snapshots.count)
            for snapshot in snapshots {
                guard !Task.isCancelled else { return nil }
                let bounds: CGRect? = autoreleasepool {
                    guard let page = snapshot.page else { return nil }
                    return ReaderContentBounds.detect(pageRef: page, cropBox: snapshot.crop,
                                                       annotationBounds: snapshot.annotations)
                }
                result.append(bounds)
            }
            return result
        }
        analysis = task
        Task { [weak self, weak pdf] in
            let result = await task.value
            guard let self, let pdf, self.generation == currentGeneration,
                  self.pdfView?.document === pdf, self.isEnabled, let result else { return }
            self.analysis = nil
            self.analyzedDocument = pdf
            self.contentBounds = result
            self.preparing(false)
            self.apply()
        }
    }

    private func apply() {
        guard isEnabled, let pdfView, let pdf = pdfView.document,
              !settings.automatic || contentBounds?.count == pdf.pageCount else { return }
        // A custom change supersedes an automatic scan still in flight.
        cancelAnalysis()
        var pages: [(ReaderPage, CGRect)] = []
        var widest: CGFloat = 0
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) as? ReaderPage else { return }
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
        lastViewportWidth = pdfView.bounds.width
        let available = max(lastViewportWidth - 32, 1)
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(available / widthToFit, pdfView.minScaleFactor), pdfView.maxScaleFactor)
    }

    func zoomToFit() {
        guard isApplied else { return }
        fittingWidth = true
        changeLayout { self.fitWidth() }
    }

    func scaleDidChange() {
        if !adjustingScale { fittingWidth = false }
    }

    func viewportDidChange() {
        guard isApplied, fittingWidth, !adjustingScale, let pdfView,
              abs(pdfView.bounds.width - lastViewportWidth) > 0.5 else { return }
        changeLayout { self.fitWidth() }
    }
}
