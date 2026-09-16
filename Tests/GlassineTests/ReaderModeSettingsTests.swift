import AppKit
import Testing
@testable import Glassine

@Suite("Reader Mode settings", .serialized) @MainActor
struct ReaderModeSettingsTests {
    private let storageKey = "readerModeDocuments"

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "ReaderModeSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("Missing settings keys retain field defaults and existing values")
    func partialDecoding() throws {
        let empty = try JSONDecoder().decode(ReaderModeSettings.self, from: Data("{}".utf8))
        #expect(empty == ReaderModeSettings())
        let partial = try JSONDecoder().decode(ReaderModeSettings.self,
            from: Data(#"{"enabled":true,"padding":24,"right":null,"futureField":"ignored"}"#.utf8))
        var expected = ReaderModeSettings()
        expected.enabled = true
        expected.padding = 24
        #expect(partial == expected)
        let clamped = try JSONDecoder().decode(ReaderModeSettings.self,
            from: Data(#"{"automatic":false,"left":0.9,"padding":-4}"#.utf8))
        #expect(!clamped.automatic && clamped.left == 0.4 && clamped.padding == 0)
        #expect(clamped.right == 0.1 && clamped.top == 0.08 && clamped.bottom == 0.08)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ReaderModeSettings.self, from: Data(#"{"enabled":"bad"}"#.utf8))
        }
    }

    @Test("Per-file storage remains flat JSON and drops only all-default settings")
    func persistenceAndReset() throws {
        try withDefaults { defaults in
            let file = URL(fileURLWithPath: "/ReaderModeSettingsTests/folder/../Reading.pdf")
            let path = file.standardizedFileURL.path
            var settings = ReaderModeSettings()
            settings.automatic = false
            settings.left = 0.17
            settings.padding = 21
            settings.save(for: file, defaults: defaults)
            #expect(ReaderModeSettings.load(for: file.standardizedFileURL, defaults: defaults) == settings)
            let stored = try #require(defaults.dictionary(forKey: storageKey)?[path] as? Data)
            // Older versions decode the same flat settings keys and ignore the
            // new optional timestamp; the preference value is still JSON Data.
            #expect(try JSONDecoder().decode(ReaderModeSettings.self, from: stored) == settings)
            let fields = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
            #expect(fields["lastSaved"] is NSNumber)
            #expect(fields["automatic"] as? Bool == false)
            #expect(fields["settings"] == nil)
            #expect(!settings.enabled)
            ReaderModeSettings().save(for: file, defaults: defaults)
            #expect(defaults.object(forKey: storageKey) == nil)
            #expect(ReaderModeSettings.load(for: file, defaults: defaults) == ReaderModeSettings())
            settings.save(for: nil, defaults: defaults)
            #expect(defaults.object(forKey: storageKey) == nil)
        }
    }

    @Test("Saving cleans legacy defaults and unreadable entries while preserving partial records")
    func legacyCleanup() throws {
        try withDefaults { defaults in
            let file = URL(fileURLWithPath: "/ReaderModeSettingsTests/current.pdf")
            let legacy = "/ReaderModeSettingsTests/legacy.pdf"
            defaults.set([
                "/ReaderModeSettingsTests/default.pdf": Data("{}".utf8),
                "/ReaderModeSettingsTests/broken.pdf": Data("invalid".utf8),
                legacy: Data(#"{"enabled":true,"lastSaved":"invalid timestamp"}"#.utf8)
            ], forKey: storageKey)
            var settings = ReaderModeSettings()
            settings.enabled = true
            settings.save(for: file, defaults: defaults)
            let entries = try #require(defaults.dictionary(forKey: storageKey))
            #expect(entries.count == 2)
            #expect(entries[file.path] != nil && entries[legacy] != nil)
            #expect(ReaderModeSettings.load(for: URL(fileURLWithPath: legacy), defaults: defaults) == settings)
        }
    }

    @Test("The 500-file cap prunes predictably and always preserves the file being saved")
    func boundedPersistence() throws {
        try withDefaults { defaults in
            func path(_ index: Int) -> String {
                String(format: "/ReaderModeSettingsTests/entry-%04d.pdf", index)
            }
            // Future equal timestamps prove the current file is explicitly
            // protected, and equal-age eviction is stable rather than hash-order based.
            let old = Data(#"{"enabled":true,"lastSaved":999999999999}"#.utf8)
            let count = ReaderModeSettings.maximumStoredDocuments
            defaults.set(Dictionary(uniqueKeysWithValues: (0...count).map { (path($0), old) }),
                         forKey: storageKey)
            let file = URL(fileURLWithPath: "/ReaderModeSettingsTests/current.pdf")
            var settings = ReaderModeSettings()
            settings.enabled = true
            settings.save(for: file, defaults: defaults)
            let entries = try #require(defaults.dictionary(forKey: storageKey))
            #expect(entries.count == count)
            #expect(entries[file.path] != nil)
            #expect(entries[path(0)] == nil && entries[path(1)] == nil)
            #expect(entries[path(2)] != nil && entries[path(count)] != nil)
            #expect(ReaderModeSettings.load(for: file, defaults: defaults) == settings)

            // Subsequent saves still enforce the cap after initial maintenance.
            let nextFile = URL(fileURLWithPath: "/ReaderModeSettingsTests/next.pdf")
            settings.save(for: nextFile, defaults: defaults)
            let nextEntries = try #require(defaults.dictionary(forKey: storageKey))
            #expect(nextEntries.count == count && nextEntries[nextFile.path] != nil)
            #expect(nextEntries[file.path] == nil) // The only non-future timestamp.
        }
    }

    @Test("Rapid margin changes persist the last value immediately without rewriting other records")
    func rapidChanges() throws {
        try withDefaults { defaults in
            var settings = ReaderModeSettings()
            settings.enabled = true
            let file = URL(fileURLWithPath: "/ReaderModeSettingsTests/slider.pdf")
            let other = URL(fileURLWithPath: "/ReaderModeSettingsTests/other.pdf")
            settings.save(for: other, defaults: defaults)
            let original = try #require(defaults.dictionary(forKey: storageKey)?[other.path] as? Data)
            for tick in 0..<120 {
                settings.padding = Double(tick % 49)
                settings.save(for: file, defaults: defaults)
            }
            #expect(ReaderModeSettings.load(for: file, defaults: defaults) == settings)
            #expect(defaults.dictionary(forKey: storageKey)?[other.path] as? Data == original)
            ReaderModeSettings().save(for: file, defaults: defaults)
            #expect(defaults.dictionary(forKey: storageKey)?[file.path] == nil)
            #expect(defaults.dictionary(forKey: storageKey)?[other.path] as? Data == original)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @Test("Escape dismisses the margins sheet while keeping live changes")
    func escapeDismissal() throws {
        _ = NSApplication.shared
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.tabbingMode = .disallowed
        var initial = ReaderModeSettings()
        initial.enabled = true
        var changes: [ReaderModeSettings] = []
        let controller = ReaderModeSettingsController(settings: initial) { changes.append($0) }
        let panel = try #require(controller.window)
        defer {
            if let parent = panel.sheetParent { parent.endSheet(panel) }
            panel.orderOut(nil)
            host.close()
        }
        host.beginSheet(panel)
        #expect(panel.sheetParent === host)
        let content = try #require(panel.contentView)
        let slider = try #require(descendants(of: content).compactMap { $0 as? NSSlider }
            .first { $0.accessibilityLabel() == "Automatic margin padding" })
        slider.doubleValue = 24
        let action = try #require(slider.action)
        #expect(slider.sendAction(action, to: slider.target))
        #expect(changes.last?.padding == 24)
        panel.cancelOperation(nil)
        #expect(panel.sheetParent == nil)
        #expect(changes.count == 1 && changes[0].enabled && changes[0].padding == 24)
    }
}
