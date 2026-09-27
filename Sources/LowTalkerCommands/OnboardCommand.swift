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
            Exits 0 when nothing on the rows it reads is left to do and 2 when something \
            is. The microphone row belongs to the app and is named, not read, so it counts \
            toward neither.
            """,
        subcommands: [Readings.self]
    )

    @OptionGroup var installation: FlavorOption

    func run() throws {
        // Read from elsewhere, not as the app: macOS keys the privacy grants to the app that
        // holds them, so the grants only the app can read are named, unread, rather than read
        // as the terminal's.
        let readiness = OnboardingProbe.readiness(flavor: installation.flavor, reader: .elsewhere)
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
    /// each copy to it. [LAW:one-source-of-truth]
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
