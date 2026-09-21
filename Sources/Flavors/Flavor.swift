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
    /// The input method nested under the app that carries it, the way the helper is, and
    /// under the `.inputmethod` segment Apple's own text input sources use
    /// (`com.apple.inputmethod.Kotoeri`).
    private static let releaseInputMethodBundleIdentifier = releaseBundleIdentifier + ".inputmethod"

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
    /// The seed the other two input method names are grown from, so a flavor branches
    /// once here and the rest follow by construction rather than by three more switches
    /// somebody has to keep in step. [LAW:dataflow-not-control-flow]
    public var inputMethodBundleIdentifier: String {
        switch self {
        case .release: Self.releaseInputMethodBundleIdentifier
        case .development: Self.releaseInputMethodBundleIdentifier + Self.developmentSuffix
        }
    }

    /// What `TISSelectInputSource` selects this flavor's source by, and what the Input
    /// menu files it under: the input mode the bundle declares, which is the identifier
    /// the text input system reports back.
    ///
    /// One mode and not a list, because there is one thing this input method does. It is
    /// namespaced under the bundle rather than spelled apart, so a source can never be
    /// filed under an installation that does not own the bundle serving it.
    public var inputSourceIdentifier: String { inputMethodBundleIdentifier + ".dictation" }

    /// The name the text input system reaches this flavor's input method server on, which
    /// its `Info.plist` publishes as `InputMethodConnectionName` and `IMKServer` answers.
    ///
    /// A port name, so it is the same kind of fact as `machServiceName`: exactly one
    /// process may answer on it, and two copies sharing it would leave the second's
    /// server unreachable rather than refused. [LAW:no-silent-failure]
    public var inputMethodConnectionName: String { inputMethodBundleIdentifier + "_Connection" }

    /// The name shown in the menu bar and in Login Items, where the whole point is that a
    /// person can tell the two apart at a glance.
    ///
    /// It is also the name the Input Sources list and the Input menu show for this
    /// flavor's input method, deliberately reused rather than copied into a name of its
    /// own: a person choosing the source is choosing this app, and two spellings of that
    /// one fact could disagree about which copy they had picked.
    /// [LAW:one-source-of-truth]
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

    /// [LAW:parse-dont-validate] The one place the helper's `--flavor` argument, the CLI's
    /// option and the script's verb become a flavor, refusing anything that is not one of
    /// the two words.
    public init?(word: String) {
        guard let flavor = Flavor(rawValue: word) else { return nil }
        self = flavor
    }
}
