import AppKit
import GlassineCore

/// An app-wide preference, so a user can also set it before opening a document
/// or switching to dark appearance. The reader applies it only while inverting.
enum DarkModeBrightnessMenu {
    private static let actions = Actions()

    static func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Dark Mode Brightness", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("glassine.appearance.darkModeBrightness")
        item.view = DarkModeBrightnessMenuView()
        return item
    }

    /// A standard item is reachable through keyboard menu navigation and
    /// VoiceOver even when AppKit skips the slider's custom menu view.
    static func makeResetMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Reset Dark Mode Brightness",
                              action: #selector(Actions.resetBrightness(_:)), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("glassine.appearance.resetDarkModeBrightness")
        item.target = actions
        return item
    }

    private final class Actions: NSObject, NSMenuItemValidation {
        @objc func resetBrightness(_ sender: Any?) {
            Prefs.darkModeBrightness = Prefs.maxDarkModeBrightness
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            Prefs.darkModeBrightness < Prefs.maxDarkModeBrightness
        }
    }
}

final class DarkModeBrightnessMenuView: NSView {
    private let slider = NSSlider()
    private let percentLabel = NSTextField(labelWithString: "100%")
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 78))

        let menuFont = NSFont.menuFont(ofSize: 0)
        let caption = NSTextField(labelWithString: "Dark Mode Brightness")
        caption.font = menuFont
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: menuFont.pointSize,
                                                            weight: .regular)
        percentLabel.alignment = .right

        let dimLabel = NSTextField(labelWithString: "Dim")
        dimLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        dimLabel.textColor = .secondaryLabelColor
        let normalLabel = NSTextField(labelWithString: "Normal")
        normalLabel.font = dimLabel.font
        normalLabel.textColor = .secondaryLabelColor
        normalLabel.alignment = .right

        slider.minValue = Prefs.minDarkModeBrightness
        slider.maxValue = Prefs.maxDarkModeBrightness
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.setAccessibilityLabel("Dark mode page brightness")
        slider.setAccessibilityHelp("Dims text, images, and highlights on inverted pages while keeping the paper colour.")
        slider.toolTip = "Applies to inverted pages in Dark Mode"

        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.font = dimLabel.font
        resetButton.target = self
        resetButton.action = #selector(resetBrightness)
        resetButton.setAccessibilityLabel("Reset dark mode brightness to normal")

        for child in [caption, percentLabel, slider, dimLabel, normalLabel, resetButton] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            percentLabel.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            percentLabel.leadingAnchor.constraint(greaterThanOrEqualTo: caption.trailingAnchor, constant: 12),
            slider.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: percentLabel.trailingAnchor),
            slider.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 5),
            dimLabel.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            dimLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 1),
            normalLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            normalLabel.centerYAnchor.constraint(equalTo: dimLabel.centerYAnchor),
            resetButton.centerXAnchor.constraint(equalTo: slider.centerXAnchor),
            resetButton.centerYAnchor.constraint(equalTo: dimLabel.centerYAnchor)
        ])
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The menu creates a window each time it opens. Pick up any preference
    /// changes made while it was closed, without keeping a global observer.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { sync() }
    }

    private func sync() {
        let value = Prefs.darkModeBrightness
        slider.doubleValue = value
        percentLabel.stringValue = "\(Int((value * 100).rounded()))%"
        resetButton.isEnabled = value < Prefs.maxDarkModeBrightness
        slider.setAccessibilityValueDescription(percentLabel.stringValue)
    }

    @objc private func sliderMoved() {
        Prefs.darkModeBrightness = slider.doubleValue
        sync()
    }

    @objc private func resetBrightness() {
        Prefs.darkModeBrightness = Prefs.maxDarkModeBrightness
        sync()
    }
}
