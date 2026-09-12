import ArgumentParser
import Flavors
import Foundation
import KeyboardLayout
import KeyboardService
import LowTalkerCore
import Typing

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
        abstract: "Perform the actions on stdin through the keyboard helper, as the app does."
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
        let layout = try KeyboardLayout.current()
        // Watched before a single report goes out, so there is no window where an
        // interrupt can end the process with a key already down.
        let interrupt = Interrupt.watched()
        // One connection for every action, held open across them: the helper answers a
        // lazy connection's first call after launchd has started the job, and that is a
        // cost to pay once and not per action.
        let helper = HelperConnection(flavor: installation.flavor)
        let executor = Executor.guarding(keyboard: helper.keyboard, mouse: helper.mouse, interrupt: interrupt, hotkeys: [Hotkey.defaultChord(for: installation.flavor)])
        // The app types into whatever was in front when the hotkey went down. Here the
        // shell was, so the context's app is brought forward first, and a run whose app
        // will not come is refused before a key goes down.
        try await TargetApp(bundleID: context.frontmostApp, interrupt: interrupt).raise(within: .seconds(5))
        // There was no key-up: the actions were handed over, and the moment they were
        // stands in for it, so the number printed is the executor's own time.
        for performed in try await executor.perform(actions, in: context, on: layout, since: ContinuousClock.now) {
            print(performed)
        }
    }
}
