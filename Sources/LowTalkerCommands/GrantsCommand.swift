import ArgumentParser
import Grants

/// The app's microphone and Input Monitoring, read in a fresh process: macOS credits this
/// process to the app that started it. The app runs this for every reading, because its
/// own process keeps stale answers. Run from a terminal, it is the terminal's.
struct GrantsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grants",
        abstract: "Print the privacy grants macOS credits to whoever started this process.",
        shouldDisplay: false)

    func run() {
        print(PrivacyReading.lineReadHere())
    }
}
