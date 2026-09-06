import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import GlassineCore

/// The measure-then-snap arithmetic behind the iOS outline. The prediction half
/// is pure; the snapping half runs against a real, text-bearing PDF, because the
/// whole point of it is that `findString` knows better than the model does.
@Suite("HeadingLocator")
struct HeadingLocatorTests {

    private let letter = HeadingLocator.Geometry.letter

    // MARK: Prediction

    @Test("a measured top below zero is clamped rather than paging backwards")
    func clampsNegativeTop() {
        // The first h1 of every memo measures top = -1.0.
        let heading = MeasuredHeading(index: 0, title: "Title", top: -1)
        #expect(heading.top == 0)
        let place = HeadingLocator.predict(heading, in: letter)
        #expect(place.page == 0)
        #expect(place.yFromTop == 72)
    }

    @Test("CSS px scale onto pages of printable band")
    func predictsAcrossPages() {
        // 810 CSS px x 0.8 = 648 pt = exactly one printable band.
        let second = HeadingLocator.predict(
            MeasuredHeading(index: 1, title: "Two", top: 810), in: letter)
        #expect(second == HeadingLocator.Place(page: 1, yFromTop: 72))

        // Half a band down page 0.
        let middle = HeadingLocator.predict(
            MeasuredHeading(index: 2, title: "Mid", top: 405), in: letter)
        #expect(middle.page == 0)
        #expect(abs(middle.yFromTop - 396) < 0.001)
    }

