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
