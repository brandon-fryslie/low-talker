import LowTalkerCore
import Testing

/// The report, which is the half of the check that is not hardware. Taking the readings
/// needs a Mac with a microphone and is `lowtalker mic indicator`; what the readings mean is
/// this, and nothing here fakes the property - a suite that did would be the mocked hardware
/// check this was built instead of.
@Suite struct IndicatorAcrossHoldTests {
    @Test func aMacThatKeptThePromiseHasNothingToExplain() {
        let across = IndicatorAcrossHold(atRest: .dark, duringHold: .lit, afterHold: .dark)
        #expect(across.kept)
        #expect("\(across)" == "at rest: dark, during the hold: lit, after the hold: dark")
    }

    /// Each moment breaks its own way, and the report names which one broke and what that
    /// means - the three faults have three different causes, and the line is where an
    /// operator learns which they are holding.
    @Test(arguments: [
        (IndicatorAcrossHold(atRest: .lit, duringHold: .lit, afterHold: .dark), IndicatorAcrossHold.Moment.atRest),
        (IndicatorAcrossHold(atRest: .dark, duringHold: .dark, afterHold: .dark), .duringHold),
        (IndicatorAcrossHold(atRest: .dark, duringHold: .lit, afterHold: .lit), .afterHold),
    ])
    func aBrokenPromiseIsNamedWithWhatItMeans(across: IndicatorAcrossHold, moment: IndicatorAcrossHold.Moment) {
        #expect(!across.kept)
        #expect(across.broken.map(\.moment) == [moment])
        #expect("\(across)".contains("\(moment): promised \(moment.promised), and \(moment.fault)"))
    }

    /// A microphone that never went dark at all breaks two of the three, and both are
    /// reported: an operator told only about the first would fix the rest and re-run into the
    /// second.
    @Test func aMicrophoneThatNeverGoesDarkBreaksMoreThanOnePromise() {
        let across = IndicatorAcrossHold(atRest: .lit, duringHold: .lit, afterHold: .lit)
        #expect(across.broken.map(\.moment) == [.atRest, .afterHold])
    }
}
