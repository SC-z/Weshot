// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "WeShot",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WeShotCore", targets: ["WeShotCore"]),
        .executable(name: "WeShot", targets: ["WeShotApp"]),
    ],
    targets: [
        .target(
            name: "WeShotCore",
            path: "Sources/WeShotCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WeShotApp",
            dependencies: ["WeShotCore"],
            path: "Sources/WeShotApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WeShotCoreTests",
            dependencies: ["WeShotCore"],
            path: "Tests/WeShotCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WeShotAppTests",
            dependencies: ["WeShotApp"],
            path: "Tests/WeShotAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
