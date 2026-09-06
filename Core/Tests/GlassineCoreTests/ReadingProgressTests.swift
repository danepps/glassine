import CoreGraphics
import Testing
@testable import GlassineCore

@Suite("ReadingProgress")
struct ReadingProgressTests {

    @Test("0 at the top, 1 at the bottom, linear in between")
    func fractionAcrossTheRange() {
        // A 13,757 pt page in a 1,000 pt window: 12,757 pt of travel.
        let span: CGFloat = 12_757
        #expect(ReadingProgress.fraction(travelled: 0, span: span) == 0)
        #expect(ReadingProgress.fraction(travelled: span, span: span) == 1)
        #expect(abs(ReadingProgress.fraction(travelled: span / 2, span: span) - 0.5) < 0.0001)
    }

    @Test("Overscroll in either direction is clamped")
    func fractionIsClamped() {
        #expect(ReadingProgress.fraction(travelled: -50, span: 100) == 0)
        #expect(ReadingProgress.fraction(travelled: 150, span: 100) == 1)
    }

    @Test("A page shorter than the view is entirely on screen, so it reads 1")
    func shortPageReadsFullyRead() {
        #expect(ReadingProgress.fraction(travelled: 0, span: 0) == 1)
        #expect(ReadingProgress.fraction(travelled: 0, span: -200) == 1)
        // The span guard is 0.5 pt, so a hair of slack still counts as read.
        #expect(ReadingProgress.fraction(travelled: 0, span: 0.4) == 1)
        #expect(ReadingProgress.fraction(travelled: 0, span: 0.6) == 0)
    }

    @Test("offset is the inverse, and nil when there is nothing to scroll")
    func offsetIsTheInverse() {
        let span: CGFloat = 12_757
        #expect(ReadingProgress.offset(forFraction: 0, span: span) == 0)
        #expect(ReadingProgress.offset(forFraction: 1, span: span) == span)
        #expect(ReadingProgress.offset(forFraction: 0.5, span: span) == span / 2)
        // Out-of-range fractions are clamped, exactly as ⌥⌘G's 0-100 is.
        #expect(ReadingProgress.offset(forFraction: -1, span: span) == 0)
        #expect(ReadingProgress.offset(forFraction: 4, span: span) == span)

        #expect(ReadingProgress.offset(forFraction: 0.5, span: 0) == nil)
        #expect(ReadingProgress.offset(forFraction: 0.5, span: 0.4) == nil)
    }

    @Test("A round trip through both returns the fraction it started with")
    func roundTrip() {
        let span: CGFloat = 9_000
        for percent in stride(from: 0, through: 100, by: 7) {
            let fraction = CGFloat(percent) / 100
            let travelled = ReadingProgress.offset(forFraction: fraction, span: span)!
            #expect(abs(ReadingProgress.fraction(travelled: travelled, span: span) - fraction)
                    < 0.0001)
        }
    }
}
