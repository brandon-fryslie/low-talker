// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "low-talker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LowTalkerCore", targets: ["LowTalkerCore"]),
        .library(name: "Flavors", targets: ["Flavors"]),
        .library(name: "Keystrokes", targets: ["Keystrokes"]),
        .library(name: "KeyboardLayout", targets: ["KeyboardLayout"]),
        .library(name: "Pointing", targets: ["Pointing"]),
        .library(name: "DriverExtension", targets: ["DriverExtension"]),
        .library(name: "Onboarding", targets: ["Onboarding"]),
        .library(name: "VirtualKeyboard", targets: ["VirtualKeyboard"]),
        .library(name: "KeyboardService", targets: ["KeyboardService"]),
        .library(name: "Signals", targets: ["Signals"]),
        .library(name: "Typing", targets: ["Typing"]),
        .library(name: "Dictation", targets: ["Dictation"]),
        .executable(name: "lowtalker", targets: ["lowtalker"]),
        .executable(name: "lowtalker-keyboardd", targets: ["lowtalker-keyboardd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // WhisperKit ships inside the Argmax OSS SDK since 1.0; the WhisperKit product
        // is the only one linked.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        // [LAW:one-way-deps] Core knows nothing of the CLI or the app; both link it.
        // Which installation this is: the one name every other name in a flavor is
        // built from. It depends on nothing, so the root helper and the app's upper
        // layers can both read it without either depending on the other.
        // [LAW:one-way-deps]
        .target(name: "Flavors"),
        .testTarget(name: "FlavorsTests", dependencies: ["Flavors"]),
        .target(
            name: "LowTalkerCore",
            dependencies: [
                "Flavors",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        // The vocabulary at the seam between deciding what to type and typing it: a HID
        // usage, the modifiers held with it, and the two names one key goes by. It links
        // nothing, so neither the layout nor the device has to link the other to speak.
        .target(name: "Keystrokes"),
        // Where the Karabiner-DriverKit-VirtualHIDDevice driver extension stands on this
        // Mac, and the four readings that answer is derived from. It links nothing and
        // knows nothing of low-talker, so the CLI, the menu-bar app and
        // scripts/virtual-hid-driver all reach one vocabulary instead of three.
        // [LAW:one-source-of-truth]
        .target(name: "DriverExtension"),
        // The verdict table is a pure function of four readings, so every combination is
        // exercised here - including the ones this Mac cannot be put into.
        .testTarget(name: "DriverExtensionTests", dependencies: ["DriverExtension"]),
        // Answering a signal rather than obeying it, for every process here that has an
        // ending of its own to unwind through. It links nothing, so the root daemon
        // watches through the same unit as the CLI and the app without linking the
        // transcriber they reach it through. [LAW:one-source-of-truth]
        .target(name: "Signals"),
        // The gate and the flag a suite plants in concurrent work to see where it has
        // got to. A plain target because test targets cannot import one another's
        // sources, and in no product because nothing ships it. [LAW:one-source-of-truth]
        .target(name: "TestProbes"),
        // The same seam for the mouse: a button, a count of motion, a move and a scroll.
        // Like Keystrokes it links nothing, so the device and the click decision share a
        // vocabulary without sharing a dependency. [LAW:one-way-deps]
        .target(name: "Pointing"),
        // Carbon lives here and not in VirtualKeyboard, so the privileged side that owns
        // the device never links a window server API. [LAW:one-way-deps]
        .target(name: "KeyboardLayout", dependencies: ["Keystrokes"]),
        // [LAW:one-way-deps] Everything about the virtual devices, the keyboard and the
        // pointing one, and nothing about low-talker: no dependency on LowTalkerCore, so
        // it leaves for its own package by a move rather than by an untangling.
        .target(name: "VirtualKeyboard", dependencies: ["DriverExtension", "Keystrokes", "Pointing"]),
        // Everything that must hold before low-talker can type, as a list a reader can
        // act on: what was read off this Mac, and the step for whatever is missing. It
        // links the driver's vocabulary and the service seam and nothing else - no
        // device and no window server - so both the CLI and the menu-bar app can show
        // the same words. [LAW:one-source-of-truth]
        .target(name: "Onboarding", dependencies: ["DriverExtension", "KeyboardService", "Flavors"]),
        // The steps are what a person acts on, so they are asserted as values rather
        // than scraped off a terminal.
        .testTarget(name: "OnboardingTests", dependencies: ["Onboarding", "DriverExtension", "KeyboardService", "Flavors"]),
        // What crosses the privilege boundary, and the client's side of it. It links the
        // two vocabularies and nothing else: not the layout, because a root helper must
        // never read one, and not the device, because a client must never open one.
        // [LAW:one-way-deps]
        .target(name: "KeyboardService", dependencies: ["Flavors", "Keystrokes", "Pointing"]),
        .testTarget(name: "KeyboardServiceTests", dependencies: ["KeyboardService", "Flavors", "Keystrokes", "Pointing"]),
        // The app's one inserter and its one pointer: text and chords lowered to keystrokes,
        // clicks and scrolls to pointing reports, with the hotkey refused and the target app
        // re-proven in front before each one. It links the core for the actions it performs,
        // the layout and both vocabularies, and takes the keyboard and the mouse as values,
        // which is what lets each run against the helper in the app and against the
        // driver under sudo. [LAW:composability]
        .target(name: "Typing", dependencies: ["LowTalkerCore", "KeyboardLayout", "Keystrokes", "Pointing", "Signals"]),
        // Driven against a keyboard the test plays, so a run can be stopped inside any
        // keystroke and its report read back.
        .testTarget(name: "TypingTests", dependencies: ["Typing", "LowTalkerCore", "KeyboardLayout", "Keystrokes", "Pointing", "Signals", "TestProbes"]),
        // The loop from a press to typed text, with every collaborator taken as a value.
        // Its own target rather than app code so the loop runs under `swift test`; the
        // app links it and hands over the real microphone, engine and keyboard.
        // [LAW:decomposition]
        .target(name: "Dictation", dependencies: ["LowTalkerCore", "Typing", "KeyboardLayout"]),
        .testTarget(name: "DictationTests", dependencies: ["Dictation", "LowTalkerCore", "Typing", "KeyboardLayout", "Keystrokes", "Pointing", "TestProbes"]),
        // The root daemon that owns the devices. It links VirtualKeyboard, both vocabularies,
        // the seam and the signal watch, DriverExtension for the identity the keyboard files
        // its Keyboard Setup Assistant answer under, and deliberately not KeyboardLayout:
        // text never reaches this process.
        .executableTarget(
            name: "lowtalker-keyboardd",
            dependencies: ["KeyboardService", "VirtualKeyboard", "DriverExtension", "Keystrokes", "Pointing", "Signals", "Flavors"]
        ),
        // The authorization boundary of a root keystroke service, checked against the
        // test process's own identity and audit token: real code signing, no root.
        .testTarget(
            name: "lowtalker-keyboarddTests",
            dependencies: ["lowtalker-keyboardd", "KeyboardService", "VirtualKeyboard", "DriverExtension", "Keystrokes", "Pointing", "Signals", "Flavors"]
        ),
        .executableTarget(
            name: "lowtalker",
            dependencies: [
                "LowTalkerCore",
                "Flavors",
                "DriverExtension",
                "Onboarding",
                "VirtualKeyboard",
                "KeyboardLayout",
                "KeyboardService",
                "Keystrokes",
                "Typing",
                "Dictation",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LowTalkerCoreTests",
            dependencies: [
                "LowTalkerCore",
                "TestProbes",
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
            dependencies: ["VirtualKeyboard", "DriverExtension", "Keystrokes", "Pointing"]
        ),
        // The vocabulary stands on its own, so its tests do too: nothing here imports a
        // layout or a device. [LAW:decomposition]
        .testTarget(
            name: "KeystrokesTests",
            dependencies: ["Keystrokes"]
        ),
        .testTarget(
            name: "PointingTests",
            dependencies: ["Pointing"]
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
