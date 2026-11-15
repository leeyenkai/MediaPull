// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "MediaPullKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(
            name: "MediaPullKit",
            targets: [
                "MediaPullCore", "MediaPullNet", "MediaPullMedia", "MediaPullEngines",
                "MediaPullLibrary", "MediaPullStore", "MediaPullBrowser", "MediaPullAnalysis",
            ]
        ),
    ],
    targets: [
        .target(
            name: "MediaPullCore",
            resources: [.copy("Resources/public_suffix_list.dat")],
            swiftSettings: settings
        ),
        .target(name: "MediaPullNet", dependencies: ["MediaPullCore"], swiftSettings: settings),
        .target(name: "MediaPullMedia", dependencies: ["MediaPullCore"], swiftSettings: settings),
        .target(
            name: "MediaPullEngines",
            dependencies: ["MediaPullCore", "MediaPullNet", "MediaPullMedia"],
            swiftSettings: settings
        ),
        .target(
            name: "MediaPullLibrary",
            dependencies: ["MediaPullCore", "MediaPullNet", "MediaPullMedia", "MediaPullEngines"],
            swiftSettings: settings
        ),
        .target(name: "MediaPullStore", dependencies: ["MediaPullCore"], swiftSettings: settings),
        .target(
            name: "MediaPullBrowser",
            dependencies: ["MediaPullCore", "MediaPullNet"],
            resources: [.copy("Resources/extract.js"), .copy("Resources/guard.js")],
            swiftSettings: settings
        ),
        .target(name: "MediaPullAnalysis", dependencies: ["MediaPullCore", "MediaPullMedia"], swiftSettings: settings),
        .testTarget(
            name: "MediaPullKitTests",
            dependencies: [
                "MediaPullCore", "MediaPullNet", "MediaPullMedia", "MediaPullEngines",
                "MediaPullLibrary", "MediaPullStore", "MediaPullBrowser", "MediaPullAnalysis",
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: settings
        ),
    ]
)
