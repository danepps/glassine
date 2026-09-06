import Foundation
import Testing
@testable import GlassineCore

/// Holds the deliveries a fake read has handed out, so a test can fire them in
/// whatever order it likes -- which is the whole point: the real read runs on a
/// concurrent queue and its completions arrive in no fixed order at all.
private final class DeliveryQueue {
    var pending: [MarkdownReloader.Delivery] = []
}

@MainActor
@Suite("MarkdownReloader")
struct MarkdownReloaderTests {

    private func content(_ text: String) -> MarkdownContent {
        MarkdownContent(html: text,
                        headings: [],
                        stats: MarkdownStats(words: text.count),
                        hash: text.hashValue)
    }

    private func makeReloader() -> (MarkdownReloader, DeliveryQueue, () -> [String]) {
        let queue = DeliveryQueue()
        let reloader = MarkdownReloader()
        reloader.read = { _, delivery in queue.pending.append(delivery) }
        let delivered = Box()
        reloader.onContent = { delivered.values.append($0.html) }
        return (reloader, queue, { delivered.values })
    }

    private final class Box { var values: [String] = [] }

    private let url = URL(fileURLWithPath: "/tmp/glassine-reloader-test.md")

    @Test("A stale reload cannot overwrite a newer one")
    func staleCompletionIsDropped() {
        let (reloader, queue, delivered) = makeReloader()

        reloader.reload(url: url)       // revision A
        reloader.reload(url: url)       // revision B, asked for while A converts
        #expect(queue.pending.count == 2)

        // B's conversion finishes first, A's second -- the order the concurrent
        // queue can perfectly well produce, and the one the hash gate alone
        // cannot tell from a genuine new revision.
        queue.pending[1](content("B"))
        queue.pending[0](content("A"))

        #expect(delivered() == ["B"])
    }

    @Test("Reloads that finish in order are all delivered")
    func inOrderCompletionsAllArrive() {
        let (reloader, queue, delivered) = makeReloader()

        reloader.reload(url: url)
        queue.pending[0](content("A"))
        reloader.reload(url: url)
        queue.pending[1](content("B"))

        #expect(delivered() == ["A", "B"])
    }

    @Test("Only the newest of several overlapping reloads is delivered")
    func onlyTheNewestOfManyArrives() {
        let (reloader, queue, delivered) = makeReloader()

        for _ in 0..<4 { reloader.reload(url: url) }
        #expect(queue.pending.count == 4)

        queue.pending[3](content("D"))
        queue.pending[0](content("A"))
        queue.pending[2](content("C"))
        queue.pending[1](content("B"))

        #expect(delivered() == ["D"])
    }

    @Test("invalidate() retires everything in flight, and the next reload still works")
    func invalidateDropsInFlightWork() {
        let (reloader, queue, delivered) = makeReloader()

        reloader.reload(url: url)
        reloader.invalidate()           // the document closed, or the file moved
        queue.pending[0](content("A"))
        #expect(delivered().isEmpty)

        reloader.reload(url: url)
        queue.pending[1](content("B"))
        #expect(delivered() == ["B"])
    }
}
