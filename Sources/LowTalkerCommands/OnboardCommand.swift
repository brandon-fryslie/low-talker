import ArgumentParser
import Choices
import Flavors
import Foundation
import LowTalkerCore
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
            Prints the rows of the delivery and hotkey source this installation's app has \
            chosen, and the rows of every choice for one it has not made yet. Exits 0 when \
            nothing on those rows is left to do and 2 when something is. The microphone, \
            Input Monitoring and Accessibility rows belong to the app and are named, not \
            read, so they count toward neither. A fact that could not be read is a row of \
            its own naming why, and it never counts as met.
            """,
        subcommands: [Readings.self]
    )

    @OptionGroup var installation: FlavorOption

    func run() throws {
        // Read from elsewhere, not as the app: `SMAppService` answers only the bundle that
        // asks, and macOS keys the privacy grants to the app that holds them, so a CLI can
        // read neither. From here launchd's "no job" covers both a helper never registered
        // and one registered and waiting for its click, and the grants only the app can read
        // are named, unread, rather than read as the terminal's.
        //
        // The setup the app chose, read from the app's own defaults domain, so the exit
        // code answers for the setup this installation actually runs. A choice the app has
        // not made yet could go either way, so the rows of every answer to it are read.
        let flavor = installation.flavor
        guard let appDefaults = UserDefaults(suiteName: flavor.bundleIdentifier) else {
            throw ValidationError("cannot read \(flavor.bundleIdentifier)'s defaults, where its app keeps its choices")
        }
        let kept = KeptChoices(appDefaults)
        let readiness = OnboardingProbe.readiness(
            flavor: flavor,
            delivery: kept.delivery,
            source: kept.source,
            reader: .elsewhere, cli: LowTalker.path)
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
