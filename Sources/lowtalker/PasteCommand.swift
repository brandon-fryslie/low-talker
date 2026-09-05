import ArgumentParser
import Foundation
import LowTalkerCore

/// Pastes text into whatever app is frontmost when the delay runs out, so the
/// insertion path can be watched landing in TextEdit or Terminal before the app is
/// wired, and the pasteboard checked afterward.
///
/// Posting a key needs Accessibility for the posting process, which for this command
/// is the terminal.
struct PasteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Paste text into the frontmost app and put the pasteboard back."
    )

    @Argument(help: "The text to insert.")
    var text: String

    @Option(help: "Seconds to wait first, to bring the receiving app to the front.")
    var delay: Double = 0

    // Whole milliseconds, for the same reason as `hotkey --tap-threshold`.
    @Option(help: "Milliseconds to wait for the app to take the text before giving the pasteboard back regardless.")
    var landingTimeout: Int = Int(PasteInserter.defaultLandingTimeout / .milliseconds(1))

    func validate() throws {
        guard delay >= 0 else { throw ValidationError("--delay cannot be negative.") }
        guard landingTimeout > 0 else { throw ValidationError("--landing-timeout must be positive.") }
    }

    @MainActor
    func run() async throws {
        try await Task.sleep(for: .seconds(delay))
        let inserter = PasteInserter(landingTimeout: .milliseconds(landingTimeout))
        let outcome = try await inserter.insert(text)
        print("\(outcome.landed ? "landed" : "not taken"), pasteboard \(outcome.restored ? "restored" : "left to whoever took it")")
    }
}
