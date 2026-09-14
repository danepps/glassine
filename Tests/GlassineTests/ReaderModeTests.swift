import AppKit
import CoreText
import GlassineCore
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Glassine

@Suite("Reader Mode", .serialized) @MainActor
struct ReaderModeTests {
    private func fixture(pages: Int = 3) throws -> (GlassineDocument, URL) {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reader-mode-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<pages {
            context.beginPDFPage(nil)
            let text = NSAttributedString(string:
                "Reader Mode page \(index + 1). A passage for selection and highlighting. " +
                String(repeating: "A useful paragraph with room around it. ", count: 38),
                attributes: [.font: CTFontCreateWithName("Times-Roman" as CFString, 14, nil)])
            let path = CGPath(rect: CGRect(x: 92, y: 112, width: 428, height: 576), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text),
                CFRange(location: 0, length: 0), path, nil), context)
            context.setFillColor(CGColor(gray: 0.25, alpha: 1))
            context.fill(CGRect(x: 110, y: 85, width: 380, height: 2))
            context.endPDFPage()
        }
        context.closePDF()
        let url = folder.appendingPathComponent("Reading.pdf")
        try (data as Data).write(to: url)
        return (try GlassineDocument(contentsOf: url, ofType: UTType.pdf.identifier), folder)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Reader Mode did not settle")
    }

    private func assertRect(_ actual: CGRect, equals expected: CGRect) {
        #expect(abs(actual.minX - expected.minX) < 0.001)
        #expect(abs(actual.minY - expected.minY) < 0.001)
        #expect(abs(actual.width - expected.width) < 0.001)
        #expect(abs(actual.height - expected.height) < 0.001)
    }

    private func showReader(for document: GlassineDocument) throws -> (ReaderWindowController, NSWindow, ReaderViewController) {
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ReaderWindowController)
        let window = try #require(controller.window)
        window.tabbingIdentifier = UUID().uuidString
        window.tabbingMode = .disallowed
        controller.showWindow(nil)
        let split = try #require(window.contentViewController?.children.first as? NSSplitViewController)
        let reader = try #require(split.splitViewItems.last?.viewController as? ReaderViewController)
        return (controller, window, reader)
    }

    @Test("Reader width follows window resizing with legacy scrollers and deferred fit notifications")
    func resizeFitting() async throws {
        let (document, folder) = try fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let (controller, window, reader) = try showReader(for: document)
        let view = reader.pdfView
        let scroll = try #require(view.documentView?.enclosingScrollView)
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        controller.toggleReaderMode(nil)
        try await waitUntil { view.readerModeActive }
        try await Task.sleep(for: .milliseconds(60))
        let pdf = try #require(document.pdf)
        let widths = (0..<pdf.pageCount).compactMap {
            (pdf.page(at: $0) as? ReaderPage)?.readerContentBounds?.width
        }
        let widest = try #require(widths.max())
        func visibleWidth() -> CGFloat {
            view.convert(scroll.contentView.bounds, from: scroll.contentView).width
        }

        for width: CGFloat in [840, 1120, 760] {
            // Deliver a fit notification on a later pass, as PDFKit is free to do.
            NotificationCenter.default.post(name: .PDFViewScaleChanged, object: view)
            window.setContentSize(NSSize(width: width, height: 700))
            window.contentView?.layoutSubtreeIfNeeded()
            try await waitUntil {
                abs(view.scaleFactor * widest - (visibleWidth() - 32)) < 0.1
            }
            #expect(visibleWidth() < view.bounds.width)
        }

        reader.actualSize(nil)
        window.setContentSize(NSSize(width: 1040, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        #expect(abs(view.scaleFactor - 1) < 0.001)
        reader.zoomToFit(nil)
        window.setContentSize(NSSize(width: 900, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitUntil {
            abs(view.scaleFactor * widest - (visibleWidth() - 32)) < 0.1
        }
    }

    @Test("New annotations expand only necessary crops without restarting content analysis")
    func annotationUpdates() async throws {
        let (document, folder) = try fixture(pages: 6)
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let pdf = try #require(document.pdf)
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        view.document = pdf
        let mode = ReaderModeController(document: document, pdfView: view)
        var scans = 0
        mode.onPreparationChanged = { if $0 { scans += 1 } }
        mode.toggle()
        #expect(mode.isPreparing)
        let first = try #require(pdf.page(at: 0) as? ReaderPage)
        let early = PDFAnnotation(bounds: CGRect(x: 18, y: 730, width: 25, height: 18),
                                  forType: .square, withProperties: nil)
        first.addAnnotation(early)
        mode.annotationsDidChange(on: [first])
        #expect(scans == 1)
        try await waitUntil { view.readerModeActive }
        #expect(try #require(first.readerContentBounds).contains(early.bounds))
        let untouched = try #require(pdf.page(at: 2) as? ReaderPage)
        let originalBounds = untouched.readerContentBounds
        let second = try #require(pdf.page(at: 1) as? ReaderPage)
        let late = PDFAnnotation(bounds: CGRect(x: 555, y: 40, width: 30, height: 24),
                                 forType: .square, withProperties: nil)
        #expect(!(second.readerContentBounds?.contains(late.bounds) ?? true))
        second.addAnnotation(late)
        mode.annotationsDidChange(on: [second])
        #expect(try #require(second.readerContentBounds).contains(late.bounds))
        #expect(untouched.readerContentBounds == originalBounds)
        #expect(scans == 1 && !mode.isPreparing)
    }

    @Test("Margin slider updates share a layout transaction and cannot reapply after disabling")
    func coalescedMargins() async throws {
        let (document, folder) = try fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        view.document = document.pdf
        let mode = ReaderModeController(document: document, pdfView: view)
        var transactions = 0
        mode.preservePosition = { changes in transactions += 1; changes() }
        var options = mode.settings
        options.automatic = false
        mode.update(options)
        mode.toggle()
        let page = try #require(document.pdf?.page(at: 0) as? ReaderPage)
        let initial = page.readerContentBounds
        for trim in [0.12, 0.14, 0.18] {
            options = mode.settings
            options.left = trim
            mode.update(options)
        }
        #expect(transactions == 1 && page.readerContentBounds == initial)
        #expect(ReaderModeSettings.load(for: document.fileURL).left == 0.18)
        try await waitUntil { transactions == 2 }
        assertRect(try #require(page.readerContentBounds),
                   equals: mode.settings.customBounds(in: page.bounds(for: .cropBox), rotation: 0))
        options.left = 0.2
        mode.update(options)
        mode.toggle()
        let afterDisable = transactions
        try await Task.sleep(for: .milliseconds(60))
        #expect(transactions == afterDisable && !view.readerModeActive)
        #expect(page.readerContentBounds == nil)
    }

    @Test("Unlocking restores saved Reader Mode and reading position", arguments: [true, false])
    func unlockedReader(automatic: Bool) async throws {
        let (source, folder) = try fixture()
        let url = folder.appendingPathComponent("Locked.pdf")
        defer { source.close(); try? FileManager.default.removeItem(at: folder) }
        try #require(source.pdf?.write(to: url, withOptions: [
            .ownerPasswordOption: "owner", .userPasswordOption: "reader"
        ]) == true)
        let document = try GlassineDocument(contentsOf: url, ofType: UTType.pdf.identifier)
        defer { document.close() }
        var options = ReaderModeSettings()
        options.enabled = true
        options.automatic = automatic
        options.save(for: url)
        Prefs.setLastPosition(.init(pageIndex: 1, x: 100, y: 500), for: url)
        let (_, _, reader) = try showReader(for: document)
        let view = reader.pdfView
        let pdf = try #require(document.pdf)
        #expect(pdf.isLocked && !view.readerModeActive)
        try await Task.sleep(for: .milliseconds(60))
        try #require(pdf.unlock(withPassword: "reader"))
        let targetPage = try #require(pdf.page(at: 1) as? ReaderPage)
        try await waitUntil { view.readerModeActive && view.currentPage === targetPage }
        try await Task.sleep(for: .milliseconds(60))
        #expect(try #require(targetPage.readerContentBounds).width < targetPage.bounds(for: .cropBox).width)
        #expect(abs((view.currentDestination?.point.y ?? 0) - 500) < 2)
        #expect(ReaderModeSettings.load(for: url).enabled)
        #expect(!document.isDocumentEdited)
    }

    @Test("Automatic trimming keeps position and selections, remembers the file, and restores original layout")
    func automaticLifecycle() async throws {
        let (document, folder) = try fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ReaderWindowController)
        let window = try #require(controller.window)
        window.tabbingIdentifier = UUID().uuidString
        window.tabbingMode = .disallowed
        controller.showWindow(nil)
        let split = try #require(window.contentViewController?.children.first as? NSSplitViewController)
        let reader = try #require(split.splitViewItems.last?.viewController as? ReaderViewController)
        let view = reader.pdfView
        let pdf = try #require(document.pdf)
        let page = try #require(pdf.page(at: 1) as? ReaderPage)
        try await Task.sleep(for: .milliseconds(60))
        view.autoScales = false
        view.scaleFactor = 1.25
        view.layoutDocumentView()
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 100, y: 500)))
        let before = try #require(view.currentDestination)
        let crop = page.bounds(for: .cropBox)
        let source = try Data(contentsOf: #require(document.fileURL))
        let text = try #require(page.string)
        let range = try #require(text.range(of: "passage"))
        let selection = try #require(page.selection(for: NSRange(range, in: text)))
        view.setCurrentSelection(selection, animate: false)
        controller.toggleReaderMode(nil)
        try await waitUntil { view.readerModeActive }
        try await Task.sleep(for: .milliseconds(60))
        #expect(view.displayBox == .artBox && !view.autoScales)
        #expect(view.currentPage === page)
        #expect(abs((view.currentDestination?.point.y ?? 0) - before.point.y) < 2)
        let content = try #require(page.readerContentBounds)
        #expect(content.width < crop.width && content.height < crop.height)
        #expect(content.contains(CGRect(x: 110, y: 85, width: 380, height: 2)))
        #expect(page.bounds(for: .cropBox) == crop)
        #expect(view.currentSelection?.string == selection.string)
        #expect(!document.isDocumentEdited)
        #expect(try Data(contentsOf: #require(document.fileURL)) == source)
        #expect(ReaderModeSettings.load(for: document.fileURL).enabled)

        let scale = view.scaleFactor
        view.go(to: try #require(pdf.page(at: 2)))
        #expect(view.scaleFactor == scale)
        view.scaleFactor = scale * 1.2
        let deliberateScale = view.scaleFactor
        window.setContentSize(NSSize(width: 800, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(view.scaleFactor - deliberateScale) < 0.001)
        reader.zoomToFit(nil)
        #expect(view.scaleFactor != deliberateScale)

        controller.toggleReaderMode(nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!view.readerModeActive && view.displayBox == .cropBox)
        #expect(page.readerContentBounds == nil)
        #expect(!view.autoScales && abs(view.scaleFactor - 1.25) < 0.001)
        #expect(!ReaderModeSettings.load(for: document.fileURL).enabled)
    }

    @Test("Cancellation, document replacement and custom margins never apply stale page bounds")
    func replacementAndCustomMargins() async throws {
        let (document, folder) = try fixture(pages: 5)
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        view.document = document.pdf
        view.autoScales = true
        let mode = ReaderModeController(document: document, pdfView: view)
        mode.toggle()
        #expect(mode.isPreparing)
        mode.toggle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!view.readerModeActive && view.displayBox == .cropBox)

        var options = mode.settings
        options.automatic = false
        options.left = 0.1
        options.right = 0.2
        options.top = 0.05
        options.bottom = 0.15
        mode.update(options)
        mode.toggle()
        let first = try #require(document.pdf?.page(at: 0) as? ReaderPage)
        assertRect(try #require(first.readerContentBounds), equals: CGRect(x: 61.2, y: 118.8, width: 428.4, height: 633.6))
        let panel = ReaderModeSettingsController(settings: mode.settings) { mode.update($0) }
        let content = try #require(panel.window?.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(content.fittingSize.width > 300)
        panel.close()
        let old = try #require(document.pdf)
        mode.toggle()
        options = mode.settings
        options.automatic = true
        mode.update(options)
        mode.toggle()
        view.document = nil
        mode.documentDidChange()
        try await Task.sleep(for: .milliseconds(100))
        #expect((old.page(at: 0) as? ReaderPage)?.readerContentBounds == nil)
        #expect(!mode.isPreparing && !view.readerModeActive)
    }

    @Test("Custom trims follow displayed edges on rotated pages and invalid preferences are bounded")
    func settingsAndRotation() {
        var settings = ReaderModeSettings()
        settings.automatic = false
        settings.left = 0.1
        settings.right = 0.2
        settings.top = 0.05
        settings.bottom = 0.15
        let box = CGRect(x: -20, y: 30, width: 600, height: 800)
        assertRect(settings.customBounds(in: box, rotation: 90), equals: CGRect(x: 10, y: 110, width: 480, height: 560))
        assertRect(settings.customBounds(in: box, rotation: 180), equals: CGRect(x: 100, y: 70, width: 420, height: 640))
        assertRect(settings.customBounds(in: box, rotation: 270), equals: CGRect(x: 70, y: 190, width: 480, height: 560))
        settings.padding = .nan
        settings.left = -.infinity
        settings.right = 2
        #expect(settings.validated.padding == 12)
        #expect(settings.validated.left == 0.1 && settings.validated.right == 0.4)
    }

    @Test("A newer reading-position restore supersedes queued jumps and replacement documents")
    func restoreGeneration() async throws {
        let (document, folder) = try fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let pdf = try #require(document.pdf)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        view.document = pdf
        let position = ReadingPosition(pdfView: view, saved: nil, url: { nil })
        var completions: [Int] = []
        position.beginInstall()
        position.aim(in: pdf, target: .init(pageIndex: 1, x: 0, y: 700)) { completions.append(1) }
        position.beginInstall()
        position.aim(in: pdf, target: .init(pageIndex: 2, x: 0, y: 600)) { completions.append(2); position.finishInstall() }
        try await waitUntil { !completions.isEmpty }
        #expect(completions == [2] && view.currentPage === pdf.page(at: 2))
        position.beginInstall()
        position.aim(in: pdf, target: .init(pageIndex: 1, x: 0, y: 700)) { completions.append(3) }
        view.document = PDFDocument(data: try Data(contentsOf: #require(document.fileURL)))
        try await Task.sleep(for: .milliseconds(40))
        #expect(completions == [2] && !position.restoreFinished)
    }
}
