import CoreGraphics
import Foundation
import PDFKit

/// A rendered Markdown document: the PDF bytes and the `PDFDocument` built from
/// them.
public struct RenderedMarkdown {
    public let data: Data
    public let document: PDFDocument

    public init(data: Data, document: PDFDocument) {
        self.data = data
        self.document = document
    }
}

/// Whatever typesets HTML into a PDF on this platform: WebKit's print path plus
/// `NSPrintOperation` on the Mac, `UIPrintPageRenderer` / `createPDF` on iOS.
@MainActor
public protocol MarkdownTypesetter: AnyObject {
    /// `key` identifies the document: queuing a second job with the same key
    /// drops the first (its completion gets `.superseded`).
    func render(html: String,
                baseURL: URL?,
                key: String,
                layout: MarkdownLayout,
                completion: @escaping (Result<RenderedMarkdown, Error>) -> Void)
    /// Let go of whatever the typesetter is holding once nothing has needed it
    /// for a while.
    func releaseIfIdle()
}

/// Everything a Markdown document carries besides its rendered pages: the
/// `<body>` half of the HTML, the headings that become the PDF's outline, the
/// word count, and the hash of the bytes it all came from.
///
/// A value, and `Sendable`, because it is produced off the main thread -- by a
/// concurrent `read(from:)` and by the reload path -- and then handed to the
/// main actor.
public struct MarkdownContent: Sendable {
    public var html: String
    public var headings: [MarkdownHeading]
    public var stats: MarkdownStats
    /// Hash of the bytes behind this content. A reload whose bytes hash the
    /// same is dropped: an editor's flurry of writes, or a save that rewrote
    /// identical text, should not re-typeset the document.
    public var hash: Int

    public init(html: String, headings: [MarkdownHeading], stats: MarkdownStats, hash: Int) {
        self.html = html
        self.headings = headings
        self.stats = stats
        self.hash = hash
    }
}

/// The Markdown half of a document, minus the platform's document shell:
/// decoding the file, converting it, noticing when a reload actually changed
/// the bytes, and giving the rendered PDF its outline.
///
/// The Mac's `GlassineDocument` keeps the `NSDocument` shell, the file watcher,
/// the export panel and the render calls, and asks these for the content.
public enum MarkdownDocumentModel {

    /// Decode + convert. Only text work, so opening a file stays fast and the
    /// typesetting happens later; deliberately safe off the main thread,
    /// because `NSDocument` reads documents concurrently.
    public static func content(of data: Data, url: URL) throws -> MarkdownContent {
        let converted = MarkdownHTML.body(
            fromMarkdown: try MarkdownHTML.decode(data, url: url),
            baseDirectory: url.deletingLastPathComponent())
        return MarkdownContent(html: converted.html,
                               headings: converted.headings,
                               stats: converted.stats,
                               hash: data.hashValue)
    }

    /// Re-read and re-convert off the main thread, then hand the result to
    /// `reloaded` **on the main actor**, where the caller compares
    /// `content.hash` against the hash it is already showing and drops the
    /// reload if they match. The gate is taken there, and not here, because the
    /// document can have moved on while this was converting.
    ///
    /// Unreadable or undecodable bytes are ignored outright: the usual cause is
    /// a half-written file, and the next save will be along shortly.
    public typealias ReloadHandler = @MainActor @Sendable (MarkdownContent) -> Void

    public static func reloadFromDisk(url: URL, reloaded: @escaping ReloadHandler) {
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? Data(contentsOf: url),
                  let content = try? content(of: data, url: url) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { reloaded(content) }
            }
        }
    }

    // MARK: Outline

    /// Give a rendered Markdown PDF the outline no print path ever writes.
    ///
    /// `MarkdownHTML` wraps every heading in a `glassine-outline://<n>` anchor.
    /// On the Mac, WebKit's print path *does* emit a link annotation for every
    /// `<a href>`, so each annotation names one heading and says exactly where
    /// it landed; those annotations are scanned, used, and then removed --
    /// nothing on screen should link to a private scheme. Pass `located` when
    /// the platform found the headings some other way (iOS measures them in
    /// JavaScript before printing): the map is used directly and no annotation
    /// is touched.
    ///
    /// `located` maps a heading's index to the page it landed on and the y of
    /// its top edge, in PDF coordinates.
    public static func applyOutline(_ headings: [MarkdownHeading],
                                    to document: PDFDocument,
                                    located: [Int: (page: Int, top: CGFloat)]? = nil) {
        guard !headings.isEmpty else { return }

        var found: [Int: (page: Int, top: CGFloat)] = located ?? [:]
        if located == nil {
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                for annotation in page.annotations {
                    guard let url = annotation.url, url.scheme == "glassine-outline",
                          let index = url.host.flatMap(Int.init) else { continue }
                    // A heading that wraps onto two lines gets one annotation per
                    // line; the topmost is where the bookmark should point.
                    let top = annotation.bounds.maxY
                    let better = found[index].map {
                        pageIndex < $0.page || (pageIndex == $0.page && top > $0.top)
                    } ?? true
                    if better { found[index] = (pageIndex, top) }
                    page.removeAnnotation(annotation)
                }
            }
        }

        let root = PDFOutline()
        var stack: [(level: Int, node: PDFOutline)] = [(0, root)]
        var previous: PDFDestination?
        for heading in headings {
            var destination = previous
            if let hit = found[heading.index], let page = document.page(at: hit.page) {
                // PDF coordinates are bottom-up, so this is the top-left corner
                // the view scrolls to.
                destination = PDFDestination(page: page, at: CGPoint(x: 0, y: hit.top + 4))
                previous = destination
            } else if destination == nil, let first = document.page(at: 0) {
                destination = PDFDestination(
                    page: first, at: CGPoint(x: 0, y: first.bounds(for: .mediaBox).maxY))
            }
            let node = PDFOutline()
            node.label = heading.title
            node.destination = destination
            // A jump from h1 straight to h3 simply nests under the h1.
            while stack.count > 1, stack[stack.count - 1].level >= heading.level {
                stack.removeLast()
            }
            let parent = stack[stack.count - 1].node
            parent.insertChild(node, at: parent.numberOfChildren)
            stack.append((heading.level, node))
        }
        document.outlineRoot = root
    }
}
