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
    ]
)
