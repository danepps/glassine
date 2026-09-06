import GlassineCore
import SwiftUI

/// `Prefs` is a plain UserDefaults façade that announces itself with
/// `.glassinePrefsChanged`; SwiftUI needs something observable. This mirrors the
/// four preferences the reader reacts to and refreshes from that notification,
/// so a change made in Settings reaches every scene's reader, thumbnail strip
/// and chrome at once -- the same "one notification, everything re-applies"
/// shape `applyWindowAppearance` has on the Mac.
///
/// Writes go *through* Prefs, never to the mirror: Core's setters are what post
/// the notification, and the refresh below is what updates the mirror.
@MainActor
@Observable
final class PrefsModel {

    static let shared = PrefsModel()

    private(set) var appearance = Prefs.appearance
    private(set) var invertInDarkMode = Prefs.invertInDarkMode
    private(set) var darkPaper = Prefs.darkPaper
    private(set) var sidebarMode = Prefs.sidebarMode
    private(set) var markdownStyle = Prefs.markdownStyle
    private(set) var markdownFontSize = Prefs.markdownFontSize
    private(set) var markdownLayout = Prefs.markdownLayout

    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        let box = MainBox(self)
        observer = NotificationCenter.default.addObserver(
            forName: .glassinePrefsChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { box.value?.refresh() }
        }
    }

    private func refresh() {
        appearance = Prefs.appearance
        invertInDarkMode = Prefs.invertInDarkMode
        darkPaper = Prefs.darkPaper
        sidebarMode = Prefs.sidebarMode
        markdownStyle = Prefs.markdownStyle
        markdownFontSize = Prefs.markdownFontSize
        markdownLayout = Prefs.markdownLayout
    }

    // MARK: Writes

    func setAppearance(_ value: AppearanceMode) { Prefs.appearance = value }
    func setInvertInDarkMode(_ value: Bool) { Prefs.invertInDarkMode = value }
    func setDarkPaper(_ value: DarkPaper) { Prefs.darkPaper = value }
    func setSidebarMode(_ value: SidebarMode) { Prefs.sidebarMode = value }
    func setMarkdownStyle(_ value: String) { Prefs.markdownStyle = value }
    func setMarkdownFontSize(_ value: Int) { Prefs.markdownFontSize = value }
    func setMarkdownLayout(_ value: MarkdownLayout) { Prefs.markdownLayout = value }

    /// True when pages should be drawn light-on-dark right now.
    func isInverted(in colorScheme: ColorScheme) -> Bool {
        colorScheme == .dark && invertInDarkMode
    }
}
