import AppKit
import GlassineCore
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Glassine

extension MacAppTests {
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

        /// Render through the reader's PDFView hook, which calls ReaderPage.draw.
        /// The bitmap supplies only the tile's scale, translation and clip; PDFKit
        /// must place the page and its overlay inside that tile itself.
        private func findPixels(_ page: ReaderPage, in view: ReaderPDFView,
                                scale: CGFloat) throws -> (bytes: [UInt8], width: Int, height: Int) {
            let box = page.bounds(for: view.displayBox)
            let sideways = page.rotation % 180 != 0
            let size = sideways ? CGSize(width: box.height, height: box.width) : box.size
            let width = Int(ceil(size.width * scale)) + 34
            let height = Int(ceil(size.height * scale)) + 46
            let context = try #require(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 17, y: 23)
            context.scaleBy(x: scale, y: scale)
            context.clip(to: CGRect(origin: .zero, size: size))
            view.draw(page, to: context)
            let pointer = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            return (Array(UnsafeBufferPointer(start: pointer, count: width * height * 4)), width, height)
        }

        @Test("Reader Mode find ink follows native match geometry at every rotation and zoom",
              arguments: [CGFloat(0.75), 1.25, 2], ["passage", "visible"])
        func renderedFindHighlights(scale: CGFloat, query: String) throws {
            try checkRenderedFindHighlights(scale: scale, query: query, displayBox: .artBox)
        }

        /// The same defect without Reader Mode: the fixture's crop box starts at
        /// (40, 50) and three of its pages are rotated, and the overlay missed
        /// the text there too until it applied the box's transform itself.
        @Test("Find ink follows native match geometry in a shifted, rotated crop box",
              arguments: [CGFloat(0.75), 1.25, 2], ["passage", "visible"])
        func renderedFindHighlightsInCropBox(scale: CGFloat, query: String) throws {
            try checkRenderedFindHighlights(scale: scale, query: query, displayBox: .cropBox)
        }

        private func checkRenderedFindHighlights(scale: CGFloat, query: String,
                                                 displayBox: PDFDisplayBox) throws {
            let name = "GlassineFindRenderTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: name))
            let previous = Prefs.defaults
            Prefs.defaults = defaults
            defer {
                Prefs.defaults = previous
                defaults.removePersistentDomain(forName: name)
            }
            let (document, folder) = try fixture()
            defer { document.close(); try? FileManager.default.removeItem(at: folder) }
            let pdf = try #require(document.pdf)
            let pages = try readerPages(in: document)
            let matches = pdf.findString(query, withOptions: [])
            try #require(matches.count == pages.count)
            let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 900))
            view.document = pdf
            view.isInverted = true
            view.setFindMatches(matches, current: 0)
            view.displayBox = .cropBox
            let ordinary = try pages.map { try findPixels($0, in: view, scale: scale).bytes }
            for page in pages { page.readerContentBounds = presentation }
            // Merely having Reader Mode bounds must not change ordinary drawing.
            // iOS uses this same highlighter and never installs those bounds.
            for (index, page) in pages.enumerated() {
                #expect(try findPixels(page, in: view, scale: scale).bytes == ordinary[index])
            }
            view.displayBox = displayBox

            for (index, page) in pages.enumerated() {
                view.isInverted = false
                let plain = try findPixels(page, in: view, scale: scale)
                // PDFKit's permanent annotation renderer is an independent oracle
                // for the selection's position. No test transform duplicates the
                // overlay's mapping, and the fixture's real art/crop/media origins
                // all differ from the presentation bounds.
                let reference = PDFAnnotation(bounds: matches[index].bounds(for: page),
                                              forType: .square, withProperties: nil)
                reference.color = .magenta
                reference.interiorColor = .magenta
                let border = PDFBorder()
                border.lineWidth = 0
                reference.border = border
                page.addAnnotation(reference)
                let marked = try findPixels(page, in: view, scale: scale)
                page.removeAnnotation(reference)
                let count = marked.width * marked.height
                let mask = (0..<count).map { pixel in
                    let offset = pixel * 4
                    return marked.bytes[offset] > 200 && marked.bytes[offset + 1] < 80
                        && marked.bytes[offset + 2] > 200
                }
                #expect(mask.filter { $0 }.count > 100)
                // The native reference must actually cover the searched glyphs.
                #expect((0..<count).filter { mask[$0] && plain.bytes[$0 * 4] < 100 }.count > 20)
                #expect(!plain.bytes.enumerated().contains { offset, value in
                    offset % 4 == 1 && Int(value) > Int(plain.bytes[offset - 1]) + 20
                        && Int(value) > Int(plain.bytes[offset + 1]) + 20
                })

                view.isInverted = true
                // Move the current result between the first and last pages; the
                // other pages must retain fills without acquiring an outline.
                for current in [0, pages.count - 1] {
                    view.setCurrentMatchIndex(current)
                    let drawn = try findPixels(page, in: view, scale: scale)
                    var missing = 0
                    var stray = 0
                    var outline = 0
                    for y in 1..<(marked.height - 1) {
                        for x in 1..<(marked.width - 1) {
                            let pixel = y * marked.width + x
                            let offset = pixel * 4
                            let red = Int(drawn.bytes[offset])
                            let green = Int(drawn.bytes[offset + 1])
                            let blue = Int(drawn.bytes[offset + 2])
                            let ink = green > red + 20 && green > blue + 20
                            if !ink && !mask[pixel] { continue }
                            // Allow one pixel of edge antialiasing, but sample
                            // every interior pixel and the entire surrounding tile.
                            let neighbours = [-marked.width, 0, marked.width].flatMap { row in
                                [-1, 0, 1].map { mask[pixel + row + $0] }
                            }
                            if neighbours.allSatisfy({ $0 }) && !ink { missing += 1 }
                            if ink && !neighbours.contains(true) { stray += 1 }
                            if red < 30 && blue < 30 && green > 170 { outline += 1 }
                        }
                    }
                    #expect(missing == 0, "Missing match ink on page \(index), scale \(scale)")
                    #expect(stray == 0, "Stray match ink on page \(index), scale \(scale)")
                    #expect(index == current ? outline > 20 : outline == 0)
                }
                view.isInverted = false
                #expect(try findPixels(page, in: view, scale: scale).bytes == plain.bytes)
            }
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
}
