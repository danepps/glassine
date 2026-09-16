// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Glassine",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        // The portable half of the app. Source-only and local, so `swift build`
        // compiles it straight into the executable and build.sh needs no change.
        // It owns the swift-markdown dependency now (pinned by revision there,
        // because swift-markdown's own manifest depends on swift-cmark by
        // *branch* and SwiftPM refuses a version range on top of that).
        .package(path: "Core")
    ],
    targets: [
        .executableTarget(
            name: "GlassineQuickLook",
            dependencies: [.product(name: "GlassineCore", package: "Core")],
            path: "Sources/GlassineQuickLook",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            // Apple's app-extension entry point, also used by Xcode's template.
            // build.sh supplies the .appex wrapper and signs it before the app.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                "-Xlinker", "-application_extension"
            ])]
        ),
        .executableTarget(
            name: "Glassine",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "GlassineCore", package: "Core")
            ],
            path: "Sources/Glassine",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            // `swift build` does not embed frameworks the way Xcode does, so
            // build.sh copies Sparkle.framework into Contents/Frameworks and
            // the binary needs an rpath pointing there.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "GlassineTests",
            dependencies: ["Glassine", .product(name: "GlassineCore", package: "Core")],
            path: "Tests/GlassineTests"
        )
    ]
)
