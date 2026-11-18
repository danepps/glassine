import Foundation
import Testing
@testable import GlassineCore

@Suite("GlassineURL")
struct GlassineURLTests {

    private let expected = URL(fileURLWithPath: "/Users/dan/My Memo.md")

    private func parse(_ s: String) -> URL? { GlassineURL.fileURL(fromString: s) }

    @Test func pathForms() {
        #expect(parse("glassine:///Users/dan/My%20Memo.md") == expected)
        #expect(parse("glassine:///Users/dan/My Memo.md") == expected)
        #expect(parse("GLASSINE:///Users/dan/My%20Memo.md") == expected)
        #expect(parse("glassine:/Users/dan/My%20Memo.md") == expected)
        #expect(parse("glassine://Users/dan/My%20Memo.md") == expected)
        #expect(parse("glassine://open/Users/dan/My%20Memo.md") == expected)
        #expect(parse("glassine:///Users/dan/My%20Memo.md#intro") == expected)
    }

    @Test func queryForms() {
        #expect(parse("glassine://open?path=/Users/dan/My%20Memo.md") == expected)
        #expect(parse("glassine://open?file=/Users/dan/My%20Memo.md") == expected)
        #expect(parse("glassine://open?url=file:///Users/dan/My%2520Memo.md") == expected)
    }

    @Test func tildeExpands() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("x.md")
        #expect(parse("glassine:~/x.md")?.path == home.path)
        #expect(parse("glassine://open?path=~/x.md")?.path == home.path)
    }

    @Test func rejectsOthers() {
        #expect(parse("https:///Users/dan/x.md") == nil)
        #expect(parse("glassine://") == nil)
        #expect(parse("glassine://open?path=") == nil)
        #expect(parse("glassine://open?path=relative/x.md") == nil)
        #expect(parse("glassine://open?url=https://example.com/x.md") == nil)
    }
}
