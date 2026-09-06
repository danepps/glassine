import CoreGraphics
import Foundation
import PDFKit

/// One heading as JavaScript measured it in the laid-out page, before printing.
///
/// `top` is `getBoundingClientRect().top + scrollY` in CSS px, clamped at 0 --
/// the first `h1` measures −1.0 (margin collapsing plus the anchor's own box)
/// and the raw arithmetic would put it on page −1.
public struct MeasuredHeading: Sendable, Equatable {
    /// The integer the `glassine-outline://<n>` anchor carries, i.e.
    /// `MarkdownHeading.index`.
    public let index: Int
    public let title: String
    public let top: CGFloat

    public init(index: Int, title: String, top: CGFloat) {
        self.index = index
        self.title = title
        self.top = max(top, 0)
    }
}

/// Where each heading of a rendered Markdown document landed, for the print
/// paths that emit no link annotations.
///
/// macOS gets the answer for free: WebKit's print path writes a link annotation
/// per `<a href>`, so `MarkdownDocumentModel.applyOutline` reads the positions
/// straight out of the PDF. Every `UIPrintPageRenderer` output on iOS has **no
/// annotations at all** (Spike B), so the position has to be recovered, and a
/// linear model of the measurement is not good enough on its own: `topCSS × 0.8`
/// places the first headings exactly and then runs monotonically ahead of the
/// print as each page break inserts slack the model cannot see -- −108 pt by
/// page 8 of an eight-page memo.
///
/// So: **measure, then snap.** The measurement gives order and a starting page;
/// `PDFDocument.findString` gives the exact position of the title; the hit
/// nearest the prediction wins among duplicates, and the prediction alone is the
/// fallback when the title cannot be found (a heading that wraps in print).
///
/// Two rules, both from Spike B and both load-bearing:
/// - **Ignore hits outside the printable band.** The print path leaves a
///   *clipped ghost copy* of every carried-over heading in the bottom margin of
///   the page it left: invisible in the render, present in `page.string` and in
///   `findString`, sitting exactly on the band's lower edge.
/// - **Clamp a negative measured top to 0**, which `MeasuredHeading` does.
public enum HeadingLocator {

    /// The geometry a prediction is made against: the sheet, its margins, and
    /// the CSS px → pt factor WebKit's minimum shrink imposes.
    public struct Geometry: Sendable, Equatable {
        /// Height of the printed sheet in points (792 for Letter; 14,400 for the
        /// tall-page fallback a continuous document past CoreGraphics' page cap
        /// uses).
        public let pageHeight: CGFloat
        /// Top *and* bottom margin, in points. Zero for the tall-page fallback.
        public let margin: CGFloat
        /// pt per CSS px. `1 / 1.25` wherever WebKit's minimum shrink applies.
        public let scale: CGFloat

        public init(pageHeight: CGFloat, margin: CGFloat, scale: CGFloat) {
            self.pageHeight = pageHeight
            self.margin = margin
            self.scale = scale
        }

        /// US Letter with one-inch margins, printed through
        /// `UIPrintPageRenderer` after WebKit's 1.25 shrink.
        public static let letter = Geometry(pageHeight: 792, margin: 72, scale: 0.8)

        /// Height of the text block on one sheet.
        public var printableHeight: CGFloat { max(pageHeight - 2 * margin, 1) }
    }

    /// A place on a printed sheet: the page it is on, and how far below the
    /// *top of the sheet* it sits, in points. (Not PDF coordinates, which run
    /// the other way; `located(...)` does that conversion at the end.)
    public struct Place: Sendable, Equatable {
        public let page: Int
        public let yFromTop: CGFloat

        public init(page: Int, yFromTop: CGFloat) {
            self.page = page
            self.yFromTop = yFromTop
        }
    }

    /// How far down the *whole document's text block* a place sits, so two
    /// places on different pages compare as one number.
    public static func offset(of place: Place, in geometry: Geometry) -> CGFloat {
        CGFloat(place.page) * geometry.printableHeight + (place.yFromTop - geometry.margin)
    }

    /// The linear prediction: the measured CSS offset scaled into points and
    /// laid across the pages' text blocks.
    public static func predict(_ heading: MeasuredHeading, in geometry: Geometry) -> Place {
        let points = heading.top * geometry.scale
        let page = max(Int(floor(points / geometry.printableHeight)), 0)
        let into = points - CGFloat(page) * geometry.printableHeight
        return Place(page: page, yFromTop: geometry.margin + into)
    }

    /// True when a place is inside the sheet's printable band. The upper edge is
    /// strict: a clipped ghost sits exactly on it.
    ///
    /// A little slack at the top, because a heading's own box can start a
    /// fraction of a point above the margin (measured: 71.9 for the first `h1`
    /// of a memo whose margin is 72).
    public static func isInBand(_ place: Place, in geometry: Geometry) -> Bool {
        let floor = geometry.margin - 2
        let ceiling = geometry.pageHeight - geometry.margin - 0.5
        return place.yFromTop >= floor && place.yFromTop < ceiling
    }

