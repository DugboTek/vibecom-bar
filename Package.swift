// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibecomBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "VibecomBarCore"),
        .executableTarget(name: "VibecomBar", dependencies: ["VibecomBarCore"]),
        .testTarget(
            name: "VibecomBarCoreTests",
            dependencies: ["VibecomBarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
