import AppKit
import CoreText
import GlassineCore
import ObjectiveC
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Glassine

@Suite("Reader printing snapshots", .serialized) @MainActor
struct ReaderModePrintingTests {
    private let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]

    private func fixture(permissions: PDFAccessPermissions? = nil) throws -> (GlassineDocument, URL) {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassine-reader-printing-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 620)
        let text = NSAttributedString(string: "Printable original text", attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        ])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
        let plain = try #require(PDFDocument(data: data as Data))
        let page = try #require(plain.page(at: 0))
        page.rotation = 90
        for (index, box) in boxes.dropFirst().enumerated() {
            let inset = CGFloat(index * 2)
            page.setBounds(CGRect(x: 20 + inset, y: 30 + inset,
                                  width: 570 - inset * 2, height: 730 - inset * 2), for: box)
        }
        let annotation = PDFAnnotation(bounds: CGRect(x: 60, y: 400, width: 90, height: 50),
                                       forType: .square, withProperties: nil)
        annotation.color = .red
        annotation.contents = "Original annotation"
        page.addAnnotation(annotation)
        let url = folder.appendingPathComponent(permissions == nil ? "Plain.pdf" : "Encrypted.pdf")
        if let permissions {
            try #require(plain.write(to: url, withOptions: [
                .ownerPasswordOption: "owner", .userPasswordOption: "reader",
                .accessPermissionsOption: NSNumber(value: permissions.rawValue)
            ]))
        } else {
            try #require(plain.write(to: url))
        }
        return (try GlassineDocument(contentsOf: url, ofType: UTType.pdf.identifier), folder)
    }

    @Test("Ordinary printing removes transient find ink without removing saved annotations")
    func ordinaryFindSnapshot() throws {
        let (document, folder) = try fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let source = try #require(document.pdf)
        let page = try #require(source.page(at: 0) as? ReaderPage)
        let originalBoxes = boxes.map { page.bounds(for: $0) }
        let baseline = try pixels(of: page)
        #expect(page.readerContentBounds == nil)
        page.findHighlights = [.init(rect: CGRect(x: 60, y: 600, width: 220, height: 25),
                                     isCurrent: true)]
        #expect(try pixels(of: page) != baseline)

        let snapshot = try #require(document.documentForPrinting())
        let copiedPage = try #require(snapshot.page(at: 0))
        #expect(try pixels(of: copiedPage) == baseline)
        #expect(boxes.map { copiedPage.bounds(for: $0) } == originalBoxes)
        #expect(copiedPage.annotations.count == 1)
        #expect(copiedPage.annotations.first?.contents == "Original annotation")
        #expect((copiedPage as? ReaderPage)?.findHighlights.isEmpty ?? true)
        #expect(page.findHighlights.count == 1 && page.readerContentBounds == nil)
        #expect(!document.isDocumentEdited)
    }

    @Test("Unlocked user copies retain permissions and original content without reader presentation state")
    func unlockedUserSnapshot() throws {
        let (document, folder) = try fixture(permissions: .allowsHighQualityPrinting)
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let source = try #require(document.pdf)
        try #require(source.unlock(withPassword: "reader"))
        #expect(source.allowsPrinting && !source.allowsCopying)
        let page = try #require(source.page(at: 0) as? ReaderPage)
        let originalBoxes = boxes.map { page.bounds(for: $0) }
        let originalAnnotation = try #require(page.annotations.first)
        let presentation = CGRect(x: 100, y: 200, width: 300, height: 400)
        page.readerContentBounds = presentation
        page.findHighlights = [.init(rect: CGRect(x: 60, y: 600, width: 220, height: 25),
                                     isCurrent: true)]
        let snapshot = try #require(document.documentForPrinting())
        let copiedPage = try #require(snapshot.page(at: 0))
        let copiedAnnotation = try #require(copiedPage.annotations.first)
        #expect(snapshot !== source && copiedPage !== page)
        #expect(!snapshot.isLocked && snapshot.isEncrypted)
        #expect(snapshot.allowsPrinting == source.allowsPrinting)
        #expect(snapshot.permissionsStatus == source.permissionsStatus)
        #expect(snapshot.accessPermissions == source.accessPermissions)
        #expect(snapshot.pageCount == source.pageCount && snapshot.string == source.string)
        #expect(copiedPage.rotation == 90)
        #expect(boxes.map { copiedPage.bounds(for: $0) } == originalBoxes)
        #expect(copiedPage.annotations.count == page.annotations.count)
        #expect(copiedAnnotation !== originalAnnotation)
        #expect(copiedAnnotation.bounds == originalAnnotation.bounds)
        #expect(copiedAnnotation.contents == "Original annotation")
        #expect((copiedPage as? ReaderPage)?.readerContentBounds == nil)
        #expect((copiedPage as? ReaderPage)?.findHighlights.isEmpty ?? true)
        #expect(page.readerContentBounds == presentation && page.findHighlights.count == 1)
        #expect(ReaderPage.withOriginalBounds { boxes.map { page.bounds(for: $0) } } == originalBoxes)
        #expect(!document.isDocumentEdited)
    }

    @Test("Locked documents and users without printing permission cannot produce a print snapshot")
    func deniedAndLocked() throws {
        let (document, folder) = try fixture(permissions: .allowsContentCopying)
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let source = try #require(document.pdf)
        #expect(source.isLocked)
        #expect(document.documentForPrinting() == nil)
        try #require(source.unlock(withPassword: "reader"))
        #expect(!source.isLocked && !source.allowsPrinting)
        #expect(document.documentForPrinting() == nil)
        #expect(source.permissionsStatus == .user)
    }

    @Test("Owner unlock preserves owner permissions and copied annotation edits are independent")
    func ownerSnapshot() throws {
        let (document, folder) = try fixture(permissions: .allowsContentCopying)
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let source = try #require(document.pdf)
        try #require(source.unlock(withPassword: "owner"))
        let snapshot = try #require(document.documentForPrinting())
        #expect(!snapshot.isLocked && snapshot.allowsPrinting)
        #expect(snapshot.permissionsStatus == .owner)
        #expect(snapshot.accessPermissions == source.accessPermissions)
        let sourcePage = try #require(source.page(at: 0))
        let copiedPage = try #require(snapshot.page(at: 0))
        let annotation = try #require(copiedPage.annotations.first)
        copiedPage.removeAnnotation(annotation)
        #expect(copiedPage.annotations.isEmpty)
        #expect(sourcePage.annotations.count == 1)
        #expect(sourcePage.annotations.first?.contents == "Original annotation")
        #expect(!document.isDocumentEdited)
    }

    private func show(_ document: GlassineDocument) throws -> (ReaderWindowController, ReaderViewController, SidebarViewController) {
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ReaderWindowController)
        let window = try #require(controller.window)
        window.tabbingIdentifier = UUID().uuidString
        window.tabbingMode = .disallowed
        controller.showWindow(nil)
        let split = try #require(window.contentViewController?.children.first as? NSSplitViewController)
        return (controller,
                try #require(split.splitViewItems.last?.viewController as? ReaderViewController),
                try #require(split.splitViewItems.first?.viewController as? SidebarViewController))
    }

    private func resolve(_ item: NSMenuItem, in window: NSWindow) throws -> NSResponder {
        let action = try #require(item.action)
        // Swift Testing may have no application key window. Walk the actual
        // window's responder chain, then let NSMenu validate the resolved target.
        var target = window.firstResponder
        while let responder = target, !responder.responds(to: action) { target = responder.nextResponder }
        let resolved = try #require(target)
        item.target = resolved
        item.menu?.update()
        return resolved
    }

    @Test("File Print routes through the reader window from PDF, highlights, and search focus")
    func commandRoutingAndOutput() throws {
        let (document, folder) = try fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let (controller, reader, sidebar) = try show(document)
        let window = try #require(controller.window)
        let source = try #require(document.pdf)
        let page = try #require(source.page(at: 0) as? ReaderPage)
        let originalBoxes = boxes.map { page.bounds(for: $0) }
        let baseline = try pixels(of: page)
        page.readerContentBounds = CGRect(x: 100, y: 200, width: 300, height: 400)
        page.findHighlights = [.init(rect: CGRect(x: 60, y: 600, width: 220, height: 25), isCurrent: true)]

        let oldWindowsMenu = NSApp.windowsMenu, oldHelpMenu = NSApp.helpMenu
        defer { NSApp.windowsMenu = oldWindowsMenu; NSApp.helpMenu = oldHelpMenu }
        let delegate = AppDelegate(startingUpdater: false)
        let menu = MainMenu.build(appDelegate: delegate)
        let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
        let item = try #require(file.items.first { $0.title == "Print…" })
        #expect(item.action == #selector(ReaderWindowController.printReaderDocument(_:)))
        #expect(item.target == nil && item.keyEquivalent == "p" && item.keyEquivalentModifierMask == .command)
        let capture = PrintCapture()
        defer { capture.restore() }
        try capture.install()
        controller.showHighlights(nil)
        let search = try #require(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first?.searchField)
        let focusViews: [NSView] = [reader.pdfView, sidebar.highlights.table, search]
        for focus in focusViews {
            try #require(window.makeFirstResponder(focus))
            let target = try resolve(item, in: window)
            #expect(target === controller && item.isEnabled)
            target.perform(item.action, with: item)
        }
        #expect(capture.documents.count == 3)
        #expect(capture.modalWindows.count == 3)
        #expect(capture.scales == Array(repeating: PDFPrintScalingMode.pageScaleNone.rawValue, count: 3))
        #expect(capture.modalWindows.allSatisfy { $0 === window })
        for snapshot in capture.documents {
            #expect(snapshot !== source)
            let copied = try #require(snapshot.page(at: 0))
            #expect(boxes.map { copied.bounds(for: $0) } == originalBoxes)
            #expect(try pixels(of: copied) == baseline)
            #expect(copied.annotations.first?.contents == "Original annotation")
        }
        #expect(page.readerContentBounds != nil && page.findHighlights.count == 1)
        #expect(capture.errors.isEmpty)
    }

    @Test("Print validates readiness and permissions on its actual responder and rechecks direct actions")
    func commandValidation() throws {
        let (document, folder) = try fixture(permissions: .allowsContentCopying)
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let (controller, reader, _) = try show(document)
        let window = try #require(controller.window)
        let menu = NSMenu(title: "File")
        let item = NSMenuItem(title: "Print…", action: #selector(ReaderWindowController.printReaderDocument(_:)), keyEquivalent: "p")
        menu.addItem(item)
        try #require(window.makeFirstResponder(reader.pdfView))
        let target = try resolve(item, in: window)
        #expect(target === controller && !item.isEnabled)
        let capture = PrintCapture()
        defer { capture.restore() }
        try capture.install()
        controller.printReaderDocument(nil)
        let source = try #require(document.pdf)
        try #require(source.unlock(withPassword: "reader"))
        menu.update()
        #expect(!item.isEnabled)
        controller.printReaderDocument(nil)
        #expect(capture.documents.isEmpty && capture.errors.isEmpty)
        try #require(source.unlock(withPassword: "owner"))
        menu.update()
        #expect(item.isEnabled)

        let empty = GlassineDocument()
        defer { empty.close() }
        let (emptyController, _, _) = try show(empty)
        #expect(!emptyController.validateMenuItem(item))
        emptyController.printReaderDocument(nil)
        #expect(capture.documents.isEmpty)
    }

    @Test("Unexpected snapshot and print operation failures present an error", arguments: [false, true])
    func preparationFailure(_ failSnapshot: Bool) throws {
        let (document, folder) = try fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let (controller, _, _) = try show(document)
        let capture = PrintCapture()
        capture.failSnapshot = failSnapshot
        capture.failOperation = !failSnapshot
        defer { capture.restore() }
        try capture.install()
        controller.printReaderDocument(nil)
        #expect(capture.documents.count == (failSnapshot ? 0 : 1) && capture.modalWindows.isEmpty)
        #expect(capture.errors.count == 1)
        #expect(capture.errors.first?.localizedDescription.contains("could not prepare") == true)
    }

    @Test("Printing continuous Markdown typesets regular pages before opening the print operation")
    func continuousMarkdownCommand() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glassine-markdown-print-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Continuous.md")
        let markdown = "# Print fixture\n\n" + (1...100).map {
            "Paragraph \($0). This passage must remain in the paginated printed document."
        }.joined(separator: "\n\n")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let document: GlassineDocument = try {
            let priorLayout = Prefs.markdownLayout
            defer { Prefs.markdownLayout = priorLayout }
            Prefs.markdownLayout = .continuous
            return try GlassineDocument(contentsOf: url, ofType: GlassineDocument.markdownType.identifier)
        }()
        defer { document.close() }
        let (controller, reader, _) = try show(document)
        let item = NSMenuItem(title: "Print…", action: #selector(ReaderWindowController.printReaderDocument(_:)), keyEquivalent: "p")
        #expect(!controller.validateMenuItem(item))
        let renderDeadline = Date().addingTimeInterval(30)
        while document.pdf == nil && Date() < renderDeadline { try await Task.sleep(for: .milliseconds(50)) }
        let source = try #require(document.pdf)
        #expect(document.needsPaginatedOutput && controller.validateMenuItem(item))
        #expect(try #require(source.page(at: 0)).bounds(for: .mediaBox).height > 792)
        let capture = PrintCapture()
        defer { capture.restore() }
        try capture.install()
        let window = try #require(controller.window)
        try #require(window.makeFirstResponder(reader.pdfView))
        let target = try resolve(item, in: window)
        target.perform(item.action, with: item)
        let printDeadline = Date().addingTimeInterval(30)
        while capture.documents.isEmpty && capture.errors.isEmpty && Date() < printDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(capture.errors.isEmpty)
        let printed = try #require(capture.documents.first)
        #expect(printed !== source && printed.pageCount > 1)
        for index in 0..<printed.pageCount {
            #expect(try #require(printed.page(at: index)).bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        }
        #expect(printed.string?.contains("Paragraph 100.") == true)
        #expect(capture.modalWindows.count == 1)
        #expect(document.pdf === source)
    }

    /// Intercept only the native print boundary: the real command, snapshot,
    /// and Markdown renderer run, but no printer or print panel is invoked.
    @MainActor private final class PrintCapture {
        var documents: [PDFDocument] = []
        var scales: [Int] = []
        var modalWindows: [NSWindow] = []
        var errors: [NSError] = []
        var failOperation = false
        var failSnapshot = false
        private var operations: [NSPrintOperation] = []
        private var hooks: [(Method, IMP, IMP)] = []

        func install() throws {
            let operation: @convention(block) (AnyObject, AnyObject?, Int, Bool) -> AnyObject? = { object, _, scale, _ in
                if let document = object as? PDFDocument { self.documents.append(document) }
                self.scales.append(scale)
                guard !self.failOperation else { return nil }
                let operation = NSPrintOperation(view: NSView())
                self.operations.append(operation)
                return operation
            }
            try hook(PDFDocument.self, "printOperationForPrintInfo:scalingMode:autoRotate:", operation)
            // NSPrintOperation's factory returns a private concrete subclass,
            // which overrides the run method. Forward other operations so the
            // Markdown renderer's own WebKit-to-PDF printing still runs normally.
            let operationType = type(of: NSPrintOperation(view: NSView()))
            let selector = NSSelectorFromString("runOperationModalForWindow:delegate:didRunSelector:contextInfo:")
            let method = try #require(class_getInstanceMethod(operationType, selector))
            typealias Run = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?, Selector?, UnsafeMutableRawPointer?) -> Void
            let originalRun = unsafeBitCast(method_getImplementation(method), to: Run.self)
            let modal: @convention(block) (AnyObject, AnyObject, AnyObject?, Selector?, UnsafeMutableRawPointer?) -> Void = { object, window, delegate, didRun, context in
                guard self.operations.contains(where: { $0 === object }) else {
                    originalRun(object, selector, window, delegate, didRun, context)
                    return
                }
                if let window = window as? NSWindow { self.modalWindows.append(window) }
            }
            try hook(operationType, NSStringFromSelector(selector), modal)
            let error: @convention(block) (AnyObject, NSError) -> Bool = { _, error in
                self.errors.append(error)
                return false
            }
            try hook(NSDocument.self, "presentError:", error)
            if failSnapshot {
                let copy: @convention(block) (AnyObject, UnsafeMutableRawPointer?) -> AnyObject? = { _, _ in nil }
                try hook(PDFDocument.self, "copyWithZone:", copy)
            }
        }

        private func hook(_ type: AnyClass, _ selector: String, _ block: Any) throws {
            let method = try #require(class_getInstanceMethod(type, NSSelectorFromString(selector)))
            let replacement = imp_implementationWithBlock(block)
            hooks.append((method, method_setImplementation(method, replacement), replacement))
        }

        func restore() {
            for (method, original, replacement) in hooks.reversed() {
                method_setImplementation(method, original)
                imp_removeBlock(replacement)
            }
            hooks.removeAll()
        }
    }

    private func pixels(of page: PDFPage) throws -> Data {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(ceil(bounds.width))
        let height = Int(ceil(bounds.height))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
        }
        return Data(bytes)
    }
}
