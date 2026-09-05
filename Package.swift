// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "low-talker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LowTalkerCore", targets: ["LowTalkerCore"]),
        .executable(name: "lowtalker", targets: ["lowtalker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // [LAW:one-way-deps] Core knows nothing of the CLI or the app; both link it.
        .target(name: "LowTalkerCore"),
        .executableTarget(
            name: "lowtalker",
            dependencies: [
                "LowTalkerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LowTalkerCoreTests",
            dependencies: ["LowTalkerCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
