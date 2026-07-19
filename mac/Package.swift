// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentsHUD",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.20.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        // Pure logic: data collection, state machine, HTTP/WS server. No AppKit,
        // so it stays unit-testable and could back a future CLI.
        .target(
            name: "AgentsHUDCore",
            dependencies: [
                .product(name: "FlyingFox", package: "FlyingFox"),
            ],
            path: "Sources/AgentsHUDCore"
        ),
        .executableTarget(
            name: "AgentsHUD",
            dependencies: [
                "AgentsHUDCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AgentsHUD",
            resources: [
                .copy("Resources/hooks"),
            ]
        ),
        .testTarget(
            name: "AgentsHUDCoreTests",
            dependencies: ["AgentsHUDCore"],
            path: "Tests/AgentsHUDCoreTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
