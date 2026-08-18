// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DynamicIsland",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DynamicIsland", targets: ["DynamicIsland"]),
    ],
    targets: [
        .target(
            name: "DynamicIslandKit",
            path: "Sources/DynamicIslandKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DynamicIsland",
            dependencies: ["DynamicIslandKit"],
            path: "Sources/DynamicIsland",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DynamicIslandKitTests",
            dependencies: ["DynamicIslandKit"],
            path: "Tests/DynamicIslandKitTests"
        ),
    ]
)
