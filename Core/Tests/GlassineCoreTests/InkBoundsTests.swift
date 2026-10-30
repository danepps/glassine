import CoreGraphics
import Foundation
import Testing
@testable import GlassineCore

/// The ink detector iOS uses to crop the tall-page fallback's last sheet. The
/// pages are drawn with plain fills: what matters is pixels, not text.
@Suite("Ink bounds")
struct InkBoundsTests {

    /// One page of `size` with each rect filled in `color` (on no background
    /// unless `paper` is given), read back as a CGPDFPage.
    private func page(size: CGSize, paper: CGColor? = nil,
                      fills: [CGRect], color: CGColor = CGColor(gray: 0, alpha: 1)) -> CGPDFPage {
        let output = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = CGDataConsumer(data: output)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        if let paper {
            context.setFillColor(paper)
            context.fill(box)
        }
        context.setFillColor(color)
        for rect in fills { context.fill(rect) }
        context.endPDFPage()
        context.closePDF()
        let document = CGPDFDocument(CGDataProvider(data: output as CFData)!)!
        return document.page(at: 1)!
    }

    private let tall = CGSize(width: 612, height: 14_400)

    @Test("detect finds a mark on an ordinary page, to within the safety margin")
    func detectOnLetter() throws {
        let mark = CGRect(x: 100, y: 200, width: 50, height: 40)
        let letter = page(size: CGSize(width: 612, height: 792), fills: [mark])
        let found = try #require(InkBounds.detect(pageRef: letter,
                                                  cropBox: CGRect(x: 0, y: 0, width: 612, height: 792)))
        #expect(found.insetBy(dx: -0.01, dy: -0.01).contains(mark))
        #expect(abs(found.minY - mark.minY) < 4 && abs(found.maxX - mark.maxX) < 4)
        #expect(InkBounds.detect(pageRef: page(size: CGSize(width: 612, height: 792), fills: []),
                                 cropBox: CGRect(x: 0, y: 0, width: 612, height: 792)) == nil)
    }

    @Test("detect declines a region too tall to rasterise usefully")
    func detectDeclinesTallPage() {
        let sheet = page(size: tall, fills: [CGRect(x: 72, y: 13_000, width: 400, height: 300)])
        #expect(InkBounds.detect(pageRef: sheet,
                                 cropBox: CGRect(origin: .zero, size: tall)) == nil)
    }

    @Test("lowestInk finds an image-like block far below the text on a 14,400 pt sheet")
    func lowestInkOnTallSheet() throws {
        // "Text" near the top, and a diagram 2,000 pt further down: the case
        // the text-only crop used to cut off.
        let text = CGRect(x: 72, y: 13_900, width: 400, height: 12)
        let diagram = CGRect(x: 72, y: 11_500, width: 300, height: 400)
        let sheet = page(size: tall, fills: [text, diagram])
        let lowest = try #require(InkBounds.lowestInk(pageRef: sheet,
                                                      in: CGRect(origin: .zero, size: tall)))
        #expect(lowest <= diagram.minY && lowest > diagram.minY - 8)
    }

    @Test("lowestInk is nil on a blank region and reaches the foot on tinted paper")
    func lowestInkBlankAndTinted() throws {
        let blank = page(size: tall, fills: [])
        #expect(InkBounds.lowestInk(pageRef: blank, in: CGRect(origin: .zero, size: tall)) == nil)

        // A paper colour painted edge to edge is ink everywhere; the iOS
        // caller recognises it by its reaching the sheet's own foot.
        let tinted = page(size: tall, paper: CGColor(red: 1, green: 0.98, blue: 0.94, alpha: 1),
                          fills: [CGRect(x: 72, y: 13_900, width: 400, height: 12)])
        let lowest = try #require(InkBounds.lowestInk(pageRef: tinted,
                                                      in: CGRect(origin: .zero, size: tall)))
        #expect(lowest == 0)
    }
}
