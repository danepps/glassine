import AppKit
import GlassineCore
import Testing
import WebKit
@testable import Glassine

@MainActor
private final class LifecyclePrinter: HTMLPrinter {
    var loads: [String] = []
    var teardownCount = 0
    func print(html: String, baseURL: URL?, layout: MarkdownLayout,
               completion: @escaping (Result<Data, Error>) -> Void) { loads.append(html) }
    func reprint(completion: @escaping (Result<Data, Error>) -> Void) {}
    func teardown() { teardownCount += 1 }
}

@MainActor
@Suite("Markdown sleep recovery", .serialized)
struct MarkdownRecoveryTests {
    @Test("System, display and login-session sleep must all clear before rendering resumes")
    func overlappingSleepNotifications() {
        let notifications = NotificationCenter()
        let printer = LifecyclePrinter()
        let renderer = MarkdownRenderer(printer: printer, workspaceNotifications: notifications)
        renderer.render(html: "document", baseURL: nil, key: "a", layout: .pages) { _ in }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            notifications.post(name: name, object: nil)
        }
        #expect(printer.loads == ["document"] && printer.teardownCount == 1)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        notifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(printer.loads == ["document"])
        notifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(printer.loads == ["document", "document"])
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(printer.loads.count == 2, "Duplicate wake notifications must not restart a running job")
    }

    @Test("A document opened during display sleep waits for wake")
    func openWhileAsleep() {
        let notifications = NotificationCenter()
        let printer = LifecyclePrinter()
        let renderer = MarkdownRenderer(printer: printer, workspaceNotifications: notifications)
        notifications.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        renderer.render(html: "document", baseURL: nil, key: "a", layout: .pages) { _ in }
        #expect(printer.loads.isEmpty)
        notifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(printer.loads == ["document"])
    }

    @Test("A document closed while suspended cannot install a late render")
    func closeDuringSleep() async throws {
        _ = NSApplication.shared
        let renderer = MarkdownRenderer.shared
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        defer { notifications.post(name: NSWorkspace.didWakeNotification, object: nil) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GlassineClosed-\(UUID()).md")
        try "# Closed while sleeping\n\nThis tab should stay closed.".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try GlassineDocument(contentsOf: url, ofType: GlassineDocument.markdownType.identifier)
        document.makeWindowControllers()
        document.close()
        #expect(document.pdf == nil)
        var following: Result<RenderedMarkdown, Error>?
        renderer.render(html: "<html><body>Following render</body></html>", baseURL: nil,
                        key: UUID().uuidString, layout: .pages) { following = $0 }
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        let deadline = Date().addingTimeInterval(30)
        while following == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let result = try #require(following)
        _ = try result.get()
        #expect(document.pdf == nil, "The closed document's earlier render must have been discarded")
    }

    @Test("WebKit prints the latest revision after an interrupted load", arguments: [MarkdownLayout.pages, .continuous])
    func actualWebKitAfterWake(layout: MarkdownLayout) async throws {
        _ = NSApplication.shared
        let notifications = NotificationCenter()
        let printer = WebKitHTMLPrinter()
        defer { printer.teardown() }
        let renderer = MarkdownRenderer(printer: printer, workspaceNotifications: notifications)
        var result: Result<RenderedMarkdown, Error>?
        var obsoleteWasSuperseded = false
        let styling = MarkdownStyling(styleID: "manuscript", css: MarkdownHTML.builtInStyle("manuscript"),
                                      size: 12, layout: layout)
        let before = MarkdownHTML.page(body: "<h1>Before sleep</h1>", title: "Before", styling: styling)
        let body = "<h1>After wake</h1>" + (1...50).map { "<p>Recovered paragraph \($0).</p>" }.joined()
        let after = MarkdownHTML.page(body: body, title: "After", styling: styling)
        renderer.render(html: before, baseURL: nil, key: "a", layout: layout) {
            if case .failure(MarkdownRenderError.superseded) = $0 { obsoleteWasSuperseded = true }
            else { Issue.record("The interrupted revision should be superseded") }
        }
        notifications.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        renderer.render(html: after, baseURL: nil, key: "a", layout: layout) { result = $0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(obsoleteWasSuperseded && result == nil)
        notifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        // A late termination callback for the discarded view must not destroy
        // the replacement view or consume its one process-restart allowance.
        printer.webViewWebContentProcessDidTerminate(WKWebView())
        let deadline = Date().addingTimeInterval(30)
        while result == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let completed = try #require(result)
        let rendered = try completed.get()
        #expect(rendered.document.string?.contains("Recovered paragraph 50.") == true)
        #expect(rendered.document.string?.contains("Before sleep") == false)
        if layout == .pages {
            #expect(rendered.document.pageCount > 1)
            #expect(rendered.document.page(at: 0)?.bounds(for: .mediaBox).height == 792)
        } else {
            #expect(rendered.document.pageCount == 1)
            #expect((rendered.document.page(at: 0)?.bounds(for: .mediaBox).height ?? 0) > 792)
        }
    }
}
