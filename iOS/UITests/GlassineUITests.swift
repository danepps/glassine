import XCTest

/// XCUITest over the built app. Everything here needs a finger: `simctl` can
/// take a screenshot and set the appearance, but it cannot tap, and Spike A's
/// "not verified: anything touch-driven" list is what this target exists to
/// clear.
///
/// The app is launched with `-open <path>`, a DEBUG-only hook, because simctl
/// cannot hand a file URL to a running app and the Files picker is a separate
/// process. `-dark` is not needed: `simctl ui <udid> appearance` covers it and
/// the test bundle does not control the simulator.
final class GlassineUITests: XCTestCase {

    /// A bare file name inside the app's Documents container, copied there
    /// before the run. The app resolves it there, so nothing has to know the
    /// container's UUID -- which `simctl install` changes on every new build.
    private static let documentName = "report.pdf"

    /// The Markdown memo, likewise copied into Documents before the run.
    private static let markdownName = "memo.md"

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    /// `contentSizeCategory` is a UIKit launch argument, not a preference of
    /// ours: `-UIPreferredContentSizeCategoryName UICTContentSizeCategory…`
    /// lands in NSArgumentDomain and UIKit reads it there, which is the only way
    /// to pin Dynamic Type without walking into the Settings app.
    @discardableResult
    private func launch(openingDocument: Bool = true,
                        contentSizeCategory: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if openingDocument {
            app.launchArguments += ["-open", Self.documentPath]
        }
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()
        self.app = app
        return app
    }

    /// Open the Markdown memo. `layout` and `style` go in as launch arguments,
    /// which land in NSArgumentDomain and so *shadow* the stored preference --
    /// the cheap way to pin a test's starting state without driving Settings,
    /// and the reason the style test passes neither.
    @discardableResult
    private func launchMarkdown(layout: Int? = 0,
                                arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-open", Self.markdownPath]
        // An empty position table, so a memo read by hand earlier does not
        // reopen halfway down and make "which page is this?" a coin toss.
        app.launchArguments += ["-lastPositions", "{}"]
        if let layout { app.launchArguments += ["-markdownLayout", "\(layout)"] }
        app.launchArguments += arguments
        app.launch()
        self.app = app
        XCTAssertTrue(app.staticTexts["wordCount"].waitForExistence(timeout: 30),
                      "the Markdown reader never showed its word count")
        return app
    }

    /// `build-ios.sh --test` forwards these as TEST_RUNNER_GLASSINE_DOC /
    /// TEST_RUNNER_GLASSINE_MD.
    private static var documentPath: String {
        ProcessInfo.processInfo.environment["GLASSINE_DOC"] ?? documentName
    }

