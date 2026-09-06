import GlassineCore
import PDFKit
import SwiftUI
import UIKit

/// The reader and its chrome. Everything that must be inverted -- and nothing
/// else -- goes inside `pageInversion`; the toolbar and the find bar sit outside
/// it, the way the Mac keeps content out from under its toolbar.
@MainActor
struct ReaderView: View {

    @Bindable var session: DocumentSession
    let onShowPanes: () -> Void
    let onShowSettings: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let prefs = PrefsModel.shared

    @FocusState private var findFocused: Bool
    @State private var exportFile: ExportFile?
    @State private var isExporting = false

    private var inverted: Bool { prefs.isInverted(in: colorScheme) }

    var body: some View {
        ZStack {
            ReaderTheme.chrome(inverted: inverted, colorScheme: colorScheme,
                               paper: prefs.darkPaper)
                .ignoresSafeArea()
            page
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toolbarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if session.isFindBarVisible { findBar }
        }
        // Only one alert per view: two `.alert` modifiers on the same view and
        // the second never presents (observed -- the go-to-page alert simply
        // did not appear in the element tree). The open-failure alert therefore
        // hangs off the `.failed` branch of `page`, which is the only time it
        // can fire anyway.
        .alert(session.isContinuousMarkdown ? "Go to Position" : "Go to Page",
               isPresented: $session.isPageDialogVisible) {
            pageDialog
        } message: {
            Text(pageRange)
        }
        .sheet(item: $exportFile) { file in
            ExportPicker(file: file) { exportFile = nil }
                .ignoresSafeArea()
        }
    }

    /// What a legal answer looks like. A continuous Markdown document is one
    /// page, so the same field takes a percentage instead.
    private var pageRange: String {
        session.isContinuousMarkdown ? "0\u{2013}100" : "1\u{2013}\(max(session.pageCount, 1))"
    }

    // MARK: The page

