// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Awake",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        // Auto-updates (Sources/Awake/UI/Updater.swift). A binary framework:
        // scripts/build-app.sh copies Sparkle.framework into the bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.3"),
    ],
    targets: [
        .executableTarget(
            name: "Awake",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Awake",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                // Where the app bundle keeps Sparkle.framework. SwiftPM's own
                // rpath (@loader_path) only finds it beside the binary in .build.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // Test-only C target. Its constructor points AWAKE_HOME at a temp
        // directory when the test bundle loads, before any test can log.
        .target(
            name: "AwakeTestHome",
            path: "Tests/AwakeTestHome"
        ),
        .testTarget(
            name: "AwakeTests",
            dependencies: ["Awake", "AwakeTestHome"],
            path: "Tests/AwakeTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
