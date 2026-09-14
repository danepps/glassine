import AppKit
import CoreGraphics
import CoreText
import PDFKit
import Testing
@testable import Glassine

@Suite("Reader Mode content bounds", .serialized) @MainActor
struct ReaderContentBoundsTests {
    private let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    private func fixture(mediaBox: CGRect? = nil,
                         draw: (CGContext) throws -> Void) throws -> PDFDocument {
        let data = NSMutableData()
        var box = mediaBox ?? letter
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        try draw(context)
        context.endPDFPage()
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    private func drawText(_ text: String, at point: CGPoint, size: CGFloat,
                          in context: CGContext) -> CGRect {
        let string = NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, size, nil)
        ])
        let line = CTLineCreateWithAttributedString(string)
        context.textPosition = point
        CTLineDraw(line, context)
        return CTLineGetImageBounds(line, context)
    }

    private func bitmap(width: Int, height: Int,
                        draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return try #require(context.makeImage())
    }

    private func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        // Tolerance is only for floating-point conversions, not crop loss.
        outer.insetBy(dx: -0.001, dy: -0.001).contains(inner)
    }

    @Test("Text, footnotes, page numbers, vector artwork and images all contribute")
    func mixedContent() throws {
        var expected = CGRect.null
        let picture = try bitmap(width: 90, height: 45) { context in
            context.setFillColor(CGColor(red: 0.15, green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 90, height: 45))
        }
        let document = try fixture { context in
            expected = expected.union(drawText("A title with visible text", at: CGPoint(x: 90, y: 690),
                                               size: 24, in: context))
            expected = expected.union(drawText("Small footnote, still part of the page.",
                                               at: CGPoint(x: 75, y: 70), size: 8, in: context))
            expected = expected.union(drawText("17", at: CGPoint(x: 300, y: 29), size: 9, in: context))
            let figure = CGRect(x: 44, y: 190, width: 180, height: 90)
            context.draw(picture, in: figure)
            expected = expected.union(figure)
            let paleMark = CGRect(x: 535, y: 120, width: 14, height: 18)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 0.95, alpha: 1))
            context.fill(paleMark)
            expected = expected.union(paleMark)
        }
        let page = try #require(document.page(at: 0))
        #expect(page.numberOfCharacters > 0)
        let result = try #require(ReaderContentBounds.detect(on: page))
        #expect(contains(result, expected))
        #expect(result.minX > 40 && result.maxX < 553)
        #expect(result.minY > 25 && result.maxY < 718)
        #expect(result.width < letter.width && result.height < letter.height)
    }

    @Test("Scanned images are measured without relying on extractable text")
    func scannedPage() throws {
        let image = try bitmap(width: 300, height: 400) { context in
            context.setFillColor(CGColor(gray: 0.2, alpha: 1))
            context.fill(CGRect(x: 40, y: 60, width: 220, height: 280))
        }
        let box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let document = try fixture(mediaBox: box) { $0.draw(image, in: box) }
        let page = try #require(document.page(at: 0))
        #expect(page.numberOfCharacters == 0)
        let result = try #require(ReaderContentBounds.detect(on: page))
        let expected = CGRect(x: 80, y: 120, width: 440, height: 560)
        #expect(contains(result, expected))
        #expect(result.minX > 75 && result.minY > 115)
        #expect(result.maxX < 525 && result.maxY < 685)
    }

    /// Make a small PDF with an explicit page dictionary. This avoids PDFKit's
    /// save-time rewriting of a shifted media box changing the fixture's stream.
    private func rotatedFixture(_ rotation: Int) throws -> PDFDocument {
        let stream = "0 g\n80 130 240 420 re f\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [-40 50 560 850] " +
                "/CropBox [-10 90 510 790] /Rotate \(rotation) /Resources << >> /Contents 4 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream"
        ]
        var pdf = "%PDF-1.4\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 5\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return try #require(PDFDocument(data: Data(pdf.utf8)))
    }

    @Test("Rotations and shifted crop/media origins return unchanged page-space geometry")
    func rotationsAndOrigins() throws {
        let crop = CGRect(x: -10, y: 90, width: 520, height: 700)
        let artwork = CGRect(x: 80, y: 130, width: 240, height: 420)
        var reference: CGRect?
        for angle in [0, 90, 180, 270] {
            let document = try rotatedFixture(angle)
            let page = try #require(document.page(at: 0))
            #expect(page.rotation == angle)
            #expect(page.bounds(for: .cropBox) == crop)
            let boxes = [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
                .map { page.bounds(for: $0) }
            let result = try #require(ReaderContentBounds.detect(on: page))
            #expect(contains(result, artwork))
            #expect(result.minX > 77 && result.minY > 127)
            #expect(result.maxX < 323 && result.maxY < 553)
            #expect(page.rotation == angle)
            #expect([PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
                .map { page.bounds(for: $0) } == boxes)
            if let reference { #expect(result == reference) }
            reference = result
        }
    }

    @Test("Visible annotations survive even on blank pages; hidden annotations do not trim the page")
    func annotations() throws {
        let document = try fixture { _ in }
        let page = try #require(document.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 28, y: 640, width: 24, height: 24),
                                 forType: .text, withProperties: nil)
        note.shouldPrint = false
        note.shouldDisplay = true
        page.addAnnotation(note)
        note.popup?.isOpen = false
        let hidden = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 600, height: 780),
                                   forType: .square, withProperties: nil)
        hidden.shouldDisplay = false
        page.addAnnotation(hidden)
        let annotationsBeforeDetection = page.annotations.count
        let pageRef = try #require(page.pageRef)
        #expect(ReaderContentBounds.detect(pageRef: pageRef, cropBox: letter) == nil)
        let result = try #require(ReaderContentBounds.detect(on: page))
        #expect(contains(result, note.bounds))
        #expect(result.width < 30 && result.height < 30)
        let captured = ReaderContentBounds.detect(pageRef: pageRef, cropBox: letter,
                                                 annotationBounds: [note.bounds])
        #expect(captured == result)
        #expect(page.annotations.count == annotationsBeforeDetection)
        #expect(note.bounds == CGRect(x: 28, y: 640, width: 24, height: 24))
        if let popup = note.popup {
            popup.isOpen = true
            let expanded = try #require(ReaderContentBounds.detect(on: page))
            #expect(contains(expanded, popup.bounds.intersection(letter)))
            #expect(expanded.width > result.width)
        }
        page.displaysAnnotations = false
        #expect(ReaderContentBounds.detect(on: page) == nil)
    }

    @Test("Existing crop boundaries exclude hidden artwork and annotations")
    func respectsOriginalCrop() throws {
        let visible = CGRect(x: 180, y: 230, width: 220, height: 350)
        let document = try fixture { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 792))
            context.fill(visible)
        }
        let page = try #require(document.page(at: 0))
        let crop = CGRect(x: 100, y: 150, width: 400, height: 500)
        page.setBounds(crop, for: .cropBox)
        let outside = PDFAnnotation(bounds: CGRect(x: 10, y: 740, width: 20, height: 20),
                                    forType: .square, withProperties: nil)
        page.addAnnotation(outside)
        let result = try #require(ReaderContentBounds.detect(on: page))
        #expect(contains(result, visible))
        #expect(contains(crop, result))
        #expect(result.minX > 177 && result.minY > 227)
        #expect(result.maxX < 403 && result.maxY < 583)
        #expect(page.bounds(for: .cropBox) == crop)
    }

    @Test("Blank, dark, tinted and full-bleed pages retain their content")
    func blankAndFullBleed() throws {
        let blank = try fixture { _ in }
        let blankPage = try #require(blank.page(at: 0))
        #expect(ReaderContentBounds.detect(on: blankPage) == nil)
        for gray in [0.0, 0.5, 0.96] {
            let document = try fixture { context in
                context.setFillColor(CGColor(gray: gray, alpha: 1))
                context.fill(letter)
            }
            let page = try #require(document.page(at: 0))
            #expect(ReaderContentBounds.detect(on: page) == letter)
        }
        let document = try fixture { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 60, width: 70, height: 500))
        }
        let page = try #require(document.page(at: 0))
        let result = try #require(ReaderContentBounds.detect(on: page))
        #expect(result.minX == 0)
        #expect(contains(result, CGRect(x: 0, y: 60, width: 70, height: 500)))
    }

    @Test("Malformed and excessively downsampled geometry safely declines cropping")
    func boundedWork() throws {
        let document = try fixture(mediaBox: CGRect(x: 0, y: 0, width: 10_000, height: 10_000)) { _ in }
        let page = try #require(document.page(at: 0))
        let pageRef = try #require(page.pageRef)
        #expect(ReaderContentBounds.detect(on: page) == nil)
        #expect(ReaderContentBounds.detect(pageRef: pageRef,
            cropBox: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 500)) == nil)
        #expect(ReaderContentBounds.detect(pageRef: pageRef, cropBox: .zero) == nil)
        #expect(ReaderContentBounds.detect(pageRef: pageRef,
            cropBox: CGRect(x: 0, y: 0, width: 1, height: 500)) == nil)
        #expect(ReaderContentBounds.detect(pageRef: pageRef, cropBox: letter,
            annotationBounds: [CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20)]) == nil)
        #expect(ReaderContentBounds.detect(pageRef: pageRef, cropBox: letter,
            annotationBounds: Array(repeating: .zero, count: 10_001)) == nil)
    }
}
