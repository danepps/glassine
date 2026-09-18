import AppKit
import GlassineCore
import Testing
@testable import Glassine

@Test @MainActor func blurDraggingDoesNotRebuildDocumentAppearance() throws {
    _ = NSApplication.shared
    let name = "GlassineAppearanceUpdatesTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    let previous = Prefs.defaults
    Prefs.defaults = defaults
    defer {
        Prefs.defaults = previous
        defaults.removePersistentDomain(forName: name)
    }
    let document = GlassineDocument()
    defer { document.close() }
    let reader = ReaderViewController(document: document)
    _ = reader.view
    reader.viewWillAppear()
    var appearancePasses = 0
    reader.onInversionChanged = { _ in appearancePasses += 1 }
    for step in 0...100 { Prefs.windowBlurStrength = Double(step) / 100 }
    Prefs.interfaceOpacity = 0.3
    Prefs.windowOpacity = 0.72
    Prefs.toolbarTint = .blue
    #expect(appearancePasses == 0)
    Prefs.darkModeBrightness = 0.7
    #expect(appearancePasses == 1)
    Prefs.darkPaper = .gray
    #expect(appearancePasses == 2)
    Prefs.invertInDarkMode.toggle()
    #expect(appearancePasses == 3)
    Prefs.appearance = .dark
    #expect(appearancePasses == 4)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GLASSINE_RUN_MENU_TEST"] == "1"))
@MainActor func windowAppearanceSliderClicksInOpenMenu() throws {
    _ = NSApplication.shared
    let name = "GlassineOpenMenuTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    let previous = Prefs.defaults
    Prefs.defaults = defaults
    defer {
        Prefs.defaults = previous
        defaults.removePersistentDomain(forName: name)
    }
    Prefs.windowOpacity = 0.72
    Prefs.windowBlurStrength = 0.82
    let menu = NSMenu(title: "Slider fixture")
    let item = NSMenuItem(title: "Blur Strength", action: nil, keyEquivalent: "")
    let row = WindowAppearanceSliderView(target: .blur)
    item.view = row
    menu.addItem(item)
    let slider = try #require(row.subviews.compactMap { $0 as? NSSlider }.first)
    var phase = 0
    var sent = 0
    let tick: @MainActor @Sendable () -> Void = {
        phase += 1
        guard phase < 8, let window = row.window else {
            menu.cancelTracking()
            return
        }
        row.layoutSubtreeIfNeeded()
        if phase == 1 {
            return
        }
        let type: NSEvent.EventType
        let fraction: CGFloat
        switch phase {
        case 2: type = .leftMouseDown; fraction = 0.82
        case 3: type = .leftMouseDragged; fraction = 0.6
        case 4: type = .leftMouseDragged; fraction = 0.4
        case 5: type = .leftMouseUp; fraction = 0.4
        default: return
        }
        let point = slider.convert(NSPoint(x: slider.bounds.width * fraction,
                                           y: slider.bounds.midY), to: nil)
        if let event = NSEvent.mouseEvent(with: type, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: phase, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
            NSApp.postEvent(event, atStart: false)
            sent += 1
        }
    }
    let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
        MainActor.assumeIsolated { tick() }
    }
    RunLoop.main.add(timer, forMode: .eventTracking)
    defer { timer.invalidate() }
    menu.popUp(positioning: item, at: NSPoint(x: 200, y: 400), in: nil)
    #expect(sent == 4)
    #expect(Prefs.windowBlurStrength < 0.5)
}

@Test @MainActor func windowAppearanceSliderTracksSmallDragSteps() throws {
    _ = NSApplication.shared
    let name = "GlassineSliderDragTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    let previous = Prefs.defaults
    Prefs.defaults = defaults
    defer {
        Prefs.defaults = previous
        defaults.removePersistentDomain(forName: name)
    }
    Prefs.windowOpacity = 0.72
    Prefs.windowBlurStrength = 0.82
    let view = WindowAppearanceSliderView(target: .blur)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    view.layoutSubtreeIfNeeded()
    let slider = try #require(view.subviews.compactMap { $0 as? NSSlider }.first)
    let cell = try #require(slider.cell as? NSSliderCell)
    let knob = cell.knobRect(flipped: slider.isFlipped)
    let start = NSPoint(x: knob.midX, y: knob.midY)
    #expect(cell.startTracking(at: start, in: slider))
    var last = start
    for step in 1...100 {
        let next = NSPoint(x: start.x - Double(step) * 0.2, y: start.y)
        #expect(cell.continueTracking(last: last, current: next, in: slider))
        #expect(NSApp.sendAction(try #require(slider.action), to: slider.target, from: slider))
        last = next
    }
    cell.stopTracking(last: last, current: last, in: slider, mouseIsUp: true)
    #expect(Prefs.windowBlurStrength < 0.75)
}

@Test @MainActor func windowAppearanceControlsKeepBlurAndOpacityIndependent() throws {
    _ = NSApplication.shared
    let name = "GlassineAppearanceControlsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    let previous = Prefs.defaults
    Prefs.defaults = defaults
    defer {
        Prefs.defaults = previous
        defaults.removePersistentDomain(forName: name)
    }
    let delegate = AppDelegate(startingUpdater: false)
    let toggle = NSMenuItem(title: "Blur Behind Window",
                            action: #selector(AppDelegate.toggleWindowBlur(_:)), keyEquivalent: "")
    let view = WindowAppearanceSliderView(target: .blur)
    let slider = try #require(view.subviews.compactMap { $0 as? NSSlider }.first)
    #expect(!slider.isEnabled)
    Prefs.windowOpacity = 0.45
    Prefs.interfaceOpacity = 0.3
    #expect(slider.isEnabled)
    Prefs.windowBlur = false
    #expect(slider.doubleValue == 0)

    slider.doubleValue = 0.803
    #expect(NSApp.sendAction(try #require(slider.action), to: slider.target, from: slider))
    #expect(slider.doubleValue == 0.803, "Saved rounding must not reset a tracking knob")
    #expect(Prefs.windowBlur && Prefs.windowBlurStrength == 0.8)
    #expect(Prefs.windowOpacity == 0.45 && Prefs.interfaceOpacity == 0.3)
    delegate.toggleWindowBlur(toggle)
    #expect(!Prefs.windowBlur && Prefs.windowBlurStrength == 0.8)
    #expect(slider.doubleValue == 0)
    delegate.toggleWindowBlur(toggle)
    #expect(Prefs.windowBlur && slider.doubleValue == 0.8)

    slider.doubleValue = 0
    #expect(NSApp.sendAction(try #require(slider.action), to: slider.target, from: slider))
    #expect(delegate.validateMenuItem(toggle))
    #expect(toggle.state == .off)
    delegate.toggleWindowBlur(toggle)
    #expect(Prefs.windowBlurStrength == 0.5 && slider.doubleValue == 0.5)

    Prefs.windowOpacity = 1
    Prefs.interfaceOpacity = 1
    #expect(!slider.isEnabled)
    Prefs.interfaceOpacity = 0.5
    #expect(slider.isEnabled)
}
