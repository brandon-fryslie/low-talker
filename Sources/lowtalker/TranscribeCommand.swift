import ArgumentParser
import Foundation
import LowTalkerCore

/// Runs the real engine on a file and prints what it heard, word by word. This is
/// how the engine is exercised on a developer's Mac; CI has no model weights and
/// tests the mapping without them.
///
/// Stdout is the transcript and stderr is the timing, so the words can be piped or
/// diffed while a human still sees how long the model took.
struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio file with WhisperKit and print every word with its timing."
    )

    @Argument(help: "An audio file AVFoundation can read (wav, aiff, m4a, ...).", transform: URL.init(fileURLWithPath:))
    var file: URL

    @OptionGroup var options: ModelOptions

    func run() async throws {
        let clip = try AudioClip(contentsOf: file)
        let clock = ContinuousClock()
        let reporter = PhaseReporter()

        let loadStart = clock.now
        let transcriber = try await WhisperKitTranscriber.load(options.model, from: options.store(), phase: reporter.report)
        let loaded = clock.now

        let transcript = try await transcriber.transcribe(clip)
        let transcribed = clock.now

        var stderr = StandardError()
        print("model \(options.model): loaded in \(loaded - loadStart), transcribed \(fixed(clip.duration, places: 3)) s of audio in \(transcribed - loaded)", to: &stderr)

        print(transcript.text)
        for word in transcript.words {
            print("\(fixed(word.time.lowerBound, places: 3)) \(fixed(word.time.upperBound, places: 3))  \(fixed(word.confidence.value, places: 2))  \(word.text)")
        }
    }

    /// [LAW:one-source-of-truth] Every number on stdout is written here, pinned to a
    /// locale no machine setting can change, so the output diffs across machines.
    private func fixed(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