    @Test("offset flattens page and y into one comparable number")
    func offsetIsMonotonic() {
        let first = HeadingLocator.Place(page: 0, yFromTop: 700)
        let second = HeadingLocator.Place(page: 1, yFromTop: 72)
        #expect(HeadingLocator.offset(of: first, in: letter)
                < HeadingLocator.offset(of: second, in: letter))
        #expect(HeadingLocator.offset(of: second, in: letter) == 648)
    }

    // MARK: The band

    @Test("the clipped ghost on the band's lower edge is out, real text is in")
    func bandExcludesGhosts() {
        // Spike B: a carried-over heading leaves a clipped copy at exactly 720.
        #expect(!HeadingLocator.isInBand(.init(page: 3, yFromTop: 720), in: letter))
        #expect(HeadingLocator.isInBand(.init(page: 4, yFromTop: 71.9), in: letter))
        #expect(HeadingLocator.isInBand(.init(page: 0, yFromTop: 719), in: letter))
        #expect(!HeadingLocator.isInBand(.init(page: 0, yFromTop: 60), in: letter))
    }

    @Test("zero margins put the whole sheet in band")
    func tallPageBandIsTheWholeSheet() {
        let tall = HeadingLocator.Geometry(pageHeight: 14_400, margin: 0, scale: 0.8)
        #expect(tall.printableHeight == 14_400)
        #expect(HeadingLocator.isInBand(.init(page: 0, yFromTop: 0), in: tall))
        #expect(HeadingLocator.isInBand(.init(page: 1, yFromTop: 14_000), in: tall))
        #expect(!HeadingLocator.isInBand(.init(page: 1, yFromTop: 14_400), in: tall))
    }

    // MARK: Snapping

    @Test("the nearest in-band candidate wins, ghosts are skipped")
    func snapsToNearestInBandCandidate() {
        let prediction = HeadingLocator.Place(page: 2, yFromTop: 300)
        let candidates = [
            HeadingLocator.Place(page: 1, yFromTop: 720),   // ghost, and nearer
            HeadingLocator.Place(page: 0, yFromTop: 100),
            HeadingLocator.Place(page: 2, yFromTop: 340)
        ]
        #expect(HeadingLocator.snap(prediction, to: candidates, in: letter)
                == HeadingLocator.Place(page: 2, yFromTop: 340))
    }

    @Test("nothing in band means no snap, and the caller keeps the prediction")
    func snapFailsWithOnlyGhosts() {
        let prediction = HeadingLocator.Place(page: 2, yFromTop: 300)
        let ghosts = [HeadingLocator.Place(page: 1, yFromTop: 720),
                      HeadingLocator.Place(page: 2, yFromTop: 730)]
        #expect(HeadingLocator.snap(prediction, to: ghosts, in: letter) == nil)
    }

    // MARK: Filling the gaps

    @Test("place(atOffset:) is the inverse of offset(of:)")
    func placeRoundTrips() {
        for offset in [CGFloat(0), 100, 640, 648, 1_000, 5_000] {
            let place = HeadingLocator.place(atOffset: offset, in: letter)
            #expect(abs(HeadingLocator.offset(of: place, in: letter) - offset) < 0.001)
        }
        #expect(HeadingLocator.place(atOffset: 648, in: letter)
                == HeadingLocator.Place(page: 1, yFromTop: 72))
    }

    @Test("a hair short of a page boundary is the top of the next page, not the foot of this one")
    func nudgesOffThePageBoundary() {
        // A heading at the head of a page measures 71.96 rather than 72, so its
        // offset lands 0.04 pt short of the boundary.
        #expect(HeadingLocator.place(atOffset: 648 - 0.04, in: letter)
                == HeadingLocator.Place(page: 1, yFromTop: 72))
        // A point and a half short is still the previous page.
        let earlier = HeadingLocator.place(atOffset: 648 - 1.5, in: letter)
        #expect(earlier.page == 0)
        #expect(abs(earlier.yFromTop - 718.5) < 0.001)
    }

    @Test("an unlocated heading is interpolated between its located neighbours")
    func interpolatesBetweenNeighbours() {
        // Measured tops 0, 500, 1000; the middle one could not be found.
        let filled = HeadingLocator.interpolate([0, nil, 800],
                                                tops: [0, 500, 1_000],
                                                predicted: [0, 9_999, 800],
                                                scale: 0.8)
        #expect(filled == [0, 400, 800])
    }

    @Test("with only one neighbour it extrapolates on the measured scale")
    func extrapolatesFromOneSide() {
        #expect(HeadingLocator.interpolate([100, nil], tops: [0, 500],
                                           predicted: [0, 0], scale: 0.8) == [100, 500])
        #expect(HeadingLocator.interpolate([nil, 500], tops: [0, 500],
                                           predicted: [0, 0], scale: 0.8) == [100, 500])
    }

    @Test("with nothing located at all it keeps the prediction")
    func keepsThePredictionWhenNothingIsKnown() {
        #expect(HeadingLocator.interpolate([nil, nil], tops: [0, 500],
                                           predicted: [40, 440], scale: 0.8) == [40, 440])
    }

    @Test("a bookmark is never placed behind the one before it")
    func offsetsAreMonotonic() {
        // The middle heading's own prediction is a page late -- the failure
        // measured on hardware. Monotonicity is the backstop.
        let filled = HeadingLocator.interpolate([0, nil, nil, 100],
                                                tops: [0, 10, 20, 30],
                                                predicted: [0, 9_000, 9_000, 100],
                                                scale: 0.8)
        #expect(filled == filled.sorted())
        #expect(filled.last == 100)
    }

    // MARK: Against a real PDF

    /// Margin 40 rather than 72 because `makeTextPDF` insets its text by 48;
    /// the band has to contain the text the fixture actually draws.
    private var fixtureGeometry: HeadingLocator.Geometry {
        HeadingLocator.Geometry(pageHeight: 792, margin: 40, scale: 1)
    }

    @Test("findString resolves a heading the linear model only approximates")
    func locatesHeadingsInARealPDF() {
        let document = makeTextPDF(pages: ["Alpha Heading\n\nfirst page body text",
                                           "Beta Heading\n\nsecond page body text",
                                           "Gamma Heading\n\nthird page body text"])
        let geometry = fixtureGeometry
        let band = geometry.printableHeight
        // Deliberately sloppy predictions -- the right page, the wrong y -- which
        // is exactly the shape the real drift has.
        let headings = [
            MeasuredHeading(index: 0, title: "Alpha Heading", top: 300),
            MeasuredHeading(index: 1, title: "Beta Heading", top: band + 300),
            MeasuredHeading(index: 2, title: "Gamma Heading", top: 2 * band + 300)
        ]
        let located = HeadingLocator.located(headings, in: document, geometry: geometry)
        #expect(located.count == 3)
        #expect(located[0]?.page == 0)
        #expect(located[1]?.page == 1)
        #expect(located[2]?.page == 2)
        // Snapped, not predicted: the prediction was 340 pt down the sheet and
        // the text is drawn about 48 pt down it, so the PDF-space top is high.
        let top = try! #require(located[1]?.top)
        #expect(top > 700, "expected the snapped top near the head of the sheet, got \(top)")
    }

    @Test("a repeated title resolves to the copy nearest the prediction")
    func choosesTheNearestOfDuplicateTitles() {
        let document = makeTextPDF(pages: ["Notes\n\nfirst", "filler page", "Notes\n\nsecond"])
        let geometry = fixtureGeometry
        let far = MeasuredHeading(index: 7, title: "Notes",
                                  top: 2 * geometry.printableHeight + 20)
        let located = HeadingLocator.located([far], in: document, geometry: geometry)
        #expect(located[7]?.page == 2)

        let near = MeasuredHeading(index: 7, title: "Notes", top: 20)
        #expect(HeadingLocator.located([near], in: document, geometry: geometry)[7]?.page == 0)
    }

    @Test("an unfindable title falls back to the prediction alone")
    func fallsBackToThePrediction() {
        let document = makeTextPDF(pages: ["Alpha", "Beta", "Gamma"])
        let geometry = fixtureGeometry
        let missing = MeasuredHeading(index: 4,
                                      title: "A title that wrapped in print",
                                      top: geometry.printableHeight + 100)
        let located = HeadingLocator.located([missing], in: document, geometry: geometry)
        #expect(located[4]?.page == 1)
        // 40 pt margin + 100 pt into the band, expressed bottom-up.
        let top = try! #require(located[4]?.top)
        #expect(abs(top - (792 - 140)) < 0.001)
    }

    @Test("a prediction past the last page is clamped onto it")
    func clampsPastTheEnd() {
        let document = makeTextPDF(pages: ["Only page"])
        let geometry = fixtureGeometry
        let overrun = MeasuredHeading(index: 0, title: "Nowhere",
                                      top: 9 * geometry.printableHeight)
        #expect(HeadingLocator.located([overrun], in: document, geometry: geometry)[0]?.page == 0)
    }

    @Test("the located map is what applyOutline builds its bookmarks from")
    func feedsApplyOutline() {
        let document = makeTextPDF(pages: ["Alpha Heading\n\none",
                                           "Beta Heading\n\ntwo"])
        let geometry = fixtureGeometry
        let measured = [MeasuredHeading(index: 0, title: "Alpha Heading", top: 10),
                        MeasuredHeading(index: 1, title: "Beta Heading",
                                        top: geometry.printableHeight + 10)]
        let located = HeadingLocator.located(measured, in: document, geometry: geometry)
        MarkdownDocumentModel.applyOutline(
            [MarkdownHeading(level: 1, title: "Alpha Heading", index: 0),
             MarkdownHeading(level: 2, title: "Beta Heading", index: 1)],
            to: document,
            located: located)

        let root = try! #require(document.outlineRoot)
        #expect(root.numberOfChildren == 1)
        let alpha = try! #require(root.child(at: 0))
        #expect(alpha.label == "Alpha Heading")
        #expect(alpha.numberOfChildren == 1)
        let beta = try! #require(alpha.child(at: 0))
        #expect(beta.label == "Beta Heading")
        let page = try! #require(beta.destination?.page)
        #expect(document.index(for: page) == 1)
    }
}
