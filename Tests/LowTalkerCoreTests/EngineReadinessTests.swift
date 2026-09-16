import LowTalkerCore
import Testing

/// The status item's face and words through the wait between launch and a loaded model.
@Suite struct EngineReadinessTests {
    let launch = ContinuousClock.now

    @Test func aWaitSaysWhatItIsDoingAndHowLongItHasRun() {
        #expect(EngineReadiness.preparing(nil, since: launch).readout(at: launch + .seconds(0.4)) == "checking the model, 0 s so far")
        #expect(EngineReadiness.preparing(.installing(.copying), since: launch).readout(at: launch + .seconds(3)) == "copying model, 3 s so far")
        #expect(EngineReadiness.preparing(.loading, since: launch).readout(at: launch + .seconds(164.7)) == "loading model, minutes the first time on this Mac, 2 min 44 s so far")
    }

    /// The load's own length, however long after it the menu is opened: a readout taken an
    /// hour later still says how long the wait was.
    @Test func theEndOfTheWaitSaysHowLongItTook() {
        let ready = EngineReadiness.ready(.default, after: .seconds(60))
        #expect(ready.readout(at: launch) == "ready (\(ModelName.default)) after 1 min 0 s")
        #expect(ready.readout(at: launch + .seconds(3600)) == "ready (\(ModelName.default)) after 1 min 0 s")
        #expect(EngineReadiness.failed("no model").readout(at: launch) == "failed — no model")
    }

    /// The icon of a ready engine is the only one that can say words are waiting: nothing
    /// is heard before the engine is ready, so a clipboard icon over a wait would be a lie.
    @Test(arguments: [false, true])
    func onlyAReadyEngineIsDrawnAsListening(wordsOnClipboard: Bool) {
        #expect(EngineReadiness.preparing(.loading, since: launch).symbolName(wordsOnClipboard: wordsOnClipboard) == "hourglass")
        #expect(EngineReadiness.failed("x").symbolName(wordsOnClipboard: wordsOnClipboard) == "exclamationmark.triangle.fill")
        #expect(EngineReadiness.ready(.default, after: .seconds(5)).symbolName(wordsOnClipboard: wordsOnClipboard) == (wordsOnClipboard ? "doc.on.clipboard.fill" : "mic.fill"))
    }

    @Test func theIconNamesItsStateToAccessibility() {
        #expect(EngineReadiness.preparing(nil, since: launch).iconDescription(for: "LowTalker", wordsOnClipboard: false) == "LowTalker: preparing the model")
        #expect(EngineReadiness.failed("x").iconDescription(for: "LowTalker", wordsOnClipboard: false) == "LowTalker: the model failed to load")
        #expect(EngineReadiness.ready(.default, after: .seconds(5)).iconDescription(for: "LowTalker", wordsOnClipboard: false) == "LowTalker")
        #expect(EngineReadiness.ready(.default, after: .seconds(5)).iconDescription(for: "LowTalker", wordsOnClipboard: true) == "LowTalker: dictation on the clipboard")
    }
}
