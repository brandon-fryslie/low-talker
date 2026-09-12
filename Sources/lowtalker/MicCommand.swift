import ArgumentParser
import Foundation
import LowTalkerCore

/// The microphone from the command line: what macOS will let this process do with it, and
/// what macOS shows the user while something is doing it. The request, the denied state, a
/// change made in System Settings and the menu-bar indicator can each be seen here before
/// the app shows them.
///
/// The CLI is not the app: macOS charges a terminal command's microphone use to the
/// terminal, so the answers here are the terminal's. The mechanism is the same.
///
/// Exit status is the answer throughout: 0 when access is granted, so
/// `lowtalker mic && lowtalker record out.wav` records only with permission, and 0 from
/// `indicator` when the microphone did what it promises.
struct MicCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mic",
        abstract: "Show, request, or follow microphone authorization, or read the indicator across a hold.",
        subcommands: [Status.self, Request.self, Watch.self, Indicator.self],
        defaultSubcommand: Status.self
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the current authorization without prompting.")

        func run() throws {
            try report(MicrophonePermission().current)
        }
    }

    struct Request: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Prompt if never asked, then print the answer.")

        func run() async throws {
            try report(await MicrophonePermission().request())
        }
    }

    struct Watch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the authorization and every change to it until interrupted.")

        // Whole milliseconds: an Int parses or fails at the command line, and
        // `.milliseconds(Int)` cannot overflow, so `interval > 0` here is exactly the
        // `> .zero` the library requires and nothing between the two can trap.
        @Option(help: "Milliseconds between reads of the authorization.")
        var interval: Int = 1000

        func validate() throws {
            guard interval > 0 else { throw ValidationError("--interval must be positive.") }
        }

        func run() async throws {
            // A pipe would otherwise hold each line until the buffer fills, and a
            // watcher's whole point is seeing the change when it happens.
            setvbuf(stdout, nil, _IOLBF, 0)
            for await authorization in MicrophonePermission().changes(every: .milliseconds(interval)) {
                print(authorization)
            }
        }
    }

    /// The promise about the menu-bar indicator, read off this Mac instead of asserted: it
    /// holds the microphone for one hold and reports what macOS was showing before, during
    /// and after. Exit status is the verdict, so a person re-checks the promise in one step
    /// rather than rebuilding the instrument.
    struct Indicator: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Hold the microphone and report what the indicator showed before, during, and after."
        )

        /// Whole milliseconds, like `watch`'s interval. Long enough by default for the
        /// reading to be taken at the far end of a real hold; raise it to watch the menu bar
        /// by eye while the microphone is held, which is the only check that does not go
        /// through this property at all.
        @Option(help: "Milliseconds to hold the microphone.")
        var hold: Int = 1000

        func validate() throws {
            guard hold > 0 else { throw ValidationError("--hold must be positive.") }
        }

        @MainActor
        func run() async throws {
            // Prompts on a Mac that has never been asked; the grant is what a hold requires.
            let grant = try await MicrophonePermission().request().grant()
            let across = try await IndicatorAcrossHold.measure(holding: .milliseconds(hold), with: grant)
            print(across)
            guard across.kept else { throw ExitCode.failure }
        }
    }
}

/// Prints the authorization and makes it the exit status.
private func report(_ authorization: MicrophoneAuthorization) throws {
    print(authorization)
    guard case .granted = authorization else { throw ExitCode.failure }
}
