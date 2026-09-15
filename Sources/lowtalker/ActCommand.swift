import ArgumentParser
import Foundation
import KeyboardLayout
import LowTalkerCore

/// Performs a list of actions the way the app does: text typed and chords pressed on the
/// virtual keyboard, clicks and scrolls made with the virtual mouse, both through the
/// installed helper, into the app the context names.
///
/// The actions come in on stdin as the JSON `lowtalker route` prints, so the two commands
/// pipe: `route` decides and `act` performs, and the decision can be read in between.
/// The context is given twice - once to route, once here - because the router and the
/// executor each read it and neither hands it on. [LAW:one-source-of-truth]
struct ActCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "act",
        abstract: "Perform the actions on stdin through the keyboard helper, as the app does.",
        discussion: PerformExit.discussion
    )

    // [LAW:parse-dont-validate] Decoded once, here at the edge, and the executor never
    // sees a string.
    @Option(
        help: ArgumentHelp(
            "The Context the actions were routed in, as JSON. Its frontmost app is raised before anything is typed.",
            discussion: #"e.g. '{"chord":{"modifiers":["rightOption"]},"press":"hold","frontmostApp":"com.apple.TextEdit","focusedElementRole":"AXTextArea"}'"#
        ),
        transform: { try JSONDecoder().decode(Context.self, from: Data($0.utf8)) }
    )
    var context: Context

    @OptionGroup var installation: FlavorOption

    @MainActor
    func run() async throws {
        let actions = try JSONDecoder().decode([Action].self, from: FileHandle.standardInput.readDataToEndOfFile())
        // The console user's own layout: this command runs as the user, and the helper is
        // what is root. [LAW:one-way-deps]
        try await Performance.perform(actions, in: context.frontmostApp, on: try KeyboardLayout.current(), flavor: installation.flavor)
    }
}
