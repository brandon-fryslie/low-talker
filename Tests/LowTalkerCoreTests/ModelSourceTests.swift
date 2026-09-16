@testable import LowTalkerCore
import Testing
@testable import WhisperKit

@Suite struct ModelSourceTests {
    /// The store installs the tokenizer WhisperKit will read at load, and WhisperKit's
    /// choice of it is internal, so the store's mirror is held to WhisperKit's own
    /// functions over every vocabulary and encoder width they tell apart, and one
    /// of each they do not.
    @Test(arguments: [51863, 51864, 51865, 51866, 51867], [0, 384, 512, 768, 1024, 1280, 1536])
    func tokenizerRepoMatchesWhisperKit(logitsDim: Int, encoderDim: Int) {
        let whisperKit = ModelUtilities.tokenizerNameForVariant(ModelUtilities.detectVariant(logitsDim: logitsDim, encoderDim: encoderDim))
        #expect(ModelVariant(logitsDim: logitsDim, encoderDim: encoderDim).tokenizerRepo == whisperKit)
    }

}
