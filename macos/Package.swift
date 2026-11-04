// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PairDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PairDesk", targets: ["PairDesk"]),
        .executable(name: "pairdesk-agent-mcp", targets: ["PairDeskAgentMCP"])
    ],
    dependencies: [
        .package(path: "../shared"),
        .package(path: "../vendor/livekit-client-swift"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(name: "PairDesk", dependencies: [
            .product(name: "LiveKit", package: "livekit-client-swift"),
            .product(name: "PairwiseCore", package: "shared"),
            .product(name: "Sparkle", package: "Sparkle")
        ]),
        .executableTarget(name: "PairDeskAgentMCP"),
        .testTarget(name: "PairDeskTests", dependencies: ["PairDesk"])
    ],
    swiftLanguageModes: [.v5]
)
