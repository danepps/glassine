import AppKit
import CoreText
import GlassineCore
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
