import ArgumentParser
import Foundation
import LowTalkerCore
import Serve
import Synchronization

/// Serves OpenAI's transcription endpoint and Realtime socket over the engine this command loads, until it is
/// stopped: how the endpoint is exercised on a developer's Mac, as `transcribe` exercises
/// the engine, with `scripts/conformance check` pointed at the URL it prints.
///
/// Stdout is the base URL, once listening, then one JSON line per request answered or socket closed.
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve OpenAI's POST /v1/audio/transcriptions and /v1/realtime on the installation's loopback port over WhisperKit."
    )

    @OptionGroup var installation: FlavorOption

    @OptionGroup var options: ModelOptions
    @OptionGroup var source: SourceOptions

    func run() async throws {
        // Bound before the model loads, so a port already taken is said at once rather than
        // a minute later, and a request meanwhile is refused with the reason.
        let resident = Mutex(ServedEngine.notResident("the model is still loading"))
        let server = try await TranscriptionServer.listen(
            for: installation.flavor,
            engine: { resident.withLock { $0 } },
            record: { line($0.json) }
        )
        line("http://127.0.0.1:\(server.port.rawValue)/v1")
        let transcriber = try await WhisperKitTranscriber.load(options.model, in: options.store(), from: source.source, phase: PhaseReporter().report)
        resident.withLock { $0 = .ready(transcriber) }
        try await server.finished()
    }
}

/// One line on stdout, written through at once: a pipe would otherwise hold the URL and the
/// events in a buffer until it fills.
private func line(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}
