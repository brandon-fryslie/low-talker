import LowTalkerCore
import Testing

/// The report, which is the half of the check that is not hardware. Taking the reading needs a
/// Mac whose microphone offers more than one sample rate and is `lowtalker mic change`; what the
/// reading means is this.
@Suite struct ReadyingAcrossChangeTests {
    private func reading(
        readying: Duration = .milliseconds(100),
        heard: Bool = true,
        longestHold: Duration = .milliseconds(5),
        press: ReadyingAcrossChange.Press = .whole(beginning: .milliseconds(80)),
        leftAt: Double = 48000
    ) -> ReadyingAcrossChange {
        ReadyingAcrossChange(device: 140, readying: readying, readiedAt: 48000, movedTo: 44100, heard: heard, longestHold: longestHold, press: press, leftAt: leftAt)
    }

    @Test func aMacThatKeptBothPromisesHasNothingToExplain() {
        let across = reading()
        #expect(across.kept)
        #expect("\(across)" == "device 140: a readying costs 100 ms; moved from 48000.0 Hz to 44100.0 Hz, heard, the main actor's longest hold 5 ms; moved back, a press made as it landed had begun 80 ms later and came back whole; left at 48000.0 Hz")
    }

    /// The fault this reading exists for: a hold as long as half a readying is a readying done on
    /// the main actor, whatever else is true.
    @Test func aHoldOfHalfAReadyingIsAReadyingOnTheMainActor() {
        #expect(reading(longestHold: .milliseconds(49)).kept)
        #expect(reading(longestHold: .milliseconds(50)).faults == [.heldTheMainActor])
    }

    /// Partial, refused and never are all a press the speaker lost, and each says which.
    @Test func everyPressThatIsNotWholeIsAFault() {
        let partial = reading(press: .partial(beginning: .milliseconds(212), lost: "cut where the microphone was not open"))
        #expect(partial.faults == [.pressNotWhole])
        #expect("\(partial)".contains("had begun 212 ms later and came back cut where the microphone was not open"))
        #expect(reading(press: .refused("no microphone")).faults == [.pressNotWhole])
        #expect(reading(press: .never).faults == [.pressNotWhole])
    }

    /// A change nobody heard leaves the hold measured across nothing, so a short one is not a
    /// promise kept.
    @Test func aChangeNobodyHeardIsNotAShortHold() {
        #expect(reading(heard: false).faults == [.unheard])
    }

    /// Every fault is reported, one line each, because they have different owners.
    @Test func aReadingThatBrokeEveryWaySaysSoEveryWay() {
        let across = reading(heard: false, longestHold: .milliseconds(100), press: .never, leftAt: 44100)
        #expect(across.faults == [.unheard, .heldTheMainActor, .pressNotWhole, .leftReshaped])
        #expect("\(across)".split(separator: "\n").count == 5)
    }
}
