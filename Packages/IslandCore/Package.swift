// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IslandCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IslandCore", targets: ["IslandCore"])
    ],
    targets: [
        .target(name: "IslandCore"),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
    ]
)
