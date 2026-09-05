import Foundation
import LowTalkerCore
import Testing
@testable import lowtalker

@Suite struct BenchRowTests {
    /// Every field of the result is distinct, so a value fed into the wrong column
    /// shows up as the wrong number under that column's name.
    @Test func everyColumnCarriesItsOwnField() {
        let result = LatencyReport.FixtureResult(
            name: "say/greeting",
            delivery: .streamed,
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
            )
        )
        let row = BenchCommand.row(model: "base.en", load: .milliseconds(1_250), result: result)
        #expect(row.map(\.name) == [
            "model", "fixture", "delivery", "audio_s", "load_s", "first_s", "median_s", "partial_s",
            "wer", "substituted", "dropped", "added", "reference_words",
        ])
        #expect(row.map(\.value) == [
            "base.en", "say/greeting", "streamed", "2.016", "1.250", "0.900", "0.700", "1.500",
            "0.500", "1", "0", "1", "4",
        ])
    }
}
