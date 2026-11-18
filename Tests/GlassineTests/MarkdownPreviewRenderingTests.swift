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
        let pdf = NSMutableData()
        var figureBounds = CGRect(x: 0, y: 0, width: 180, height: 120)
        let consumer = try #require(CGDataConsumer(data: pdf))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &figureBounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(figureBounds.insetBy(dx: 10, dy: 10))
        context.endPDFPage()
        context.closePDF()
        let pdfData = pdf as Data
        try pdfData.write(to: folder.appendingPathComponent("Figure.pdf"))
        let file = folder.appendingPathComponent("Preview.md")
        try """
        # Quick Look

        [Jump](#destination) and a footnote.[^note]

        <script>window.previewAttack = true</script>

        ## Destination

        | Name | Value |
        | --- | --- |
        | One | Two |

        ![Embedded PDF](data:application/pdf;base64,\(pdfData.base64EncodedString()))

        ![Local PDF](Figure.pdf)

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
            let renderedFigures = try await web.evaluateJavaScript("Array.from(document.images).filter(img => img.complete && img.naturalWidth === 180 && img.naturalHeight === 120).length") as? Int
            #expect(renderedFigures == 2, "Embedded and local PDF figures must render in both appearances")
            let broken = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('a[href^=\"#\"]')).filter(a => !document.getElementById(decodeURIComponent(a.hash.slice(1)))).length") as? Int
            #expect(broken == 0, "All heading and footnote links must have a target")
            // The link in the text, not its twin in the headings column.
            _ = try await web.evaluateJavaScript("document.querySelector('.preview-body a[href=\"#destination\"]').click()")
            let fragment = try await web.evaluateJavaScript("location.hash") as? String
            #expect(fragment == "#destination")
        }
    }

    @Test("The headings column shows beside the text at panel width, links to headings, and hides when narrow")
    func headingsColumn() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlassinePreview-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Outline.md")
        let filler = String(repeating: "A paragraph long enough to wrap across the reading column. ", count: 30)
        try """
        # Outline

        \(filler)

        ## A rather long second-level heading that will not fit in the column

        \(filler)

        ### Notes

        \(filler)

        ## Notes

        \(filler)
        """.write(to: file, atomically: true, encoding: .utf8)
        let html = String(decoding: try MarkdownPreview.html(for: file), as: UTF8.self)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            // 760 is Quick Look's default panel width (PreviewProvider's contentSize).
            try await withPreview(html, width: 760, appearance: appearance) { web in
                let display = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('nav.preview-outline')).display") as? String
                #expect(display != nil && display != "none")
                let links = try await web.evaluateJavaScript("document.querySelectorAll('nav.preview-outline a').length") as? Int
                #expect(links == 4)
                let separate = try await web.evaluateJavaScript("""
                    (() => { const nav = document.querySelector('nav.preview-outline').getBoundingClientRect();
                      const main = document.querySelector('main.preview-body').getBoundingClientRect();
                      const text = document.querySelector('main.preview-body p').getBoundingClientRect();
                      return nav.width > 0 && nav.right <= main.left && nav.right < text.left && text.width >= 400; })()
                    """) as? Bool
                #expect(separate == true, "The column must sit left of the text and leave it at least 400px")
                let background = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('nav.preview-outline')).backgroundColor") as? String
                #expect(background == (appearance == .aqua ? "rgb(255, 255, 255)" : "rgb(24, 24, 24)"))
                let decoration = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('nav.preview-outline a')).textDecorationLine") as? String
                #expect(decoration == "none")
                let truncated = try await web.evaluateJavaScript("(() => { const a = document.querySelectorAll('nav.preview-outline a')[1]; return a.scrollWidth > a.clientWidth && getComputedStyle(a).textOverflow === 'ellipsis' && a.title.startsWith('A rather long'); })()") as? Bool
                #expect(truncated == true)
                let broken = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('a[href^=\"#\"]')).filter(a => !document.getElementById(decodeURIComponent(a.hash.slice(1)))).length") as? Int
                #expect(broken == 0)
                // The second "Notes" is the repeated title: it must go to notes-1.
                _ = try await web.evaluateJavaScript("document.querySelectorAll('nav.preview-outline a')[3].click()")
                let fragment = try await web.evaluateJavaScript("location.hash") as? String
                #expect(fragment == "#notes-1")
                let scrolled = try await web.evaluateJavaScript("window.scrollY > 0 && Math.abs(document.getElementById('notes-1').getBoundingClientRect().top) < 40") as? Bool
                #expect(scrolled == true, "The click must bring the heading to the top")
                let navStays = try await web.evaluateJavaScript("document.querySelector('nav.preview-outline').getBoundingClientRect().top") as? Double
                #expect(navStays == 0, "The column is fixed while the text scrolls")
            }
            try await withPreview(html, width: 600, appearance: appearance) { web in
                let display = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('nav.preview-outline')).display") as? String
                #expect(display == "none")
                // The body is laid out as it is on a page with no column.
                let layout = try await web.evaluateJavaScript("(() => { const s = getComputedStyle(document.body); return [s.maxWidth, s.paddingLeft, s.paddingTop]; })()") as? [String]
                #expect(layout == ["864px", "30px", "32px"])
                let mainPadding = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('main.preview-body')).paddingLeft") as? String
                #expect(mainPadding == "0px")
            }
        }
    }

    private func withPreview(_ html: String, width: CGFloat, appearance: NSAppearance.Name,
                             _ body: (WKWebView) async throws -> Void) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 600), configuration: configuration)
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
        try await body(web)
    }
}

@MainActor private final class PreviewNavigationDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error }
}
