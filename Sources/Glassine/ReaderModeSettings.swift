import AppKit
import GlassineCore

struct ReaderModeSettings: Codable, Equatable {
    var enabled = false
    var automatic = true
    var padding = 12.0
    var left = 0.10
    var right = 0.10
    var top = 0.08
    var bottom = 0.08

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, automatic, padding, left, right, top, bottom
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? automatic
        padding = try values.decodeIfPresent(Double.self, forKey: .padding) ?? padding
        left = try values.decodeIfPresent(Double.self, forKey: .left) ?? left
        right = try values.decodeIfPresent(Double.self, forKey: .right) ?? right
        top = try values.decodeIfPresent(Double.self, forKey: .top) ?? top
        bottom = try values.decodeIfPresent(Double.self, forKey: .bottom) ?? bottom
        self = validated
    }

    var validated: Self {
        var value = self
        value.padding = padding.isFinite ? min(max(padding, 0), 48) : 12
        value.left = left.isFinite ? min(max(left, 0), 0.4) : 0.1
        value.right = right.isFinite ? min(max(right, 0), 0.4) : 0.1
        value.top = top.isFinite ? min(max(top, 0), 0.4) : 0.08
        value.bottom = bottom.isFinite ? min(max(bottom, 0), 0.4) : 0.08
        return value
    }

    private static let key = "readerModeDocuments"
    static let maximumStoredDocuments = 500

    /// The existing path -> JSON Data format stays readable by older builds.
    /// The optional flat timestamp only controls eviction; old entries have
    /// no timestamp and are pruned first, with path order breaking ties.
    private struct StoredSettings: Codable {
        let settings: ReaderModeSettings
        let lastSaved: Double

        private enum CodingKeys: String, CodingKey { case lastSaved }

        init(settings: ReaderModeSettings, lastSaved: Double) {
            self.settings = settings
            self.lastSaved = lastSaved
        }

        init(from decoder: Decoder) throws {
            settings = try ReaderModeSettings(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let stamp = (try? values.decode(Double.self, forKey: .lastSaved)) ?? 0
            lastSaved = stamp.isFinite ? stamp : 0
        }

        func encode(to encoder: Encoder) throws {
            try settings.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(lastSaved, forKey: .lastSaved)
        }
    }

    static func load(for url: URL?, defaults: UserDefaults = Prefs.defaults) -> Self {
        guard let url,
              let data = defaults.dictionary(forKey: key)?[url.standardizedFileURL.path] as? Data,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.validated
    }

    func save(for url: URL?, defaults: UserDefaults = Prefs.defaults) {
        guard let url else { return }
        let path = url.standardizedFileURL.path
        let value = validated
        var entries = defaults.dictionary(forKey: Self.key) ?? [:]
        if value == Self() {
            entries.removeValue(forKey: path)
        } else {
            let stored = StoredSettings(settings: value, lastSaved: Date().timeIntervalSinceReferenceDate)
            guard let data = try? JSONEncoder().encode(stored) else { return }
            entries[path] = data
        }

        let decoder = JSONDecoder()
        var ages: [String: Double] = [:]
        for (entryPath, raw) in entries {
            guard let data = raw as? Data,
                  let stored = try? decoder.decode(StoredSettings.self, from: data),
                  stored.settings != Self() else {
                entries.removeValue(forKey: entryPath)
                continue
            }
            ages[entryPath] = stored.lastSaved
        }
        if entries.count > Self.maximumStoredDocuments {
            let oldest = entries.keys.filter { $0 != path }.sorted { lhs, rhs in
                let left = ages[lhs] ?? 0, right = ages[rhs] ?? 0
                return left == right ? lhs < rhs : left < right
            }
            for key in oldest.prefix(entries.count - Self.maximumStoredDocuments) {
                entries.removeValue(forKey: key)
            }
        }
        if entries.isEmpty { defaults.removeObject(forKey: Self.key) }
        else { defaults.set(entries, forKey: Self.key) }
    }

    func bounds(in original: CGRect, content: CGRect?) -> CGRect {
        let value = validated
        if value.automatic {
            guard let content, !content.isNull, !content.isEmpty else { return original }
            return content.insetBy(dx: -value.padding, dy: -value.padding).intersection(original)
        }
        // Insets are page-space values. The controller rotates the named
        // display edges into page space before calling this for custom mode.
        return CGRect(x: original.minX + original.width * value.left,
                      y: original.minY + original.height * value.bottom,
                      width: original.width * (1 - value.left - value.right),
                      height: original.height * (1 - value.top - value.bottom))
    }

    func customBounds(in original: CGRect, rotation: Int) -> CGRect {
        let value = validated
        var rotated = value
        switch ((rotation % 360) + 360) % 360 {
        case 90: (rotated.left, rotated.top, rotated.right, rotated.bottom) = (value.top, value.right, value.bottom, value.left)
        case 180: (rotated.left, rotated.top, rotated.right, rotated.bottom) = (value.right, value.bottom, value.left, value.top)
        case 270: (rotated.left, rotated.top, rotated.right, rotated.bottom) = (value.bottom, value.left, value.top, value.right)
        default: break
        }
        return rotated.bounds(in: original, content: nil)
    }
}

