import AppKit
import CoreImage
import GlassineCore
import PDFKit

/// PDFView with two additions: it reports effective-appearance changes
/// (NSViewController has no hook for that -- only NSView does), and the arrow
/// keys always move a whole page instead of scrolling by a line.
final class ReaderPDFView: PDFView {
    var onEffectiveAppearanceChange: (() -> Void)?

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
}


/// Hosts the PDFView and owns the light/dark rendering decision for its window.
final class ReaderViewController: NSViewController {

    let pdfView = ReaderPDFView()
    private let glassineDocument: GlassineDocument

    /// True when pages are being shown light-on-dark.
    private(set) var isInverted = false

    /// Called after every appearance pass with the current inversion state, so
    /// the window can keep the sidebar and the find highlights in step.
    var onInversionChanged: ((Bool) -> Void)?

    /// Luminance inversion that keeps hues: invert, then rotate hue 180 degrees,
    /// so blue links stay blue instead of turning orange. Above Black paper a
    /// third stage compresses the result into `[lift, top]`, lifting the page
    /// off pure black without touching the light-mode path.
    /// CIFilters are mutable objects, so each view gets its own chain rather
    /// than sharing one static set across windows and the sidebar.
    static func makeDarkFilters() -> [CIFilter] {
        guard let invert = CIFilter(name: "CIColorInvert"),
              let hue = CIFilter(name: "CIHueAdjust") else { return [] }
        hue.setValue(Float.pi, forKey: "inputAngle")

        let paper = Prefs.darkPaper
        guard paper != .black, let compress = CIFilter(name: "CIColorMatrix") else {
            return [invert, hue]
        }
        // out = lift + (top - lift) * in, per channel, in the linear light the
        // layer filters work in (same reason the gutter is 0.997 pre-filter), so
        // the levels are converted from the screen values they are written as.
        let lift = linearLight(paper.lift)
        let span = linearLight(paper.top) - lift
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
        view = pdfView
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

    @objc private func prefsChanged() {
        applyAppearance()
    }

    // MARK: Appearance

    private func applyAppearance() {
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
        pdfView.pageShadowsEnabled = !invert

        if isInverted != invert {
            isInverted = invert
        }
        onInversionChanged?(invert)
    }

    // MARK: Actions

    @objc func zoomToFit(_ sender: Any?) {
        pdfView.autoScales = true
    }

    @objc func actualSize(_ sender: Any?) {
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
    }

    /// A PDF, and a Markdown document already laid out as pages, print exactly
    /// what is on screen. A *continuous* Markdown render does not: it is one
    /// 612 × 13,757 pt page, and handing that to the print system leaves the
    /// pagination to whatever scaling it decides on. So it goes through the same
    /// paginated typesetting Export as PDF uses, and the print panel is given a
    /// real Letter document.
    @objc func printDocument(_ sender: Any?) {
        guard glassineDocument.needsPaginatedOutput, let window = view.window else {
            pdfView.print(with: NSPrintInfo.shared, autoRotate: true)
            return
        }
        glassineDocument.paginatedDocumentForOutput { [weak self] result in
            switch result {
            case .success(let document):
                // .pageScaleNone: the pages are already the paper's size, and
                // "fit to page" would inset them by the printer's margins twice.
                guard let operation = document.printOperation(for: NSPrintInfo.shared,
                                                              scalingMode: .pageScaleNone,
                                                              autoRotate: true)
                else { return }
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            case .failure(let error):
                self?.glassineDocument.presentError(error)
            }
        }
    }
}
