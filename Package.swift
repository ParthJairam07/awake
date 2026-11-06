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
    ]
)
