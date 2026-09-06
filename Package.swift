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
        )
    ]
)
