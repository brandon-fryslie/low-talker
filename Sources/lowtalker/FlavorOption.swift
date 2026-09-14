import ArgumentParser
import Flavors
import Foundation

/// A flavor as a command-line value, parsed through the one parse there is.
/// [LAW:single-enforcer] The CLI does not learn a second spelling of these words.
extension Flavor: ExpressibleByArgument {
    public init?(argument: String) { self.init(word: argument) }
    public static var allValueStrings: [String] { allCases.map(\.description) }
}

/// Which installation a command acts on.
///
/// [LAW:one-source-of-truth] Declared once and shared by every command that reaches a
/// helper, so the flag is spelled, defaulted and described the same way everywhere rather
/// than four times with three agreements.
///
/// **The default is the development copy, because this binary is part of it.**
/// `.build/debug/lowtalker` is built from the working tree beside the development app and
/// signed with the same identity; having it reach into the installed copy's helper by
/// default would be the surprising direction, and it is the copy a person is least
/// willing to have surprised. `--flavor release` is how the installed one is addressed on
/// purpose.
struct FlavorOption: ParsableArguments {
    /// What was actually typed, which is not the same question as which installation to
    /// act on. A command that reads *this installation's* file wants the default below; a
    /// command handed a `--path` cannot infer a flavor at all and has to know whether one
    /// was stated. Keeping the stated value and deriving the other is the only order that
    /// answers both - a default stored here would erase the difference before anyone could
    /// ask. [LAW:one-source-of-truth]
    @Option(
        name: .customLong("flavor"),
        help: "Which installation to act on: release (the copy that runs at login) or development (the copy built from this tree). Defaults to \(FlavorOption.defaultFlavor).")
    var stated: Flavor?

    /// The installation a command acts on when none is stated, for the reason above. Named
    /// once, because the help text, this option and `ConfigSource` all say it.
    /// [LAW:one-source-of-truth]
    static let defaultFlavor: Flavor = .development

    /// The installation this command acts on.
    var flavor: Flavor { stated ?? Self.defaultFlavor }

    init() {}
}

/// Which config file to read, and as which installation.
///
/// [LAW:types-are-the-program] `Config.load(_:for:)` takes a path and a flavor, and its
/// own documentation names the hazard in holding them apart: "read a file as the wrong
/// installation and every key it leaves out falls back to the other copy's defaults - for
/// the hotkey, that is one copy coming up on the chord the other listens for." With
/// `--flavor` defaulted, `config check --path ~/.config/low-talker/config.toml` - the
/// release file, checked before installing, which is what `--path` is *for* - filled its
/// gaps from development defaults and reported the development chord as the one the
/// release app would use. Quietly, and in the one command whose entire job is to say what
/// will run.
///
/// The two are one decision, so they are one value. A path with no flavor stated is not a
/// thing this type can hold, because the only way to build one is the parse below.
struct ConfigSource {
    /// The file to read, or nil for this installation's own.
    let path: URL?
    /// The installation the file is read as.
    let flavor: Flavor

    /// [LAW:parse-dont-validate] The one place two optional flags become the decision they
    /// describe. [LAW:no-silent-failure] A `--path` with no `--flavor` stops here, because
    /// the alternative is a report that is confidently about the wrong installation.
    init(path: URL?, stated: Flavor?) throws {
        guard path == nil || stated != nil else {
            throw ValidationError(
                "--path needs --flavor: which installation a file is read as decides every "
                + "default it does not set, and the hotkey is one of them. Say which copy "
                + "this file belongs to - --flavor release or --flavor development.")
        }
        self.path = path
        self.flavor = stated ?? FlavorOption.defaultFlavor
    }
}
