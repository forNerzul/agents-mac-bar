// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentsBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AgentsBarCore"),
        .executableTarget(
            name: "AgentsBar",
            dependencies: ["AgentsBarCore"]
        ),
        .testTarget(
            name: "AgentsBarCoreTests",
            dependencies: ["AgentsBarCore"]
        ),
    ]
)
