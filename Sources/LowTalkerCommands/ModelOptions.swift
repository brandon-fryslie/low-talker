import ArgumentParser
import Foundation
import LowTalkerCore
import ModelInstall
import Synchronization

/// Which store, for every command that touches models.
///
/// [LAW:one-source-of-truth] exception: `model-tool` parses these flags with its own copy,
/// since an executable cannot import this library; this one goes with the CLI on
/// low-no-cli-hpk.c0i.
///
/// [LAW:one-source-of-truth] The default store is the one `make app` copies each bundle's
/// model out of, so a download from the terminal is what the next build carries. The app
/// itself never reads it: it loads the store inside its bundle.
struct StoreOptions: ParsableArguments {
    @Option(name: .customLong("models-dir"), help: "Where models are stored. Defaults to low-talker's store under Application Support, which `make app` copies a bundle's model out of.", transform: URL.init(fileURLWithPath:))
    var modelsDirectory: URL?

    func store() throws -> ModelStore {
        try modelsDirectory.map(ModelStore.init(directory:)) ?? ModelStore.applicationSupport()
    }
}

/// Which model and which store, for every command that works one model.
struct ModelOptions: ParsableArguments {
    @Option(help: "A model folder name in the whisperkit-coreml repo.")
    var model: ModelName = .default

    @OptionGroup var location: StoreOptions

    func store() throws -> ModelStore {
        try location.store()
    }
}

/// Where a command takes a model from when the store does not have it.
struct SourceOptions: ParsableArguments {
    @Option(name: .customLong("from"), help: "Where to take a model the store lacks: huggingface.co at a revision `model-tool revision` printed, an http(s) base URL serving <model>.zip, as `model-tool pack` writes them, or a directory holding another model store. Defaults to huggingface.co at the revision `main` names.")
    var source: ModelSource = .huggingFace(nil)
}

/// [LAW:parse-dont-validate] Two commits are a revision on huggingface.co, a URL with an
/// http or https scheme is a published base, and anything else is a path to a store, so
/// the one flag cannot be read two ways and a revision cannot be asked of a copy.
extension ModelSource: ExpressibleByArgument {
    public init?(argument: String) {
        if let revision = ModelRevision(argument) {
            self = .huggingFace(revision)
        } else if let url = URL(string: argument), ["http", "https"].contains(url.scheme) {
            self = .published(url)
        } else {
            self = .store(ModelStore(directory: URL(fileURLWithPath: argument)))
        }
    }

    public var defaultValueDescription: String { description }
}


/// What the speaker is expected to say, for every command that hears: the
/// vocabulary a mode would supply, given by hand.
///
/// [LAW:parse-dont-validate] Each `--vocabulary` is parsed into a term at the
/// command line, so a blank one is refused before any model loads.
struct VocabularyOptions: ParsableArguments {
    @Option(name: .customLong("vocabulary"), help: "A name or term the speaker is expected to say, spelled as it should be written; the engine is told it ahead of the audio. Repeat for several.", transform: Vocabulary.Term.init)
    var terms: [Vocabulary.Term] = []

    var vocabulary: Vocabulary {
        Vocabulary(terms)
    }
}

/// Narrates a load on stderr, one line each time the phase's own words change, so
/// a download prints once per whole percent. Stdout stays the command's own.
final class PhaseReporter: Sendable {
    private let lastLine = Mutex<String?>(nil)

    func report(_ phase: WhisperKitTranscriber.InstallingLoadPhase) {
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

