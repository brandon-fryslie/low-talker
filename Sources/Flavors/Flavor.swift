/// Which installation of low-talker this is: the one that runs all day, or the one being
/// worked on. Two copies are meant to be installed and running at the same moment, so
/// every name macOS keys an installation by has to differ between them.
///
/// [LAW:one-type-per-behavior] They are not two programs. They are one program installed
/// twice, and what separates them is configuration - a bundle identifier, a Mach service,
/// a launchd label, a file to read. So this is one type with two instances rather than a
/// `#if DEBUG` seam through the code, and no caller ever branches on which it holds: it
/// asks the value for the name it needs. [LAW:dataflow-not-control-flow]
///
/// **Why these particular names and no others.** Each entry below is a namespace macOS
/// itself enforces uniqueness in, and sharing any one of them is what makes the second
/// copy fail rather than run:
///
/// - the bundle identifier, which LaunchServices treats as the app's identity and TCC
///   keys Microphone, Accessibility and Input Monitoring grants to;
/// - the Mach service, which exactly one process may own;
/// - the launchd label, which Background Task Management files the approval record under;
/// - the config file, so a setting changed for one build does not move the other;
/// - the input method's bundle identifier, input source identifier and connection name,
///   which the text input system keys a text input source by: two copies sharing any one
///   of them is the second failing to register beside the first.
///
/// Nothing else needs to differ by flavor. The model store differs too, but by whether
/// the bundle carries one, not by this type: a release loads the store it carries in place,
/// read-only, and a development build downloads into Application Support.
///
/// [LAW:one-way-deps] This module depends on nothing, which is what lets both the helper
/// - a root daemon that must stay lean - and the app's higher layers read from one source
/// without either depending on the other.
public enum Flavor: String, CaseIterable, Sendable, CustomStringConvertible {
    /// The installed copy: launched at login, left running, holding right Option.
    case release
    /// The copy built from the working tree, run beside the release copy.
    case development

    /// The reverse-DNS identity of the release build, which every other name here is
    /// built from. Named once so a rename reaches all of them together.
    /// [LAW:one-source-of-truth]
    private static let releaseBundleIdentifier = "ai.promptctl.low-talker"
    /// The helper nested under the app it belongs to, the shape Apple's own embedded
    /// helpers take, so the parentage Background Task Management records reads in the name.
    private static let releaseMachServiceName = releaseBundleIdentifier + ".keyboardd"

    /// What the development build suffixes onto each of the release build's names. One
    /// suffix for all of them, so the two installations are told apart the same way
    /// wherever they are told apart.
    private static let developmentSuffix = ".dev"

    /// The word the CLI takes and the plist passes: `release` or `development`, which is
    /// the case name, so the spelling cannot drift from the cases.
    public var description: String { rawValue }

    /// What `CFBundleIdentifier` holds, and what the app reads back to learn which of the
    /// two it is.
    public var bundleIdentifier: String {
        switch self {
        case .release: Self.releaseBundleIdentifier
        case .development: Self.releaseBundleIdentifier + Self.developmentSuffix
        }
    }

    /// The Mach service this flavor's helper listens on and this flavor's clients dial.
    ///
    /// Distinct per flavor, and that is the change that lets both run at once: one name
    /// shared between them would mean one helper held the endpoint and the other silently
    /// never got it.
    public var machServiceName: String {
        switch self {
        case .release: Self.releaseMachServiceName
        case .development: Self.releaseMachServiceName + Self.developmentSuffix
        }
    }

    /// The launchd job that owns this flavor's service.
    ///
    /// **The same string as the service, and that is load-bearing.** A flavor's helper can
    /// be registered two ways - `SMAppService` from inside the app, or a plist in
    /// /Library/LaunchDaemons that `scripts/keyboard-helper` bootstraps - and exactly one
    /// of them may hold the flavor at a time. Giving both paths this one label is what
    /// makes a second claimant fail loudly instead of quietly. Measured on this Mac:
    ///
    /// - two jobs under one label: the second `launchctl bootstrap` exits 5, "Bootstrap
    ///   failed: Input/output error", and no job is added;
    /// - two labels naming one Mach service: the second bootstrap exits 0, the job runs,
    ///   and it is simply never given the endpoint - it has no `endpoints` entry at all.
    ///
    /// The second is what low-keyboard-3ti.13 recorded in the field, a helper sitting
    /// unreachable for twelve minutes while logging that it was listening. One label per
    /// flavor is how that stops being reachable from launchd. [LAW:no-silent-failure]
    ///
    /// It does not cover a helper started by hand from a terminal, which is a claimant no
    /// label governs; that is still 3ti.13's to answer at startup.
    public var launchdLabel: String { machServiceName }

    /// What `CFBundleIdentifier` holds inside this flavor's input method bundle, the one
    /// the app carries and installs into `~/Library/Input Methods`.
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
    /// Grown from `bundleIdentifier` and not from the release seed the way the helper's
    /// names are, which is the one place this type departs from "suffix `.dev` onto the
    /// release name" - deliberately, because the input method is a *bundle nested inside
    /// the app bundle* where the helper is a plain tool, and a nested bundle's identifier
    /// belongs under the identifier of the bundle carrying it. Suffixing the release seed
    /// instead would give the development copy `…inputmethod.dictation.dev` sitting inside
    /// the release app's namespace rather than its own container's.
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
    /// A port name, so it is the same kind of fact as `machServiceName`: exactly one
    /// process may answer on it, and two copies sharing it would leave the second's
    /// server unreachable rather than refused. [LAW:no-silent-failure]
    public var inputMethodConnectionName: String { inputMethodBundleIdentifier + "_Connection" }

    /// The name the app reaches this flavor's input method on to ask it to insert text.
    ///
    /// A second port beside `inputMethodConnectionName` and not that one: the connection
    /// name belongs to the text input system, which opens it, speaks its own protocol over
    /// it and would not carry a message of ours. This one is ours end to end.
    ///
    /// Measured on 2026-09-22, and the reason this is a registered Mach port rather than the XPC
    /// the helper uses: a process macOS launches from a bundle has no launchd job, so it
    /// cannot check a Mach service name in. `NSXPCListener(machServiceName:)` resumes
    /// without raising, logs nothing, and simply never receives, which would have made an
    /// input method that looked installed and answered nothing. [LAW:no-silent-failure]
    public var inputMethodPortName: String { inputMethodBundleIdentifier + ".insert" }

    /// The name shown in the menu bar and in Login Items, where the whole point is that a
    /// person can tell the two apart at a glance.
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

    /// The config file's name inside `~/.config/low-talker`. One directory, two files:
    /// the directory is the project's, and a reader editing one build's settings should
    /// find the other's beside it rather than somewhere else entirely.
    public var configFileName: String {
        switch self {
        case .release: "config.toml"
        case .development: "config.dev.toml"
        }
    }

    /// [LAW:parse-dont-validate] The one place a bundle identifier becomes a flavor. The
    /// app knows which copy it is only by the identity macOS launched it under, and this
    /// is where that string stops being a string.
    ///
    /// Nil rather than a default, because guessing is the one wrong answer: a build whose
    /// identifier matches neither flavor is a misconfigured bundle, and answering
    /// `.release` for it would point a development build's helper, config and hotkey at
    /// the installed copy's. The caller fails loudly instead. [LAW:no-silent-failure]
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

    /// [LAW:parse-dont-validate] The one place the helper's `--flavor` argument, the CLI's
    /// option and the script's verb become a flavor, refusing anything that is not one of
    /// the two words.
    public init?(word: String) {
        guard let flavor = Flavor(rawValue: word) else { return nil }
        self = flavor
    }
}
