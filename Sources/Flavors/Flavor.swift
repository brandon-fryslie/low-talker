/// Which installation of low-talker this is: the one that runs all day, or the one being
/// worked on. Two copies are meant to be installed and running at the same moment, so
/// every name macOS keys an installation by has to differ between them.
///
/// [LAW:one-type-per-behavior] They are not two programs. They are one program installed
/// twice, and what separates them is configuration - a bundle identifier, a port name, a
/// file to read. So this is one type with two instances rather than a `#if DEBUG` seam
/// through the code, and no caller ever branches on which it holds: it asks the value for
/// the name it needs. [LAW:dataflow-not-control-flow]
///
/// **Why these particular names and no others.** Each entry below is a namespace macOS
/// itself enforces uniqueness in, and sharing any one of them is what makes the second
/// copy fail rather than run:
///
/// - the bundle identifier, which LaunchServices treats as the app's identity and TCC
///   keys the Microphone grant to;
/// - the ports its processes answer on, Mach and TCP, which exactly one process may own;
/// - the input method's bundle identifier, input source identifier and connection name,
///   which the text input system keys a text input source by: two copies sharing any one
///   of them is the second failing to register beside the first.
///
/// Nothing else differs by flavor. Both bundles are built by one recipe and carry their
/// model the same way, so the development copy runs the path the release ships.
///
/// [LAW:one-way-deps] This module depends on nothing, which is what lets both the input
/// method - a sandboxed process that must stay lean - and the app's higher layers read from
/// one source without either depending on the other.
public enum Flavor: String, CaseIterable, Sendable, CustomStringConvertible {
    /// The installed copy: launched at login, left running, holding right Option.
    case release
    /// The copy built from the working tree, run beside the release copy.
    case development

    /// The reverse-DNS identity of the release build, which every other name here is
    /// built from. Named once so a rename reaches all of them together.
    /// [LAW:one-source-of-truth]
    private static let releaseBundleIdentifier = "ai.promptctl.low-talker"

    /// What the development build suffixes onto the release build's identifier, which every
    /// other name is grown from.
    private static let developmentSuffix = ".dev"

    /// The word the CLI takes: `release` or `development`, which is the case name, so the
    /// spelling cannot drift from the cases.
    public var description: String { rawValue }

    /// What `CFBundleIdentifier` holds, and what the app reads back to learn which of the
    /// two it is.
    public var bundleIdentifier: String {
        switch self {
        case .release: Self.releaseBundleIdentifier
        case .development: Self.releaseBundleIdentifier + Self.developmentSuffix
        }
    }

    /// What `CFBundleIdentifier` holds inside this flavor's input method bundle, the one
    /// its installer package puts in `/Library/Input Methods` beside the app.
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
    ///
    /// Grown from `bundleIdentifier` rather than by suffixing `.dev` onto a release name,
    /// because the input method is a *bundle nested inside the app bundle*, and a nested
    /// bundle's identifier belongs under the identifier of the bundle carrying it.
    /// Suffixing instead would give the development copy `…inputmethod.dictation.dev`
    /// sitting inside the release app's namespace rather than its own container's.
    ///
    /// Doing it this way also means no flavor branches here at all: `bundleIdentifier` is
    /// the one switch, and all three input method names fall out of it.
    /// [LAW:dataflow-not-control-flow]
    public var inputMethodBundleIdentifier: String { bundleIdentifier + ".inputmethod.dictation" }

    /// What `TISSelectInputSource` selects this flavor's source by: the input mode the
    /// bundle declares, which is the identifier the text input system reports back.
    ///
    /// One mode and not a list, because there is one thing this input method does. It is
    /// namespaced under the bundle rather than spelled apart, so a source can never be
    /// filed under an installation that does not own the bundle serving it.
    ///
    /// Distinct from `inputMethodBundleIdentifier` on purpose, though macOS accepts them
    /// equal: a registered bundle yields TWO entries in the source list - the bundle's
    /// own, which is not selectable, and the mode's, which is - and giving both one string
    /// would leave low-input-method-s71.9ug selecting by an identifier that answers twice.
    /// Every Apple input method keeps them apart the same way.
    public var inputSourceIdentifier: String { inputMethodBundleIdentifier + ".text" }

    /// The name the text input system reaches this flavor's input method server on, which
    /// its `Info.plist` publishes as `InputMethodConnectionName` and `IMKServer` answers.
    ///
    /// A port name: exactly one process may answer on it, and two copies sharing it would
    /// leave the second's server unreachable rather than refused. [LAW:no-silent-failure]
    public var inputMethodConnectionName: String { inputMethodBundleIdentifier + "_Connection" }

