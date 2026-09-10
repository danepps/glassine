import AppKit
import GlassineCore

/// Own the backing in the public content hierarchy. AppKit owns everything
/// above it, including the tab bar and its hover glass. Inserting views into
/// the private title-bar hierarchy and using CGS window blur are suspected
/// contributors to the recurring tab rendering failures on macOS 26.
final class WindowChromeContentController: NSViewController {
    let body: NSViewController
    let blur = NSVisualEffectView()
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

        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        titlebarBacking.wantsLayer = true
        for child in [blur, titlebarBacking, body.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }

        // The window's layout guide must share a hierarchy with the body
        // before its constraint is activated.
        window.contentViewController = self

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            blur.topAnchor.constraint(equalTo: root.topAnchor),
            blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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

enum WindowChrome {
    static func apply(to window: NSWindow) {
        guard let host = window.contentViewController as? WindowChromeContentController else { return }
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let level = Prefs.darkPaper
        let paper: NSColor = (level != .black && Prefs.invertInDarkMode)
            ? NSColor(white: level.lift, alpha: 1) : .black
        let color: NSColor = dark ? paper : .white
        let opacity = Prefs.windowOpacity
        let translucent = opacity < Prefs.maxWindowOpacity

        window.titlebarAppearsTransparent = dark || translucent
        window.titlebarSeparatorStyle = (dark || translucent) ? .none : .automatic
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : (dark ? paper : .windowBackgroundColor)

        // Only the document fades. The behind-window material and chrome
        // backing remain separate siblings with unit view alpha so AppKit can
        // composite its tab hover effects over them normally.
        host.body.view.wantsLayer = true
        host.body.view.alphaValue = translucent ? opacity : 1
        host.blur.isHidden = !translucent || !Prefs.windowBlur
        host.titlebarBacking.isHidden = !dark && !translucent
        host.titlebarBacking.layer?.backgroundColor = color.withAlphaComponent(translucent ? opacity : 1).cgColor
    }
}
