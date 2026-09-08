import ArgumentParser
import Onboarding

/// Everything that must hold before low-talker can type, read off this Mac, with the
/// step for whatever is missing.
///
/// The menu-bar app shows this same list in these same words - the app is the surface
/// the onboarding ticket is about, and this is how an agent reads it back without a
/// screen. Neither surface assembles the list; `OnboardingProbe.readiness` does, once.
struct OnboardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "onboard",
        abstract: "Print everything that must hold before low-talker can type, and the step for whatever is missing.",
        discussion: """
            Exits 0 when nothing is left to do and 2 when something is. A fact that could \
            not be read is a row of its own naming why, and it never counts as met.
            """,
        subcommands: [Readings.self]
    )

    func run() throws {
        // Nil, not false: `SMAppService` answers only the bundle that asks, so a CLI has
        // no registration of its own to put the question to. From here launchd's "no job"
        // covers both a helper never registered and one registered and waiting for its
        // click, and saying so beats answering no on the app's behalf.
        let readiness = OnboardingProbe.readiness(approvalPending: nil)
        print(readiness)
        // The code is a value computed the one way every time, rather than an exit taken
        // on some runs and not others. [LAW:dataflow-not-control-flow]
        throw ExitCode(readiness.ready ? 0 : 2)
    }
}

extension OnboardCommand {
    /// Every reading every onboarding row can take, one to a line, each named with the
    /// row it belongs to.
    ///
    /// README.md lists these for a reader following the runbook by hand. It cannot read a
    /// Swift enum, so it keeps a copy per row, and `make check-docs` reads this to hold
    /// each copy to it - the same proof the driver extension's verdict vocabulary already
    /// gets, and the absence of which let a case added to `HelperStanding` leave README
    /// stale with every check green. [LAW:one-source-of-truth]
    ///
    /// The row is on every line because this used to print the helper's readings alone
    /// and say nothing about it. What that cost was not a wrong answer but an invisible
    /// gap: the assistant's two readings were hand-copied into README with no check, and
    /// no reader of this command's output could have told. Naming the row makes the
    /// command's answer complete and lets each caller take the rows it came for.
    /// [LAW:composability]
    ///
    /// [CLI] One reading per line on stdout, as row and reading separated by a tab. Both
    /// halves are phrases with spaces in them, so the tab is the one delimiter that
    /// cannot collide with the content, and the line is the one that cannot collide with
    /// a pair.
    struct Readings: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "readings",
            abstract: "Print every reading each onboarding row can take, as row and reading separated by a tab."
        )

        func run() {
            print(Requirement.readings.map { "\($0.row.rawValue)\t\($0.reading)" }.joined(separator: "\n"))
        }
    }
}
