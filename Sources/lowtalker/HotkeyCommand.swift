import ArgumentParser
import Flavors
import Foundation
import LowTalkerCore

/// Watches this installation's hotkey from the command line, so a hold, a tap, and the
/// key no longer reaching the frontmost app can each be seen before the app is wired.
///
/// The CLI is not the app: macOS charges a terminal command's event tap to the
/// terminal, so it needs Input Monitoring and Accessibility for the terminal.
struct HotkeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hotkey",
        abstract: "Print each press of this installation's hotkey, hold or tap, until interrupted."
    )

    @OptionGroup var installation: FlavorOption

    // Whole milliseconds, for the same reason as `mic watch --interval`.
    @Option(help: "Milliseconds a press must stay under to be a tap.")
    var tapThreshold: Int = Int(Hotkey.defaultTapThreshold / .milliseconds(1))

    func validate() throws {
        guard tapThreshold > 0 else { throw ValidationError("--tap-threshold must be positive.") }
    }

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let chord = Hotkey.defaultChord(for: installation.flavor)
        let hotkey = Hotkey(chords: [chord], tapThreshold: .milliseconds(tapThreshold))
        let (transitions, continuation) = AsyncStream.makeStream(of: HotkeyDetector.Transition.self)
        try hotkey.start { continuation.yield($0) } onLapse: { print("\($0)") }
        // Named from the chord rather than spelled here, because the two installations
        // do not watch the same keys. [LAW:one-source-of-truth]
        print("watching \(chord.spelled)")
        for await transition in transitions {
            switch transition {
            case .began: print("began")
            case .ended(_, let ending): print("ended (\(ending))")
            }
        }
    }
}
