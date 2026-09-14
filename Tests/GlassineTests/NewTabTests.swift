import AppKit
import GlassineCore
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Glassine

@Suite("New tab routing", .serialized) @MainActor
struct NewTabTests {
    /// These are real AppKit windows, in the test process. Keep other suites'
    /// windows out of host selection and restore the menus and defaults after
    /// each synchronous scenario.
    private func withEnvironment(_ body: (NSMenuItem) throws -> Void) throws {
        let app = NSApplication.shared
        let priorWindows = Set(app.windows.map(ObjectIdentifier.init))
        let visibleWindows = app.orderedWindows.filter {
            $0.isVisible && !$0.isMiniaturized
                && ($0.tabbingIdentifier == ReaderWindowController.tabbingIdentifier
                    || $0.windowController is RecentsWindowController)
        }
        let priorKeyWindow = app.keyWindow
        visibleWindows.forEach { $0.orderOut(nil) }

        let suite = "NewTabTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let priorDefaults = Prefs.defaults
        Prefs.defaults = defaults
        let frameKeys = ["NSWindow Frame ReaderWindow", "NSWindow Frame RecentsWindow"]
        let frameValues = frameKeys.map { UserDefaults.standard.object(forKey: $0) }
        let priorMainMenu = app.mainMenu
        let priorWindowsMenu = app.windowsMenu
        let priorHelpMenu = app.helpMenu
        let priorDelegate = app.delegate
        let delegate = AppDelegate(startingUpdater: false)
        app.delegate = delegate
        let mainMenu = MainMenu.build(appDelegate: delegate)
        app.mainMenu = mainMenu

        defer {
            // Start-tab controllers remove their self-retention on close.
            for window in app.windows where !priorWindows.contains(ObjectIdentifier(window)) {
                window.close()
            }
            RecentsWindowController.shared.hide()
            app.mainMenu = priorMainMenu
            app.windowsMenu = priorWindowsMenu
            app.helpMenu = priorHelpMenu
            app.delegate = priorDelegate
            for (key, value) in zip(frameKeys, frameValues) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            Prefs.defaults = priorDefaults
            defaults.removePersistentDomain(forName: suite)
            visibleWindows.reversed().forEach { $0.orderFront(nil) }
            priorKeyWindow?.makeKey()
        }

        let fileMenu = try #require(mainMenu.items.first { $0.title == "File" }?.submenu)
        let newTab = try #require(fileMenu.items.first { $0.title == "New Tab" })
        #expect(newTab.target === delegate)
        #expect(newTab.action == #selector(AppDelegate.newTab(_:)))
        #expect(newTab.keyEquivalent == "t" && newTab.keyEquivalentModifierMask == .command)
        try withExtendedLifetime(delegate) { try body(newTab) }
    }

    private func newlyOpenedStartTab(_ action: () -> Void) throws -> NSWindow {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let documentCount = NSDocumentController.shared.documents.count
        action()
        let added = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
        #expect(added.count == 1)
        let window = try #require(added.first)
        #expect(window.windowController is StartTabWindowController)
        #expect(NSDocumentController.shared.documents.count == documentCount)
        #expect(window.title == "Recents")
        let chrome = try #require(window.contentViewController as? WindowChromeContentController)
        #expect(chrome.body is RecentsViewController)
        let children = descendants(of: chrome.body.view)
        #expect(children.contains { ($0 as? NSButton)?.title == "Open Other…" })
        #expect(children.contains { ($0 as? NSSearchField)?.placeholderString == "Filter" })
        #expect(window.firstResponder is NSTableView)
        #expect(window.contentLayoutRect.height >= window.contentMinSize.height)
        return window
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func send(_ item: NSMenuItem) {
        #expect(NSApp.sendAction(item.action!, to: item.target, from: item))
    }

    @Test("Command-T from the launch picker opens a usable start tab without an untitled document")
    func recentsOnly() throws {
        try withEnvironment { newTab in
            let recents = RecentsWindowController.shared
            recents.show()
            let launchWindow = try #require(recents.window)
            #expect(launchWindow.isVisible)
            let first = try newlyOpenedStartTab { send(newTab) }
            #expect(!launchWindow.isVisible)
            #expect(first.tabGroup?.windows.contains { $0 === launchWindow } != true)

            let second = try newlyOpenedStartTab { send(newTab) }
            let group = try #require(second.tabGroup)
            #expect(group.windows.count == 2)
            #expect(group.windows.contains { $0 === first })
            #expect(group.selectedWindow === second)
        }
    }

    @Test("Native new-tab actions from Recents and an existing start tab show the same picker")
    func nativeNewTabAction() throws {
        try withEnvironment { _ in
            let recents = RecentsWindowController.shared
            recents.show()
            let first = try newlyOpenedStartTab {
                #expect(NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: recents, from: nil))
            }
            let controller = try #require(first.windowController as? StartTabWindowController)
            let second = try newlyOpenedStartTab { controller.newWindowForTab(nil) }
            #expect(second.tabGroup?.windows.count == 2)
            #expect(second.tabGroup?.windows.contains { $0 === first } == true)
            #expect(!recents.window!.isVisible)
        }
    }

    @Test("New Tab keeps the existing reader group even while the launch picker is in front")
    func readerGroup() throws {
        try withEnvironment { newTab in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("NewTabFixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("Reader.pdf")
            let pdf = PDFDocument()
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
            pdf.insert(page, at: 0)
            try #require(pdf.dataRepresentation()).write(to: url)
            let document = try GlassineDocument(contentsOf: url, ofType: UTType.pdf.identifier)
            defer { document.close() }
            document.makeWindowControllers()
            let reader = try #require(document.windowControllers.first as? ReaderWindowController)
            reader.showWindow(nil)
            let readerWindow = try #require(reader.window)
            RecentsWindowController.shared.show()

            let first = try newlyOpenedStartTab { send(newTab) }
            #expect(first.tabGroup?.windows.count == 2)
            #expect(first.tabGroup?.windows.contains { $0 === readerWindow } == true)
            #expect(first.tabGroup?.selectedWindow === first)

            // The tab bar's "+" bypasses the File menu.
            readerWindow.makeKeyAndOrderFront(nil)
            let second = try newlyOpenedStartTab { reader.newWindowForTab(nil) }
            #expect(second.tabGroup?.windows.count == 3)
            #expect(second.tabGroup?.windows.contains { $0 === readerWindow } == true)
        }
    }

    @Test("Command-T without open windows ignores retained closed windows")
    func noWindowsAndClosedWindows() throws {
        try withEnvironment { newTab in
            RecentsWindowController.shared.close()
            let first = try newlyOpenedStartTab { send(newTab) }
            first.close()
            #expect(!first.isVisible)

            let second = try newlyOpenedStartTab { send(newTab) }
            #expect(second.tabGroup?.windows.contains { $0 === first } != true)
            second.close()

            // A stale native responder must not revive its closed host either.
            let third = try newlyOpenedStartTab { StartTabWindowController.present(besides: first) }
            #expect(third.tabGroup?.windows.contains { $0 === first || $0 === second } != true)
            #expect(!first.isVisible && !second.isVisible)
        }
    }
}
