import Foundation

/// Keeps Markdown reloads in order.
///
/// `MarkdownDocumentModel.reloadFromDisk` reads and converts on a *concurrent*
/// queue, so two saves in quick succession are two conversions racing each
/// other, and the slower one can finish last however early it started. The
/// caller's only guard is a content hash, which says "these bytes differ from
/// what is on screen" -- exactly what a stale revision also says. Worse, the
/// stale revision then starts a render carrying a *newer* generation, so the
/// render-completion guard cannot catch it either, and the reader sits on the
/// older text until the file is saved again.
///
/// So every reload is stamped with a generation before it is dispatched, and a
/// completion whose generation is no longer current is dropped. `invalidate()`
/// retires everything in flight: the document is closing, or the file it points
/// at has moved.
@MainActor
public final class MarkdownReloader {

    /// Called on the main actor with the newest content only. The caller still
    /// takes the hash gate from there: a reload that decoded the same bytes it
    /// is already showing is in order, just not worth re-typesetting.
    public var onContent: ((MarkdownContent) -> Void)?

    private var generation = 0

    /// Where a reload's result is handed back. A nominal type rather than a
    /// bare closure because a closure sitting in a *stored property's* function
    /// type is non-escaping, and this one is held and called later by
    /// definition.
    package struct Delivery: Sendable {
        private let deliver: @Sendable @MainActor (MarkdownContent) -> Void

        package init(_ deliver: @escaping @Sendable @MainActor (MarkdownContent) -> Void) {
            self.deliver = deliver
        }

        @MainActor
        package func callAsFunction(_ content: MarkdownContent) { deliver(content) }
    }

    /// The read itself, so a test can deliver completions out of order without
    /// touching the disk or sleeping. Production is
    /// `MarkdownDocumentModel.reloadFromDisk`.
    package var read: (URL, Delivery) -> Void = { url, delivery in
        MarkdownDocumentModel.reloadFromDisk(url: url) { delivery($0) }
    }

    public init() {}

    /// Re-read `url` and deliver its content, unless a later reload has been
    /// asked for in the meantime.
    public func reload(url: URL) {
        generation &+= 1
        let stamp = generation
        read(url, Delivery { [weak self] content in
            guard let self, stamp == self.generation else { return }
            self.onContent?(content)
        })
    }

    /// Drop every reload still in flight.
    public func invalidate() {
        generation &+= 1
    }
}
