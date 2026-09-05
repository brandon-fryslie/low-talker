import ArgumentParser

/// The CLI is how each stage is exercised alone. Every stage that lands in
/// LowTalkerCore gets a subcommand here, one per file, before it gets wired into
/// the app.
@main
struct LowTalker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lowtalker",
        abstract: "Exercise each stage of the low-talker pipeline from the command line.",
        subcommands: [Info.self, RouteCommand.self, MicCommand.self, RecordCommand.self, TranscribeCommand.self, ModelCommand.self, HotkeyCommand.self]
    )
}
