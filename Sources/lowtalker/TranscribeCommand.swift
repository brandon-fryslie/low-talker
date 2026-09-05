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

    @Option(help: "A model folder name in the whisperkit-coreml repo, downloaded on first use.", transform: WhisperKitTranscriber.Model.init(rawValue:))
    var model: WhisperKitTranscriber.Model = .default

    func run() async throws {
        let clip = try AudioClip(contentsOf: file)
        let clock = ContinuousClock()

        let loadStart = clock.now
        let transcriber = try await WhisperKitTranscriber(model: model)
        let loaded = clock.now

        let transcript = try await transcriber.transcribe(clip)
        let transcribed = clock.now

        var stderr = StandardError()
        print("model \(model): loaded in \(loaded - loadStart), transcribed \(seconds(clip.duration)) s of audio in \(transcribed - loaded)", to: &stderr)

        print(transcript.text)
        for word in transcript.words {
            print("\(seconds(word.time.lowerBound)) \(seconds(word.time.upperBound))  \(word.confidence.value.formatted(.number.precision(.fractionLength(2))))  \(word.text)")
        }
    }

    private func seconds(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(3)))
    }
}

/// `print(_:to:)` wants a TextOutputStream, and FileHandle is not one.
private struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
