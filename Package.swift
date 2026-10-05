// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FortiBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FortiBarCore", path: "Sources/FortiBarCore"),
        .executableTarget(
            name: "FortiBar",
            dependencies: ["FortiBarCore"],
            path: "Sources/FortiBar"
        ),
        // Root LaunchDaemon: runs charon, loads the connection over VICI and
        // manages routes so connecting needs no sudo/Touch ID.
        .executableTarget(
            name: "FortiBarHelper",
            dependencies: ["FortiBarCore"],
            path: "Sources/FortiBarHelper"
        ),
        .testTarget(
            name: "FortiBarCoreTests",
            dependencies: ["FortiBarCore"],
            path: "Tests/FortiBarCoreTests"
        ),
    ]
)
