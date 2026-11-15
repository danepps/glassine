import AppKit

let app = NSApplication.shared
// Preview bundles have their own identity and never join the release feed.
let isPreview = Bundle.main.object(forInfoDictionaryKey: "GlassinePreviewBuild") as? Bool == true
let appDelegate = AppDelegate(startingUpdater: !isPreview)
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
