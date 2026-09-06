import Foundation
import Testing
@testable import GlassineCore

/// Every test here swaps `Prefs.defaults` for an isolated suite, so they run one
/// at a time and put `.standard` back afterwards. Nothing in this file may touch
/// the real preferences domain.
@Suite("Prefs", .serialized)
struct PrefsTests {

    /// Run `body` against a private defaults suite.
    private func withIsolatedDefaults(_ body: () throws -> Void) rethrows {
        let name = "com.epps.Glassine.tests.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: name) else {
            Issue.record("could not make a defaults suite")
            return
        }
        let previous = Prefs.defaults
        Prefs.defaults = suite
        defer {
            Prefs.flushRecentDocumentWrites()
            Prefs.defaults = previous
            suite.removePersistentDomain(forName: name)
        }
        try body()
    }

    @Test("Every key round trips, and the defaults are what they always were")
    func roundTrips() {
        withIsolatedDefaults {
            // Defaults first: an empty domain must read as the shipped defaults.
            #expect(Prefs.invertInDarkMode == true)
            #expect(Prefs.darkPaper == .black)
            #expect(Prefs.appearance == .system)
            #expect(Prefs.sidebarMode == .thumbnails)
            #expect(Prefs.windowOpacity == 1.0)
            #expect(Prefs.windowBlur == true)
            #expect(Prefs.markdownStyle == MarkdownStyle.defaultID)
            #expect(Prefs.markdownLayout == .pages)
            #expect(Prefs.markdownFontSize == 11)
            #expect(Prefs.recentDocuments.isEmpty)
            #expect(Prefs.lastPosition(for: URL(fileURLWithPath: "/tmp/x.pdf")) == nil)

            Prefs.invertInDarkMode = false
            #expect(Prefs.invertInDarkMode == false)

            Prefs.darkPaper = .gray
            #expect(Prefs.darkPaper == .gray)

            Prefs.appearance = .dark
            #expect(Prefs.appearance == .dark)

            Prefs.sidebarMode = .outline
            #expect(Prefs.sidebarMode == .outline)

            Prefs.windowOpacity = 0.55
            #expect(Prefs.windowOpacity == 0.55)
            // Clamped to the range and rounded to two decimals.
            Prefs.windowOpacity = 0.01
            #expect(Prefs.windowOpacity == Prefs.minWindowOpacity)
            Prefs.windowOpacity = 5
            #expect(Prefs.windowOpacity == Prefs.maxWindowOpacity)
            Prefs.windowOpacity = 0.8999999999
            #expect(Prefs.windowOpacity == 0.9)

            Prefs.windowBlur = false
            #expect(Prefs.windowBlur == false)

            Prefs.markdownStyle = "custom:Mine"
            #expect(Prefs.markdownStyle == "custom:Mine")

            Prefs.markdownLayout = .continuous
            #expect(Prefs.markdownLayout == .continuous)

            Prefs.markdownFontSize = 13
            #expect(Prefs.markdownFontSize == 13)
            // A size that is not on the menu is refused, not stored.
            Prefs.markdownFontSize = 42
            #expect(Prefs.markdownFontSize == 13)

            let file = URL(fileURLWithPath: "/tmp/glassine-test.pdf")
            Prefs.setLastPosition(Prefs.Position(pageIndex: 7, x: 12, y: 340), for: file)
            let read = Prefs.lastPosition(for: file)
            #expect(read?.pageIndex == 7)
            #expect(read?.x == 12)
            #expect(read?.y == 340)
            #expect(Prefs.lastAccess(for: file) != nil)
        }
    }

    @Test("A pre-4.0 three-element position entry still reads")
    func legacyPositionEntry() {
        withIsolatedDefaults {
            let file = URL(fileURLWithPath: "/tmp/legacy.pdf")
            Prefs.defaults.set([file.path: [3.0, 1.0, 2.0]], forKey: "lastPositions")
            #expect(Prefs.lastPosition(for: file)?.pageIndex == 3)
            // No stamp: treated as least recently used, and no date to report.
            #expect(Prefs.lastAccess(for: file) == nil)
        }
    }

    @Test("The 501st position evicts the least recently used entry")
    func positionLRUEviction() {
        withIsolatedDefaults {
            // 500 entries with distinguishable access stamps, oldest first.
            var table: [String: Any] = [:]
            for index in 0..<500 {
                table["/tmp/file-\(index).pdf"] = [Double(index), 0.0, 0.0, Double(index)]
            }
            Prefs.defaults.set(table, forKey: "lastPositions")

            let fresh = URL(fileURLWithPath: "/tmp/file-new.pdf")
            Prefs.setLastPosition(Prefs.Position(pageIndex: 1, x: 0, y: 0), for: fresh)

            let after = Prefs.defaults.dictionary(forKey: "lastPositions") ?? [:]
            #expect(after.count == 500)
            #expect(after["/tmp/file-0.pdf"] == nil)      // stamp 0: the oldest
            #expect(after["/tmp/file-1.pdf"] != nil)
            #expect(after["/tmp/file-499.pdf"] != nil)
            #expect(after["/tmp/file-new.pdf"] != nil)
        }
    }

    @Test("The recents list is capped at 30 and keeps its fields")
    func recentDocumentsCap() {
        withIsolatedDefaults {
            let now = Date()
            var seeded: [RecentDocument] = []
            for index in 0..<35 {
                let bookmark: Data? = index == 0 ? Data([1, 2, 3]) : nil
                let pages: Int? = index == 0 ? 211 : nil
                let when: Date = now.addingTimeInterval(-Double(index))
                seeded.append(RecentDocument(path: "/tmp/doc-\(index).pdf",
                                             bookmark: bookmark,
                                             lastOpened: when,
                                             pageCount: pages))
            }
            Prefs.recentDocuments = seeded
            let stored = Prefs.recentDocuments
            #expect(stored.count == Prefs.maxRecentDocuments)
            #expect(stored.first?.path == "/tmp/doc-0.pdf")
            #expect(stored.first?.pageCount == 211)
            #expect(stored.first?.bookmark == Data([1, 2, 3]))
            #expect(stored.last?.path == "/tmp/doc-29.pdf")
            #expect(stored[1].pageCount == nil)
            #expect(stored[1].bookmark == nil)
        }
    }

    @Test("Noting a document de-duplicates it and moves it to the front")
    func recentDocumentsDeduplication() {
        withIsolatedDefaults {
            let directory = TempDirectory()
            let first = directory.write(Data("a".utf8), to: "first.pdf")
            let second = directory.write(Data("b".utf8), to: "second.pdf")

            Prefs.noteRecentDocument(first, pageCount: 3)
            Prefs.noteRecentDocument(second, pageCount: 4)
            Prefs.noteRecentDocument(first, pageCount: 9)
            Prefs.flushRecentDocumentWrites()

            let rows = Prefs.recentDocuments
            #expect(rows.count == 2)
            #expect(rows.first?.path == first.standardizedFileURL.path)
            #expect(rows.first?.pageCount == 9)
            #expect(rows.last?.path == second.standardizedFileURL.path)
            // A real open earns a bookmark; a seeded entry would not have one.
            #expect(rows.first?.bookmark != nil)
        }
    }

    @Test("Removing a recent document drops exactly that path")
    func removeRecentDocument() {
        withIsolatedDefaults {
            Prefs.recentDocuments = (0..<3).map {
                RecentDocument(path: "/tmp/r-\($0).pdf", bookmark: nil,
                               lastOpened: Date(), pageCount: nil)
            }
            Prefs.removeRecentDocument(path: "/tmp/r-1.pdf")
            #expect(Prefs.recentDocuments.map(\.path) == ["/tmp/r-0.pdf", "/tmp/r-2.pdf"])
        }
    }

    @Test("resolvedURL finds a moved file through its bookmark and rewrites the entry")
    func resolvedURLFollowsAMove() throws {
        try withIsolatedDefaults {
            let directory = TempDirectory()
            let original = directory.write(Data("pdf".utf8), to: "before.pdf")
            let bookmark = try original.bookmarkData()

            let moved = directory.url.appendingPathComponent("after.pdf")
            try FileManager.default.moveItem(at: original, to: moved)

            let entry = RecentDocument(path: original.path, bookmark: bookmark,
                                       lastOpened: Date(), pageCount: nil)
            Prefs.recentDocuments = [entry]

            let resolved = Prefs.resolvedURL(for: entry)
            #expect(resolved?.lastPathComponent == "after.pdf")
            // The stored entry now names the new location.
            #expect(Prefs.recentDocuments.first?.path == moved.standardizedFileURL.path)

            // A file that is really gone resolves to nothing.
            try FileManager.default.removeItem(at: moved)
            #expect(Prefs.resolvedURL(for: RecentDocument(path: moved.path, bookmark: bookmark,
                                                          lastOpened: Date(),
                                                          pageCount: nil)) == nil)
        }
    }

    @Test("The appearance override hook fires from the setter, in order")
    func appearanceHook() {
        withIsolatedDefaults {
            var seen: [AppearanceMode] = []
            var storedWhenCalled: [Int] = []
            Prefs.applyAppearanceOverride = { mode in
                seen.append(mode)
                storedWhenCalled.append(Prefs.defaults.integer(forKey: "appearance"))
            }
            defer { Prefs.applyAppearanceOverride = nil }

            Prefs.appearance = .light
            Prefs.appearance = .dark
            #expect(seen == [.light, .dark])
            // The value is written before the hook runs, as it always was.
            #expect(storedWhenCalled == [1, 2])
        }
    }

    @Test("The styles directory is injectable and drives the custom style list")
    func stylesDirectory() {
        let directory = TempDirectory()
        let previous = Prefs.stylesDirectory
        Prefs.stylesDirectory = directory.url
        defer { Prefs.stylesDirectory = previous }

        directory.write(Data("body { color: red }".utf8), to: "Zebra.css")
        directory.write(Data("body { color: blue }".utf8), to: "Apple.css")
        directory.write(Data("not css".utf8), to: "notes.txt")

        let styles = MarkdownStyle.customStyles()
        #expect(styles.map(\.title) == ["Apple", "Zebra"])
        #expect(styles.map(\.id) == ["custom:Apple", "custom:Zebra"])
        #expect(MarkdownStyle.css(forID: "custom:Zebra") == "body { color: red }")
        // A custom style whose file has gone falls back to the default built-in.
        #expect(MarkdownStyle.css(forID: "custom:Missing")
                == MarkdownHTML.builtInStyle(MarkdownStyle.defaultID))
        #expect(MarkdownStyle.folder == directory.url)
    }

    @Test("RecentsModel.detailText reports the folder and the saved page")
    func detailText() {
        withIsolatedDefaults {
            let home = "/Users/tester"
            let url = URL(fileURLWithPath: home + "/Papers/memo.pdf")

            let plain = RecentRow(url: url, key: url.path, lastOpened: Date(),
                                  pageCount: nil, isMissing: false)
            #expect(RecentsModel.detailText(plain, home: home) == "~/Papers")

            Prefs.setLastPosition(Prefs.Position(pageIndex: 11, x: 0, y: 0), for: url)
            #expect(RecentsModel.detailText(plain, home: home) == "~/Papers  ·  p. 12")

            let counted = RecentRow(url: url, key: url.path, lastOpened: Date(),
                                    pageCount: 30, isMissing: false)
            #expect(RecentsModel.detailText(counted, home: home) == "~/Papers  ·  p. 12 of 30")
        }
    }

    @Test("RecentsModel.rows marks a file that is not there")
    func rowsMarkMissingFiles() {
        withIsolatedDefaults {
            let directory = TempDirectory()
            let real = directory.write(Data("x".utf8), to: "real.pdf")
            Prefs.recentDocuments = [
                RecentDocument(path: real.path, bookmark: nil,
                               lastOpened: Date(), pageCount: 5),
                RecentDocument(path: directory.url.appendingPathComponent("gone.pdf").path,
                               bookmark: nil, lastOpened: Date(), pageCount: nil)
            ]
            let rows = RecentsModel.rows()
            #expect(rows.count == 2)
            #expect(rows[0].isMissing == false)
            #expect(rows[0].pageCount == 5)
            #expect(rows[1].isMissing == true)
        }
    }
}
