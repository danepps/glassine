import AppKit
import GlassineCore
import Testing
@testable import Glassine

@Test @MainActor
func chromeBackingSurvivesTabAndAppearanceChanges() throws {
    _ = NSApplication.shared
    let suiteName = "GlassineChromeTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let previous = Prefs.defaults
    Prefs.defaults = defaults
    defer {
        Prefs.defaults = previous
        defaults.removePersistentDomain(forName: suiteName)
    }

    var windows: [NSWindow] = []
    defer { windows.forEach { $0.close() } }
    for index in 0..<3 {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Chrome fixture \(index)"
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "GlassineChromeTests"
        window.toolbar = NSToolbar(identifier: "ChromeFixture.\(index)")
        window.toolbarStyle = .unified
        let body = NSViewController()
        body.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        WindowChromeContentController.install(in: window, body: body)
        windows.append(window)
    }

    // Exercise AppKit's real tab-group handoff, including hidden windows.
    windows[0].addTabbedWindow(windows[1], ordered: .above)
    windows[1].addTabbedWindow(windows[2], ordered: .above)
    let group = try #require(windows[2].tabGroup)
    #expect(group.windows.count == 3)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for opacity in [1.0, 0.88, 0.6, 0.3] {
            for blur in [true, false] {
                Prefs.windowOpacity = opacity
                Prefs.windowBlur = blur
                for window in windows {
                    window.appearance = NSAppearance(named: appearance)
                    group.selectedWindow = window
                    window.setContentSize(NSSize(width: 700 + opacity * 100, height: 500))
                    WindowChrome.apply(to: window)
                    window.contentView?.layoutSubtreeIfNeeded()
                    let host = try #require(window.contentViewController as? WindowChromeContentController)
                    #expect(host.blur.superview === window.contentView)
                    #expect(host.titlebarBacking.superview === window.contentView)
                    // AppKit quantizes view opacity; hidden tabs need not
                    // round-trip the exact Double passed to the setter.
                    #expect(abs(host.body.view.alphaValue - opacity) < 0.0001)
                    #expect(host.view.alphaValue == 1)
                    #expect(host.blur.alphaValue == 1)
                    #expect(host.blur.isHidden == (opacity == 1 || !blur))
                    #expect(window.isOpaque == (opacity == 1))
                    let body = host.body.view.convert(host.body.view.bounds, to: nil)
                    let band = host.titlebarBacking.convert(host.titlebarBacking.bounds, to: nil)
                    #expect(abs(body.maxY - window.contentLayoutRect.maxY) < 1)
                    #expect(abs(band.minY - body.maxY) < 1)
                    #expect(band.height > 0)
                    #expect(abs(band.maxY - window.frame.height) < 1)
                    #expect(!host.view.hasAmbiguousLayout)
                }
            }
        }
    }
    // Detaching a tab must keep its own backing and restore the content guide.
    group.removeWindow(windows[1])
    windows[1].contentView?.layoutSubtreeIfNeeded()
    let detached = try #require(windows[1].contentViewController as? WindowChromeContentController)
    #expect(detached.titlebarBacking.superview === windows[1].contentView)
    let body = detached.body.view.convert(detached.body.view.bounds, to: nil)
    #expect(abs(body.maxY - windows[1].contentLayoutRect.maxY) < 1)
}