    /// The name the app reaches this flavor's input method on to ask it to insert text.
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
    public var inputMethodPortName: String { inputMethodBundleIdentifier + ".insert" }

    /// The name the input method reaches this flavor's app on to say the modifier keys
    /// moved: the other direction from `inputMethodPortName`, so the app registers it and
    /// the input method looks it up.
    ///
    /// Under the app's identifier rather than the input method's, because the app is what
    /// answers on it. The input method is sandboxed, so this name is also the one Mach
    /// lookup its entitlements admit beyond the text input system's.
    public var hotkeyPortName: String { bundleIdentifier + ".hotkey" }

    /// The TCP port this flavor's transcription server answers on (epic low-serve-axq).
    ///
    /// Fixed rather than chosen at launch, because its callers are configured by hand: a
    /// Pipecat pipeline's `base_url` is typed once and has no way to ask which port today's
    /// launch drew. So it is a name in the same sense as the ones above, one process at a
    /// time may hold it, and each flavor needs its own for both to serve at once.
    public var serverPort: UInt16 {
        switch self {
        case .release: 8610
        case .development: 8611
        }
    }

    /// The name shown in the menu bar, where the whole point is that a person can tell the
    /// two apart at a glance.
    ///
    /// It is the name the Input Sources list shows for this flavor's input method too -
    /// reused deliberately rather than coined a second time, because a person choosing the
    /// source is choosing this app, and two spellings of that one fact could disagree
    /// about which copy they had picked. [LAW:one-source-of-truth]
    ///
    /// macOS reads that name off the input method bundle rather than off anything here, so
    /// the reuse is carried by the bundle's `en.lproj/InfoPlist.strings`, which maps both
    /// `CFBundleName` and `inputSourceIdentifier` to this string. Measured, not assumed:
    /// with no such file both entries come back from `kTISPropertyLocalizedName` as the
    /// raw identifier, which is the same for nothing a person would recognise.
    public var displayName: String {
        switch self {
        case .release: "LowTalker"
        case .development: "LowTalker Dev"
        }
    }

    /// The app icon set in App/LowTalker/Assets.xcassets this installation's bundle
    /// carries, so the two copies side by side are told apart before their names are read.
    public var appIconName: String {
        switch self {
        case .release: "AppIcon"
        case .development: "AppIconDev"
        }
    }

    /// The menu bar mark in the same catalog. Dev's carries a badge, because both copies'
    /// status items sit in one menu bar.
    public var statusMarkName: String {
        switch self {
        case .release: "StatusMark"
        case .development: "StatusMarkDev"
        }
    }

    /// [LAW:parse-dont-validate] The one place a bundle identifier becomes a flavor. The
    /// app knows which copy it is only by the identity macOS launched it under, and this
    /// is where that string stops being a string.
    ///
    /// Nil rather than a default, because guessing is the one wrong answer: a build whose
    /// identifier matches neither flavor is a misconfigured bundle, and answering
    /// `.release` for it would point a development build's input method, config and hotkey
    /// at the installed copy's. The caller fails loudly instead. [LAW:no-silent-failure]
    public init?(bundleIdentifier: String) {
        guard let flavor = Self.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return nil }
        self = flavor
    }

    /// [LAW:parse-dont-validate] The one place the input method process learns which
    /// installation it belongs to.
    ///
    /// It cannot use `init?(bundleIdentifier:)`: macOS launches an input method as its own
    /// process out of its own bundle, so `Bundle.main.bundleIdentifier` there is the name
    /// above, which that initialiser refuses by design. The fact still travels with the
    /// bundle, though - the identifier macOS launched it under already says which flavor
    /// it is - so this reads that rather than a second per-flavor string written beside it
    /// [LAW:one-source-of-truth], and rather than the app bundle's identifier reached by
    /// walking out of the enclosing directories, which would make the answer depend on
    /// where the bundle happens to sit and low-input-method-s71.ssn is free to move it.
    ///
    /// Nil rather than a default, for the reason `init?(bundleIdentifier:)` gives.
    public init?(inputMethodBundleIdentifier: String) {
        guard let flavor = Self.allCases.first(where: { $0.inputMethodBundleIdentifier == inputMethodBundleIdentifier })
        else { return nil }
        self = flavor
    }

    /// [LAW:parse-dont-validate] The one place a `--flavor` argument becomes a flavor,
    /// refusing anything that is not one of the two words.
    public init?(word: String) {
        guard let flavor = Flavor(rawValue: word) else { return nil }
        self = flavor
    }
}
