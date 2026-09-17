import ArgumentParser
import Foundation
import LowTalkerCore
import Typing

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
        abstract: "Show, request, or follow microphone authorization, or read the indicator across a hold, a resting microphone across a change of shape or of slice, and a press across a readying.",
        subcommands: [Status.self, Request.self, Watch.self, Indicator.self, Shape.self, Slice.self, Change.self],
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

    /// The other half of what the resting microphone promises, and the half no suite can
    /// reach: a microphone readied and then left alone still hears the device under it change
    /// shape. Moves the default input to another rate it offers while nothing has it open,
    /// and reports whether the readied microphone was told - then puts the rate back.
    ///
    /// This Mac is changed for the length of the run, which is why it is a command someone
    /// asks for rather than anything the app does: the reading names the rate it left the
    /// device at, so a run that could not put it back says so instead of leaving it to be
    /// noticed later. Ctrl-C is answered rather than obeyed for the same reason - obeyed, it
    /// ended the process with the device moved and nothing said - so an interrupted run puts
    /// the device back, prints where it left it, and exits as interrupted.
    struct Shape: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change the input device's shape while a microphone rests, and report whether it was heard."
        )

        /// Whole milliseconds, like `indicator`'s hold. The most this Mac gets to publish each
        /// change: the reading goes on the moment a report lands, so this is spent in full only
        /// on a Mac that never reports.
        @Option(help: "Milliseconds to wait for the report, and again for the device to change back.")
        var wait: Int = 1000

        func validate() throws {
            guard wait > 0 else { throw ValidationError("--wait must be positive.") }
        }

        @MainActor
        func run() async throws {
            let interrupt = Interrupt.watched()
            let across = try await ShapeChangeAtRest.measure(waiting: .milliseconds(wait), stoppingFor: { interrupt.isRaised })
            print(across)
            guard across.kept else { throw ExitCode.failure }
            // The shell's own status for a command Ctrl-C ended, so a script reads an interrupted
            // reading the way it reads any other interrupted command and never as a promise kept.
            guard across.report != .interrupted else { throw ExitCode(130) }
        }
    }

    /// A press on a microphone readied before its device's IO buffer grew. Grows this
    /// process's IO buffer on the default input while nothing has it open, holds one press,
    /// and reports whether that press heard anything. The size is per process, so nothing on
    /// the Mac outlives the run.
    struct Slice: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Grow the input device's IO buffer while a microphone rests, and report whether the next press heard."
        )

        /// Whole milliseconds, like `indicator`'s hold.
        @Option(help: "Milliseconds to hold the press.")
        var hold: Int = 500

        func validate() throws {
            guard hold > 0 else { throw ValidationError("--hold must be positive.") }
        }

        @MainActor
        func run() async throws {
            let across = try await SliceGrownAtRest.measure(holding: .milliseconds(hold))
            print(across)
            guard across.kept else { throw ExitCode.failure }
        }
    }
}

extension MicCommand {
    /// Whether a device change leaves the key-down handler free and a press on it whole.
    /// Moves the default input's rate and back, like `shape`, and puts it back on every way
    /// out; exit status is the verdict.
    struct Change: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change the input device's shape twice, and report how long the main actor was held and whether a press on the change came back whole."
        )

        /// Whole milliseconds, like `shape`'s wait. Spent on each change.
        @Option(help: "Milliseconds to watch each change land.")
        var wait: Int = 1000

        @Option(help: "Milliseconds to hold the press once it has begun.")
        var hold: Int = 500

        func validate() throws {
            guard wait > 0 else { throw ValidationError("--wait must be positive.") }
            guard hold > 0 else { throw ValidationError("--hold must be positive.") }
        }

        @MainActor
        func run() async throws {
            let grant = try await MicrophonePermission().request().grant()
            let across = try await ReadyingAcrossChange.measure(waiting: .milliseconds(wait), holding: .milliseconds(hold), with: grant)
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
