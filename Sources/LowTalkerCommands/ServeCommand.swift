import ArgumentParser
import Foundation
import LowTalkerCore
import Network
import Serve

/// Serves OpenAI's transcription endpoint and Realtime socket over the engine this command loads, until it is
/// stopped: how the endpoint is exercised on a developer's Mac, as `transcribe` exercises
/// the engine, with `scripts/conformance check` pointed at the URL it prints.
///
/// Stdout is the base URL, then one JSON line per request answered or socket closed.
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve OpenAI's POST /v1/audio/transcriptions and /v1/realtime on loopback over WhisperKit."
    )

    @Option(help: "The loopback port to listen on; 0 lets the system choose.")
    var port: UInt16 = 0

    @OptionGroup var options: ModelOptions
    @OptionGroup var source: SourceOptions

    func run() async throws {
        let transcriber = try await WhisperKitTranscriber.load(options.model, in: options.store(), from: source.source, phase: PhaseReporter().report)
        let server = try await TranscriptionServer.listen(
            on: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            engine: { .ready(transcriber) },
            record: { line($0.json) }
        )
        line("http://127.0.0.1:\(server.port.rawValue)/v1")
        try await server.finished()
    }
}

/// One line on stdout, written through at once: a pipe would otherwise hold the URL and the
/// events in a buffer until it fills.
private func line(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}
