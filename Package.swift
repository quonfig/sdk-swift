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
