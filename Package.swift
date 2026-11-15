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
                "AwakeLeaseKit",
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
            dependencies: ["Awake", "AwakeLeaseKit", "AwakeTestHome"],
            path: "Tests/AwakeTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Phase 4 (leases). The lease file format, shared by the app and
        // the command so the JSON one writes is the JSON the other reads.
        .target(
            name: "AwakeLeaseKit",
            path: "Sources/AwakeLeaseKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // The `awake` command and its MCP server. Foundation only. Built as
        // `awake-cli` and installed as `awake`: the default macOS volume
        // ignores case, so a product named `awake` would be the same file
        // as the app's `Awake` in .build and in Contents/MacOS.
        .executableTarget(
            name: "awake-cli",
            dependencies: ["AwakeLeaseKit"],
            path: "Sources/AwakeCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "AwakeLeaseTests",
            dependencies: ["awake-cli", "AwakeLeaseKit", "AwakeTestHome"],
            path: "Tests/AwakeLeaseTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
