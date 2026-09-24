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
        subcommands: [Status.self, Download.self, Pack.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report whether the model is installed. Exits 1 when it is not, so scripts can test."
        )

        @OptionGroup var options: ModelOptions

        func run() throws {
            let store = try options.store()
            print("store: \(store.directory.path)")
            switch try store.presence(of: options.model) {
            case .installed(let installed):
                print("installed: \(installed.folder.path)")
            case .missing:
                print("missing: \(options.model)")
                throw ExitCode(1)
            case .damaged(let damages):
                print("damaged: \(damages.map(\.description).joined(separator: "; "))")
                throw ExitCode(1)
            }
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install the model into the store, or finish an install that stopped."
        )

        @OptionGroup var options: ModelOptions
        @OptionGroup var source: SourceOptions

        func run() async throws {
            let reporter = PhaseReporter()
            let installed = try await options.store().install(options.model, from: source.source) { reporter.report(.installing($0)) }
            print("installed: \(installed.folder.path)")
        }
    }

    /// The archive a published base serves, made from a model this store holds, so a
    /// Mac that cannot reach huggingface.co can install it with `download --from`.
    struct Pack: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write <model>.zip, a store holding the installed model alone, for a published base to serve."
        )

        @OptionGroup var options: ModelOptions

        @Option(name: .customLong("to"), help: "The directory to write <model>.zip into.", transform: URL.init(fileURLWithPath:))
        var directory: URL

        func run() async throws {
            let reporter = PhaseReporter()
            let archive = try await options.store().pack(options.model, into: directory) { reporter.report(.installing($0)) }
            print("packed: \(archive.path)")
        }
    }
}
