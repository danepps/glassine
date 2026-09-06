import GlassineCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One scene: a sidebar of panes and, beside it, either the reader or the
/// Recents picker as the launch screen. The iPad analogue of the Mac's window;
/// on iPhone the same panes are a sheet, because a split view there is a
/// navigation stack and a sidebar would push the document off screen.
@MainActor
struct RootView: View {

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme

    private let prefs = PrefsModel.shared

    @State private var session: DocumentSession?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var showsPanes = false
    @State private var showsSettings = false
    @State private var showsPicker = false

    var body: some View {
        content
            .tint(.accentColor)
            // Files, Mail and the share sheet all arrive here.
            .onOpenURL { open($0) }
            // Scene restoration, and "Open in New Window" landing in a fresh scene.
            .onContinueUserActivity(AppLaunch.activityType) { activity in
                if let url = DocumentSession.url(from: activity) { open(url) }
            }
            .userActivity(AppLaunch.activityType, isActive: session != nil) { activity in
                session?.fill(activity)
            }
            .sheet(isPresented: $showsSettings) { SettingsView() }
            .sheet(isPresented: $showsPanes) {
                NavigationStack { panes(inSheet: true) }
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showsPicker) {
                DocumentPicker { url in open(url) }
                    .ignoresSafeArea()
            }
            .onAppear {
                // Windows exist only once a scene has connected, so the saved
                // Light/Dark override is applied from here rather than at launch.
                AppearanceBridge.apply()
                openLaunchArgumentIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        if sizeClass == .compact {
            NavigationStack { detail }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                panes(inSheet: false)
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session {
            ReaderView(session: session,
                       onShowPanes: { showsPanes = true },
                       onShowSettings: { showsSettings = true },
                       onClose: { close() })
        } else {
            launchScreen
        }
    }

    /// Nothing open: the Recents picker fills the whole window, which is what
    /// the Mac's launch window and start tabs show.
    private var launchScreen: some View {
        RecentsList(onOpen: { open($0) },
                    onOpenInNewWindow: { openInNewWindow($0) },
                    onOpenOther: { showsPicker = true })
            .navigationTitle("Recents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open…", systemImage: "folder") { showsPicker = true }
                        .accessibilityIdentifier("openOtherToolbar")
                        .accessibilityLabel("Open")
                        .accessibilityHint("Choose a document from Files")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                        .accessibilityIdentifier("settingsButton")
                        .accessibilityLabel("Settings")
                }
            }
    }

    // MARK: The panes

    /// Recents / Thumbnails / Contents. Recents is the iOS answer to the Mac's
    /// start tab: a way into another document without leaving this one.
    @ViewBuilder
    private func panes(inSheet: Bool) -> some View {
        VStack(spacing: 0) {
            Picker("Pane", selection: sidebarMode) {
                Text("Recents").tag(SidebarMode.recents)
                Text("Thumbnails").tag(SidebarMode.thumbnails)
                Text("Contents").tag(SidebarMode.outline)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("panePicker")
            // A segmented picker in a bare VStack has no visible title, so it
            // has no spoken one either: VoiceOver would say "Recents, selected"
            // with nothing to say what the choice is between.
            .accessibilityLabel("Sidebar pane")
            .accessibilityHint("Choose what this pane shows")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch prefs.sidebarMode {
            case .recents:
                RecentsList(onOpen: { open($0); showsPanes = false },
                            onOpenInNewWindow: { openInNewWindow($0) },
                            onOpenOther: { showsPanes = false; showsPicker = true })
            case .thumbnails:
                paneOrPlaceholder { session in
                    ThumbnailsPane(session: session,
                                   inverted: prefs.isInverted(in: colorScheme),
                                   paper: prefs.darkPaper)
                }
            case .outline:
                paneOrPlaceholder { session in
                    ContentsPane(session: session, onNavigate: { showsPanes = false })
                }
            }
        }
        .background(ReaderTheme.chrome(inverted: prefs.isInverted(in: colorScheme),
                                       colorScheme: colorScheme,
                                       paper: prefs.darkPaper))
        .navigationTitle(inSheet ? "Panes" : "Glassine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showsPanes = false }
                }
            }
        }
    }

    @ViewBuilder
    private func paneOrPlaceholder<Pane: View>(
        @ViewBuilder _ pane: (DocumentSession) -> Pane
    ) -> some View {
        if let session {
            pane(session)
        } else {
            ContentUnavailableView("No Document", systemImage: "doc",
                                   description: Text("Open a document to see this pane."))
        }
    }

    private var sidebarMode: Binding<SidebarMode> {
        Binding(get: { prefs.sidebarMode }, set: { prefs.setSidebarMode($0) })
    }

    // MARK: Opening

    private func open(_ url: URL) {
        // A file the reader cannot read at all should not replace what is on
        // screen; the session reports anything else as an alert.
        guard DocumentTypes.canOpen(url) else { return }
        session?.close()
        let opened = DocumentSession(url: url)
        session = opened
        opened.open()
        columnVisibility = .detailOnly
    }

    private func close() {
        session?.close()
        session = nil
    }

    /// iPad side-by-side. A brand-new scene picks the document up from the
    /// activity in `onContinueUserActivity`; a document already open somewhere
    /// else simply opens again, as a second tab would on the Mac.
    private func openInNewWindow(_ url: URL) {
        let activity = NSUserActivity(activityType: AppLaunch.activityType)
        activity.targetContentIdentifier = url.path
        var info: [String: Any] = [AppLaunch.activityPathKey: url.path]
        if let bookmark = try? url.bookmarkData() {
            info[AppLaunch.activityBookmarkKey] = bookmark
        }
        activity.addUserInfoEntries(from: info)
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity,
                                                           options: nil, errorHandler: nil)
    }

    private func openLaunchArgumentIfNeeded() {
        #if DEBUG
        // `-open <path>` at launch, for the UI tests and for driving the app
        // from a script: simctl cannot hand a file URL to a running app.
        // `-key value` lands in NSArgumentDomain, so this is just a read.
        //
        // A bare name is resolved against the app's own Documents folder,
        // because `simctl install` of a new build gives the app a *new* data
        // container UUID and any absolute path captured beforehand is stale.
        guard session == nil, let argument = UserDefaults.standard.string(forKey: "open")
        else { return }
        let fileManager = FileManager.default
        var path = argument
        if !fileManager.fileExists(atPath: path) {
            let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            path = documents.appendingPathComponent((argument as NSString).lastPathComponent).path
        }
        guard fileManager.fileExists(atPath: path) else { return }
        open(URL(fileURLWithPath: path))
        #endif
    }
}

/// What Glassine will open, in one place. The extension list is the Mac's,
/// because LaunchServices hands over a plain-text type (or nothing at all) for
/// Markdown often enough that the file name is the reliable answer.
enum DocumentTypes {
    static let markdown = UTType(importedAs: "net.daringfireball.markdown",
                                 conformingTo: .plainText)

    static let markdownExtensions: Set<String> =
        ["md", "markdown", "mdown", "mkdn", "mkd", "mdwn"]

    static func canOpen(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pdf" || markdownExtensions.contains(ext)
    }

    static func kind(of url: URL) -> DocumentSession.Kind {
        markdownExtensions.contains(url.pathExtension.lowercased()) ? .markdown : .pdf
    }
}
