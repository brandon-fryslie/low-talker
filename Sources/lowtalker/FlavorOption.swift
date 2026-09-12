import ArgumentParser
import Flavors

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
    @Option(
        name: .customLong("flavor"),
        help: "Which installation to act on: release (the copy that runs at login) or development (the copy built from this tree).")
    var flavor: Flavor = .development

    init() {}
}
