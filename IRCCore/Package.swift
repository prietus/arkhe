// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IRCCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "IRCCore", targets: ["IRCCore"])
    ],
    targets: [
        .target(
            name: "IRCCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "IRCCoreTests",
            dependencies: ["IRCCore"]
        )
    ]
)