    /// The candidate nearest the prediction, ignoring anything outside the
    /// printable band. Nil when nothing survives, which is the caller's cue to
    /// keep the prediction.
    public static func snap(_ prediction: Place,
                            to candidates: [Place],
                            in geometry: Geometry) -> Place? {
        let target = offset(of: prediction, in: geometry)
        var best: Place?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for candidate in candidates where isInBand(candidate, in: geometry) {
            let distance = abs(offset(of: candidate, in: geometry) - target)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }

    /// Every place in `document` whose text is `title`, as `findString` reports
    /// them. Out-of-band ghosts are left in: `snap` is what discards them, and a
    /// test wants to see that they were there.
    public static func candidates(for title: String, in document: PDFDocument) -> [Place] {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return document.findString(needle, withOptions: []).compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            let index = document.index(for: page)
            guard index != NSNotFound else { return nil }
            let bounds = selection.bounds(for: page)
            // PDF y grows upwards, so the top edge of the text is maxY.
            let yFromTop = page.bounds(for: .mediaBox).maxY - bounds.maxY
            return Place(page: index, yFromTop: yFromTop)
        }
    }

    /// The inverse of `offset(of:in:)`.
    ///
    /// With one asymmetry, and it is load-bearing: a heading at the *head* of a
    /// page measures a hair above the top margin (71.96 for a 72 pt margin, the
    /// anchor's own box), so its offset is a hair below a page boundary and the
    /// plain arithmetic puts it at the very foot of the page before -- inside
    /// the bottom margin, where nothing is drawn, and a page behind where it
    /// really is. Anything within a point of the foot of the band is therefore
    /// read as the top of the next page.
    public static func place(atOffset offset: CGFloat, in geometry: Geometry) -> Place {
        let clamped = max(offset, 0)
        var page = Int(floor(clamped / geometry.printableHeight))
        var into = clamped - CGFloat(page) * geometry.printableHeight
        if geometry.printableHeight - into < 1 {
            page += 1
            into = 0
        }
        return Place(page: page, yFromTop: geometry.margin + into)
    }

    /// Fill in the headings `findString` could not place, and make the whole
    /// sequence monotonic.
    ///
    /// A raw prediction is a bad destination on its own: it runs monotonically
    /// *ahead* of the print as page-break slack accumulates, and over eight
    /// pages that is enough to name the wrong page. But the headings on either
    /// side of an unplaceable one are usually exact, and the measurement says
    /// exactly where it sat between them -- so interpolate on the measurement's
    /// own scale between the nearest located neighbours, extrapolate linearly
    /// when there is only one of them, and fall back to the prediction only when
    /// nothing at all was located. (Measured on Dan's iPhone 16 Pro: the three
    /// headings of a memo whose titles wrap in print were each predicted a page
    /// late, putting three bookmarks *behind* the one before them.)
    ///
    /// `located` and `tops` are parallel, in document order; `predicted` is the
    /// last resort for each.
    public static func interpolate(_ located: [CGFloat?],
                                   tops: [CGFloat],
                                   predicted: [CGFloat],
                                   scale: CGFloat) -> [CGFloat] {
        var result = [CGFloat](repeating: 0, count: located.count)
        for index in located.indices {
            if let known = located[index] {
                result[index] = known
                continue
            }
            let before = located[..<index].lastIndex(where: { $0 != nil })
            let after = located[(index + 1)...].firstIndex(where: { $0 != nil })
            switch (before, after) {
            case let (.some(low), .some(high)):
                let span = tops[high] - tops[low]
                let fraction = span > 0 ? (tops[index] - tops[low]) / span : 0
                result[index] = located[low]!
                    + fraction * (located[high]! - located[low]!)
            case let (.some(low), .none):
                result[index] = located[low]! + (tops[index] - tops[low]) * scale
            case let (.none, .some(high)):
                result[index] = located[high]! - (tops[high] - tops[index]) * scale
            case (.none, .none):
                result[index] = predicted[index]
            }
        }
        // Never behind the heading before it: a bookmark that goes backwards
        // makes the contents list jump.
        for index in 1..<max(result.count, 1) {
            result[index] = max(result[index], result[index - 1])
        }
        return result
    }

    /// The whole pipeline, in the shape `MarkdownDocumentModel.applyOutline`
    /// takes: heading index → (page, top in *PDF* coordinates).
    public static func located(_ headings: [MeasuredHeading],
                               in document: PDFDocument,
                               geometry: Geometry) -> [Int: (page: Int, top: CGFloat)] {
        var snapped: [CGFloat?] = []
        var predicted: [CGFloat] = []
        for heading in headings {
            let prediction = predict(heading, in: geometry)
            predicted.append(offset(of: prediction, in: geometry))
            let hits = candidates(for: heading.title, in: document)
            snapped.append(snap(prediction, to: hits, in: geometry)
                .map { offset(of: $0, in: geometry) })
        }
        let offsets = interpolate(snapped, tops: headings.map(\.top),
                                  predicted: predicted, scale: geometry.scale)

        var result: [Int: (page: Int, top: CGFloat)] = [:]
        let lastPage = max(document.pageCount - 1, 0)
        for (index, heading) in headings.enumerated() {
            var spot = place(atOffset: offsets[index], in: geometry)
            // A placement can run off the end of a document that came out
            // shorter than the model expected.
            if spot.page > lastPage {
                spot = Place(page: lastPage, yFromTop: spot.yFromTop)
            }
            guard let page = document.page(at: spot.page) else { continue }
            result[heading.index] = (spot.page,
                                     page.bounds(for: .mediaBox).maxY - spot.yFromTop)
        }
        return result
    }
}
