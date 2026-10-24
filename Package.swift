// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentNotch",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentNotchCore", targets: ["AgentNotchCore"]),
        .executable(name: "AgentNotch", targets: ["AgentNotch"]),
    ],
    targets: [
        .target(name: "AgentNotchCore"),
        .executableTarget(name: "AgentNotch", dependencies: ["AgentNotchCore"]),
        .testTarget(name: "AgentNotchCoreTests", dependencies: ["AgentNotchCore"]),
    ]
)
