import AppKit
import GlassineCore
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Glassine

@Suite("Reader Mode output", .serialized) @MainActor
struct ReaderModeOutputTests {
    private let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
    private let presentation = CGRect(x: 100, y: 110, width: 400, height: 590)

    /// Write the boxes directly into a source PDF. Going through PDFKit first
    /// would normalize the shifted origin before the behavior under test.
    private func fixture() throws -> (GlassineDocument, URL) {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassine-reader-output-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Shifted pages.pdf")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 4 /Kids [4 0 R 6 0 R 8 0 R 10 0 R] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        for index in 0..<4 {
            let stream = "BT /F1 16 Tf 100 660 Td (Body passage on page \(index + 1).) Tj "
                + "0 -500 Td (Footnote remains visible.) Tj ET\n"
            objects.append("""
                << /Type /Page /Parent 2 0 R /Resources << /Font << /F1 3 0 R >> >>
                /MediaBox [20 30 620 830] /CropBox [40 50 600 800]
                /BleedBox [50 60 590 780] /TrimBox [60 70 580 770]
                /ArtBox [70 80 570 760] /Rotate \(index * 90)
                /Contents \(5 + index * 2) 0 R >>
                """)
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream")
        }
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try data.write(to: url)
        let document = try GlassineDocument(contentsOf: url, ofType: UTType.pdf.identifier)
        document.undoManager?.groupsByEvent = false
        return (document, folder)
    }

    private func readerPages(in document: GlassineDocument) throws -> [ReaderPage] {
        let pdf = try #require(document.pdf)
        return try (0..<pdf.pageCount).map { index in
            try #require(pdf.page(at: index) as? ReaderPage)
        }
    }

    private func assertRect(_ actual: CGRect, equals expected: CGRect) {
        #expect(abs(actual.minX - expected.minX) < 0.001)
        #expect(abs(actual.minY - expected.minY) < 0.001)
        #expect(abs(actual.width - expected.width) < 0.001)
        #expect(abs(actual.height - expected.height) < 0.001)
    }

    /// PDFKit's page draw includes the permanent annotation appearances. The
    /// square canvas accommodates all four page rotations without rescaling one
    /// output differently from another.
    private func pixels(of page: PDFPage) throws -> [UInt8] {
        let media = page.bounds(for: .mediaBox)
        let side = Int(ceil(max(media.width, media.height) / 2)) + 4
        let context = try #require(CGContext(data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.scaleBy(x: 0.5, y: 0.5)
        page.draw(with: .mediaBox, to: context)
        let pointer = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: side * side * 4))
    }

    private func differences(_ left: [UInt8], _ right: [UInt8]) -> Int {
        abs(left.count - right.count) + zip(left, right).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    private func assertOutput(_ data: Data, matches baseline: PDFDocument) throws {
        let output = try #require(PDFDocument(data: data))
        #expect(output.pageCount == baseline.pageCount)
        #expect(output.string == baseline.string)
        for index in 0..<baseline.pageCount {
            let expected = try #require(baseline.page(at: index))
            let actual = try #require(output.page(at: index))
            #expect(actual.rotation == expected.rotation)
            for box in boxes { assertRect(actual.bounds(for: box), equals: expected.bounds(for: box)) }
            #expect(actual.annotations.count == expected.annotations.count)
            for (saved, original) in zip(actual.annotations, expected.annotations) {
                #expect(saved.type == original.type)
                #expect(saved.contents == original.contents)
                #expect(saved.shouldPrint == original.shouldPrint)
                assertRect(saved.bounds, equals: original.bounds)
                let savedRects = SavedHighlight.rects(for: saved)
                let originalRects = SavedHighlight.rects(for: original)
                #expect(savedRects.count == originalRects.count)
                for (savedRect, originalRect) in zip(savedRects, originalRects) {
                    assertRect(savedRect, equals: originalRect)
                }
            }
            #expect(try differences(pixels(of: actual), pixels(of: expected)) == 0)
        }
    }

    @MainActor private final class ReplacementNavigation {
        var reachedTarget = false
        var pagesAfterArrival: [Int] = []
    }

    private func drainPositionRestore() async {
        // ReadingPosition restores on two main-queue passes. Drain those
        // passes explicitly instead of assuming a wall-clock delay ran them.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @Test("A real revert with custom margins restores the latest position without a stale second jump")
    func customMarginsAcrossRevert() async throws {
        let (document, folder) = try fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let url = try #require(document.fileURL)
        var settings = ReaderModeSettings()
        settings.enabled = true
        settings.automatic = false
        settings.save(for: url)
        defer { ReaderModeSettings().save(for: url) }

        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ReaderWindowController)
        let window = try #require(controller.window)
        // Other suites create real reader windows concurrently. This test
        // owns its viewport geometry and must not join their native tab group.
        window.tabbingIdentifier = "reader-mode-revert-test-\(UUID())"
        window.tabbingMode = .disallowed
        controller.showWindow(nil)
        window.setContentSize(NSSize(width: 700, height: 600))
        let split = try #require(window.contentViewController?.children.first as? NSSplitViewController)
        let reader = try #require(split.splitViewItems.last?.viewController as? ReaderViewController)
        let view = reader.pdfView
        await drainPositionRestore()
        await drainPositionRestore()
        #expect(view.readerModeActive && view.displayBox == .artBox)

        let originalPDF = try #require(document.pdf)
        let targetPage = try #require(originalPDF.page(at: 2))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        view.scaleFactor = 1.5
        view.layoutDocumentView()
        view.go(to: targetPage)
        // Capture and start the revert in this same main-actor turn. Other UI
        // suites temporarily hide/show all app windows while we are suspended.
        let before = try #require(view.currentDestination)
        let beforePage = try #require(before.page)
        let targetIndex = originalPDF.index(for: beforePage)
        #expect(targetIndex == 2)
        let previousScale = view.scaleFactor

        let navigation = ReplacementNavigation()
        let originalIdentity = ObjectIdentifier(originalPDF)
        let observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged,
            object: view, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard let pdf = view.document, ObjectIdentifier(pdf) != originalIdentity,
                          let page = view.currentPage else { return }
                    let index = pdf.index(for: page)
                    if index == targetIndex { navigation.reachedTarget = true }
                    if navigation.reachedTarget { navigation.pagesAfterArrival.append(index) }
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        try document.revert(toContentsOf: url, ofType: UTType.pdf.identifier)
        await drainPositionRestore()
        await drainPositionRestore()
        let replacement = try #require(document.pdf)
        let after = try #require(view.currentDestination)
        let afterPage = try #require(after.page)
        #expect(replacement !== originalPDF && view.document === replacement)
        #expect(replacement.index(for: afterPage) == targetIndex)
        #expect(abs(after.point.x - before.point.x) < 3)
        #expect(abs(after.point.y - before.point.y) < 3)
        #expect(abs(view.scaleFactor - previousScale) < 0.001)
        #expect(view.readerModeActive && view.displayBox == .artBox)
        #expect(navigation.reachedTarget)
        // Layout may initially report page 1. Once the requested page has
        // landed, an inner margin-change restore must not jump back there.
        #expect(navigation.pagesAfterArrival.allSatisfy { $0 == targetIndex })
        for index in 0..<replacement.pageCount {
            let page = try #require(replacement.page(at: index) as? ReaderPage)
            assertRect(try #require(page.readerContentBounds),
                       equals: settings.customBounds(in: page.bounds(for: .cropBox), rotation: page.rotation))
            #expect((originalPDF.page(at: index) as? ReaderPage)?.readerContentBounds == nil)
        }
    }

    @Test("Clean export stays byte-identical and save data retains all five original boxes")
    func cleanOutput() throws {
        let (document, folder) = try fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let url = try #require(document.fileURL)
        let source = try Data(contentsOf: url)
        let pdf = try #require(document.pdf)
        let pages = try readerPages(in: document)
        #expect(pages.count == 4)
        #expect(pages[0].bounds(for: .mediaBox).origin == CGPoint(x: 20, y: 30))
        // PDFKit itself normalizes nonzero origins when rewriting. The correct
        // comparison is the ordinary serialization of this same source.
        let baselineBytes = try #require(pdf.dataRepresentation())
        let baseline = try #require(PDFDocument(data: baselineBytes))
        for page in pages { page.readerContentBounds = presentation }
        #expect(!document.isDocumentEdited)
        for page in pages {
            #expect(page.bounds(for: .artBox) == presentation)
            #expect(page.pageRef?.getBoxRect(.artBox) != presentation)
        }
        var exported: Swift.Result<Data, Error>?
        document.pdfDataForExport { exported = $0 }
        let exportResult = try #require(exported)
        #expect(try exportResult.get() == source)
        try assertOutput(document.data(ofType: UTType.pdf.identifier), matches: baseline)
        #expect(!document.isDocumentEdited)
        #expect(pages.allSatisfy { $0.bounds(for: .artBox) == presentation })
    }

    @Test("Save and edited export retain highlights while excluding trimming and temporary find ink")
    func editedOutput() async throws {
        let (document, folder) = try fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let pdf = try #require(document.pdf)
        let selection = try #require(pdf.selectionForEntireDocument)
        document.undoManager?.beginUndoGrouping()
        document.addHighlight(selection: selection, color: .yellow)
        document.undoManager?.endUndoGrouping()
        #expect(document.isDocumentEdited)
        #expect(document.savedHighlights.count == 4)
        let baselineBytes = try document.data(ofType: UTType.pdf.identifier)
        let baseline = try #require(PDFDocument(data: baselineBytes))
        for index in 0..<baseline.pageCount {
            let annotation = try #require(baseline.page(at: index)?.annotations.first)
            #expect(annotation.type == "Highlight")
            #expect(annotation.shouldPrint)
            #expect(HighlightColor.yellow.matches(annotation.color))
            #expect(annotation.quadrilateralPoints?.count == 8)
        }
        let pages = try readerPages(in: document)
        for page in pages {
            page.readerContentBounds = presentation
            page.findHighlights = [.init(rect: CGRect(x: 220, y: 330, width: 150, height: 55), isCurrent: true)]
        }
        // Positive control: the subclass's transient ink really would be
        // burned into output by an unguarded serialization.
        let unguardedBytes = try #require(pdf.dataRepresentation())
        let unguarded = try #require(PDFDocument(data: unguardedBytes))
        let unguardedPage = try #require(unguarded.page(at: 0))
        let baselinePage = try #require(baseline.page(at: 0))
        #expect(try differences(pixels(of: unguardedPage), pixels(of: baselinePage)) > 500)

        try assertOutput(document.data(ofType: UTType.pdf.identifier), matches: baseline)
        var exported: Swift.Result<Data, Error>?
        document.pdfDataForExport { exported = $0 }
        let exportResult = try #require(exported)
        try assertOutput(exportResult.get(), matches: baseline)

        let url = try #require(document.fileURL)
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: UTType.pdf.identifier, for: .saveOperation) {
                continuation.resume(returning: $0)
            }
        }
        #expect(error == nil)
        #expect(!document.isDocumentEdited)
        try assertOutput(Data(contentsOf: url), matches: baseline)
        #expect(pages.allSatisfy { $0.bounds(for: .artBox) == presentation && $0.findHighlights.count == 1 })
    }

    @Test("Nested output scopes restore presentation bounds and transient drawing after throws")
    func throwingScopes() throws {
        enum ScopeError: Error { case expected }
        let (document, folder) = try fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: folder) }
        let pages = try readerPages(in: document)
        let page = try #require(pages.first)
        let original = page.bounds(for: .artBox)
        let withoutFind = try pixels(of: page)
        page.readerContentBounds = presentation
        page.findHighlights = [.init(rect: CGRect(x: 220, y: 330, width: 150, height: 55), isCurrent: true)]
        let withFind = try pixels(of: page)
        #expect(differences(withFind, withoutFind) > 500)

        try ReaderPage.withOriginalBounds { () throws -> Void in
            #expect(page.bounds(for: .artBox) == original)
            #expect(throws: ScopeError.self) {
                try ReaderPage.withOriginalBounds {
                    #expect(page.bounds(for: .artBox) == original)
                    throw ScopeError.expected
                }
            }
            #expect(page.bounds(for: .artBox) == original)
            let guardedPixels = try pixels(of: page)
            #expect(differences(guardedPixels, withoutFind) == 0)
        }
        #expect(page.bounds(for: .artBox) == presentation)
        #expect(try differences(pixels(of: page), withFind) == 0)
        #expect(throws: ScopeError.self) {
            try ReaderPage.withOriginalBounds { throw ScopeError.expected }
        }
        #expect(page.bounds(for: .artBox) == presentation)
        #expect(try differences(pixels(of: page), withFind) == 0)
    }
}
