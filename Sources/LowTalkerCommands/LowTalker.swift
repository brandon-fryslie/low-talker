import ArgumentParser
import Foundation

/// The CLI is how each stage is exercised alone. Every stage that lands in
/// LowTalkerCore gets a subcommand here, one per file, before it gets wired into
/// the app.
public struct LowTalker: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "lowtalker",
        abstract: "Exercise each stage of the low-talker pipeline from the command line.",
        subcommands: [Info.self, ConfigCommand.self, DriverCommand.self, OnboardCommand.self, SeeCommand.self, ClickCommand.self, PointerCommand.self, RouteCommand.self, ActCommand.self, TypeCommand.self, KeysCommand.self, MicCommand.self, RecordCommand.self, TranscribeCommand.self, ModelCommand.self, HotkeyCommand.self, PasteCommand.self, BenchCommand.self, DextCommand.self, DictateCommand.self]
    )

    public init() {}

    /// This binary as a reader can run it again: its own file, links resolved, so a step
    /// that names it outlives the link it was reached by. Where Foundation cannot say what
    /// file that is, the name it was started by.
    static let path: String = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
}
