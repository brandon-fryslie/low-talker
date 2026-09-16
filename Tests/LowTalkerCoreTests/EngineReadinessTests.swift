import LowTalkerCore
import Testing

/// The status item's face and words through the wait between launch and a loaded model.
@Suite struct EngineReadinessTests {
    @Test func aWaitSaysWhatItIsDoingAndHowLongItHasRun() {
        #expect(EngineReadiness.preparing(nil).readout(after: .seconds(0.4)) == "checking the model, 0 s so far")
        #expect(EngineReadiness.preparing(.installing(.copying)).readout(after: .seconds(3)) == "copying model, 3 s so far")
        #expect(EngineReadiness.preparing(.loading).readout(after: .seconds(164.7)) == "loading model, minutes the first time on this Mac, 2 min 44 s so far")
    }

    @Test func theEndOfTheWaitSaysHowLongItTook() {
        #expect(EngineReadiness.ready(.default).readout(after: .seconds(60)) == "ready (\(ModelName.default)) after 1 min 0 s")
        #expect(EngineReadiness.failed("no model").readout(after: .seconds(9)) == "failed — no model")
    }

    /// The icon of a ready engine is the only one that can say words are waiting: nothing
    /// is heard before the engine is ready, so a clipboard icon over a wait would be a lie.
    @Test(arguments: [false, true])
    func onlyAReadyEngineIsDrawnAsListening(wordsOnClipboard: Bool) {
        #expect(EngineReadiness.preparing(.loading).symbolName(wordsOnClipboard: wordsOnClipboard) == "hourglass")
        #expect(EngineReadiness.failed("x").symbolName(wordsOnClipboard: wordsOnClipboard) == "exclamationmark.triangle.fill")
        #expect(EngineReadiness.ready(.default).symbolName(wordsOnClipboard: wordsOnClipboard) == (wordsOnClipboard ? "doc.on.clipboard.fill" : "mic.fill"))
    }

    @Test func theIconNamesItsStateToAccessibility() {
        #expect(EngineReadiness.preparing(nil).iconDescription(for: "LowTalker", wordsOnClipboard: false) == "LowTalker: preparing the model")
        #expect(EngineReadiness.failed("x").iconDescription(for: "LowTalker", wordsOnClipboard: false) == "LowTalker: the model failed to load")
        #expect(EngineReadiness.ready(.default).iconDescription(for: "LowTalker", wordsOnClipboard: false) == "LowTalker")
        #expect(EngineReadiness.ready(.default).iconDescription(for: "LowTalker", wordsOnClipboard: true) == "LowTalker: dictation on the clipboard")
    }
}
