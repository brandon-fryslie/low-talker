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
        // WhisperKit ships inside the Argmax OSS SDK since 1.0; the WhisperKit product
        // is the only one linked.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        // [LAW:one-way-deps] Core knows nothing of the CLI or the app; both link it.
        .target(
            name: "LowTalkerCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .executableTarget(
            name: "lowtalker",
            dependencies: [
                "LowTalkerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LowTalkerCoreTests",
            dependencies: [
                "LowTalkerCore",
                // The tests build WhisperKit's result types by hand to exercise the
                // mapping without model weights.
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
