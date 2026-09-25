import ArgumentParser
import Grants

/// The app's privacy grants, read in a fresh process: macOS credits this process's reading
/// to the app that started it. The app runs this for every reading, because its own
/// process keeps a stale answer. Run from a terminal, it reads the terminal's grants.
struct GrantsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grants",
        abstract: "Print the privacy grants macOS credits to whoever started this process.",
        shouldDisplay: false)

    func run() {
        print(PrivacyReading.here().line)
    }
}
