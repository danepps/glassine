import AppKit
import PDFKit
import Sparkle

/// The whole menu bar, built in code. Items use a nil target so they travel the
/// responder chain (PDFView, the window controller, the document, the app) and
/// disable themselves automatically when nothing implements them.
enum MainMenu {

    static func build(appDelegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu(appMenu(appDelegate: appDelegate,
                                     updater: appDelegate.updaterController)))
        main.addItem(submenu(fileMenu(appDelegate: appDelegate)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu(appDelegate: appDelegate)))
        main.addItem(submenu(goMenu()))

        let windows = windowMenu()
        main.addItem(submenu(windows))
        NSApp.windowsMenu = windows

        let help = NSMenu(title: "Help")
        main.addItem(submenu(help))
        NSApp.helpMenu = help

        return main
    }

    // MARK: Builders

    private static let upArrowKey = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downArrowKey = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil,
        tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = target
        item.tag = tag
        menu.addItem(item)
        return item
    }

    // MARK: Menus

    private static func appMenu(appDelegate: AppDelegate,
                                updater: SPUStandardUpdaterController) -> NSMenu {
        let menu = NSMenu(title: "Glassine")
        add(menu, "About Glassine", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        // Explicit target: Sparkle's controller is not in the responder chain.
        add(menu, "Check for Updates…",
            #selector(SPUStandardUpdaterController.checkForUpdates(_:)), target: updater)
        menu.addItem(.separator())
        // Explicit target: the app delegate is in the responder chain, but only
        // behind the document, and this item is about the app, not a document.
        add(menu, "Use Glassine to Open Markdown Files",
            #selector(AppDelegate.makeDefaultMarkdownApp(_:)), target: appDelegate)
        menu.addItem(.separator())
        add(menu, "Hide Glassine", #selector(NSApplication.hide(_:)), key: "h")
        add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
            key: "h", modifiers: [.command, .option])
        add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "Quit Glassine", #selector(NSApplication.terminate(_:)), key: "q")
        return menu
    }

    private static func fileMenu(appDelegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        add(menu, "Open…", #selector(NSDocumentController.openDocument(_:)), key: "o")
        // Explicit target: the Recents window is the app's, not a document's.
        add(menu, "Recents…", #selector(AppDelegate.showRecents(_:)),
            key: "o", modifiers: [.command, .shift], target: appDelegate)

        // AppKit populates and maintains this submenu once it contains the
        // standard "Clear Menu" item.
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        add(recentMenu, "Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
        recent.submenu = recentMenu
        menu.addItem(recent)

        menu.addItem(.separator())
        add(menu, "New Tab", #selector(NSWindow.newWindowForTab(_:)), key: "t")
        add(menu, "Close", #selector(NSWindow.performClose(_:)), key: "w")
        menu.addItem(.separator())
        add(menu, "Print…", #selector(NSDocument.printDocument(_:)), key: "p")
        menu.addItem(.separator())
        // ⇧⌘E because ⌘E is Use Selection for Find.
        add(menu, "Export as PDF…", #selector(GlassineDocument.exportAsPDF(_:)),
            key: "e", modifiers: [.command, .shift])
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // Standard items with nil targets: the responder chain (search field,
        // page field, PDFView) supplies and validates each one.
        add(menu, "Undo", Selector(("undo:")), key: "z")
        add(menu, "Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Cut", #selector(NSText.cut(_:)), key: "x")
        add(menu, "Copy", #selector(NSText.copy(_:)), key: "c")
        add(menu, "Paste", #selector(NSText.paste(_:)), key: "v")
        add(menu, "Delete", #selector(NSText.delete(_:)))
        add(menu, "Select All", #selector(NSText.selectAll(_:)), key: "a")
        menu.addItem(.separator())
        add(menu, "Find…", #selector(ReaderWindowController.focusSearch(_:)), key: "f")
        add(menu, "Find Next", #selector(ReaderWindowController.findNext(_:)), key: "g")
        add(menu, "Find Previous", #selector(ReaderWindowController.findPrevious(_:)), key: "g",
            modifiers: [.command, .shift])
        add(menu, "Use Selection for Find", #selector(ReaderWindowController.useSelectionForFind(_:)), key: "e")
        return menu
    }

    private static func viewMenu(appDelegate: AppDelegate) -> NSMenu {
        // Must be titled "View": AppKit appends the tab-bar items (Show Tab Bar,
        // Show All Tabs) to the menu with this title.
        let menu = NSMenu(title: "View")
        add(menu, "Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)),
            key: "s", modifiers: [.command, .control])
        // Preview's shortcuts for the same two panes.
        add(menu, "Thumbnails", #selector(ReaderWindowController.showThumbnails(_:)),
            key: "2", modifiers: [.command, .option])
        add(menu, "Table of Contents", #selector(ReaderWindowController.showOutline(_:)),
            key: "3", modifiers: [.command, .option])
        menu.addItem(.separator())
        add(menu, "Zoom In", #selector(PDFView.zoomIn(_:)), key: "=")
        add(menu, "Zoom Out", #selector(PDFView.zoomOut(_:)), key: "-")
        add(menu, "Zoom to Fit", #selector(ReaderViewController.zoomToFit(_:)), key: "0")
        add(menu, "Actual Size", #selector(ReaderViewController.actualSize(_:)), key: "1")
        menu.addItem(.separator())

        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        add(appearanceMenu, "System", #selector(AppDelegate.setAppearance(_:)),
            target: appDelegate, tag: AppearanceMode.system.rawValue)
        add(appearanceMenu, "Light", #selector(AppDelegate.setAppearance(_:)),
            target: appDelegate, tag: AppearanceMode.light.rawValue)
        add(appearanceMenu, "Dark", #selector(AppDelegate.setAppearance(_:)),
            target: appDelegate, tag: AppearanceMode.dark.rawValue)
        appearanceMenu.addItem(.separator())
        for paper in [DarkPaper.black, .charcoal, .gray] {
            add(appearanceMenu, paper.title, #selector(AppDelegate.setDarkPaper(_:)),
                target: appDelegate, tag: paper.rawValue)
        }
        appearance.submenu = appearanceMenu
        menu.addItem(appearance)

        add(menu, "Invert Page Colors in Dark Mode",
            #selector(AppDelegate.toggleInvertInDarkMode(_:)), target: appDelegate)

        let opacity = NSMenuItem(title: "Window Opacity", action: nil, keyEquivalent: "")
        opacity.view = OpacityMenuItemView()
        menu.addItem(opacity)
        add(menu, "Blur Behind Window", #selector(AppDelegate.toggleWindowBlur(_:)),
            target: appDelegate)
        add(menu, "Increase Opacity", #selector(AppDelegate.increaseOpacity(_:)),
            key: upArrowKey, modifiers: [.command, .option], target: appDelegate)
        add(menu, "Decrease Opacity", #selector(AppDelegate.decreaseOpacity(_:)),
            key: downArrowKey, modifiers: [.command, .option], target: appDelegate)

        let markdown = NSMenuItem(title: "Markdown", action: nil, keyEquivalent: "")
        let markdownMenu = NSMenu(title: "Markdown")
        for layout in [MarkdownLayout.pages, .continuous] {
            add(markdownMenu, layout.title, #selector(AppDelegate.setMarkdownLayout(_:)),
                target: appDelegate, tag: layout.rawValue)
        }
        markdownMenu.addItem(.separator())

        let style = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu(title: "Style")
        // Rebuilt every time it opens, so a .css file dropped into the Styles
        // folder appears without a relaunch.
        styleMenu.identifier = markdownStyleMenuIdentifier
        styleMenu.delegate = appDelegate
        populateMarkdownStyleMenu(styleMenu, appDelegate: appDelegate)
        style.submenu = styleMenu
        markdownMenu.addItem(style)

        markdownMenu.addItem(.separator())
        for size in Prefs.markdownFontSizes {
            add(markdownMenu, "\(size) pt", #selector(AppDelegate.setMarkdownFontSize(_:)),
                target: appDelegate, tag: size)
        }
        markdown.submenu = markdownMenu
        menu.addItem(markdown)
        menu.addItem(.separator())
        add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)),
            key: "f", modifiers: [.command, .control])
        return menu
    }

    /// Marks the one menu the app delegate rebuilds in `menuNeedsUpdate`.
    static let markdownStyleMenuIdentifier = NSUserInterfaceItemIdentifier("glassine.markdownStyle")

    /// Fill View ▸ Markdown ▸ Style: the built-ins, then whatever `.css` files
    /// are in the Styles folder right now, then the way to that folder. The
    /// style's id rides on `representedObject`, since ids are strings and a
    /// menu item's tag is not.
    static func populateMarkdownStyleMenu(_ menu: NSMenu, appDelegate: AppDelegate) {
        menu.removeAllItems()
        let action = #selector(AppDelegate.setMarkdownStyle(_:))
        for style in MarkdownStyle.builtIns {
            add(menu, style.title, action, target: appDelegate).representedObject = style.id
        }
        let custom = MarkdownStyle.customStyles()
        if !custom.isEmpty {
            menu.addItem(.separator())
            for style in custom {
                add(menu, style.title, action, target: appDelegate).representedObject = style.id
            }
        }
        menu.addItem(.separator())
        add(menu, "Open Styles Folder…",
            #selector(AppDelegate.openMarkdownStylesFolder(_:)), target: appDelegate)
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        add(menu, "Previous Page", #selector(PDFView.goToPreviousPage(_:)))
        add(menu, "Next Page", #selector(PDFView.goToNextPage(_:)))
        add(menu, "First Page", #selector(PDFView.goToFirstPage(_:)))
        add(menu, "Last Page", #selector(PDFView.goToLastPage(_:)))
        menu.addItem(.separator())
        add(menu, "Go to Page…", #selector(ReaderWindowController.focusPageField(_:)), key: "g",
            modifiers: [.command, .option])
        menu.addItem(.separator())
        add(menu, "Back", #selector(PDFView.goBack(_:)), key: "[")
        add(menu, "Forward", #selector(PDFView.goForward(_:)), key: "]")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }
}

/// The View ▸ Window Opacity row: caption, slider, live percentage. A menu item
/// with a custom view draws none of the usual chrome, so the leading inset is
/// hand-matched to the title inset of the plain items around it.
final class OpacityMenuItemView: NSView {

    private let slider = NSSlider()
    private let percentLabel = NSTextField(labelWithString: "100%")

    init() {
        super.init(frame: .zero)

        let menuFont = NSFont.menuFont(ofSize: 0)
        let caption = NSTextField(labelWithString: "Opacity")
        caption.font = menuFont
        caption.textColor = .labelColor
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: menuFont.pointSize,
                                                             weight: .regular)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .right

        slider.minValue = Prefs.minWindowOpacity
        slider.maxValue = Prefs.maxWindowOpacity
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.setAccessibilityLabel("Window opacity")

        for subview in [caption, slider, percentLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            caption.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 10),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: 150),
            percentLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 10),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])

        // A menu sizes an item's view from its frame, not its constraints.
        frame = NSRect(origin: .zero, size: fittingSize)
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The menu builds a fresh window every time it opens, so this is where the
    /// row picks up an opacity the keyboard shortcuts changed behind its back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { sync() }
    }

    private func sync() {
        slider.doubleValue = Prefs.windowOpacity
        showPercent(Prefs.windowOpacity)
    }

    private func showPercent(_ value: Double) {
        percentLabel.stringValue = "\(Int((value * 100).rounded()))%"
    }

    @objc private func sliderMoved() {
        Prefs.windowOpacity = slider.doubleValue
        showPercent(slider.doubleValue)
    }
}

