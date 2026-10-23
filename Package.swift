// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacMonitor",
            path: "Sources/MacMonitor"
        )
    ]
)
