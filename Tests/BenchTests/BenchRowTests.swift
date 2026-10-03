import Foundation
import LowTalkerCore
import Testing
import Bench

@Suite struct BenchRowTests {
    /// Every field of the result is distinct, so a value fed into the wrong column
    /// shows up as the wrong number under that column's name.
    @Test func everyColumnCarriesItsOwnField() {
        let result = LatencyReport.FixtureResult(
            name: "say/greeting",
            arrival: .streamed,
            serving: .served,
            audio: 2.0164,
            first: LatencyReport.Run(keyUpToTranscript: .milliseconds(900), holdToFirstText: .milliseconds(1_600)),
            later: [
                LatencyReport.Run(keyUpToTranscript: .milliseconds(700), holdToFirstText: .milliseconds(1_400)),
                LatencyReport.Run(keyUpToTranscript: .milliseconds(650), holdToFirstText: .milliseconds(1_500)),
            ],
            transcript: Transcript(typed: "hello here world four five"),
            wordErrorRate: WordErrorRate(
                reference: SpokenWords("hello there world four"),
                hypothesis: SpokenWords("hello here world four five")
            ),
            served: LatencyReport.Served(cancelled: 6, deferred: 3, changed: 2)
        )
        let row = BenchRow(model: "base.en", load: .milliseconds(1_250), result: result).cells
        #expect(row.map(\.name) == [
            "model", "fixture", "delivery", "serving", "audio_s", "load_s", "first_s", "median_s", "partial_s",
            "wer", "substituted", "dropped", "added", "reference_words",
            "served_cancelled", "served_deferred", "served_changed",
        ])
        #expect(row.map(\.value) == [
            "base.en", "say/greeting", "streamed", "served", "2.016", "1.250", "0.900", "0.700", "1.500",
            "0.500", "1", "0", "1", "4",
            "6", "3", "2",
        ])
    }
}
