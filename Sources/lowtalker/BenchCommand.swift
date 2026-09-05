import ArgumentParser
import Foundation
import LowTalkerCore

/// The latency harness from the terminal: every fixture in a directory through
/// every model asked for, one table out. This is how the default model was chosen
/// and how the streaming and vocabulary work measure themselves.
///
/// Stdout is one tab-separated table, a row per model and fixture, so runs can be
/// diffed or pasted into a ticket. Stderr narrates each load and shows what the
/// engine heard, which is where a word error rate gets explained.
struct BenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Time model load and key-up-to-transcript, and score word error rate, over a fixture directory."
    )

    @Argument(help: "A directory of <name>.wav beside <name>.txt, the reference text.", transform: URL.init(fileURLWithPath:))
    var fixtures: URL

    @Option(name: .customLong("model"), help: "A model folder name in the whisperkit-coreml repo. Repeat for several.")
    var models: [ModelName] = [.default]

    @Option(help: "How many times to decode each fixture. The first decode after a load is reported apart from the median.")
    var runs: Int = 3

    @OptionGroup var location: StoreOptions

    func validate() throws {
        guard runs >= 1 else { throw ValidationError("--runs must be at least 1.") }
    }

    func run() async throws {
        let fixtures = try Fixture.load(directory: fixtures)
        let store = try location.store()
        var stderr = StandardError()
        var header = true
        for model in models {
            let reporter = PhaseReporter()
            print("model \(model)", to: &stderr)
            let report = try await LatencyHarness.measure(fixtures, reruns: runs - 1) {
                try await WhisperKitTranscriber.load(model, from: store, phase: reporter.report)
            }
            for result in report.fixtures {
                print("  \(result.name): heard \"\(result.transcript.text)\", \(result.wordErrorRate)", to: &stderr)
                let row = Self.row(model: model, load: report.load, result: result)
                // [LAW:one-source-of-truth] The header is the first row's names, so a
                // column cannot be titled one thing and filled with another.
                if header { print(row.map(\.name).joined(separator: "\t")) }
                header = false
                print(row.map(\.value).joined(separator: "\t"))
                // A row can be minutes apart from the next; a file watcher sees each as
                // it lands rather than all of them at exit.
                fflush(stdout)
            }
        }
    }

    /// One table row: every number to three places, every duration in seconds.
    static func row(model: ModelName, load: Duration, result: LatencyReport.FixtureResult) -> [(name: String, value: String)] {
        let wer = result.wordErrorRate
        return [
            ("model", model.description),
            ("fixture", result.name),
            ("audio_s", fixed(result.audio, places: 3)),
            ("load_s", load.seconds),
            ("first_s", result.firstKeyUpToTranscript.seconds),
            ("median_s", result.medianKeyUpToTranscript.seconds),
            ("wer", fixed(wer.rate, places: 3)),
            ("substituted", String(wer.substitutions)),
            ("dropped", String(wer.deletions)),
            ("added", String(wer.insertions)),
            ("reference_words", String(wer.referenceCount)),
        ]
    }
}
