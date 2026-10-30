import Foundation
import Testing
@testable import GlassineCore

@Suite("TextLinks")
struct TextLinksTests {

    /// Page 6 of the HLR "President's Read" memo, as PDFKit extracts it.
    private let politico = "(June 10, 2022 at 04:30 ET),\nhttps://www.politico.com/news/magazine/2022/06/10/ruth-bader-ginsburg-\nretire-legacy-00038638.\n3. “Consider first"
    private let full = "https://www.politico.com/news/magazine/2022/06/10/ruth-bader-ginsburg-retire-legacy-00038638"

    private func url(_ text: String, clicking needle: String) -> String? {
        let index = (text as NSString).range(of: needle).location
        return TextLinks.url(in: text, at: index)?.absoluteString
    }

    @Test func joinsAddressWrappedAfterHyphen() {
        #expect(url(politico, clicking: "politico") == full)
    }

    @Test func clickOnSecondLineFindsWholeAddress() {
        #expect(url(politico, clicking: "legacy") == full)
    }

    @Test func joinsAcrossSeveralLines() {
        let text = "See https://example.com/a-\nlong-\npath/\nend for more."
        #expect(url(text, clicking: "long") == "https://example.com/a-long-path/end")
    }

    @Test func addressOnOneLineIsUnchanged() {
        let text = "Read https://example.com/page. Then\nmore."
        #expect(url(text, clicking: "example") == "https://example.com/page")
    }

    @Test func periodAtLineEndIsASentenceEnd() {
        let text = "Read https://example.com.\nNext sentence."
        #expect(url(text, clicking: "example") == "https://example.com")
    }

    @Test func spaceOnTheSameLineIsNotJoined() {
        let text = "https://example.com/a- b"
        #expect(url(text, clicking: "example") == "https://example.com/a-")
    }

    @Test func hyphenatedProseIsNotALink() {
        let text = "a well-\nknown fact"
        #expect(url(text, clicking: "known") == nil)
        #expect(url(text, clicking: "well") == nil)
    }

    @Test func clickOffTheAddressFindsNothing() {
        #expect(url(politico, clicking: "June") == nil)
        #expect(TextLinks.url(in: politico, at: -1) == nil)
        #expect(TextLinks.url(in: politico, at: 10_000) == nil)
    }
}
