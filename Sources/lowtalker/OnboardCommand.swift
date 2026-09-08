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
    /// Every reading the keyboard helper's row can take, one to a line.
    ///
    /// README.md lists these for a reader following the runbook by hand. It cannot read a
    /// Swift enum, so it keeps a copy, and `make check-docs` reads this to prove the copy
    /// still agrees - the same proof the driver extension's verdict vocabulary already
    /// gets, and the absence of which let a case added to `HelperStanding` leave README
    /// stale with every check green. [LAW:one-source-of-truth]
    ///
    /// [CLI] One reading per line on stdout, because a reading is a phrase with spaces in
    /// it and a line is the one delimiter that cannot collide with the content.
    struct Readings: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "readings",
            abstract: "Print every reading the keyboard helper's row can take, one per line."
        )

        func run() {
            print(Requirement.helperReadings.joined(separator: "\n"))
        }
    }
}
