import ArgumentParser
import KeyboardLayout
import LowTalkerCore

/// Types text into an app through the keyboard helper, the way dictation types a
/// transcript: the scripting surface for insertion.
///
/// The CLI is signed with the identity the helper admits callers by, so this is inside
/// the same trust boundary as the app, and needs no sudo.
struct TypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into an app through the keyboard helper, as dictation does.",
        discussion: PerformExit.discussion
    )

    @Argument(help: "The text to type: anything the console user's keyboard layout has keys for, dead-key sequences and line breaks included.")
    var text: String

    @OptionGroup var target: TargetOption

    @OptionGroup var installation: FlavorOption

    @MainActor
    func run() async throws {
        // The console user's own layout: this command runs as the user, and the helper is
        // what is root. [LAW:one-way-deps]
        try await Performance.perform([.insertText(text: text, target: .focus)], in: try target.app(), on: try KeyboardLayout.current(), flavor: installation.flavor)
    }
}
