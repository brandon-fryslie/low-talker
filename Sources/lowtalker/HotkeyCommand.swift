import ArgumentParser
import Foundation
import LowTalkerCore

/// Watches Right Option from the command line, so a hold, a tap, and the key no
/// longer reaching the frontmost app can each be seen before the app is wired.
///
/// The CLI is not the app: macOS charges a terminal command's event tap to the
/// terminal, so it needs Input Monitoring and Accessibility for the terminal.
struct HotkeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hotkey",
        abstract: "Print each press of Right Option, hold or tap, until interrupted."
    )

    // Whole milliseconds, for the same reason as `mic watch --interval`.
    @Option(help: "Milliseconds a press must stay under to be a tap.")
    var tapThreshold: Int = Int(Hotkey.defaultTapThreshold / .milliseconds(1))

    func validate() throws {
        guard tapThreshold > 0 else { throw ValidationError("--tap-threshold must be positive.") }
    }

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let hotkey = Hotkey(chords: [KeyChord(modifiers: .rightOption)], tapThreshold: .milliseconds(tapThreshold))
        let (transitions, continuation) = AsyncStream.makeStream(of: HotkeyDetector.Transition.self)
        try hotkey.start { continuation.yield($0) }
        print("watching Right Option")
        for await transition in transitions {
            switch transition {
            case .began: print("began")
            case .ended(_, let press): print("ended (\(press.rawValue)), lapses \(hotkey.lapses)")
            }
        }
    }
}
