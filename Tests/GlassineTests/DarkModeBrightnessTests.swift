import AppKit
import CoreImage
import GlassineCore
import Testing
@testable import Glassine

@Suite("Dark mode brightness", .serialized) @MainActor
struct DarkModeBrightnessTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "GlassineBrightnessTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let previous = Prefs.defaults
        Prefs.defaults = defaults
        defer {
            Prefs.defaults = previous
            defaults.removePersistentDomain(forName: name)
        }
        try body(defaults)
    }

    @Test("Brightness persists, clamps finite values, and rejects invalid saved data")
    func persistenceAndValidation() throws {
        try withDefaults { defaults in
            #expect(Prefs.darkModeBrightness == 1)
            for (requested, expected) in [(0.35, 0.35), (0.72, 0.72), (1.0, 1.0),
                                           (0.1, 0.35), (4.0, 1.0), (0.716, 0.72)] {
                Prefs.darkModeBrightness = requested
                #expect(Prefs.darkModeBrightness == expected)
                #expect(defaults.double(forKey: "darkModeBrightness") == expected)
            }
            for invalid in [Double.nan, Double.infinity, -Double.infinity] {
                Prefs.darkModeBrightness = invalid
                #expect(Prefs.darkModeBrightness == 1)
                defaults.set(invalid, forKey: "darkModeBrightness")
                #expect(Prefs.darkModeBrightness == 1)
            }
            defaults.set("broken", forKey: "darkModeBrightness")
            #expect(Prefs.darkModeBrightness == 1)
            defaults.set(-5.0, forKey: "darkModeBrightness")
            #expect(Prefs.darkModeBrightness == Prefs.minDarkModeBrightness)
            defaults.set(50.0, forKey: "darkModeBrightness")
            #expect(Prefs.darkModeBrightness == Prefs.maxDarkModeBrightness)

            // The preference is app-wide and independent of whether inversion
            // is currently enabled or which paper the user selected.
            Prefs.invertInDarkMode = false
            Prefs.darkPaper = .gray
            Prefs.darkModeBrightness = 0.62
            #expect(!Prefs.invertInDarkMode && Prefs.darkPaper == .gray)
            #expect(Prefs.darkModeBrightness == 0.62)
            Prefs.invertInDarkMode = true
            Prefs.darkPaper = .black
            #expect(Prefs.darkModeBrightness == 0.62)
        }
    }

    @Test("Normal brightness preserves the original filter chain and all paper levels")
    func normalAppearanceIsUnchanged() throws {
        try withDefaults { _ in
            for paper in [DarkPaper.black, .charcoal, .gray] {
                Prefs.darkPaper = paper
                Prefs.darkModeBrightness = 1
                let filters = ReaderViewController.makeDarkFilters()
                #expect(filters.map(\.name) == (paper == .black
                    ? ["CIColorInvert", "CIHueAdjust"]
                    : ["CIColorInvert", "CIHueAdjust", "CIColorMatrix"]))
                let angle = try #require(filters[1].value(forKey: "inputAngle") as? NSNumber)
                #expect(angle.floatValue == Float.pi)
                if paper != .black {
                    try verifyMatrix(try #require(filters.last), lift: paper.lift, top: paper.top)
                }
            }
        }
    }

    @Test("Every paper keeps its background as text, images, and highlights dim")
    func renderedEndpointsAndAlpha() throws {
        try withDefaults { _ in
            for paper in [DarkPaper.black, .charcoal, .gray] {
                Prefs.darkPaper = paper
                for brightness in [Prefs.minDarkModeBrightness, 0.65, 1.0] {
                    Prefs.darkModeBrightness = brightness
                    let filters = ReaderViewController.makeDarkFilters()
                    let top = paper.lift + CGFloat(brightness) * (paper.top - paper.lift)
                    if filters.count == 3 {
                        try verifyMatrix(try #require(filters.last), lift: paper.lift, top: top)
                    }
                    let paperPixel = try render(filters, rgba: [1, 1, 1, 1])
                    let textPixel = try render(filters, rgba: [0, 0, 0, 1])
                    for channel in 0..<3 {
                        #expect(abs(CGFloat(paperPixel[channel]) / 255 - paper.lift) < 0.009)
                        #expect(abs(CGFloat(textPixel[channel]) / 255 - top) < 0.009)
                    }
                    let transparentPixel = try render(filters, rgba: [0.1, 0.4, 0.8, 0.5])
                    #expect(abs(Int(transparentPixel[3]) - 128) <= 1)
                    #expect(paperPixel[3] == 255 && textPixel[3] == 255)
                }
            }
        }
    }

    @Test("Menu slider updates the preference immediately and Reset restores Normal")
    func menuInteraction() throws {
        _ = NSApplication.shared
        try withDefaults { _ in
            Prefs.darkModeBrightness = 0.68
            let item = DarkModeBrightnessMenu.makeMenuItem()
            let view = try #require(item.view)
            let slider = try #require(view.subviews.compactMap { $0 as? NSSlider }.first)
            let reset = try #require(view.subviews.compactMap { $0 as? NSButton }.first)
            let labels = view.subviews.compactMap { $0 as? NSTextField }
            #expect(slider.minValue == 0.35 && slider.maxValue == 1)
            #expect(slider.isContinuous && slider.doubleValue == 0.68)
            #expect(labels.contains { $0.stringValue == "68%" })
            #expect(reset.isEnabled)

            slider.doubleValue = 0.42
            slider.sendAction(slider.action, to: slider.target)
            #expect(Prefs.darkModeBrightness == 0.42)
            #expect(labels.contains { $0.stringValue == "42%" })
            reset.performClick(nil)
            #expect(Prefs.darkModeBrightness == 1 && slider.doubleValue == 1)
            #expect(labels.contains { $0.stringValue == "100%" })
            #expect(!reset.isEnabled)

            // A second window/control reads the same stored app-wide value.
            Prefs.darkModeBrightness = 0.55
            let second = try #require(DarkModeBrightnessMenu.makeMenuItem().view)
            let secondSlider = try #require(second.subviews.compactMap { $0 as? NSSlider }.first)
            #expect(secondSlider.doubleValue == 0.55)
        }
    }

    @Test("Appearance has a standard keyboard-accessible reset that restores Normal")
    func standardResetMenuItem() throws {
        let app = NSApplication.shared
        let previousWindowsMenu = app.windowsMenu
        let previousHelpMenu = app.helpMenu
        defer { app.windowsMenu = previousWindowsMenu; app.helpMenu = previousHelpMenu }
        let delegate = AppDelegate(startingUpdater: false)
        let mainMenu = MainMenu.build(appDelegate: delegate)
        let viewMenu = try #require(mainMenu.items.first { $0.title == "View" }?.submenu)
        let appearance = try #require(viewMenu.items.first { $0.title == "Appearance" }?.submenu)
        let reset = try #require(appearance.items.first { $0.title == "Reset Dark Mode Brightness" })
        let action = try #require(reset.action)
        #expect(reset.view == nil)
        let resetIndex = appearance.index(of: reset)
        #expect(resetIndex > 0)
        #expect(appearance.items[resetIndex - 1].view is DarkModeBrightnessMenuView)

        try withDefaults { _ in
            Prefs.darkModeBrightness = 0.4
            appearance.update()
            #expect(reset.isEnabled)
            #expect(app.sendAction(action, to: reset.target, from: reset))
            #expect(Prefs.darkModeBrightness == 1)
            appearance.update()
            #expect(!reset.isEnabled)
        }
    }

    private func verifyMatrix(_ matrix: CIFilter, lift: CGFloat, top: CGFloat) throws {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let span = linear(top) - linear(lift)
        let expected: [(String, [CGFloat])] = [
            ("inputRVector", [span, 0, 0, 0]),
            ("inputGVector", [0, span, 0, 0]),
            ("inputBVector", [0, 0, span, 0]),
            ("inputAVector", [0, 0, 0, 1]),
            ("inputBiasVector", [linear(lift), linear(lift), linear(lift), 0])
        ]
        for (key, values) in expected {
            let vector = try #require(matrix.value(forKey: key) as? CIVector)
            for index in 0..<4 {
                #expect(abs(vector.value(at: index) - values[index]) < 0.000001)
            }
        }
    }

    /// Exercise Core Image in the same linear working space used by the layer,
    /// then inspect screen-sRGB endpoints. This catches a brightness multiplier
    /// accidentally applied in linear light or to the selected paper level.
    private func render(_ filters: [CIFilter], rgba: [CGFloat]) throws -> [UInt8] {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let linear = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let color = try #require(CIColor(red: rgba[0], green: rgba[1], blue: rgba[2],
                                         alpha: rgba[3], colorSpace: srgb))
        var output = CIImage(color: color)
        for filter in filters {
            filter.setValue(output, forKey: kCIInputImageKey)
            output = try #require(filter.outputImage)
        }
        let context = CIContext(options: [.workingColorSpace: linear,
                                          .outputColorSpace: srgb,
                                          .useSoftwareRenderer: true])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: srgb)
        return pixel
    }
}
