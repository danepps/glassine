import AppKit
import PDFKit

/// A hit-transparent sibling of PDFView, so the amber current-match marker
/// retains its colour when the PDF's dark-mode inversion filter is enabled.
/// Only the selected match is measured; the pulse runs on the compositor.
final class FindMatchIndicator: NSView {
    private weak var pdfView: PDFView?
    private weak var observedClip: NSClipView?
    private var lines: [(page: PDFPage, rect: CGRect)] = []
    let marker = CAShapeLayer()
    let pulse = CAShapeLayer()

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        let amber = NSColor(srgbRed: 1, green: 0.65, blue: 0.08, alpha: 1)
        marker.strokeColor = amber.cgColor
        marker.fillColor = amber.withAlphaComponent(0.12).cgColor
        marker.lineWidth = 2
        pulse.strokeColor = amber.cgColor
        pulse.fillColor = nil
        pulse.opacity = 0
        layer?.addSublayer(marker)
        layer?.addSublayer(pulse)
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged),
                                                  name: name, object: pdfView)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ selection: PDFSelection,
              reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        lines = selection.selectionsByLine().flatMap { line in
            line.pages.map { (page: $0, rect: line.bounds(for: $0)) }
        }
        observeScrolling()
        updateGeometry()
        pulse.removeAllAnimations()
        guard !reduceMotion, !lines.isEmpty else { return }

        // One gentle contraction/fade, with no PDF tile redraws or repeated
        // flashing. Rapid stepping replaces the old pulse immediately.
        let width = CABasicAnimation(keyPath: "lineWidth")
        width.fromValue = 10
        width.toValue = 2
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.85
        opacity.toValue = 0
        let animation = CAAnimationGroup()
        animation.animations = [width, opacity]
        animation.duration = 0.8
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.add(animation, forKey: "findNavigation")
    }

    func clear() {
        lines.removeAll()
        pulse.removeAllAnimations()
        updateGeometry()
        if let observedClip {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                      object: observedClip)
        }
        observedClip = nil
    }

    private func observeScrolling() {
        let clip = pdfView?.documentView?.enclosingScrollView?.contentView
        guard clip !== observedClip else { return }
        if let observedClip {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                      object: observedClip)
        }
        observedClip = clip
        if let clip {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged),
                                                  name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func geometryChanged() { updateGeometry() }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    private func updateGeometry() {
        let path = CGMutablePath()
        if let pdfView, let document = pdfView.document {
            for line in lines where line.page.document === document {
                let rect = convert(pdfView.convert(line.rect, from: line.page), from: pdfView)
                guard !rect.isEmpty, !rect.isInfinite, !rect.isNull else { continue }
                path.addRoundedRect(in: rect.insetBy(dx: -3, dy: -2),
                                    cornerWidth: 3, cornerHeight: 3)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marker.frame = bounds
        pulse.frame = bounds
        marker.path = path
        pulse.path = path
        CATransaction.commit()
    }
}
