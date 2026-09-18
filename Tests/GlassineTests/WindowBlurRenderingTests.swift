import AppKit
import GlassineCore
import ScreenCaptureKit
import Testing
@testable import Glassine

/// Opt in with GLASSINE_RUN_BLUR_RENDER_TEST=1 and filter to this test.
/// Uses only two windows owned by the test process; no desktop capture grant
/// or other applications' contents are needed. Requires WindowServer access.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GLASSINE_RUN_BLUR_RENDER_TEST"] == "1"))
@MainActor func windowBlurPreservesColorAndSoftensBackgroundDetail() async throws {
    guard #available(macOS 26.0, *) else { return }
    _ = NSApplication.shared
    let suiteName = "GlassineRenderedBlurTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let frame = NSRect(x: 100, y: 120, width: 720, height: 480)
    let background = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
    background.isReleasedWhenClosed = false
    let pattern = BlurPatternView(frame: NSRect(origin: .zero, size: frame.size))
    background.contentView = pattern

    let window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.hasShadow = false
    window.toolbar = NSToolbar(identifier: "RenderedBlurFixture")
    window.toolbarStyle = .unified
    let body = NSViewController()
    body.view = NSView(frame: NSRect(origin: .zero, size: frame.size))
    body.view.wantsLayer = true
    WindowChromeContentController.install(in: window, body: body)
    window.setFrame(frame, display: false)
    defer { window.close(); background.close() }

    // Keep preference changes synchronous: other tests use the same injectable
    // defaults, and screen capture necessarily yields the main actor.
    func configure(blur: Bool, strength: Double) {
        let previous = Prefs.defaults
        Prefs.defaults = defaults
        defer { Prefs.defaults = previous }
        Prefs.windowOpacity = 0.45
        Prefs.interfaceOpacity = 0.3
        Prefs.windowBlur = blur
        Prefs.windowBlurStrength = strength
        WindowChrome.apply(to: window)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func capture(name: String) async throws -> NSBitmapImageRep {
        try await Task.sleep(for: .milliseconds(400))
        let content = try await SCShareableContent.currentProcess
        let captured = try #require(content.windows.first { $0.windowID == window.windowNumber })
        let display = try #require(content.displays.first { $0.frame.intersects(captured.frame) })
        let owned = content.windows.filter {
            $0.windowID == window.windowNumber || $0.windowID == background.windowNumber
        }
        #expect(owned.count == 2)
        // A single-window capture excludes its backdrop. Include both
        // fixture windows to test the actual compositor output.
        let filter = SCContentFilter(display: display, including: owned)
        let config = SCStreamConfiguration()
        config.width = Int(frame.width)
        config.height = Int(frame.height)
        config.sourceRect = captured.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: image)
        if let directory = ProcessInfo.processInfo.environment["GLASSINE_BLUR_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: url.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    background.orderFront(nil)
    window.orderFront(nil)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        pattern.content = .stripes
        window.appearance = NSAppearance(named: appearance)
        body.view.layer?.backgroundColor = (appearance == .aqua ? NSColor.white : .black).cgColor
        var captures: [NSBitmapImageRep] = []
        let settings = [(false, 0.5), (true, 0.1), (true, 0.5),
                        (true, 1.0), (true, 0.0), (false, 0.5)]
        for (index, setting) in settings.enumerated() {
            configure(blur: setting.0, strength: setting.1)
            captures.append(try await capture(name: "\(appearance.rawValue)-\(index)"))
        }

        let off = try stripeDetail(in: captures[0])
        let light = try stripeDetail(in: captures[1])
        let on = try stripeDetail(in: captures[2])
        let zero = try stripeDetail(in: captures[4])
        let offAgain = try stripeDetail(in: captures[5])
        #expect(off > 0.02, "Fixture must contain visible sharp stripes")
        #expect(light < off * 0.9 && light > on,
                "Low blur must visibly soften detail without becoming the full-strength effect")
        #expect(on < off * 0.2, "Blur must suppress detail, not just fade or tint it")
        #expect(zero > off * 0.8, "Zero strength must disable blur")
        #expect(offAgain > off * 0.8, "Turning blur off must restore sharp detail")

        // A broad step gives the larger blur kernel enough space to settle
        // on both sides; the narrow stripe fixture truncates that transition.
        pattern.content = .colorEdge
        configure(blur: true, strength: 0.5)
        let mediumColor = try await capture(name: "\(appearance.rawValue)-color-medium")
        configure(blur: true, strength: 1)
        let strongColor = try await capture(name: "\(appearance.rawValue)-color-strong")
        let mediumEdge = try colorTransitionWidth(in: mediumColor)
        let strongEdge = try colorTransitionWidth(in: strongColor)
        #expect(Double(strongEdge) > Double(mediumEdge) * 1.5,
                "Strong blur must spread colour transitions more than medium blur")

        // The stronger maximum intentionally merges nearby color bands. Use
        // two uniform backdrops covering the oversized kernel instead: a
        // real blur must still transmit their color, unlike an opaque sheet.
        background.setFrame(frame.insetBy(dx: -1024, dy: -1024), display: true)
        pattern.content = .solidBlue
        configure(blur: true, strength: 1)
        let blueBackdrop = try await capture(name: "\(appearance.rawValue)-solid-blue-strong")
        pattern.content = .solidRed
        let redBackdrop = try await capture(name: "\(appearance.rawValue)-solid-red-strong")
        let blue = try pixel(blueBackdrop, x: 0.5, y: 0.5)
        let red = try pixel(redBackdrop, x: 0.5, y: 0.5)
        #expect(red.redComponent - blue.redComponent > 0.15,
                "Background colours must survive: a solid frosted sheet also erases stripes")
        #expect(blue.blueComponent - red.blueComponent > 0.15)
        background.setFrame(frame, display: true)

        // The previous fixture checked only the center. Large text extending
        // across all margins also exposes sharp strips and edge-only failures.
        pattern.content = .text
        configure(blur: false, strength: 1)
        let sharpText = try await capture(name: "\(appearance.rawValue)-text-off")
        configure(blur: true, strength: 1)
        let softText = try await capture(name: "\(appearance.rawValue)-text-strong")
        let bodyFrame = body.view.convert(body.view.bounds, to: window.contentView)
        let top = Int(frame.height - bodyFrame.maxY)
        let width = softText.pixelsWide
        let height = softText.pixelsHigh
        let margins = [
            NSRect(x: 24, y: top + 2, width: width - 48, height: 32),
            NSRect(x: 24, y: height - 36, width: width - 48, height: 32),
            NSRect(x: 2, y: top + 24, width: 32, height: height - top - 48),
            NSRect(x: width - 36, y: top + 24, width: 32, height: height - top - 48),
            NSRect(x: width / 2 - 40, y: height / 2 - 40, width: 80, height: 80)
        ]
        for region in margins {
            let sharp = try textDetail(in: sharpText, region: region)
            let soft = try textDetail(in: softText, region: region)
            #expect(sharp > 0.005, "Every sampled region must contain background text")
            #expect(soft < sharp * 0.15, "Blur must soften text at the margins as well as the center")
        }
    }
}

