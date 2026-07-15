// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SSDMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SSDMonitor",
            path: "Sources/SSDMonitor"
        )
    ]
)
