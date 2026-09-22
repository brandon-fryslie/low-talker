import ArgumentParser
import Flavors
import Foundation
import Insertion

/// Sends one string to the input method and prints what it answered.
///
/// The hand-held half of low-input-method-s71.31s's checkpoint: with the input source
/// selected, this is how the channel is watched putting words at a real cursor in a real
/// app, before the executor is wired to it in low-input-method-s71.b26.
///
/// It is also the only thing that exercises the channel against the actual input method
/// process. The suite stands a port up in-process, which proves the codec and every named
/// failure but cannot prove the claim the epic turns on - that a commit driven by a
/// message, not a key, reaches the app in front. [LAW:verifiable-goals]
struct InsertCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "insert",
        abstract: "Ask the input method to insert text at the cursor, and print its answer."
    )

    @Argument(help: "The text to insert.")
    var text: String

    @OptionGroup var installation: FlavorOption

    @Option(help: "Seconds to wait first, to bring the receiving app to the front.")
    var delay: Int = 0

    @Option(help: "Seconds for the whole round trip: the request out and the answer back.")
    var timeout: Int = 5

    func validate() throws {
        guard delay >= 0 else { throw ValidationError("--delay cannot be negative.") }
        guard timeout > 0 else { throw ValidationError("--timeout must be at least one second.") }
    }

    func run() throws {
        // Synchronous, like the insert below it: `Inserter` runs a run loop while it waits
        // and says in its own contract that no task may hold a cooperative thread for that
        // long. An `async` command here would be exactly that task, and the worked example
        // low-input-method-s71.b26 copies. [LAW:no-ambient-temporal-coupling]
        Thread.sleep(forTimeInterval: Double(delay))
        let flavor = installation.flavor
        // Thrown, not printed as an outcome: a channel that could not carry the question
        // is not an answer about the cursor, and the two must never read alike.
        // [LAW:no-silent-failure]
        let answer = try InputMethodInserter(flavor: flavor, timeout: .seconds(timeout)).insert(text)
        print("\(flavor) input method: \(describe(answer))")
    }

    private func describe(_ answer: InsertionAnswer) -> String {
        switch answer {
        case let .inserted(characters): "inserted \(characters) characters at the cursor"
        case let .refused(refusal): "refused - \(refusal)"
        }
    }
}
