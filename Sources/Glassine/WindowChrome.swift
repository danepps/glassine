import AppKit
import GlassineCore

/// Own the backing in the public content hierarchy. AppKit owns everything
/// above it, including the tab bar and its hover glass. Inserting views into
/// the private title-bar hierarchy and using CGS window blur are suspected
/// contributors to the recurring tab rendering failures on macOS 26.
final class WindowChromeContentController: NSViewController {
    let body: NSViewController
    let documentBlur = WindowBackdropView()
    let titlebarBlur = WindowBackdropView()
    let titlebarBacking = NSView()

    static func install(in window: NSWindow, body: NSViewController) {
        _ = WindowChromeContentController(window: window, body: body)
    }

    private init(window: NSWindow, body: NSViewController) {
        self.body = body
        super.init(nibName: nil, bundle: nil)

        let root = ChromeContentView(frame: body.view.frame)
        root.wantsLayer = true
        view = root
        addChild(body)

        titlebarBacking.wantsLayer = true
        for child in [documentBlur, titlebarBlur, titlebarBacking, body.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }

        // The window's layout guide must share a hierarchy with the body
        // before its constraint is activated.
        window.contentViewController = self

        NSLayoutConstraint.activate([
            documentBlur.leadingAnchor.constraint(equalTo: body.view.leadingAnchor),
            documentBlur.trailingAnchor.constraint(equalTo: body.view.trailingAnchor),
            documentBlur.topAnchor.constraint(equalTo: body.view.topAnchor),
            documentBlur.bottomAnchor.constraint(equalTo: body.view.bottomAnchor),
            titlebarBlur.leadingAnchor.constraint(equalTo: titlebarBacking.leadingAnchor),
            titlebarBlur.trailingAnchor.constraint(equalTo: titlebarBacking.trailingAnchor),
            titlebarBlur.topAnchor.constraint(equalTo: titlebarBacking.topAnchor),
            titlebarBlur.bottomAnchor.constraint(equalTo: titlebarBacking.bottomAnchor),
            body.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // Do not put PDF pixels beneath the glass: AppKit can sample them
            // before the PDF's dark-mode inversion filter is applied.
            NSLayoutConstraint(item: body.view, attribute: .top, relatedBy: .equal,
                               toItem: window.contentLayoutGuide, attribute: .top,
                               multiplier: 1, constant: 0),
            titlebarBacking.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebarBacking.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titlebarBacking.topAnchor.constraint(equalTo: root.topAnchor),
            titlebarBacking.bottomAnchor.constraint(equalTo: body.view.topAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class ChromeContentView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let window { WindowChrome.apply(to: window) }
    }
}

/// Show the interior of an oversized backdrop, clipping its refractive edges
/// outside the visible region. Scale only its coordinate system to vary blur;
/// foreground views keep their geometry and effect alpha stays at one.
final class WindowBackdropView: NSView {
    let effect = WindowChrome.makeBackdrop()
    private let coordinateSpace = NSView()
    var strength = Prefs.defaultWindowBlurStrength {
        didSet { if strength != oldValue { needsLayout = true } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(coordinateSpace)
        coordinateSpace.addSubview(effect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        // A wider radius range makes the upper half useful for hiding text.
        // Bound the minimum scale to avoid enormous virtual backing sizes.
        let scale = CGFloat(0.1 + 3.9 * strength)
        // Clear glass bends background pixels near its physical edges. Keep
        // those edges well outside our clipped viewport, including the seam
        // between the document and toolbar. Padding scales with the effect.
        let padding: CGFloat = 64 * scale
        coordinateSpace.frame = bounds.insetBy(dx: -padding, dy: -padding)
        coordinateSpace.setBoundsSize(NSSize(width: coordinateSpace.frame.width / scale,
                                             height: coordinateSpace.frame.height / scale))
        // Transform a plain parent view, leaving the glass view's own frame
        // and bounds equal. Changing glass bounds alone leaves its cached
        // material mask at the old size during live slider changes.
        effect.frame = coordinateSpace.bounds
        effect.setBoundsSize(coordinateSpace.bounds.size)
        effect.needsLayout = true
        effect.layoutSubtreeIfNeeded()
    }
}

@MainActor enum WindowChrome {
    static func makeBackdrop() -> NSView {
        if #available(macOS 26.0, *) {
            // Clear glass preserves the background's colour while blurring
            // detail. The standard under-window material can become a nearly
            // solid sheet on modern macOS. Supply our colour separately.
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = 0
            return glass
        }

        // Older systems retain AppKit's standard behind-window material.
        let blur = NSVisualEffectView()
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        return blur
    }

    /// Every tint has a light and a dark variant. One colour extends through
    /// the toolbar and tab band; paper and document colours remain separate.
    nonisolated static func backgroundColor(dark: Bool, tint: ToolbarTint = Prefs.toolbarTint) -> NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch (tint, dark) {
        case (.seaGlass, false): rgb = (0.88, 0.93, 0.915)
        case (.seaGlass, true): rgb = (0.035, 0.065, 0.06)
        case (.blue, false): rgb = (0.875, 0.91, 0.96)
        case (.blue, true): rgb = (0.035, 0.055, 0.10)
        case (.lavender, false): rgb = (0.925, 0.895, 0.97)
        case (.lavender, true): rgb = (0.07, 0.04, 0.10)
        case (.rose, false): rgb = (0.96, 0.895, 0.905)
        case (.rose, true): rgb = (0.10, 0.04, 0.055)
        case (.sand, false): rgb = (0.95, 0.925, 0.865)
        case (.sand, true): rgb = (0.09, 0.07, 0.035)
        case (.graphite, false): rgb = (0.92, 0.92, 0.92)
        case (.graphite, true): rgb = (0.055, 0.055, 0.055)
        }
        let lift = dark && Prefs.invertInDarkMode ? Prefs.darkPaper.lift : 0
        return NSColor(srgbRed: lift + rgb.0, green: lift + rgb.1,
                       blue: lift + rgb.2, alpha: 1)
    }

    static func apply(to window: NSWindow) {
        guard let host = window.contentViewController as? WindowChromeContentController else { return }
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = backgroundColor(dark: dark)
        let translucent = Prefs.hasWindowTransparency

        // Use the same backing even at full opacity in light mode; otherwise
        // AppKit reinstates a separate standard toolbar surface and rule.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : color

        // Opacity belongs to the foreground surface, never the backdrop effect:
        // reducing the effect view's alpha lets sharp background pixels through
        // and can disable the compositor's blur entirely. Separate regions keep
        // toolbar transparency out of the document. The host and native controls
        // also stay at unit alpha for tab compositing and legible labels.
        host.body.view.wantsLayer = true
        host.body.view.alphaValue = Prefs.windowOpacity
        for (blur, opacity) in [(host.documentBlur, Prefs.windowOpacity),
                                (host.titlebarBlur, Prefs.interfaceOpacity)] {
            blur.alphaValue = 1
            blur.strength = Prefs.windowBlurStrength
            blur.isHidden = opacity == Prefs.maxWindowOpacity || !Prefs.windowBlur
                || Prefs.windowBlurStrength == 0
        }
        host.titlebarBacking.isHidden = false
        host.titlebarBacking.layer?.backgroundColor = color.withAlphaComponent(Prefs.interfaceOpacity).cgColor
    }
}
