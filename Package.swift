// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "quonfig-swift",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "Quonfig",
            targets: ["Quonfig"]
        ),
    ],
    targets: [
        .target(
            name: "Quonfig",
            dependencies: [],
            resources: [
                // App Store privacy manifest (plan §1, §2.10). `process` bundles it
                // into Bundle.module for SPM consumers — the Statsig trap is shipping
                // the file at repo root but NOT wiring it into resources (#7).
                .process("Resources/PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
        .testTarget(
            name: "QuonfigTests",
            dependencies: ["Quonfig"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
    ]
)
