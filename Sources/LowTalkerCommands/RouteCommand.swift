import ArgumentParser
import Foundation
import LowTalkerCore

/// Runs the router on a synthetic context and transcript and prints what it chose.
/// Nothing executes: the output is the same JSON a Pipe program would hand back, so
/// a route can be debugged by reading it.
struct RouteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "route",
        abstract: "Print the actions the router would choose, without executing them."
    )

    // [LAW:parse-dont-validate] The option's type is Context: the JSON is decoded once,
    // here at the edge, and the router never sees a string.
    @Option(
        help: ArgumentHelp(
            "The Context as JSON.",
            discussion: #"e.g. '{"chord":{"modifiers":["rightOption"]},"press":"hold","frontmostApp":"com.apple.Notes","focusedElementRole":"AXTextArea"}'"#
        ),
        transform: { try JSONDecoder().decode(Context.self, from: Data($0.utf8)) }
    )
    var context: Context

    @Option(help: "The words, as if the engine had heard them.")
    var text: String

    func run() throws {
        let actions = Router(routes: [.dictation]).actions(for: Transcript(typed: text), in: context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(actions), as: UTF8.self))
    }
}
