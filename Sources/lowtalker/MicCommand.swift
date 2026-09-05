import ArgumentParser
import Foundation
import LowTalkerCore

/// Microphone authorization from the command line, so the request, the denied state,
/// and a change made in System Settings can each be seen before the app shows them.
///
/// The CLI is not the app: macOS charges a terminal command's microphone use to the
/// terminal, so the answers here are the terminal's. The mechanism is the same.
///
/// Exit status is the answer: 0 when granted, 1 when withheld, so
/// `lowtalker mic && lowtalker record out.wav` records only with permission.
struct MicCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mic",
        abstract: "Show, request, or follow microphone authorization.",
        subcommands: [Status.self, Request.self, Watch.self],
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

        @Option(help: "Seconds between reads of the authorization.")
        var interval: Double = 1

        func validate() throws {
            guard interval > 0 else { throw ValidationError("--interval must be positive.") }
        }

        func run() async throws {
            // A pipe would otherwise hold each line until the buffer fills, and a
            // watcher's whole point is seeing the change when it happens.
            setvbuf(stdout, nil, _IOLBF, 0)
            for await authorization in MicrophonePermission().changes(every: .seconds(interval)) {
                print(authorization)
            }
        }
    }
}

/// Prints the authorization and makes it the exit status.
private func report(_ authorization: MicrophoneAuthorization) throws {
    print(authorization)
    guard case .granted = authorization else { throw ExitCode.failure }
}
