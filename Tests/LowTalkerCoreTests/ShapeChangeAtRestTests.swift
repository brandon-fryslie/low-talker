import LowTalkerCore
import Testing

/// The report, which is the half of the check that is not hardware. Taking the reading needs a
/// Mac with a microphone that offers more than one sample rate and is `lowtalker mic shape`;
/// what the reading means is this, and nothing here fakes the notification - a suite that did
/// would be the mocked hardware check this was built instead of.
@Suite struct ShapeChangeAtRestTests {
    @Test func aMacThatKeptThePromiseHasNothingToExplain() {
        let across = ShapeChangeAtRest(device: 143, readiedAt: 48000, movedTo: 44100, report: .heard, leftAt: 48000)
        #expect(across.kept)
        #expect("\(across)" == "device 143: readied at 48000.0 Hz, moved to 44100.0 Hz while resting, heard, left at 48000.0 Hz")
    }

    /// The fault an operator is most likely to hold, and the one this whole reading exists to
    /// catch: the watch outlived the press or it did not.
    @Test func aChangeNobodyHeardNamesTheDefectItMeans() {
        let across = ShapeChangeAtRest(device: 143, readiedAt: 48000, movedTo: 44100, report: .never, leftAt: 48000)
        #expect(!across.kept)
        #expect(across.faults == [.unheard])
        #expect("\(across)".contains("\(ShapeChangeAtRest.Fault.unheard)"))
    }

    /// A reading moves this Mac to ask its question, so a run that could not move it back owes
    /// the operator that sentence whatever the answer turned out to be.
    @Test func aDeviceLeftInTheShapeTheReadingMovedItToIsAFaultOfItsOwn() {
        let across = ShapeChangeAtRest(device: 143, readiedAt: 48000, movedTo: 44100, report: .heard, leftAt: 44100)
        #expect(!across.kept)
        #expect(across.faults == [.leftReshaped])
    }

    /// Both faults are reported, because they have different owners: one is the app's code and
    /// one is the Mac this ran on, and an operator told only about the first would fix the
    /// watch and never learn their sample rate had moved.
    @Test func aReadingThatBrokeTwiceSaysSoTwice() {
        let across = ShapeChangeAtRest(device: 143, readiedAt: 48000, movedTo: 44100, report: .never, leftAt: 44100)
        #expect(across.faults == [.unheard, .leftReshaped])
        #expect("\(across)".split(separator: "\n").count == 3)
    }
}