private func pixel(_ bitmap: NSBitmapImageRep, x: Double, y: Double) throws -> NSColor {
    try #require(bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * x),
                                y: Int(Double(bitmap.pixelsHigh) * y))?.usingColorSpace(.sRGB))
}

private func stripeDetail(in bitmap: NSBitmapImageRep) throws -> Double {
    let y = bitmap.pixelsHigh / 2
    let range = (bitmap.pixelsWide * 4 / 10)..<(bitmap.pixelsWide * 6 / 10)
    var total = 0.0
    for x in range {
        let a = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        let b = try #require(bitmap.colorAt(x: x + 1, y: y)?.usingColorSpace(.sRGB))
        total += abs(a.redComponent - b.redComponent)
    }
    return total / Double(range.count)
}

private func colorTransitionWidth(in bitmap: NSBitmapImageRep) throws -> Int {
    let y = bitmap.pixelsHigh / 2
    var samples: [CGFloat] = []
    for x in (bitmap.pixelsWide / 10)..<(bitmap.pixelsWide * 9 / 10) {
        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        samples.append(color.redComponent)
    }
    let low = try #require(samples.min())
    let high = try #require(samples.max())
    #expect(high - low > 0.08)
    // Compare transition width, not squared adjacent-pixel differences: an
    // 8-bit screenshot quantizes both gradual ramps to the same 1/255 steps.
    return samples.filter { $0 > low + (high - low) * 0.1 && $0 < low + (high - low) * 0.9 }.count
}

private final class BlurPatternView: NSView {
    enum Content { case stripes, colorEdge, text, solidBlue, solidRed }
    var content = Content.stripes {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if content == .solidBlue || content == .solidRed {
            (content == .solidBlue ? NSColor.systemBlue : NSColor.systemRed).setFill()
            bounds.fill()
            return
        }
        if content == .colorEdge {
            NSColor.systemBlue.setFill()
            bounds.fill()
            NSColor.systemRed.setFill()
            NSRect(x: bounds.midX, y: 0, width: bounds.width / 2, height: bounds.height).fill()
            return
        }
        if content == .text {
            NSColor.black.setFill()
            bounds.fill()
            for y in stride(from: -20, to: Int(bounds.height), by: 60) {
                ("ROW 0123456789 → Background text ABC 0123456789" as NSString)
                    .draw(at: NSPoint(x: -8, y: y), withAttributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 40, weight: .medium),
                        .foregroundColor: NSColor.systemGreen
                    ])
            }
            return
        }
        for x in stride(from: 0, to: Int(bounds.width), by: 8) {
            (x / 8 % 2 == 0 ? NSColor.black : NSColor.white).setFill()
            NSRect(x: CGFloat(x), y: 0, width: 8, height: bounds.height).fill()
        }
        NSColor.systemBlue.setFill()
        NSRect(x: bounds.width * 0.1, y: 0, width: bounds.width * 0.2, height: bounds.height).fill()
        NSColor.systemRed.setFill()
        NSRect(x: bounds.width * 0.7, y: 0, width: bounds.width * 0.2, height: bounds.height).fill()
    }
}

private func textDetail(in bitmap: NSBitmapImageRep, region: NSRect) throws -> Double {
    var total = 0.0
    var count = 0
    for y in Int(region.minY)..<Int(region.maxY) {
        for x in Int(region.minX)..<Int(region.maxX) {
            let a = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let right = try #require(bitmap.colorAt(x: x + 1, y: y)?.usingColorSpace(.sRGB))
            let below = try #require(bitmap.colorAt(x: x, y: y + 1)?.usingColorSpace(.sRGB))
            total += abs(a.greenComponent - right.greenComponent)
                + abs(a.greenComponent - below.greenComponent)
            count += 2
        }
    }
    return total / Double(count)
}
