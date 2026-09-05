import ArgumentParser

/// The CLI is how the pipeline is exercised without the hotkey. Every stage that
/// lands in LowTalkerCore gets a subcommand here, one per file, before it gets wired
/// into the app.
@main
struct LowTalker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lowtalker",
        abstract: "Exercise the low-talker pipeline without the hotkey.",
        subcommands: [Info.self, RouteCommand.self, MicCommand.self, RecordCommand.self, TranscribeCommand.self, ModelCommand.self, HotkeyCommand.self]
    )
}
