// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArchScan",
    platforms: [.macOS(.v15)],
    targets: [
        // The app: SwiftUI views and window setup.
        .executableTarget(
            name: "ArchScan",
            dependencies: ["ArchScanCore"]
        ),
        // Storage and import logic, kept free of UI so it can be tested.
        .target(name: "ArchScanCore"),
        .testTarget(
            name: "ArchScanCoreTests",
            dependencies: ["ArchScanCore"]
        ),
    ]
)
