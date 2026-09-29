import ArgumentParser
import Foundation
import LowTalkerCore
import Serve
import Synchronization

/// Serves OpenAI's transcription endpoint and Realtime socket over the engine this command loads, until it is
/// stopped: how the endpoint is exercised on a developer's Mac, as `transcribe` exercises
/// the engine, with `scripts/conformance check` pointed at the URL it prints.
///
/// Stdout is the base URL, once it can transcribe, then one JSON line per request answered or socket closed.
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve OpenAI's POST /v1/audio/transcriptions and /v1/realtime on the installation's port over WhisperKit.",
        discussion: """
            Listens where the config's [serve] table says: loopback when it names no \
            interface, answering any token or none; otherwise that interface, answering \
            only callers that send serve.token as a bearer token.
            """
    )

    @OptionGroup var installation: FlavorOption

    /// Absent means this installation's own file, resolved as `config check` resolves it.
    @Option(
        help: "The config file whose [serve] table says where to listen, for trying one out before it is installed.",
        transform: URL.init(fileURLWithPath:)
    )
    var path: URL?

    @OptionGroup var options: ModelOptions
    @OptionGroup var source: SourceOptions

    func run() async throws {
        // Bound before the model loads, so a port already taken is said at once rather than
        // a minute later, and a request meanwhile is refused with the reason.
        let file = try ConfigSource(path: path, stated: installation.stated)
        let binding = try Config.load(file.path, for: file.flavor).config.serve
        let resident = Mutex(ServedEngine.notResident("the model is still loading"))
        let server = try await TranscriptionServer.listen(
            for: file.flavor,
            on: binding,
            engine: { resident.withLock { $0 } },
            record: { line($0.json) }
        )
        let transcriber = try await WhisperKitTranscriber.load(options.model, in: options.store(), from: source.source, phase: PhaseReporter().report)
        resident.withLock { $0 = .ready(transcriber) }
        // The URL is the readiness signal a client waits for; one given it early is refused
        // with 503 until the model is resident.
        line(server.baseURL)
        try await server.finished()
    }
}

/// One line on stdout, written through at once: a pipe would otherwise hold the URL and the
/// events in a buffer until it fills.
private func line(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}
