import AppKit
import GlassineCore
import Testing
import WebKit

@Suite("Quick Look HTML rendering", .serialized) @MainActor
struct MarkdownPreviewRenderingTests {
    @Test("WebKit renders both appearances, internal links and passive document content")
    func rendering() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlassinePreview-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Preview.md")
        try """
        # Quick Look

        [Jump](#destination) and a footnote.[^note]

        <script>window.previewAttack = true</script>

        ## Destination

        | Name | Value |
        | --- | --- |
        | One | Two |

        [^note]: A readable footnote.
        """.write(to: file, atomically: true, encoding: .utf8)
        let html = String(decoding: try MarkdownPreview.html(for: file), as: UTF8.self)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 860), configuration: configuration)
            let delegate = PreviewNavigationDelegate()
            web.navigationDelegate = delegate
            web.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            defer { web.stopLoading(); web.navigationDelegate = nil; window.close() }
            web.loadHTMLString(html, baseURL: nil)
            for _ in 0..<500 {
                if delegate.finished || delegate.error != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if let error = delegate.error { throw error }
            try #require(delegate.finished, "WebKit did not finish loading")
            let background = try await web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
            #expect(background == (appearance == .aqua ? "rgb(255, 255, 255)" : "rgb(24, 24, 24)"))
            let scriptCount = try await web.evaluateJavaScript("document.scripts.length") as? Int
            #expect(scriptCount == 0)
            let attack = try await web.evaluateJavaScript("typeof window.previewAttack") as? String
            #expect(attack == "undefined")
            let tables = try await web.evaluateJavaScript("document.querySelectorAll('table').length") as? Int
            #expect(tables == 1)
            let broken = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('a[href^=\"#\"]')).filter(a => !document.getElementById(decodeURIComponent(a.hash.slice(1)))).length") as? Int
            #expect(broken == 0, "All heading and footnote links must have a target")
            _ = try await web.evaluateJavaScript("document.querySelector('a[href=\"#destination\"]').click()")
            let fragment = try await web.evaluateJavaScript("location.hash") as? String
            #expect(fragment == "#destination")
        }
    }
}

@MainActor private final class PreviewNavigationDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error }
}
