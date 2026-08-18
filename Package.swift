// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimBridgeKit",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "SimBridgeServer", targets: ["SimBridgeServer"]),
        .library(name: "SimBridgeShell", targets: ["SimBridgeShell"]),
    ],
    targets: [
        .target(name: "SimBridgeServer"),
        .target(name: "SimBridgeShell", dependencies: ["SimBridgeServer"]),
        .testTarget(name: "SimBridgeServerTests", dependencies: ["SimBridgeServer"]),
    ]
)
