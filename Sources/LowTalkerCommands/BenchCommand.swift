import ArgumentParser
import Bench
import Foundation
import LowTalkerCore
import ModelInstall

/// The latency harness from the terminal: every fixture in a directory through
/// every model asked for, held every way asked for, one table out. This is how
/// the default model was chosen and how the streaming and vocabulary work measure
/// themselves.
///
/// Stdout is one tab-separated table, a row per model, fixture, and delivery, so
/// runs can be diffed or pasted into a ticket: a run with `--vocabulary` against
/// one without is how a vocabulary's effect on every fixture is read. Stderr
/// narrates each load and shows what the engine heard, which is where a word
/// error rate gets explained.
struct BenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Time model load, key-up-to-transcript, and first text, and score word error rate, over a fixture directory."
    )

    @Argument(help: "A directory of <name>.wav beside <name>.txt, the reference text.", transform: URL.init(fileURLWithPath:))
    var fixtures: URL

    @Option(name: .customLong("model"), help: "A model folder name in the whisperkit-coreml repo. Repeat for several.")
    var models: [ModelName] = [.default]

    /// Still spelled `--delivery`, as is the column it prints, because the flag and the
    /// header are what every bench run already recorded was taken under - in the README's
    /// tables and in closed tickets - and a reading is only comparable to one named the
    /// same way. The type behind them is `Arrival`, because a delivery is how the words
    /// reach the cursor, which is another question. [LAW:one-source-of-truth]
    @Option(name: .customLong("delivery"), help: "How a hold's audio reaches the engine: batch (the whole clip at key-up) or streamed (a microphone buffer at a time). Repeat for both.")
    var arrivals: [LatencyHarness.Arrival] = LatencyHarness.Arrival.allCases

    @Option(name: .customLong("serving"), help: "What else asks the engine during each hold: idle (nothing) or served (a 40 s upload decoding at key-down, another arriving mid-hold, and a stream throughout). Repeat for both.")
    var servings: [LatencyHarness.Serving] = [.idle]

    @Option(help: "How many times to hold each fixture, per delivery. The first hold after a load is reported apart from the median.")
    var runs: Int = 3

    @OptionGroup var location: StoreOptions
    @OptionGroup var source: SourceOptions
    @OptionGroup var expected: VocabularyOptions

    func run() async throws {
        let fixtures = try Fixture.load(directory: fixtures)
        let store = try location.store()
        let plan = try BenchPlan(models: models, arrivals: arrivals, servings: servings, runs: runs, vocabulary: expected.vocabulary)
        var header = true
        // [LAW:one-source-of-truth] The loop and the table are the app's bench; only the load,
        // which may install from a source, and the printing are this command's.
        try await Bench.measure(fixtures, plan: plan, load: { [source] model in
            let turns = EngineTurns()
            let engine = try await WhisperKitTranscriber.load(model, in: store, from: source.source, turns: turns, phase: PhaseReporter().report)
            return LatencyHarness.Engine(dictation: engine, served: engine.served, turns: turns)
        }) { event in
            var stderr = StandardError()
            switch event {
            case .loading(let model):
                print("model \(model)", to: &stderr)
            case .row(let row):
                print("  \(row.narration)", to: &stderr)
                if header { print(row.header) }
                header = false
                print(row.line)
                // A row can be minutes apart from the next; a file watcher sees each as it
                // lands rather than all of them at exit.
                fflush(stdout)
            }
        }
    }
}