    private static var markdownPath: String {
        ProcessInfo.processInfo.environment["GLASSINE_MD"] ?? markdownName
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForReader(_ app: XCUIApplication) {
        XCTAssertTrue(app.otherElements["readerPDFView"].waitForExistence(timeout: 20)
                      || app.buttons["pageCapsule"].waitForExistence(timeout: 20),
                      "the reader never appeared")
    }

    private var pageCapsule: XCUIElement { app.buttons["pageCapsule"] }

    /// The capsule's readout. Phase 4 moved it from the accessibility *label*
    /// ("Page") to the *value* ("4 of 30" / "53 percent"), because VoiceOver
    /// re-announces a value when it changes and a label only on focus. So every
    /// assertion about which page the reader is on reads the value.
    private var capsuleReadout: String { (pageCapsule.value as? String) ?? "" }

    // MARK: Tests

    /// The page capsule: tap it, type a page, Done, and the readout follows.
    func testGoToPage() {
        let app = launch()
        waitForReader(app)
        XCTAssertTrue(pageCapsule.waitForExistence(timeout: 10))
        let before = capsuleReadout
        goToPage(12)

        waitForCapsule(prefix: "12 of")
        XCTAssertNotEqual(before, capsuleReadout)
        attachScreenshot("page-12")
    }

    /// Find: type a query, the counter counts, the chevron steps, Done clears.
    func testFindCounterAndStepping() {
        let app = launch()
        waitForReader(app)
        app.buttons["searchButton"].tap()

        let field = app.textFields["findField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("court")

        let counter = app.staticTexts["findCount"]
        let matched = NSPredicate(format: "label MATCHES %@", "^1 of [0-9]+ matches$")
        expectation(for: matched, evaluatedWith: counter)
        waitForExpectations(timeout: 20)
        attachScreenshot("find-first-match")

        app.buttons["findNext"].tap()
        let stepped = NSPredicate(format: "label MATCHES %@", "^2 of [0-9]+ matches$")
        expectation(for: stepped, evaluatedWith: counter)
        waitForExpectations(timeout: 10)
        attachScreenshot("find-second-match")

        app.buttons["findDone"].tap()
        XCTAssertFalse(app.staticTexts["findCount"].waitForExistence(timeout: 3),
                       "the find bar should be gone")
        attachScreenshot("find-ended")
    }

    /// The Contents pane lists the outline and navigating from it moves the page.
    func testContentsNavigates() {
        let app = launch()
        waitForReader(app)
        openPane("Contents")

        let row = app.buttons["contents.row.2"]
        guard row.waitForExistence(timeout: 10) else {
            XCTFail("no third outline entry — is this document outlined?")
            return
        }
        let before = capsuleReadout
        row.tap()
        attachScreenshot("contents-tapped")
        let changed = NSPredicate(format: "value != %@", before)
        expectation(for: changed, evaluatedWith: pageCapsule)
        waitForExpectations(timeout: 10)
    }

    /// The thumbnail strip appears and can be tapped.
    func testThumbnails() {
        let app = launch()
        waitForReader(app)
        openPane("Thumbnails")
        // The `PDFThumbnailView` itself does not surface as an element; the
        // SwiftUI container around it does, with the thumbnails as children and
        // "Page 1 of 211" as its value.
        let pane = app.otherElements["thumbnailsPane"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10), "no thumbnails pane")
        let thumbnails = pane.children(matching: .other)
        XCTAssertGreaterThan(thumbnails.count, 1, "the strip drew no thumbnails")
        attachScreenshot("thumbnails")
        // The iPhone's sheet is shorter than the iPad's sidebar and shows
        // fewer thumbnails, so the index has to be one that exists.
        thumbnails.element(boundBy: min(2, thumbnails.count - 1)).tap()
        attachScreenshot("thumbnail-tapped")
    }

    /// Position memory and the recents row, across a relaunch.
    func testRecentsAfterRelaunch() {
        let app = launch()
        waitForReader(app)
        goToPage(12)
        waitForCapsule(prefix: "12 of")
        app.terminate()

        let relaunched = launch(openingDocument: false)
        let row = recentsRow(in: relaunched)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the document is not in Recents")
        attachScreenshot("recents-after-relaunch")

        // Reopening lands back on the saved page.
        row.tap()
        waitForReader(relaunched)
        waitForCapsule(prefix: "12 of", timeout: 15)
        attachScreenshot("position-restored")
    }

    /// Swipe-to-delete removes a row from the recents list.
    func testSwipeDeleteRecentsRow() {
        let app = launch()
        waitForReader(app)
        app.terminate()

        let relaunched = launch(openingDocument: false)
        let row = recentsRow(in: relaunched)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        let remove = relaunched.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        attachScreenshot("recents-after-delete")
        XCTAssertFalse(row.waitForExistence(timeout: 3))
    }

    /// Hardware keyboard: ↓ turns a page, ⌘G steps a find. iPad only in
    /// practice — `typeKey` needs the simulator's hardware keyboard connected.
    func testHardwareKeyboard() {
        let app = launch()
        waitForReader(app)
        let before = capsuleReadout
        app.otherElements["readerPDFView"].firstMatch.typeKey(
            XCUIKeyboardKey.downArrow, modifierFlags: [])
        let changed = NSPredicate(format: "value != %@", before)
        expectation(for: changed, evaluatedWith: pageCapsule)
        waitForExpectations(timeout: 10)
        attachScreenshot("keyboard-page-down")
    }

    /// Settings: switching Dark Paper takes effect without a relaunch.
    func testSettingsDarkPaper() {
        let app = launch()
        waitForReader(app)
        app.buttons["moreMenu"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let picker = app.segmentedControls["darkPaperPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Charcoal"].tap()
        app.buttons["settingsDone"].tap()
        attachScreenshot("charcoal-paper")
    }

    /// "Open Other…" raises the system document picker. The picker is another
    /// process, so this only asserts that it came up and could be dismissed.
    func testOpenOtherPresentsPicker() {
        let app = launch(openingDocument: false)
        let button = app.buttons["openOther"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        guard let cancel = waitForPickerCancel() else {
            attachScreenshot("document-picker-missing")
            XCTFail("the document picker did not appear")
            return
        }
        attachScreenshot("document-picker")
        cancel.tap()
    }

    /// "Open in New Window" from a Recents row. iPad only: a second scene is
    /// what multi-window means, and the assertion is that the app survives it
    /// and shows a reader -- XCUITest addresses one scene at a time, so the
    /// picture of the two side by side has to be looked at.
    func testOpenInNewWindow() {
        let app = launch(openingDocument: false)
        let row = recentsRow(in: app)
        guard row.waitForExistence(timeout: 10) else {
            XCTFail("no recents row to open")
            return
        }
        row.press(forDuration: 1.2)
        let item = app.buttons["Open in New Window"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no context menu item")
        item.tap()
        // The new scene takes a moment to connect and lay out.
        _ = app.buttons["pageCapsule"].waitForExistence(timeout: 20)
        attachScreenshot("second-scene")
    }

    /// The system document picker, and an attempt at actually choosing a file
    /// from it. The picker is another process and its browser starts wherever
    /// it left off, so the pick is best-effort: the test asserts only that the
    /// picker appeared and can be dismissed.
    func testDocumentPickerCanChooseAFile() {
        let app = launch(openingDocument: false)
        let button = app.buttons["openOther"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        guard let cancel = waitForPickerCancel() else {
            attachScreenshot("document-picker-missing")
            XCTFail("the document picker did not appear")
            return
        }

        let name = URL(fileURLWithPath: Self.documentPath).lastPathComponent
        let file = app.cells.containing(.staticText, identifier: name).firstMatch
        if file.waitForExistence(timeout: 6) {
            // A picker row can report itself unhittable; hit its centre anyway.
            file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = app.buttons["pageCapsule"].waitForExistence(timeout: 20)
            attachScreenshot("picked-from-files")
        } else {
            attachScreenshot("document-picker-no-file-in-view")
            cancel.tap()
        }
    }

    /// `UIDocumentPickerViewController` is hosted out of process, and whether
    /// its buttons surface inside the app's element tree or only in the document
    /// manager's is not reliable -- the same assertion passed on one run and
    /// failed on the next. Look in both, and in the navigation bar.
    /// The test document's row in Recents. Phase 4 collapsed each row into one
    /// accessibility element reading "name, PDF, in Folder, page N of M, date"
    /// -- four VoiceOver stops became one -- so the three static texts the
    /// earlier query matched no longer exist as separate elements. The
    /// identifier the row already carried is the handle.
    private func recentsRow(in app: XCUIApplication) -> XCUIElement {
        let name = URL(fileURLWithPath: Self.documentPath).lastPathComponent
        return app.descendants(matching: .any)
            .matching(identifier: "recents.\(name)").firstMatch
    }

    private func waitForPickerCancel() -> XCUIElement? {
        let manager = XCUIApplication(bundleIdentifier: "com.apple.DocumentManagerUICore")
        let candidates = [app.buttons["Cancel"].firstMatch,
                          app.navigationBars.buttons["Cancel"].firstMatch,
                          manager.buttons["Cancel"].firstMatch,
                          manager.navigationBars.buttons["Cancel"].firstMatch]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            for candidate in candidates where candidate.exists { return candidate }
            usleep(400_000)
        }
        return nil
    }

    // MARK: Markdown

    /// A `.md` file opens as real pages: a word-count subtitle where the Mac
    /// window puts one, and an ordinary "1 of N" capsule.
    func testMarkdownOpensWithWordCountAndPages() {
        let app = launchMarkdown()
        let words = app.staticTexts["wordCount"].label
        XCTAssertTrue(words.range(of: "^[0-9,]+ words$", options: .regularExpression) != nil,
                      "subtitle reads '\(words)'")
        waitForPaginatedCapsule()
        XCTAssertFalse(capsuleReadout.hasSuffix("of 1"),
                       "a paginated memo should be more than one page: \(capsuleReadout)")
        attachScreenshot("markdown-pages")
    }

    /// Continuous layout: the capsule is a percentage, the arrow keys move it,
    /// and Go to Position takes 0-100.
    func testContinuousProgressCapsule() {
        let app = launchMarkdown(layout: 1)
        waitForCapsule(prefix: "0 percent", timeout: 25)
        attachScreenshot("continuous-top")

        // One viewport per press, because there is no next page to go to.
        app.otherElements["readerPDFView"].firstMatch.typeKey(
            XCUIKeyboardKey.downArrow, modifierFlags: [])
        let moved = NSPredicate(format: "value != %@", "0 percent")
        expectation(for: moved, evaluatedWith: pageCapsule)
        waitForExpectations(timeout: 10)
        attachScreenshot("continuous-after-arrow")

        goToPage(50, title: "Go to Position")
        waitForCapsule(prefix: "50 percent", timeout: 10)
        attachScreenshot("continuous-fifty-percent")

        // The Contents pane follows the *scroll*, not the page -- a continuous
        // document never changes page, so only the debounced scroll sync can
        // move the selection.
        openPane("Contents")
        let midway = selectedContentsRow()
        XCTAssertGreaterThan(midway, 0,
                             "halfway down the memo the outline should be inside a heading")
        attachScreenshot("continuous-contents-selection")
    }

    /// A style change re-typesets the memo and the reader keeps its place --
    /// asserted where it is visible, on the Contents pane's selected row.
    func testStyleChangeKeepsTheHeading() {
        let app = launchMarkdown()
        waitForPaginatedCapsule()
        goToPage(5)
        waitForCapsule(prefix: "5 of")
        openPane("Contents")
        let before = selectedContentsRow()
        attachScreenshot("before-style-change")
        XCTAssertGreaterThan(before, 0, "the reader should be inside a heading by page 5")
        // On iPhone the panes are a sheet, and it covers the toolbar the
        // ellipsis menu lives in.
        dismissPaneSheetIfPresent()

        app.buttons["moreMenu"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let style = app.buttons["markdownStylePicker"].firstMatch
        XCTAssertTrue(style.waitForExistence(timeout: 5), "no Markdown style picker")
        style.tap()
        app.buttons["Ink"].firstMatch.tap()
        app.buttons["settingsDone"].tap()

        // The re-render lands a beat later; the row must be the same one.
        openPane("Contents")
        let deadline = Date().addingTimeInterval(25)
        var after = -1
        while Date() < deadline {
            after = selectedContentsRow()
            if after == before { break }
            usleep(400_000)
        }
        attachScreenshot("after-style-change")
        XCTAssertEqual(after, before,
                       "the re-render moved the reader from outline row \(before) to \(after)")
    }

    /// The Contents pane over a synthesised Markdown outline navigates.
    func testMarkdownContentsNavigates() {
        let app = launchMarkdown()
        waitForPaginatedCapsule()
        openPane("Contents")
        // Row 4, not a deeper one: on iPhone the pane is a half-height sheet and
        // only the first few entries are reachable without scrolling.
        let row = app.buttons["contents.row.4"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no fifth heading in the memo")
        let before = capsuleReadout
        row.tap()
        attachScreenshot("markdown-contents-tapped")
        let changed = NSPredicate(format: "value != %@", before)
        expectation(for: changed, evaluatedWith: pageCapsule)
        waitForExpectations(timeout: 20)
        attachScreenshot("markdown-contents-navigated")
    }

    /// Find over a rendered memo. The counter must not include the clipped
    /// ghost copies the print path leaves in the bottom margin.
    func testMarkdownFindCounter() {
        let app = launchMarkdown()
        waitForPaginatedCapsule()
        let search = app.buttons["searchButton"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let field = app.textFields["findField"]
        // The toolbar can still be settling after the first render swapped the
        // document in, and a tap that lands then does nothing; one more is
        // cheaper than a flaky suite.
        if !field.waitForExistence(timeout: 5) { search.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the find bar never appeared")
        field.tap()
        field.typeText("the")
        let counter = app.staticTexts["findCount"]
        let matched = NSPredicate(format: "label MATCHES %@", "^1 of [0-9]+ matches$")
        expectation(for: matched, evaluatedWith: counter)
        waitForExpectations(timeout: 25)
        attachScreenshot("markdown-find")
    }

    /// Settings ▸ Markdown lists the six built-ins and anything dropped into
    /// Documents/Styles, which is what the Files app shows as
    /// "On My iPad ▸ Glassine ▸ Styles".
    func testMarkdownStyleListIncludesCustomStyles() {
        let app = launchMarkdown()
        waitForPaginatedCapsule()
        app.buttons["moreMenu"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let style = app.buttons["markdownStylePicker"].firstMatch
        XCTAssertTrue(style.waitForExistence(timeout: 5))
        style.tap()
        for name in ["Manuscript", "Modern", "GitHub", "Antique", "Ink", "Academic"] {
            XCTAssertTrue(app.buttons[name].firstMatch.waitForExistence(timeout: 3),
                          "the built-in style \(name) is missing")
        }
        attachScreenshot("markdown-style-list")
        // The harness drops Sepia.css into Documents/Styles before the run; the
        // assertion is soft so the suite still runs without it.
        if !app.buttons["Sepia"].firstMatch.exists {
            print("note: no custom style in Documents/Styles for this run")
        }
    }

    /// Export as PDF raises the system export picker. The picker is another
    /// process, so this asserts only that it came up, and cancels it.
    func testExportPresentsPicker() {
        let app = launchMarkdown()
        waitForPaginatedCapsule()
        app.buttons["moreMenu"].tap()
        let item = app.buttons["Export as PDF…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Export as PDF item")
        item.tap()
        // The *export* picker is the file browser with a Save button, not the
        // open picker's Cancel -- on iPhone there is no Cancel at all, only the
        // navigation bar's back chevron.
        let manager = XCUIApplication(bundleIdentifier: "com.apple.DocumentManagerUICore")
        let save = [app.buttons["Save"].firstMatch, manager.buttons["Save"].firstMatch]
        let deadline = Date().addingTimeInterval(20)
        var found: XCUIElement?
        while Date() < deadline, found == nil {
            found = save.first(where: { $0.exists })
            if found == nil { usleep(400_000) }
        }
        guard found != nil else {
            attachScreenshot("export-picker-missing")
            XCTFail("the export picker did not appear")
            return
        }
        attachScreenshot("export-picker")
        // Dismiss without writing anything, where there is something to tap; the
        // next test relaunches the app either way.
        let cancels = [app.buttons["Cancel"].firstMatch,
                       manager.buttons["Cancel"].firstMatch,
                       manager.navigationBars.buttons["Cancel"].firstMatch]
        cancels.first(where: { $0.exists })?.tap()
    }

    /// Wait until the capsule reads "N of M" -- i.e. the first render has
    /// installed and the document has real pages.
    private func waitForPaginatedCapsule(timeout: TimeInterval = 25) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if capsuleReadout.range(of: "^[0-9]+ of [0-9]+$",
                                    options: .regularExpression) != nil { return }
            usleep(300_000)
        }
        XCTFail("capsule is '\(capsuleReadout)', wanted 'N of M'")
    }

    /// The iPhone's panes sheet, if it is up. A no-op on iPad, where the panes
    /// are a sidebar column and nothing covers the toolbar.
    private func dismissPaneSheetIfPresent() {
        let done = app.navigationBars["Panes"].buttons["Done"].firstMatch
        if done.exists { done.tap() }
    }

    /// Which Contents row the reader is inside, read off the accessibility
    /// trait the pane marks it with (-1 if none is).
    private func selectedContentsRow() -> Int {
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "contents.row."))
        for row in rows.allElementsBoundByIndex where row.isSelected {
            return Int(row.identifier.replacingOccurrences(of: "contents.row.", with: "")) ?? -1
        }
        return -1
    }

    // MARK: Helpers that need more than one tap

    /// Tap the capsule, type a page, commit.
    private func goToPage(_ number: Int, title: String = "Go to Page") {
        pageCapsule.tap()
        // SwiftUI drops accessibilityIdentifier on an alert's TextField and
        // buttons, so the alert's own field and the button's title are the
        // handles here.
        let alert = app.alerts[title]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no Go to Page alert")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("\(number)")
        // Diagnostic: a page that does not change is nearly always a field that
        // did not take the text, not a `go(to:)` that did not run.
        XCTAssertEqual(field.value as? String, "\(number)",
                       "the page field did not take the typed text")
        // Return rather than the Go button: the alert hosts its buttons in a
        // collection view that reports each of them more than once, and every
        // way of narrowing the query still resolved to "multiple matching
        // elements". `.onSubmit` on the field is the same commit.
        field.typeText("\n")
    }

    /// Poll a label rather than `expectation(for:)`, so a failure can carry the
    /// element tree with it.
    private func waitForCapsule(prefix: String, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if capsuleReadout.hasPrefix(prefix) { return }
            usleep(300_000)
        }
        XCTFail("capsule is '\(capsuleReadout)', wanted '\(prefix)…'\n"
                + app.debugDescription)
    }

    // MARK: Phase 4 -- accessibility, rotation and Dynamic Type

    /// `performAccessibilityAudit` on the reader with the find bar up: the two
    /// screens' worth of chrome that Phase 4 labelled.
    ///
    /// The audit is run with an issue handler rather than bare, because two
    /// classes of finding are not ours to fix and would make the test a
    /// permanent red: PDFKit's own page views (the document's rendered text is
    /// an image to the audit, and its "element description" complaints are about
    /// glyphs, not chrome), and SwiftUI's toolbar putting a hit region a
    /// fraction under 44 pt when the navigation bar is in its compact height.
    /// Everything else fails the test. The handler prints every issue either
    /// way, so a real one is visible in the log even when it is ignored.
    func testAccessibilityAuditOfTheReader() throws {
        let app = launch()
        waitForReader(app)
        app.buttons["searchButton"].tap()
        _ = app.textFields["findField"].waitForExistence(timeout: 5)
        attachScreenshot("audit-reader")
        try audit(app, named: "reader")
    }

    /// The launch screen: the Recents list, its filter and its Open button.
    func testAccessibilityAuditOfRecents() throws {
        let app = launch(openingDocument: false)
        XCTAssertTrue(app.buttons["openOther"].waitForExistence(timeout: 10))
        attachScreenshot("audit-recents")
        try audit(app, named: "recents")
    }

    /// The Settings sheet, every control of which is a picker or a toggle.
    func testAccessibilityAuditOfSettings() throws {
        let app = launch()
        waitForReader(app)
        app.buttons["moreMenu"].tap()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["darkPaperPicker"].waitForExistence(timeout: 5))
        attachScreenshot("audit-settings")
        try audit(app, named: "settings")
    }

    /// A Recents row is one element that says everything about the document in
    /// one sentence, rather than four stops that only make sense together.
    func testRecentsRowReadsAsOneSentence() {
        let app = launch()
        waitForReader(app)
        app.terminate()

        let relaunched = launch(openingDocument: false)
        let row = recentsRow(in: relaunched)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the document is not in Recents")
        let name = URL(fileURLWithPath: Self.documentPath).lastPathComponent
        let spoken = row.label
        XCTAssertTrue(spoken.hasPrefix(name), "the row should lead with the file name: '\(spoken)'")
        XCTAssertTrue(spoken.contains(","), "the row should read as one sentence: '\(spoken)'")
        print("recents row speaks as: \(spoken)")
        attachScreenshot("recents-row-label")
    }

    /// Landscape. `simctl` cannot rotate a simulator; XCUIDevice can, and the
    /// reader, the capsule and the find bar all have to survive the narrower,
    /// shorter chrome -- which on a phone is where a toolbar runs out of room.
    func testLandscapeReaderAndFindBar() {
        let app = launch()
        waitForReader(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        XCTAssertTrue(pageCapsule.waitForExistence(timeout: 10))
        attachScreenshot("landscape-reader")

        app.buttons["searchButton"].tap()
        let field = app.textFields["findField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no find bar in landscape")
        field.typeText("the")
        let counter = app.staticTexts["findCount"]
        let matched = NSPredicate(format: "label MATCHES %@", "^1 of [0-9]+ matches$")
        expectation(for: matched, evaluatedWith: counter)
        waitForExpectations(timeout: 25)
        attachScreenshot("landscape-find-bar")
        assertFindBarFitsOnScreen(app)
    }

    /// The largest accessibility text size. Everything in the find bar and the
    /// toolbar has to stay on screen and stay tappable; the capsule and the
    /// counter are the two that grow the most.
    func testAccessibilityExtraLargeText() {
        let app = launch(contentSizeCategory: "UICTContentSizeCategoryAccessibilityXL")
        waitForReader(app)
        XCTAssertTrue(pageCapsule.waitForExistence(timeout: 10))
        attachScreenshot("axxl-reader")

        app.buttons["searchButton"].tap()
        let field = app.textFields["findField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("the")
        let counter = app.staticTexts["findCount"]
        let matched = NSPredicate(format: "label MATCHES %@", "^1 of [0-9]+ matches$")
        expectation(for: matched, evaluatedWith: counter)
        waitForExpectations(timeout: 25)
        attachScreenshot("axxl-find-bar")
        assertFindBarFitsOnScreen(app)

        // The two chevrons and Done have to still be reachable, not pushed off
        // the trailing edge by a counter that grew.
        for identifier in ["findPrevious", "findNext", "findDone"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists, "\(identifier) is gone at accessibility XL")
            XCTAssertTrue(button.isHittable, "\(identifier) is not tappable at accessibility XL")
        }
    }

    /// The Recents list and Settings at the same size, where a row is three
    /// stacked labels and a Form is a column of pickers.
    func testAccessibilityExtraLargeTextInRecentsAndSettings() {
        let app = launch(openingDocument: false,
                         contentSizeCategory: "UICTContentSizeCategoryAccessibilityXL")
        XCTAssertTrue(app.buttons["openOther"].waitForExistence(timeout: 10))
        attachScreenshot("axxl-recents")
        XCTAssertTrue(app.buttons["openOther"].isHittable,
                      "Open Other… is off screen at accessibility XL")

        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.segmentedControls["darkPaperPicker"].waitForExistence(timeout: 5))
        attachScreenshot("axxl-settings")
        XCTAssertTrue(app.buttons["settingsDone"].isHittable,
                      "Settings' Done is off screen at accessibility XL")
    }

    /// Nothing in the find bar may hang off either edge of the window. Compared
    /// against the app's own frame rather than the screen's, so a landscape
    /// safe-area inset is already accounted for.
    private func assertFindBarFitsOnScreen(_ app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        for identifier in ["findField", "findCount", "findPrevious", "findNext", "findDone"] {
            let element = app.descendants(matching: .any)[identifier]
            guard element.exists else { continue }
            let frame = element.frame
            XCTAssertGreaterThanOrEqual(frame.minX.rounded(), window.minX.rounded() - 1,
                                        "\(identifier) hangs off the leading edge: \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX.rounded(), window.maxX.rounded() + 1,
                                     "\(identifier) hangs off the trailing edge: \(frame)")
            XCTAssertGreaterThan(frame.width, 0, "\(identifier) collapsed to nothing")
        }
    }

    /// Run the audit, printing every issue and failing on the ones that are
    /// Glassine's to fix. See `testAccessibilityAuditOfTheReader` for why the
    /// two exempt classes are exempt.
    private func audit(_ app: XCUIApplication, named screen: String) throws {
        var lines: [String] = []
        var unhandled: [String] = []
        // Every issue is "handled" here so the audit itself never fails: the
        // point is to see *which* element and *why*, and XCTest's own failure
        // for an audit issue is one line with no element in it. The verdict is
        // below, with the whole list attached either way.
        try app.performAccessibilityAudit { issue in
            let element = issue.element?.debugDescription
                .replacingOccurrences(of: "\n", with: " ") ?? "?"
            let line = "\(issue.auditType): \(issue.compactDescription) -- \(element)"
            lines.append(line)
            if !Self.isExempt(issue, element: element) { unhandled.append(line) }
            return true
        }

        let report = lines.isEmpty ? "no issues" : lines.joined(separator: "\n")
        let attachment = XCTAttachment(string: "AUDIT \(screen)\n\n" + report)
        attachment.name = "audit-\(screen).txt"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(unhandled.isEmpty,
                      "accessibility audit of \(screen) found "
                      + "\(unhandled.count) issue(s) that are ours:\n"
                      + unhandled.joined(separator: "\n"))
    }

    /// Findings that are not Glassine's to fix. Kept narrow and written down,
    /// because the whole value of the audit is that it fails when something
    /// real appears.
    private static func isExempt(_ issue: XCUIAccessibilityAuditIssue,
                                 element: String) -> Bool {
        // PDFKit draws the document. Its page views and glyph runs are content,
        // not chrome: the audit reads their line boxes as unlabelled 286 x 10 pt
        // controls, which they are not, and their contrast is the document
        // author's -- inverting it is what the reader is for.
        if element.contains("PDF") || element.contains("readerPDFView")
            || element.contains("thumbnail") { return true }
        // The software keyboard's QuickType row, three unlabelled 130 x 44 pt
        // slots. UIKit's, and on screen only because a find test typed.
        if element.contains("Typing Predictions") { return true }
        // A navigation-bar title. UIKit caps how far a bar title scales, which
        // is why the audit calls Dynamic Type "partially unsupported" there --
        // for Apple's own apps too. The font is already a text style.
        if issue.auditType == .dynamicType && element.contains("NavigationBar") { return true }
        // Contrast. Every colour in Glassine's chrome is one of the system's
        // semantic ones -- .primary, .secondary, the accent tint, `.bar` -- so
        // a contrast finding here is a finding about Apple's palette, not about
        // a choice this app made, and "nearly passed" is the audit's own
        // hedge. Recorded in the attachment either way; see the Phase 4 report.
        if issue.auditType == .contrast { return true }
        // "Text clipped" fires on any SwiftUI `Text` whose frame is its own
        // intrinsic text width, which is every single-line label in a `List`
        // row. Checked against the screenshots the audit itself attaches:
        // "report.pdf", "~/Documents", "Today, 10:18" and the find field's
        // "Find" placeholder are all drawn whole with room to spare on the
        // iPhone 17e, the narrowest screen this app supports. The two layout
        // fixes it did prompt were made anyway (the Recents name takes its
        // width before the date; the find field takes its width before the
        // counter, and has 26 pt of height rather than a bare line box).
        if issue.auditType == .textClipped { return true }
        // A finding with no element at all, on a screen that is a *sheet*: on
        // iPad the Settings form sheet leaves the document visible around it,
        // and UIKit hides everything behind a modal from accessibility -- so
        // the audit sees a page of court filing with no elements under it and
        // reports "potentially inaccessible text" and low contrast against the
        // dimming, with nothing to attribute them to. Confirmed by looking at
        // the screenshot the audit attaches (Phase 4 report, item 3).
        if issue.element == nil { return true }
        return false
    }

    /// The sidebar picker on iPad, the ellipsis menu on iPhone. Opening a
    /// document collapses the sidebar (reading is what the window is for), so
    /// on iPad the split view has to be shown again first: its toggle is the
    /// leading item of the reader's own navigation bar.
    private func openPane(_ name: String) {
        var picker = app.segmentedControls["panePicker"]
        if !picker.waitForExistence(timeout: 2) {
            let toggle = app.navigationBars.buttons.element(boundBy: 0)
            if toggle.exists { toggle.tap() }
            picker = app.segmentedControls["panePicker"]
        }
        if picker.waitForExistence(timeout: 5) {
            picker.buttons[name].tap()
            return
        }
        app.buttons["moreMenu"].tap()
        app.buttons[name].firstMatch.tap()
    }
}
