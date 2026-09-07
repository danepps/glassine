// swift-tools-version:5.9
import PackageDescription

// GlassineCore: the portable half of Glassine -- Markdown conversion,
// preferences, the file watcher, and the reader logic (find, outline, reading
// position and progress, the render queue, the recents model) that the Mac app
// and the iOS app both drive. Nothing here imports AppKit or UIKit; the two
// places a platform differs are behind `#if canImport(UIKit)` or a hook.
//
// A separate package directory rather than a second target in the root
// manifest, so Sparkle (a macOS-only binary xcframework) never enters an iOS
// build graph.
let package = Package(
    name: "GlassineCore",
    // `.iOS(.v18)` needs tools-version 6.0; the string form says the same thing
    // and keeps this manifest on 5.9, like the root's.
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [
        .library(name: "GlassineCore", targets: ["GlassineCore"])
    ],
    dependencies: [
        // Same pin as the root manifest: swift-markdown's own manifest depends
        // on swift-cmark by *branch*, so SwiftPM refuses a version range and
        // the revision is spelled out. Both must stay identical or the two
        // packages resolve to two copies.
        .package(url: "https://github.com/swiftlang/swift-markdown.git",
                 revision: "27b7fc1a19068bcea3d2072db0ce86360d1400ed")
    ],
    targets: [
        .target(
            name: "GlassineCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/GlassineCore",
            swiftSettings: [
                // Core is held to a stricter standard than the app that
                // consumes it: the iOS target starts concurrency-clean, and
                // anything shared has to be safe for both.
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .testTarget(
            name: "GlassineCoreTests",
            dependencies: ["GlassineCore"],
            path: "Tests/GlassineCoreTests"
        )
    ]
)