@MainActor
private final class ReaderModeSettingsPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        // Settings apply live, so Escape and Done only dismiss the sheet.
        if let parent = sheetParent { parent.endSheet(self) }
        else { orderOut(sender) }
    }
}

/// Live, per-document margin controls. Automatic padding cannot remove detected
/// ink. Custom insets let the reader handle scanner borders or unusual layouts.
@MainActor
final class ReaderModeSettingsController: NSWindowController {
    private let mode = NSSegmentedControl(labels: ["Automatic", "Custom"], trackingMode: .selectOne,
                                           target: nil, action: nil)
    private let padding = NSSlider(value: 12, minValue: 0, maxValue: 48, target: nil, action: nil)
    private var trims: [NSSlider] = []
    private var values: [NSTextField] = []
    private var settings: ReaderModeSettings
    private let onChange: (ReaderModeSettings) -> Void

    init(settings: ReaderModeSettings, onChange: @escaping (ReaderModeSettings) -> Void) {
        self.settings = settings.validated
        self.onChange = onChange
        let panel = ReaderModeSettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 336),
                                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Reader Mode Margins"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        let content = NSView()
        panel.contentView = content
        mode.target = self
        mode.action = #selector(changed(_:))
        mode.setAccessibilityLabel("Margin detection")
        let description = NSTextField(wrappingLabelWithString:
            "Automatic keeps detected content. Custom trims the page edges you choose.")
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [mode, description])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for (index, title) in ["Padding", "Left", "Right", "Top", "Bottom"].enumerated() {
            let slider = index == 0 ? padding : NSSlider(value: 10, minValue: 0, maxValue: 40,
                                                         target: nil, action: nil)
            if index > 0 { trims.append(slider) }
            slider.target = self
            slider.action = #selector(changed(_:))
            slider.isContinuous = true
            slider.setAccessibilityLabel(index == 0 ? "Automatic margin padding" : "Trim \(title.lowercased()) margin")
            let label = NSTextField(labelWithString: title)
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.alignment = .right
            values.append(value)
            let row = NSStackView(views: [label, slider, value])
            row.spacing = 10
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                label.widthAnchor.constraint(equalToConstant: 54),
                slider.widthAnchor.constraint(equalToConstant: 186),
                value.widthAnchor.constraint(equalToConstant: 48)
            ])
        }
        let reset = NSButton(title: "Reset", target: self, action: #selector(reset(_:)))
        reset.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [reset, NSView(), done])
        stack.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        sync()
        panel.setContentSize(NSSize(width: 380, height: stack.fittingSize.height + 40))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func sync() {
        mode.selectedSegment = settings.automatic ? 0 : 1
        padding.doubleValue = settings.padding
        padding.isEnabled = settings.automatic
        values[0].stringValue = "\(Int(settings.padding.rounded())) pt"
        for (index, value) in [settings.left, settings.right, settings.top, settings.bottom].enumerated() {
            trims[index].doubleValue = value * 100
            trims[index].isEnabled = !settings.automatic
            values[index + 1].stringValue = "\(Int((value * 100).rounded()))%"
        }
    }

    @objc private func changed(_ sender: Any?) {
        settings.automatic = mode.selectedSegment == 0
        settings.padding = padding.doubleValue
        settings.left = trims[0].doubleValue / 100
        settings.right = trims[1].doubleValue / 100
        settings.top = trims[2].doubleValue / 100
        settings.bottom = trims[3].doubleValue / 100
        settings = settings.validated
        sync()
        onChange(settings)
    }

    @objc private func reset(_ sender: Any?) {
        let enabled = settings.enabled
        settings = ReaderModeSettings()
        settings.enabled = enabled
        sync()
        onChange(settings)
    }

    @objc private func done(_ sender: Any?) {
        window?.cancelOperation(sender)
    }
}
