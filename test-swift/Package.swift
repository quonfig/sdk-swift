// swift-tools-version:5.9
import PackageDescription

// test-swift: the validation / smoke app for the Quonfig Apple-platform SDK,
// mirroring the test-* app pattern used by the other SDKs (plan §6 step 6).
//
// It depends on the local `Quonfig` package by path and drives the full public
// surface — initialize, typed getters, subscribe, updateContext — against either:
//   - a LIVE api-delivery (set QUONFIG_SDK_KEY + QUONFIG_DOMAIN), or
//   - a built-in in-process FIXTURE server that flips a flag on a cadence so the
//     poll loop visibly updates (the default, so the demo runs with no server).
//
// Built as a SwiftPM executable so `swift build` / `swift run` verify it
// end-to-end in CI without an Xcode project or a simulator. The SwiftUI views
// (FlagListView) compile on iOS/macOS for real on-device use; the executable's
// headless demo (main.swift) is the CI-runnable entry.
let package = Package(
    name: "test-swift",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    dependencies: [
        .package(name: "quonfig-swift", path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "TestSwiftApp",
            dependencies: [
                .product(name: "Quonfig", package: "quonfig-swift"),
            ],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
    ]
)
