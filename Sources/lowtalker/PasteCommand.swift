import AppKit
import ArgumentParser
import LowTalkerCore

/// Pastes text into whatever app is frontmost when the delay runs out, so the
/// insertion path can be watched landing in TextEdit or Terminal before the app is
/// wired, and the pasteboard checked afterward.
///
/// Pressing another app's menu item needs Accessibility for this process, which for
/// this command is the terminal.
struct PasteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Paste text into the frontmost app and put the pasteboard back."
    )

    @Argument(help: "The text to insert.")
    var text: String

    @Option(help: "Seconds to wait first, to bring the receiving app to the front.")
    var delay: Int = 0

    func validate() throws {
        guard delay >= 0 else { throw ValidationError("--delay cannot be negative.") }
    }

    @MainActor
    func run() async throws {
        try await Task.sleep(for: .seconds(delay))
        guard let app = NSWorkspace.shared.frontmostApplication else { throw NoFrontmostApp() }
        let outcome = try await PasteInserter().insert(text, into: PasteMenuItem(of: app))
        switch outcome {
        case .restored: print("pasted into \(app.bundleIdentifier ?? "the frontmost app"), pasteboard restored")
        case .pasteboardTaken: print("pasted into \(app.bundleIdentifier ?? "the frontmost app"), pasteboard left to whoever took it")
        }
    }
}

struct NoFrontmostApp: Error, CustomStringConvertible {
    var description: String { "no app is frontmost; nothing can receive a paste" }
}
