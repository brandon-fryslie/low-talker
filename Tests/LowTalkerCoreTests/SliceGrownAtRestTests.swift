import LowTalkerCore
import Testing

/// The report, which is the half of the check that is not hardware. Taking the reading needs a
/// Mac whose default input offers a larger IO buffer than it is using, and is
/// `lowtalker mic slice`; nothing here fakes a render.
@Suite struct SliceGrownAtRestTests {
    @Test func aPressThatHeardHasNothingToExplain() {
        let across = SliceGrownAtRest(device: 140, readiedAt: 512, grownTo: 4096, delivered: 5, failure: nil)
        #expect(across.kept)
        #expect("\(across)" == "device 140: readied at 512 frames, grown to 4096 while resting, press delivered 5 buffers")
    }

    /// A press whose every render was refused, which is what this Mac printed before
    /// low-privacy-o1z.c0p: the refusal is the reading's evidence.
    @Test func aRefusedPressCarriesItsFailureAndTheDefectItMeans() {
        let across = SliceGrownAtRest(device: 140, readiedAt: 512, grownTo: 4096, delivered: 0, failure: "past the 512 frames it was readied at")
        #expect(!across.kept)
        let lines = "\(across)".split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("past the 512 frames it was readied at"))
    }

    /// A press that reports nothing and delivers nothing lost the same utterance, only quietly.
    @Test func aPressThatDeliveredNothingIsNotKeptEvenWithNoFailure() {
        let across = SliceGrownAtRest(device: 140, readiedAt: 512, grownTo: 4096, delivered: 0, failure: nil)
        #expect(!across.kept)
        #expect("\(across)".contains("and reported nothing"))
    }

    /// Audio that arrived does not excuse a failure the press reported alongside it.
    @Test func aPressThatDeliveredButReportedAFailureIsNotKept() {
        let across = SliceGrownAtRest(device: 140, readiedAt: 512, grownTo: 4096, delivered: 3, failure: "refused")
        #expect(!across.kept)
    }
}
