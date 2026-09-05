import ArgumentParser
import Foundation
import LowTalkerCore

/// The model store from the terminal: what is on disk, and fetching what is not.
/// This is how "a fresh install downloads once and the next launch loads from
/// cache" is checked without launching the app.
struct ModelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: "Inspect and download the Whisper model the app loads at launch.",
        subcommands: [Status.self, Download.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report whether the model is installed. Exits 1 when it is not, so scripts can test."
        )

        @OptionGroup var options: ModelOptions

        func run() throws {
            let store = try options.store()
            print("store: \(store.directory.path)")
            switch store.presence(of: options.model) {
            case .installed(let installed):
                print("installed: \(installed.folder.path)")
            case .missing:
                print("missing: \(options.model)")
                throw ExitCode(1)
            case .damaged(let reason):
                print("damaged: \(reason)")
                throw ExitCode(1)
            }
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download the model into the store, or finish a download that stopped."
        )

        @OptionGroup var options: ModelOptions

        func run() async throws {
            let reporter = PhaseReporter()
            let installed = try await options.store().install(options.model) { reporter.report(.downloading(fractionCompleted: $0)) }
            print("installed: \(installed.folder.path)")
        }
    }
}
