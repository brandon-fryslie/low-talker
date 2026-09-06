// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "low-talker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LowTalkerCore", targets: ["LowTalkerCore"]),
        .library(name: "Keystrokes", targets: ["Keystrokes"]),
        .library(name: "KeyboardLayout", targets: ["KeyboardLayout"]),
        .library(name: "VirtualKeyboard", targets: ["VirtualKeyboard"]),
        .library(name: "KeyboardService", targets: ["KeyboardService"]),
        .executable(name: "lowtalker", targets: ["lowtalker"]),
        .executable(name: "lowtalker-keyboardd", targets: ["lowtalker-keyboardd"]),
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
        // The vocabulary at the seam between deciding what to type and typing it: a HID
        // usage, the modifiers held with it, and the two names one key goes by. It links
        // nothing, so neither the layout nor the device has to link the other to speak.
        .target(name: "Keystrokes"),
        // Carbon lives here and not in VirtualKeyboard, so the privileged side that owns
        // the device never links a window server API. [LAW:one-way-deps]
        .target(name: "KeyboardLayout", dependencies: ["Keystrokes"]),
        // [LAW:one-way-deps] Everything about the virtual keyboard and nothing about
        // low-talker: no dependency on LowTalkerCore, so it leaves for its own package by
        // a move rather than by an untangling.
        .target(name: "VirtualKeyboard", dependencies: ["Keystrokes"]),
        // What crosses the privilege boundary, and the client's side of it. It links
        // Keystrokes and nothing else: not the layout, because a root helper must never
        // read one, and not the device, because a client must never open one.
        // [LAW:one-way-deps]
        .target(name: "KeyboardService", dependencies: ["Keystrokes"]),
        // The root daemon that owns the device. It links VirtualKeyboard and the seam, and
        // deliberately not KeyboardLayout: text never reaches this process.
        .executableTarget(
            name: "lowtalker-keyboardd",
            dependencies: ["KeyboardService", "VirtualKeyboard", "Keystrokes"]
        ),
        .executableTarget(
            name: "lowtalker",
            dependencies: [
                "LowTalkerCore",
                "VirtualKeyboard",
                "KeyboardLayout",
                "KeyboardService",
                "Keystrokes",
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
        // The wire protocol against a fake daemon on the other end of a socketpair, so
        // the framing is proven without root and without the driver.
        .testTarget(
            name: "VirtualKeyboardTests",
            dependencies: ["VirtualKeyboard", "Keystrokes"]
        ),
        // The vocabulary stands on its own, so its tests do too: nothing here imports a
        // layout or a device. [LAW:decomposition]
        .testTarget(
            name: "KeystrokesTests",
            dependencies: ["Keystrokes"]
        ),
        // The reverse map is built from a real layout's own data, so these read the
        // installed US and Dvorak layouts rather than a fixture that could agree with a
        // wrong reading of them.
        .testTarget(
            name: "KeyboardLayoutTests",
            dependencies: ["KeyboardLayout", "Keystrokes"]
        ),
        // The CLI's table shape is its contract; this pins column names to fields.
        .testTarget(
            name: "lowtalkerTests",
            dependencies: ["lowtalker", "LowTalkerCore", "VirtualKeyboard", "Keystrokes"]
        ),
    ]
)
