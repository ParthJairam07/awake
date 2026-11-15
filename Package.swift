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
            // The phone web app (phase 3). Embedded in the executable, so
            // the app bundle stays one binary with no resource bundle to
            // copy or seal.
            resources: [
                .embedInCode("Phone/Web/index.html"),
                .embedInCode("Phone/Web/app.js"),
                .embedInCode("Phone/Web/app.css"),
                .embedInCode("Phone/Web/manifest.webmanifest"),
                .embedInCode("Phone/Web/sw.js"),
                .embedInCode("Phone/Web/icon-180.png"),
                .embedInCode("Phone/Web/icon-192.png"),
                .embedInCode("Phone/Web/icon-512.png"),
            ],
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
