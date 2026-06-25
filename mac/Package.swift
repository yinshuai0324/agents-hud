// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentsHUD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AgentsHUD",
            path: "Sources/AgentsHUD"
        )
    ]
)
