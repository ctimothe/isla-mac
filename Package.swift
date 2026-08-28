// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Isla",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Isla", targets: ["Isla"]),
    ],
    targets: [
        .target(
            name: "IslaKit",
            path: "Sources/IslaKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Isla",
            dependencies: ["IslaKit"],
            path: "Sources/Isla",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "IslaKitTests",
            dependencies: ["IslaKit"],
            path: "Tests/IslaKitTests"
        ),
    ]
)
