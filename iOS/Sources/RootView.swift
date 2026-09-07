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
                       onNewWindow: { newWindow() },
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

    /// A second window: the iPad answer to the Mac's Cmd-T, reached from the
    /// reader's ellipsis menu and from Cmd-N. The activity carries no path, so
    /// `DocumentSession.url(from:)` reads it as nothing, the new scene's
    /// `session` stays nil and `detail` shows `launchScreen` -- the Recents
    /// picker, which is exactly what a start tab shows. (The requesting scene
    /// gets the empty activity back through `onContinueUserActivity` as well;
    /// the same nil is what makes that a no-op.)
    ///
    /// The empty activity is not decoration. Activating with `userActivity: nil`
    /// -- and `activateSceneSession(for:)`, the iOS 17 spelling of the same call
    /// -- does create the scene, but on the iPad Pro 13-inch (M5) simulator it
    /// connects in the *background*: `connectedScenes` went from one to two with
    /// states foregroundActive and background, and the scene's window carried no
    /// content at all in the accessibility tree. Handing over an activity of the
    /// type the app declares in `NSUserActivityTypes` is the same call "Open in
    /// New Window" makes, and it gets the scene attached and rendered.
    ///
    /// `options` stays nil deliberately: a `requestingScene`, or a
    /// `UIWindowSceneProminentPlacement`, moved the whole app into iPadOS 26's
    /// windowed presentation -- the reader became a floating window with a
    /// close button -- which is not something a menu item should do.
    private func newWindow() {
        let activity = NSUserActivity(activityType: AppLaunch.activityType)
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity,
                                                           options: nil, errorHandler: nil)
    }

    #if DEBUG
    private static var launchArgumentConsumed = false
    #endif

    private func openLaunchArgumentIfNeeded() {
        #if DEBUG
        // `-open <path>` at launch, for the UI tests and for driving the app
        // from a script: simctl cannot hand a file URL to a running app.
        // `-key value` lands in NSArgumentDomain, so this is just a read.
        //
        // A bare name is resolved against the app's own Documents folder,
        // because `simctl install` of a new build gives the app a *new* data
        // container UUID and any absolute path captured beforehand is stale.
        //
        // Once per *process*, not per scene. The argument lives in
        // NSArgumentDomain for the app's whole life, and every new scene's
        // RootView appears with `session == nil` -- so on Dan's iPad a New
        // Window from an app launched with `-open report.pdf` came up showing
        // report.pdf again instead of Recents. A TestFlight build has no hook
        // at all, but the Debug one has to behave like it.
        guard session == nil, !Self.launchArgumentConsumed,
              let argument = UserDefaults.standard.string(forKey: "open")
        else { return }
        Self.launchArgumentConsumed = true
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
