import Testing

/// Every macOS test runs inside this one serialized suite.
///
/// These tests share one process-wide AppKit: `NSApplication.shared`, the main
/// run loop, `NotificationCenter.default`, and above all `Prefs.defaults`, which
/// most of them swap for an isolated `UserDefaults` suite and restore on exit.
/// Swift Testing runs top-level suites concurrently and interleaves `@MainActor`
/// tests at every `await`, so one suite's isolated store could be in place
/// while another suite saved into it and read back after it was gone, and a
/// `Prefs` setter in one test re-rendered the Markdown documents open in
/// another. Those were the "environmental" failures in Reader Mode, File
/// presenter, and Markdown refresh. Nesting the suites here (an `extension`
/// is enough) makes the parent's `.serialized` trait apply to all of them.
@Suite(.serialized)
enum MacAppTests {}
