import Foundation
import Testing
@testable import GlassineCore

@Suite("RecentsModel")
struct RecentsModelTests {

    private func row(_ path: String) -> RecentRow {
        RecentRow(url: URL(fileURLWithPath: path), key: path,
                  lastOpened: Date(), pageCount: nil, isMissing: false)
    }

    @Test("The filter is case-insensitive and matches the file name only")
    func filterMatchesTheNameOnly() {
        let rows = [
            row("/Users/dan/McKenzie/notes.pdf"),
            row("/Users/dan/Papers/McKenzie - Bibliography.pdf"),
            row("/Users/dan/Papers/mckenzie lecture.md")
        ]

        // The folder "McKenzie" must not pull in the file called notes.pdf.
        let hits = RecentsModel.filter(rows, query: "mcken")
        #expect(hits.map { $0.url.lastPathComponent }
                == ["McKenzie - Bibliography.pdf", "mckenzie lecture.md"])

        // Case-insensitive both ways.
        #expect(RecentsModel.filter(rows, query: "MCKENZIE").count == 2)
        #expect(RecentsModel.filter(rows, query: "NOTES").count == 1)

        // Empty and all-whitespace queries keep everything.
        #expect(RecentsModel.filter(rows, query: "").count == 3)
        #expect(RecentsModel.filter(rows, query: "   ").count == 3)
        // A query is trimmed before it is used.
        #expect(RecentsModel.filter(rows, query: "  notes  ").count == 1)

        #expect(RecentsModel.filter(rows, query: "nothing here").isEmpty)
    }

    @Test("dateText: today with a time, yesterday by name, older by date")
    func dateStrings() {
        let calendar = Calendar.current
        let now = Date()

        let today = RecentsModel.dateText(now, now: now)
        #expect(today.hasPrefix("Today, "))
        #expect(today.count > "Today, ".count)

        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        #expect(RecentsModel.dateText(yesterday, now: now) == "Yesterday")

        // Earlier this year: no year in the string.
        let earlierThisYear = calendar.date(byAdding: .day, value: -40, to: now)!
        let thisYear = RecentsModel.dateText(earlierThisYear, now: now)
        #expect(!thisYear.isEmpty)
        #expect(!thisYear.hasPrefix("Today"))
        #expect(thisYear != "Yesterday")

        // A previous year: a different, longer format that names the year.
        let lastYear = calendar.date(byAdding: .year, value: -2, to: now)!
        let older = RecentsModel.dateText(lastYear, now: now)
        let year = calendar.component(.year, from: lastYear)
        #expect(older.contains("\(year)"))

        // A seeded entry can carry no date at all.
        #expect(RecentsModel.dateText(.distantPast, now: now) == "")
    }
}
