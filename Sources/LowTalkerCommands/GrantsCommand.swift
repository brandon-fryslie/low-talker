import ArgumentParser
import Grants

/// The app's privacy grants, read - and asked for - in a fresh process: macOS credits this
/// process to the app that started it. The app runs this for every reading and request,
/// because its own process keeps stale answers. Run from a terminal, it is the terminal's.
struct GrantsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grants",
        abstract: "Print the privacy grants macOS credits to whoever started this process.",
        shouldDisplay: false)

    @Option(help: "Ask macOS for this grant first: microphone or input-monitoring.")
    var ask: PrivacyGrant?

    func run() async {
        await ask?.ask()
        print(PrivacyReading.here().line)
    }
}

extension PrivacyGrant: ExpressibleByArgument {}
