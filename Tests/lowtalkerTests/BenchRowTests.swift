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
            audio: 2.0164,
            firstKeyUpToTranscript: .milliseconds(900),
            laterKeyUpToTranscript: [.milliseconds(700), .milliseconds(650)],
            transcript: Transcript(typed: "hello here world four five"),
            wordErrorRate: WordErrorRate(
                reference: SpokenWords("hello there world four"),
                hypothesis: SpokenWords("hello here world four five")
            )
        )
        let row = BenchCommand.row(model: "base.en", load: .milliseconds(1_250), result: result)
        #expect(row.map(\.name) == [
            "model", "fixture", "audio_s", "load_s", "first_s", "median_s",
            "wer", "substituted", "dropped", "added", "reference_words",
        ])
        #expect(row.map(\.value) == [
            "base.en", "say/greeting", "2.016", "1.250", "0.900", "0.700",
            "0.500", "1", "0", "1", "4",
        ])
    }
}
