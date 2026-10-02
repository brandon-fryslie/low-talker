/// The names macOS keys LowTalker by: its bundle identifiers, its input source, and the
/// ports its processes answer on.
///
/// [LAW:one-source-of-truth] There is one LowTalker. A development build and a release build
/// are the same app under these same names, differing only in the certificate that signs
/// them and in whether the build may accept connections, so installing either replaces the
/// other. No name here is chosen by the kind of build.
///
/// [LAW:one-way-deps] This module depends on nothing, which is what lets both the input
/// method - a sandboxed process that must stay lean - and the app's higher layers read from
/// one source without either depending on the other.
public enum AppIdentity {
    /// What `CFBundleIdentifier` holds: the identity LaunchServices knows the app by and TCC
    /// keys the Microphone grant to. Every other name here is grown from it, so a rename
    /// reaches all of them together.
    public static let bundleIdentifier = "ai.promptctl.low-talker"

    /// What `CFBundleIdentifier` holds inside the input method bundle, the one the installer
    /// package puts in `/Library/Input Methods` beside the app.
    ///
    /// The `.inputmethod` segment is load-bearing and its POSITION is load-bearing, which
    /// is not a convention but a rule macOS enforces silently. Measured on macOS Tahoe
    /// (low-input-method-s71.0ae) against bundles differing in nothing but this string:
    /// an identifier ending in `.inputmethod` registers NOTHING, and so does one carrying
    /// no such segment at all, while `…inputmethod.<leaf>` registers. `TISRegisterInputSource`
    /// answers noErr in every one of those cases, so the source list is the only honest
    /// reading of whether a bundle was taken. [LAW:no-silent-failure] Hence the leaf:
    /// `.dictation` names what this input method does, and it is what keeps the segment
    /// off the end.
    public static let inputMethodBundleIdentifier = bundleIdentifier + ".inputmethod.dictation"

    /// What `TISSelectInputSource` selects the source by: the input mode the bundle
    /// declares, which is the identifier the text input system reports back.
    ///
    /// One mode and not a list, because there is one thing this input method does.
    ///
    /// Distinct from `inputMethodBundleIdentifier` on purpose, though macOS accepts them
    /// equal: a registered bundle yields TWO entries in the source list - the bundle's
    /// own, which is not selectable, and the mode's, which is - and giving both one string
    /// would leave low-input-method-s71.9ug selecting by an identifier that answers twice.
    /// Every Apple input method keeps them apart the same way.
    public static let inputSourceIdentifier = inputMethodBundleIdentifier + ".text"

    /// The name the text input system reaches the input method server on, which its
    /// `Info.plist` publishes as `InputMethodConnectionName` and `IMKServer` answers.
    public static let inputMethodConnectionName = inputMethodBundleIdentifier + "_Connection"

    /// The name the app reaches the input method on to ask it to insert text.
    ///
    /// A second port beside `inputMethodConnectionName` and not that one: the connection
    /// name belongs to the text input system, which opens it, speaks its own protocol over
    /// it and would not carry a message of ours. This one is ours end to end.
    ///
    /// Measured on 2026-09-22, and the reason this is a registered Mach port rather than XPC:
    /// a process macOS launches from a bundle has no launchd job, so it cannot check a Mach
    /// service name in. `NSXPCListener(machServiceName:)` resumes
    /// without raising, logs nothing, and simply never receives, which would have made an
    /// input method that looked installed and answered nothing. [LAW:no-silent-failure]
    public static let inputMethodPortName = inputMethodBundleIdentifier + ".insert"

    /// The name the input method reaches the app on to say the modifier keys moved: the
    /// other direction from `inputMethodPortName`, so the app registers it and the input
    /// method looks it up.
    ///
    /// Under the app's identifier rather than the input method's, because the app is what
    /// answers on it. The input method is sandboxed, so this name is also the one Mach
    /// lookup its entitlements admit beyond the text input system's.
    public static let hotkeyPortName = bundleIdentifier + ".hotkey"

    /// The TCP port the transcription server answers on (epic low-serve-axq).
    ///
    /// Fixed rather than chosen at launch, because its callers are configured by hand: a
    /// Pipecat pipeline's `base_url` is typed once and has no way to ask which port today's
    /// launch drew.
    public static let serverPort: UInt16 = 8610

    /// The name shown in the menu bar, and the name the Input Sources list shows for the
    /// input method - reused deliberately rather than coined a second time, because a person
    /// choosing the source is choosing this app. [LAW:one-source-of-truth]
    ///
    /// macOS reads that name off the input method bundle rather than off anything here, so
    /// the reuse is carried by the bundle's `en.lproj/InfoPlist.strings`, which maps both
    /// `CFBundleName` and `inputSourceIdentifier` to this string. Measured, not assumed:
    /// with no such file both entries come back from `kTISPropertyLocalizedName` as the
    /// raw identifier.
    public static let displayName = "LowTalker"

    /// The menu bar mark in App/LowTalker/Assets.xcassets.
    public static let statusMarkName = "StatusMark"
}
