import GlassineCore
import SwiftUI
import UIKit

/// Glassine for iPad and iPhone. A SwiftUI shell around UIKit/PDFKit views --
/// not a taste, a necessity: the dark-mode inversion is `.colorInvert()` +
/// `.hueRotation`, which have no UIKit equivalent (Spike A), so the reader has
/// to be SwiftUI-hosted for the filter to exist at all.
///
/// One document per scene, as one document per tab on the Mac. There is no
/// cross-scene dedupe in v1: opening a document that is already up elsewhere
/// simply opens it again.
@main
struct GlassineApp: App {

    init() {
        AppLaunch.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The launch-time wiring each app owes Core, plus the two iOS-only calibrations.
enum AppLaunch {

    /// The user activity a scene publishes so iPadOS can restore its document,
    /// and that "Open in New Window" carries to a brand-new scene.
    static let activityType = "com.epps.Glassine.readDocument"
    /// Key inside that activity's `userInfo`.
    static let activityBookmarkKey = "bookmark"
    static let activityPathKey = "path"

    @MainActor
    static func configure() {
        // Custom Markdown stylesheets live in Documents/Styles so they show up
        // in the Files app under "On My iPad ▸ Glassine" (UIFileSharingEnabled).
        // Phase 3 reads them; creating the folder now is what makes it visible.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let styles = documents.appendingPathComponent("Styles", isDirectory: true)
        try? FileManager.default.createDirectory(at: styles, withIntermediateDirectories: true)
        Prefs.stylesDirectory = styles

        // The Mac's find ink was calibrated against a linear-light CIColorInvert;
        // iOS inverts in sRGB, so the same green needs a different pre-filter
        // value. See ReaderTheme.matchInk for the arithmetic.
        ReaderPage.matchInk = ReaderTheme.matchInk

        AppearanceBridge.install()
    }
}

/// `Prefs.appearance` applied to the platform. The Mac sets `NSApp.appearance`;
/// iOS has no app-wide equivalent, so every connected scene's windows get an
/// `overrideUserInterfaceStyle`. Using the window (rather than SwiftUI's
/// `.preferredColorScheme`) is deliberate: it also reaches the UIKit views
/// inside the reader -- the scroll indicators, the document picker, the
/// keyboard -- which a SwiftUI environment override does not.
enum AppearanceBridge {

    static func install() {
        Prefs.applyAppearanceOverride = { mode in
            // Core calls this synchronously from the `appearance` setter, which
            // only ever runs on the main thread in this app.
            MainActor.assumeIsolated { apply(mode) }
        }
    }

    @MainActor
    static func apply(_ mode: AppearanceMode = Prefs.appearance) {
        let style: UIUserInterfaceStyle
        switch mode {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
