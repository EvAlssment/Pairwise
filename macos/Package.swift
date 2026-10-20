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
        .package(path: "../vendor/livekit-client-swift")
    ],
    targets: [
        .executableTarget(name: "PairDesk", dependencies: [.product(name: "LiveKit", package: "livekit-client-swift")]),
        .executableTarget(name: "PairDeskAgentMCP"),
        .testTarget(name: "PairDeskTests", dependencies: ["PairDesk"])
    ],
    swiftLanguageModes: [.v5]
)
