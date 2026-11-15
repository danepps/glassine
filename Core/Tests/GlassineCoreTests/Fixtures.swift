import CoreText
import Foundation
import PDFKit

/// Build a real, text-bearing PDF in memory. PDFKit's find needs extractable
/// text, so the pages are drawn with Core Text rather than filled with shapes.
func makeTextPDF(pages: [String],
                 size: CGSize = CGSize(width: 612, height: 792)) -> PDFDocument {
    guard let document = PDFDocument(data: makeTextPDFData(pages: pages, size: size)) else {
        fatalError("could not read back the PDF just written")
    }
    return document
}

/// The same bytes, undecoded, for a test that needs to build a `PDFDocument`
/// *subclass* around them.
func makeTextPDFData(pages: [String],
                     size: CGSize = CGSize(width: 612, height: 792)) -> Data {
    let output = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    guard let consumer = CGDataConsumer(data: output),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { fatalError("could not open a PDF context") }

    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    for text in pages {
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: box.insetBy(dx: 48, dy: 48), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             path, nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
    }
    context.closePDF()
    return output as Data
}

/// Pages made like a JSTOR scan: one full-page image, tagged as a Figure as
/// JSTOR tags its scans, with the text drawn invisibly over it. On macOS 27
/// PDFKit reports the image as a U+FFFC at the start of the page's text whose
/// bounds cover the page, and point hit-testing lands on it. (An *untagged*
/// image does not reproduce that: PDFKit leaves it out of the text.)
func makeScanPDFData(pages: [[String]],
                     size: CGSize = CGSize(width: 612, height: 792)) -> Data {
    let output = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    guard let consumer = CGDataConsumer(data: output),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil),
          let bitmap = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
    else { fatalError("could not open a PDF context") }
    bitmap.setFillColor(gray: 1, alpha: 1)
    bitmap.fill(box)
    guard let image = bitmap.makeImage() else { fatalError("no image") }
    let font = CTFontCreateWithName("Times-Roman" as CFString, 11, nil)

    for lines in pages {
        let framesetter = CTFramesetterCreateWithAttributedString(
            NSAttributedString(string: lines.joined(separator: "\n"), attributes: [.font: font]))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: box.insetBy(dx: 60, dy: 60), transform: nil), nil)
        context.beginPDFPage(nil)
        CGPDFContextBeginTag(context, .figure, [:] as CFDictionary)
        context.draw(image, in: box)
        CGPDFContextEndTag(context)
        let ctLines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, origin) in zip(ctLines, origins) {
            context.textPosition = CGPoint(x: 60 + origin.x, y: 60 + origin.y)
            context.setTextDrawingMode(.invisible)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    return output as Data
}

/// A blank PDF of `count` pages -- enough for outline and annotation work.
func makeBlankPDF(pageCount: Int) -> PDFDocument {
    makeTextPDF(pages: (0..<pageCount).map { "Page \($0 + 1)" })
}

/// A scratch directory that cleans itself up.
final class TempDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassineCoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ data: Data, to name: String) -> URL {
        let file = url.appendingPathComponent(name)
        try? data.write(to: file)
        return file
    }
}
