import AppKit
import CoreText
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Glassine

@Suite("Saved PDF highlights", .serialized) @MainActor
struct HighlightsTests {
    private func fixture() throws -> (GlassineDocument, URL) {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glassine-highlights-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Reading.pdf")
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in ["First passage to remember.\nSecond line with a separate thought.",
                     "Another page of useful material.\nFinal passage to remember."] {
            context.beginPDFPage(nil)
            let string = NSAttributedString(string: text, attributes: [
                .font: CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            ])
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string),
                CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 48, dy: 48), transform: nil), nil), context)
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
        let doc = try GlassineDocument(contentsOf: url, ofType: UTType.pdf.identifier)
        doc.undoManager?.groupsByEvent = false
        return (doc, folder)
    }

    private func edit(_ doc: GlassineDocument, _ action: () -> Void) {
        doc.undoManager?.beginUndoGrouping()
        action()
        doc.undoManager?.endUndoGrouping()
    }

    @Test("Multi-line and multi-page highlights persist as standard quads, with undo and redo")
    func roundTrip() throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let pdf = try #require(doc.pdf)
        let selection = try #require(pdf.selectionForEntireDocument)
        let before = try Data(contentsOf: #require(doc.fileURL))
        edit(doc) { doc.addHighlight(selection: selection, color: .yellow) }
        #expect(doc.isDocumentEdited)
        #expect(doc.savedHighlights.count == 2)
        #expect(doc.savedHighlights.allSatisfy { ($0.annotation.quadrilateralPoints?.count ?? 0) == 8 })
        #expect(try Data(contentsOf: #require(doc.fileURL)) == before)
        let bytes = try doc.data(ofType: UTType.pdf.identifier)
        let reopened = try #require(PDFDocument(data: bytes))
        #expect(reopened.pageCount == 2)
        #expect(reopened.string == pdf.string)
        for index in 0..<2 {
            let annotation = try #require(reopened.page(at: index)?.annotations.first)
            #expect(annotation.type == "Highlight")
            #expect(annotation.shouldPrint)
            #expect(annotation.contents == nil || annotation.contents == "")
            #expect(HighlightColor.yellow.matches(annotation.color))
            #expect(annotation.quadrilateralPoints?.count == 8)
            let original = doc.savedHighlights[index].annotation
            for (savedRect, originalRect) in zip(SavedHighlight.rects(for: annotation), SavedHighlight.rects(for: original)) {
                #expect(abs(savedRect.minX - originalRect.minX) < 0.001)
                #expect(abs(savedRect.minY - originalRect.minY) < 0.001)
                #expect(abs(savedRect.width - originalRect.width) < 0.001)
                #expect(abs(savedRect.height - originalRect.height) < 0.001)
            }
        }
        doc.undoManager?.undo()
        #expect(doc.savedHighlights.isEmpty)
        #expect(!doc.isDocumentEdited)
        doc.undoManager?.redo()
        #expect(doc.savedHighlights.count == 2)
        #expect(doc.isDocumentEdited)
    }

    @Test("Safe save and export include edits; recolor and deletion can be undone after saving")
    func saveAndExport() async throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let selection = try #require(doc.pdf?.findString("passage", withOptions: []).first)
        edit(doc) { doc.addHighlight(selection: selection, color: .pink) }
        var exported: Data?
        doc.pdfDataForExport { exported = try? $0.get() }
        #expect(PDFDocument(data: try #require(exported))?.page(at: 0)?.annotations.count == 1)
        let url = try #require(doc.fileURL)
        let error: Error? = await withCheckedContinuation { continuation in
            doc.save(to: url, ofType: UTType.pdf.identifier, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(!doc.isDocumentEdited)
        let saved = try #require(PDFDocument(url: url))
        #expect(saved.page(at: 0)?.annotations.count == 1)
        let highlight = try #require(doc.savedHighlights.first?.annotation)
        edit(doc) { doc.recolorHighlight(highlight, color: HighlightColor.blue.color) }
        #expect(highlight.color == HighlightColor.blue.color)
        doc.undoManager?.undo()
        #expect(highlight.color == HighlightColor.pink.color)
        #expect(!doc.isDocumentEdited)
        edit(doc) { doc.removeHighlight(highlight) }
        #expect(doc.savedHighlights.isEmpty)
        #expect(doc.isDocumentEdited)
        doc.undoManager?.undo()
        #expect(doc.savedHighlights.count == 1)
        #expect(!doc.isDocumentEdited)
        // Undoing the creation after a save must itself be an unsaved edit.
        doc.undoManager?.undo()
        #expect(doc.savedHighlights.isEmpty)
        #expect(doc.isDocumentEdited)
        doc.pdfDataForExport { exported = try? $0.get() }
        #expect(PDFDocument(data: try #require(exported))?.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test("Invalid selections and locked annotations cannot mutate documents")
    func permissions() throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let (other, otherFolder) = try fixture()
        defer { other.close(); try? FileManager.default.removeItem(at: otherFolder) }
        let foreign = try #require(other.pdf?.selectionForEntireDocument)
        #expect(doc.addHighlight(selection: foreign, color: .green).isEmpty)
        #expect(!doc.isDocumentEdited)
        let own = try #require(doc.pdf?.selectionForEntireDocument)
        edit(doc) { doc.addHighlight(selection: own, color: .green) }
        let annotation = try #require(doc.savedHighlights.first?.annotation)
        annotation.setValue(NSNumber(value: 128), forAnnotationKey: .flags)
        #expect(!doc.canEdit(annotation))
        edit(doc) { doc.removeHighlight(annotation) }
        #expect(doc.savedHighlights.count == 2)
        let markdown = folder.appendingPathComponent("Notes.md")
        try "# Notes\nSome text".write(to: markdown, atomically: true, encoding: .utf8)
        let md = try GlassineDocument(contentsOf: markdown, ofType: GlassineDocument.markdownType.identifier)
        defer { md.close() }
        #expect(!md.canEditHighlights)
        #expect(throws: (any Error).self) { try md.data(ofType: UTType.pdf.identifier) }
    }

    @Test("Sidebar navigation, refresh and mode changes preserve annotation identity")
    func sidebar() throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        edit(doc) { doc.addHighlight(selection: doc.pdf!.selectionForEntireDocument!, color: .blue) }
        let pdfView = ReaderPDFView()
        pdfView.document = doc.pdf
        pdfView.highlightDocument = doc
        let sidebar = SidebarViewController(pdfView: pdfView, isContinuousMarkdown: false)
        sidebar.highlights.document = doc
        sidebar.showHighlights()
        #expect(sidebar.showsHighlights)
        #expect(!sidebar.showsSearchResults)
        let results = sidebar.highlights
        #expect(results.table.numberOfRows == 2)
        #expect(results.highlights[0].text.contains("First passage"))
        #expect(results.highlights[1].pageReference == "Page 2")
        var selected: PDFAnnotation?
        results.onSelect = { selected = $0.annotation }
        results.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(selected === results.highlights[1].annotation)
        results.refresh()
        #expect(results.table.selectedRow == 1)
        edit(doc) { results.deleteHighlight(nil) }
        results.refresh()
        #expect(results.table.numberOfRows == 1)
        #expect(results.table.selectedRow == 0)
        sidebar.showSearchResults()
        #expect(!sidebar.showsHighlights)
        #expect(sidebar.showsSearchResults)
        sidebar.showHighlights()
        sidebar.mode = .thumbnails
        #expect(!sidebar.showsHighlights && !sidebar.showsSearchResults)
        let item = NSMenuItem(title: "Highlight", action: #selector(ReaderPDFView.highlightSelection(_:)), keyEquivalent: "")
        #expect(!pdfView.validateMenuItem(item))
        pdfView.setCurrentSelection(doc.pdf?.selectionForEntireDocument, animate: false)
        #expect(pdfView.validateMenuItem(item))
    }

    @Test("Save As preserves the source, existing annotations and rotated-page geometry")
    func saveAs() async throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let source = try #require(doc.fileURL)
        let originalBytes = try Data(contentsOf: source)
        let page = try #require(doc.pdf?.page(at: 0))
        page.rotation = 90
        page.setBounds(CGRect(x: 20, y: 30, width: 570, height: 740), for: .cropBox)
        let note = PDFAnnotation(bounds: CGRect(x: 300, y: 600, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "An existing note"
        page.addAnnotation(note)
        let selection = try #require(doc.pdf?.findString("First passage", withOptions: []).first)
        edit(doc) { doc.addHighlight(selection: selection, color: .green) }
        let destination = folder.appendingPathComponent("Annotated Copy.pdf")
        let error: Error? = await withCheckedContinuation { continuation in
            doc.save(to: destination, ofType: UTType.pdf.identifier, for: .saveAsOperation) {
                continuation.resume(returning: $0)
            }
        }
        #expect(error == nil)
        #expect(doc.fileURL == destination)
        #expect(try Data(contentsOf: source) == originalBytes)
        let reopened = try GlassineDocument(contentsOf: destination, ofType: UTType.pdf.identifier)
        defer { reopened.close() }
        #expect(reopened.savedHighlights.count == 1)
        #expect(reopened.savedHighlights.first?.text == "First passage")
        #expect(reopened.pdf?.page(at: 0)?.rotation == 90)
        #expect(reopened.pdf?.page(at: 0)?.bounds(for: .cropBox) == page.bounds(for: .cropBox))
        #expect(reopened.pdf?.page(at: 0)?.annotations.contains(where: { $0.contents == "An existing note" }) == true)
        #expect(!reopened.isDocumentEdited)
    }

    @Test("Failed saves retain unsaved edits and encrypted documents remain read-only")
    func failedSaveAndEncryption() async throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let selection = try #require(doc.pdf?.selectionForEntireDocument)
        edit(doc) { doc.addHighlight(selection: selection, color: .yellow) }
        let impossible = folder.appendingPathComponent("missing/Annotated.pdf")
        let error: Error? = await withCheckedContinuation { continuation in
            doc.save(to: impossible, ofType: UTType.pdf.identifier, for: .saveAsOperation) {
                continuation.resume(returning: $0)
            }
        }
        #expect(error != nil)
        #expect(doc.isDocumentEdited)
        #expect(doc.savedHighlights.count == 2)
        let encryptedURL = folder.appendingPathComponent("Encrypted.pdf")
        #expect(doc.pdf?.write(to: encryptedURL, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader"]) == true)
        let encrypted = try GlassineDocument(contentsOf: encryptedURL, ofType: UTType.pdf.identifier)
        defer { encrypted.close() }
        #expect(encrypted.pdf?.unlock(withPassword: "owner") == true)
        #expect(!encrypted.canEditHighlights)
        #expect(throws: (any Error).self) { try encrypted.data(ofType: UTType.pdf.identifier) }
    }

    @Test("Highlight colors render consistently inside the passage across repeated saves")
    func stableAppearance() throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let selection = try #require(doc.pdf?.findString("First passage", withOptions: []).first)
        let originalPage = try #require(doc.pdf?.page(at: 0))
        let rect = selection.bounds(for: originalPage).integral
        func meanColor(_ page: PDFPage) throws -> [Double] {
            let width = Int(rect.width), height = Int(rect.height)
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: -rect.minX, y: -rect.minY)
            page.draw(with: .mediaBox, to: context)
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<3).map { channel in
                (0..<(width * height)).reduce(0.0) { $0 + Double(pixels[$1 * 4 + channel]) }
                    / Double(width * height)
            }
        }
        let plain = try meanColor(originalPage)
        edit(doc) { doc.addHighlight(selection: selection, color: .yellow) }
        let baseline = try meanColor(originalPage)
        // A yellow highlight materially removes blue over the actual passage,
        // rather than passing on antialiasing noise elsewhere in the bitmap.
        #expect(plain[2] - baseline[2] > 40)
        #expect(baseline[0] - baseline[2] > 40)
        var current = try #require(doc.pdf)
        for _ in 0..<3 {
            let bytes = try #require(current.dataRepresentation())
            current = try #require(PDFDocument(data: bytes))
            let page = try #require(current.page(at: 0))
            let rendered = try meanColor(page)
            for channel in 0..<3 { #expect(abs(baseline[channel] - rendered[channel]) < 1) }
            #expect(page.annotations.first?.color.alphaComponent == 1)
        }
    }

    @Test("Creating highlights preserves a collapsed sidebar and its selected pane")
    func sidebarDoesNotJump() throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        doc.makeWindowControllers()
        let window = try #require(doc.windowControllers.first?.window)
        let split = try #require(window.contentViewController?.children.first as? NSSplitViewController)
        let sidebar = try #require(split.splitViewItems.first?.viewController as? SidebarViewController)
        let reader = try #require(split.splitViewItems.last?.viewController as? ReaderViewController)
        sidebar.mode = .thumbnails
        let item = try #require(split.splitViewItems.first)
        item.isCollapsed = true
        reader.pdfView.setCurrentSelection(doc.pdf?.findString("First passage", withOptions: []).first, animate: false)
        edit(doc) { reader.pdfView.highlightSelection(nil) }
        #expect(item.isCollapsed)
        #expect(sidebar.mode == .thumbnails && !sidebar.showsHighlights)
        item.isCollapsed = false
        reader.pdfView.setCurrentSelection(doc.pdf?.findString("Another page", withOptions: []).first, animate: false)
        edit(doc) { reader.pdfView.highlightSelection(nil) }
        #expect(!item.isCollapsed)
        #expect(sidebar.mode == .thumbnails && !sidebar.showsHighlights)
        #expect(doc.savedHighlights.count == 2)
        let highlight = try #require(doc.savedHighlights.first)
        reader.pdfView.layoutDocumentView()
        reader.pdfView.setCurrentSelection(doc.pdf?.findString("First passage", withOptions: []).first, animate: false)
        let rect = highlight.annotation.bounds
        let point = reader.pdfView.convert(NSPoint(x: rect.midX, y: rect.midY), from: highlight.page)
        let location = reader.pdfView.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(reader.pdfView.menu(for: event))
        let actions = menu.items.compactMap(\.action).map(NSStringFromSelector)
        #expect(actions.contains("copy:"))
        #expect(actions.contains("copyRaw:"))
        #expect(actions.contains("removeClickedHighlight:"))
        #expect(!actions.contains("_removeMarkup:") && !actions.contains("_addNote:"))
    }

    @Test("Two-column highlights follow PDF text order, including after cache invalidation")
    func columnOrder() throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        for (x, text) in [(48.0, "Left first\nLeft last"), (330.0, "Right first\nRight last")] {
            let string = NSAttributedString(string: text, attributes: [
                .font: CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            ])
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string),
                CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: x, y: 48, width: 220, height: 696),
                transform: nil), nil), context)
        }
        context.endPDFPage(); context.closePDF()
        let url = folder.appendingPathComponent("Columns.pdf")
        try (data as Data).write(to: url)
        let columns = try GlassineDocument(contentsOf: url, ofType: UTType.pdf.identifier)
        defer { columns.close() }
        columns.undoManager?.groupsByEvent = false
        for text in ["Right last", "Left last", "Right first", "Left first"] {
            let selection = try #require(columns.pdf?.findString(text, withOptions: []).first)
            edit(columns) { columns.addHighlight(selection: selection, color: .yellow) }
        }
        #expect(columns.savedHighlights.map(\.text) == ["Left first", "Left last", "Right first", "Right last"])
        let last = try #require(columns.savedHighlights.last?.annotation)
        edit(columns) { columns.removeHighlight(last) }
        #expect(columns.savedHighlights.count == 3)
        columns.undoManager?.undo()
        #expect(columns.savedHighlights.last?.text == "Right last")
    }

    @Test("Automatic saving debounces edits and persists undo and redo")
    func automaticSave() async throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let url = try #require(doc.fileURL)
        let before = try Data(contentsOf: url)
        let selection = try #require(doc.pdf?.findString("First passage", withOptions: []).first)
        edit(doc) { doc.addHighlight(selection: selection, color: .yellow) }
        let annotation = try #require(doc.savedHighlights.first?.annotation)
        try await Task.sleep(for: .milliseconds(800))
        edit(doc) { doc.recolorHighlight(annotation, color: HighlightColor.blue.color) }
        try await Task.sleep(for: .milliseconds(800))
        #expect(try Data(contentsOf: url) == before)
        for _ in 0..<40 where doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!doc.isDocumentEdited)
        #expect(PDFDocument(url: url)?.page(at: 0)?.annotations.first.map { HighlightColor.blue.matches($0.color) } == true)
        doc.undoManager?.undo()
        let undoError: Error? = await withCheckedContinuation { continuation in
            doc.flushHighlights { continuation.resume(returning: $0) }
        }
        #expect(undoError == nil)
        #expect(PDFDocument(url: url)?.page(at: 0)?.annotations.first.map { HighlightColor.yellow.matches($0.color) } == true)
        doc.undoManager?.redo()
        doc.save(nil) // Command-S flushes the redo immediately.
        for _ in 0..<40 where doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!doc.isDocumentEdited)
        #expect(PDFDocument(url: url)?.page(at: 0)?.annotations.first.map { HighlightColor.blue.matches($0.color) } == true)
    }

    @Test("Closing during the debounce saves before the close decision")
    func closeFlush() async throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        edit(doc) { doc.addHighlight(selection: doc.pdf!.selectionForEntireDocument!, color: .green) }
        let reply = HighlightCloseReply()
        let shouldClose: Bool = await withCheckedContinuation { continuation in
            reply.completion = { continuation.resume(returning: $0) }
            doc.canClose(withDelegate: reply,
                shouldClose: #selector(HighlightCloseReply.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        }
        #expect(shouldClose)
        #expect(!doc.isDocumentEdited)
        #expect(PDFDocument(url: try #require(doc.fileURL))?.page(at: 1)?.annotations.count == 1)
    }

    @Test("Quit review flushes multiple documents without an aggregate Save alert")
    func quitFlush() async throws {
        let (first, firstFolder) = try fixture()
        let (second, secondFolder) = try fixture()
        let controller = GlassineDocumentController()
        defer {
            controller.removeDocument(first); controller.removeDocument(second)
            first.close(); second.close()
            try? FileManager.default.removeItem(at: firstFolder)
            try? FileManager.default.removeItem(at: secondFolder)
        }
        for doc in [first, second] {
            controller.addDocument(doc)
            edit(doc) { doc.addHighlight(selection: doc.pdf!.selectionForEntireDocument!, color: .pink) }
        }
        let firstURL = try #require(first.fileURL), secondURL = try #require(second.fileURL)
        let reply = HighlightCloseReply()
        let reviewed: Bool = await withCheckedContinuation { continuation in
            reply.completion = { continuation.resume(returning: $0) }
            controller.reviewUnsavedDocuments(withAlertTitle: "Unsaved PDFs", cancellable: true,
                delegate: reply, didReviewAllSelector: #selector(HighlightCloseReply.controller(_:didReviewAll:contextInfo:)),
                contextInfo: nil)
        }
        #expect(reviewed)
        #expect(!first.isDocumentEdited && !second.isDocumentEdited)
        for url in [firstURL, secondURL] { #expect(PDFDocument(url: url)?.page(at: 1)?.annotations.count == 1) }
    }

    @Test("A failed automatic flush retains edits for a successful retry")
    func flushFailure() async throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let source = try #require(doc.fileURL)
        edit(doc) { doc.addHighlight(selection: doc.pdf!.selectionForEntireDocument!, color: .yellow) }
        doc.fileURL = folder.appendingPathComponent("missing/Reading.pdf")
        let failure: Error? = await withCheckedContinuation { continuation in
            doc.flushHighlights { continuation.resume(returning: $0) }
        }
        #expect(failure != nil)
        #expect(doc.isDocumentEdited && doc.undoManager?.canUndo == true)
        #expect(PDFDocument(url: source)?.page(at: 0)?.annotations.isEmpty == true)
        doc.fileURL = source
        let retry: Error? = await withCheckedContinuation { continuation in
            doc.flushHighlights { continuation.resume(returning: $0) }
        }
        #expect(retry == nil)
        #expect(!doc.isDocumentEdited)
        #expect(PDFDocument(url: source)?.page(at: 0)?.annotations.count == 1)
    }

    @Test("Revert replaces pages and undo state; direct discard cancels a pending save")
    func revertAndDiscard() async throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let url = try #require(doc.fileURL)
        let original = try Data(contentsOf: url)
        let oldPDF = doc.pdf
        edit(doc) { doc.addHighlight(selection: doc.pdf!.selectionForEntireDocument!, color: .yellow) }
        #expect(doc.savedHighlights.count == 2) // Populate the page cache.
        var replaced = false
        let observer = NotificationCenter.default.addObserver(forName: .glassineDocumentDidReplacePDF,
            object: doc, queue: nil) { _ in replaced = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        try doc.revert(toContentsOf: url, ofType: UTType.pdf.identifier)
        #expect(replaced && doc.pdf !== oldPDF)
        #expect(!doc.isDocumentEdited && doc.undoManager?.canUndo == false)
        #expect(doc.savedHighlights.isEmpty)
        #expect(GlassineDocument.canConcurrentlyReadDocuments(ofType: UTType.pdf.identifier))
        #expect(!GlassineDocument.preservesVersions)
        edit(doc) { doc.addHighlight(selection: doc.pdf!.selectionForEntireDocument!, color: .blue) }
        doc.close() // NSDocument's Don't Save/discard path must not write.
        try await Task.sleep(for: .milliseconds(1800))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("PDF backing data survives in-place replacement before an unseen page is read")
    func ownedBackingData() throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let url = try #require(doc.fileURL)
        try Data("External replacement".utf8).write(to: url)
        #expect(doc.pdf?.page(at: 1)?.string?.contains("Another page") == true)
    }

    @Test("Inherited signature fields prevent editing and saving")
    func signatureProtection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glassine-signature-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] >> >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>",
            "<< /FT /Sig /T (Signature) /Kids [5 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 4 0 R /P 3 0 R /Rect [0 0 100 30] >>"
        ]
        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let url = folder.appendingPathComponent("Signed.pdf")
        try bytes.write(to: url)
        let doc = try GlassineDocument(contentsOf: url, ofType: UTType.pdf.identifier)
        defer { doc.close() }
        #expect(doc.hasSignatureFields)
        #expect(!doc.canEditHighlights)
        #expect(throws: (any Error).self) { try doc.data(ofType: UTType.pdf.identifier) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Highlight notes save as comments and undo without changing the quoted passage")
    func notePersistence() async throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let selection = try #require(doc.pdf?.findString("First passage", withOptions: []).first)
        edit(doc) { doc.addHighlight(selection: selection, color: .yellow) }
        let highlight = try #require(doc.savedHighlights.first)
        edit(doc) { #expect(doc.setHighlightNote(highlight.annotation, text: "Compare the later holding.\n\nA second paragraph.")) }
        #expect(highlight.text == "First passage")
        #expect(highlight.note == "Compare the later holding.\n\nA second paragraph.")
        let error: Error? = await withCheckedContinuation { continuation in
            doc.flushHighlights { continuation.resume(returning: $0) }
        }
        #expect(error == nil && !doc.isDocumentEdited)
        let reopened = try GlassineDocument(contentsOf: #require(doc.fileURL), ofType: UTType.pdf.identifier)
        defer { reopened.close() }
        #expect(reopened.savedHighlights.first?.note == highlight.note)
        #expect(reopened.savedHighlights.first?.text == "First passage")
        doc.undoManager?.undo()
        #expect(highlight.annotation.contents == nil)
        #expect(doc.isDocumentEdited)
        doc.undoManager?.redo()
        #expect(highlight.note.contains("second paragraph"))
        edit(doc) { #expect(doc.setHighlightNote(highlight.annotation, text: "   \n")) }
        #expect(highlight.annotation.contents == nil)
        doc.undoManager?.undo()
        #expect(highlight.note.contains("second paragraph"))
        highlight.annotation.setValue(NSNumber(value: 128), forAnnotationKey: .flags)
        #expect(!doc.setHighlightNote(highlight.annotation, text: "Forbidden"))
        #expect(highlight.note.contains("second paragraph"))
    }

    @Test("Note editor commits only Done, supports read-only viewing and rejects detached highlights")
    func noteEditor() throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        edit(doc) { doc.addHighlight(selection: doc.pdf!.selectionForEntireDocument!, color: .green) }
        let highlight = try #require(doc.savedHighlights.first)
        let editor = HighlightNoteEditor(highlight: highlight, editable: true) { doc.setHighlightNote(highlight.annotation, text: $0) }
        _ = editor.view
        editor.textView.string = "Draft note"
        editor.cancel(nil)
        #expect(highlight.note.isEmpty)
        edit(doc) { editor.saveNote(nil) }
        #expect(highlight.note == "Draft note")
        let viewer = HighlightNoteEditor(highlight: highlight, editable: false) { _ in Issue.record("Read-only editor attempted a write"); return false }
        _ = viewer.view
        #expect(!viewer.textView.isEditable)
        #expect(viewer.textView.string == "Draft note")
        viewer.saveNote(nil)
        edit(doc) { doc.removeHighlight(highlight.annotation) }
        editor.textView.string = "Stale draft"
        edit(doc) { editor.saveNote(nil) }
        #expect(highlight.note == "Draft note")
    }

    @Test("Selected highlights copy in reading order with notes; export includes every highlight")
    func selectedMarkdown() throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        edit(doc) { doc.addHighlight(selection: doc.pdf!.selectionForEntireDocument!, color: .blue) }
        let sidebar = HighlightsViewController()
        sidebar.document = doc
        _ = sidebar.view
        let items = doc.savedHighlights
        edit(doc) { doc.setHighlightNote(items[0].annotation, text: "Useful for the introduction.") }
        sidebar.table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        sidebar.refresh()
        #expect(sidebar.table.selectedRowIndexes == IndexSet([0, 1]))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        sidebar.copySelectedHighlights(to: pasteboard)
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("2 highlights, 1 note."))
        #expect(copied.contains("**Note:** Useful for the introduction."))
        #expect(copied.contains("#page=1") && copied.contains("#page=2"))
        sidebar.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        sidebar.copySelectedHighlights(to: pasteboard)
        let one = try #require(pasteboard.string(forType: .string))
        #expect(one.contains("1 highlight, 0 notes."))
        #expect(!one.contains("First passage"))
        #expect(doc.highlightsMarkdown().contains("First passage"))
        sidebar.table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        edit(doc) { sidebar.deleteHighlight(nil) }
        #expect(doc.savedHighlights.isEmpty)
        doc.undoManager?.undo()
        #expect(doc.savedHighlights.count == 2)
    }

    @Test("The PDF note action captures its highlight and rejects a replacement document")
    func noteMenuIdentity() throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        edit(doc) { doc.addHighlight(selection: doc.pdf!.selectionForEntireDocument!, color: .yellow) }
        let annotation = try #require(doc.savedHighlights.first?.annotation)
        let view = ReaderPDFView()
        view.document = doc.pdf
        view.highlightDocument = doc
        var selected: PDFAnnotation?
        view.onEditHighlightNote = { selected = $0 }
        let item = NSMenuItem(title: "Add Note…", action: #selector(ReaderPDFView.editClickedHighlightNote(_:)), keyEquivalent: "")
        item.representedObject = annotation
        #expect(view.validateMenuItem(item))
        view.editClickedHighlightNote(item)
        #expect(selected === annotation)
        selected = nil
        view.document = PDFDocument()
        #expect(!view.validateMenuItem(item))
        view.editClickedHighlightNote(item)
        #expect(selected == nil)
    }

    @Test("Context-menu swatches capture the selection, recolor in place and reject stale documents")
    func contextColors() throws {
        let (doc, folder) = try fixture()
        defer { doc.close(); try? FileManager.default.removeItem(at: folder) }
        let view = ReaderPDFView()
        view.document = doc.pdf
        view.highlightDocument = doc
        let selection = try #require(doc.pdf?.findString("First passage", withOptions: []).first)
        view.setCurrentSelection(selection, animate: false)
        let item = view.makeHighlightMenuItem(annotation: nil)
        #expect(item.submenu == nil)
        func buttons(_ item: NSMenuItem) throws -> [HighlightColorButton] {
            let stack = try #require(item.view?.subviews.compactMap { $0 as? NSStackView }.first)
            return stack.views.compactMap { $0 as? HighlightColorButton }
        }
        let swatches = try buttons(item)
        #expect(swatches.count == 4)
        #expect(swatches.allSatisfy { $0.isEnabled })
        view.setCurrentSelection(nil, animate: false)
        edit(doc) { swatches[2].performClick(nil) }
        let highlight = try #require(doc.savedHighlights.first)
        #expect(doc.savedHighlights.count == 1)
        #expect(highlight.text == "First passage")
        #expect(HighlightColor.blue.matches(highlight.annotation.color))
        let recolor = try buttons(view.makeHighlightMenuItem(annotation: highlight.annotation))
        #expect(recolor[2].state == .on)
        edit(doc) { recolor[1].performClick(nil) }
        #expect(doc.savedHighlights.count == 1)
        #expect(HighlightColor.green.matches(highlight.annotation.color))
        let disabled = try buttons(view.makeHighlightMenuItem(annotation: nil))
        #expect(disabled.allSatisfy { !$0.isEnabled })
        view.document = PDFDocument()
        recolor[3].performClick(nil)
        #expect(HighlightColor.green.matches(highlight.annotation.color))
    }
}

@MainActor private final class HighlightCloseReply: NSObject {
    var completion: ((Bool) -> Void)?
    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion?(shouldClose)
    }
    @objc func controller(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion?(didReviewAll)
    }
}
