import ArgumentParser
import Foundation
import LowTalkerCore
import Synchronization

/// Which model and which store, for every command that touches the engine.
///
/// [LAW:one-source-of-truth] The default store is the app's; the CLI reads and writes
/// the same directory so a download from the terminal is a download for the app.
struct ModelOptions: ParsableArguments {
    @Option(help: "A model folder name in the whisperkit-coreml repo.")
    var model: ModelName = .default

    @Option(name: .customLong("models-dir"), help: "Where models are stored. Defaults to the app's directory under Application Support.", transform: URL.init(fileURLWithPath:))
    var modelsDirectory: URL?

    func store() throws -> ModelStore {
        try modelsDirectory.map(ModelStore.init(directory:)) ?? ModelStore.applicationSupport()
    }
}

/// [LAW:parse-dont-validate] `--model` is parsed into a name at the command line, so a
/// value that is not one path step is refused before any path is built from it.
extension ModelName: ExpressibleByArgument {}

/// Narrates a load on stderr, one line each time the phase's own words change, so
/// a download prints once per whole percent. Stdout stays the command's own.
final class PhaseReporter: Sendable {
    private let lastLine = Mutex<String?>(nil)

    func report(_ phase: WhisperKitTranscriber.LoadPhase) {
        let line = phase.description
        let changed = lastLine.withLock { last in
            defer { last = line }
            return line != last
        }
        if changed {
            var stderr = StandardError()
            print(line, to: &stderr)
        }
    }
}

/// `print(_:to:)` wants a TextOutputStream, and FileHandle is not one.
struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