    @ViewBuilder
    private var page: some View {
        switch session.phase {
        case .opening:
            ProgressView()
        case .downloading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Downloading…").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("downloadingStatus")
        case .failed(let message):
            // The alert carries the wording, which is the Mac's; this is what
            // is behind it.
            ContentUnavailableView("Cannot Open Document", systemImage: "doc.questionmark")
                .alert("Cannot Open Document", isPresented: .constant(true)) {
                    Button("OK") { onClose() }
                } message: {
                    Text(message)
                }
        case .ready:
            ReaderPDFViewRepresentable(session: session,
                                       inverted: inverted,
                                       colorScheme: colorScheme,
                                       onCommand: handle)
                .pageInversion(inverted, paper: prefs.darkPaper)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                // The word count, where the Mac window puts its subtitle.
                if let subtitle = session.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("wordCount")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) { pageCapsule }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Find", systemImage: "magnifyingglass") { beginFind() }
                .accessibilityIdentifier("searchButton")
                .accessibilityLabel("Find")
                .accessibilityHint("Search the text of this document")
        }
        ToolbarItem(placement: .topBarTrailing) { menu }
    }

    /// "4 of 30" in a capsule, monospaced so it does not jitter while paging --
    /// or "53%" for a continuous Markdown document, where "1 of 1" would say
    /// nothing about a 65-page memo.
    private var capsuleText: String {
        session.isContinuousMarkdown
            ? "\(session.progressPercent)%"
            : "\(session.currentPageIndex + 1) of \(max(session.pageCount, 1))"
    }

    /// What VoiceOver says the capsule *is*. The changing part goes in the
    /// value, not the label, because VoiceOver re-announces a value when it
    /// changes and a label only when focus moves -- so paging with the arrow
    /// keys speaks the new page.
    private var capsuleAccessibilityLabel: String {
        session.isContinuousMarkdown ? "Reading position" : "Page"
    }

    private var capsuleAccessibilityValue: String {
        session.isContinuousMarkdown
            ? "\(session.progressPercent) percent"
            : "\(session.currentPageIndex + 1) of \(max(session.pageCount, 1))"
    }

    private var pageCapsule: some View {
        Button {
            // Empty, not pre-filled with the current page. The Mac pre-fills
            // and selects the whole field so typing replaces it; a SwiftUI
            // TextField has no select-on-focus, so a pre-filled field would
            // make "12" mean "112". The number is right beside the field
            // anyway, and the placeholder still states the range.
            session.pageEntry = ""
            session.isPageDialogVisible = true
        } label: {
            Text(capsuleText)
                .font(.subheadline)
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(session.pageCount == 0)
        .accessibilityIdentifier("pageCapsule")
        .accessibilityLabel(capsuleAccessibilityLabel)
        .accessibilityValue(capsuleAccessibilityValue)
        .accessibilityHint(session.isContinuousMarkdown
                           ? "Go to a position in the document"
                           : "Go to a page")
    }

    /// Go to page, as an alert with a text field rather than a popover.
    ///
    /// A popover was tried twice and neither worked. Anchored to the reader it
    /// opens at the foot of the screen, under the number pad. Anchored to the
    /// capsule -- a toolbar item -- it looks right, but its buttons never fire:
    /// tapping "Done" dismissed the popover with the action's first line
    /// (an `NSLog`) never reaching the console, i.e. the full-screen
    /// `PopoverDismissRegion` SwiftUI puts behind a toolbar popover takes the
    /// touch. An alert has none of that, and a text prompt is what iOS uses for
    /// this anyway.
    @ViewBuilder
    private var pageDialog: some View {
        TextField(pageRange, text: $session.pageEntry)
            .keyboardType(.numberPad)
            .submitLabel(.go)
            .onSubmit { commitPage() }
            .accessibilityIdentifier("pageField")
        Button("Go") { commitPage() }
            .accessibilityIdentifier("pageDone")
        Button("Cancel", role: .cancel) { session.isPageDialogVisible = false }
    }

    private var menu: some View {
        Menu {
            if sizeClass == .compact {
                Button("Thumbnails", systemImage: "square.grid.2x2") {
                    prefs.setSidebarMode(.thumbnails)
                    onShowPanes()
                }
                Button("Contents", systemImage: "list.bullet") {
                    prefs.setSidebarMode(.outline)
                    onShowPanes()
                }
                Button("Recents", systemImage: "clock") {
                    prefs.setSidebarMode(.recents)
                    onShowPanes()
                }
                Divider()
            }
            Button("Print", systemImage: "printer") { printDocument() }
            ShareLink(item: session.url) { Label("Share", systemImage: "square.and.arrow.up") }
            if session.kind == .markdown {
                Button("Export as PDF…", systemImage: "square.and.arrow.down") { exportPDF() }
                    .disabled(isExporting)
            }
            Divider()
            Button("Settings", systemImage: "gearshape") { onShowSettings() }
            Button("Close", systemImage: "xmark") { onClose() }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("moreMenu")
        .accessibilityLabel("More")
        .accessibilityHint("Panes, printing, sharing, settings and closing")
    }

    // MARK: Find bar

    /// Pinned to the bottom rather than the top: on a phone the keyboard takes
    /// the bottom half, and a find field under the thumb is where the counter
    /// and the two chevrons want to be.
    ///
    /// At an accessibility text size the five controls stop fitting across a
    /// 390 pt phone: measured on the iPhone 17e at Accessibility XL, the counter
    /// was cut to "1 of…" and "Done" wrapped onto two lines. Everything stayed
    /// on screen and tappable, but it read as broken, so at those sizes the bar
    /// becomes two rows -- the field, then the counter and the three buttons.
    private var findBar: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) { magnifier; findFieldView }
                    HStack(spacing: 14) {
                        findCounter
                        Spacer(minLength: 8)
                        findButtons
                    }
                }
            } else {
                HStack(spacing: 10) {
                    magnifier
                    findFieldView
                    findCounter
                    findButtons
                }
            }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find bar")
    }

    /// Decoration beside a field that already says what it is.
    private var magnifier: some View {
        Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var findFieldView: some View {
        TextField("Find", text: $session.findQuery)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($findFocused)
                .onSubmit { session.stepFind(by: 1) }
                .onChange(of: session.findQuery) { _, query in session.startFind(query) }
                .accessibilityIdentifier("findField")
                .accessibilityLabel("Find")
                .accessibilityHint("Type to search; the match count is read out beside the field")
                // The field and the counter are both flexible, and on a 390 pt
                // phone SwiftUI split the row between them until the field was
                // 140 pt. The field is where the typing happens; it gets the
                // width first.
                .layoutPriority(1)
                // A plain TextField takes exactly the line height of its font
                // and no more -- 22 pt at body -- and the accessibility audit
                // calls that clipped, because a descender and the caret do not
                // fit inside it. Four points of headroom, which also makes the
                // tap target of the field itself a sane size.
                .frame(minHeight: 26)
    }

    private var findCounter: some View {
        Text(session.findCountText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Enough for "No matches" at the default size, and allowed to
                // shrink a little rather than push the chevrons off a small
                // screen at an accessibility size.
                .minimumScaleFactor(0.75)
                .frame(minWidth: 62, alignment: .trailing)
                .accessibilityIdentifier("findCount")
                // "3 of 12" on its own is a page number to a listener. The
                // spoken form says what the numbers count; it is also what the
                // XCUITests match, so there is one string, not two.
                .accessibilityLabel(findCountAccessibilityLabel)
    }

    @ViewBuilder
    private var findButtons: some View {
        Button("Previous match", systemImage: "chevron.up") { session.stepFind(by: -1) }
            .disabled(!session.findCanStep)
            .accessibilityIdentifier("findPrevious")
            .accessibilityLabel("Previous match")
        Button("Next match", systemImage: "chevron.down") { session.stepFind(by: 1) }
            .disabled(!session.findCanStep)
            .accessibilityIdentifier("findNext")
            .accessibilityLabel("Next match")
        Button("Done") { endFind() }
            .accessibilityIdentifier("findDone")
            .accessibilityLabel("Done")
            .accessibilityHint("Ends the search and clears the highlights")
            // "Done" is the only word in the bar; on a narrow phone at an
            // accessibility size it wrapped onto two lines rather than push the
            // chevrons, which looked like a broken control.
            .lineLimit(1)
            .fixedSize()
    }

    /// "3 of 12" reads as a page number on its own; "3 of 12 matches" does not.
    /// An empty counter stays empty so VoiceOver skips it.
    private var findCountAccessibilityLabel: String {
        let text = session.findCountText
        guard !text.isEmpty else { return "" }
        return text.range(of: "^[0-9]+ of [0-9]+$", options: .regularExpression) != nil
            ? "\(text) matches" : text
    }

    // MARK: Actions

    private func beginFind() {
        session.isFindBarVisible = true
        // The bar has to exist before its field can take focus.
        DispatchQueue.main.async { findFocused = true }
    }

    private func endFind() {
        findFocused = false
        session.endFind()
    }

    private func commitPage() {
        session.isPageDialogVisible = false
        let text = session.pageEntry.trimmingCharacters(in: .whitespaces)
        guard let number = Int(text) else { return }
        session.goToPage(number: number)
    }

    private func handle(_ command: ReaderCommand) {
        switch command {
        case .focusFind: beginFind()
        case .nextMatch: session.stepFind(by: 1)
        case .previousMatch: session.stepFind(by: -1)
        case .endFind: if session.isFindBarVisible { endFind() }
        case .goToPage:
            session.pageEntry = ""
            session.isPageDialogVisible = true
        }
    }

    /// Print what a printer can use. For a continuous Markdown document that is
    /// *not* what is on screen -- one 40-inch page prints as a single sheet with
    /// the text scaled into illegibility -- so the same paginated re-render an
    /// export uses goes to the print controller. A PDF, and Markdown already in
    /// Pages, print what is shown.
    private func printDocument() {
        session.paginatedDocumentForOutput { result in
            guard case .success(let document) = result,
                  let data = document.dataRepresentation() else { return }
            let info = UIPrintInfo(dictionary: nil)
            info.outputType = .general
            info.jobName = session.title
            let controller = UIPrintInteractionController.shared
            controller.printInfo = info
            controller.printingItem = data
            controller.present(animated: true, completionHandler: nil)
        }
    }

    private func exportPDF() {
        isExporting = true
        session.exportPDF { result in
            isExporting = false
            guard case .success(let url) = result else { return }
            exportFile = ExportFile(url: url)
        }
    }
}
