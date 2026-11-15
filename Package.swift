// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Awake",
    platforms: [
        .macOS(.v26),
    ],
    targets: [
        .executableTarget(
            name: "Awake",
            dependencies: ["AwakeLeaseKit"],
            path: "Sources/Awake",
            swiftSettings: [
                .swiftLanguageMode(.v6),
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
            name: "AwakeCLITests",
            dependencies: ["awake-cli", "AwakeLeaseKit", "AwakeTestHome"],
            path: "Tests/AwakeCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
