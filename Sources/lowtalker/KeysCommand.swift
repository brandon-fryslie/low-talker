import ArgumentParser
import KeyboardLayout
import LowTalkerCore
import Typing

/// Presses chords in an app through the keyboard helper, the way a SendKeys action does.
struct KeysCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Press chords in an app through the keyboard helper, as a SendKeys action does.",
        discussion: """
            A chord is modifier names and one key joined by +, e.g. leftCommand+s or leftShift+leftCommand+left. \
            A key is a name (\(KeyChord.namedKeys.keys.sorted().joined(separator: ", "))), the character the \
            keyboard layout types with it and nothing held, or a key code written key 0x24.

            \(PerformExit.discussion)
            """
    )

    @Argument(help: "The chords, pressed in order. Every one is proven pressable before the first goes down.")
    var chords: [String]

    @OptionGroup var target: TargetOption

    @OptionGroup var installation: FlavorOption

    @MainActor
    func run() async throws {
        let layout = try KeyboardLayout.current()
        // [LAW:parse-dont-validate] Spelled out here, at the edge, so the executor is handed
        // chords and never a string. A spelling that names no chord is a usage error.
        let actions = try chords.map { spelling in
            do { return Action.sendKeys(chord: try KeyChord(spelled: spelling, on: layout)) }
            catch { throw ValidationError("\(error)") }
        }
        try await Performance.perform(actions, in: try target.app(), on: layout, flavor: installation.flavor)
    }
}
